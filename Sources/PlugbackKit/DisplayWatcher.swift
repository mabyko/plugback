import AppKit

/// 원시 화면 이벤트 3~6회를 의미 있는 이벤트 1회로 압축한다 (F-01.2, F-01.3).
/// US-009(창 튐 방지)는 전부 이 모듈 안에서 결판난다.
///
/// - 이벤트 안정화: 마지막 이벤트 후 일정 시간 추가 이벤트가 없을 때만 판정한다 (trailing 디바운스).
/// - 위상 게이트: 직전 외장 화면 식별자 집합과 비교해 **새 식별자가 추가된 경우에만** 등장 콜백한다.
///   잠자기 해제·덮개 여닫기·잠금 해제·해상도 변경은 집합이 변하지 않으므로 조용히 지나간다.
/// - 잠자기 억제: 해제 직후 일정 시간은 추가가 보여도 콜백하지 않는다. 기준선은 계속 갱신한다.
/// - 잠금 미루기: 잠긴 상태에서 온 등장은 **어느 화면인지 기억한 채** 들고 있다가 잠금 해제 때 한 번 소비한다.
///   미뤄둔 화면이 그사이 빠지면 미룰 것도 사라진다. 변경 신호를 받은 시점의 잠금도 기억해,
///   안정화 전에 풀린 잠금 때문에 잠자기 억제에 삼켜지지 않는다 (2026-09-11 재현 검사).
@MainActor
public final class DisplayWatcher {
    private let provider: ScreenProvider
    private let debounceInterval: TimeInterval
    private let wakeSuppressionInterval: TimeInterval
    private let onExternalScreensAppeared: () -> Void
    private let onExternalScreensRemoved: (Set<String>) -> Void
    /// 원시 화면 변경 신호 — 안정화 전부터 수집을 멈추고 이전 작업 환경 이력을 보존하기 위해 (4.3절).
    private let onRawChange: () -> Void
    /// 잠금 해제 확인 — 보류한 복원 작업의 재개 신호 (D8).
    private let onScreenUnlocked: () -> Void
    private let isLocked: () -> Bool

    private var knownExternalIDs: Set<String>
    /// 잠금 중이라 미뤄둔 등장의 화면 식별자들. 잠금 해제 때 아직 연결된 것만 소비한다.
    private var deferredIDs: Set<String> = []
    /// 마지막 변경 신호가 잠긴 상태에서 왔다 — 안정화 판정에서 잠자기 억제보다 앞선다.
    private var changeArrivedWhileLocked = false
    private var pending: DispatchWorkItem?
    private var suppressUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    /// 안정화 대기 중 — 수집·저장은 이 동안 이전 환경의 마지막 유효 상태를 보존한다.
    public private(set) var isSettling = false

    /// 시간 상수는 실기기 측정 후 조정할 수 있는 초기값이다 (FUNCTIONAL_SPEC 서문).
    public init(provider: ScreenProvider,
                debounceInterval: TimeInterval = 1.5,
                wakeSuppressionInterval: TimeInterval = 2.5,
                isLocked: @escaping () -> Bool = { ScreenLock.current() == .locked },
                onExternalScreensRemoved: @escaping (Set<String>) -> Void = { _ in },
                onRawChange: @escaping () -> Void = {},
                onScreenUnlocked: @escaping () -> Void = {},
                onExternalScreensAppeared: @escaping () -> Void) {
        self.provider = provider
        self.debounceInterval = debounceInterval
        self.wakeSuppressionInterval = wakeSuppressionInterval
        self.isLocked = isLocked
        self.onExternalScreensRemoved = onExternalScreensRemoved
        self.onRawChange = onRawChange
        self.onScreenUnlocked = onScreenUnlocked
        self.onExternalScreensAppeared = onExternalScreensAppeared
        knownExternalIDs = Set(provider.screens().filter { !$0.isBuiltin }.map(\.id))
    }

    /// 순수 이벤트 구독만 사용한다 — 상시 폴링·주기 타이머 없음 (F-07).
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

    /// 비공식 세션 키의 잠금 판정 — 판정 불가는 잠금으로 보지 않는다. 판정 불가 시의 보류는 컨트롤러의 실행 게이트가 맡는다.
    public nonisolated static func screenIsLocked() -> Bool { ScreenLock.current() == .locked }

    // internal — 테스트가 알림 없이 직접 주입한다.
    func screenParametersChanged() {
        if !isSettling { onRawChange() }
        isSettling = true
        if isLocked() { changeArrivedWhileLocked = true }
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
        onScreenUnlocked()
        guard !deferredIDs.isEmpty else { return } // 평소의 잠금 해제는 여전히 조용하다 (US-009 AC-3)
        // 같은 디바운스로 재진입한다 — 해제 직후 macOS가 창을 재배치할 시간을 준다.
        screenParametersChanged()
    }

    private func stabilized() {
        isSettling = false
        let current = Set(provider.screens().filter { !$0.isBuiltin }.map(\.id))
        let added = current.subtracting(knownExternalIDs)
        let removed = knownExternalIDs.subtracting(current)
        knownExternalIDs = current // 제거·복귀도 기준선에 반영 — 다음 비교의 기준 (F-01.3)
        let arrivedLocked = changeArrivedWhileLocked
        changeArrivedWhileLocked = false
        // 제거는 잠자기 억제를 타지 않는다. 순서도 제거가 먼저다 —
        // 화면을 바꿔 끼우면 확정이 재복원보다 앞서야 직전 배치를 잃지 않는다.
        if !removed.isEmpty { onExternalScreensRemoved(removed) }
        deferredIDs = deferredIDs.intersection(current) // 잠금 중에 도로 뽑은 화면은 미룰 것이 없다

        let pendingIDs = added.union(deferredIDs)
        guard !pendingIDs.isEmpty else { return }
        // 잠금 판정이 억제 판정보다 위다. 덮개를 열며 꽂는 흐름은 연결이 곧 잠자기 해제라
        // 아래 억제에 걸리는데, 그 회차를 버리면 added가 비어 다시 발화할 길이 없다.
        guard !isLocked() else { deferredIDs = pendingIDs; return }
        // 미뤄둔 회차와 잠긴 채 도착한 변경은 억제를 타지 않는다 — Touch ID로 억제 창 안에 풀면 두 번 삼켜진다.
        guard !deferredIDs.isEmpty || arrivedLocked || Date() >= suppressUntil else { return }
        deferredIDs = []
        onExternalScreensAppeared()
    }
}
