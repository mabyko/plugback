import CoreGraphics
import XCTest
@testable import PlugbackKit

@MainActor
final class RestoreSessionTests: XCTestCase {
    private let builtin = ScreenInfo(
        id: "builtin", name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        isBuiltin: true
    )
    private let external = ScreenInfo(
        id: "external", name: "External",
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000),
        isBuiltin: false
    )
    private let hint = SpaceHint(opaqueName: "saved-space", localOrderHint: 2)
    private let savedID = SpaceRuntimeID(1)
    private let builtinID = SpaceRuntimeID(2)
    private let externalID = SpaceRuntimeID(3)

    func testStrandedSpaceMovesThenWaitsForVisitThenRestores() async {
        let (session, reader, gateway) = makeSession()
        let resolved = resolvedProfile()

        reader.availability = .available(strandedSnapshot())
        _ = await session.restore(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )

        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(session.recoveries.map(\.spaceNumber), [1])
        XCTAssertEqual(session.recoveries.first?.step, .move(sourceScreenID: builtin.id))

        reader.availability = .unavailable
        _ = await session.recheck(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )

        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(session.recoveries.first?.step, .unavailable)
        XCTAssertTrue(session.hasPendingRecovery)

        reader.availability = .available(movedSnapshot(isCurrent: false))
        _ = await session.recheck(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )

        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(session.recoveries.first?.step, .visit)

        reader.availability = .available(movedSnapshot(isCurrent: true))
        let visited = await session.recheck(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )

        XCTAssertEqual(visited?.first?.entries.first?.outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.map(\.target), [
            CGRect(x: 1000, y: 0, width: 500, height: 1000),
        ])
        XCTAssertFalse(session.hasPendingRecovery)
    }

    func testInitiallyInactiveSpaceNeverBecomesAGeneralVisitRestore() async {
        let (session, reader, gateway) = makeSession()
        let resolved = resolvedProfile()
        reader.availability = .available(movedSnapshot(isCurrent: false))

        _ = await session.restore(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )

        XCTAssertTrue(session.recoveries.isEmpty)
        XCTAssertFalse(session.hasPendingRecovery)
        reader.availability = .available(movedSnapshot(isCurrent: true))
        let rechecked = await session.recheck(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )
        XCTAssertNil(rechecked)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testRecoveryMatchesAppsByOpaqueIdentityNotOldOrderHint() async {
        let (session, reader, _) = makeSession()
        let oldHint = SpaceHint(opaqueName: hint.opaqueName, localOrderHint: 1)
        let resolved = [external.id: ResolvedProfile(
            profile: resolvedProfile()[external.id]!.profile,
            overlay: SlotSpaceOverlay(
                byBundle: ["com.app": .regular(oldHint)],
                regularSpaces: [hint]
            )
        )]
        reader.availability = .available(strandedSnapshot())

        _ = await session.restore(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )

        XCTAssertEqual(session.recoveries.first?.bundleIDs, ["com.app"])
    }

    func testCancelDuringObservationCannotReviveARecovery() async {
        let (session, reader, gateway) = makeSession()
        reader.availability = .available(strandedSnapshot())
        gateway.standardWindowsDelay = 0.02

        let restore = Task {
            await session.restore(
                resolved: resolvedProfile(), screens: [external],
                options: RestoreOptions()
            )
        }
        while gateway.standardWindowsCalls == 0 { await Task.yield() }
        session.cancel()
        _ = await restore.value

        XCTAssertTrue(session.recoveries.isEmpty)
        XCTAssertFalse(session.hasPendingRecovery)
    }

    func testStrandedSpaceWithoutTargetAppsDoesNotBlockTheSession() async {
        let (session, reader, _) = makeSession()
        reader.availability = .available(strandedSnapshot())
        let resolved = [external.id: ResolvedProfile(
            profile: Profile(screenID: external.id, screenName: external.name),
            overlay: SlotSpaceOverlay(regularSpaces: [hint])
        )]

        _ = await session.restore(
            resolved: resolved, screens: [external], options: RestoreOptions()
        )

        XCTAssertTrue(session.recoveries.isEmpty)
        XCTAssertFalse(session.hasPendingRecovery)
    }

    func testUncertainObservationNeverFallsBackToFlatRestore() async {
        let (session, reader, gateway) = makeSession()
        reader.availability = .unavailable

        let update = await session.restore(
            resolved: resolvedProfile(), screens: [external], options: RestoreOptions()
        )

        XCTAssertTrue(update.first?.entries.isEmpty == true)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testLegacyProfileStillUsesTheOrdinaryRestorePath() async {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [WindowInfo(
            id: 1, appBundleID: "com.app", appName: "App",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300)
        )]
        let session = RestoreSession(
            observation: DesktopObservation(gateway: gateway, spaceReader: nil),
            gateway: gateway
        )
        let profile = Profile(
            screenID: external.id,
            screenName: external.name,
            apps: [TargetApp(
                bundleID: "com.app", displayName: "App",
                unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1)
            )]
        )

        let update = await session.restore(
            resolved: [external.id: ResolvedProfile(profile: profile, overlay: nil)],
            screens: [external],
            options: RestoreOptions()
        )

        XCTAssertEqual(update.first?.entries.first?.outcome, .moved)
    }

    private func makeSession() -> (
        RestoreSession, RestoreSessionSpaceReader, FakeWindowGateway
    ) {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [WindowInfo(
            id: 1, appBundleID: "com.app", appName: "App",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300),
            windowServerID: 11
        )]
        let reader = RestoreSessionSpaceReader()
        return (
            RestoreSession(
                observation: DesktopObservation(gateway: gateway, spaceReader: reader),
                gateway: gateway
            ),
            reader,
            gateway
        )
    }

    private func resolvedProfile() -> [String: ResolvedProfile] {
        [external.id: ResolvedProfile(
            profile: Profile(
                screenID: external.id,
                screenName: external.name,
                apps: [TargetApp(
                    bundleID: "com.app", displayName: "App",
                    unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1)
                )]
            ),
            overlay: SlotSpaceOverlay(
                byBundle: ["com.app": .regular(hint)], regularSpaces: [hint]
            )
        )]
    }

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
            membershipsByWindowServerID: [11: [savedID]]
        )
    }

    private func space(
        _ id: SpaceRuntimeID, _ name: String, order: Int, current: Bool = false
    ) -> SpaceSnapshot.Space {
        .init(
            runtimeID: id, opaqueName: name, localOrder: order,
            kind: .regular, isCurrent: current
        )
    }
}

@MainActor
private final class RestoreSessionSpaceReader: SpaceReading {
    var availability: SpaceSnapshotAvailability = .unavailable

    func stableSnapshot(
        windowServerIDs: [CGWindowID]
    ) async -> SpaceSnapshotAvailability {
        availability
    }
}
