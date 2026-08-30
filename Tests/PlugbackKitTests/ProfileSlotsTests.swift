import XCTest
@testable import PlugbackKit

/// 슬롯 규칙을 **자기 인터페이스에서** 검증한다.
/// 이전에는 전부 컨트롤러를 지나야 했다 — 규칙이 틀렸는지 배선이 틀렸는지 실패가 구별해주지 않았다.
@MainActor
final class ProfileSlotsTests: XCTestCase {
    private nonisolated let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugback-slots-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private let screen = ScreenInfo(id: "ext-1", name: "LG",
                                    frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let other = ScreenInfo(id: "ext-2", name: "DELL",
                                   frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)

    private func makeSlots(
        lab: Bool = false, updateMode: AutoSlotUpdateMode = .onDisconnect
    ) -> ProfileSlots {
        ProfileSlots(
            store: ProfileStore(directory: dir), isLabEnabled: lab, updateMode: updateMode
        )
    }

    private func window(_ bundleID: String, _ frame: CGRect) -> WindowInfo {
        WindowInfo(id: 1, appBundleID: bundleID, appName: bundleID, frame: frame)
    }

    private let left = CGRect(x: 0, y: 0, width: 500, height: 1000)
    private let right = CGRect(x: 500, y: 0, width: 500, height: 1000)

    private func storedKeys() throws -> Set<String> {
        let data = try Data(contentsOf: dir.appendingPathComponent("profiles.json"))
        return Set(try JSONDecoder().decode([String: Profile].self, from: data).keys)
    }

    // MARK: - 복원 소스 판정

    func testTieGoesToManual() {
        // 켠 직후가 정확히 동점이다 — 씨앗이 수동의 저장 시각을 물려받기 때문이다.
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true

        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .manual)
    }

