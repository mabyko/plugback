import AppKit

/// 자동 슬롯의 수집 트리거 (실험실). 앱 전환 알림을 "수집할 시점"으로 압축한다.
///
/// 순수 이벤트 구독이다 — 주기 타이머가 아니라 **사용자가 앱을 바꿀 때만** 온다.
/// 자리를 비우면 아무 일도 일어나지 않으므로 F-07(유휴 시 CPU를 쓰지 않는다)의 취지를 깨지 않는다.
/// 앱 전환은 하루에 수백 번이므로 최소 간격으로 솎아낸다 — 그 간격이 곧 자동 슬롯의 오차 상한이다.
///
/// 종료 알림도 같이 받는다. 후보는 메모리에만 살기 때문에, 화면을 뽑기 전에 앱을 끄면
/// 그 세션의 배치가 통째로 사라진다. 종료는 확정할 마지막 기회다.
@MainActor
public final class ActivityWatcher {
    private let minimumInterval: TimeInterval
    private let onCollect: () -> Void
    private let onTerminating: () -> Void

    private var lastFired = Date.distantPast
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// 최소 간격은 실기기 측정 후 조정하는 보정 노브다 — 짧을수록 정확하고 길수록 조용하다.
    /// 열거 비용이 앱당 최대 1.25초(250ms + 재시도 1초)이므로 짧게 잡으려면 먼저 실측해야 한다.
    public init(minimumInterval: TimeInterval = 30,
                onTerminating: @escaping () -> Void = {},
                onCollect: @escaping () -> Void) {
        self.minimumInterval = minimumInterval
        self.onTerminating = onTerminating
        self.onCollect = onCollect
    }

    public func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appActivated() }
        }))
        // 종료는 동기로 받는다 — Task로 미루면 프로세스가 먼저 죽어 확정이 유실된다.
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTerminating() }
        }))
    }

    /// 실험실을 끄면 구독을 끊는다 — 꺼진 기능이 알림을 받고 있으면 "꺼짐"이 아니다.
    public func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    // ponytail: deinit 해제는 두지 않는다. 해제 경로는 stop() 하나뿐이고
    // (컨트롤러가 실험실을 끌 때 반드시 부른다), 콜백이 weak self라 살아남은 구독도 무해하다.

    // internal — 테스트가 알림 없이 직접 주입한다 (DisplayWatcher와 같은 방식).
    func appActivated() {
        let now = Date()
        guard now.timeIntervalSince(lastFired) >= minimumInterval else { return }
        lastFired = now
        onCollect()
    }
}
