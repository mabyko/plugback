import CoreGraphics
import Foundation
@testable import PlugbackKit

/// 테스트용 페이크 — 이 심 하나로 두 엔진의 정책 전부를 실기기 없이 검증한다 (docs/ARCHITECTURE.md).
/// @MainActor: 테스트(전부 @MainActor)가 상태를 동기로 만지게 — 격리는 심의 Sendable 요구를 충족한다.
@MainActor
final class FakeWindowGateway: WindowGateway, WindowMoveSource {
    enum MoveBehavior {
        case honest                      // 요청대로 이동
        case clampWidth(min: CGFloat)    // 앱 최소 크기 제약 흉내 (US-008 AC-3)
        case silentFail                  // 전체화면처럼 조용히 실패 — 원래 프레임 유지
        case unresponsive                // 응답 없음
    }

    var windowsList: [WindowInfo] = []
    var runningBundleIDs: Set<String> = []
    /// 열거 횟수 — "복원 중엔 재열거하지 않는다" 계약의 관측 지점.
    private(set) var standardWindowsCalls = 0
    var standardWindowsDelay: TimeInterval = 0
    private(set) var standardWindowsHighWater = 0
    private var standardWindowsInFlight = 0
    var moveBehavior: MoveBehavior = .honest
    var perWindowBehavior: [Int: MoveBehavior] = [:]
    private(set) var moveCalls: [(windowID: Int, target: CGRect)] = []
    private(set) var standardWindowsCallsAtMove: [Int] = []
    var fullscreenSucceeds = true
    private(set) var fullscreenCalls: [(windowID: Int, fullscreen: Bool)] = []

    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] {
        standardWindowsCalls += 1
        standardWindowsInFlight += 1
        standardWindowsHighWater = max(standardWindowsHighWater, standardWindowsInFlight)
        defer { standardWindowsInFlight -= 1 }
        if standardWindowsDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(standardWindowsDelay * 1_000_000_000))
        }
        return windowsList.filter { window in
            runningBundleIDs.contains(window.appBundleID)
                && (bundleIDs == nil || bundleIDs!.contains(window.appBundleID))
        }
    }

    func move(windowID: Int, to frame: CGRect) async -> CGRect? {
        moveCalls.append((windowID, frame))
        standardWindowsCallsAtMove.append(standardWindowsCalls)
        switch perWindowBehavior[windowID] ?? moveBehavior {
        case .honest:
            if let i = windowsList.firstIndex(where: { $0.id == windowID }) {
                let old = windowsList[i]
                windowsList[i] = WindowInfo(id: old.id, appBundleID: old.appBundleID, appName: old.appName,
                                            frame: frame, fullscreenState: old.fullscreenState,
                                            isMinimized: old.isMinimized,
                                            windowServerID: old.windowServerID)
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

    func setFullscreen(windowID: Int, _ fullscreen: Bool) async -> Bool {
        fullscreenCalls.append((windowID, fullscreen))
        guard fullscreenSucceeds,
              let i = windowsList.firstIndex(where: { $0.id == windowID }) else { return false }
        let old = windowsList[i]
        windowsList[i] = WindowInfo(
            id: old.id, appBundleID: old.appBundleID, appName: old.appName,
            frame: old.frame,
            fullscreenState: fullscreen ? .fullscreen : .windowed,
            isMinimized: old.isMinimized, windowServerID: old.windowServerID
        )
        return true
    }

    func isRunning(bundleID: String) async -> Bool { runningBundleIDs.contains(bundleID) }

    /// openWindow 시 이 창이 나타난다 — 실제 앱이 새 창을 여는 것을 흉내낸다.
    /// 등록이 없으면 false — 한도까지 창이 안 뜬 앱과 같다. 페이크는 기다리지 않는다.
    var windowOnReopen: [String: WindowInfo] = [:]
    private(set) var openWindowCalls: [String] = []

    /// 0보다 크면 openWindow가 그만큼 매달린다 — 복원 중 인터리빙 시나리오용 서스펜션 지점.
    var openWindowDelay: TimeInterval = 0

    /// 동시 진행 최고치 — 병렬 대기의 결정적 증거 (타이밍 측정 없이 잡는다).
    private(set) var openWindowHighWater = 0
    private var openWindowInFlight = 0

    func openWindow(bundleID: String) async -> Bool {
        openWindowCalls.append(bundleID)
        openWindowInFlight += 1
        openWindowHighWater = max(openWindowHighWater, openWindowInFlight)
        defer { openWindowInFlight -= 1 }
        if openWindowDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(openWindowDelay * 1_000_000_000))
        }
        guard let window = windowOnReopen[bundleID] else { return false }
        windowsList.append(window)
        return true
    }

    /// 앱이 최소화 해제를 거부하는 상황 (unminimize → nil)
    var unminimizeFails = false
    /// Dock에서 나오며 프레임이 바뀌는 상황 — 열거 스냅샷과 재판독의 괴리를 흉내낸다
    var frameOnUnminimize: [Int: CGRect] = [:]

    /// 이동 관찰 등록 — 마지막 대상과 콜백을 들고 있어 테스트가 직접 발화시킨다.
    /// 실물 어댑터의 디바운스는 여기 없다 — 페이크는 "정착했다" 지점만 흉내낸다.
    private(set) var observedBundleIDs: [String] = []
    private var onWindowSettled: (@Sendable () -> Void)?

    func observeWindowMoves(of bundleIDs: [String], onSettled: @escaping @Sendable () -> Void) async {
        observedBundleIDs = bundleIDs.sorted()
        onWindowSettled = bundleIDs.isEmpty ? nil : onSettled
    }

    /// 창을 옮기고 손을 뗐다 — 실물에서 디바운스가 끝나 콜백이 나가는 지점.
    func simulateWindowSettled() { onWindowSettled?() }

    func unminimize(windowID: Int) async -> CGRect? {
        guard !unminimizeFails, let i = windowsList.firstIndex(where: { $0.id == windowID }) else { return nil }
        let old = windowsList[i]
        let frame = frameOnUnminimize[windowID] ?? old.frame
        windowsList[i] = WindowInfo(id: old.id, appBundleID: old.appBundleID, appName: old.appName,
                                    frame: frame, fullscreenState: old.fullscreenState,
                                    isMinimized: false, windowServerID: old.windowServerID)
        return frame
    }
}

final class FakeScreenProvider: ScreenProvider {
    var screensList: [ScreenInfo] = []
    func screens() -> [ScreenInfo] { screensList }
}
