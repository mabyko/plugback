import CoreGraphics
import XCTest
@testable import PlugbackKit

@MainActor
final class RestoreSessionTests: XCTestCase {
    private let screen = ScreenInfo(
        id: "external", name: "External",
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000),
        isBuiltin: false
    )
    private let hint = SpaceHint(opaqueName: "saved-space", localOrderHint: 1)

    func testRestoreAllWaitsForTheSavedSpaceThenCompletesOnVisit() async {
        let (session, reader, _) = makeSession()
        let resolved = resolvedProfile()

        reader.availability = .available(snapshot(savedSpaceIsCurrent: false))
        _ = await session.restoreAll(
            resolved: resolved, screens: [screen], options: RestoreOptions()
        )
        XCTAssertTrue(session.hasAwaitingVisit(in: resolved))

        reader.availability = .available(snapshot(savedSpaceIsCurrent: true))
        let results = await session.restoreVisited(
            resolved: resolved, screens: [screen], options: RestoreOptions()
        )

        XCTAssertEqual(results.first?.entries.first?.outcome, .skipped(.alreadyInPlace))
        XCTAssertFalse(session.hasAwaitingVisit(in: resolved))
    }

    func testInvalidateDropsOnlyTheNamedScreensAwaitingVisit() async {
        let (session, reader, _) = makeSession()
        let resolved = resolvedProfile()
        reader.availability = .available(snapshot(savedSpaceIsCurrent: false))
        _ = await session.restoreAll(
            resolved: resolved, screens: [screen], options: RestoreOptions()
        )

        session.invalidate(screens: [screen.id])

        XCTAssertFalse(session.hasAwaitingVisit(in: resolved))
    }

    func testDisabledAppIsDerivedOutWithoutDestroyingItsAwaitingVisit() async {
        let (session, reader, _) = makeSession()
        let resolved = resolvedProfile()
        reader.availability = .available(snapshot(savedSpaceIsCurrent: false))
        _ = await session.restoreAll(
            resolved: resolved, screens: [screen], options: RestoreOptions()
        )

        var disabled = resolved
        disabled[screen.id]?.profile.apps[0].isEnabled = false
        XCTAssertFalse(session.hasAwaitingVisit(in: disabled))
        XCTAssertTrue(session.awaitingBundleIDs(in: disabled).isEmpty)
        _ = await session.restoreVisited(
            resolved: disabled, screens: [screen], options: RestoreOptions()
        )

        XCTAssertTrue(session.hasAwaitingVisit(in: resolved))
    }

    func testDisabledScopeUsesLegacyRestoreWithoutAwaitingVisit() async {
        let (session, reader, gateway) = makeSession(scope: .none)
        let displaced = CGRect(x: 1200, y: 100, width: 400, height: 400)
        gateway.windowsList[0] = WindowInfo(
            id: 1, appBundleID: "com.app", appName: "App",
            frame: displaced, windowServerID: 11
        )
        let resolved = resolvedProfile()

        _ = await session.restoreAll(
            resolved: resolved, screens: [screen], options: RestoreOptions()
        )

        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1])
        XCTAssertFalse(session.hasAwaitingVisit(in: resolved))
        XCTAssertEqual(reader.snapshotCallCount, 0)
    }

    func testExistingProfileWithoutEnabledAppsStillReturnsAnEmptyResult() async {
        let (session, reader, _) = makeSession(scope: .none)
        var resolved = resolvedProfile()
        resolved[screen.id]?.profile.apps[0].isEnabled = false

        let results = await session.restoreAll(
            resolved: resolved, screens: [screen], options: RestoreOptions()
        )

        XCTAssertEqual(results.map(\.screenID), [screen.id])
        XCTAssertTrue(results[0].entries.isEmpty)
        XCTAssertEqual(reader.snapshotCallCount, 0)
    }

    func testVisitedPassDoesNotEmitEmptyResultsForOtherScreens() async {
        let other = ScreenInfo(
            id: "other", name: "Other",
            frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
            isBuiltin: false
        )
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app", "com.other"]
        gateway.windowsList = [
            WindowInfo(
                id: 1, appBundleID: "com.app", appName: "App",
                frame: CGRect(x: 1000, y: 0, width: 500, height: 500),
                windowServerID: 11
            ),
            WindowInfo(
                id: 2, appBundleID: "com.other", appName: "Other",
                frame: CGRect(x: 2000, y: 0, width: 500, height: 500),
                windowServerID: 22
            ),
        ]
        let reader = RestoreSessionSpaceReader()
        let session = RestoreSession(
            scope: SpaceRestoreScope(regular: true, fullscreen: false),
            observation: DesktopObservation(gateway: gateway, spaceReader: reader),
            gateway: gateway,
            spaceRelocator: nil
        )
        var resolved = resolvedProfile()
        resolved[other.id] = ResolvedProfile(profile: Profile(
            screenID: other.id,
            screenName: other.name,
            apps: [TargetApp(
                bundleID: "com.other", displayName: "Other",
                unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
            )]
        ))
        reader.availability = .available(snapshot(savedSpaceIsCurrent: false))
        let initial = await session.restoreAll(
            resolved: resolved, screens: [screen, other], options: RestoreOptions()
        )
        XCTAssertEqual(initial.first(where: { $0.screenID == other.id })?.entries.count, 1)

        reader.availability = .available(snapshot(savedSpaceIsCurrent: true))
        let visited = await session.restoreVisited(
            resolved: resolved, screens: [screen, other], options: RestoreOptions()
        )

        XCTAssertEqual(visited.map(\.screenID), [screen.id])
    }

    func testDisabledBindingUsesLegacyReopenWhileAnotherScopeIsEnabled() async {
        let (session, _, gateway) = makeSession(
            scope: SpaceRestoreScope(regular: true, fullscreen: false)
        )
        gateway.windowsList = []
        gateway.windowOnReopen["com.app"] = WindowInfo(
            id: 2, appBundleID: "com.app", appName: "App",
            frame: CGRect(x: 100, y: 100, width: 400, height: 400),
            windowServerID: 22
        )
        var resolved = resolvedProfile()
        resolved[screen.id]?.overlay?.byBundle["com.app"] = .fullscreen

        let results = await session.restoreAll(
            resolved: resolved, screens: [screen],
            options: RestoreOptions(reopenWindowless: true)
        )

        XCTAssertEqual(gateway.openWindowCalls, ["com.app"])
        XCTAssertEqual(results.first?.entries.first?.outcome, .moved)
        XCTAssertFalse(session.hasAwaitingVisit(in: resolved))
    }

    private func makeSession(
        scope: SpaceRestoreScope = SpaceRestoreScope(regular: true, fullscreen: false)
    ) -> (RestoreSession, RestoreSessionSpaceReader, FakeWindowGateway) {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [WindowInfo(
            id: 1, appBundleID: "com.app", appName: "App",
            frame: CGRect(x: 1000, y: 0, width: 500, height: 500),
            windowServerID: 11
        )]
        let reader = RestoreSessionSpaceReader()
        let observation = DesktopObservation(gateway: gateway, spaceReader: reader)
        return (
            RestoreSession(
                scope: scope,
                observation: observation,
                gateway: gateway,
                spaceRelocator: nil
            ),
            reader,
            gateway
        )
    }

    private func resolvedProfile() -> [String: ResolvedProfile] {
        [screen.id: ResolvedProfile(
            profile: Profile(
                screenID: screen.id,
                screenName: screen.name,
                apps: [TargetApp(
                    bundleID: "com.app", displayName: "App",
                    unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
                )]
            ),
            overlay: SlotSpaceOverlay(
                byBundle: ["com.app": .regular(hint)], regularSpaces: [hint]
            )
        )]
    }

    private func snapshot(savedSpaceIsCurrent: Bool) -> SpaceSnapshot {
        let saved = SpaceRuntimeID(1)
        let other = SpaceRuntimeID(2)
        return SpaceSnapshot(
            displays: [.init(screenID: screen.id, spaces: [
                .init(
                    runtimeID: saved, opaqueName: hint.opaqueName, localOrder: 1,
                    kind: .regular, isCurrent: savedSpaceIsCurrent
                ),
                .init(
                    runtimeID: other, opaqueName: "other-space", localOrder: 2,
                    kind: .regular, isCurrent: !savedSpaceIsCurrent
                ),
            ])],
            membershipsByWindowServerID: [11: [saved]]
        )
    }
}

@MainActor
private final class RestoreSessionSpaceReader: SpaceReading {
    var availability: SpaceSnapshotAvailability = .unavailable
    private(set) var snapshotCallCount = 0

    func stableSnapshot(
        windowServerIDs: [CGWindowID]
    ) async -> SpaceSnapshotAvailability {
        snapshotCallCount += 1
        return availability
    }
}
