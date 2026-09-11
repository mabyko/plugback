import AppKit
import ApplicationServices
import Foundation

/// 언제 수집이 돌아야 하는지를 답하는 모듈 (F-08.3). 자동 저장 OFF에서도 창 연결·닫힘 판정을 위해 돈다.
///
/// 신호원은 **창 이동**과 **앱 전환**이다. Mission Control 닫힘은 안내형 복원과
/// 순서를 공유하므로 컨트롤러가 watcher 하나를 소유한다.
@MainActor
public final class CollectTrigger {
    private let moveSource: WindowMoveSource?
    private let activity: ActivityWatcher
    /// 창 이동 경로가 쓰는 참조. ActivityWatcher도 같은 클로저를 들지만 둘 다 불변이라 어긋날 수 없다 —
    /// 하나로 합치려면 ActivityWatcher의 콜백을 var로 열어야 해서, 그 대가가 이 중복보다 크다.
    private let onCollect: () -> Void
    private var started = false

    /// 최소 간격은 앱 전환 쪽에만 걸린다. 창 이동은 이동이 끝날 때 1회만 오므로
    /// 스로틀이 필요 없고, 걸면 사용자가 옮긴 마지막 배치를 놓친다.
    public init(moveSource: WindowMoveSource?,
                minimumInterval: TimeInterval = 10,
                onTerminating: @escaping () -> Void = {},
                onAppTerminated: @escaping (String) -> Void = { _ in },
                onCollect: @escaping () -> Void) {
        self.moveSource = moveSource
        self.onCollect = onCollect
        self.activity = ActivityWatcher(minimumInterval: minimumInterval,
                                        onTerminating: onTerminating,
                                        onAppTerminated: onAppTerminated,
                                        onCollect: onCollect)
    }

    /// 앱 종료를 알림 없이 주입한다 — 테스트용.
    func appTerminated(_ bundleID: String) { activity.appTerminated(bundleID) }

    /// 앱 전환 구독을 시작한다. 창 이동은 대상이 정해져야 하므로 `retarget`이 켠다.
    public func start() {
        guard !started else { return }
        started = true
        activity.start()
    }

    /// 두 신호원을 모두 끊는다. 꺼진 기능이 알림을 받고 있으면 "꺼짐"이 아니다.
    public func stop() async {
        started = false
        activity.stop()
        await moveSource?.observeWindowMoves(of: [], onSettled: {})
    }

    /// 창 이동을 관찰할 대상 앱을 지금 상태에 맞춘다. 멱등이다 — 등록 차이만 반영된다.
    /// 빈 목록이면 이동 관찰만 해제되고 앱 전환 구독은 남는다.
    public func retarget(_ bundleIDs: [String]) async {
        guard started else { return }
        await moveSource?.observeWindowMoves(of: bundleIDs) { [weak self] in
            Task { @MainActor in self?.onCollect() }
        }
    }
}

/// Dock의 Mission Control AX tree가 사라지는 순간만 한 번의 desktop 변화로 압축한다.
/// 비활성 Space의 화면 간 drag는 Workspace Space/app 알림을 내지 않으므로 이 신호가 필요하다.
@MainActor
final class MissionControlWatcher {
    private let settleDelay: TimeInterval
    private let onClosed: () -> Void
    private var observer: AXObserver?
    private var dockApplication: AXUIElement?
    private var wasOpen = false
    private var pending: DispatchWorkItem?

    init(settleDelay: TimeInterval = 0.5, onClosed: @escaping () -> Void) {
        self.settleDelay = settleDelay
        self.onClosed = onClosed
    }

    func start() {
        guard observer == nil, AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == "com.apple.dock"
              })?.processIdentifier else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, missionControlAXCallback, &created) == .success,
              let created else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXSelectedChildrenChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
        ]
        var added: [CFString] = []
        for notification in notifications where AXObserverAddNotification(
            created, application, notification, context
        ) == .success {
            added.append(notification)
        }
        guard added.count == notifications.count else {
            for notification in added {
                AXObserverRemoveNotification(created, application, notification)
            }
            return
        }

        observer = created
        dockApplication = application
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode
        )
    }

    func stop() {
        pending?.cancel()
        pending = nil
        wasOpen = false
        guard let observer, let dockApplication else { return }
        for notification in [
            kAXSelectedChildrenChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
        ] {
            AXObserverRemoveNotification(observer, dockApplication, notification)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
        )
        self.observer = nil
        self.dockApplication = nil
    }

    fileprivate func treeChanged() {
        guard let dockApplication else { return }
        treeChanged(isOpen: firstDescendant(of: dockApplication, identifier: "mc") != nil)
    }

    /// internal test seam — AXObserver를 만들지 않고 open→closed 압축만 검증한다.
    func treeChanged(isOpen: Bool) {
        if isOpen {
            pending?.cancel()
            pending = nil
            wasOpen = true
            return
        }
        guard wasOpen else { return }
        wasOpen = false
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onClosed() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: item)
    }

    private func firstDescendant(
        of element: AXUIElement, identifier: String, depth: Int = 0
    ) -> AXUIElement? {
        guard depth <= 12 else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, "AXIdentifier" as CFString, &value
        ) == .success, value as? String == identifier {
            return element
        }
        value = nil
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        ) == .success, let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let found = firstDescendant(
                of: child, identifier: identifier, depth: depth + 1
            ) { return found }
        }
        return nil
    }
}

private func missionControlAXCallback(
    _ observer: AXObserver, _ element: AXUIElement,
    _ notification: CFString, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let watcher = Unmanaged<MissionControlWatcher>
        .fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in watcher.treeChanged() }
}
