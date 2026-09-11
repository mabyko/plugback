import XCTest
@testable import PlugbackKit

// 화면 배치: 내장(0,0,1512×982) 오른쪽에 외장(1512,0,2560×1440). 좌상단 원점 통일 좌표계.
private let builtin = ScreenInfo(id: "builtin", name: "내장 화면", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let external = ScreenInfo(id: "ext-1", name: "LG UltraFine 27", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

private func window(_ id: Int, _ app: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                    fullscreen: Bool = false, minimized: Bool = false, serverID: CGWindowID? = nil) -> WindowInfo {
    WindowInfo(id: id, appBundleID: app, appName: app, frame: CGRect(x: x, y: y, width: w, height: h),
               isFullscreen: fullscreen, isMinimized: minimized, windowServerID: serverID ?? CGWindowID(100 + id))
}

// MARK: - UnitRect (F-03.4)

final class UnitRectTests: XCTestCase {
    func testRoundTripOnNegativeOriginScreen() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = CGRect(x: -960, y: 340, width: 960, height: 540)
        let rect = UnitRect(frame, in: screen)
        XCTAssertEqual(rect.frame(in: screen), frame)
    }

    func testRatioSurvivesResolutionChange() {
        // 우측 50%는 해상도가 바뀌어도 우측 50%다 (US-001 AC-4)
        let rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let smaller = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(rightHalf.frame(in: smaller), CGRect(x: 1512 + 960, y: 0, width: 960, height: 1080))
    }
}

// MARK: - 저장 관찰 (F-03, US-002) — 창 하나가 기록 하나다 (D1)

final class CaptureEngineTests: XCTestCase {
    private func observe(_ windows: [WindowInfo], base: WorkspaceSnapshot? = nil,
                         links: [UUID: CGWindowID] = [:], excluded: Set<String> = [],
                         closed: Set<UUID> = []) -> CaptureEngine.Observation {
        CaptureEngine.observe(windows: windows, screens: [builtin, external], snapshot: nil, base: base,
                              links: links, excludedBundleIDs: excluded, closedPlacementIDs: closed)
    }

    func testCenterPointDecidesScreen() {
        // 두 화면에 걸친 창은 중심점이 있는 화면 소속이다 (US-002 AC-3)
        let straddlingCenterOnExternal = window(1, "com.chrome", x: 1400, y: 100, w: 800, h: 600) // 중심 x=1800 → 외장
        let straddlingCenterOnBuiltin = window(2, "com.slack", x: 1200, y: 100, w: 400, h: 300)   // 중심 x=1400 → 내장
        let observation = observe([straddlingCenterOnExternal, straddlingCenterOnBuiltin])
        XCTAssertEqual(observation.placements.map(\.bundleID), ["com.chrome"])
    }

    func testEveryWindowOfAnAppGetsItsOwnPlacement() {
        // 같은 Space의 같은 앱 창 둘은 각각 기록한다 — 대표 창 하나로 줄이지 않는다 (D1 확정, W08)
        let left = window(1, "com.chrome", x: 1512, y: 0, w: 1280, h: 1440)
        let right = window(2, "com.chrome", x: 2792, y: 0, w: 1280, h: 1440)
        let observation = observe([left, right])
        XCTAssertEqual(observation.placements.count, 2)
        XCTAssertEqual(observation.placements.map { $0.unitRect.x }, [0, 0.5])
        XCTAssertEqual(observation.links.count, 2, "관찰한 창마다 실행 중 연결이 생긴다")
    }

    func testUnobservedPlacementsSurviveAndLinkedWindowsUpdateInPlace() {
        // 오늘 Slack을 안 켰어도 Slack 기록은 남고, 연결된 Chrome 창은 같은 자리를 갱신한다 (US-002 AC-4, S04)
        let base = WorkspaceSnapshot.flat(screen: external, apps: [
            ("com.slack", UnitRect(x: 0, y: 0, width: 0.3, height: 0.5)),
            ("com.chrome", UnitRect(x: 0, y: 0, width: 1, height: 1)),
        ])
        let chromeID = base.placements[1].id
        let chromeNow = window(1, "com.chrome", x: 1512 + 1280, y: 0, w: 1280, h: 1440)
        let observation = observe([chromeNow], base: base, links: [chromeID: 101])

        XCTAssertEqual(observation.placements.count, 2)
        XCTAssertEqual(observation.placements.first { $0.bundleID == "com.slack" }?.unitRect,
                       UnitRect(x: 0, y: 0, width: 0.3, height: 0.5))
        XCTAssertEqual(observation.placements.first { $0.id == chromeID }?.unitRect,
                       UnitRect(x: 0.5, y: 0, width: 0.5, height: 1), "연결된 창은 새 기록이 아니라 같은 자리의 갱신이다")
    }

    func testUnlinkedWindowBecomesANewPlacementNextToThePreservedOne() {
        // 연결이 없는 창(새 창)은 기존 기록을 덮지 않고 새 기록으로 추가된다 (W04)
        let base = WorkspaceSnapshot.flat(screen: external, apps: [("com.chrome", UnitRect(x: 0, y: 0, width: 0.5, height: 1))])
        let observation = observe([window(1, "com.chrome", x: 2792, y: 0, w: 1280, h: 1440)], base: base)
        XCTAssertEqual(observation.placements.count, 2)
    }

    func testClosedInWorkspaceAndMovedToBuiltinAreDroppedFromTheNextHistory() {
        // 같은 환경에서 닫힌 자리와 내장으로 옮긴 창의 기록은 새 이력에서 뺀다 (D9·D4)
        let base = WorkspaceSnapshot.flat(screen: external, apps: [
            ("com.a", UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
            ("com.b", UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ])
        let bID = base.placements[1].id
        let bOnBuiltin = window(2, "com.b", x: 100, y: 100, w: 400, h: 300, serverID: 102)
        let observation = observe([bOnBuiltin], base: base, links: [bID: 102], closed: [base.placements[0].id])
        XCTAssertTrue(observation.placements.isEmpty)
        XCTAssertEqual(observation.droppedPlacementIDs, [bID])
    }

    func testBuiltinScreenIsNeverCaptured() {
        let onBuiltin = window(1, "com.notes", x: 100, y: 100, w: 400, h: 300)
        XCTAssertTrue(observe([onBuiltin]).placements.isEmpty)
    }

    func testMinimizedFullscreenAndExcludedWindowsAreNotCaptured() {
        let minimized = window(1, "com.a", x: 1600, y: 0, w: 800, h: 600, minimized: true)
        let fullscreen = window(2, "com.b", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true)
        let excluded = window(3, "com.c", x: 1600, y: 0, w: 800, h: 600)
        let observation = observe([minimized, fullscreen, excluded], excluded: ["com.c"])
        XCTAssertTrue(observation.placements.isEmpty)
        XCTAssertTrue(observation.observedApps.isEmpty, "제외한 앱은 관찰 목록에도 올리지 않는다")
    }

    func testNewPlacementsKeepWindowOrder() {
        let windows = [
            window(1, "com.b", x: 1600, y: 0, w: 800, h: 600),
            window(2, "com.a", x: 2500, y: 0, w: 800, h: 600),
            window(3, "com.c", x: 1700, y: 500, w: 800, h: 600),
        ]
        XCTAssertEqual(observe(windows).placements.map(\.bundleID), ["com.b", "com.a", "com.c"])
    }
}

// MARK: - 드리프트 방지 (F-08.4)

final class CaptureDriftTests: XCTestCase {
    private let screen = ScreenInfo(id: "ext-1", name: "LG",
                                    frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: false)

    /// 복원은 허용 오차 안에 착지하면 성공으로 기록한다(F-02.3). 그 값을 저장하면 회차마다
    /// 조금씩 밀리고, 검증은 계속 통과한다 — Memmon #19가 실물 증거다.
    func testWithinToleranceDriftIsNotWrittenBack() {
        let stored = WorkspaceSnapshot.flat(screen: screen, apps: [("com.chrome", UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))])
        let drifted = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                 frame: CGRect(x: 4, y: 4, width: 500, height: 500), windowServerID: 7)
        let after = CaptureEngine.observe(windows: [drifted], screens: [screen], snapshot: nil, base: stored,
                                          links: [stored.placements[0].id: 7], excludedBundleIDs: [], closedPlacementIDs: [])
        XCTAssertEqual(after.placements[0].unitRect.x, 0)
        XCTAssertEqual(after.placements[0].unitRect.y, 0)
    }

    func testRealMoveIsWrittenBack() {
        let stored = WorkspaceSnapshot.flat(screen: screen, apps: [("com.chrome", UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))])
        let moved = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                               frame: CGRect(x: 400, y: 0, width: 500, height: 500), windowServerID: 7)
        let after = CaptureEngine.observe(windows: [moved], screens: [screen], snapshot: nil, base: stored,
                                          links: [stored.placements[0].id: 7], excludedBundleIDs: [], closedPlacementIDs: [])
        XCTAssertEqual(after.placements[0].unitRect.x, 0.4, accuracy: 0.001)
    }
}

