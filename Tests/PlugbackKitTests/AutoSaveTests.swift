import XCTest
@testable import PlugbackKit

// 자동 저장 (D2·D7)과 작업 환경 이탈 저장 (D5)을 컨트롤러 배선에서 검증한다. 규칙 자체는 WorkspaceLibraryTests가 지킨다.

private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                 frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let external = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                  frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
private let external2 = ScreenInfo(id: "ext-2", name: "DELL",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)

@MainActor
final class AutoSaveTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("autosave")
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

    private lazy var testDefaults = UserDefaults(suiteName: "plugback-autosave-\(UUID().uuidString)")!

    private func makeController() -> PlugbackController {
        PlugbackController(gateway: gateway, screenProvider: screens,
                           store: ProfileStore(directory: dir), defaults: testDefaults,
                           collectInterval: 0, moveSource: gateway)
    }

    private func chrome(at frame: CGRect, id: Int = 1) -> WindowInfo {
        WindowInfo(id: id, appBundleID: "com.chrome", appName: "Chrome", frame: frame, windowServerID: CGWindowID(100 + id))
    }

    private func placeChrome(at frame: CGRect) {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: frame)]
    }

    private let left = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
    private let right = CGRect(x: 2792, y: 0, width: 1280, height: 1440)
    private var key: WorkspaceKey { WorkspaceKey(screenIDs: [external.id]) }

    private func storedSnapshot() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("workspaces.json")),
              let file = try? JSONDecoder.plugback.decode(StoreFile.self, from: data) else { return nil }
        return file.workspaces[key.raw]?.saved
    }

    // MARK: - 최초값과 설정 이전

    func testAutoSaveIsOnByDefaultAndLegacyChoicesArePreservedOnce() {
        XCTAssertTrue(makeController().autoSave, "선택 이력이 없으면 ON (A13)")

        let legacy = UserDefaults(suiteName: "plugback-legacy-\(UUID().uuidString)")!
        legacy.set(false, forKey: "labAutoSlot")
        legacy.set(true, forKey: "reopenWindowless")
        let migrated = PlugbackController(gateway: gateway, screenProvider: screens,
                                          store: ProfileStore(directory: dir), defaults: legacy, collectInterval: 0)
        XCTAssertFalse(migrated.autoSave, "명시적인 옛 선택은 보존한다")
        XCTAssertTrue(migrated.reviveWindowlessApps, "「창이 없는 앱은 새 창을 열어 복원」은 「실행 중인 앱 창 되살리기」로 이어진다")
        XCTAssertFalse(migrated.reopenClosedApps, "부모 옵션은 자동으로 켜지 않는다")
        XCTAssertFalse(migrated.openMissingWindows)
        XCTAssertFalse(migrated.directWindowAssignment)

        legacy.set(true, forKey: "labAutoSlot") // 이전은 한 번뿐이다 — 이후 옛 키가 바뀌어도 새 키를 덮지 않는다
        XCTAssertFalse(PlugbackController(gateway: gateway, screenProvider: screens,
                                          store: ProfileStore(directory: dir), defaults: legacy, collectInterval: 0).autoSave)
    }

    // MARK: - 이력과 확정

    func testLeavingTheWorkspaceConfirmsThePendingHistory() async {
        // 작업 중 이력은 저장 대기이고, 환경을 떠날 때 마지막 유효 상태를 저장한다 (A15)
        placeChrome(at: left)
        let controller = makeController()
        controller.startWatching()
        await controller.captureNow()

        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        XCTAssertTrue(controller.hasPendingCollect)
        XCTAssertEqual(storedSnapshot()?.placements.first?.unitRect.x, 0, "수집만으로는 파일이 바뀌지 않는다")

        screens.screensList = [builtin]
        await controller.workspaceChanged()
        XCTAssertEqual(storedSnapshot()?.savedBy, .auto)
        XCTAssertEqual(storedSnapshot()?.placements.first?.unitRect.x, 0.5)
    }

    func testAutoSaveOffKeepsTheLastSaveWhenLeaving() async {
        placeChrome(at: left)
        let controller = makeController()
        controller.startWatching()
        await controller.captureNow()
        controller.autoSave = false

        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        XCTAssertFalse(controller.hasPendingCollect)
        screens.screensList = [builtin]
        await controller.workspaceChanged()
        XCTAssertEqual(storedSnapshot()?.savedBy, .manual)
        XCTAssertEqual(storedSnapshot()?.placements.first?.unitRect.x, 0)
    }

    func testRestoreUsesTheLastConfirmedSaveNotThePendingHistory() async {
        // 연결 중 「지금 복원」은 마지막 저장 완료본을 쓴다 (A18)
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        XCTAssertTrue(controller.hasPendingCollect)

        await controller.restoreNow()
        XCTAssertEqual(gateway.windowsList[0].frame, left)
    }

    func testWindowMoveTriggersCollectionWithoutAppSwitch() async throws {
        placeChrome(at: left)
        let controller = makeController()
        controller.startWatching()
        await controller.captureNow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gateway.observedBundleIDs, ["com.chrome"], "저장한 앱을 이동 관찰한다")

        gateway.windowsList = [chrome(at: right)]
        gateway.simulateWindowSettled()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(controller.hasPendingCollect, "창만 옮기고 앱 전환을 안 해도 이력이 생긴다")
    }

    func testFailedRestoreLandingIsNotPromotedToTheNextSource() async {
        // 복원 실패의 착지 위치를 다음 저장 기준으로 삼지 않는다 (R5·A09)
        placeChrome(at: left)
        let controller = makeController()
        controller.startWatching()
        await controller.captureNow()

        gateway.windowsList = [chrome(at: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        gateway.moveBehavior = .silentFail
        await controller.restoreNow()
        XCTAssertEqual(controller.lastResults.first?.failedCount, 1)

        await controller.collectCandidate()
        XCTAssertFalse(controller.hasPendingCollect, "실패한 착지는 새 이력이 아니다")
        screens.screensList = [builtin]
        await controller.workspaceChanged()
        XCTAssertEqual(storedSnapshot()?.placements.first?.unitRect.x, 0)
        XCTAssertEqual(storedSnapshot()?.savedBy, .manual)
    }

    func testUserMoveAfterAFailedRestoreIsCollectedAgain() async {
        placeChrome(at: left)
        let controller = makeController()
        controller.startWatching()
        await controller.captureNow()
        gateway.windowsList = [chrome(at: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        gateway.moveBehavior = .silentFail
        await controller.restoreNow()
        gateway.moveBehavior = .honest

        gateway.simulateWindowMoved(101) // 사용자가 그 창을 직접 옮겼다
        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        XCTAssertTrue(controller.hasPendingCollect)
    }

    func testWorkspacesAreIndependentPerScreenCombination() async {
        // A 단독과 A+B는 별개 저장본이다 (D5·G06·G22)
        placeChrome(at: left)
        let controller = makeController()
        controller.startWatching()
        await controller.captureNow()

        screens.screensList = [builtin, external, external2]
        await controller.workspaceChanged()
        XCTAssertFalse(controller.hasRestorableProfile, "A+B에는 아직 저장본이 없다 — A 기록을 대신 쓰지 않는다 (G21)")
        gateway.windowsList = [chrome(at: right)]
        await controller.captureNow()
        XCTAssertEqual(controller.allWorkspaces.count, 2)

        gateway.windowsList = [chrome(at: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        await controller.restoreNow()
        XCTAssertEqual(gateway.windowsList[0].frame, right, "A+B 저장본")

        screens.screensList = [builtin, external]
        gateway.windowsList = [chrome(at: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        await controller.workspaceChanged() // 자동 복원 — A 단독 저장본
        XCTAssertEqual(gateway.windowsList[0].frame, left)
    }

    func testGracefulTerminationSavesPendingHistoryAndReportsFailure() async throws {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        XCTAssertTrue(controller.hasUnsavedHistory)
        XCTAssertEqual(controller.prepareForTermination(), .proceed)
        XCTAssertEqual(storedSnapshot()?.placements.first?.unitRect.x, 0.5)

        gateway.windowsList = [chrome(at: left)]
        await controller.collectCandidate()
        try FileManager.default.removeItem(at: dir)
        try Data("not-a-directory".utf8).write(to: dir)
        XCTAssertEqual(controller.prepareForTermination(), .saveFailed, "저장 실패는 종료를 취소해야 한다 (A25)")
        XCTAssertTrue(controller.hasUnsavedHistory, "실패한 이력은 남는다")
    }
}
