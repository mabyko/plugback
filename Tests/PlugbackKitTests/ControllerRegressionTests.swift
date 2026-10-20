import AppKit
import Combine
import CoreGraphics
import XCTest
@testable import PlugbackKit

// 화면 안정화·실행 중 이벤트·결과 귀속의 회귀 검사.
// T1·T2·T4·T5는 재설계 검토 부록 A의 재현 테스트를 올바른 기대 동작으로 바꾼 것이다 (docs/proposals/2026-10-20-*).

private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                 frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let extA = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                              frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
private let extB = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                              frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)

@MainActor
private final class RegressionSpaceReader: SpaceReading {
    var availability: SpaceSnapshotAvailability = .unavailable
    var queuedResponses: [(availability: SpaceSnapshotAvailability, delay: TimeInterval)] = []
    private(set) var requests: [[CGWindowID]] = []

    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability {
        requests.append(windowServerIDs)
        let response = queuedResponses.isEmpty ? (availability: availability, delay: 0) : queuedResponses.removeFirst()
        if response.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000)) }
        return response.availability
    }
}

/// 이동 직전에 한 번 끼어드는 게이트웨이 — 실행 중 이동과 이동 사이의 사용자 조작을 흉내낸다.
@MainActor
private final class InterleavingGateway: WindowGateway {
    let base: FakeWindowGateway
    var beforeFirstMove: (() async -> Void)?

    init(_ base: FakeWindowGateway) { self.base = base }

    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] { await base.standardWindows(of: bundleIDs) }
    func enumerationFailures() async -> Set<String> { await base.enumerationFailures() }
    func existingWindowServerIDs() async -> Set<CGWindowID>? { await base.existingWindowServerIDs() }
    func isRunning(bundleID: String) async -> Bool { await base.isRunning(bundleID: bundleID) }
    func unminimize(windowID: Int) async -> CGRect? { await base.unminimize(windowID: windowID) }
    func openWindow(bundleID: String) async -> Bool { await base.openWindow(bundleID: bundleID) }
    func move(windowID: Int, to frame: CGRect) async -> CGRect? {
        if let hook = beforeFirstMove {
            beforeFirstMove = nil
            await hook()
        }
        return await base.move(windowID: windowID, to: frame)
    }
}

