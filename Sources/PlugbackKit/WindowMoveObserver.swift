import AppKit
import ApplicationServices

/// 창 이동·크기 변경 알림의 노이즈를 "정착했다" 1회로 압축하고, 원시 알림의 창 요소는 그대로 전달한다.
/// DisplayWatcher가 연결 이벤트에 하는 것과 같은 처방 — 원시 이벤트 폭주를 의미 있는 1회로.
///
/// AX 옵저버는 실행 루프에 붙으므로 메인에서 산다. AXWindowGateway가 소유하며,
/// 다른 앱의 AX를 만지는 것은 여전히 게이트웨이 안뿐이다 (docs/ARCHITECTURE.md).
///
/// 알림은 **앱 요소**에 건다 — 그 앱의 모든 창을 덮고, 등록 뒤에 열린 창도 포함된다.
/// Chrome 실측(2026-09-11)에서는 마우스 버튼을 누른 동안에도 같은 창의 이동 알림이 반복해서 왔다 —
/// 「이동이 끝날 때 1회」를 모든 앱에 전제하지 않는다.
@MainActor
final class WindowMoveObserver {
    /// 창이 정착했다고 볼 때까지의 대기. 실기기 측정 후 조정하는 보정 노브다.
    private let settleInterval: TimeInterval
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?
    private var onSettled: (@Sendable () -> Void)?
    /// 원시 알림마다 창 요소로 부른다 — 사용자 조작 보호가 쓴다. 등록 대상 앱의 창만 온다.
    var onWindowMoved: ((AXUIElement) -> Void)?

    init(settleInterval: TimeInterval = 0.3) {
        self.settleInterval = settleInterval
    }

    /// 관찰 대상을 이 pid 집합으로 맞춘다. 멱등 — 이미 등록된 것은 그대로 두고 차이만 반영한다.
    /// 빈 집합이면 전부 해제한다.
    func observe(pids: [pid_t], onSettled: @escaping @Sendable () -> Void) {
        self.onSettled = onSettled
        let wanted = Set(pids)

        for (pid, observer) in observers where !wanted.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers.removeValue(forKey: pid)
        }
        for pid in wanted where observers[pid] == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, windowMoveCallback, &created) == .success,
                  let observer = created else { continue } // 권한 없음·죽은 프로세스 — 조용히 건너뛴다
            let app = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverAddNotification(observer, app, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
        if wanted.isEmpty { pending?.cancel(); pending = nil }
    }

    // internal — 테스트가 AX 없이 직접 주입한다 (DisplayWatcher와 같은 방식).
    func windowMoved(_ element: AXUIElement? = nil) {
        if let element { onWindowMoved?(element) }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pending = nil
                self.onSettled?()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + settleInterval, execute: item)
    }
}

/// AX 콜백은 C 함수 포인터라 컨텍스트를 못 잡는다 — refcon으로 관찰자를 되찾는다.
/// 실행 루프 소스를 메인에 붙였으므로 이 호출은 메인에서 온다.
private func windowMoveCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let target = Unmanaged<WindowMoveObserver>.fromOpaque(refcon).takeUnretainedValue()
    nonisolated(unsafe) let moved = element // 실행 루프 소스가 메인에 있어 이 호출은 메인에서 온다
    MainActor.assumeIsolated { target.windowMoved(moved) }
}
