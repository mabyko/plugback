import AppKit
import ApplicationServices

/// 실물 어댑터 — 접근성 API 전체를 여기 가둔다 (docs/ARCHITECTURE.md의 유일한 AX 접점).
/// AX 좌표계는 이미 좌상단 원점 전역이므로 창 프레임은 무변환으로 흐른다.
///
/// actor다: AX 왕복(호출당 250ms 응답 한도)은 이 actor의 직렬 실행기에서 돌고,
/// 메인 액터는 막히지 않는다 (F-02.4). NSWorkspace 접근만 메인으로 홉한다.
public actor AXWindowGateway: WindowGateway, WindowMoveSource {
    private var refs: [Int: AXUIElement] = [:]
    private var nextID = 1
    /// openWindow가 창 등장을 기다리는 한도. 무거운 앱의 실측에 맞춰 조정하는 보정 노브.
    private let windowWaitDeadline: TimeInterval
    /// 창 목록 조회가 한도를 넘겼을 때 한 번만 쓰는 재시도 한도 (F-02.4의 250ms는 평시 한도다).
    /// 화면 재구성 순간의 앱은 느리다 — 실기기 측정 후 조정하는 보정 노브다.
    private let retryTimeout: TimeInterval

    public init(windowWaitDeadline: TimeInterval = 3.0, retryTimeout: TimeInterval = 1.0) {
        self.windowWaitDeadline = windowWaitDeadline
        self.retryTimeout = retryTimeout
    }

    public func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] {
        // ID 수명 계약: 마지막 열거만 유효 — 이전 열거의 참조를 비워 죽은 ID가
        // 조용히 성공하는 것을 막고, 장기 실행 시 refs의 무한 증식도 막는다.
        refs.removeAll()
        // 앱 목록은 NSWorkspace(메인)에서 한 번에 — AX 순회는 actor 실행기에서
        let apps: [(pid: pid_t, bundleID: String, name: String)] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
                if let ids = bundleIDs, !ids.contains(id) { return nil }
                return (app.processIdentifier, id, app.localizedName ?? id)
            }
        }

        var result: [WindowInfo] = []
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            // 앱 하나가 응답하지 않아도 멈추는 시간의 한도 (F-02.4, 초기값 250ms)
            AXUIElementSetMessagingTimeout(appElement, 0.25)

            // 열거 실패는 "창 없음"이 아니다 — 화면 재구성 직후 실제로 한도를 넘긴다(실측 2026-08-18).
            // 여기서 조용히 넘기면 창이 멀쩡한 앱이 "창이 없어 건너뜀"으로 보고된다. 한 번은 넉넉히 다시 묻는다.
            var windows: [AXUIElement]? = copy(appElement, kAXWindowsAttribute)
            if windows == nil {
                AXUIElementSetMessagingTimeout(appElement, Float(retryTimeout))
                windows = copy(appElement, kAXWindowsAttribute)
            }
            guard let windows else { continue }
            for element in windows {
                // 타임아웃은 요소별이다 — 창 요소에도 걸어야 move()·재검증이 기본값(수 초)을 타지 않는다
                AXUIElementSetMessagingTimeout(element, 0.25)
                guard let subrole: String = copy(element, kAXSubroleAttribute),
                      subrole == kAXStandardWindowSubrole as String,
                      let frame = frame(of: element) else { continue }
                let minimized: Bool = copy(element, kAXMinimizedAttribute) ?? false
                let fullscreen: Bool = copy(element, "AXFullScreen") ?? false

                let id = nextID
                nextID += 1
                refs[id] = element
                result.append(WindowInfo(id: id, appBundleID: app.bundleID,
                                         appName: app.name,
                                         frame: frame, isFullscreen: fullscreen, isMinimized: minimized))
            }
        }
        return result
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
        // 성공 반환값을 믿지 않는다 — 최소화 상태와 프레임을 실제로 다시 읽는다 (F-02.3과 같은 처방).
        // 수락한 척 최소화를 유지하는 앱이면 nil — 보이지 않는 창을 옮기고 .moved로 보고하지 않는다.
        let stillMinimized: Bool = copy(element, kAXMinimizedAttribute) ?? false
        guard !stillMinimized else { return nil }
        return frame(of: element)
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
            // 완료 핸들러 판을 명시 — async 판은 실패를 던지지만, 성공 여부는 어차피 폴링이 판정한다
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return true
        }
        guard opened else { return false }

        // 창 등장 폴링 — 빠른 앱은 첫 확인에서 끝나고, 늦는 앱도 한도까지 잡는다.
        // 이벤트에 반응해 시작되는 유한 대기라 F-07이 허용한다.
        let deadline = Date().addingTimeInterval(windowWaitDeadline)
        repeat {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await standardWindows(of: [bundleID]).isEmpty == false { return true }
        } while Date() < deadline
        return false
    }

    // MARK: - 창 이동 관찰 (실험실 · 자동 슬롯)

    // ponytail: 앱에 게이트웨이는 하나뿐이라 관찰자도 하나로 둔다.
    // 인스턴스 프로퍼티로 두면 actor(비메인)가 MainActor 객체를 들게 되고, 그 격리를 푸는 값이 없다.
    @MainActor private static let moveObserver = WindowMoveObserver()

    public func observeWindowMoves(of bundleIDs: [String], onSettled: @escaping @Sendable () -> Void) async {
        // pid로 등록한다 — AX 옵저버는 프로세스 단위다. 앱 목록 조회는 NSWorkspace(메인)의 일이다.
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
}
