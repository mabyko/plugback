import XCTest
@testable import PlugbackKit

final class ProfileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugback-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testRoundTrip() throws {
        let store = ProfileStore(directory: dir)
        let profiles = ["ext-1": Profile(screenID: "ext-1", screenName: "LG", apps: [
            TargetApp(bundleID: "com.chrome", displayName: "Chrome",
                      unitRect: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ])]
        try store.save(profiles)
        let outcome = ProfileStore(directory: dir).load()
        XCTAssertEqual(outcome.profiles, profiles)
        XCTAssertNil(outcome.corruptionBackupURL)
    }

    func testCorruptedFileIsBackedUpAndReset() throws {
        // 손상 파일은 백업 후 초기화 — 앱이 죽지 않는다 (F-04.2, US-011 AC-5)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{{{ not json".utf8).write(to: dir.appendingPathComponent("profiles.json"))

        let outcome = ProfileStore(directory: dir).load()
        XCTAssertTrue(outcome.profiles.isEmpty)
        let backupURL = try XCTUnwrap(outcome.corruptionBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profiles.json").path))
    }
}

@MainActor
final class PlugbackControllerTests: XCTestCase {
    private var dir: URL!
    private var gateway: FakeWindowGateway!
    private var screens: FakeScreenProvider!

    private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                     frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
    private let external = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                      frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugback-tests-\(UUID().uuidString)", isDirectory: true)
        gateway = FakeWindowGateway()
        screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeController() -> PlugbackController {
        PlugbackController(gateway: gateway, screenProvider: screens, store: ProfileStore(directory: dir))
    }

    func testCaptureThenRestoreRoundTrip() {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.refresh()
        controller.captureNow()
        XCTAssertEqual(controller.profile?.apps.map(\.bundleID), ["com.chrome"])

        // 창이 어질러졌다 → 수동 복원 (US-007 AC-1)
        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        controller.restoreNow()
        XCTAssertEqual(controller.lastResult?.movedCount, 1)
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testProfileSurvivesRelaunch() {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let first = makeController()
        first.refresh()
        first.captureNow()

        let second = makeController()
        second.refresh()
        XCTAssertEqual(second.profile?.apps.map(\.bundleID), ["com.chrome"])
    }

    func testRestoreWithoutProfileMovesNothing() {
        // 프로필 없는 화면에서 수동 복원 → 아무 창도 움직이지 않는다 (US-007 AC-5)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        let controller = makeController()
        controller.refresh()
        controller.restoreNow()
        XCTAssertNil(controller.lastResult)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }
    func testDisconnectKeepsLastScreenAndProfile() {
        // 화면을 뽑아도 마지막 화면 이름과 프로필 유무는 남는다 (ARCHITECTURE 고정 결정)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.refresh()
        controller.captureNow()

        screens.screensList = [builtin] // 외장 화면 분리
        controller.refresh()
        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(controller.currentScreen?.name, "LG UltraFine 27")
        XCTAssertEqual(controller.profile?.apps.count, 1)
    }

    func testFreshLaunchShowsStoredScreenName() {
        // 재시작 직후 화면이 없어도 저장된 프로필의 화면 이름이 보인다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let first = makeController()
        first.refresh()
        first.captureNow()

        screens.screensList = [builtin]
        let second = makeController()
        second.refresh()
        XCTAssertFalse(second.isConnected)
        XCTAssertEqual(second.currentScreen?.name, "LG UltraFine 27")
    }

    func testCaptureSetsConfirmationAndRefreshClearsIt() {
        // 저장됐다는 것을 화면에서 확인할 수 있다 (US-002 AC-1)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.refresh()
        controller.captureNow()
        XCTAssertEqual(controller.lastCaptureCount, 1)
        controller.refresh()
        XCTAssertNil(controller.lastCaptureCount)
    }
}

