import XCTest
@testable import PlugbackKit

// 실험실 · 자동 슬롯. 시뮬레이션 문서(auto-capture-simulation.html)의 시나리오를 코드로 옮긴 것.
// 규칙은 하나다 — 더 최근에 저장된 슬롯이 이긴다. 저장된 "활성 슬롯"은 없다.

private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                 frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let external = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                  frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

@MainActor
final class LabAutoSlotTests: XCTestCase {
    private nonisolated let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugback-lab-\(UUID().uuidString)", isDirectory: true)
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

    private lazy var testDefaults = UserDefaults(suiteName: "plugback-lab-\(UUID().uuidString)")!

    /// collectInterval 0 — 수집을 부를 때마다 실제로 돌게 한다.
    private func makeController() -> PlugbackController {
        PlugbackController(gateway: gateway, screenProvider: screens,
                           store: ProfileStore(directory: dir), defaults: testDefaults,
                           collectInterval: 0)
    }

    private func chrome(at frame: CGRect) -> WindowInfo {
        WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome", frame: frame)
    }

    private func placeChrome(at frame: CGRect) {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: frame)]
    }

    /// 저장 파일의 키 — 자동 슬롯이 진짜로 파일에 들어갔는지는 여기서만 확인된다.
    private func storedKeys() throws -> Set<String> {
        let data = try Data(contentsOf: dir.appendingPathComponent("profiles.json"))
        return Set(try JSONDecoder().decode([String: Profile].self, from: data).keys)
    }

    private let left = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
    private let right = CGRect(x: 2792, y: 0, width: 1280, height: 1440)

    // MARK: - 꺼져 있으면 오늘의 앱과 같다

    func testLabOffNeverWritesAutoSlot() async throws {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        // 꺼져 있으면 수집·확정이 아무 일도 하지 않는다
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])

        XCTAssertEqual(try storedKeys(), ["ext-1"])
        XCTAssertEqual(controller.restoreSource, .manual)
    }

    // MARK: - S2 · 오늘 안 켠 앱이 사라지지 않는다 (US-002 AC-4)

    func testEnablingLabSeedsAutoSlotFromManual() async throws {
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [chrome(at: left),
                               WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack", frame: right)]
        let controller = makeController()
        await controller.captureNow()

        controller.labAutoSlot = true
        // 씨앗이 없으면 Slack이 첫 확정에서 통째로 빠진다
        XCTAssertEqual(try storedKeys(), ["ext-1", "ext-1#auto"])

        // 오늘은 Slack을 켜지 않았다 — 수집은 Chrome만 본다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])

        // 자동 슬롯이 이겼는데도 Slack이 살아 있다 (병합)
        XCTAssertEqual(controller.restoreSource, .auto)
        XCTAssertEqual(controller.profile?.apps.map(\.bundleID).sorted(), ["com.chrome", "com.slack"])
    }

    // MARK: - 수집 → 확정

    func testConfirmWritesCollectedLayoutToAutoSlot() async throws {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true

        gateway.windowsList = [chrome(at: right)] // 하루 동안 창을 옮겼다
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])

        XCTAssertEqual(controller.restoreSource, .auto)
        XCTAssertEqual(try XCTUnwrap(controller.profile?.apps.first?.unitRect.x), 0.5, accuracy: 0.001)
    }

    func testConfirmDoesNotReadWindows() async {
        // 확정 시점엔 창이 이미 내장 화면으로 옮겨져 있다 — 읽으면 늦는다.
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true
        await controller.collectCandidate()

        let before = gateway.standardWindowsCalls
        controller.confirmCandidates(for: ["ext-1"])
        XCTAssertEqual(gateway.standardWindowsCalls, before)
    }

    func testCollectDoesNotTouchTheFile() async throws {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true

        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()

        // 수집만으로는 자동 슬롯이 아직 씨앗 값이다 — 후보는 메모리에만 있다
        let stored = try JSONDecoder()
            .decode([String: Profile].self, from: Data(contentsOf: dir.appendingPathComponent("profiles.json")))
        XCTAssertEqual(stored["ext-1#auto"]?.apps.first?.unitRect.x, 0)
    }

    // MARK: - 창을 옮기면 그 자체가 신호다 (앱 전환을 기다리지 않는다)

    func testWindowMoveTriggersCollectionWithoutAppSwitch() async throws {
        // 실기기 1차 실패의 핵심 — 창만 옮기고 앱 전환을 안 하면 신호가 없었다.
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true
        await controller.collectCandidate() // 관찰 등록은 수집 끝에 붙는다

        XCTAssertEqual(gateway.observedBundleIDs, ["com.chrome"], "수집 열거와 같은 앱을 관찰해야 한다")

        // 창을 옮기고 손을 뗀다. 앱 전환은 하지 않는다.
        gateway.windowsList = [chrome(at: right)]
        gateway.simulateWindowSettled()
        try? await Task.sleep(nanoseconds: 100_000_000)

        controller.confirmCandidates(for: ["ext-1"])
        XCTAssertEqual(controller.restoreSource, .auto)
        XCTAssertEqual(try XCTUnwrap(controller.profile?.apps.first?.unitRect.x), 0.5, accuracy: 0.001)
    }

    func testMoveObserversRegisterWithoutAPriorScreenSync() async {
        // 앱을 켤 때 외장 화면이 이미 꽂혀 있으면 연결 이벤트가 없다.
        // 시작 직후 화면 상태는 '기억만'이라, 스스로 동기화하지 않으면 등록이 통째로 빠진다.
        placeChrome(at: left)
        let first = makeController()
        await first.captureNow()

        let second = makeController() // 새 실행 — 아직 화면을 동기화한 적이 없다
        second.labAutoSlot = true
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(gateway.observedBundleIDs, ["com.chrome"])
    }

    func testTurningLabOffReleasesMoveObservers() async {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true
        await controller.collectCandidate()
        XCTAssertFalse(gateway.observedBundleIDs.isEmpty)

        controller.labAutoSlot = false
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(gateway.observedBundleIDs.isEmpty, "꺼진 기능이 창을 관찰하고 있으면 꺼짐이 아니다")
    }

    // MARK: - S1 · 더 최근 슬롯이 이긴다

    func testMoreRecentAutoSlotWinsAndRestoresToIt() async {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true

        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])

        gateway.windowsList = [chrome(at: CGRect(x: 2000, y: 300, width: 800, height: 600))] // 어질러짐
        await controller.restoreNow()
        XCTAssertEqual(gateway.windowsList[0].frame, right) // 수동(left)이 아니라 자동(right)
    }

    // MARK: - S7 · 수동 저장이 소스가 된다 (구멍 3이 스펙이 된 자리)

    func testManualSaveBecomesTheNewestSource() async {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true
        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])
        XCTAssertEqual(controller.restoreSource, .auto)

        // 사람이 저장을 누른다 — 활성 슬롯을 따로 전환하지 않는데도 수동이 소스가 된다
        gateway.windowsList = [chrome(at: left)]
        await controller.captureNow()
        XCTAssertEqual(controller.restoreSource, .manual)

        gateway.windowsList = [chrome(at: CGRect(x: 2000, y: 300, width: 800, height: 600))]
        await controller.restoreNow()
        XCTAssertEqual(gateway.windowsList[0].frame, left)
    }

    // MARK: - S6 · 끄면 자동 슬롯이 비교에서 빠진다

    func testTurningLabOffDropsAutoSlotFromComparison() async throws {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true
        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])
        XCTAssertEqual(controller.restoreSource, .auto)

        controller.labAutoSlot = false
        XCTAssertEqual(controller.restoreSource, .manual)
        // 파일은 남는다 — 다시 켜면 이어진다
        XCTAssertEqual(try storedKeys(), ["ext-1", "ext-1#auto"])
        controller.labAutoSlot = true
        XCTAssertEqual(controller.restoreSource, .auto)
    }

    // MARK: - 카드가 보여주는 슬롯을 고친다

    func testEditingTargetAppsHitsTheWinningSlot() async {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true
        gateway.windowsList = [chrome(at: right)]
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])
        XCTAssertEqual(controller.restoreSource, .auto)

        controller.setAppEnabled("com.chrome", false)

        // 목록(=이긴 슬롯)이 바뀌고, 수동 슬롯은 그대로다
        XCTAssertEqual(controller.profile?.apps.first?.isEnabled, false)
        XCTAssertEqual(controller.allProfiles.first?.apps.first?.isEnabled, true)
    }

    // MARK: - 목록·삭제는 슬롯을 새지 않는다

    func testAllProfilesHidesAutoSlotAndRemoveClearsBoth() async throws {
        placeChrome(at: left)
        let controller = makeController()
        await controller.captureNow()
        controller.labAutoSlot = true
        await controller.collectCandidate()
        controller.confirmCandidates(for: ["ext-1"])

        XCTAssertEqual(controller.allProfiles.count, 1) // 화면 하나가 두 줄로 보이지 않는다

        controller.removeProfile("ext-1")
        XCTAssertEqual(try storedKeys(), [])
        XCTAssertNil(controller.profile)
    }
}