// MARK: - 창 대응 (D3)

final class WindowMatchingTests: XCTestCase {
    private func slot(_ id: UUID, _ x: CGFloat) -> WindowMatching.Slot {
        WindowMatching.Slot(id: id, target: CGRect(x: x, y: 0, width: 500, height: 1000))
    }

    func testNearestOneToOneAssignmentMinimizesTotalDistance() {
        let left = UUID(), right = UUID()
        let assignment = WindowMatching.assign(
            slots: [slot(left, 0), slot(right, 500)],
            candidates: [WindowMatching.Candidate(index: 0, frame: CGRect(x: 520, y: 0, width: 500, height: 1000)),
                         WindowMatching.Candidate(index: 1, frame: CGRect(x: 30, y: 0, width: 500, height: 1000))]
        )
        XCTAssertEqual(assignment, [left: 1, right: 0])
    }

    func testMoreCandidatesThanSlotsPicksOnlyTheNeededOnesAndLeavesTheRest() {
        // 저장 자리 둘·후보 셋 — 가장 적게 움직이는 둘만 고르고 남는 창은 유지한다 (W09)
        let left = UUID(), right = UUID()
        let assignment = WindowMatching.assign(
            slots: [slot(left, 0), slot(right, 500)],
            candidates: [WindowMatching.Candidate(index: 0, frame: CGRect(x: 2000, y: 0, width: 500, height: 1000)),
                         WindowMatching.Candidate(index: 1, frame: CGRect(x: 10, y: 0, width: 500, height: 1000)),
                         WindowMatching.Candidate(index: 2, frame: CGRect(x: 490, y: 0, width: 500, height: 1000))]
        )
        XCTAssertEqual(assignment, [left: 1, right: 2])
    }

