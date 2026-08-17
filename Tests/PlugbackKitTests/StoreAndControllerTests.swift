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

    private lazy var testDefaults = UserDefaults(suiteName: "plugback-tests-\(UUID().uuidString)")!

    private func makeController() -> PlugbackController {
        PlugbackController(gateway: gateway, screenProvider: screens,
                           store: ProfileStore(directory: dir), defaults: testDefaults)
    }

    func testCaptureThenRestoreRoundTrip() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()
        XCTAssertEqual(controller.profile?.apps.map(\.bundleID), ["com.chrome"])

        // 창이 어질러졌다 → 수동 복원 (US-007 AC-1)
        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.restoreNow()
        XCTAssertEqual(controller.lastResult?.movedCount, 1)
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testProfileSurvivesRelaunch() {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let first = makeController()
        first.captureNow()

        let second = makeController()
        second.cardOpened()
        XCTAssertEqual(second.profile?.apps.map(\.bundleID), ["com.chrome"])
    }

    func testRestoreWithoutProfileMovesNothing() async {
        // 프로필 없는 화면에서 수동 복원 → 아무 창도 움직이지 않는다 (US-007 AC-5)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        let controller = makeController()
        await controller.restoreNow()
        XCTAssertNil(controller.lastResult)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }
    func testDisconnectKeepsLastScreenAndProfile() {
        // 화면을 뽑아도 마지막 화면 이름과 프로필 유무는 남는다 (ARCHITECTURE 고정 결정)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()

        screens.screensList = [builtin] // 외장 화면 분리
        controller.cardOpened()
        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(controller.currentScreen?.name, "LG UltraFine 27")
        XCTAssertEqual(controller.profile?.apps.count, 1)
    }

    func testRunningWithoutWindowIsNotWindowed() {
        // 실행 중 + 표준 창 0개 = "창 없음" 상태 — 실행 점과 창 점이 갈라진다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()

        gateway.windowsList = [] // 창만 모두 닫힘 — 프로세스는 생존
        controller.cardOpened()
        XCTAssertEqual(controller.runningBundleIDs, ["com.chrome"])
        XCTAssertEqual(controller.windowedBundleIDs, [])
    }

    func testSettingsFlowIntoRestoreOptions() async {
        // 배선 스모크: 설정 토글이 엔진 옵션으로 흐른다. 정책 자체는 엔진 테스트가 검증한다.
        // 반환 시점 = 완료 시점 — 대기·재시도가 없다.
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()

        gateway.windowsList = [] // 창만 닫힘 — 프로세스는 생존
        gateway.windowOnReopen["com.chrome"] = WindowInfo(id: 2, appBundleID: "com.chrome", appName: "Chrome",
                                                          frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        controller.reopenWindowless = true
        await controller.restoreNow()
        XCTAssertEqual(gateway.openWindowCalls, ["com.chrome"])
        XCTAssertEqual(controller.lastResult?.entries.first?.outcome, .moved) // 최종 결과 — 중간 상태 없음
        XCTAssertEqual(gateway.windowsList.first?.frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testFreshLaunchShowsStoredScreenName() {
        // 재시작 직후 화면이 없어도 저장된 프로필의 화면 이름이 보인다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let first = makeController()
        first.captureNow()

        screens.screensList = [builtin]
        let second = makeController()
        second.cardOpened()
        XCTAssertFalse(second.isConnected)
        XCTAssertEqual(second.currentScreen?.name, "LG UltraFine 27")
    }

    // 다중 화면 중복 제거(F-01.6)는 이제 엔진 정책 — RestoreEngineTests가 검증한다.

    func testFingerprintMismatchBlocksRestore() async {
        // UUID는 같은데 지문이 다르면 복원하지 않는다 — 오작동 대신 무작동 (F-01.4)
        let fpA = ScreenFingerprint(vendor: 1, model: 2, serial: 3)
        let fpB = ScreenFingerprint(vendor: 1, model: 2, serial: 999)
        let screenA = ScreenInfo(id: "ext-1", name: "LG", frame: external.frame,
                                 isBuiltin: false, fingerprint: fpA)
        screens.screensList = [builtin, screenA]
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()
        XCTAssertEqual(controller.profile?.fingerprint, fpA) // 저장 시 지문 기록

        // 같은 UUID, 다른 지문의 화면으로 교체 (OS가 배정을 바꾼 상황)
        screens.screensList = [builtin, ScreenInfo(id: "ext-1", name: "LG", frame: external.frame,
                                                   isBuiltin: false, fingerprint: fpB)]
        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.restoreNow()

        XCTAssertTrue(controller.identityMismatch) // 결과에서 파생된 배선 확인
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testAutoModeRestoresWhenScreenAppears() async {
        // 외장 화면이 연결되면 자동으로 복원된다 (US-001, F-01.1)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.externalScreensAppeared(["ext-1"])
        XCTAssertEqual(controller.lastResult?.movedCount, 1)
    }

    func testManualModeDoesNotRestoreOnConnect() async {
        // 수동 모드에서는 연결돼도 복원되지 않는다 (US-007 AC-4)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()
        controller.restoreMode = .manual

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.externalScreensAppeared(["ext-1"])
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testUnauthorizedBlocksAutoRestore() async {
        // 권한이 없으면 복원을 시도하지 않는다 (US-010 AC-2)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()
        controller.isAuthorized = { false }

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.externalScreensAppeared(["ext-1"])
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testRestoreModePersists() {
        // 복원 모드 설정은 재시작을 넘어 보존된다 (F-05.4)
        let first = makeController()
        first.restoreMode = .manual
        let second = makeController()
        XCTAssertEqual(second.restoreMode, .manual)
    }

    func testRemoveProfileDeletesAndPersists() {
        // 프로필 통째 삭제 — 되살아나지 않고, 재연결 시 프로필 없는 화면 (US-012 AC-2·3)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()
        XCTAssertEqual(controller.allProfiles.count, 1)

        controller.removeProfile("ext-1")
        XCTAssertTrue(controller.allProfiles.isEmpty)
        XCTAssertNil(controller.profile)

        let relaunched = makeController()
        relaunched.cardOpened()
        XCTAssertNil(relaunched.profile)
    }

    func testCaptureConfirmationExpiresOnCardOpen() {
        // 저장됐다는 것을 화면에서 확인할 수 있다 (US-002 AC-1)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        controller.captureNow()
        XCTAssertEqual(controller.lastCaptureCount, 1)
        controller.cardOpened()
        XCTAssertNil(controller.lastCaptureCount)
    }
}

