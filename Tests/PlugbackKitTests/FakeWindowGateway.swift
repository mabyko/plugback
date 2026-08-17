import CoreGraphics
@testable import PlugbackKit

/// 테스트용 페이크 — 이 심 하나로 두 엔진의 정책 전부를 실기기 없이 검증한다 (docs/ARCHITECTURE.md).
final class FakeWindowGateway: WindowGateway {
    enum MoveBehavior {
        case honest                      // 요청대로 이동
        case clampWidth(min: CGFloat)    // 앱 최소 크기 제약 흉내 (US-008 AC-3)
        case silentFail                  // 전체화면처럼 조용히 실패 — 원래 프레임 유지
        case unresponsive                // 응답 없음
    }

    var windowsList: [WindowInfo] = []
    var runningBundleIDs: Set<String> = []
    var moveBehavior: MoveBehavior = .honest
    var perWindowBehavior: [Int: MoveBehavior] = [:]
    private(set) var moveCalls: [(windowID: Int, target: CGRect)] = []

    func standardWindows(of bundleIDs: [String]?) -> [WindowInfo] {
        windowsList.filter { window in
            runningBundleIDs.contains(window.appBundleID)
                && (bundleIDs == nil || bundleIDs!.contains(window.appBundleID))
        }
    }

    func move(windowID: Int, to frame: CGRect) -> CGRect? {
        moveCalls.append((windowID, frame))
        switch perWindowBehavior[windowID] ?? moveBehavior {
        case .honest:
            if let i = windowsList.firstIndex(where: { $0.id == windowID }) {
                let old = windowsList[i]
                windowsList[i] = WindowInfo(id: old.id, appBundleID: old.appBundleID, appName: old.appName,
                                            frame: frame, isFullscreen: old.isFullscreen, isMinimized: old.isMinimized)
            }
            return frame
        case .clampWidth(let minWidth):
            var f = frame
            f.size.width = max(f.width, minWidth)
            return f
        case .silentFail:
            return windowsList.first { $0.id == windowID }?.frame
        case .unresponsive:
            return nil
        }
    }

    func isRunning(bundleID: String) -> Bool { runningBundleIDs.contains(bundleID) }

    /// openWindow 시 이 창이 나타난다 — 실제 앱이 새 창을 여는 것을 흉내낸다.
    /// 등록이 없으면 false — 한도까지 창이 안 뜬 앱과 같다. 페이크는 기다리지 않는다.
    var windowOnReopen: [String: WindowInfo] = [:]
    private(set) var openWindowCalls: [String] = []

    func openWindow(bundleID: String) async -> Bool {
        openWindowCalls.append(bundleID)
        guard let window = windowOnReopen[bundleID] else { return false }
        windowsList.append(window)
        return true
    }

    func unminimize(windowID: Int) -> Bool {
        guard let i = windowsList.firstIndex(where: { $0.id == windowID }) else { return false }
        let old = windowsList[i]
        windowsList[i] = WindowInfo(id: old.id, appBundleID: old.appBundleID, appName: old.appName,
                                    frame: old.frame, isFullscreen: old.isFullscreen, isMinimized: false)
        return true
    }
}

final class FakeScreenProvider: ScreenProvider {
    var screensList: [ScreenInfo] = []
    func screens() -> [ScreenInfo] { screensList }
}
