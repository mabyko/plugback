import AppKit
import ApplicationServices

/// 실물 어댑터 — 접근성 API 전체를 여기 가둔다 (docs/ARCHITECTURE.md의 유일한 AX 접점).
/// AX 좌표계는 이미 좌상단 원점 전역이므로 창 프레임은 무변환으로 흐른다.
public final class AXWindowGateway: WindowGateway {
    private var refs: [Int: AXUIElement] = [:]
    private var nextID = 1
    /// openWindow가 창 등장을 기다리는 한도. 무거운 앱의 실측에 맞춰 조정하는 보정 노브.
    private let windowWaitDeadline: TimeInterval

    public init(windowWaitDeadline: TimeInterval = 3.0) {
        self.windowWaitDeadline = windowWaitDeadline
    }

    public func standardWindows(of bundleIDs: [String]?) -> [WindowInfo] {
        // ID 수명 계약: 마지막 열거만 유효 — 이전 열거의 참조를 비워 죽은 ID가
        // 조용히 성공하는 것을 막고, 장기 실행 시 refs의 무한 증식도 막는다.
        refs.removeAll()
        var result: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            if let ids = bundleIDs, !ids.contains(bundleID) { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            // 앱 하나가 응답하지 않아도 멈추는 시간의 한도 (F-02.4, 초기값 250ms)
            AXUIElementSetMessagingTimeout(appElement, 0.25)

            guard let windows: [AXUIElement] = copy(appElement, kAXWindowsAttribute) else { continue }
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
                result.append(WindowInfo(id: id, appBundleID: bundleID,
                                         appName: app.localizedName ?? bundleID,
                                         frame: frame, isFullscreen: fullscreen, isMinimized: minimized))
            }
        }
        return result
    }

    public func move(windowID: Int, to target: CGRect) -> CGRect? {
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

    public func unminimize(windowID: Int) -> CGRect? {
        guard let element = refs[windowID],
              AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        else { return nil }
        // 성공 반환값을 믿지 않는다 — 최소화 상태와 프레임을 실제로 다시 읽는다 (F-02.3과 같은 처방).
        // 수락한 척 최소화를 유지하는 앱이면 nil — 보이지 않는 창을 옮기고 .moved로 보고하지 않는다.
        let stillMinimized: Bool = copy(element, kAXMinimizedAttribute) ?? false
        guard !stillMinimized else { return nil }
        return frame(of: element)
    }

    @MainActor
    public func openWindow(bundleID: String) async -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
        }), let url = app.bundleURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false // 창만 열게 한다 — 포커스는 훔치지 않는다
        // 완료 핸들러 판을 명시 — async 판은 실패를 던지지만, 성공 여부는 어차피 폴링이 판정한다
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)

        // 창 등장 폴링 — 빠른 앱은 첫 확인에서 끝나고, 늦는 앱도 한도까지 잡는다.
        // await sleep이라 메인 스레드를 막지 않는다.
        let deadline = Date().addingTimeInterval(windowWaitDeadline)
        repeat {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !standardWindows(of: [bundleID]).isEmpty { return true }
        } while Date() < deadline
        return false
    }

    public func isRunning(bundleID: String) -> Bool {
        // 창 열거와 같은 집합(.regular)만 본다 — 액세서리 앱이 "창 없음"으로 오분류되지 않게
        NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
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
