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
        XCTAssertNil(outcome.trouble)
    }

    func testCorruptedFileIsBackedUpAndReset() throws {
        // 손상 파일은 백업 후 초기화 — 앱이 죽지 않는다 (F-04.2, US-011 AC-5)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{{{ not json".utf8).write(to: dir.appendingPathComponent("profiles.json"))

        let outcome = ProfileStore(directory: dir).load()
        XCTAssertTrue(outcome.profiles.isEmpty)
        guard case .corruptionBackedUp(let backupURL) = try XCTUnwrap(outcome.trouble) else {
            return XCTFail("\(String(describing: outcome.trouble))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profiles.json").path))
    }

    func testUnreadableFileIsReportedNotTreatedAsFirstRun() throws {
        // 읽기 실패 ≠ 첫 실행 — 파일을 건드리지 않고 보고한다 (덮어쓰기 데이터 손실 방지)
        // profiles.json 자리에 디렉터리를 놓으면 "존재하지만 읽을 수 없음"이 결정적으로 재현된다
        let fileAsDir = dir.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: fileAsDir, withIntermediateDirectories: true)

        let outcome = ProfileStore(directory: dir).load()
        XCTAssertTrue(outcome.profiles.isEmpty)
        XCTAssertEqual(outcome.trouble, .unreadable)
        // 파일(디렉터리)이 그대로 남아 있다 — 백업·초기화하지 않는다
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileAsDir.path))
    }

    func testWriteFailureIsReported() throws {
        let store = ProfileStore(directory: dir)
        _ = store.load() // 없는 파일을 정상적인 첫 실행으로 읽은 뒤 쓰기 경로만 막는다
        try Data("not-a-directory".utf8).write(to: dir)

        XCTAssertThrowsError(try store.save([:]))
    }
}

private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                 frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let external = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                  frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

@MainActor
final class PlugbackControllerTests: XCTestCase {
    // XCTest는 테스트 메서드마다 새 인스턴스를 만든다 — setUp 없이 프로퍼티 초기화로 충분하고,
    // nonisolated한 setUp/tearDown이 @MainActor 상태를 만지는 격리 경고도 원천 차단된다.
    private nonisolated let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugback-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testCaptureThenRestoreRoundTrip() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()
        XCTAssertEqual(controller.sections.first?.profile?.apps.map(\.bundleID), ["com.chrome"])

        // 창이 어질러졌다 → 수동 복원 (US-007 AC-1)
        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.restoreNow()
        XCTAssertEqual(controller.sections.first?.lastResult?.movedCount, 1)
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testProfileSurvivesRelaunch() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let first = makeController()
        await first.captureNow()