    func testMoreRecentAutoWins() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"])

        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .auto)
        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.first?.unitRect.x, 0.5)
    }

    func testManualSaveRetakesTheSource() {
        // 사람이 개입하면 사람 것이 최신이 된다 — 슬롯 전환 조작이 없는 이유다.
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"])
        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .auto)

        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .manual)
    }

    func testLabOffDropsAutoFromThePool() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"])

        slots.isLabEnabled = false
        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .manual)
        // 파일은 남는다 — 다시 켜면 이어진다
        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.first?.unitRect.x, 0)
        slots.isLabEnabled = true
        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .auto)
    }

    func testNoProfileMeansNoSource() {
        XCTAssertNil(makeSlots().source(for: "ext-1"))
    }

    // MARK: - 씨앗

    func testSeedCopiesManualSoUnlaunchedAppsSurvive() {
        // US-002 AC-4: 오늘 켜지 않은 앱이 첫 확정에서 통째로 빠지면 안 된다.
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left),
                                WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack", frame: right)],
                      on: [screen])
        slots.isLabEnabled = true

        // Slack을 안 켠 채로 수집·확정
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"])

        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.map(\.bundleID).sorted(),
                       ["com.chrome", "com.slack"])
    }

    func testSeedDoesNotOverwriteAnExistingAutoSlot() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"])

        slots.isLabEnabled = false
        slots.isLabEnabled = true // 다시 켜도 모아둔 자동 슬롯을 덮지 않는다

        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.first?.unitRect.x, 0.5)
    }

    // MARK: - 수집과 확정

    func testCollectStaysInMemoryUntilConfirm() throws {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true

        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        let onDisk = try JSONDecoder().decode(
            [String: Profile].self, from: Data(contentsOf: dir.appendingPathComponent("profiles.json")))
        XCTAssertEqual(onDisk["ext-1#auto"]?.apps.first?.unitRect.x, 0, "확정 전에는 파일에 닿지 않는다")
        XCTAssertTrue(slots.hasPendingCollect)

        XCTAssertTrue(slots.confirm(["ext-1"]))
        XCTAssertFalse(slots.hasPendingCollect, "확정하면 기다리는 변경이 없다")
    }

    func testAutoSlotUpdateModesChooseWhenCandidateIsUsedAndSaved() throws {
        let delayed = makeSlots(lab: true)
        delayed.capture(windows: [window("com.chrome", left)], on: [screen])
        delayed.collect(windows: [window("com.chrome", right)], on: [screen])
        XCTAssertEqual(delayed.source(for: screen.id)?.profile.apps.first?.unitRect.x, 0)
        XCTAssertTrue(delayed.hasPendingCollect)

        delayed.updateMode = .liveUntilDisconnect
        XCTAssertEqual(delayed.source(for: screen.id)?.profile.apps.first?.unitRect.x, 0.5)
        XCTAssertTrue(delayed.usesCandidate(for: screen.id))

        delayed.updateMode = .immediate
        XCTAssertFalse(delayed.hasPendingCollect)
        XCTAssertEqual(delayed.source(for: screen.id)?.profile.apps.first?.unitRect.x, 0.5)
        let onDisk = try JSONDecoder().decode(
            [String: Profile].self, from: Data(contentsOf: dir.appendingPathComponent("profiles.json"))
        )
        XCTAssertEqual(onDisk["ext-1#auto"]?.apps.first?.unitRect.x, 0.5)

        delayed.collect(windows: [window("com.chrome", left)], on: [screen])
        XCTAssertFalse(delayed.hasPendingCollect)
        let updatedOnDisk = try JSONDecoder().decode(
            [String: Profile].self, from: Data(contentsOf: dir.appendingPathComponent("profiles.json"))
        )
        XCTAssertEqual(updatedOnDisk["ext-1#auto"]?.apps.first?.unitRect.x, 0)
    }

    func testCollectCanStartAnAutoSlotFromVisibleApps() {
        let slots = makeSlots(lab: true)
        slots.collect(windows: [
            window("com.chrome", left),
            WindowInfo(id: 2, appBundleID: "com.linear", appName: "Linear", frame: right),
        ], on: [screen])

        XCTAssertTrue(slots.confirm(["ext-1"]))
        XCTAssertEqual(
            slots.source(for: "ext-1")?.profile.apps.map(\.bundleID).sorted(),
            ["com.chrome", "com.linear"]
        )
    }

    func testConfirmDoesNothingWhileLabIsOff() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        XCTAssertFalse(slots.confirm(["ext-1"]))
    }

    func testConfirmOnlyTouchesTheNamedScreens() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen, other])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen, other])

        XCTAssertTrue(slots.confirm(["ext-1"]))
        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .auto)
        XCTAssertEqual(slots.source(for: "ext-2")?.slot, .manual, "안 뽑은 화면은 그대로다")
    }

    func testConfirmAllSweepsEveryCandidate() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen, other])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen, other])

        XCTAssertTrue(slots.confirmAll())
        XCTAssertEqual(slots.source(for: "ext-1")?.slot, .auto)
        XCTAssertEqual(slots.source(for: "ext-2")?.slot, .auto)
    }

    func testManualSaveIsNotOvertakenByAStaleCandidate() {
        // 낡은 후보가 확정되면서 방금 저장한 배치를 이기면 안 된다.
        // 재현: 수집(배치 A) → 수동 저장(배치 B) → 앱 종료로 확정.
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true

        slots.collect(windows: [window("com.chrome", right)], on: [screen]) // 후보 = 오른쪽
        slots.capture(windows: [window("com.chrome", left)], on: [screen])  // 사람이 왼쪽으로 저장
        slots.confirmAll()                                                   // 종료 시 확정

        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.first?.unitRect.x, 0,
                       "방금 저장한 배치가 낡은 후보에 밀리면 안 된다")
    }

    // MARK: - 체크 해제 = 저장하지 않고 감지하지 않는다

    func testCaptureDoesNotTouchUncheckedApps() {
        // 실기기에서 나온 것: 체크를 껐는데 저장이 그 앱 좌표를 계속 갱신했다.
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.edit(screenID: "ext-1") { $0.apps[0].isEnabled = false }

        // 창을 옮긴 뒤 저장 — 체크가 꺼진 앱이니 좌표가 그대로여야 한다
        slots.capture(windows: [window("com.chrome", right)], on: [screen])

        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.first?.unitRect.x, 0,
                       "체크 해제한 앱은 저장이 건드리지 않는다")
        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.count, 1, "프로필에는 남는다")
    }

    func testCollectDoesNotTrackUncheckedApps() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.edit(screenID: "ext-1") { $0.apps[0].isEnabled = false }

        XCTAssertTrue(slots.targets(for: [screen]).isEmpty, "체크 해제한 앱은 감지하지 않는다")

        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"])
        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.first?.unitRect.x, 0,
                       "수집도 그 앱을 건드리지 않는다")
    }

    // MARK: - 수집 바탕과 대상

    func testTargetsPreferCandidateThenAutoThenManual() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        XCTAssertEqual(slots.targets(for: [screen]), ["com.chrome"], "수동 슬롯만 있을 때")

        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        XCTAssertEqual(slots.targets(for: [screen]), ["com.chrome"], "후보가 바탕이 돼도 같은 앱")
    }

    func testTargetsIncludeAppsKnownOnlyToTheManualSlot() {
        // 실기기에서 나온 것: 자동 슬롯이 이미 있는 상태에서 새 앱을 수동 저장하면,
        // 명부를 자동 슬롯에서만 가져오는 동안 그 앱은 수집에 영영 안 잡힌다.
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"]) // 자동 슬롯 = { chrome }

        // Linear를 화면에 띄운 채 수동 저장 — 수동 슬롯에만 들어간다
        slots.capture(windows: [window("com.chrome", left),
                                WindowInfo(id: 2, appBundleID: "com.linear", appName: "Linear", frame: right)],
                      on: [screen])

        XCTAssertEqual(slots.targets(for: [screen]).sorted(), ["com.chrome", "com.linear"],
                       "수동 슬롯에만 있는 앱도 따라가야 자동 슬롯에 도달한다")
    }

    func testTargetsAreEmptyForAnUnknownScreen() {
        XCTAssertTrue(makeSlots().targets(for: [screen]).isEmpty)
    }

    // MARK: - 목록·편집·삭제

    func testAllHidesTheAutoSlot() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true

        XCTAssertEqual(slots.all.count, 1, "화면 하나가 두 줄로 보이면 어느 것을 지울지 알 수 없다")
        XCTAssertEqual(slots.firstByName?.screenName, "LG")
    }

    func testEditAppliesToBothSlots() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        slots.confirm(["ext-1"])

        slots.edit(screenID: "ext-1") { $0.apps[0].isEnabled = false }

        // 한쪽만 고치면 이기는 슬롯이 바뀌는 순간 되살아난다 — 체크 상태는 슬롯마다 다를 이유가 없다.
        XCTAssertEqual(slots.source(for: "ext-1")?.profile.apps.first?.isEnabled, false, "이긴 슬롯")
        XCTAssertEqual(slots.all.first?.apps.first?.isEnabled, false, "수동 슬롯도 함께")
    }

    func testRemoveClearsBothSlotsAndTheCandidate() throws {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen])
        slots.isLabEnabled = true
        slots.collect(windows: [window("com.chrome", right)], on: [screen])
        XCTAssertEqual(try storedKeys(), ["ext-1", "ext-1#auto"])

        slots.remove(screenID: "ext-1")

        XCTAssertEqual(try storedKeys(), [], "한쪽만 남으면 지울 길 없는 유령이 된다")
        XCTAssertNil(slots.source(for: "ext-1"))
        XCTAssertFalse(slots.hasPendingCollect, "모으던 후보도 함께 버린다")
    }

    // MARK: - 엔진에 넘기는 모양

    func testResolvedPairNarrowsToOneValuePerScreen() {
        let slots = makeSlots()
        slots.capture(windows: [window("com.chrome", left)], on: [screen, other])

        let resolved = slots.resolvedWithSpaces(for: [screen, other])
        XCTAssertEqual(Set(resolved.keys), ["ext-1", "ext-2"], "엔진은 슬롯을 모른다")
    }
}
