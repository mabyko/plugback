import CoreGraphics
import XCTest
@testable import PlugbackKit

@MainActor
final class SpaceAwareRestoreTests: XCTestCase {
    private let external = ScreenInfo(
        id: "EXTERNAL", name: "External",
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false
    )
    private let builtin = ScreenInfo(
        id: "BUILTIN", name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: true
    )

    func testCaptureBindsOneRegularSpaceAndRejectsAmbiguity() {
        let firstID = SpaceRuntimeID(1)
        let secondID = SpaceRuntimeID(2)
        let firstFrame = CGRect(x: 1100, y: 100, width: 400, height: 500)
        let first = window(
            1, bundleID: "com.app", frame: firstFrame, windowServerID: 11
        )
        let snapshot = makeSnapshot(
            externalSpaces: [
                space(firstID, "first", order: 1, current: true),
                space(secondID, "second", order: 2),
            ],
            memberships: [11: [firstID]]
        )

        let captured = CaptureEngine.capture(
            windows: [first], on: external, merging: nil, snapshot: snapshot
        )
        XCTAssertEqual(
            captured.overlay?.byBundle["com.app"],
            .regular(SpaceHint(opaqueName: "first", localOrderHint: 1))
        )

        let second = window(
            2, bundleID: "com.app",
            frame: CGRect(x: 1500, y: 100, width: 400, height: 500),
            windowServerID: 12
        )
        let ambiguous = CaptureEngine.capture(
            windows: [first, second],
            on: external,
            merging: captured,
            snapshot: makeSnapshot(
                externalSpaces: snapshot.displays[1].spaces,
                memberships: [11: [firstID], 12: [secondID]]
            )
        )

        XCTAssertEqual(ambiguous.profile.apps[0].unitRect, captured.profile.apps[0].unitRect)
        XCTAssertEqual(
            ambiguous.overlay?.byBundle["com.app"],
            .unresolved(reason: .multipleSpaces)
        )
    }

    func testCaptureRemembersEmptyRegularSpacesButNotFullscreenSpaces() {
        let snapshot = makeSnapshot(
            externalSpaces: [
                space(SpaceRuntimeID(1), "first", order: 1, current: true),
                space(
                    SpaceRuntimeID(2), "fullscreen", order: 2,
                    kind: .fullscreen
                ),
                space(SpaceRuntimeID(3), "empty", order: 3),
            ],
            memberships: [:]
        )

        let captured = CaptureEngine.capture(
            windows: [], on: external, merging: nil, snapshot: snapshot
        )

        XCTAssertEqual(captured.overlay?.regularSpaces, [
            SpaceHint(opaqueName: "first", localOrderHint: 1),
            SpaceHint(opaqueName: "empty", localOrderHint: 3),
        ])
    }