        let second = makeController()
        await second.cardOpened()
        XCTAssertEqual(second.sections.first?.profile?.apps.map(\.bundleID), ["com.chrome"])
    }

    func testRestoreWithoutProfileMovesNothing() async {
        // 프로필 없는 화면에서 수동 복원 → 아무 창도 움직이지 않는다 (US-007 AC-5)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        let controller = makeController()
        await controller.restoreNow()
        XCTAssertNil(controller.sections.first?.lastResult)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }
    func testDisconnectKeepsLastScreenAndProfile() async {
        // 화면을 뽑아도 마지막 화면 이름과 프로필 유무는 남는다 (ARCHITECTURE 고정 결정)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()

        screens.screensList = [builtin] // 외장 화면 분리
        await controller.cardOpened()
        XCTAssertEqual(controller.screenPresence, .remembered(screenID: "ext-1", name: "LG UltraFine 27"))
        XCTAssertEqual(controller.sections.first?.profile?.apps.count, 1)
    }

    func testCardScreenSharesRestoreOrderOnTwoScreens() async {
        // "현재 화면"의 정의는 하나 — 식별자 정렬상 첫 화면. 공급자가 어떤 순서로 주든
        // 카드와 중복 제거(F-01.6)가 같은 첫 화면을 쓴다.
        let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        screens.screensList = [builtin, external2, external] // 일부러 역순 공급
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                       frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440)),  // ext-1
            WindowInfo(id: 2, appBundleID: "com.chrome", appName: "Chrome",
                       frame: CGRect(x: 4072, y: 0, width: 960, height: 1080)),   // ext-2 — 두 프로필에 등록됨
        ]
        let controller = makeController()
        await controller.captureNow()
        guard case .connected(let first, let count) = controller.screenPresence else {
            return XCTFail("\(controller.screenPresence)")
        }
        XCTAssertEqual(first.id, "ext-1") // 공급 순서와 무관하게 식별자 정렬상 첫 화면
        XCTAssertEqual(count, 2)

        // 공유 앱은 식별자 정렬상 첫 화면에서 복원된다.
        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.restoreNow()
        XCTAssertEqual(controller.sections.first?.lastResult?.entries.first?.outcome, .moved)
    }

    func testSectionsCoverEveryConnectedScreen() async {
        // 화면 인식이 아니라 표시의 문제였다 — 카드가 첫 화면만 그려서 두 번째 화면의 앱이
        // 사라진 것처럼 보였다. 섹션은 연결된 모든 화면을 식별자 정렬 순서로 담는다.
        let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        screens.screensList = [builtin, external, external2]
        gateway.runningBundleIDs = ["com.orca", "com.slack"]
        gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "com.orca", appName: "Orca",
                       frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440)),   // ext-1
            WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack",
                       frame: CGRect(x: 4072, y: 0, width: 960, height: 1080)),    // ext-2
        ]
        let controller = makeController()
        await controller.captureNow()

        var sections = controller.sections
        XCTAssertEqual(sections.map(\.screenID), ["ext-1", "ext-2"])
        XCTAssertEqual(sections[0].profile?.apps.map(\.bundleID), ["com.orca"])
        XCTAssertEqual(sections[1].profile?.apps.map(\.bundleID), ["com.slack"])
        // 새 앱이 두 번째 화면에 떴다 — 그 화면의 「저장하지 않는 앱」에만 나타난다
        gateway.runningBundleIDs.insert("com.figma")
        gateway.windowsList.append(WindowInfo(id: 3, appBundleID: "com.figma", appName: "Figma",
                                              frame: CGRect(x: 4500, y: 100, width: 800, height: 600)))
        await controller.cardOpened()
        sections = controller.sections
        XCTAssertEqual(sections[0].untrackedApps.map(\.bundleID), [])
        XCTAssertEqual(sections[1].untrackedApps.map(\.bundleID), ["com.figma"])

        // 두 번째 화면이 어질러졌다 — 복원 결과가 그 섹션과 lastResults에 온다
        gateway.windowsList[1] = WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.restoreNow()
        XCTAssertEqual(controller.lastResults.map(\.screenID), ["ext-1", "ext-2"])
        XCTAssertEqual(controller.sections[1].lastResult?.movedCount, 1)
    }

    func testCheckAndRemoveActOnTheGivenScreenOnly() async {
        // 같은 앱이 두 화면 프로필에 있어도 체크/삭제는 넘긴 화면의 프로필만 바꾼다 —
        // 화면 식별자 없이 부르면 첫 화면이라, 두 번째 화면의 행은 조작할 수 없었다.
        let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        screens.screensList = [builtin, external, external2]
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                       frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440)),   // ext-1
            WindowInfo(id: 2, appBundleID: "com.chrome", appName: "Chrome",
                       frame: CGRect(x: 4072, y: 0, width: 960, height: 1080)),    // ext-2
        ]
        let controller = makeController()
        await controller.captureNow()

        await controller.setTracked("com.chrome", false, on: "ext-2")
        XCTAssertEqual(controller.sections[0].profile?.apps.first?.isEnabled, true)
        XCTAssertEqual(controller.sections[1].profile?.apps.first?.isEnabled, false)
        XCTAssertEqual(controller.sections[1].untrackedApps.map(\.bundleID), ["com.chrome"])

        gateway.windowsList[1] = WindowInfo(
            id: 2, appBundleID: "com.chrome", appName: "Chrome",
            frame: CGRect(x: 100, y: 100, width: 960, height: 700)
        )
        await controller.cardOpened()
        await controller.remove("com.chrome", on: "ext-2")
        XCTAssertEqual(controller.sections[1].profile?.apps ?? [], [])
        XCTAssertEqual(controller.sections[0].profile?.apps.count, 1) // 첫 화면은 그대로
        XCTAssertTrue(
            controller.sections[1].untrackedApps.isEmpty,
            "프로필에서도 외장 화면에서도 사라진 앱의 projection을 즉시 비운다"
        )
    }

    func testTrackingANewAppRegistersOnlyTheGivenScreen() async {
        let external2 = ScreenInfo(
            id: "ext-2", name: "DELL U2723QE",
            frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false
        )
        screens.screensList = [builtin, external, external2]
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            WindowInfo(
                id: 1, appBundleID: "com.chrome", appName: "Chrome",
                frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440)
            ),
            WindowInfo(
                id: 2, appBundleID: "com.chrome", appName: "Chrome",
                frame: CGRect(x: 4072, y: 0, width: 960, height: 1080)
            ),
        ]
        let controller = makeController()

        await controller.setTracked("com.chrome", true, on: external2.id)

        XCTAssertNil(controller.sections[0].profile)
        XCTAssertEqual(
            controller.sections[1].profile?.apps.map(\.bundleID), ["com.chrome"],
            "두 화면에 창이 있어도 체크한 화면의 프로필만 등록한다"
        )
    }

    func testRemovingAnUncheckedAppAllowsLaterExternalDetection() async {
        gateway.runningBundleIDs = ["cc.ffitch.shottr"]
        gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "cc.ffitch.shottr", appName: "Shottr",
                       frame: CGRect(x: 1800, y: 100, width: 800, height: 600)),
        ]
        let controller = makeController()
        await controller.captureNow()
        await controller.setTracked("cc.ffitch.shottr", false, on: external.id)

        gateway.windowsList[0] = WindowInfo(
            id: 1, appBundleID: "cc.ffitch.shottr", appName: "Shottr",
            frame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.untrackedApps.map(\.bundleID), ["cc.ffitch.shottr"])

        await controller.remove("cc.ffitch.shottr", on: external.id)
        XCTAssertFalse(controller.sections.first?.profile?.apps.contains { $0.bundleID == "cc.ffitch.shottr" } ?? true)
        XCTAssertTrue(controller.sections.first?.untrackedApps.isEmpty ?? false)

        gateway.windowsList[0] = WindowInfo(
            id: 1, appBundleID: "cc.ffitch.shottr", appName: "Shottr",
            frame: CGRect(x: 1800, y: 100, width: 800, height: 600)
        )
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.untrackedApps.map(\.bundleID), ["cc.ffitch.shottr"])
    }

    func testRestorableWhenOnlyALaterScreenHasAProfile() async {
        // 프로필이 정렬상 뒤 화면에만 있어도 복원할 수 있어야 한다 —
        // 첫 화면의 프로필만 보던 판정은 이 상황에서 복원 버튼을 잠갔다.
        let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        screens.screensList = [builtin, external2] // ext-2만 연결된 동안 저장
        gateway.runningBundleIDs = ["com.slack"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.slack", appName: "Slack",
                                          frame: CGRect(x: 4072, y: 0, width: 960, height: 1080))]
        let controller = makeController()
        await controller.captureNow()

        screens.screensList = [builtin, external, external2] // ext-1이 새로 연결 — 프로필 없음
        await controller.cardOpened()
        XCTAssertNil(controller.sections.first?.profile)    // 첫 화면 기준으로는 프로필이 없다
        XCTAssertTrue(controller.hasRestorableProfile)      // 그래도 복원은 가능해야 한다

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.slack", appName: "Slack",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        guard case .restored(let results) = await controller.restoreNow() else { return XCTFail() }
        XCTAssertEqual(results.map(\.screenID), ["ext-2"])
        XCTAssertEqual(results.first?.movedCount, 1)
    }

    func testSettingsFlowIntoRestoreOptions() async {
        // 배선 스모크: 설정 토글이 엔진 옵션으로 흐른다. 정책 자체는 엔진 테스트가 검증한다.
        // 반환 시점 = 완료 시점 — 대기·재시도가 없다.
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()

        gateway.windowsList = [] // 창만 닫힘 — 프로세스는 생존
        gateway.windowOnReopen["com.chrome"] = WindowInfo(id: 2, appBundleID: "com.chrome", appName: "Chrome",
                                                          frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        controller.reopenWindowless = true
        await controller.restoreNow()
        XCTAssertEqual(gateway.openWindowCalls, ["com.chrome"])
        XCTAssertEqual(controller.sections.first?.lastResult?.entries.first?.outcome, .moved) // 최종 결과 — 중간 상태 없음
        XCTAssertEqual(gateway.windowsList.first?.frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    // MARK: 복원 진행 중의 상호배제 — await가 연 틈으로 아무도 못 들어온다

    /// 복원을 openWindow 지연에 매달아 두고 반환한다 — 인터리빙 시나리오의 공통 준비.
    /// 창만 닫힌 chrome + 새 창 열기 옵션으로 서스펜션 지점에 진입시킨다.
    private func startHangingRestore(_ controller: PlugbackController) async -> Task<RestoreOutcome, Never> {
        gateway.windowsList = []
        gateway.windowOnReopen["com.chrome"] = WindowInfo(id: 2, appBundleID: "com.chrome", appName: "Chrome",
                                                          frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        gateway.openWindowDelay = 0.05
        controller.reopenWindowless = true
        let task = Task { await controller.restoreNow() }
        while gateway.openWindowCalls.isEmpty { await Task.yield() } // 서스펜션 도달까지 양보
        return task
    }

    func testCaptureDuringRestoreIsRejected() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()
        await controller.cardOpened() // 확인 표시 만료 — 아래 거부가 새 표시를 안 만드는지 보기 위해
        let before = controller.sections.first?.profile

        let restore = await startHangingRestore(controller)
        // 복원이 매달린 사이 창이 엉뚱한 자리에 — 저장이 허용되면 이 배치가 박제된다
        gateway.windowsList = [WindowInfo(id: 9, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        let capture = await controller.captureNow()
        XCTAssertEqual(capture, .restoringInProgress)
        XCTAssertEqual(controller.sections.first?.profile, before) // 반쯤 복원된 배치가 프로필을 오염시키지 않았다
        XCTAssertNil(controller.lastCaptureCount)  // 저장 확인 표시도 뜨지 않는다
        _ = await restore.value
    }

    func testRestoreDuringRestoreReportsBusy() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()

        let restore = await startHangingRestore(controller)
        let second = await controller.restoreNow()
        XCTAssertEqual(second, .alreadyRestoring) // 조용한 무시가 아니라 명시적 거부
        _ = await restore.value
    }

    func testRemoveProfileDuringRestoreDoesNotResurrectResult() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()

        let restore = await startHangingRestore(controller)
        controller.removeProfile("ext-1") // 복원이 매달린 사이 프로필 삭제
        _ = await restore.value
        XCTAssertNil(controller.sections.first?.lastResult) // await 뒤의 결과 쓰기가 삭제를 되돌리지 않는다
    }

    func testCardOpenDuringRestoreDoesNotReenumerate() async {
        // 복원 중 카드 열기 → projection 갱신의 재열거가 진행 중 복원의 창 ID를 죽인다 —
        // refreshProjection은 복원 중엔 양보해야 한다 (ID 수명 계약)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()

        let restore = await startHangingRestore(controller)
        let callsBefore = gateway.standardWindowsCalls
        await controller.cardOpened() // 복원이 매달린 사이 카드 열림
        XCTAssertEqual(gateway.standardWindowsCalls, callsBefore) // 재열거하지 않았다
        let outcome = await restore.value
        guard case .restored(let results) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(results.first?.entries.first?.outcome, .moved) // 복원은 무사히 끝난다
    }

    func testScreenConnectedDuringRestoreIsRestoredAfterward() async {
        // 복원 중 연결된 화면은 조용히 소실되지 않는다 — 종료 직후 1회 재복원 (보류)
        let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        screens.screensList = [builtin, external, external2]
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                       frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440)),  // ext-1
            WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack",
                       frame: CGRect(x: 4072, y: 0, width: 960, height: 1080)),   // ext-2
        ]
        let controller = makeController()
        await controller.captureNow() // 두 화면 모두 프로필 확보

        screens.screensList = [builtin, external] // ext-2 분리
        let restore = await startHangingRestore(controller)
        screens.screensList = [builtin, external, external2] // 복원이 매달린 사이 ext-2 재연결
        gateway.windowsList.append(WindowInfo(id: 3, appBundleID: "com.slack", appName: "Slack",
                                              frame: CGRect(x: 4500, y: 300, width: 800, height: 600))) // 어질러짐
        await controller.externalScreensAppeared() // isRestoring → 보류
        let outcome = await restore.value

        XCTAssertEqual(gateway.windowsList.first { $0.appBundleID == "com.slack" }?.frame,
                       CGRect(x: 4072, y: 0, width: 960, height: 1080)) // 두 번째 바퀴에서 복원됨
        guard case .restored(let results) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(results.contains { $0.screenID == "ext-2" })
    }

    func testFreshLaunchShowsStoredScreenName() async {
        // 재시작 직후 화면이 없어도 저장된 프로필의 화면 이름이 보인다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let first = makeController()
        await first.captureNow()

        screens.screensList = [builtin]
        let second = makeController()
        await second.cardOpened()
        XCTAssertEqual(second.screenPresence, .remembered(screenID: "ext-1", name: "LG UltraFine 27"))
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
        await controller.captureNow()
        XCTAssertEqual(controller.sections.first?.profile?.fingerprint, fpA) // 저장 시 지문 기록

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
        await controller.captureNow()

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.externalScreensAppeared()
        XCTAssertEqual(controller.sections.first?.lastResult?.movedCount, 1)
    }

    func testManualModeDoesNotRestoreOnConnect() async {
        // 수동 모드에서는 연결돼도 복원되지 않는다 (US-007 AC-4)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()
        controller.restoreMode = .manual

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.externalScreensAppeared()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testUnauthorizedBlocksAutoRestore() async {
        // 권한이 없으면 복원을 시도하지 않는다 (US-010 AC-2)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()
        controller.authorizationCheck = { false }

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        await controller.externalScreensAppeared()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testUnauthorizedBlocksEveryCommand() async {
        // 게이트는 자동 경로만이 아니라 모든 명령 내부에 있다 (US-010 AC-2) — published 상태도 갱신된다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow() // 권한 있는 동안 프로필 확보
        controller.authorizationCheck = { false }

        gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                            frame: CGRect(x: 2500, y: 500, width: 800, height: 600))
        let outcome = await controller.restoreNow()
        XCTAssertEqual(outcome, .notAuthorized)       // 반환값으로도 구별된다
        XCTAssertTrue(gateway.moveCalls.isEmpty)      // 수동 복원 차단
        XCTAssertFalse(controller.isAuthorized)       // UI 바인딩용 상태 갱신

        let before = controller.sections.first?.profile
        let capture = await controller.captureNow()         // 저장도 차단 — 어질러진 배치로 덮어쓰지 않는다
        XCTAssertEqual(capture, .notAuthorized)
        XCTAssertEqual(controller.sections.first?.profile, before)
    }

    func testRestoreModePersists() {
        // 사용자 모드 설정은 재시작을 넘어 보존된다 (F-05.4, F-08.3)
        let first = makeController()
        XCTAssertEqual(first.autoSlotUpdateMode, .onDisconnect, "기존 사용자의 기본 동작")
        first.restoreMode = .manual
        first.autoSlotUpdateMode = .liveUntilDisconnect
        let second = makeController()
        XCTAssertEqual(second.restoreMode, .manual)
        XCTAssertEqual(second.autoSlotUpdateMode, .liveUntilDisconnect)
    }

    func testRemoveProfileDeletesAndPersists() async {
        // 프로필 통째 삭제 — 되살아나지 않고, 재연결 시 프로필 없는 화면 (US-012 AC-2·3)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()
        XCTAssertEqual(controller.allProfiles.count, 1)

        controller.removeProfile("ext-1")
        XCTAssertTrue(controller.allProfiles.isEmpty)
        XCTAssertNil(controller.sections.first?.profile)

        let relaunched = makeController()
        await relaunched.cardOpened()
        XCTAssertNil(relaunched.sections.first?.profile)
    }

    func testRemoveProfileAlsoDropsItsResult() async {
        // 결과 수명 = 프로필 수명. 같은 화면에 프로필을 다시 만들어도 전생의 결과가 보이면 안 된다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 2500, y: 500, width: 800, height: 600))]
        let controller = makeController()
        await controller.captureNow()
        await controller.restoreNow()
        XCTAssertNotNil(controller.sections.first?.lastResult)

        controller.removeProfile("ext-1")
        XCTAssertNil(controller.sections.first?.lastResult)
        await controller.captureNow() // 새 삶 — 결과는 아직 없어야 한다
        XCTAssertNil(controller.sections.first?.lastResult)
    }

    func testUnreadableStoreNeverOverwritesTheFile() async throws {
        // 읽기 실패가 첫 실행으로 위장하면 다음 저장이 원본을 덮어쓴다 — 그 경로를 막는다.
        // chmod 000: 읽기는 실패하지만 atomic 쓰기(rename)는 성공하는, 정확히 위험한 조합.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("profiles.json")
        try Data("소중한 원본".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        XCTAssertEqual(controller.storeNotice, .unreadable)

        // 저장은 통째로 거부된다 — 재시작에 증발할 메모리 저장으로 "저장됨"을 속이지 않는다
        let outcome = await controller.captureNow()
        XCTAssertEqual(outcome, .saveBlocked)
        XCTAssertNil(controller.sections.first?.profile)
        XCTAssertNil(controller.lastCaptureCount)  // 거짓 확인 표시가 뜨지 않는다
        controller.dismissStoreNotice()            // 알림을 닫아도 차단은 유지
        _ = await controller.captureNow()
        controller.labAutoSlot = true
        await controller.collectCandidate()
        controller.confirmAllCandidates()

        XCTAssertTrue(controller.isSaveBlocked)
        XCTAssertFalse(controller.hasPendingCollect)
        XCTAssertTrue(controller.allProfiles.isEmpty)
        XCTAssertNil(controller.sections.first?.restoreSource)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "소중한 원본") // 원본 무사
    }

    func testRuntimeWriteFailureDoesNotClaimCaptureSucceededAndCanRetry() async throws {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController() // 없는 파일을 정상적인 첫 실행으로 읽는다
        try Data("not-a-directory".utf8).write(to: dir)

        let failed = await controller.captureNow()

        XCTAssertEqual(failed, .saveFailed)
        XCTAssertEqual(controller.storeNotice, .writeFailed)
        XCTAssertFalse(controller.isSaveBlocked, "실행 중 쓰기 실패는 다음 저장에서 재시도할 수 있어야 한다")
        XCTAssertNil(controller.sections.first?.profile)
        XCTAssertNil(controller.lastCaptureCount)

        try FileManager.default.removeItem(at: dir)
        let retried = await controller.captureNow()

        XCTAssertEqual(retried, .captured(appCount: 1))
        XCTAssertNil(controller.storeNotice)
        XCTAssertEqual(controller.sections.first?.profile?.apps.map(\.bundleID), ["com.chrome"])
        XCTAssertEqual(controller.lastCaptureCount, 1)
    }

    func testCaptureConfirmationExpiresOnCardOpen() async {
        // 저장됐다는 것을 화면에서 확인할 수 있다 (US-002 AC-1)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                          frame: CGRect(x: 1512, y: 0, width: 1280, height: 1440))]
        let controller = makeController()
        await controller.captureNow()
        XCTAssertEqual(controller.lastCaptureCount, 1)
        await controller.cardOpened()
        XCTAssertNil(controller.lastCaptureCount)
    }
}