    func testTieBreaksOnSizeThenStableOrder() {
        // 같은 거리면 크기 차이가 작은 쪽, 그래도 같으면 입력 순서 — 무작위로 바뀌지 않는다
        let only = UUID()
        let bigger = WindowMatching.Candidate(index: 0, frame: CGRect(x: 100, y: 0, width: 900, height: 1000))
        let closer = WindowMatching.Candidate(index: 1, frame: CGRect(x: 100, y: 0, width: 500, height: 1000))
        XCTAssertEqual(WindowMatching.assign(slots: [slot(only, 100)], candidates: [bigger, closer]), [only: 1])
        let twin = WindowMatching.Candidate(index: 2, frame: closer.frame)
        XCTAssertEqual(WindowMatching.assign(slots: [slot(only, 100)], candidates: [closer, twin]), [only: 1])
        XCTAssertEqual(WindowMatching.assign(slots: [slot(only, 100)], candidates: [twin, closer]), [only: 2])
    }

    func testFewerCandidatesThanSlotsLeavesSlotsUnassigned() {
        let a = UUID(), b = UUID()
        let assignment = WindowMatching.assign(
            slots: [slot(a, 0), slot(b, 500)],
            candidates: [WindowMatching.Candidate(index: 0, frame: CGRect(x: 480, y: 0, width: 500, height: 1000))]
        )
        XCTAssertEqual(assignment, [b: 0])
    }
}

// MARK: - 선택 복원 (F-02, US-004·005·007·008)