    func testProjectionShowsMoveThenOnlyAnActiveRecoveryShowsVisit() {
        let hint = SpaceHint(opaqueName: "saved", localOrderHint: 2)
        let app = TargetApp(
            bundleID: "com.app", displayName: "App",
            unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let resolved = ResolvedProfile(
            profile: Profile(
                screenID: external.id, screenName: external.name, apps: [app]
            ),
            overlay: SlotSpaceOverlay(
                byBundle: [app.bundleID: .regular(hint)], regularSpaces: [hint]
            )
        )
        let stranded = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(SpaceRuntimeID(1), hint.opaqueName, order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(SpaceRuntimeID(2), "external", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [:]
        )
        let names = [builtin.id: builtin.name, external.id: external.name]

        let passive = PlugbackController.spaceGroups(
            in: resolved, snapshot: stranded, screenNamesByID: names
        )
        XCTAssertEqual(passive.first?.kind, .regular(number: 1, state: .otherDisplay))
        XCTAssertNil(passive.first?.guide)

        let moveRecovery = RestoreSession.Recovery(
            id: .init(targetScreenID: external.id, opaqueName: hint.opaqueName),
            spaceNumber: 1,
            bundleIDs: [app.bundleID],
            step: .move(sourceScreenID: builtin.id)
        )
        let move = PlugbackController.spaceGroups(
            in: resolved,
            snapshot: stranded,
            recoveries: [moveRecovery],
            screenNamesByID: names
        )
        XCTAssertEqual(move.first?.kind, .regular(number: 1, state: .otherDisplay))
        XCTAssertEqual(
            move.first?.guide,
            .move(sourceScreenName: builtin.name, destinationScreenName: external.name)
        )

        let inactive = makeSnapshot(
            externalSpaces: [
                space(SpaceRuntimeID(2), "external", order: 1, current: true),
                space(SpaceRuntimeID(1), hint.opaqueName, order: 2),
            ],
            memberships: [:]
        )
        XCTAssertNil(PlugbackController.spaceGroups(
            in: resolved, snapshot: inactive, screenNamesByID: names
        ).first?.guide, "처음부터 비활성인 Space는 일반 방문 복원이 아니다")

        let recovery = RestoreSession.Recovery(
            id: .init(targetScreenID: external.id, opaqueName: hint.opaqueName),
            spaceNumber: 1,
            bundleIDs: [app.bundleID],
            step: .visit
        )
        let visit = PlugbackController.spaceGroups(
            in: resolved,
            snapshot: inactive,
            recoveries: [recovery],
            screenNamesByID: names
        )
        XCTAssertEqual(visit.first?.guide, .visit(screenName: external.name))
    }

    func testControllerContinuesOneGuidedRestoreAcrossDesktopEvents() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        let savedID = SpaceRuntimeID(1)
        let builtinID = SpaceRuntimeID(100)
        let externalID = SpaceRuntimeID(200)
        let savedFrame = CGRect(x: 1000, y: 0, width: 500, height: 1000)

        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(
            1, bundleID: "com.app", frame: savedFrame, windowServerID: 11
        )]
        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinID, "builtin", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(savedID, "saved", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [savedID]]
        ))
        let capture = await controller.captureNow()
        XCTAssertEqual(capture, .captured(appCount: 1))

        gateway.windowsList = [window(
            1, bundleID: "com.app",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300),
            windowServerID: 11
        )]
        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(savedID, "saved", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalID, "external", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [savedID]]
        ))

        _ = await controller.restoreNow()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(
            controller.sections.first?.spaceGroups.first?.guide,
            .move(sourceScreenName: builtin.name, destinationScreenName: external.name)
        )

        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinID, "builtin", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalID, "external", order: 1, current: true),
                    space(savedID, "saved", order: 2),
                ]),
            ],
            membershipsByWindowServerID: [11: [savedID]]
        ))
        await controller.missionControlClosed()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(
            controller.sections.first?.spaceGroups.first?.guide,
            .visit(screenName: external.name)
        )

        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinID, "builtin", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalID, "external", order: 1),
                    space(savedID, "saved", order: 2, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [savedID]]
        ))
        await controller.activeSpaceChanged()

        XCTAssertEqual(gateway.moveCalls.map(\.target), [savedFrame])
        XCTAssertNil(controller.sections.first?.spaceGroups.first?.guide)
    }

    func testAuthoritativeRestoreCanDrainAnEarlierObservation() async {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", windowServerID: 11)]
        gateway.standardWindowsDelay = 0.02
        let observation = DesktopObservation(gateway: gateway, spaceReader: nil)

        let earlier = Task { await observation.sample() }
        while gateway.standardWindowsCalls == 0 { await Task.yield() }
        await observation.drain()
        _ = await observation.sample()
        _ = await earlier.value

        XCTAssertEqual(gateway.standardWindowsHighWater, 1)
    }

    private func makeSnapshot(
        externalSpaces: [SpaceSnapshot.Space],
        memberships: [CGWindowID: [SpaceRuntimeID]]
    ) -> SpaceSnapshot {
        SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(SpaceRuntimeID(100), "builtin", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: externalSpaces),
            ],
            membershipsByWindowServerID: memberships
        )
    }

    private func space(
        _ id: SpaceRuntimeID,
        _ name: String?,
        order: Int,
        kind: SpaceKind = .regular,
        current: Bool = false
    ) -> SpaceSnapshot.Space {
        .init(
            runtimeID: id, opaqueName: name, localOrder: order,
            kind: kind, isCurrent: current
        )
    }

    private func window(
        _ id: Int,
        bundleID: String,
        frame: CGRect = CGRect(x: 1000, y: 0, width: 500, height: 1000),
        windowServerID: CGWindowID?
    ) -> WindowInfo {
        WindowInfo(
            id: id, appBundleID: bundleID, appName: bundleID, frame: frame,
            windowServerID: windowServerID
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("guided-space-restore-\(UUID().uuidString)")
    }

    private func makeController(
        gateway: FakeWindowGateway,
        screens: FakeScreenProvider,
        reader: FakeSpaceReader,
        directory: URL
    ) -> PlugbackController {
        PlugbackController(
            gateway: gateway,
            screenProvider: screens,
            store: ProfileStore(directory: directory),
            defaults: UserDefaults(
                suiteName: "guided-space-restore-\(UUID().uuidString)"
            )!,
            spaceReader: reader,
            activeSpaceDebounceInterval: 0
        )
    }
}

@MainActor
private final class FakeSpaceReader: SpaceReading {
    var availability: SpaceSnapshotAvailability = .unavailable

    func stableSnapshot(
        windowServerIDs: [CGWindowID]
    ) async -> SpaceSnapshotAvailability {
        availability
    }
}
