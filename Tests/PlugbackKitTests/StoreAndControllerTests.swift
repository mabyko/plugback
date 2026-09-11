import XCTest
@testable import PlugbackKit

final class ProfileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = temporaryDirectory("store")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private let screen = ScreenInfo(id: "ext-1", name: "LG", frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: false)

    func testRoundTrip() throws {
        let store = ProfileStore(directory: dir)
        let snapshot = WorkspaceSnapshot.flat(screen: screen, apps: [("com.chrome", UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))])
        var record = WorkspaceRecord.with(snapshot)
        record.closedPlacementIDs = [snapshot.placements[0].id]
        try store.save([snapshot.key: record])
        let outcome = ProfileStore(directory: dir).load()
        XCTAssertEqual(outcome.workspaces, [snapshot.key: record])
        XCTAssertNil(outcome.trouble)
        XCTAssertFalse(outcome.migratedFromLegacy)
    }

    func testCorruptedFileIsBackedUpAndReset() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{{{ not json".utf8).write(to: dir.appendingPathComponent("workspaces.json"))

        let outcome = ProfileStore(directory: dir).load()
        XCTAssertTrue(outcome.workspaces.isEmpty)
        guard case .corruptionBackedUp(let backupURL) = try XCTUnwrap(outcome.trouble) else {
            return XCTFail("\(String(describing: outcome.trouble))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspaces.json").path))
    }

    func testUnreadableFileIsReportedNotTreatedAsFirstRun() throws {
        let fileAsDir = dir.appendingPathComponent("workspaces.json")
        try FileManager.default.createDirectory(at: fileAsDir, withIntermediateDirectories: true)
        let outcome = ProfileStore(directory: dir).load()
        XCTAssertTrue(outcome.workspaces.isEmpty)
        XCTAssertEqual(outcome.trouble, .unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileAsDir.path))
    }

    func testNewerFileVersionIsPreservedAndBlocksWrites() throws {
        // 이후 버전의 형식은 손상이 아니다 — 원본을 보존하고 쓰기를 막는다 (DSK10)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "workspaces": {}}"#.utf8).write(to: dir.appendingPathComponent("workspaces.json"))
        let outcome = ProfileStore(directory: dir).load()
        XCTAssertEqual(outcome.trouble, .unsupportedVersion(99))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspaces.json").path))
    }

    func testWriteFailureIsReported() throws {
        let store = ProfileStore(directory: dir)
        _ = store.load()
        try Data("not-a-directory".utf8).write(to: dir)
        XCTAssertThrowsError(try store.save([:]))
    }

    func testLegacyProfilesMigrateToSingleScreenWorkspacesAndTheOriginalStays() throws {
        // 구버전 화면별 프로필 → 화면 하나짜리 작업 환경. 조합·Space 정보는 지어내지 않고 원본은 그대로 둔다 (DSK05)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manual = Profile(screenID: "ext-1", screenName: "LG", apps: [
            TargetApp(bundleID: "com.chrome", displayName: "Chrome", isEnabled: false,
                      unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
            TargetApp(bundleID: "com.slack", displayName: "Slack", unitRect: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ], fingerprint: ScreenFingerprint(vendor: 1, model: 2, serial: 3), savedAt: Date(timeIntervalSince1970: 100))
        let auto = Profile(screenID: "ext-1", screenName: "LG", apps: [
            TargetApp(bundleID: "com.chrome", displayName: "Chrome", unitRect: UnitRect(x: 0.25, y: 0, width: 0.5, height: 1)),
        ], savedAt: Date(timeIntervalSince1970: 200))
        let autoOnly = Profile(screenID: "ext-3", screenName: "LG ULTRAFINE", apps: [
            TargetApp(bundleID: "com.slack", displayName: "Slack", unitRect: UnitRect(x: 0, y: 0, width: 1, height: 1)),
        ], savedAt: Date(timeIntervalSince1970: 300))
        let legacy = try JSONEncoder().encode(["ext-1": manual, "ext-1#auto": auto,
                                              "ext-2": Profile(screenID: "ext-2", screenName: "DELL"),
                                              "ext-3#auto": autoOnly])
        try legacy.write(to: dir.appendingPathComponent("profiles.json"))

        let plain = ProfileStore(directory: dir).load()
        XCTAssertTrue(plain.migratedFromLegacy)
        XCTAssertEqual(Set(plain.workspaces.keys), [WorkspaceKey(screenIDs: ["ext-1"]), WorkspaceKey(screenIDs: ["ext-2"])])
        let record = try XCTUnwrap(plain.workspaces[WorkspaceKey(screenIDs: ["ext-1"])])
        XCTAssertEqual(record.saved?.savedBy, .manual, "옛 자동 슬롯 선택이 없었으면 수동 프로필이다")
        XCTAssertEqual(record.saved?.placements.map(\.bundleID), ["com.chrome", "com.slack"])
        XCTAssertNil(record.saved?.placements.first?.space, "Space 정보를 지어내지 않는다")
        XCTAssertEqual(record.apps.first { $0.bundleID == "com.chrome" }?.isEnabled, false, "제외 선택은 보존된다")
        XCTAssertEqual(record.saved?.screens.first?.fingerprint, manual.fingerprint)

        XCTAssertNil(plain.workspaces[WorkspaceKey(screenIDs: ["ext-3"])], "자동 슬롯이 꺼져 있었으면 자동 슬롯만 있는 화면은 옛 규칙대로 쓰지 않는다")

        let withAuto = ProfileStore(directory: dir).load(preferLegacyAutoSlots: true)
        XCTAssertEqual(withAuto.workspaces[WorkspaceKey(screenIDs: ["ext-1"])]?.saved?.savedBy, .auto,
                       "옛 자동 슬롯이 켜져 있었고 더 최근이면 그 기록이 복원 소스였다")
        XCTAssertEqual(withAuto.workspaces[WorkspaceKey(screenIDs: ["ext-3"])]?.saved?.placements.map(\.bundleID), ["com.slack"],
                       "자동 슬롯만 있는 화면도 자동 슬롯이 켜져 있었으면 가져온다")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("profiles.json")), legacy, "원본 파일은 건드리지 않는다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspaces.json").path))
    }
}