@MainActor
final class RestoreEngineTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("engine")
    private var gateway = FakeWindowGateway()

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1)
    private let rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)

    /// 단일 화면 복원 — 제품과 같은 RestoreSession 인터페이스의 테스트용 축약.
    private func restore(_ apps: [(String, UnitRect)], options: RestoreOptions = RestoreOptions(),
                         screens: [ScreenInfo]? = nil, snapshot: WorkspaceSnapshot? = nil,
                         library: WorkspaceLibrary? = nil) async -> RestoreResult {
        let results = await restoreAll(snapshot ?? .flat(screen: external, apps: apps),
                                       screens: screens ?? [external], options: options, library: library)
        return results.first ?? RestoreResult(screenID: external.id)
    }

    private func restoreAll(_ snapshot: WorkspaceSnapshot, screens: [ScreenInfo],
                            options: RestoreOptions = RestoreOptions(),
                            library: WorkspaceLibrary? = nil) async -> [RestoreResult] {
        let library = library ?? makeLibrary(directory: dir, records: [.with(snapshot)])
        let observation = DesktopObservation(gateway: gateway, spaceReader: nil)
        let session = RestoreSession(observation: observation, gateway: gateway, library: library)
        return await session.start(origin: .user, key: snapshot.key, screens: screens,
                                   environment: RestoreSession.Environment(options: { options }, spaceObservationEnabled: false)) ?? []
    }

    func testClosedAppIsSkippedAndNotLaunched() async {
        // 꺼둔 앱은 건너뛰고 실행하지 않는다 (US-004 AC-1) — 다시 열기 옵션은 최초 OFF
        let result = await restore([("com.slack", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .skipped(.appNotRunning))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertTrue(gateway.launchCalls.isEmpty)
    }

    func testFullscreenWindowIsLeftAlone() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true)]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .skipped(.fullscreen))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMinimizedWindowIsLeftAlone() async {
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true)]
        let result = await restore([("com.vscode", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .skipped(.minimized))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMinimizedWindowIsRestoredWhenOptedIn() async {
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true)]
        let result = await restore([("com.vscode", leftHalf)], options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertFalse(gateway.windowsList[0].isMinimized)
    }

    func testOptedInStillPrefersVisibleWindow() async {
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [
            window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true),
            window(2, "com.vscode", x: 2000, y: 100, w: 800, h: 600),
        ]
        let result = await restore([("com.vscode", leftHalf)], options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [2], "보이는 창이 저장 자리에 더 가깝다")
        XCTAssertTrue(gateway.windowsList[0].isMinimized)
    }

    func testUnminimizeRefusalFallsBackToSkip() async {
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true)]
        gateway.unminimizeFails = true
        let result = await restore([("com.vscode", leftHalf)], options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.minimized))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testUnminimizedFrameIsJudgedFresh() async {
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 2500, y: 500, w: 800, h: 600, minimized: true)]
        gateway.frameOnUnminimize[1] = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        let result = await restore([("com.vscode", leftHalf)], options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.alreadyInPlace))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testWindowAlreadyInPlaceIsNotMoved() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 1514, y: 1, w: 1278, h: 1439)]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .skipped(.alreadyInPlace))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMoveIsVerified() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 2000, y: 300, w: 800, h: 600)]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.count, 1)
        XCTAssertEqual(gateway.moveCalls[0].target, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testMinSizeConstraintRetriesOnceThenFails() async {
        gateway.runningBundleIDs = ["com.tiny"]
        gateway.windowsList = [window(1, "com.tiny", x: 2000, y: 300, w: 1400, h: 600)]
        gateway.moveBehavior = .clampWidth(min: 1400)
        let result = await restore([("com.tiny", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(gateway.moveCalls.count, 2)
    }

    func testOneFailureDoesNotStopTheRest() async {
        gateway.runningBundleIDs = ["com.a", "com.b"]
        gateway.windowsList = [
            window(1, "com.a", x: 2000, y: 300, w: 800, h: 600),
            window(2, "com.b", x: 2100, y: 400, w: 800, h: 600),
        ]
        gateway.perWindowBehavior[1] = .unresponsive
        let result = await restore([("com.a", leftHalf), ("com.b", rightHalf)])
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(result.entries[1].outcome, .moved)
        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testBuiltinWindowOfTargetAppIsNotTouched() async {
        // 대상 앱이어도 내장 화면의 창은 그대로 (US-005 AC-2) — 외장에 후보가 있으면 그 창이 더 가깝다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 100, y: 100, w: 800, h: 600),
            window(2, "com.chrome", x: 2000, y: 300, w: 800, h: 600),
        ]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [2])
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    func testDisabledAppIsNotRestoredButKept() async {
        // 체크 해제는 복원 제외일 뿐 삭제가 아니다 (US-006 AC-2)
        gateway.runningBundleIDs = ["com.slack"]
        gateway.windowsList = [window(1, "com.slack", x: 2000, y: 300, w: 800, h: 600)]
        let snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.slack", leftHalf)])
        var record = WorkspaceRecord.with(snapshot)
        record.apps[0].isEnabled = false
        let library = makeLibrary(directory: dir, records: [record])
        let result = await restore([], snapshot: snapshot, library: library)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(library.saved(for: snapshot.key)?.placements.count, 1)
    }

    func testSkipReasonPrefersFullscreenRegardlessOfWindowOrder() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 1600, y: 0, w: 800, h: 600, minimized: true),
            window(2, "com.chrome", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true),
        ]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .skipped(.fullscreen))
    }

    func testSilentMoveFailureIsDetected() async {
        gateway.runningBundleIDs = ["com.stuck"]
        gateway.windowsList = [window(1, "com.stuck", x: 2000, y: 300, w: 800, h: 600)]
        gateway.moveBehavior = .silentFail
        let result = await restore([("com.stuck", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(gateway.moveCalls.count, 2)
    }

    func testResultCarriesScreenID() async {
        let result = await restore([("com.x", leftHalf)])
        XCTAssertEqual(result.screenID, external.id)
    }

    func testWindowOnBuiltinIsPulledBackToExternal() async {
        // 연결 해제로 내장에 내려온 창을 데려온다 (요구사항 다, US-001 핵심 시나리오)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 100, y: 100, w: 800, h: 600)]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls[0].target, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testRunningAppWithNoWindowsIsSkippedByDefault() async {
        // 실행 중인데 표준 창이 없으면 건너뛴다 — 실험실 최초 OFF에서는 새 창을 열게 하지 않는다
        gateway.runningBundleIDs = ["com.chrome"]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries[0].outcome, .skipped(.noWindow))
        XCTAssertTrue(gateway.openWindowCalls.isEmpty)
    }

    func testTwoWindowsOfOneAppRestoreToTheirOwnPlacements() async {
        // 같은 앱의 창 둘 — 앱 전역 선점 없이 각자 가까운 자리로 (D1·D3, R2)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 2900, y: 100, w: 800, h: 600),  // 오른쪽에 가까움
            window(2, "com.chrome", x: 1600, y: 100, w: 800, h: 600),  // 왼쪽에 가까움
        ]
        let result = await restore([("com.chrome", leftHalf), ("com.chrome", rightHalf)])
        XCTAssertEqual(result.entries.map(\.outcome), [.moved, .moved])
        XCTAssertEqual(gateway.windowsList.first { $0.id == 2 }?.frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
        XCTAssertEqual(gateway.windowsList.first { $0.id == 1 }?.frame, CGRect(x: 2792, y: 0, width: 1280, height: 1440))
    }

    func testExtraWindowsStayWhereTheyAre() async {
        // 저장 자리보다 창이 많으면 필요한 만큼만 고르고 나머지는 유지한다 (W09)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 1600, y: 100, w: 800, h: 600),
            window(2, "com.chrome", x: 3200, y: 500, w: 800, h: 600),
        ]
        let result = await restore([("com.chrome", leftHalf)])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1])
    }

    func testAmbiguousCandidatesWaitForTheUserWhenDirectAssignmentIsOn() async {
        // 직접 지정 ON — 모호한 후보는 자동 배정하지 않고 확인 필요로 남긴다 (W27)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 1600, y: 100, w: 800, h: 600),
            window(2, "com.chrome", x: 3200, y: 500, w: 800, h: 600),
        ]
        let result = await restore([("com.chrome", leftHalf)], options: RestoreOptions(directAssignment: true))
        XCTAssertEqual(result.entries[0].outcome, .needsConfirmation(.ambiguousCandidates([101, 102])))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testDirectAssignmentDoesNotAskWhenTheCandidateIsUnambiguous() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 2000, y: 300, w: 800, h: 600)]
        let result = await restore([("com.chrome", leftHalf)], options: RestoreOptions(directAssignment: true))
        XCTAssertEqual(result.entries[0].outcome, .moved)
    }

    func testClosedInWorkspacePlacementIsSkippedEvenWhenReopenIsOn() async {
        // 같은 환경에서 닫은 창의 자리는 다음 저장까지 제외 — 다시 열기 옵션도 이를 해제하지 않는다 (D9·W30)
        gateway.runningBundleIDs = ["com.chrome"]
        let snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.chrome", leftHalf)])
        let library = makeLibrary(directory: dir, records: [.with(snapshot, closed: [snapshot.placements[0].id])])
        let result = await restore([], options: RestoreOptions(reopenClosedApps: true, reviveWindowlessApps: true),
                                   snapshot: snapshot, library: library)
        XCTAssertEqual(result.entries[0].outcome, .skipped(.closedInWorkspace))
        XCTAssertTrue(gateway.openWindowCalls.isEmpty)
    }

    func testUnknownClosureHoldsCreationAndAsksForConfirmation() async {
        // 연결 정보가 없는(재실행 뒤 등) 빈 자리는 닫힌 환경을 알 수 없다 — 옵션 ON이어도 실행·생성을 보류한다 (W21)
        gateway.launchable = ["com.slack"]
        let result = await restore([("com.slack", leftHalf)],
                                   options: RestoreOptions(reopenClosedApps: true, reviveWindowlessApps: true, openMissingWindows: true))
        XCTAssertEqual(result.entries[0].outcome, .needsConfirmation(.closureUnknown))
        XCTAssertTrue(gateway.launchCalls.isEmpty)
    }

    func testLostElsewhereLaunchesTheAppWhenReopenIsOn() async {
        // 다른 환경에서 닫힌 창의 자리는 유지되고, 부모 옵션 ON이면 앱을 실행해 창을 배치한다 (W19·W12)
        let snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.slack", leftHalf)])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        library.confirmLink(placementID: snapshot.placements[0].id, bundleID: "com.slack", windowServerID: 501)
        library.noteAppTerminated("com.slack", currentKey: WorkspaceKey(screenIDs: ["elsewhere"]))
        gateway.windowsOnLaunch["com.slack"] = [window(3, "com.slack", x: 2500, y: 500, w: 800, h: 600)]

        let off = await restore([], snapshot: snapshot, library: library)
        XCTAssertEqual(off.entries[0].outcome, .skipped(.appNotRunning), "부모 OFF면 실행하지 않는다 (W22)")
        XCTAssertTrue(gateway.launchCalls.isEmpty)

        let on = await restore([], options: RestoreOptions(reopenClosedApps: true), snapshot: snapshot, library: library)
        XCTAssertEqual(gateway.launchCalls, ["com.slack"])
        XCTAssertEqual(on.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testReviveRequiresItsOwnToggleAndIsNotBypassedByAdditionalWindows() async {
        // 실행 중·창 0개: 되살리기 OFF면 추가 열기 ON이어도 창을 만들지 않는다 (W13)
        let snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.chrome", leftHalf)])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        library.confirmLink(placementID: snapshot.placements[0].id, bundleID: "com.chrome", windowServerID: 501)
        library.trackLinks(sample: DesktopObservation.Sample(sequence: 1, windows: [], unavailableBundleIDs: [], spaceAvailability: nil,
                                                             existingWindowServerIDs: []),
                           currentKey: nil) // 외장 없는 동안 창이 닫힘 (W20)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowOnReopen["com.chrome"] = window(2, "com.chrome", x: 2500, y: 500, w: 800, h: 600)
        gateway.additionalWindows["com.chrome"] = [window(3, "com.chrome", x: 2500, y: 500, w: 800, h: 600)]

        let bypass = await restore([], options: RestoreOptions(reopenClosedApps: true, openMissingWindows: true),
                                   snapshot: snapshot, library: library)
        XCTAssertEqual(bypass.entries[0].outcome, .skipped(.noWindow))
        XCTAssertTrue(gateway.openWindowCalls.isEmpty)
        XCTAssertTrue(gateway.additionalWindowCalls.isEmpty)

        let revive = await restore([], options: RestoreOptions(reopenClosedApps: true, reviveWindowlessApps: true),
                                   snapshot: snapshot, library: library)
        XCTAssertEqual(gateway.openWindowCalls, ["com.chrome"])
        XCTAssertEqual(revive.entries[0].outcome, .moved)
    }

    func testAdditionalWindowsFillOnlyTheShortfall() async {
        // 창 하나에 자리 둘 — 추가 열기 ON이면 부족한 하나만 더 연다 (W10)
        let snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.chrome", leftHalf), ("com.chrome", rightHalf)])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        library.confirmLink(placementID: snapshot.placements[1].id, bundleID: "com.chrome", windowServerID: 502)
        library.trackLinks(sample: DesktopObservation.Sample(sequence: 1, windows: [], unavailableBundleIDs: [], spaceAvailability: nil,
                                                             existingWindowServerIDs: []),
                           currentKey: WorkspaceKey(screenIDs: ["other"]))
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 1600, y: 100, w: 800, h: 600)]
        gateway.additionalWindows["com.chrome"] = [window(9, "com.chrome", x: 2500, y: 500, w: 800, h: 600)]

        let result = await restore([], options: RestoreOptions(reopenClosedApps: true, openMissingWindows: true),
                                   snapshot: snapshot, library: library)
        XCTAssertEqual(gateway.additionalWindowCalls, ["com.chrome"])
        XCTAssertEqual(result.entries.map(\.outcome), [.moved, .moved])
    }

    func testCreationFailureIsReportedAsConfirmationNotSuccess() async {
        let snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.slack", leftHalf)])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        library.confirmLink(placementID: snapshot.placements[0].id, bundleID: "com.slack", windowServerID: 501)
        library.noteAppTerminated("com.slack", currentKey: nil)
        gateway.launchable = ["com.slack"] // 실행은 되지만 창이 나타나지 않는다
        let result = await restore([], options: RestoreOptions(reopenClosedApps: true), snapshot: snapshot, library: library)
        XCTAssertEqual(gateway.launchCalls, ["com.slack"])
        XCTAssertEqual(result.entries[0].outcome, .needsConfirmation(.windowCreationFailed))
    }

    func testFingerprintMismatchSkipsScreenWhole() async {
        let mismatched = ScreenInfo(id: external.id, name: external.name, frame: external.frame,
                                    isBuiltin: false,
                                    fingerprint: ScreenFingerprint(vendor: 1, model: 2, serial: 999))
        var snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.chrome", leftHalf)])
        snapshot.screens[0].fingerprint = ScreenFingerprint(vendor: 1, model: 2, serial: 3)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 2000, y: 300, w: 800, h: 600)]

        let results = await restoreAll(snapshot, screens: [mismatched])
        XCTAssertEqual(results[0].screenSkipReason, .fingerprintMismatch)
        XCTAssertTrue(results[0].entries.isEmpty)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testSameAppOnTwoScreensRestoresBothWindows() async {
        // 두 화면의 같은 앱 창은 각각의 자리로 간다 — 화면 순서 선점은 없다 (W03, R2)
        let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        let key = WorkspaceKey(screenIDs: [external.id, external2.id])
        let snapshot = WorkspaceSnapshot(
            key: key,
            screens: [ScreenRecord(id: external.id, name: external.name), ScreenRecord(id: external2.id, name: external2.name)],
            placements: [
                WindowPlacement(bundleID: "com.chrome", displayName: "com.chrome", screenID: external.id, space: nil, unitRect: leftHalf),
                WindowPlacement(bundleID: "com.chrome", displayName: "com.chrome", screenID: external2.id, space: nil, unitRect: leftHalf),
            ], savedAt: Date()
        )
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 2500, y: 500, w: 800, h: 600),  // ext-1 — 어질러짐
            window(2, "com.chrome", x: 4500, y: 300, w: 800, h: 600),  // ext-2 — 어질러짐
        ]
        let results = await restoreAll(snapshot, screens: [external2, external])
        XCTAssertEqual(results.map(\.screenID), [external.id, external2.id])
        XCTAssertEqual(Set(gateway.moveCalls.map(\.windowID)), [1, 2])
        XCTAssertEqual(results[1].entries.first?.outcome, .moved)
    }
}
