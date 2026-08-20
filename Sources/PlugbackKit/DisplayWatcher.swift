import AppKit

/// 원시 화면 이벤트 3~6회를 의미 있는 이벤트 1회로 압축한다 (F-01.2, F-01.3).
/// US-009(창 튐 방지)는 전부 이 모듈 안에서 결판난다.
///
/// - 이벤트 안정화: 마지막 이벤트 후 일정 시간 추가 이벤트가 없을 때만 판정한다 (trailing 디바운스).
/// - 위상 게이트: 직전 외장 화면 식별자 집합과 비교해 **새 식별자가 추가된 경우에만** 콜백한다.
///   잠자기 해제·덮개 여닫기·잠금 해제·해상도 변경은 집합이 변하지 않으므로 조용히 지나간다.
/// - 잠자기 억제: 해제 직후 일정 시간은 추가가 보여도 콜백하지 않는다. 기준선은 계속 갱신한다.
/// - 잠금 미루기: 잠긴 상태에서 온 등장은 **버리지 않고** 들고 있다가 잠금 해제 때 한 번 소비한다.
///   잠긴 채로 복원하면 해제 때 macOS가 창을 다시 흩고, 덮개를 열며 꽂는 흐름은 잠자기 억제에
///   삼켜져 재발화 경로가 없다. 미뤄둔 회차가 없으면 잠금 해제는 지금처럼 조용하다.
@MainActor
public final class DisplayWatcher {
    private let provider: ScreenProvider
    private let debounceInterval: TimeInterval
    private let wakeSuppressionInterval: TimeInterval
    /// 무페이로드 — 어떤 화면인지는 소비자가 어차피 전체 동기화로 알아낸다.
    /// "어느 화면이 새로 왔나"는 발화 여부를 정하는 내부 계산일 뿐, 인터페이스가 아니다.
    private let onExternalScreensAppeared: () -> Void
    /// 사라진 외장 화면의 식별자들. 등장과 달리 페이로드가 있다 —
    /// 자동 슬롯 확정은 "어느 화면이 빠졌나"를 알아야 하는데, 그 화면은 이미 목록에 없어 되물을 수 없다.
    private let onExternalScreensRemoved: (Set<String>) -> Void
    /// 화면 잠금 판정. 주입하는 이유는 테스트뿐이다 (컨트롤러의 권한 판정과 같은 방식).
    /// 기본 구현은 비공식 세션 키를 읽는다 — docs/UNDOCUMENTED_APIS.md.
    private let isLocked: () -> Bool

    private var knownExternalIDs: Set<String>
    /// 잠금 중이라 미뤄둔 등장이 있다. 잠금 해제 때 이 한 건만 소비한다.
    private var deferredUntilUnlock = false
    private var pending: DispatchWorkItem?
    private var suppressUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    /// 시간 상수는 실기기 측정 후 조정할 수 있는 초기값이다 (FUNCTIONAL_SPEC 서문).
    public init(provider: ScreenProvider,
                debounceInterval: TimeInterval = 1.5,
                wakeSuppressionInterval: TimeInterval = 2.5,
                isLocked: @escaping () -> Bool = { DisplayWatcher.screenIsLocked() },
                onExternalScreensRemoved: @escaping (Set<String>) -> Void = { _ in },
                onExternalScreensAppeared: @escaping () -> Void) {
        self.provider = provider
        self.debounceInterval = debounceInterval
        self.wakeSuppressionInterval = wakeSuppressionInterval
        self.isLocked = isLocked
        self.onExternalScreensRemoved = onExternalScreensRemoved
        self.onExternalScreensAppeared = onExternalScreensAppeared
        knownExternalIDs = Set(provider.screens().filter { !$0.isBuiltin }.map(\.id))
    }

    /// 순수 이벤트 구독만 사용한다 — 상시 폴링·주기 타이머 없음 (F-07).
    /// 디바운스의 one-shot asyncAfter는 이벤트에 반응해 시작되는 유한 대기라 F-07이 허용한다.
    public func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenParametersChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        })
        // 잠금 해제는 분산 알림으로만 온다 — NSWorkspace에 대응 알림이 없다 (docs/UNDOCUMENTED_APIS.md).
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenDidUnlock() }
        })
        // ponytail: 앱 수명과 같이 사는 객체라 구독 해제 경로는 만들지 않는다.
    }

    /// 비공식 API 두 개 중 하나 — 잠금 여부를 세션 사전에서 읽는다 (docs/UNDOCUMENTED_APIS.md).
    /// 키가 사라지면 "잠기지 않음"으로 읽혀 이 기능만 조용히 꺼진다 — 복원 자체는 막지 않는다.
    public nonisolated static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // internal — 테스트가 알림 없이 직접 주입한다.
    func screenParametersChanged() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.stabilized() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    func systemDidWake() {
        suppressUntil = Date().addingTimeInterval(wakeSuppressionInterval)
    }

    // internal — 테스트가 알림 없이 직접 주입한다.
    func screenDidUnlock() {
        guard deferredUntilUnlock else { return } // 평소의 잠금 해제는 여전히 조용하다 (US-009 AC-3)
        // 같은 디바운스로 재진입한다 — 해제 직후 macOS가 창을 재배치할 시간을 준다.
        screenParametersChanged()
    }

    private func stabilized() {
        let current = Set(provider.screens().filter { !$0.isBuiltin }.map(\.id))
        let added = current.subtracting(knownExternalIDs)
        let removed = knownExternalIDs.subtracting(current)
        knownExternalIDs = current // 제거·복귀도 기준선에 반영 — 다음 비교의 기준 (F-01.3)
        // 제거는 잠자기 억제를 타지 않는다. 억제는 "해제 직후의 가짜 등장"을 막는 규칙이고,
        // 해제 시점에 화면이 진짜로 빠져 있으면 그건 진짜 제거다. 순서도 제거가 먼저다 —
        // 화면을 바꿔 끼우면 확정이 재복원보다 앞서야 직전 배치를 잃지 않는다.
        if !removed.isEmpty { onExternalScreensRemoved(removed) }
        if current.isEmpty { deferredUntilUnlock = false } // 잠금 중에 도로 뽑았다 — 미룰 것이 없다

        let deferred = deferredUntilUnlock
        guard !added.isEmpty || deferred else { return }
        // 잠금 판정이 억제 판정보다 위다. 덮개를 열며 꽂는 흐름은 연결이 곧 잠자기 해제라
        // 아래 억제에 걸리는데, 그 회차를 버리면 added가 비어 다시 발화할 길이 없다.
        guard !isLocked() else { deferredUntilUnlock = true; return }
        // 미뤄둔 회차는 억제를 타지 않는다 — Touch ID로 억제 창 안에 풀면 두 번 삼켜진다.
        guard deferred || Date() >= suppressUntil else { return }
        deferredUntilUnlock = false
        onExternalScreensAppeared()
    }
}