private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                 frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let external = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                  frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
private let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)

@MainActor
final class PlugbackControllerTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("controller")
    private var gateway = FakeWindowGateway()
    private var screens: FakeScreenProvider = {
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, external]
        return provider
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private lazy var testDefaults = UserDefaults(suiteName: "plugback-tests-\(UUID().uuidString)")!

    private func makeController() -> PlugbackController {
        PlugbackController(gateway: gateway, screenProvider: screens,
                           store: ProfileStore(directory: dir), defaults: testDefaults)
    }

    private func chrome(_ id: Int = 1, at frame: CGRect) -> WindowInfo {
        WindowInfo(id: id, appBundleID: "com.chrome", appName: "Chrome", frame: frame, windowServerID: CGWindowID(100 + id))
    }
    private let saved = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
    private let messy = CGRect(x: 2500, y: 500, width: 800, height: 600)

    func testCaptureThenRestoreRoundTrip() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        let awaited1 = await controller.captureNow()
        XCTAssertEqual(awaited1, .captured(appCount: 1, windowCount: 1))
        XCTAssertEqual(controller.sections.first?.apps.map(\.bundleID), ["com.chrome"])

        gateway.windowsList[0] = chrome(at: messy)
        await controller.restoreNow()
        XCTAssertEqual(controller.sections.first?.lastResult?.movedCount, 1)
        XCTAssertEqual(gateway.windowsList[0].frame, saved)
    }

    func testProfileSurvivesRelaunch() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let first = makeController()
        await first.captureNow()

        let second = makeController()
        await second.cardOpened()
        XCTAssertEqual(second.sections.first?.apps.map(\.bundleID), ["com.chrome"])
    }

    func testRestoreWithoutASnapshotMovesNothing() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: messy)]
        let controller = makeController()
        let awaited2 = await controller.restoreNow()
        XCTAssertEqual(awaited2, .restored([]))
        XCTAssertNil(controller.sections.first?.lastResult)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testDisconnectKeepsLastScreenAndSnapshot() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()

        screens.screensList = [builtin]
        await controller.cardOpened()
        XCTAssertEqual(controller.screenPresence, .remembered(screenID: "ext-1", name: "LG UltraFine 27"))
        XCTAssertEqual(controller.sections.first?.apps.count, 1)
        XCTAssertTrue(controller.hasRestorableProfile)
    }

    func testSectionsCoverEveryConnectedScreen() async {
        screens.screensList = [builtin, external, external2]
        gateway.runningBundleIDs = ["com.orca", "com.slack"]
        gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "com.orca", appName: "Orca", frame: saved, windowServerID: 101),
            WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack",
                       frame: CGRect(x: 4072, y: 0, width: 960, height: 1080), windowServerID: 102),
        ]
        let controller = makeController()
        await controller.captureNow()

        var sections = controller.sections
        XCTAssertEqual(sections.map(\.screenID), ["ext-1", "ext-2"])
        XCTAssertEqual(sections[0].apps.map(\.bundleID), ["com.orca"])
        XCTAssertEqual(sections[1].apps.map(\.bundleID), ["com.slack"])
        gateway.runningBundleIDs.insert("com.figma")
        gateway.windowsList.append(WindowInfo(id: 3, appBundleID: "com.figma", appName: "Figma",
                                              frame: CGRect(x: 4500, y: 100, width: 800, height: 600), windowServerID: 103))
        await controller.cardOpened()
        sections = controller.sections
        XCTAssertEqual(sections[0].presentApps.map(\.bundleID), ["com.orca"])
        XCTAssertEqual(sections[1].presentApps.map { ($0.bundleID, $0.isSaved) }.map { "\($0.0):\($0.1)" }, ["com.slack:true", "com.figma:false"],
                       "아직 저장하지 않은 앱도 지금 화면에 있으면 첫 묶음에 「저장 전」으로 보인다 (D4)")
        XCTAssertTrue(sections[1].excludedApps.isEmpty)

        gateway.windowsList[1] = WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack", frame: messy, windowServerID: 102)
        await controller.restoreNow()
        XCTAssertEqual(controller.lastResults.map(\.screenID), ["ext-1", "ext-2"])
        XCTAssertEqual(controller.sections[1].lastResult?.movedCount, 1)
        XCTAssertNotNil(controller.lastRestoredAt)
    }

    func testSharedAppOnTwoScreensRestoresBothWindows() async {
        // 같은 앱이 두 화면에 저장돼 있으면 창마다 자기 자리로 간다 — 첫 화면 선점이 없다 (W03)
        screens.screensList = [builtin, external2, external]
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            chrome(1, at: saved),
            chrome(2, at: CGRect(x: 4072, y: 0, width: 960, height: 1080)),
        ]
        let controller = makeController()
        await controller.captureNow()
        guard case .connected(let first, let count) = controller.screenPresence else { return XCTFail() }
        XCTAssertEqual(first.id, "ext-1")
        XCTAssertEqual(count, 2)

        gateway.windowsList[0] = chrome(1, at: messy)
        gateway.windowsList[1] = chrome(2, at: CGRect(x: 4500, y: 300, width: 800, height: 600))
        await controller.restoreNow()
        XCTAssertEqual(controller.sections[0].lastResult?.entries.first?.outcome, .moved)
        XCTAssertEqual(controller.sections[1].lastResult?.entries.first?.outcome, .moved)
    }

    func testUncheckingAnAppAppliesToTheWholeWorkspaceAndKeepsItsRecords() async {
        // 앱 포함·제외는 작업 환경에 공유된다 (D4). 제외해도 기록은 남고, 다시 켜면 저장돼 있던 자리다 (US-006 AC-2)
        screens.screensList = [builtin, external, external2]
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(1, at: saved), chrome(2, at: CGRect(x: 4072, y: 0, width: 960, height: 1080))]
        let controller = makeController()
        await controller.captureNow()

        await controller.setTracked("com.chrome", false, on: "ext-2")
        XCTAssertTrue(controller.sections[0].apps.isEmpty)
        XCTAssertTrue(controller.sections[1].apps.isEmpty)
        XCTAssertEqual(controller.sections[1].excludedApps.map(\.bundleID), ["com.chrome"])
        XCTAssertTrue(controller.sections[1].presentApps.isEmpty, "제외한 앱은 지금 화면에 있어도 첫 묶음에 없다")

        gateway.windowsList[0] = chrome(1, at: messy)
        await controller.setTracked("com.chrome", true, on: "ext-1")
        XCTAssertEqual(controller.sections[0].apps.map(\.bundleID), ["com.chrome"])
        await controller.restoreNow()
        XCTAssertEqual(gateway.windowsList[0].frame, saved, "예전 자리 그대로")
    }

    func testCheckingAnUntrackedAppIncludesItInTheNextSave() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        await controller.setTracked("com.chrome", false, on: external.id)

        gateway.runningBundleIDs.insert("com.linear")
        gateway.windowsList.append(WindowInfo(id: 2, appBundleID: "com.linear", appName: "Linear",
                                              frame: CGRect(x: 2792, y: 0, width: 1280, height: 1440), windowServerID: 102))
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.excludedApps.map(\.bundleID), ["com.chrome"])
        XCTAssertEqual(controller.sections.first?.presentApps.map(\.bundleID), ["com.linear"])
        XCTAssertEqual(controller.sections.first?.presentApps.first?.isSaved, false)

        await controller.captureNow()
        XCTAssertEqual(controller.sections.first?.apps.map(\.bundleID), ["com.linear"], "제외한 앱만 빠지고 새 앱은 기본 포함이다 (D4)")
    }

    func testRemovingAnAppForgetsItUntilItIsSeenAgain() async {
        gateway.runningBundleIDs = ["cc.ffitch.shottr"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "cc.ffitch.shottr", appName: "Shottr",
                                          frame: CGRect(x: 1800, y: 100, width: 800, height: 600), windowServerID: 101)]
        let controller = makeController()
        await controller.captureNow()
        await controller.setTracked("cc.ffitch.shottr", false, on: external.id)

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "cc.ffitch.shottr", appName: "Shottr",
                                            frame: CGRect(x: 100, y: 100, width: 800, height: 600), windowServerID: 101)
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.excludedApps.map(\.bundleID), ["cc.ffitch.shottr"],
                       "제외한 앱은 창이 내장에 있어도 기록이 있는 화면에 보인다")

        await controller.remove("cc.ffitch.shottr", on: external.id)
        XCTAssertTrue(controller.sections.first?.apps.isEmpty ?? false)
        XCTAssertTrue(controller.sections.first?.excludedApps.isEmpty ?? false)
        XCTAssertTrue(controller.sections.first?.presentApps.isEmpty ?? false)

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "cc.ffitch.shottr", appName: "Shottr",
                                            frame: CGRect(x: 1800, y: 100, width: 800, height: 600), windowServerID: 101)
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.presentApps.map(\.bundleID), ["cc.ffitch.shottr"], "잊은 앱이 다시 보이면 기본 포함이다")
        XCTAssertEqual(controller.sections.first?.presentApps.first?.isSaved, false)
    }

    func testSectionsGroupAppsByPresenceAndKeepAbsentSavedAppsRestorable() async {
        // 첫 묶음은 지금 화면의 앱, 저장만 된 앱은 접힌 묶음, 제외한 앱은 별도 묶음 — 어디에도 없는 제외 앱은 첫 화면에 모인다
        screens.screensList = [builtin, external, external2]
        gateway.runningBundleIDs = ["com.chrome", "com.slack", "com.keka"]
        gateway.windowsList = [
            chrome(1, at: saved),
            WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack", frame: CGRect(x: 4072, y: 0, width: 960, height: 1080), windowServerID: 102),
            WindowInfo(id: 3, appBundleID: "com.keka", appName: "Keka", frame: CGRect(x: 4200, y: 100, width: 400, height: 300), windowServerID: 103),
        ]
        let controller = makeController()
        await controller.captureNow()
        await controller.setTracked("com.keka", false, on: "ext-2")

        gateway.runningBundleIDs = ["com.chrome", "com.notes"]
        gateway.windowsList = [
            chrome(1, at: saved),
            WindowInfo(id: 4, appBundleID: "com.notes", appName: "Notes", frame: CGRect(x: 4200, y: 100, width: 400, height: 300), windowServerID: 104),
        ]
        await controller.cardOpened()
        let sections = controller.sections
        XCTAssertEqual(sections[0].presentApps.map(\.bundleID), ["com.chrome"])
        XCTAssertTrue(sections[0].absentSavedApps.isEmpty)
        XCTAssertEqual(sections[1].presentApps.map { "\($0.bundleID):\($0.isSaved)" }, ["com.notes:false"])
        XCTAssertEqual(sections[1].absentSavedApps.map(\.bundleID), ["com.slack"], "창이 없어도 저장 기록은 복원 대상으로 남는다")
        XCTAssertEqual(sections[1].excludedApps.map(\.bundleID), ["com.keka"], "제외한 앱은 기록이 있는 화면에 보인다")
        XCTAssertTrue(sections[0].excludedApps.isEmpty)

        await controller.remove("com.keka", on: "ext-2")
        await controller.setTracked("com.keka", false, on: "ext-2") // 기록·창이 어디에도 없는 제외 앱
        XCTAssertEqual(controller.sections[0].excludedApps.map(\.bundleID), ["com.keka"], "어느 화면에도 없는 제외 앱은 첫 화면에 모인다")
        XCTAssertTrue(controller.sections[1].excludedApps.isEmpty)
    }

    func testAWorkspaceWithoutASnapshotDoesNotBorrowAnotherWorkspace() async {
        // B 단독 저장본은 A+B 환경의 저장본이 아니다 (D5·G21)
        screens.screensList = [builtin, external2]
        gateway.runningBundleIDs = ["com.slack"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.slack", appName: "Slack",
                                          frame: CGRect(x: 4072, y: 0, width: 960, height: 1080), windowServerID: 101)]
        let controller = makeController()
        await controller.captureNow()

        screens.screensList = [builtin, external, external2]
        await controller.cardOpened()
        XCTAssertFalse(controller.hasRestorableProfile)
        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.slack", appName: "Slack", frame: messy, windowServerID: 101)
        let awaited3 = await controller.restoreNow()
        XCTAssertEqual(awaited3, .restored([]))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(controller.allWorkspaces.map(\.key), [WorkspaceKey(screenIDs: ["ext-2"])], "B 단독 저장본은 그대로다")
    }

    func testSettingsFlowIntoRestoreOptions() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome", frame: messy,
                                            isMinimized: true, windowServerID: 101)
        await controller.restoreNow()
        XCTAssertEqual(controller.sections.first?.lastResult?.entries.first?.outcome, .skipped(.minimized))
        controller.restoreMinimized = true
        await controller.restoreNow()
        XCTAssertEqual(controller.sections.first?.lastResult?.entries.first?.outcome, .moved)
    }

    func testChildLabOptionsHaveNoEffectWhileTheParentIsOff() async {
        // 부모 OFF는 실행·명시적 창 생성 전체를 막는다 (3.5절)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        controller.reviveWindowlessApps = true
        controller.openMissingWindows = true
        gateway.windowsList = []
        gateway.windowOnReopen["com.chrome"] = chrome(2, at: messy)
        await controller.restoreNow()
        XCTAssertTrue(gateway.openWindowCalls.isEmpty)
        XCTAssertEqual(controller.sections.first?.lastResult?.entries.first?.outcome, .skipped(.noWindow))

        await controller.collectCandidate() // 같은 환경에서 닫힌 것을 관찰했다
        controller.reopenClosedApps = true
        await controller.restoreNow()
        XCTAssertTrue(gateway.openWindowCalls.isEmpty)
        XCTAssertEqual(controller.sections.first?.lastResult?.entries.first?.outcome, .skipped(.closedInWorkspace),
                       "같은 환경에서 닫은 창의 자리는 다시 열기 ON이어도 채우지 않는다 (D9)")
    }

    // MARK: 복원 진행 중의 상호배제

    private func startHangingRestore(_ controller: PlugbackController) async -> Task<RestoreOutcome, Never> {
        gateway.standardWindowsDelay = 0.05
        let before = gateway.standardWindowsCalls
        let task = Task { await controller.restoreNow() }
        while gateway.standardWindowsCalls == before { await Task.yield() }
        return task
    }

    func testCaptureDuringRestoreIsRejected() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        await controller.cardOpened()
        let before = controller.allWorkspaces

        let restore = await startHangingRestore(controller)
        gateway.windowsList = [chrome(9, at: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        let awaited4 = await controller.captureNow()
        XCTAssertEqual(awaited4, .restoringInProgress)
        XCTAssertEqual(controller.allWorkspaces, before)
        XCTAssertNil(controller.lastCaptureCount)
        _ = await restore.value
    }

    func testRestoreDuringRestoreReportsBusy() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        let restore = await startHangingRestore(controller)
        let awaited5 = await controller.restoreNow()
        XCTAssertEqual(awaited5, .alreadyRestoring)
        _ = await restore.value
    }

    func testRemoveWorkspaceDuringRestoreDoesNotResurrectResult() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        let restore = await startHangingRestore(controller)
        controller.removeWorkspace(WorkspaceKey(screenIDs: ["ext-1"]))
        _ = await restore.value
        XCTAssertNil(controller.sections.first?.lastResult)
    }

    func testCardOpenDuringRestoreDoesNotReenumerate() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: messy)]
        let controller = makeController()
        await controller.captureNow()
        gateway.windowsList[0] = chrome(at: saved)
        let restore = await startHangingRestore(controller)
        let callsBefore = gateway.standardWindowsCalls
        await controller.cardOpened()
        XCTAssertEqual(gateway.standardWindowsCalls, callsBefore)
        let outcome = await restore.value
        guard case .restored(let results) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(results.first?.entries.first?.outcome, .moved)
    }

    func testScreenConnectedDuringRestoreSwitchesToTheNewWorkspaceAfterward() async {
        // 복원 중 B가 추가되면 남은 A 작업을 중단하고 준비된 A+B 저장본으로 전환한다 (G05)
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow() // A 단독
        screens.screensList = [builtin, external, external2]
        let slackSaved = CGRect(x: 4072, y: 0, width: 960, height: 1080)
        gateway.windowsList.append(WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack", frame: slackSaved, windowServerID: 102))
        await controller.cardOpened()
        await controller.captureNow() // A+B
        screens.screensList = [builtin, external]
        await controller.workspaceChanged()

        gateway.windowsList[0] = chrome(at: messy)
        let restore = await startHangingRestore(controller)
        screens.screensList = [builtin, external, external2]
        gateway.windowsList[1] = WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack",
                                            frame: CGRect(x: 4500, y: 300, width: 800, height: 600), windowServerID: 102)
        await controller.externalScreensAppeared()
        _ = await restore.value

        XCTAssertEqual(gateway.windowsList.first { $0.appBundleID == "com.slack" }?.frame, slackSaved)
        XCTAssertEqual(gateway.windowsList.first { $0.appBundleID == "com.chrome" }?.frame, saved)
        XCTAssertTrue(controller.lastResults.contains { $0.screenID == "ext-2" })
    }

    func testFreshLaunchShowsStoredScreenName() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let first = makeController()
        await first.captureNow()

        screens.screensList = [builtin]
        let second = makeController()
        await second.cardOpened()
        XCTAssertEqual(second.screenPresence, .remembered(screenID: "ext-1", name: "LG UltraFine 27"))
    }

    func testFingerprintMismatchBlocksRestore() async {
        let fpA = ScreenFingerprint(vendor: 1, model: 2, serial: 3)
        let fpB = ScreenFingerprint(vendor: 1, model: 2, serial: 999)
        let screenA = ScreenInfo(id: "ext-1", name: "LG", frame: external.frame, isBuiltin: false, fingerprint: fpA)
        screens.screensList = [builtin, screenA]
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()

        screens.screensList = [builtin, ScreenInfo(id: "ext-1", name: "LG", frame: external.frame, isBuiltin: false, fingerprint: fpB)]
        gateway.windowsList[0] = chrome(at: messy)
        await controller.restoreNow()
        XCTAssertTrue(controller.identityMismatch)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testAutoModeRestoresWhenScreenAppears() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        gateway.windowsList[0] = chrome(at: messy)
        await controller.externalScreensAppeared()
        XCTAssertEqual(controller.sections.first?.lastResult?.movedCount, 1)
    }

    func testLaunchWithScreensAlreadyConnectedDoesNotRestore() async {
        // 앱 실행 자체로 복원하지 않는다 — 연결된 화면은 기준선일 뿐이다 (D8·G19)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let first = makeController()
        await first.captureNow()
        gateway.windowsList[0] = chrome(at: messy)
        let second = makeController()
        second.startWatching()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        await second.workspaceChanged() // 같은 환경의 반복 알림도 복원이 아니다
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testManualModeDoesNotRestoreOnConnectAndCancelsAutomaticWaits() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        controller.restoreMode = .manual
        gateway.windowsList[0] = chrome(at: messy)
        await controller.externalScreensAppeared()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testUnauthorizedBlocksAutoRestore() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        controller.authorizationCheck = { false }
        gateway.windowsList[0] = chrome(at: messy)
        await controller.externalScreensAppeared()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testUnauthorizedBlocksEveryCommand() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        controller.authorizationCheck = { false }
        gateway.windowsList[0] = chrome(at: messy)
        let awaited6 = await controller.restoreNow()
        XCTAssertEqual(awaited6, .notAuthorized)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertFalse(controller.isAuthorized)
        let before = controller.allWorkspaces
        let awaited7 = await controller.captureNow()
        XCTAssertEqual(awaited7, .notAuthorized)
        XCTAssertEqual(controller.allWorkspaces, before)
    }

    func testSettingsPersist() {
        let first = makeController()
        first.restoreMode = .manual
        first.autoSave = false
        first.reopenClosedApps = true
        first.openMissingWindows = true
        first.directWindowAssignment = true
        let second = makeController()
        XCTAssertEqual(second.restoreMode, .manual)
        XCTAssertFalse(second.autoSave)
        XCTAssertTrue(second.reopenClosedApps)
        XCTAssertFalse(second.reviveWindowlessApps, "부모 ON이 하위 값을 켜지 않는다 (W23)")
        XCTAssertTrue(second.openMissingWindows)
        XCTAssertTrue(second.directWindowAssignment)
    }

    func testRemoveWorkspaceDeletesAndPersists() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        XCTAssertEqual(controller.allWorkspaces.count, 1)

        controller.removeWorkspace(WorkspaceKey(screenIDs: ["ext-1"]))
        XCTAssertTrue(controller.allWorkspaces.isEmpty)
        XCTAssertFalse(controller.hasRestorableProfile)

        let relaunched = makeController()
        await relaunched.cardOpened()
        XCTAssertFalse(relaunched.hasRestorableProfile)
    }

    func testRemoveWorkspaceAlsoDropsItsResult() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: messy)]
        let controller = makeController()
        await controller.captureNow()
        gateway.windowsList[0] = chrome(at: saved)
        await controller.restoreNow()
        XCTAssertNotNil(controller.sections.first?.lastResult)
        controller.removeWorkspace(WorkspaceKey(screenIDs: ["ext-1"]))
        XCTAssertNil(controller.sections.first?.lastResult)
        await controller.captureNow()
        XCTAssertNil(controller.sections.first?.lastResult)
    }

    func testUnreadableStoreNeverOverwritesTheFile() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("workspaces.json")
        try Data("소중한 원본".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        XCTAssertEqual(controller.storeNotice, .unreadable)
        let awaited8 = await controller.captureNow()
        XCTAssertEqual(awaited8, .saveBlocked)
        XCTAssertFalse(controller.hasRestorableProfile)
        XCTAssertNil(controller.lastCaptureCount)
        controller.dismissStoreNotice()
        _ = await controller.captureNow()
        await controller.collectCandidate()
        XCTAssertEqual(controller.prepareForTermination(), .proceed)
        XCTAssertTrue(controller.isSaveBlocked)
        XCTAssertFalse(controller.hasPendingCollect)
        XCTAssertTrue(controller.allWorkspaces.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "소중한 원본")
    }

    func testRuntimeWriteFailureDoesNotClaimCaptureSucceededAndCanRetry() async throws {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        try Data("not-a-directory".utf8).write(to: dir)

        let awaited9 = await controller.captureNow()
        XCTAssertEqual(awaited9, .saveFailed)
        XCTAssertEqual(controller.storeNotice, .writeFailed)
        XCTAssertFalse(controller.isSaveBlocked)
        XCTAssertFalse(controller.hasRestorableProfile)
        XCTAssertNil(controller.lastCaptureCount)

        try FileManager.default.removeItem(at: dir)
        let awaited10 = await controller.captureNow()
        XCTAssertEqual(awaited10, .captured(appCount: 1, windowCount: 1))
        XCTAssertNil(controller.storeNotice)
        XCTAssertEqual(controller.lastCaptureCount, 1)
    }

    func testCaptureConfirmationExpiresOnCardOpen() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: saved)]
        let controller = makeController()
        await controller.captureNow()
        XCTAssertEqual(controller.lastCaptureCount, 1)
        await controller.cardOpened()
        XCTAssertNil(controller.lastCaptureCount)
    }

    func testScreenLabelsUsePortLocationThenLetters() {
        let labels = PlugbackController.screenLabels(for: [
            ("a", "LG Fine 24", .leftBack), ("b", "LG Fine 24", .right), ("c", "LG Fine 24", .right),
            ("d", "DELL", nil), ("e", "BenQ", nil), ("f", "BenQ", nil),
        ])
        XCTAssertEqual(labels["a"], ScreenLabel(name: "LG Fine 24", portLocation: .leftBack))
        XCTAssertEqual(labels["b"], ScreenLabel(name: "LG Fine 24", portLocation: .right, letter: "A"))
        XCTAssertEqual(labels["c"], ScreenLabel(name: "LG Fine 24", portLocation: .right, letter: "B"))
        XCTAssertEqual(labels["d"], ScreenLabel(name: "DELL"), "유일한 이름에는 아무것도 붙이지 않는다")
        XCTAssertEqual(labels["e"], ScreenLabel(name: "BenQ", letter: "A"))
        XCTAssertEqual(labels["f"], ScreenLabel(name: "BenQ", letter: "B"))
    }
}
