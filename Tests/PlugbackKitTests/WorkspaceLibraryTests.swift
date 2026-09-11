import XCTest
@testable import PlugbackKit

/// 작업 환경 저장 규칙을 **자기 인터페이스에서** 검증한다 (D2·D4·D7·D9).
@MainActor
final class WorkspaceLibraryTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("library")

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private let screen = ScreenInfo(id: "ext-1", name: "LG",
                                    frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let other = ScreenInfo(id: "ext-2", name: "DELL",
                                   frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private var key: WorkspaceKey { WorkspaceKey(screenIDs: [screen.id]) }
    private var pairKey: WorkspaceKey { WorkspaceKey(screenIDs: [screen.id, other.id]) }
    private let left = CGRect(x: 0, y: 0, width: 500, height: 1000)
    private let right = CGRect(x: 500, y: 0, width: 500, height: 1000)
    private let onOther = CGRect(x: 1200, y: 0, width: 500, height: 1000)

    private func makeLibrary(autoSave: Bool = true) -> WorkspaceLibrary {
        WorkspaceLibrary(store: ProfileStore(directory: dir), isAutoSaveEnabled: autoSave)
    }

    private func window(_ bundleID: String, _ frame: CGRect, id: Int = 1, serverID: CGWindowID = 11) -> WindowInfo {
        WindowInfo(id: id, appBundleID: bundleID, appName: bundleID, frame: frame, windowServerID: serverID)
    }

    /// existing: 존재하는 창 전부. 기본은 열거한 창과 같다 — 다른 Space의 창을 흉내내려면 열거에서 빼고 여기에 넣는다.
    private func sample(_ windows: [WindowInfo], sequence: Int, failed: Set<String> = [],
                        existing: Set<CGWindowID>? = nil) -> DesktopObservation.Sample {
        DesktopObservation.Sample(sequence: sequence, windows: windows, unavailableBundleIDs: failed, spaceAvailability: nil,
                                  existingWindowServerIDs: existing ?? Set(windows.compactMap(\.windowServerID)))
    }

    private func onDisk() throws -> [String: WorkspaceRecord] {
        let data = try Data(contentsOf: dir.appendingPathComponent("workspaces.json"))
        return try JSONDecoder.plugback.decode(StoreFile.self, from: data).workspaces
    }

    private func blockWrites() throws {
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try Data("not-a-directory".utf8).write(to: dir)
    }

    // MARK: - 저장과 이력

    func testManualSaveIsTheRestoreSourceAndClearsPendingHistory() {
        let library = makeLibrary()
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 1), snapshot: nil, runningBundleIDs: [])
        XCTAssertTrue(library.hasPendingChanges(for: key))
        XCTAssertNil(library.saved(for: key), "이력만으로는 저장본이 생기지 않는다")

        XCTAssertTrue(library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 2), snapshot: nil))
        XCTAssertEqual(library.saved(for: key)?.savedBy, .manual)
        XCTAssertEqual(library.saved(for: key)?.placements.first?.unitRect.x, 0)
        XCTAssertFalse(library.hasPendingChanges(for: key), "수동 저장은 그 전 이력을 정리한다")
    }

    func testCollectStaysInMemoryUntilConfirm() throws {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 2), snapshot: nil, runningBundleIDs: ["com.chrome"])

        XCTAssertEqual(try onDisk()[key.raw]?.saved?.placements.first?.unitRect.x, 0, "확정 전에는 파일에 닿지 않는다")
        XCTAssertEqual(library.saved(for: key)?.placements.first?.unitRect.x, 0, "복원 소스도 그대로다 (A02)")
        XCTAssertTrue(library.hasPendingChanges(for: key))

        XCTAssertEqual(library.confirm(key: key), .saved)
        XCTAssertEqual(library.saved(for: key)?.savedBy, .auto)
        XCTAssertEqual(library.saved(for: key)?.placements.first?.unitRect.x, 0.5)
        XCTAssertEqual(try onDisk()[key.raw]?.saved?.placements.first?.unitRect.x, 0.5)
        XCTAssertFalse(library.hasPendingChanges(for: key))
    }

    func testConfirmSkipsWhenHistoryEqualsTheLastSave() {
        // 같은 내용의 자동 저장은 생략하고 저장 시각도 올리지 않는다 (A21)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        let savedAt = library.saved(for: key)?.savedAt
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", CGRect(x: 2, y: 1, width: 500, height: 1000))], sequence: 2),
                        snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertFalse(library.hasPendingChanges(for: key))
        XCTAssertEqual(library.confirm(key: key), .nothingToSave)
        XCTAssertEqual(library.saved(for: key)?.savedAt, savedAt)
        XCTAssertEqual(library.saved(for: key)?.savedBy, .manual)
    }

    func testManualSaveInvalidatesOlderObservations() {
        // 수동 저장 뒤 늦게 도착한 옛 관찰은 이력이 되지 않는다 (A22, S09)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 5), snapshot: nil)
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 3), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertFalse(library.hasPendingChanges(for: key), "저장 전에 시작한 관찰은 버린다")
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 6), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertTrue(library.hasPendingChanges(for: key))
    }

    func testAutoSaveOffDropsHistoryAndOnStartsFreshFromLaterObservations() {
        // OFF는 저장 전 이력을 지우고 마지막 저장본을 유지한다. 다시 ON이면 그 뒤의 관찰만 받는다 (A23·A24, D7)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 2), snapshot: nil, runningBundleIDs: ["com.chrome"])
        library.setAutoSave(false, currentSequence: 2)
        XCTAssertFalse(library.hasPendingChanges(for: key))
        XCTAssertEqual(library.confirm(key: key), .disabled)
        XCTAssertEqual(library.saved(for: key)?.placements.first?.unitRect.x, 0)

        library.setAutoSave(true, currentSequence: 4)
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 3), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertFalse(library.hasPendingChanges(for: key), "OFF 전에 시작한 관찰은 되살아나지 않는다")
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 5), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertTrue(library.hasPendingChanges(for: key))
    }

    func testAutoSaveOffStillTracksLinksAndClosures() {
        // 자동 저장 OFF에서도 창 연결과 닫힘 판정은 돈다 — 수동 저장과 닫힘 제외는 별개다 (3.4절)
        let library = makeLibrary(autoSave: false)
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        let placementID = library.saved(for: key)!.placements[0].id
        XCTAssertEqual(library.link(for: placementID)?.windowServerID, 11)

        library.collect(key: key, screens: [screen], sample: sample([], sequence: 2), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertEqual(library.record(for: key)?.closedPlacementIDs, [placementID])
        XCTAssertFalse(library.hasPendingChanges(for: key))
        XCTAssertEqual(library.saved(for: key)?.placements.count, 1, "저장본은 다음 저장 성공까지 그대로다")
    }

    // MARK: - 닫힌 창 (D9)

    func testClosedWindowIsExcludedUntilTheNextSuccessfulSave() throws {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11), window("com.slack", right, id: 2, serverID: 12),
        ], sequence: 1), snapshot: nil)
        let slackID = library.saved(for: key)!.placements.first { $0.bundleID == "com.slack" }!.id

        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", left, id: 1, serverID: 11)], sequence: 2),
                        snapshot: nil, runningBundleIDs: ["com.chrome", "com.slack"])
        XCTAssertEqual(library.record(for: key)?.closedPlacementIDs, [slackID])
        XCTAssertEqual(try onDisk()[key.raw]?.closedPlacementIDs, [slackID], "제외는 재실행을 넘어 보존된다 (W30)")
        XCTAssertEqual(library.pending[key]?.snapshot.placements.map(\.bundleID), ["com.chrome"])

        // 다시 열어 수집만 해도 제외는 풀리지 않는다
        library.collect(key: key, screens: [screen], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11), window("com.slack", right, id: 3, serverID: 13),
        ], sequence: 3), snapshot: nil, runningBundleIDs: ["com.chrome", "com.slack"])
        XCTAssertEqual(library.record(for: key)?.closedPlacementIDs, [slackID])

        XCTAssertEqual(library.confirm(key: key), .saved)
        XCTAssertTrue(library.record(for: key)!.closedPlacementIDs.isEmpty, "저장 성공이 제외를 정리한다")
        XCTAssertFalse(library.saved(for: key)!.placements.contains { $0.id == slackID })
        XCTAssertEqual(library.saved(for: key)?.placements.filter { $0.bundleID == "com.slack" }.count, 1, "다시 연 창은 새 기록으로 들어간다 (D4)")
    }

    func testClosureObservedElsewhereKeepsTheOriginalRecord() {
        // 다른 환경·연결 해제 중 닫힌 창의 원래 기록은 유지한다 (W19·W20)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        let placementID = library.saved(for: key)!.placements[0].id

        library.trackLinks(sample: sample([], sequence: 2), currentKey: nil)
        XCTAssertEqual(library.link(for: placementID)?.status, .lost(in: nil))
        XCTAssertTrue(library.record(for: key)!.closedPlacementIDs.isEmpty)

        library.confirmLink(placementID: placementID, bundleID: "com.chrome", windowServerID: 11)
        library.noteAppTerminated("com.chrome", currentKey: WorkspaceKey(screenIDs: ["home"]))
        XCTAssertEqual(library.link(for: placementID)?.status, .lost(in: WorkspaceKey(screenIDs: ["home"])))
        XCTAssertTrue(library.record(for: key)!.closedPlacementIDs.isEmpty)
    }

    func testAppTerminationInTheSameWorkspaceIsAClosure() {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        let placementID = library.saved(for: key)!.placements[0].id
        library.noteAppTerminated("com.chrome", currentKey: key)
        XCTAssertEqual(library.record(for: key)?.closedPlacementIDs, [placementID])
    }

    func testEnumerationFailureIsNotAClosure() {
        // 조회 실패를 창 0개로 판정하지 않는다 (O05·O07)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.collect(key: key, screens: [screen], sample: sample([], sequence: 2, failed: ["com.chrome"]), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertTrue(library.record(for: key)!.closedPlacementIDs.isEmpty)
        XCTAssertEqual(library.link(for: library.saved(for: key)!.placements[0].id)?.status, .live)
    }

    // MARK: - 같은 창의 이동과 새 창 (D4·S15)

    func testMovingTheSameWindowToAnotherScreenUpdatesItsSingleDestination() {
        let library = makeLibrary()
        library.capture(key: pairKey, screens: [screen, other], sample: sample([window("com.keynote", left)], sequence: 1), snapshot: nil)
        library.collect(key: pairKey, screens: [screen, other], sample: sample([window("com.keynote", onOther)], sequence: 2),
                        snapshot: nil, runningBundleIDs: ["com.keynote"])
        let pending = library.pending[pairKey]!.snapshot
        XCTAssertEqual(pending.placements.count, 1)
        XCTAssertEqual(pending.placements[0].screenID, other.id)
        XCTAssertEqual(library.saved(for: pairKey)?.placements[0].screenID, screen.id, "저장 완료 전 복원 기준은 A다 (3.3절)")
        XCTAssertEqual(library.confirm(key: pairKey), .saved)
        XCTAssertEqual(library.saved(for: pairKey)?.placements.map(\.screenID), [other.id])
    }

    func testANewWindowOnTheOtherScreenIsAddedNextToTheOldRecord() {
        let library = makeLibrary()
        library.capture(key: pairKey, screens: [screen, other], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.collect(key: pairKey, screens: [screen, other], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11), window("com.chrome", onOther, id: 2, serverID: 12),
        ], sequence: 2), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertEqual(library.pending[pairKey]?.snapshot.placements.map(\.screenID), [screen.id, other.id])
    }

    func testWindowOnAnotherSpaceIsNotAClosure() {
        // AX 열거는 다른 Space의 창을 돌려주지 않는다 — 창이 존재하는 한 부재는 닫힘이 아니다 (F-03.6, 실측 2026-09-11)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        let placementID = library.saved(for: key)!.placements[0].id
        library.collect(key: key, screens: [screen], sample: sample([], sequence: 2, existing: [11]), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertTrue(library.record(for: key)!.closedPlacementIDs.isEmpty)
        XCTAssertEqual(library.link(for: placementID)?.status, .live)
        XCTAssertEqual(library.pending[key]?.snapshot.placements.map(\.id), [placementID], "미관찰 기록은 보존한다")
        library.trackLinks(sample: sample([], sequence: 3, existing: [11]), currentKey: nil)
        XCTAssertEqual(library.link(for: placementID)?.status, .live)

        // 존재 목록을 얻지 못하면 판정하지 않는다
        library.collect(key: key, screens: [screen], sample: sample([], sequence: 4, existing: []), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertEqual(library.record(for: key)?.closedPlacementIDs, [placementID], "존재 목록에서도 빠지면 닫힘이다")
    }

    func testWindowsGatheredOnBuiltinByAScreenChangeAreNotDropped() {
        // 화면 분리·재연결로 macOS가 내장에 모은 창은 사용자의 이동이 아니다 — 이 환경에서 외장에 있는 것을 다시 본 뒤에야 판정한다 (W17·S17)
        let library = makeLibrary()
        let builtin = CGRect(x: -900, y: 0, width: 500, height: 500)
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.noteWorkspaceChanged() // 분리
        library.trackLinks(sample: sample([window("com.chrome", builtin)], sequence: 2), currentKey: nil)
        library.noteWorkspaceChanged() // 재연결 — 창은 아직 내장에 있다
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", builtin)], sequence: 3), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertEqual(library.pending[key]?.snapshot.placements.count, 1, "재연결 직후 내장에 있는 창의 외장 기록을 지우지 않는다")
        XCTAssertEqual(library.confirm(key: key), .nothingToSave)

        // 외장으로 돌아온 뒤 사용자가 내장으로 옮기면 그때 뺀다
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 4), snapshot: nil, runningBundleIDs: ["com.chrome"])
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", builtin)], sequence: 5), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertTrue(library.pending[key]!.snapshot.placements.isEmpty)
    }

    func testWindowMovedToBuiltinLeavesTheNextHistory() {
        // 연결을 유지한 채 내장으로 옮긴 창은 다음 저장 완료 뒤 외장 복원 대상에서 빠진다 (S17)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", CGRect(x: -900, y: 0, width: 500, height: 500))], sequence: 2),
                        snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertTrue(library.pending[key]!.snapshot.placements.isEmpty)
        XCTAssertEqual(library.saved(for: key)?.placements.count, 1, "저장 완료 전 복원은 기존 외장 위치 기준이다")
    }

    // MARK: - 앱 포함·제외 (D4)

    func testNewAppsAreIncludedByDefaultInManualAndAutoSaves() {
        // 외장에 새로 나타난 앱은 수동·자동 저장 모두 기본 포함한다 (R6)
        for automatic in [false, true] {
            let dir = temporaryDirectory("d4")
            defer { try? FileManager.default.removeItem(at: dir) }
            let library = WorkspaceLibrary(store: ProfileStore(directory: dir), isAutoSaveEnabled: automatic)
            library.capture(key: key, screens: [screen], sample: sample([window("com.existing", left)], sequence: 1), snapshot: nil)
            let arrived = [window("com.existing", left, id: 1, serverID: 11), window("com.new", right, id: 2, serverID: 12)]
            if automatic {
                library.collect(key: key, screens: [screen], sample: sample(arrived, sequence: 2), snapshot: nil, runningBundleIDs: ["com.existing"])
                XCTAssertTrue(library.pending[key]!.snapshot.placements.contains { $0.bundleID == "com.new" })
            }
            XCTAssertTrue(library.capture(key: key, screens: [screen], sample: sample(arrived, sequence: 3), snapshot: nil))
            XCTAssertTrue(library.saved(for: key)!.placements.contains { $0.bundleID == "com.new" }, "auto=\(automatic)")
            XCTAssertEqual(library.observedBundleIDs(for: key), ["com.existing", "com.new"])
        }
    }

    func testExcludedAppStaysOutOfSavesAndKeepsItsOldRecord() {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        XCTAssertEqual(library.setAppEnabled("com.chrome", false, displayName: "Chrome", in: key), .applied)
        XCTAssertFalse(library.isEnabled("com.chrome", in: key))

        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 2), snapshot: nil)
        XCTAssertEqual(library.saved(for: key)?.placements.first?.unitRect.x, 0, "제외한 앱은 저장이 건드리지 않는다 (US-006 AC-2)")
        XCTAssertTrue(library.observedBundleIDs(for: key).isEmpty)

        XCTAssertEqual(library.setAppEnabled("com.chrome", true, displayName: "Chrome", in: key), .applied)
        XCTAssertEqual(library.saved(for: key)?.placements.first?.unitRect.x, 0, "다시 켜면 저장돼 있던 자리다")
    }

    func testExcludingAnAppKeepsItsRecordThroughTheNextAutoSave() throws {
        // 제외는 이력에서도 기록을 지우지 않는다 — 실기기에서 제외 뒤 종료 저장으로 기록이 사라진 회귀 (2026-09-11)
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11), window("com.slack", right, id: 2, serverID: 12),
        ], sequence: 1), snapshot: nil)
        library.collect(key: key, screens: [screen], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11), window("com.slack", right, id: 2, serverID: 12),
        ], sequence: 2), snapshot: nil, runningBundleIDs: ["com.chrome", "com.slack"])
        XCTAssertEqual(library.setAppEnabled("com.slack", false, displayName: "Slack", in: key), .applied)
        XCTAssertEqual(library.pending[key]?.snapshot.placements.map(\.bundleID), ["com.chrome", "com.slack"])

        // 제외한 뒤 그 창을 내장으로 옮겨도 기록은 그대로다
        library.collect(key: key, screens: [screen], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11),
            window("com.slack", CGRect(x: -900, y: 0, width: 500, height: 500), id: 2, serverID: 12),
        ], sequence: 3), snapshot: nil, runningBundleIDs: ["com.chrome", "com.slack"])
        XCTAssertEqual(library.confirmAll(), .nothingToSave)
        XCTAssertEqual(try onDisk()[key.raw]?.saved?.placements.map(\.bundleID), ["com.chrome", "com.slack"])
        XCTAssertFalse(library.isEnabled("com.slack", in: key))
    }

    func testExcludingBeforeTheFirstSaveIsHonored() {
        // 첫 저장 전에 제외한 앱은 첫 저장에서도 뺀다 (S12)
        let library = makeLibrary()
        XCTAssertEqual(library.setAppEnabled("com.slack", false, displayName: "Slack", in: key), .applied)
        library.capture(key: key, screens: [screen], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11), window("com.slack", right, id: 2, serverID: 12),
        ], sequence: 1), snapshot: nil)
        XCTAssertEqual(library.saved(for: key)?.placements.map(\.bundleID), ["com.chrome"])
    }

    func testRemoveAppForgetsRecordsAndSelection() {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.setAppEnabled("com.chrome", false, displayName: "Chrome", in: key)
        XCTAssertTrue(library.removeApp("com.chrome", in: key))
        XCTAssertTrue(library.saved(for: key)!.placements.isEmpty)
        XCTAssertTrue(library.isEnabled("com.chrome", in: key), "잊은 앱은 다시 기본 포함이다")
    }

    // MARK: - 재실행과 연결

    func testRelaunchAdoptsThePlacementBySpotInsteadOfDuplicating() {
        // 재실행으로 연결이 사라져도 같은 앱·화면·Space의 자리를 갱신한다 — 기록이 겹겹이 쌓이지 않는다
        var library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        let placementID = library.saved(for: key)!.placements[0].id
        library = makeLibrary()
        XCTAssertNil(library.link(for: placementID))
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right, serverID: 99)], sequence: 1),
                        snapshot: nil, runningBundleIDs: ["com.chrome"])
        let pending = library.pending[key]!.snapshot.placements
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].id, placementID)
        XCTAssertEqual(pending[0].unitRect.x, 0.5)
        XCTAssertEqual(library.link(for: placementID)?.windowServerID, 99)
    }

    func testResavingASpacelessRecordAssignsItsSpaceInsteadOfDuplicating() throws {
        // 구버전 이전 기록(Space 없음)은 다시 저장하면 같은 앱·화면의 창이 이어받아 Space를 지정한다 — 실기기 중복 기록 회귀 (2026-09-11)
        let flat = WorkspaceSnapshot.flat(screen: screen, apps: [("com.chrome", UnitRect(left, in: screen.frame))], savedBy: .auto)
        let store = ProfileStore(directory: dir)
        try store.save([key: .with(flat)])
        let library = WorkspaceLibrary(store: store, isAutoSaveEnabled: true)
        let first = SpaceRuntimeID(1)
        let snapshot = SpaceSnapshot(
            displays: [.init(screenID: screen.id, spaces: [.init(runtimeID: first, opaqueName: "first", localOrder: 1, kind: .regular, isCurrent: true)])],
            membershipsByWindowServerID: [11: [first]]
        )
        XCTAssertTrue(library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: snapshot))
        let saved = library.saved(for: key)!
        XCTAssertEqual(saved.placements.map(\.id), [flat.placements[0].id], "기록 하나가 승격된다")
        XCTAssertEqual(saved.placements[0].space?.opaqueName, "first")

        // 이미 중복된 저장본(Space 없음 + Space 1)도 재실행 뒤 저장 한 번으로 정리된다
        var duplicated = flat
        duplicated.placements.append(WindowPlacement(bundleID: "com.chrome", displayName: "Chrome", screenID: screen.id,
                                                     space: SpaceHint(opaqueName: "first", localOrderHint: 1),
                                                     unitRect: UnitRect(left, in: screen.frame)))
        let dir2 = temporaryDirectory("dup")
        defer { try? FileManager.default.removeItem(at: dir2) }
        let store2 = ProfileStore(directory: dir2)
        try store2.save([key: .with(duplicated)])
        let relaunched = WorkspaceLibrary(store: store2, isAutoSaveEnabled: true)
        XCTAssertTrue(relaunched.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: snapshot))
        XCTAssertEqual(relaunched.saved(for: key)?.placements.map { $0.space?.opaqueName }, ["first"])
    }

    func testUserConfirmedLinkReplacesOtherLinksToTheSameWindow() {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([
            window("com.chrome", left, id: 1, serverID: 11), window("com.chrome", right, id: 2, serverID: 12),
        ], sequence: 1), snapshot: nil)
        let ids = library.saved(for: key)!.placements.map(\.id)
        library.confirmLink(placementID: ids[0], bundleID: "com.chrome", windowServerID: 12)
        XCTAssertEqual(library.link(for: ids[0])?.windowServerID, 12)
        XCTAssertNil(library.link(for: ids[1]), "같은 실제 창을 두 자리에 두지 않는다")
    }

    func testGroupConfirmCommitsTheWholeWorkspace() {
        // 화면 하나만 빠져도 이전 작업 환경 전체의 마지막 이력을 함께 확정한다 (R4)
        let library = makeLibrary()
        library.capture(key: pairKey, screens: [screen, other], sample: sample([window("com.app", left)], sequence: 1), snapshot: nil)
        library.collect(key: pairKey, screens: [screen, other], sample: sample([window("com.app", onOther)], sequence: 2),
                        snapshot: nil, runningBundleIDs: ["com.app"])
        XCTAssertEqual(library.confirm(key: pairKey), .saved)
        XCTAssertEqual(library.saved(for: pairKey)?.placements.map(\.screenID), [other.id])
    }

    // MARK: - 저장소 실패

    func testUnreadableStoreFreezesEveryChange() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("workspaces.json"), withIntermediateDirectories: true)
        let library = makeLibrary()
        XCTAssertTrue(library.isSaveBlocked)
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil, runningBundleIDs: [])
        XCTAssertFalse(library.hasPendingChanges(for: key))
        XCTAssertFalse(library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 2), snapshot: nil))
        XCTAssertEqual(library.confirm(key: key), .failed)
        XCTAssertNil(library.saved(for: key))
        XCTAssertTrue(library.allRecords.isEmpty)
    }

    func testConfirmPreservesHistoryWhenDiskWriteFails() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = makeLibrary()
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 1), snapshot: nil, runningBundleIDs: [])
        XCTAssertTrue(library.hasPendingChanges(for: key))

        try blockWrites()
        XCTAssertEqual(library.confirm(key: key), .failed)
        XCTAssertTrue(library.hasPendingChanges(for: key), "실패한 이력은 다음 저장 시도를 위해 남아야 한다")
        XCTAssertEqual(library.trouble, .writeFailed)

        try FileManager.default.removeItem(at: dir)
        XCTAssertEqual(library.confirm(key: key), .saved)
        XCTAssertFalse(library.hasPendingChanges(for: key))
        XCTAssertNil(library.trouble)
    }

    func testManualCaptureDoesNotPublishMemoryStateWhenDiskWriteFails() throws {
        let library = makeLibrary()
        try blockWrites()
        XCTAssertFalse(library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil))
        XCTAssertNil(library.saved(for: key), "재시작하면 사라질 배치를 저장된 것처럼 보이면 안 된다")
        XCTAssertEqual(library.trouble, .writeFailed)
    }

    func testEditAndRemoveKeepPublishedStateWhenDiskWriteFails() throws {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        try blockWrites()
        XCTAssertEqual(library.setAppEnabled("com.chrome", false, displayName: "Chrome", in: key), .failed)
        XCTAssertTrue(library.isEnabled("com.chrome", in: key))
        XCTAssertFalse(library.removeApp("com.chrome", in: key))
        XCTAssertEqual(library.saved(for: key)?.placements.count, 1)
        XCTAssertFalse(library.remove(key: key))
        XCTAssertNotNil(library.saved(for: key))
    }

    func testRemoveWorkspaceClearsEverything() throws {
        let library = makeLibrary()
        library.capture(key: key, screens: [screen], sample: sample([window("com.chrome", left)], sequence: 1), snapshot: nil)
        library.collect(key: key, screens: [screen], sample: sample([window("com.chrome", right)], sequence: 2), snapshot: nil, runningBundleIDs: ["com.chrome"])
        XCTAssertTrue(library.remove(key: key))
        XCTAssertTrue(try onDisk().isEmpty)
        XCTAssertNil(library.saved(for: key))
        XCTAssertFalse(library.hasPendingChanges(for: key))
    }
}
