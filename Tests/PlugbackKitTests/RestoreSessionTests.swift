import CoreGraphics
import XCTest
@testable import PlugbackKit

/// 복원 요청의 수명 (D8): 방문 대기·이동 안내·확인 필요·잠금 보류·취소.
@MainActor
final class RestoreSessionTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("session")
    private let builtin = ScreenInfo(id: "builtin", name: "Built-in",
                                     frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: true)
    private let external = ScreenInfo(id: "external", name: "External",
                                      frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let hint = SpaceHint(opaqueName: "saved-space", localOrderHint: 2)
    private let savedID = SpaceRuntimeID(1)
    private let builtinID = SpaceRuntimeID(2)
    private let externalID = SpaceRuntimeID(3)
    private let target = CGRect(x: 1000, y: 0, width: 500, height: 1000)

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var key: WorkspaceKey { WorkspaceKey(screenIDs: [external.id]) }

    private func snapshotRecord() -> WorkspaceRecord {
        .with(WorkspaceSnapshot(
            key: key,
            screens: [ScreenRecord(id: external.id, name: external.name, regularSpaces: [hint])],
            placements: [WindowPlacement(bundleID: "com.app", displayName: "App", screenID: external.id,
                                         space: hint, unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1))],
            savedAt: Date()
        ))
    }

    private struct Harness {
        let session: RestoreSession
        let reader: RestoreSessionSpaceReader
        let gateway: FakeWindowGateway
        let library: WorkspaceLibrary
        var lock: LockState = .unlocked
        var options = RestoreOptions()
        var touched: Set<CGWindowID> = []
    }

    private func makeHarness(record: WorkspaceRecord? = nil) -> Harness {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [WindowInfo(
            id: 1, appBundleID: "com.app", appName: "App",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11
        )]
        let reader = RestoreSessionSpaceReader()
        let library = makeLibrary(directory: dir, records: [record ?? snapshotRecord()])
        return Harness(
            session: RestoreSession(observation: DesktopObservation(gateway: gateway, spaceReader: reader),
                                    gateway: gateway, library: library),
            reader: reader, gateway: gateway, library: library
        )
    }

    private func environment(_ harness: Harness) -> RestoreSession.Environment {
        RestoreSession.Environment(options: { harness.options }, lockState: { harness.lock },
                                   spaceObservationEnabled: true,
                                   isTouched: { wsid, _ in harness.touched.contains(wsid) })
    }

    func testStrandedSpaceMovesThenWaitsForVisitThenRestores() async {
        var h = makeHarness()
        h.reader.availability = .available(strandedSnapshot())
        let started = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))

        XCTAssertTrue(h.gateway.moveCalls.isEmpty)
        XCTAssertEqual(started?.first?.entries.first?.outcome, .awaitingSpaceMove(sourceScreenID: builtin.id))

        h.reader.availability = .unavailable
        let unavailable = await h.session.resume(scope: .waiting, screens: [external], environment: environment(h))
        XCTAssertTrue(h.gateway.moveCalls.isEmpty)
        XCTAssertEqual(unavailable?.first?.entries.first?.outcome, .needsConfirmation(.spaceUnavailable),
                       "판정 불가는 안내 불가로 남고 창은 움직이지 않는다")

        // 확인 필요는 이벤트로 재개하지 않는다 — 사용자의 「남은 창 복원」만 재개한다 (RQ18·RQ19)
        h.reader.availability = .available(movedSnapshot(isCurrent: false))
        let awaited1 = await h.session.resume(scope: .waiting, screens: [external], environment: environment(h))
        XCTAssertNil(awaited1)
        let visitWait = await h.session.resume(scope: .user, screens: [external], environment: environment(h))
        XCTAssertEqual(visitWait?.first?.entries.first?.outcome, .awaitingVisit)

        h.reader.availability = .available(movedSnapshot(isCurrent: true))
        let visited = await h.session.resume(scope: .waiting, screens: [external], environment: environment(h))
        XCTAssertEqual(visited?.first?.entries.first?.outcome, .moved)
        XCTAssertEqual(h.gateway.moveCalls.map(\.target), [target])
        XCTAssertFalse(h.session.hasOpenItems)
        h.lock = .unlocked
    }

    func testInitiallyInactiveSpaceWaitsForTheVisitAndThenRestoresOnce() async {
        // 처음부터 비활성인 저장 Space도 요청이 있으면 방문 대기로 남는다 (P02, R1)
        let h = makeHarness()
        h.reader.availability = .available(movedSnapshot(isCurrent: false))
        let started = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(started?.first?.entries.first?.outcome, .awaitingVisit)
        XCTAssertTrue(h.session.hasOpenItems)

        h.reader.availability = .available(movedSnapshot(isCurrent: true))
        let visited = await h.session.resume(scope: .waiting, screens: [external], environment: environment(h))
        XCTAssertEqual(visited?.first?.entries.first?.outcome, .moved)
        XCTAssertEqual(h.gateway.moveCalls.map(\.target), [target])

        // 요청이 끝난 뒤의 평소 방문은 창을 움직이지 않는다 (P03)
        let awaited2 = await h.session.resume(scope: .waiting, screens: [external], environment: environment(h))
        XCTAssertNil(awaited2)
        XCTAssertEqual(h.gateway.moveCalls.count, 1)
    }

    func testCancelDuringObservationCannotReviveARecovery() async {
        let h = makeHarness()
        h.reader.availability = .available(strandedSnapshot())
        h.gateway.standardWindowsDelay = 0.02
        let env = environment(h)
        let restore = Task { await h.session.start(origin: .user, key: key, screens: [external], environment: env) }
        while h.gateway.standardWindowsCalls == 0 { await Task.yield() }
        h.session.cancel(reason: .userCancelled)
        _ = await restore.value

        XCTAssertFalse(h.session.hasOpenItems)
        let awaited3 = await h.session.resume(scope: .waiting, screens: [external], environment: env)
        XCTAssertNil(awaited3)
    }

    func testUserCancelLeavesCompletedWindowsAndBlocksLaterVisits() async {
        // 「남은 복원 취소」 뒤에는 방문해도 재개하지 않는다 (RQ24)
        let h = makeHarness()
        h.reader.availability = .available(movedSnapshot(isCurrent: false))
        _ = await h.session.start(origin: .automatic, key: key, screens: [external], environment: environment(h))
        h.session.cancel(reason: .userCancelled)
        XCTAssertEqual(h.session.results.first?.entries.first?.outcome, .cancelled(.userCancelled))

        h.reader.availability = .available(movedSnapshot(isCurrent: true))
        let awaited4 = await h.session.resume(scope: .waiting, screens: [external], environment: environment(h))
        XCTAssertNil(awaited4)
        XCTAssertTrue(h.gateway.moveCalls.isEmpty)
    }

    func testAutomaticRestoreOffCancelsOnlyAutomaticRequests() async {
        // 자동 복원 OFF는 자동으로 시작한 요청의 남은 작업만 취소한다 (RQ17·RQ21)
        let h = makeHarness()
        h.reader.availability = .available(movedSnapshot(isCurrent: false))
        _ = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        h.session.cancel(reason: .automaticRestoreDisabled, onlyAutomatic: true)
        XCTAssertTrue(h.session.hasOpenItems, "명시적 요청은 유지된다")

        _ = await h.session.start(origin: .automatic, key: key, screens: [external], environment: environment(h))
        h.session.cancel(reason: .automaticRestoreDisabled, onlyAutomatic: true)
        XCTAssertFalse(h.session.hasOpenItems)
        XCTAssertEqual(h.session.results.first?.entries.first?.outcome, .cancelled(.automaticRestoreDisabled))
    }

    func testLockHoldsUnsentMovesAndUnlockResumesOnlyThoseItems() async {
        // 잠금 중 미전송 이동을 보류하고, 해제 후 같은 요청의 보류 항목만 이어간다 (D8, 1.1절)
        var h = makeHarness()
        h.reader.availability = .available(movedSnapshot(isCurrent: true))
        h.lock = .locked
        let held = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(held?.first?.entries.first?.outcome, .held(.screenLocked))
        XCTAssertTrue(h.gateway.moveCalls.isEmpty)

        h.lock = .undetermined
        let undetermined = await h.session.resume(scope: .unlock, screens: [external], environment: environment(h))
        XCTAssertEqual(undetermined?.first?.entries.first?.outcome, .held(.lockStateUndetermined),
                       "판정 불가는 잠금 해제로 취급하지 않는다")

        h.lock = .unlocked
        let resumed = await h.session.resume(scope: .unlock, screens: [external], environment: environment(h))
        XCTAssertEqual(resumed?.first?.entries.first?.outcome, .moved)
        XCTAssertEqual(h.gateway.moveCalls.count, 1)
    }

    func testTouchedWindowIsProtectedOnlyDuringAutomaticRestore() async {
        // 자동 복원 도중 사용자가 조작한 창은 이번 복원에서 보호한다 (D5). 명시적 요청은 기존 규칙대로다.
        var h = makeHarness()
        h.reader.availability = .available(movedSnapshot(isCurrent: true))
        h.touched = [11]
        let automatic = await h.session.start(origin: .automatic, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(automatic?.first?.entries.first?.outcome, .skipped(.userInteraction))
        XCTAssertTrue(h.gateway.moveCalls.isEmpty)

        let user = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(user?.first?.entries.first?.outcome, .moved)
    }

    func testDirectAssignmentChoiceIsAppliedOnResumeAndReusedAsALink() async {
        // 직접 지정: 모호한 후보를 사용자가 고르고 「남은 창 복원」으로 적용하면 그 연결을 다음 복원에도 재사용한다 (W27)
        var h = makeHarness()
        h.gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "com.app", appName: "App", frame: CGRect(x: 1600, y: 100, width: 300, height: 300), windowServerID: 11),
            WindowInfo(id: 2, appBundleID: "com.app", appName: "App", frame: CGRect(x: 1100, y: 100, width: 300, height: 300), windowServerID: 12),
        ]
        h.reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin-current", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(savedID, hint.opaqueName, order: 1, current: true)]),
            ],
            membershipsByWindowServerID: [11: [savedID], 12: [savedID]]
        ))
        h.options = RestoreOptions(directAssignment: true)
        let asked = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(asked?.first?.entries.first?.outcome, .needsConfirmation(.ambiguousCandidates([11, 12])))
        XCTAssertEqual(h.session.candidates(for: h.library.saved(for: key)!.placements[0].id).count, 2)

        // 이벤트로는 재개하지 않는다; 사용자가 멀리 있는 창(11)을 고르고 남은 창 복원을 누른다
        let awaited5 = await h.session.resume(scope: .waiting, screens: [external], environment: environment(h))
        XCTAssertNil(awaited5)
        let placementID = h.library.saved(for: key)!.placements[0].id
        h.session.chooseWindow(placementID: placementID, windowServerID: 11)
        let applied = await h.session.resume(scope: .user, screens: [external], environment: environment(h))
        XCTAssertEqual(applied?.first?.entries.first?.outcome, .moved)
        XCTAssertEqual(h.gateway.moveCalls.map(\.windowID), [1])
        XCTAssertEqual(h.library.link(for: placementID)?.windowServerID, 11)

        // 다음 복원은 같은 선택을 다시 묻지 않는다
        h.gateway.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.app", appName: "App",
                                              frame: CGRect(x: 1700, y: 200, width: 300, height: 300), windowServerID: 11)
        let again = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(again?.first?.entries.first?.outcome, .moved)
        XCTAssertEqual(h.gateway.moveCalls.map(\.windowID), [1, 1])
    }

    func testTurningDirectAssignmentOffDiscardsOnlyUnconfirmedChoices() async {
        var h = makeHarness()
        h.gateway.windowsList = [
            WindowInfo(id: 1, appBundleID: "com.app", appName: "App", frame: CGRect(x: 1600, y: 100, width: 300, height: 300), windowServerID: 11),
            WindowInfo(id: 2, appBundleID: "com.app", appName: "App", frame: CGRect(x: 1100, y: 100, width: 300, height: 300), windowServerID: 12),
        ]
        h.reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin-current", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(savedID, hint.opaqueName, order: 1, current: true)]),
            ],
            membershipsByWindowServerID: [11: [savedID], 12: [savedID]]
        ))
        h.options = RestoreOptions(directAssignment: true)
        _ = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        let placementID = h.library.saved(for: key)!.placements[0].id
        h.session.chooseWindow(placementID: placementID, windowServerID: 11)
        h.session.discardUnconfirmedChoices()
        h.options = RestoreOptions(directAssignment: false)
        XCTAssertTrue(h.gateway.moveCalls.isEmpty, "전환만으로 이동하지 않는다 (RQ26)")

        let resumed = await h.session.resume(scope: .user, screens: [external], environment: environment(h))
        XCTAssertEqual(resumed?.first?.entries.first?.outcome, .moved)
        XCTAssertEqual(h.gateway.moveCalls.map(\.windowID), [2], "OFF 자동 배정은 가까운 창(12)을 고른다")
    }

    func testUncertainObservationNeverFallsBackToFlatRestore() async {
        let h = makeHarness()
        h.reader.availability = .unavailable
        let update = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(update?.first?.entries.first?.outcome, .needsConfirmation(.spaceUnavailable))
        XCTAssertTrue(h.gateway.moveCalls.isEmpty)
    }

    func testMissingSpaceIsNotReplacedByAnotherSpaceWithTheSameNumber() async {
        // 저장 Space가 없으면 확인 필요 — 번호가 같은 다른 Space를 고르지 않는다 (P06)
        let h = makeHarness()
        h.reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin-current", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(externalID, "another", order: 2, current: true)]),
            ],
            membershipsByWindowServerID: [11: [externalID]]
        ))
        let update = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        XCTAssertEqual(update?.first?.entries.first?.outcome, .needsConfirmation(.spaceMissing))
        XCTAssertTrue(h.gateway.moveCalls.isEmpty)
    }

    func testLegacyPlacementStillUsesTheOrdinaryRestorePath() async {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [WindowInfo(id: 1, appBundleID: "com.app", appName: "App",
                                          frame: CGRect(x: 100, y: 100, width: 300, height: 300))]
        let snapshot = WorkspaceSnapshot.flat(screen: external, apps: [("com.app", UnitRect(x: 0, y: 0, width: 0.5, height: 1))])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        let session = RestoreSession(observation: DesktopObservation(gateway: gateway, spaceReader: nil),
                                     gateway: gateway, library: library)
        let update = await session.start(origin: .user, key: snapshot.key, screens: [external],
                                         environment: RestoreSession.Environment(options: { RestoreOptions() }, spaceObservationEnabled: false))
        XCTAssertEqual(update?.first?.entries.first?.outcome, .moved)
    }

    func testDisablingTheAppCancelsItsOpenItemsOnly() async {
        let h = makeHarness()
        h.reader.availability = .available(movedSnapshot(isCurrent: false))
        _ = await h.session.start(origin: .user, key: key, screens: [external], environment: environment(h))
        h.session.cancelItems(bundleID: "com.other")
        XCTAssertTrue(h.session.hasOpenItems)
        h.session.cancelItems(bundleID: "com.app")
        XCTAssertEqual(h.session.results.first?.entries.first?.outcome, .cancelled(.targetRemoved))
    }

    // MARK: - snapshot helpers

    private func strandedSnapshot() -> SpaceSnapshot {
        SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinID, "builtin-current", order: 1, current: true),
                    space(savedID, hint.opaqueName, order: 2),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalID, "external-current", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [savedID]]
        )
    }

    private func movedSnapshot(isCurrent: Bool) -> SpaceSnapshot {
        SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinID, "builtin-current", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalID, "external-current", order: 1, current: !isCurrent),
                    space(savedID, hint.opaqueName, order: 2, current: isCurrent),
                ]),
            ],
            membershipsByWindowServerID: [11: [isCurrent ? savedID : builtinID]]
        )
    }

    private func space(_ id: SpaceRuntimeID, _ name: String, order: Int, current: Bool = false) -> SpaceSnapshot.Space {
        .init(runtimeID: id, opaqueName: name, localOrder: order, kind: .regular, isCurrent: current)
    }
}

@MainActor
final class RestoreSessionSpaceReader: SpaceReading {
    var availability: SpaceSnapshotAvailability = .unavailable
    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability { availability }
}