// MARK: - 드리프트 방지 (순수 함수라 컨트롤러 없이 검증한다)

final class CaptureDriftTests: XCTestCase {
    private let screen = ScreenInfo(id: "ext-1", name: "LG",
                                    frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: false)

    /// 복원은 허용 오차 안에 착지하면 성공으로 기록한다(F-02.3). 그 값을 저장하면 회차마다
    /// 조금씩 밀리고, 검증은 계속 통과한다 — Memmon #19가 실물 증거다.
    func testWithinToleranceDriftIsNotWrittenBack() {
        let stored = Profile(screenID: screen.id, screenName: screen.name, apps: [
            TargetApp(bundleID: "com.chrome", displayName: "Chrome",
                      unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        ])
        // 4px 어긋나게 착지 — 허용 오차(5) 안이라 복원은 .moved로 기록한다
        let drifted = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                 frame: CGRect(x: 4, y: 4, width: 500, height: 500))

        let after = CaptureEngine.capture(windows: [drifted], on: screen, merging: stored)
        XCTAssertEqual(after.apps[0].unitRect.x, 0)
        XCTAssertEqual(after.apps[0].unitRect.y, 0)
    }

    func testRealMoveIsWrittenBack() {
        let stored = Profile(screenID: screen.id, screenName: screen.name, apps: [
            TargetApp(bundleID: "com.chrome", displayName: "Chrome",
                      unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        ])
        // 사용자가 실제로 옮긴 거리는 허용 오차보다 크다
        let moved = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                               frame: CGRect(x: 400, y: 0, width: 500, height: 500))

        let after = CaptureEngine.capture(windows: [moved], on: screen, merging: stored)
        XCTAssertEqual(after.apps[0].unitRect.x, 0.4, accuracy: 0.001)
    }
}