@MainActor
final class ControllerRegressionTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("controller-regression")

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "controller-regression-\(UUID().uuidString)")! }

    private func win(_ id: Int, _ bundleID: String, _ frame: CGRect, _ wsid: CGWindowID) -> WindowInfo {
        WindowInfo(id: id, appBundleID: bundleID, appName: bundleID, frame: frame, windowServerID: wsid)
    }

    private func stored(_ key: WorkspaceKey) -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("workspaces.json")),
              let file = try? JSONDecoder.plugback.decode(StoreFile.self, from: data) else { return nil }
        return file.workspaces[key.raw]?.saved
    }

    /// 저장소 디렉터리 자리에 파일을 둬 쓰기를 실패시킨다. 지우면 다시 쓸 수 있다.
    private func blockWrites() throws {
        try? FileManager.default.removeItem(at: dir)
        try Data("not-a-directory".utf8).write(to: dir)
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 조건이 참이 될 때까지 기다린다 — 실제 디바운스를 거치는 검사가 고정 대기에 기대지 않게.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - T1 · 집합이 그대로인 원시 화면 변경

    func testSettlingStatusClearsWhenTheExternalSetDoesNotChange() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        controller.startWatching()
        XCTAssertFalse(controller.isSettlingScreens)

        // 해상도·배치 변경처럼 외장 화면 집합이 그대로인 원시 변경
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let raised = await waitUntil(timeout: 1) { controller.isSettlingScreens }
        XCTAssertTrue(raised, "원시 변경 신호는 받았다")
        let captureDuringSettle = await controller.captureNow()
        XCTAssertEqual(captureDuringSettle, .notConnected, "안정화 중인 연결에서 새 저장본을 만들지 않는다")

        let cleared = await waitUntil(timeout: 4) { !controller.isSettlingScreens } // 기본 안정화 1.5초
        XCTAssertTrue(cleared, "집합이 그대로여도 안정화가 끝나면 「화면 연결 확인 중」을 내린다 (US-009 AC-4)")
        await controller.cardOpened()
        XCTAssertFalse(controller.isSettlingScreens)
        XCTAssertTrue(gateway.moveCalls.isEmpty, "해상도 변경만으로 복원하지 않는다")
    }

    // MARK: - PR 검토 · 늦은 안정화와 연결 해제된 다중 화면

    func testOlderSettleDoesNotOpenTheGateDuringANewerRawChange() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        controller.startWatching()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let raised = await waitUntil(timeout: 1) { controller.isSettlingScreens }
        XCTAssertTrue(raised)

        // 새 원시 변경이 디바운스 중인 동안, 이전 회차의 MainActor 작업이 늦게 도착한다.
        await controller.screensSettled(.unchanged)
        XCTAssertTrue(controller.isSettlingScreens, "다음 회차의 안정화 게이트를 이전 통지가 열면 안 된다")
        let capture = await controller.captureNow()
        XCTAssertEqual(capture, .notConnected)
        let cleared = await waitUntil(timeout: 4) { !controller.isSettlingScreens }
        XCTAssertTrue(cleared, "새 회차가 끝나면 게이트가 정상적으로 열린다")
    }

    func testDisconnectedWorkspaceKeepsSpaceGroupsForEveryScreen() async throws {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA, extB]
        let reader = RegressionSpaceReader()
        let key = WorkspaceKey(screenIDs: [extA.id, extB.id])
        let snapshot = WorkspaceSnapshot(key: key, screens: [extA, extB].map {
            ScreenRecord(id: $0.id, name: $0.name,
                         regularSpaces: [SpaceHint(opaqueName: "saved-\($0.id)", localOrderHint: 1)])
        }, placements: [], savedAt: Date())
        let store = ProfileStore(directory: dir)
        try store.save([key: WorkspaceRecord(key: key, apps: [], saved: snapshot)])
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: store, defaults: defaults(), spaceReader: reader)
        await controller.cardOpened()
        screens.screensList = [builtin]
        await controller.workspaceChanged()
        XCTAssertEqual(controller.sections.count, 2)
        XCTAssertTrue(controller.sections.allSatisfy { $0.spaceGroups.count == 1 })

        let restarted = PlugbackController(gateway: gateway, screenProvider: screens,
                                           store: store, defaults: defaults(), spaceReader: reader)
        await restarted.cardOpened()
        XCTAssertEqual(restarted.sections.count, 2)
        XCTAssertTrue(restarted.sections.allSatisfy { $0.spaceGroups.count == 1 })
    }

    // MARK: - T2 · 복원 실행 중 Space 방문

    func testSpaceVisitDuringARunningRestoreIsHandledRightAfterTheRun() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        let ext = ScreenInfo(id: "EXTERNAL", name: "External",
                             frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)
        let laptop = ScreenInfo(id: "BUILTIN", name: "Built-in",
                                  frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: true)
        screens.screensList = [laptop, ext]
        let reader = RegressionSpaceReader()
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults(),
                                            spaceReader: reader, activeSpaceDebounceInterval: 0)
        let first = SpaceRuntimeID(1), second = SpaceRuntimeID(2)
        func snapshot(current: SpaceRuntimeID) -> SpaceSnapshotAvailability {
            .available(SpaceSnapshot(
                displays: [
                    .init(screenID: laptop.id, spaces: [.init(runtimeID: SpaceRuntimeID(100), opaqueName: "builtin",
                                                                localOrder: 1, kind: .regular, isCurrent: true)]),
                    .init(screenID: ext.id, spaces: [
                        .init(runtimeID: first, opaqueName: "first", localOrder: 1, kind: .regular, isCurrent: current == first),
                        .init(runtimeID: second, opaqueName: "second", localOrder: 2, kind: .regular, isCurrent: current == second),
                    ]),
                ],
                membershipsByWindowServerID: [11: [first], 12: [second]]
            ))
        }
        let left = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        let right = CGRect(x: 1500, y: 0, width: 500, height: 1000)
        let messy = CGRect(x: 1200, y: 200, width: 400, height: 400)
        gateway.runningBundleIDs = ["com.one", "com.two"]
        gateway.existingWindowServerIDsOverride = [11, 12]

        gateway.windowsList = [win(1, "com.one", left, 11)]
        reader.availability = snapshot(current: first)
        let firstSave = await controller.captureNow()
        XCTAssertEqual(firstSave, .captured(appCount: 1, windowCount: 1))
        gateway.windowsList = [win(2, "com.two", right, 12)]
        reader.availability = snapshot(current: second)
        let secondSave = await controller.captureNow()
        XCTAssertEqual(secondSave, .captured(appCount: 2, windowCount: 2))

        // Space 1로 돌아와 복원 시작 — 관찰이 0.3초 걸린다
        gateway.windowsList = [win(1, "com.one", messy, 11)]
        reader.availability = snapshot(current: first)
        reader.queuedResponses = [(snapshot(current: first), 0.3)]
        let before = reader.requests.count
        let restore = Task { await controller.restoreNow() }
        while reader.requests.count == before { await Task.yield() }

        // 복원이 도는 동안 사용자가 Space 2로 이동
        reader.availability = snapshot(current: second)
        gateway.windowsList = [win(2, "com.two", messy, 12)]
        await controller.activeSpaceChanged()
        _ = await restore.value

        XCTAssertTrue(gateway.moveCalls.contains { $0.windowID == 2 && $0.target == right },
                      "실행 중 도착한 Space 방문을 실행 직후 재판정해 Space 2의 창을 복원한다 (I8)")
        XCTAssertFalse(controller.waitingItems.contains { $0.outcome == .awaitingVisit },
                       "이미 현재 Space인 항목을 방문 대기로 남기지 않는다")
    }

    // MARK: - T4 · 이전 작업 환경의 결과

    func testAnotherWorkspaceResultIsNotShownOnTheNextWorkspaceCard() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA, extB]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        let chromeSaved = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        let slackSaved = CGRect(x: 4072, y: 0, width: 960, height: 1080)
        var publishedTimes: [Date?] = []
        let subscription = controller.$lastRestoredAt.sink { publishedTimes.append($0) }
        defer { subscription.cancel() }
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [win(1, "com.chrome", chromeSaved, 101), win(2, "com.slack", slackSaved, 102)]
        _ = await controller.captureNow() // A+B
        gateway.windowsList[0] = win(1, "com.chrome", CGRect(x: 2500, y: 500, width: 800, height: 600), 101)
        _ = await controller.restoreNow()
        XCTAssertFalse(controller.lastResults.isEmpty)
        XCTAssertNotNil(controller.lastRestoredAt)
        XCTAssertNotNil(publishedTimes.last ?? nil)

        // B를 분리 — A 단독 환경에는 저장본이 없다
        screens.screensList = [builtin, extA]
        await controller.workspaceChanged()
        XCTAssertFalse(controller.hasRestorableProfile, "A 단독 환경은 저장본이 없다")
        XCTAssertNil(controller.sections.first?.lastResult, "A+B 요청의 결과를 A 카드의 마지막 복원으로 보이지 않는다")
        XCTAssertTrue(controller.lastResults.isEmpty)
        XCTAssertNil(controller.lastRestoredAt, "복원 시각도 그 결과의 작업 환경에 속한다")
        XCTAssertNil(publishedTimes.last ?? nil, "기존 Combine 구독에도 현재 작업 환경의 시각을 알린다")

        // A+B로 돌아오면 그 환경 요청의 결과만 보인다
        screens.screensList = [builtin, extA, extB]
        await controller.workspaceChanged()
        XCTAssertEqual(Set(controller.lastResults.map(\.screenID)), ["ext-1", "ext-2"])
        XCTAssertNotNil(controller.lastRestoredAt)
    }

    // MARK: - T5 · 「남은 창 복원」 실행 중 화면 추가

    func testWorkspaceChangeDuringResumeRestartsForTheNewWorkspaceAfterTheRun() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let store = ProfileStore(directory: dir)
        let sharedDefaults = defaults()
        let leftA = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        let rightA = CGRect(x: 2792, y: 0, width: 1280, height: 1440)
        let slackSaved = CGRect(x: 4072, y: 0, width: 960, height: 1080)
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [win(1, "com.chrome", leftA, 101), win(2, "com.chrome", rightA, 102)]
        let first = PlugbackController(gateway: gateway, screenProvider: screens, store: store, defaults: sharedDefaults)
        _ = await first.captureNow() // A: Chrome 창 둘
        screens.screensList = [builtin, extA, extB]
        gateway.windowsList.append(win(3, "com.slack", slackSaved, 103))
        _ = await first.captureNow() // A+B

        // 재실행 — 창 연결은 메모리뿐이라 사라진다. A만 연결된 상태에서 시작
        screens.screensList = [builtin, extA]
        gateway.windowsList = [win(1, "com.chrome", rightA, 101), win(2, "com.chrome", leftA, 102),
                               win(3, "com.slack", CGRect(x: 100, y: 100, width: 600, height: 400), 103)]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: sharedDefaults)
        controller.directWindowAssignment = true
        await controller.workspaceChanged() // A 자동 복원 → Chrome 두 자리 확인 필요
        XCTAssertEqual(controller.confirmationCount, 2)

        gateway.standardWindowsDelay = 0.05
        let before = gateway.standardWindowsCalls
        let resume = Task { await controller.resumeRemaining() }
        while gateway.standardWindowsCalls == before { await Task.yield() }

        // 남은 창 복원이 도는 동안 B 연결
        screens.screensList = [builtin, extA, extB]
        gateway.windowsList[2] = win(3, "com.slack", CGRect(x: 4500, y: 300, width: 800, height: 600), 103)
        await controller.externalScreensAppeared()
        let resumedOutcome = await resume.value
        if case .restored(let results) = resumedOutcome {
            XCTAssertFalse(results.contains { $0.screenID == extB.id },
                           "이전 A 요청의 반환값에 후속 A+B 요청 결과를 섞지 않는다")
        } else {
            XCTFail("시작한 요청의 취소 결과를 반환해야 한다")
        }

        XCTAssertTrue(gateway.moveCalls.contains { $0.windowID == 3 && $0.target == slackSaved },
                      "재개 실행 직후 A+B 저장본으로 새 자동 복원을 시작한다 (G05)")
        XCTAssertTrue(controller.lastResults.contains { $0.screenID == "ext-2" })
    }

    // MARK: - 안정화 통지

    func testWatcherSettlesEveryRoundIncludingUnchangedSuppressedAndDeferred() async {
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, extA]
        var locked = false
        var settles: [DisplayWatcher.Settle] = []
        var appeared = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02, wakeSuppressionInterval: 0.2,
                                     isLocked: { locked }, onSettled: { settles.append($0) }) { appeared += 1 }

        watcher.screenParametersChanged() // 해상도 변경 — 집합 그대로
        await wait(0.08)
        XCTAssertEqual(settles, [.unchanged])

        watcher.systemDidWake() // 억제 창 안의 등장 — 자동 복원만 억제한다
        provider.screensList = [builtin, extA, extB]
        watcher.screenParametersChanged()
        await wait(0.08)
        XCTAssertEqual(settles.last, .changed(automaticRestore: false))
        XCTAssertEqual(appeared, 0, "기존 등장 콜백의 억제는 그대로다")

        provider.screensList = [builtin, extA] // 제거는 억제를 타지 않는다
        watcher.screenParametersChanged()
        await wait(0.08)
        XCTAssertEqual(settles.last, .changed(automaticRestore: true))

        await wait(0.2) // 억제 창이 끝난다
        locked = true // 잠긴 채 연결 — 해제 뒤로 미룬다
        provider.screensList = [builtin, extA, extB]
        watcher.screenParametersChanged()
        await wait(0.08)
        XCTAssertEqual(settles.last, .deferredUntilUnlock)
        locked = false
        watcher.screenDidUnlock()
        await wait(0.08)
        XCTAssertEqual(settles.last, .changed(automaticRestore: true))
        XCTAssertEqual(appeared, 1)
        XCTAssertEqual(settles.count, 5, "안정화마다 정확히 한 번 알린다")
    }

    func testWakeSuppressedArrivalSwitchesTheWorkspaceWithoutAutomaticRestore() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        let left = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        let right = CGRect(x: 2792, y: 0, width: 1280, height: 1440)
        let slackSaved = CGRect(x: 4072, y: 0, width: 960, height: 1080)
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [win(1, "com.chrome", left, 101)]
        _ = await controller.captureNow() // A
        screens.screensList = [builtin, extA, extB]
        gateway.windowsList.append(win(2, "com.slack", slackSaved, 102))
        _ = await controller.captureNow() // A+B
        screens.screensList = [builtin, extA]
        await controller.workspaceChanged() // A 선택 — 창은 이미 제자리
        let movesBefore = gateway.moveCalls.count
        gateway.windowsList[0] = win(1, "com.chrome", right, 101)
        await controller.collectCandidate()
        XCTAssertTrue(controller.hasPendingCollect)

        // 잠자기 해제 직후 B 연결 — 등장 콜백은 억제됐지만 안정화는 통지된다
        screens.screensList = [builtin, extA, extB]
        gateway.windowsList[1] = win(2, "com.slack", CGRect(x: 4500, y: 300, width: 800, height: 600), 102)
        await controller.screensSettled(.changed(automaticRestore: false))

        XCTAssertFalse(controller.isSettlingScreens)
        XCTAssertEqual(controller.currentWorkspace, WorkspaceKey(screenIDs: [extA.id, extB.id]))
        XCTAssertTrue(controller.hasRestorableProfile, "새 환경을 선택했다")
        XCTAssertEqual(gateway.moveCalls.count, movesBefore, "억제 회차는 자동 복원하지 않는다 (US-009 AC-5)")
        XCTAssertEqual(stored(WorkspaceKey(screenIDs: [extA.id]))?.savedBy, .auto, "떠난 A의 이력은 저장한다 (D2)")
        XCTAssertEqual(stored(WorkspaceKey(screenIDs: [extA.id]))?.placements.first?.unitRect.x, 0.5)

        await controller.screensSettled(.unchanged)
        XCTAssertEqual(gateway.moveCalls.count, movesBefore, "같은 조합의 다음 안정화도 복원이 아니다")
        _ = await controller.restoreNow() // 수동 복원으로 잡는다
        XCTAssertTrue(gateway.moveCalls.contains { $0.windowID == 2 && $0.target == slackSaved })
    }

    func testLockDeferredArrivalWaitsForTheSettleAfterUnlock() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA, extB]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        let slackSaved = CGRect(x: 4072, y: 0, width: 960, height: 1080)
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101),
                               win(2, "com.slack", slackSaved, 102)]
        _ = await controller.captureNow() // A+B
        screens.screensList = [builtin, extA]
        await controller.workspaceChanged() // A 선택 — 저장본 없음
        gateway.windowsList[1] = win(2, "com.slack", CGRect(x: 4500, y: 300, width: 800, height: 600), 102)

        // 잠긴 채 B 연결 — 해제 뒤로 미룬 회차는 환경을 바꾸지도, 복원하지도 않는다
        screens.screensList = [builtin, extA, extB]
        await controller.screensSettled(.deferredUntilUnlock)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        // 해제 뒤 다시 안정화되면 그때의 조합으로 한 번 복원한다 (US-009 AC-3·AC-7)
        await controller.screensSettled(.changed(automaticRestore: true))
        XCTAssertTrue(gateway.moveCalls.contains { $0.windowID == 2 && $0.target == slackSaved })
    }

    // MARK: - 요청 귀속


    func testRememberedWorkspaceKeepsAllScreenNamesAfterDisconnectAndRelaunch() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA, extB]
        let store = ProfileStore(directory: dir)
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: store, defaults: defaults())
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        await controller.captureNow()
        await controller.workspaceChanged()
        screens.screensList = [builtin]
        await controller.workspaceChanged()
        XCTAssertEqual(Set(controller.sections.map(\.screenID)), [extA.id, extB.id])
        XCTAssertTrue(controller.sections.allSatisfy(\.hasSnapshot))

        let restarted = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: store, defaults: defaults())
        await restarted.cardOpened()
        XCTAssertEqual(Set(restarted.sections.map(\.screenID)), [extA.id, extB.id])
        XCTAssertTrue(restarted.sections.allSatisfy(\.hasSnapshot))
        XCTAssertNil(restarted.lastRestoredAt)
    }

    func testItemsOfAnotherWorkspaceRequestAreNotExposed() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let leftA = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        let rightA = CGRect(x: 2792, y: 0, width: 1280, height: 1440)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", leftA, 101), win(2, "com.chrome", rightA, 102)]
        let sharedDefaults = defaults()
        _ = await PlugbackController(gateway: gateway, screenProvider: screens, store: ProfileStore(directory: dir),
                                     defaults: sharedDefaults).captureNow()
        // 재실행 — 연결이 없어 직접 지정이 Chrome 두 자리를 확인 필요로 남긴다
        gateway.windowsList = [win(1, "com.chrome", rightA, 101), win(2, "com.chrome", leftA, 102)]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: sharedDefaults)
        controller.directWindowAssignment = true
        _ = await controller.restoreNow()
        XCTAssertEqual(controller.confirmationCount, 2)

        // B가 연결됐지만 안정화를 아직 반영하지 않았다 (디바운스·잠금 보류 중) — A 요청의 항목을 A+B 카드에 보이지 않는다
        screens.screensList = [builtin, extA, extB]
        await controller.cardOpened()
        XCTAssertTrue(controller.waitingItems.isEmpty)
        XCTAssertTrue(controller.confirmationItems.isEmpty)
        XCTAssertEqual(controller.confirmationCount, 0)
        XCTAssertFalse(controller.hasOpenRestoreItems)
        XCTAssertTrue(controller.lastResults.isEmpty)
        let resumed = await controller.resumeRemaining()
        XCTAssertEqual(resumed, .restored([]))
        XCTAssertTrue(gateway.moveCalls.isEmpty)

        screens.screensList = [builtin, extA] // A로 돌아오면 같은 요청이 다시 보인다
        await controller.cardOpened()
        XCTAssertEqual(controller.confirmationCount, 2)
        XCTAssertTrue(controller.hasOpenRestoreItems)
    }

    // MARK: - 즉시 반영하는 안전 신호

    func testRawScreenChangePausesUnsentMovesUntilTheScreensSettle() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        let saved = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", saved, 101)]
        _ = await controller.captureNow()
        controller.startWatching()
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 2500, y: 500, width: 800, height: 600), 101)]

        gateway.standardWindowsDelay = 0.3
        let before = gateway.standardWindowsCalls
        let restore = Task { await controller.restoreNow() }
        while gateway.standardWindowsCalls == before { await Task.yield() }
        // 관찰 도중 해상도가 바뀐다 — 실행 직전 게이트가 바로 본다
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        _ = await restore.value
        XCTAssertTrue(gateway.moveCalls.isEmpty, "화면이 바뀌는 동안 옛 좌표로 이동을 보내지 않는다")
        XCTAssertTrue(controller.hasOpenRestoreItems, "보내지 못한 항목은 같은 요청에 남는다")

        gateway.standardWindowsDelay = 0
        let continued = await waitUntil(timeout: 4) { !gateway.moveCalls.isEmpty }
        XCTAssertTrue(continued, "집합이 그대로 안정되면 같은 요청의 남은 항목을 새 좌표로 이어간다")
        XCTAssertEqual(gateway.windowsList.first?.frame, saved)
        XCTAssertFalse(controller.isSettlingScreens)
        XCTAssertFalse(controller.hasOpenRestoreItems)
    }

    func testExcludingAnAppMidRunStopsItsUnsentMove() async {
        let fake = FakeWindowGateway()
        let gateway = InterleavingGateway(fake)
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        fake.runningBundleIDs = ["com.one", "com.two"]
        fake.windowsList = [win(1, "com.one", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101),
                            win(2, "com.two", CGRect(x: 2792, y: 0, width: 1280, height: 1440), 102)]
        _ = await controller.captureNow()
        fake.windowsList = [win(1, "com.one", CGRect(x: 2000, y: 300, width: 800, height: 600), 101),
                            win(2, "com.two", CGRect(x: 2200, y: 400, width: 800, height: 600), 102)]

        // 첫 창을 옮기는 사이 사용자가 com.two를 대상에서 뺀다
        gateway.beforeFirstMove = { await controller.setTracked("com.two", false, on: extA.id) }
        _ = await controller.restoreNow()

        XCTAssertEqual(fake.moveCalls.map(\.windowID), [1], "제외한 앱의 아직 보내지 않은 이동은 하지 않는다 (RQ12)")
        XCTAssertEqual(controller.lastResults.flatMap(\.entries).first { $0.bundleID == "com.two" }?.outcome,
                       .cancelled(.targetRemoved))
    }

    // MARK: - 실행 중 미룬 수집

    func testCollectionRequestedDuringARunHappensAfterIt() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        _ = await controller.captureNow()
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 2500, y: 500, width: 800, height: 600), 101)]

        gateway.standardWindowsDelay = 0.05
        let before = gateway.standardWindowsCalls
        let restore = Task { await controller.restoreNow() }
        while gateway.standardWindowsCalls == before { await Task.yield() }
        // 복원이 도는 동안 사용자가 새 앱 창을 열고 수집 신호가 온다
        gateway.runningBundleIDs.insert("com.notes")
        gateway.windowsList.append(win(2, "com.notes", CGRect(x: 3000, y: 200, width: 600, height: 400), 102))
        await controller.collectCandidate()
        XCTAssertFalse(controller.hasPendingCollect, "복원 중에는 모으지 않는다")
        _ = await restore.value
        XCTAssertTrue(controller.hasPendingCollect, "실행이 끝나면 미룬 수집을 한다")
    }

    // MARK: - 저장 실패의 귀속과 종료 저장 (P5)

    func testLeaveSaveFailureIsKeptPerWorkspaceAndCanBeRetried() async throws {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        let keyA = WorkspaceKey(screenIDs: [extA.id])
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        _ = await controller.captureNow()
        await controller.workspaceChanged() // A 선택
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 2792, y: 0, width: 1280, height: 1440), 101)]
        await controller.collectCandidate()

        try blockWrites()
        screens.screensList = [builtin]
        await controller.workspaceChanged() // A를 떠난다 — 이탈 저장 실패
        XCTAssertEqual(controller.saveFailedWorkspaces, [keyA])
        XCTAssertEqual(controller.allWorkspaces.first { $0.key == keyA }?.savedBy, .manual, "다음 연결은 이전 저장본으로 복원된다")

        // 다른 쓰기가 성공해 범용 알림이 사라져도 그 환경의 실패는 남는다
        try FileManager.default.removeItem(at: dir)
        screens.screensList = [builtin, extB]
        gateway.windowsList.append(win(2, "com.slack", CGRect(x: 4072, y: 0, width: 960, height: 1080), 102))
        _ = await controller.captureNow()
        XCTAssertNil(controller.storeNotice)
        XCTAssertEqual(controller.saveFailedWorkspaces, [keyA])

        XCTAssertTrue(controller.retrySave(keyA), "연결되지 않은 환경도 다시 시도할 수 있다")
        XCTAssertTrue(controller.saveFailedWorkspaces.isEmpty)
        XCTAssertEqual(stored(keyA)?.savedBy, .auto)
        XCTAssertEqual(stored(keyA)?.placements.first?.unitRect.x, 0.5)
    }


    func testRetryingASaveEndsTheOldRequestAndCannotRunDuringRestore() async throws {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        controller.restoreMode = .manual
        let keyA = WorkspaceKey(screenIDs: [extA.id])
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        await controller.captureNow()
        await controller.workspaceChanged()
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 2792, y: 0, width: 1280, height: 1440), 101)]
        await controller.collectCandidate()
        try blockWrites()
        screens.screensList = [builtin]
        await controller.workspaceChanged()
        try FileManager.default.removeItem(at: dir)
        screens.screensList = [builtin, extA]
        await controller.workspaceChanged()

        gateway.standardWindowsDelay = 0.2
        let calls = gateway.standardWindowsCalls
        let restore = Task { await controller.restoreNow() }
        while gateway.standardWindowsCalls == calls { await Task.yield() }
        XCTAssertFalse(controller.retrySave(keyA), "복원 실행 중에는 저장을 확정하지 않는다")
        controller.cancelRemaining()
        _ = await restore.value
        gateway.standardWindowsDelay = 0
        controller.lockStateCheck = { .locked }
        await controller.restoreNow()
        XCTAssertTrue(controller.hasOpenRestoreItems)
        XCTAssertTrue(controller.retrySave(keyA))
        XCTAssertFalse(controller.hasOpenRestoreItems, "새 저장이 성공하면 이전 소스의 남은 요청을 끝낸다")
        XCTAssertTrue(controller.saveFailedWorkspaces.isEmpty)
    }

    func testQuitWithoutSavingIsNotOverwrittenOnWillTerminate() async throws {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        _ = await controller.captureNow()
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 2792, y: 0, width: 1280, height: 1440), 101)]
        await controller.collectCandidate()

        try blockWrites()
        XCTAssertEqual(controller.prepareForTermination(), .saveFailed)
        // 「저장하지 않고 종료」 — 그 사이 쓰기가 가능해져도 종료 알림이 다시 쓰지 않는다
        try FileManager.default.removeItem(at: dir)
        controller.willTerminate()
        XCTAssertNil(stored(WorkspaceKey(screenIDs: [extA.id])))
    }

    func testTerminationWithoutShouldTerminateStillConfirmsOnWillTerminate() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        _ = await controller.captureNow()
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 2792, y: 0, width: 1280, height: 1440), 101)]
        await controller.collectCandidate()

        controller.willTerminate() // applicationShouldTerminate를 거치지 않은 예외 경로 — 마지막 기회로 확정한다
        XCTAssertEqual(stored(WorkspaceKey(screenIDs: [extA.id]))?.savedBy, .auto)
    }
}
