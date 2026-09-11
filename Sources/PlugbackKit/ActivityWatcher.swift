import AppKit

/// 수집 신호원 중 하나 — 앱 전환 알림을 "수집할 시점"으로 압축한다 (CollectTrigger의 구현 세부).
///
/// 순수 이벤트 구독이다 — 주기 타이머가 아니라 **사용자가 앱을 바꿀 때만** 온다.
/// 앱 전환은 하루에 수백 번이므로 최소 간격으로 솎아낸다 — 그 간격이 곧 저장 대기 이력의 오차 상한이다.
///
/// **비활성화도 함께 구독한다.** 활성화는 상호작용의 *시작*에 오므로, 그 순간의 배치는
/// 사용자가 창을 옮기기 *전*의 것이다. 앱에서 빠져나오는 순간이 그 앱 창의 최종 상태다.
/// (2026-08-18 실기기: 활성화만 구독했더니 확정된 후보가 씨앗과 좌표가 같았다.)
///
/// 앱 종료 알림은 번들 식별자와 함께 전한다 — 그 앱의 살아 있던 창 연결이 지금 환경에서 끝났다는 뜻이다 (D9).
/// Plugback 자신의 종료 알림도 받는다. 후보는 메모리에만 살기 때문에 종료는 확정할 마지막 기회다.
@MainActor
final class ActivityWatcher {
    private let minimumInterval: TimeInterval
    private let onCollect: () -> Void
    private let onTerminating: () -> Void
    private let onAppTerminated: (String) -> Void

    private var lastFired = Date.distantPast
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// 최소 간격은 실기기 측정 후 조정하는 보정 노브다 — 짧을수록 정확하고 길수록 조용하다.
    init(minimumInterval: TimeInterval = 10,
         onTerminating: @escaping () -> Void = {},
         onAppTerminated: @escaping (String) -> Void = { _ in },
         onCollect: @escaping () -> Void) {
        self.minimumInterval = minimumInterval
        self.onTerminating = onTerminating
        self.onAppTerminated = onAppTerminated
        self.onCollect = onCollect
    }

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.appActivated() }
            }))
        }
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor in
                if let bundleID { self?.appTerminated(bundleID) }
            }
        }))
        // 종료는 동기로 받는다 — Task로 미루면 프로세스가 먼저 죽어 확정이 유실된다.
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTerminating() }
        }))
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    // internal — 테스트가 알림 없이 직접 주입한다 (DisplayWatcher와 같은 방식).
    func appActivated() {
        let now = Date()
        guard now.timeIntervalSince(lastFired) >= minimumInterval else { return }
        lastFired = now
        onCollect()
    }

    func appTerminated(_ bundleID: String) { onAppTerminated(bundleID) }
}
