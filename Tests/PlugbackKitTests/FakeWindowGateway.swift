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
    /// 창 목록 조회에 실패한 것으로 보고할 앱 (O05·O07).
    var failedBundleIDs: Set<String> = []
    private(set) var standardWindowsCalls = 0
    var standardWindowsDelay: TimeInterval = 0
    private(set) var standardWindowsHighWater = 0
    private var standardWindowsInFlight = 0
    var moveBehavior: MoveBehavior = .honest
    var perWindowBehavior: [Int: MoveBehavior] = [:]
    private(set) var moveCalls: [(windowID: Int, target: CGRect)] = []
    private(set) var standardWindowsCallsAtMove: [Int] = []

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
                && !failedBundleIDs.contains(window.appBundleID)
                && (bundleIDs == nil || bundleIDs!.contains(window.appBundleID))
        }
    }

    func enumerationFailures() async -> Set<String> { failedBundleIDs }

    /// 존재하는 창 전부 — 기본은 실행 중 앱의 windowsList다. 다른 Space에 있어 열거에서 빠진 창을 흉내내려면 직접 지정한다.
    var existingWindowServerIDsOverride: Set<CGWindowID>?
    func existingWindowServerIDs() async -> Set<CGWindowID>? {
        if let existingWindowServerIDsOverride { return existingWindowServerIDsOverride }
        return Set(windowsList.filter { runningBundleIDs.contains($0.appBundleID) }.compactMap(\.windowServerID))
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
                                            windowServerID: old.windowServerID, title: old.title)
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

    func isRunning(bundleID: String) async -> Bool { runningBundleIDs.contains(bundleID) }

    /// openWindow(되살리기) 시 이 창이 나타난다 — 실제 앱이 새 창을 여는 것을 흉내낸다.
    var windowOnReopen: [String: WindowInfo] = [:]
    private(set) var openWindowCalls: [String] = []
    var openWindowDelay: TimeInterval = 0
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

    /// launch(종료된 앱 다시 열기) 시 앱이 실행되며 나타나는 창들 — 비어 있으면 실행은 되지만 창은 없다.
    var windowsOnLaunch: [String: [WindowInfo]] = [:]
    var launchable: Set<String> = []
    private(set) var launchCalls: [String] = []

    func launch(bundleID: String) async -> Bool {
        launchCalls.append(bundleID)
        guard launchable.contains(bundleID) || windowsOnLaunch[bundleID] != nil else { return false }
        runningBundleIDs.insert(bundleID)
        let windows = windowsOnLaunch[bundleID] ?? []
        windowsList.append(contentsOf: windows)
        return !windows.isEmpty
    }

    /// 추가 창 열기 시 순서대로 나타나는 창들.
    var additionalWindows: [String: [WindowInfo]] = [:]
    private(set) var additionalWindowCalls: [String] = []

    func openAdditionalWindow(bundleID: String) async -> Bool {
        additionalWindowCalls.append(bundleID)
        guard var queue = additionalWindows[bundleID], !queue.isEmpty else { return false }
        windowsList.append(queue.removeFirst())
        additionalWindows[bundleID] = queue
        return true
    }

    private(set) var raiseCalls: [Int] = []
    func raise(windowID: Int) async -> Bool {
        raiseCalls.append(windowID)
        return windowsList.contains { $0.id == windowID }
    }

    var unminimizeFails = false
    var frameOnUnminimize: [Int: CGRect] = [:]

    private(set) var observedBundleIDs: [String] = []
    private var onWindowSettled: (@Sendable () -> Void)?
    private var onWindowMoved: (@Sendable (CGWindowID) -> Void)?

    func observeWindowMoves(of bundleIDs: [String], onSettled: @escaping @Sendable () -> Void) async {
        observedBundleIDs = bundleIDs.sorted()
        onWindowSettled = bundleIDs.isEmpty ? nil : onSettled
    }

    func observeWindowInteractions(_ onWindowMoved: @escaping @Sendable (CGWindowID) -> Void) async {
        self.onWindowMoved = onWindowMoved
    }

    /// 창을 옮기고 손을 뗐다 — 실물에서 디바운스가 끝나 콜백이 나가는 지점.
    func simulateWindowSettled() { onWindowSettled?() }
    /// 원시 이동 알림 — 사용자 조작 보호가 듣는다.
    func simulateWindowMoved(_ windowServerID: CGWindowID) { onWindowMoved?(windowServerID) }

    func unminimize(windowID: Int) async -> CGRect? {
        guard !unminimizeFails, let i = windowsList.firstIndex(where: { $0.id == windowID }) else { return nil }
        let old = windowsList[i]
        let frame = frameOnUnminimize[windowID] ?? old.frame
        windowsList[i] = WindowInfo(id: old.id, appBundleID: old.appBundleID, appName: old.appName,
                                    frame: frame, fullscreenState: old.fullscreenState,
                                    isMinimized: false, windowServerID: old.windowServerID, title: old.title)
        return frame
    }
}

final class FakeScreenProvider: ScreenProvider {
    var screensList: [ScreenInfo] = []
    func screens() -> [ScreenInfo] { screensList }
}

// MARK: - 공통 헬퍼

extension WorkspaceSnapshot {
    /// 화면 하나에 앱별 창 하나씩 놓은 저장본 — 구버전 프로필과 같은 모양의 테스트 씨앗.
    static func flat(screen: ScreenInfo, apps: [(String, UnitRect)], savedBy: Slot = .manual,
                     savedAt: Date? = Date()) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            key: WorkspaceKey(screenIDs: [screen.id]),
            screens: [ScreenRecord(id: screen.id, name: screen.name, fingerprint: screen.fingerprint)],
            placements: apps.map {
                WindowPlacement(bundleID: $0.0, displayName: $0.0, screenID: screen.id, space: nil, unitRect: $0.1)
            },
            savedAt: savedAt, savedBy: savedBy
        )
    }
}

extension WorkspaceRecord {
    static func with(_ snapshot: WorkspaceSnapshot, closed: Set<UUID> = []) -> WorkspaceRecord {
        WorkspaceRecord(key: snapshot.key,
                        apps: Array(Set(snapshot.placements.map(\.bundleID))).sorted().map {
                            AppSelection(bundleID: $0, displayName: $0)
                        },
                        saved: snapshot, closedPlacementIDs: closed)
    }
}

@MainActor
func makeLibrary(directory: URL, records: [WorkspaceRecord] = [], autoSave: Bool = true) -> WorkspaceLibrary {
    let store = ProfileStore(directory: directory)
    if !records.isEmpty {
        try! store.save(Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }))
    }
    return WorkspaceLibrary(store: store, isAutoSaveEnabled: autoSave)
}

func temporaryDirectory(_ prefix: String = "plugback-tests") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}
