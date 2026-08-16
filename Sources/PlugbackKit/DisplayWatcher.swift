import AppKit

/// 원시 화면 이벤트 3~6회를 의미 있는 이벤트 1회로 압축한다 (F-01.2, F-01.3).
/// US-009(창 튐 방지)는 전부 이 모듈 안에서 결판난다.
///
/// - 이벤트 안정화: 마지막 이벤트 후 일정 시간 추가 이벤트가 없을 때만 판정한다 (trailing 디바운스).
/// - 위상 게이트: 직전 외장 화면 식별자 집합과 비교해 **새 식별자가 추가된 경우에만** 콜백한다.
///   잠자기 해제·덮개 여닫기·잠금 해제·해상도 변경은 집합이 변하지 않으므로 조용히 지나간다.
/// - 잠자기 억제: 해제 직후 일정 시간은 추가가 보여도 콜백하지 않는다. 기준선은 계속 갱신한다.
@MainActor
public final class DisplayWatcher {
    private let provider: ScreenProvider
    private let debounceInterval: TimeInterval
    private let wakeSuppressionInterval: TimeInterval
    private let onExternalScreensAppeared: ([String]) -> Void

    private var knownExternalIDs: Set<String>
    private var pending: DispatchWorkItem?
    private var suppressUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    /// 시간 상수는 실기기 측정 후 조정할 수 있는 초기값이다 (FUNCTIONAL_SPEC 서문).
    public init(provider: ScreenProvider,
                debounceInterval: TimeInterval = 1.5,
                wakeSuppressionInterval: TimeInterval = 2.5,
                onExternalScreensAppeared: @escaping ([String]) -> Void) {
        self.provider = provider
        self.debounceInterval = debounceInterval
        self.wakeSuppressionInterval = wakeSuppressionInterval
        self.onExternalScreensAppeared = onExternalScreensAppeared
        knownExternalIDs = Set(provider.screens().filter { !$0.isBuiltin }.map(\.id))
    }

    /// 순수 이벤트 구독만 사용한다 — 폴링·타이머 없음 (F-07).
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
        // ponytail: 앱 수명과 같이 사는 객체라 구독 해제 경로는 만들지 않는다.
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

    private func stabilized() {
        let current = Set(provider.screens().filter { !$0.isBuiltin }.map(\.id))
        let added = current.subtracting(knownExternalIDs)
        knownExternalIDs = current // 제거·복귀도 기준선에 반영 — 다음 비교의 기준 (F-01.3)
        guard !added.isEmpty, Date() >= suppressUntil else { return }
        onExternalScreensAppeared(added.sorted())
    }
}
