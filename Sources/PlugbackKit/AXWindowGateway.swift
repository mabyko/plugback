import AppKit
import ApplicationServices
import Darwin

private typealias AXUIElementGetWindowFunction = @convention(c) (
    AXUIElement, UnsafeMutablePointer<CGWindowID>
) -> AXError

/// 실물 어댑터 — 접근성 API 전체를 여기 가둔다 (docs/ARCHITECTURE.md의 유일한 AX 접점).
/// AX 좌표계는 이미 좌상단 원점 전역이므로 창 프레임은 무변환으로 흐른다.
///
/// actor다: AX 왕복(호출당 250ms 응답 한도)은 이 actor의 직렬 실행기에서 돌고,
/// 메인 액터는 막히지 않는다 (F-02.4). NSWorkspace 접근만 메인으로 홉한다.
public actor AXWindowGateway: WindowGateway, WindowMoveSource {
    private var refs: [Int: AXUIElement] = [:]
    private var nextID = 1
    private var lastEnumerationFailures: Set<String> = []
    /// openWindow·launch가 창 등장을 기다리는 한도. 무거운 앱의 실측에 맞춰 조정하는 보정 노브.
    private let windowWaitDeadline: TimeInterval
    /// 창 목록 조회가 한도를 넘겼을 때 한 번만 쓰는 재시도 한도 (F-02.4의 250ms는 평시 한도다).
    private let retryTimeout: TimeInterval
    private let axWindowID: AXUIElementGetWindowFunction?

    public init(windowWaitDeadline: TimeInterval = 3.0, retryTimeout: TimeInterval = 1.0) {
        self.windowWaitDeadline = windowWaitDeadline
        self.retryTimeout = retryTimeout
        let applicationServices = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
            RTLD_LAZY | RTLD_LOCAL
        )
        let hiServices = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/HIServices",
            RTLD_LAZY | RTLD_LOCAL
        )
        axWindowID = loadUndocumentedSymbol(
            from: [applicationServices, hiServices],
            named: "_AXUIElementGetWindow",
            as: AXUIElementGetWindowFunction.self
        )
    }

    public func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] {
        // ID 수명 계약: 마지막 열거만 유효 — 이전 열거의 참조를 비워 죽은 ID가
        // 조용히 성공하는 것을 막고, 장기 실행 시 refs의 무한 증식도 막는다.
        refs.removeAll()
        lastEnumerationFailures.removeAll()
        // 앱 목록은 NSWorkspace(메인)에서 한 번에 — AX 순회는 actor 실행기에서
        let apps: [(pid: pid_t, bundleID: String, name: String, hidden: Bool)] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
                if let ids = bundleIDs, !ids.contains(id) { return nil }
                return (app.processIdentifier, id, app.localizedName ?? id, app.isHidden)
            }
        }

        var result: [WindowInfo] = []
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            // 앱 하나가 응답하지 않아도 멈추는 시간의 한도 (F-02.4, 초기값 250ms)
            AXUIElementSetMessagingTimeout(appElement, 0.25)

            // 열거 실패는 "창 없음"이 아니다 — 화면 재구성 직후 실제로 한도를 넘긴다(실측 2026-08-18).
            var windows: [AXUIElement]? = copy(appElement, kAXWindowsAttribute)
            if windows == nil {
                AXUIElementSetMessagingTimeout(appElement, Float(retryTimeout))
                windows = copy(appElement, kAXWindowsAttribute)
            }
            guard let windows else {
                lastEnumerationFailures.insert(app.bundleID) // 조회 실패를 창 0개로 기록하지 않는다 (O07)
                continue
            }
            for element in windows {
                AXUIElementSetMessagingTimeout(element, 0.25)
                guard let subrole: String = copy(element, kAXSubroleAttribute),
                      subrole == kAXStandardWindowSubrole as String,
                      let frame = frame(of: element) else { continue }
                let minimized: Bool = copy(element, kAXMinimizedAttribute) ?? false
                let fullscreen = fullscreenState(of: element)
                var rawWindowID: CGWindowID = 0
                let windowServerID = axWindowID?(element, &rawWindowID) == .success
                    ? rawWindowID : nil
                let title: String? = copy(element, kAXTitleAttribute)

                let id = nextID
                nextID += 1
                refs[id] = element
                result.append(WindowInfo(id: id, appBundleID: app.bundleID,
                                         appName: app.name,
                                         frame: frame, fullscreenState: fullscreen,
                                         isMinimized: minimized, isHidden: app.hidden,
                                         windowServerID: windowServerID, title: title))
            }
        }
        return result
    }

    public func enumerationFailures() async -> Set<String> { lastEnumerationFailures }

    /// 공개 API — 모든 Space·최소화·숨김 창을 포함한 WindowServer 창 목록. 창 이름은 읽지 않는다.
    public func existingWindowServerIDs() async -> Set<CGWindowID>? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    public func move(windowID: Int, to target: CGRect) async -> CGRect? {
        guard let element = refs[windowID] else { return nil }
        var origin = target.origin
        var size = target.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return nil }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        // 성공 반환값을 믿지 않는다 — 실제 프레임을 다시 읽는다 (F-02.3, 부록 1)
        return frame(of: element)
    }

    public func unminimize(windowID: Int) async -> CGRect? {
        guard let element = refs[windowID],
              AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        else { return nil }
        let stillMinimized: Bool = copy(element, kAXMinimizedAttribute) ?? false
        guard !stillMinimized else { return nil }
        return frame(of: element)
    }

    public func raise(windowID: Int) async -> Bool {
        guard let element = refs[windowID] else { return false }
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    public func isRunning(bundleID: String) async -> Bool {
        // 창 열거와 같은 집합(.regular)만 본다 — 액세서리 앱이 "창 없음"으로 오분류되지 않게
        await MainActor.run {
            NSWorkspace.shared.runningApplications.contains {
                $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
            }
        }
    }

    public func openWindow(bundleID: String) async -> Bool {
        let opened = await MainActor.run { () -> Bool in
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
            }), let url = app.bundleURL else { return false }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false // 창만 열게 한다 — 포커스는 훔치지 않는다
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return true
        }
        guard opened else { return false }
        return await waitForWindows(of: bundleID, atLeast: 1)
    }

    public func launch(bundleID: String) async -> Bool {
        // 종료된 앱의 실행 (3.5절 「종료된 앱 다시 열기」). 실행 중이면 새 창 열기와 같다.
        let requested = await MainActor.run { () -> Bool in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return true
        }
        guard requested else { return false }
        return await waitForWindows(of: bundleID, atLeast: 1, deadline: windowWaitDeadline * 3)
    }

    public func openAdditionalWindow(bundleID: String) async -> Bool {
        // ponytail: 범용 「새 창」 API는 없다. 앱의 메뉴 막대에서 파일 > 새 창(New Window) 항목을 AX로 누른다 —
        // 앱마다 항목 이름·지원이 다르므로 실기기 검증 항목이다. 못 찾으면 false로 사유를 남긴다.
        let before = await standardWindows(of: [bundleID]).count
        let pid: pid_t? = await MainActor.run {
            NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
            }?.processIdentifier
        }
        guard let pid else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let menuBar: AXUIElement = copy(application, kAXMenuBarAttribute),
              let menus: [AXUIElement] = copy(menuBar, kAXChildrenAttribute) else { return false }
        let newWindowTitles = ["New Window", "새로운 윈도우", "새 윈도우", "새로운 창", "새 창"]
        var pressed = false
        search: for menu in menus.prefix(4) { // Apple·앱·파일 메뉴 안에서만 찾는다
            guard let items: [AXUIElement] = copy(menu, kAXChildrenAttribute) else { continue }
            for submenu in items {
                guard let entries: [AXUIElement] = copy(submenu, kAXChildrenAttribute) else { continue }
                for entry in entries {
                    guard let title: String = copy(entry, kAXTitleAttribute),
                          newWindowTitles.contains(where: { title.hasPrefix($0) }) else { continue }
                    guard AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success else { continue }
                    pressed = true
                    break search
                }
            }
        }
        guard pressed else { return false }
        return await waitForWindows(of: bundleID, atLeast: before + 1)
    }

    private func waitForWindows(of bundleID: String, atLeast count: Int, deadline: TimeInterval? = nil) async -> Bool {
        // 창 등장 폴링 — 이벤트에 반응해 시작되는 유한 대기라 F-07이 허용한다.
        let limit = Date().addingTimeInterval(deadline ?? windowWaitDeadline)
        repeat {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await standardWindows(of: [bundleID]).count >= count { return true }
        } while Date() < limit
        return false
    }

    // MARK: - 창 이동 관찰

    // ponytail: 앱에 게이트웨이는 하나뿐이라 관찰자도 하나로 둔다.
    @MainActor private static let moveObserver = WindowMoveObserver()

    public func observeWindowMoves(of bundleIDs: [String], onSettled: @escaping @Sendable () -> Void) async {
        await MainActor.run {
            let pids = bundleIDs.isEmpty ? [] : NSWorkspace.shared.runningApplications.compactMap {
                app -> pid_t? in
                guard app.activationPolicy == .regular,
                      let id = app.bundleIdentifier, bundleIDs.contains(id) else { return nil }
                return app.processIdentifier
            }
            Self.moveObserver.observe(pids: pids, onSettled: onSettled)
        }
    }

    public func observeWindowInteractions(_ onWindowMoved: @escaping @Sendable (CGWindowID) -> Void) async {
        let resolver = axWindowID
        await MainActor.run {
            Self.moveObserver.onWindowMoved = { element in
                guard let resolver else { return }
                var raw: CGWindowID = 0
                guard resolver(element, &raw) == .success else { return }
                onWindowMoved(raw)
            }
        }
    }

    // MARK: - AX helpers

    private func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: CFTypeRef = copy(element, kAXPositionAttribute),
              let sizeValue: CFTypeRef = copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func fullscreenState(of element: AXUIElement) -> WindowFullscreenState {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXFullScreen" as CFString, &value
        ) == .success, let fullscreen = value as? Bool else { return .unknown }
        return fullscreen ? .fullscreen : .windowed
    }
}
