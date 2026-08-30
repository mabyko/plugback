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

    func testCaptureBindsTheSelectedFrameAndRejectsMultipleSpaces() throws {
        let e1 = SpaceRuntimeID(1)
        let e2 = SpaceRuntimeID(2)
        let firstFrame = CGRect(x: 1100, y: 100, width: 400, height: 500)
        let first = window(1, bundleID: "com.app", frame: firstFrame, windowServerID: 11)
        let snapshot = makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 1, current: true),
                             space(e2, "other", order: 2)],
            memberships: [11: [e1]]
        )

        let captured = CaptureEngine.capture(
            windows: [first], on: external, merging: nil, snapshot: snapshot
        )
        XCTAssertEqual(captured.profile.apps.first?.unitRect, UnitRect(firstFrame, in: external.frame))
        XCTAssertEqual(
            captured.overlay?.byBundle["com.app"],
            .regular(SpaceHint(opaqueName: "stable-name", localOrderHint: 1))
        )

        let existingRect = captured.profile.apps[0].unitRect
        let second = window(
            2, bundleID: "com.app",
            frame: CGRect(x: 1550, y: 100, width: 400, height: 500), windowServerID: 12
        )
        let ambiguous = CaptureEngine.capture(
            windows: [first, second],
            on: external,
            merging: captured,
            snapshot: makeSnapshot(
                externalSpaces: snapshot.displays[1].spaces,
                memberships: [11: [e1], 12: [e2]]
            )
        )
        XCTAssertEqual(ambiguous.profile.apps[0].unitRect, existingRect)
        XCTAssertEqual(
            ambiguous.overlay?.byBundle["com.app"], .unresolved(.multipleSpaces)
        )
    }

    func testCaptureRejectsABindingWhoseNameIsDuplicatedAcrossScreens() {
        let externalSpace = SpaceRuntimeID(1)
        let builtinSpace = SpaceRuntimeID(2)
        let target = window(1, bundleID: "com.app", windowServerID: 11)
        let existing = ResolvedProfile(
            profile: Profile(
                screenID: external.id,
                screenName: external.name,
                apps: [TargetApp(
                    bundleID: "com.app",
                    displayName: "App",
                    unitRect: UnitRect(x: 0, y: 0, width: 1, height: 1)
                )]
            ),
            overlay: nil
        )
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinSpace, "duplicated", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalSpace, "duplicated", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [externalSpace]]
        )

        let captured = CaptureEngine.capture(
            windows: [target], on: external, merging: existing, snapshot: snapshot
        )

        XCTAssertEqual(captured.overlay?.byBundle["com.app"], .unresolved(.nameUnavailable))
        XCTAssertEqual(captured.overlay?.regularSpaces, [])
    }

    func testCaptureTreatsAWindowJoinedToAnotherScreensFullscreenAsStranded() {
        let externalSpace = SpaceRuntimeID(1)
        let builtinFullscreen = SpaceRuntimeID(2)
        let target = window(1, bundleID: "com.app", windowServerID: 11)
        let existing = ResolvedProfile(
            profile: Profile(
                screenID: external.id,
                screenName: external.name,
                apps: [TargetApp(
                    bundleID: "com.app",
                    displayName: "App",
                    unitRect: UnitRect(x: 0, y: 0, width: 1, height: 1)
                )]
            ),
            overlay: nil
        )
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(
                        builtinFullscreen, "builtin-fullscreen", order: 1,
                        kind: .fullscreen, current: true
                    ),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalSpace, "external", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [builtinFullscreen]]
        )

        let captured = CaptureEngine.capture(
            windows: [target], on: external, merging: existing, snapshot: snapshot
        )

        XCTAssertEqual(captured.overlay?.byBundle["com.app"], .unresolved(.stranded))
    }

    func testCaptureRemembersRegularSpacesWithoutWindows() {
        let first = SpaceRuntimeID(1)
        let fullscreen = SpaceRuntimeID(2)
        let second = SpaceRuntimeID(3)
        let unnamed = SpaceRuntimeID(4)
        let snapshot = makeSnapshot(
            externalSpaces: [
                space(first, "first", order: 1, current: true),
                space(fullscreen, "fullscreen", order: 2, kind: .fullscreen),
                space(second, "second", order: 3),
                space(unnamed, nil, order: 4),
            ],
            memberships: [:]
        )

        let captured = CaptureEngine.capture(
            windows: [], on: external, merging: nil, snapshot: snapshot
        )

        XCTAssertTrue(captured.profile.apps.isEmpty)
        XCTAssertEqual(captured.overlay?.regularSpaces, [
            SpaceHint(opaqueName: "first", localOrderHint: 1),
            SpaceHint(opaqueName: "second", localOrderHint: 3),
        ])
    }

    func testCardGroupsUseStableLocalSpaceNumbers() {
        let first = TargetApp(
            bundleID: "com.first", displayName: "First",
            unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let fullscreen = TargetApp(
            bundleID: "com.fullscreen", displayName: "Fullscreen",
            unitRect: UnitRect(x: 0, y: 0, width: 1, height: 1)
        )
        let unresolved = TargetApp(
            bundleID: "com.unresolved", displayName: "Unresolved",
            unitRect: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        )
        let resolved = ResolvedProfile(
            profile: Profile(
                screenID: external.id, screenName: external.name,
                apps: [first, fullscreen, unresolved]
            ),
            overlay: SlotSpaceOverlay(
                byBundle: [
                    first.bundleID: .regular(SpaceHint(
                        opaqueName: "external-first", localOrderHint: 1
                    )),
                    fullscreen.bundleID: .fullscreen,
                    unresolved.bundleID: .unresolved(.spaceMissing),
                ],
                regularSpaces: [
                    SpaceHint(opaqueName: "external-first", localOrderHint: 1),
                    SpaceHint(opaqueName: "external-empty", localOrderHint: 2),
                ]
            )
        )
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(SpaceRuntimeID(100), "builtin", order: 1, current: true),
                    space(SpaceRuntimeID(101), "builtin-full", order: 2, kind: .fullscreen),
                ]),
                .init(screenID: external.id, spaces: [
                    space(SpaceRuntimeID(1), "external-first", order: 1, current: true),
                    space(SpaceRuntimeID(2), "external-empty", order: 2),
                ]),
            ],
            membershipsByWindowServerID: [:]
        )

        let groups = PlugbackController.spaceGroups(in: resolved, snapshot: snapshot)
        XCTAssertEqual(groups.map(\.kind), [
            .regular(number: 1, state: .current),
            .regular(number: 2, state: .inactive),
            .fullscreen,
            .unresolved,
        ])
        XCTAssertEqual(groups.map { $0.apps.map(\.bundleID) }, [
            [first.bundleID], [], [fullscreen.bundleID], [unresolved.bundleID],
        ])

        let unavailable = PlugbackController.spaceGroups(in: resolved, snapshot: nil)
        XCTAssertEqual(unavailable.first?.kind, .regular(number: 1, state: .unknown))

        let movedAndAdded = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(SpaceRuntimeID(100), "builtin", order: 1, current: true),
                    space(SpaceRuntimeID(2), "external-empty", order: 2),
                ]),
                .init(screenID: external.id, spaces: [
                    space(SpaceRuntimeID(1), "external-first", order: 1, current: true),
                    space(SpaceRuntimeID(3), "new-unsaved", order: 2),
                ]),
            ],
            membershipsByWindowServerID: [:]
        )
        let movedGroups = PlugbackController.spaceGroups(in: resolved, snapshot: movedAndAdded)
        XCTAssertEqual(movedGroups.filter {
            if case .regular = $0.kind { true } else { false }
        }.map(\.kind), [
            .regular(number: 1, state: .current),
            .regular(number: 2, state: .otherDisplay),
        ], "live-but-unsaved Space must not become a saved restore-plan row")
        XCTAssertTrue(PlugbackController.spaceConfigurationDiffers(
            in: resolved, snapshot: movedAndAdded, targetConnected: true
        ))

        let missing = SpaceSnapshot(
            displays: [.init(screenID: external.id, spaces: [
                space(SpaceRuntimeID(1), "external-first", order: 1, current: true),
            ])],
            membershipsByWindowServerID: [:]
        )
        XCTAssertEqual(
            PlugbackController.spaceGroups(in: resolved, snapshot: missing)[1].kind,
            .regular(number: 2, state: .missing)
        )
        let changedKind = SpaceSnapshot(
            displays: [.init(screenID: external.id, spaces: [
                space(SpaceRuntimeID(1), "external-first", order: 1, current: true),
                space(
                    SpaceRuntimeID(2), "external-empty", order: 2,
                    kind: .fullscreen
                ),
            ])],
            membershipsByWindowServerID: [:]
        )
        XCTAssertEqual(
            PlugbackController.spaceGroups(in: resolved, snapshot: changedKind)[1].kind,
            .regular(number: 2, state: .unknown)
        )
        XCTAssertFalse(PlugbackController.spaceConfigurationDiffers(
            in: resolved, snapshot: nil, targetConnected: false
        ), "a disconnected target has no live configuration to compare")
    }

    func testAutoCollectKeepsAnEmptyRegularSpaceForRelocation() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slots = ProfileSlots(
            store: ProfileStore(directory: directory), isLabEnabled: true
        )
        let remembered = SpaceRuntimeID(1)
        slots.collect(
            windows: [], on: [external],
            snapshot: makeSnapshot(
                externalSpaces: [space(
                    remembered, "empty-space", order: 1, current: true
                )],
                memberships: [:]
            )
        )

        XCTAssertTrue(slots.hasPendingCollect)
        XCTAssertTrue(slots.confirm([external.id]))
        let resolved = slots.resolvedWithSpaces(for: [external])
        XCTAssertEqual(
            resolved[external.id]?.overlay?.regularSpaces,
            [SpaceHint(opaqueName: "empty-space", localOrderHint: 1)]
        )

        let plan = SpaceRelocationPlanner.next(
            resolved: resolved, screens: [external], snapshot: SpaceSnapshot(
                displays: [
                    .init(screenID: builtin.id, spaces: [
                        space(SpaceRuntimeID(100), "builtin", order: 1, current: true),
                        space(remembered, "empty-space", order: 2),
                    ]),
                    .init(screenID: external.id, spaces: [
                        space(SpaceRuntimeID(200), "external", order: 1, current: true),
                    ]),
                ],
                membershipsByWindowServerID: [:]
            )
        )
        guard case .move(let move) = plan else {
            return XCTFail("앱 없는 Space도 화면 소속 복원 대상이어야 한다")
        }
        XCTAssertEqual(move.runtimeID, remembered)
        XCTAssertEqual(move.request.destinationScreenID, external.id)
    }

    func testPlannerMovesAnInactiveSpacePastABlockedCurrentSpace() {
        let current = SpaceRuntimeID(1)
        let movable = SpaceRuntimeID(2)
        let resolved = [external.id: ResolvedProfile(
            profile: Profile(screenID: external.id, screenName: external.name),
            overlay: SlotSpaceOverlay(regularSpaces: [
                SpaceHint(opaqueName: "current", localOrderHint: 1),
                SpaceHint(opaqueName: "movable", localOrderHint: 2),
            ])
        )]
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(current, "current", order: 1, current: true),
                    space(movable, "movable", order: 2),
                ]),
                .init(screenID: external.id, spaces: [
                    space(SpaceRuntimeID(100), "external", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [:]
        )

        guard case .move(let move) = SpaceRelocationPlanner.next(
            resolved: resolved, screens: [external], snapshot: snapshot
        ) else { return XCTFail("막힌 현재 Space가 뒤의 안전한 이동을 막으면 안 된다") }
        XCTAssertEqual(move.runtimeID, movable)
    }

    func testCaptureRecordsSingleFullscreenIntentButRejectsSplitView() {
        let fullscreen = SpaceRuntimeID(2)
        let stored = UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let existing = ResolvedProfile(
            profile: Profile(
                screenID: external.id, screenName: external.name,
                apps: [TargetApp(bundleID: "com.app", displayName: "App", unitRect: stored)]
            ),
            overlay: nil
        )
        let target = window(
            1, bundleID: "com.app", frame: external.frame,
            fullscreenState: .fullscreen, windowServerID: 11
        )
        let single = makeSnapshot(
            externalSpaces: [space(
                fullscreen, "fullscreen", order: 2, kind: .fullscreen, current: true
            )],
            memberships: [11: [fullscreen]]
        )

        let discovered = CaptureEngine.capture(
            windows: [target], on: external, merging: nil, snapshot: single
        )
        XCTAssertEqual(discovered.profile.apps.map(\.bundleID), ["com.app"])
        XCTAssertEqual(discovered.overlay?.byBundle["com.app"], .fullscreen)

        let captured = CaptureEngine.capture(
            windows: [target], on: external, merging: existing, snapshot: single
        )
        XCTAssertEqual(captured.profile.apps.first?.unitRect, stored)
        XCTAssertEqual(captured.overlay?.byBundle["com.app"], .fullscreen)

        let partner = window(
            2, bundleID: "com.partner", frame: external.frame,
            fullscreenState: .fullscreen, windowServerID: 22
        )
        let split = makeSnapshot(
            externalSpaces: single.displays[1].spaces,
            memberships: [11: [fullscreen], 22: [fullscreen]]
        )
        let rejected = CaptureEngine.capture(
            windows: [target, partner], on: external, merging: captured, snapshot: split
        )
        XCTAssertEqual(
            rejected.overlay?.byBundle["com.app"], .unresolved(.unsupportedSpace)
        )
    }

    func testPlannerFailsClosedWithoutFallingBackToLegacy() {
        let e1 = SpaceRuntimeID(1)
        let e2 = SpaceRuntimeID(2)
        let target = window(1, bundleID: "com.app", windowServerID: 11)
        let profile = Profile(
            screenID: external.id, screenName: external.name,
            apps: [TargetApp(bundleID: "com.app", displayName: "App",
                             unitRect: UnitRect(x: 0, y: 0, width: 1, height: 1))]
        )
        let bound = ResolvedProfile(
            profile: profile,
            overlay: SlotSpaceOverlay(byBundle: [
                "com.app": .regular(SpaceHint(opaqueName: "stable-name", localOrderHint: 99)),
            ])
        )
        let current = makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 2, current: true),
                             space(e2, "other", order: 1)],
            memberships: [11: [e1]]
        )
        XCTAssertEqual(
            RestoreEngine.selectSpaceWindow(
                bundleID: "com.app", in: bound, on: external,
                windows: [target], snapshot: current
            ),
            .window(target)
        )
        XCTAssertEqual(
            RestoreEngine.selectSpaceWindow(
                bundleID: "com.app",
                in: ResolvedProfile(profile: profile, overlay: nil),
                on: external, windows: [target], snapshot: current
            ),
            .legacy
        )

        let inactive = makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 1),
                             space(e2, "other", order: 2, current: true)],
            memberships: [11: [e1]]
        )
        XCTAssertEqual(selection(bound, [target], inactive), .inactive)

        let duplicate = makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 1, current: true),
                             space(e2, "stable-name", order: 2)],
            memberships: [11: [e1]]
        )
        XCTAssertEqual(selection(bound, [target], duplicate), .unavailable)
        XCTAssertEqual(selection(bound, [target], nil), .unavailable)
        XCTAssertEqual(selection(bound, [target], currentWithMembership([])), .unavailable)
        XCTAssertEqual(
            selection(bound, [target], currentWithMembership([e1, e2])), .unavailable
        )

        let missingName = makeSnapshot(
            externalSpaces: [space(e1, nil, order: 1, current: true)],
            memberships: [11: [e1]]
        )
        XCTAssertEqual(selection(bound, [target], missingName), .unavailable)

        let unknownSpace = makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 1,
                                   kind: .unknown(99), current: true)],
            memberships: [11: [e1]]
        )
        XCTAssertEqual(selection(bound, [target], unknownSpace), .unavailable)

        let unknown = window(
            1, bundleID: "com.app", fullscreenState: .unknown, windowServerID: 11
        )
        XCTAssertEqual(selection(bound, [unknown], current), .unavailable)
        let fullscreen = window(
            1, bundleID: "com.app", fullscreenState: .fullscreen, windowServerID: 11
        )
        XCTAssertEqual(selection(bound, [fullscreen], current), .fullscreen)
        let fullscreenWhileRegularBindingIsInactive = makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 1),
                             space(e2, "fullscreen", order: 2,
                                   kind: .fullscreen, current: true)],
            memberships: [11: [e2]]
        )
        XCTAssertEqual(
            selection(bound, [fullscreen], fullscreenWhileRegularBindingIsInactive), .fullscreen
        )

        let fullscreenSpace = makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 1,
                                   kind: .fullscreen, current: true)],
            memberships: [11: [e1]]
        )
        XCTAssertEqual(selection(bound, [target], fullscreenSpace), .fullscreen)

        let stranded = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(e1, "stable-name", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(e2, "other", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [e1]]
        )
        XCTAssertEqual(selection(bound, [target], stranded), .unavailable)

        let secondWindow = window(2, bundleID: "com.app", windowServerID: 12)
        let twoWindows = makeSnapshot(
            externalSpaces: current.displays[1].spaces,
            memberships: [11: [e1], 12: [e1]]
        )
        XCTAssertEqual(selection(bound, [target, secondWindow], twoWindows), .unavailable)
    }

    func testRestoreRejectsABoundNameDuplicatedAcrossScreens() {
        let externalSpace = SpaceRuntimeID(1)
        let builtinSpace = SpaceRuntimeID(2)
        let target = window(1, bundleID: "com.app", windowServerID: 11)
        let bound = ResolvedProfile(
            profile: Profile(
                screenID: external.id,
                screenName: external.name,
                apps: [TargetApp(
                    bundleID: "com.app",
                    displayName: "App",
                    unitRect: UnitRect(x: 0, y: 0, width: 1, height: 1)
                )]
            ),
            overlay: SlotSpaceOverlay(byBundle: [
                "com.app": .regular(SpaceHint(
                    opaqueName: "duplicated", localOrderHint: 1
                )),
            ])
        )
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinSpace, "duplicated", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalSpace, "duplicated", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [externalSpace]]
        )

        XCTAssertEqual(selection(bound, [target], snapshot), .unavailable)
    }

    func testSpacePredictionMatchesRestoreTruthAndOmitsNoResult() async {
        let runtimeID = SpaceRuntimeID(1)
        let target = TargetApp(
            bundleID: "com.app", displayName: "App",
            unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let resolved = ResolvedProfile(
            profile: Profile(
                screenID: external.id, screenName: external.name, apps: [target]
            ),
            overlay: SlotSpaceOverlay(byBundle: [
                target.bundleID: .regular(SpaceHint(
                    opaqueName: "stable-name", localOrderHint: 1
                )),
            ])
        )
        let displaced = window(
            1, bundleID: target.bundleID,
            frame: CGRect(x: 100, y: 100, width: 300, height: 300),
            windowServerID: 11
        )
        let current = makeSnapshot(
            externalSpaces: [space(runtimeID, "stable-name", order: 1, current: true)],
            memberships: [11: [runtimeID]]
        )
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = [target.bundleID]
        gateway.windowsList = [displaced]

        let predictions = RestoreEngine.predict(
            resolved: resolved, on: external, windows: [displaced], snapshot: current,
            running: gateway.runningBundleIDs, scope: .all
        )
        let pass = await RestoreEngine.restore(
            resolved: [external.id: resolved], screens: [external], windows: [displaced],
            snapshot: current, scope: .all, using: gateway
        )
        XCTAssertEqual(predictions[target.bundleID], .willMove)
        XCTAssertEqual(pass.results.first?.entries.first?.outcome, .moved)

        let inactive = makeSnapshot(
            externalSpaces: [
                space(runtimeID, "stable-name", order: 1),
                space(SpaceRuntimeID(2), "other", order: 2, current: true),
            ],
            memberships: [11: [runtimeID]]
        )
        let waiting = RestoreEngine.predict(
            resolved: resolved, on: external, windows: [displaced], snapshot: inactive,
            running: gateway.runningBundleIDs, scope: .all
        )
        let waitingPass = await RestoreEngine.restore(
            resolved: [external.id: resolved], screens: [external], windows: [displaced],
            snapshot: inactive, scope: .all, using: gateway
        )
        XCTAssertNil(waiting[target.bundleID])
        XCTAssertTrue(waitingPass.results.first?.entries.isEmpty == true)

        let stopped = RestoreEngine.predict(
            resolved: resolved, on: external, windows: [displaced], snapshot: inactive,
            running: [], scope: .all
        )
        XCTAssertEqual(stopped[target.bundleID], .willSkip(.appNotRunning))
    }

    func testSpaceRestoreHonorsMinimizedOption() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        let runtimeID = SpaceRuntimeID(1)
        let savedFrame = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        let displacedFrame = CGRect(x: 100, y: 100, width: 300, height: 300)
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(
            1, bundleID: "com.app", frame: savedFrame, windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(runtimeID, "desktop-3", order: 1, current: true)],
            memberships: [11: [runtimeID]]
        ))
        await controller.captureNow()

        gateway.windowsList = [window(
            1, bundleID: "com.app", frame: displacedFrame,
            isMinimized: true, windowServerID: 11
        )]
        guard case .restored(let skipped) = await controller.restoreNow() else {
            return XCTFail("restore did not run")
        }
        XCTAssertEqual(skipped.first?.entries.first?.outcome, .skipped(.minimized))
        XCTAssertTrue(gateway.windowsList[0].isMinimized)
        XCTAssertTrue(gateway.moveCalls.isEmpty)

        controller.restoreMinimized = true
        guard case .restored(let restored) = await controller.restoreNow() else {
            return XCTFail("restore did not run")
        }
        XCTAssertEqual(restored.first?.entries.first?.outcome, .moved)
        XCTAssertFalse(gateway.windowsList[0].isMinimized)
        XCTAssertEqual(gateway.windowsList[0].frame, savedFrame)
    }

    func testSlotLifecycleKeepsProfileAndOverlayTogether() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("space-aware-slots-\(UUID().uuidString)")
        let slots = ProfileSlots(store: ProfileStore(directory: directory), isLabEnabled: true)
        let runtimeID = SpaceRuntimeID(1)
        let snapshot = makeSnapshot(
            externalSpaces: [space(runtimeID, "stable-name", order: 1, current: true)],
            memberships: [11: [runtimeID], 12: [runtimeID]]
        )
        let first = window(1, bundleID: "com.app", windowServerID: 11)

        slots.capture(windows: [first], on: [external], snapshot: snapshot)
        var resolved = try XCTUnwrap(slots.resolvedWithSpaces(for: [external])[external.id])
        XCTAssertEqual(
            resolved.overlay?.byBundle["com.app"],
            .regular(SpaceHint(opaqueName: "stable-name", localOrderHint: 1))
        )

        let second = window(
            2, bundleID: "com.second",
            frame: CGRect(x: 1500, y: 0, width: 500, height: 1000), windowServerID: 12
        )
        slots.addTarget(windows: [second], on: [external], snapshot: snapshot)
        slots.collect(windows: [first, second], on: [external], snapshot: snapshot)
        XCTAssertTrue(slots.confirm([external.id]))
        resolved = try XCTUnwrap(slots.resolvedWithSpaces(for: [external])[external.id])
        XCTAssertEqual(Set(resolved.profile.apps.map(\.bundleID)), ["com.app", "com.second"])
        XCTAssertEqual(
            Set(resolved.overlay?.byBundle.keys.map { $0 } ?? []), ["com.app", "com.second"]
        )

        slots.edit(screenID: external.id) {
            $0.apps.removeAll { $0.bundleID == "com.app" }
        }
        resolved = try XCTUnwrap(slots.resolvedWithSpaces(for: [external])[external.id])
        XCTAssertNil(resolved.overlay?.byBundle["com.app"])

        slots.remove(screenID: external.id)
        XCTAssertTrue(slots.resolvedWithSpaces(for: [external]).isEmpty)
    }

    func testCollectAfterManualSaveKeepsTheWinningManualOverlay() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slots = ProfileSlots(store: ProfileStore(directory: directory), isLabEnabled: false)
        let firstID = SpaceRuntimeID(1)
        let secondID = SpaceRuntimeID(2)
        let first = window(1, bundleID: "com.first", windowServerID: 11)
        let second = window(2, bundleID: "com.second", windowServerID: 22)

        slots.capture(windows: [first], on: [external])
        slots.isLabEnabled = true
        slots.collect(windows: [first], on: [external])
        slots.confirm([external.id]) // 예전 자동 슬롯에는 메모리 overlay가 없다.

        slots.capture(
            windows: [first], on: [external],
            snapshot: makeSnapshot(
                externalSpaces: [space(firstID, "first", order: 1, current: true),
                                 space(secondID, "second", order: 2)],
                memberships: [11: [firstID]]
            )
        )
        slots.capture(
            windows: [second], on: [external],
            snapshot: makeSnapshot(
                externalSpaces: [space(firstID, "first", order: 1),
                                 space(secondID, "second", order: 2, current: true)],
                memberships: [22: [secondID]]
            )
        )

        slots.collect(
            windows: [second], on: [external],
            snapshot: makeSnapshot(
                externalSpaces: [space(firstID, "first", order: 1),
                                 space(secondID, "second", order: 2, current: true)],
                memberships: [22: [secondID]]
            )
        )
        slots.confirm([external.id])

        let overlay = try XCTUnwrap(
            slots.resolvedWithSpaces(for: [external])[external.id]?.overlay
        )
        XCTAssertEqual(overlay.byBundle["com.first"], .regular(.init(
            opaqueName: "first", localOrderHint: 1
        )))
        XCTAssertEqual(overlay.byBundle["com.second"], .regular(.init(
            opaqueName: "second", localOrderHint: 2
        )))
    }

    func testCollectDropsAnAppMovedFromExternalToBuiltin() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slots = ProfileSlots(store: ProfileStore(directory: directory), isLabEnabled: true)
        let fullscreenID = SpaceRuntimeID(1)
        let externalFullscreen = window(
            1, bundleID: "com.buzz", frame: external.frame,
            fullscreenState: .fullscreen, windowServerID: 11
        )
        slots.capture(
            windows: [externalFullscreen], on: [external],
            snapshot: makeSnapshot(
                externalSpaces: [space(
                    fullscreenID, "buzz-fullscreen", order: 1,
                    kind: .fullscreen, current: true
                )],
                memberships: [11: [fullscreenID]]
            )
        )

        let builtinWindow = window(
            1, bundleID: "com.buzz",
            frame: CGRect(x: 0, y: 0, width: 500, height: 1000), windowServerID: 11
        )
        slots.collect(
            windows: [builtinWindow], on: [external],
            snapshot: makeSnapshot(
                externalSpaces: [space(
                    SpaceRuntimeID(2), "external", order: 1, current: true
                )],
                memberships: [11: [SpaceRuntimeID(100)]]
            )
        )
        XCTAssertTrue(slots.confirm([external.id]))

        let resolved = try XCTUnwrap(slots.resolvedWithSpaces(for: [external])[external.id])
        XCTAssertFalse(resolved.profile.apps.contains { $0.bundleID == "com.buzz" })
        XCTAssertNil(resolved.overlay?.byBundle["com.buzz"])
        XCTAssertTrue(slots.targets(for: [external]).contains("com.buzz"))
    }

    func testCollectDiscoversInactiveFullscreenWithoutAXVisit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slots = ProfileSlots(store: ProfileStore(directory: directory), isLabEnabled: true)
        let fullscreenID = SpaceRuntimeID(2)
        let builtinWindow = window(
            1, bundleID: "dev.zed.Zed",
            frame: CGRect(x: 0, y: 0, width: 500, height: 1000), windowServerID: 11
        )

        slots.collect(
            windows: [builtinWindow], on: [external],
            snapshot: makeSnapshot(
                externalSpaces: [
                    space(SpaceRuntimeID(1), "external", order: 1, current: true),
                    space(fullscreenID, "zed-fullscreen", order: 2, kind: .fullscreen),
                ],
                memberships: [11: [SpaceRuntimeID(100)]],
                fullscreenCandidates: [
                    FullscreenSpaceCandidate(
                        bundleID: "dev.zed.Zed", displayName: "Zed",
                        screenID: external.id, runtimeID: fullscreenID
                    ),
                ]
            )
        )
        XCTAssertTrue(slots.confirm([external.id]))

        let resolved = try XCTUnwrap(slots.resolvedWithSpaces(for: [external])[external.id])
        XCTAssertEqual(resolved.profile.apps.map(\.bundleID), ["dev.zed.Zed"])
        XCTAssertEqual(resolved.overlay?.byBundle["dev.zed.Zed"], .fullscreen)
    }

    func testManualCaptureDoesNotDiscoverAnInactiveFullscreenCandidate() {
        let fullscreenID = SpaceRuntimeID(2)
        let snapshot = makeSnapshot(
            externalSpaces: [
                space(SpaceRuntimeID(1), "regular", order: 1, current: true),
                space(fullscreenID, "zed-fullscreen", order: 2, kind: .fullscreen),
            ],
            memberships: [:],
            fullscreenCandidates: [
                FullscreenSpaceCandidate(
                    bundleID: "dev.zed.Zed", displayName: "Zed",
                    screenID: external.id, runtimeID: fullscreenID
                ),
            ]
        )

        let captured = CaptureEngine.capture(
            windows: [], on: external, merging: nil, snapshot: snapshot
        )

        XCTAssertFalse(captured.profile.apps.contains { $0.bundleID == "dev.zed.Zed" })
        XCTAssertNil(captured.overlay?.byBundle["dev.zed.Zed"])
    }

    func testControllerRestoresEachExternalSpaceOnlyWhenVisitedAndOnlyOnce() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        let e1 = SpaceRuntimeID(1)
        let e2 = SpaceRuntimeID(2)
        let firstFrame = CGRect(x: 1000, y: 0, width: 400, height: 1000)
        let secondFrame = CGRect(x: 1400, y: 0, width: 600, height: 1000)

        gateway.runningBundleIDs = ["com.first", "com.second"]
        gateway.windowsList = [window(
            1, bundleID: "com.first", frame: firstFrame, windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1, current: true),
                             space(e2, "desktop-4", order: 2)],
            memberships: [11: [e1]]
        ))
        await controller.captureNow()

        gateway.windowsList = [window(
            2, bundleID: "com.second", frame: secondFrame, windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1),
                             space(e2, "desktop-4", order: 2, current: true)],
            memberships: [22: [e2]]
        ))
        await controller.captureNow()

        // 재연결 직후 현재 Space가 Desktop 3이라고 가정한다. Desktop 4 창은 AX 열거에 없다.
        gateway.windowsList = [window(
            1, bundleID: "com.first",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1, current: true),
                             space(e2, "desktop-4", order: 2)],
            memberships: [11: [e1]]
        ))
        await controller.externalScreensAppeared()
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1])
        XCTAssertEqual(gateway.windowsList[0].frame, firstFrame)

        // Desktop 4를 방문했을 때만 두 번째 binding이 복원된다.
        gateway.windowsList = [window(
            2, bundleID: "com.second",
            frame: CGRect(x: 200, y: 100, width: 300, height: 300), windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1),
                             space(e2, "desktop-4", order: 2, current: true)],
            memberships: [22: [e2]]
        ))
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1, 2])
        XCTAssertEqual(gateway.windowsList[0].frame, secondFrame)
        XCTAssertEqual(gateway.standardWindowsCallsAtMove.last.map { $0 + 2 },
                       gateway.standardWindowsCalls,
                       "복원 authoritative 열거 뒤에는 자동 수집과 예측 읽기만 와야 한다")

        let callsAfterCompletion = gateway.standardWindowsCalls
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1, 2])
        XCTAssertEqual(gateway.standardWindowsCalls, callsAfterCompletion + 1,
                       "완료 뒤 Space 방문은 복원하지 않고 자동 수집만 한다")
    }

    func testReconnectMovesBoundWindowFromBuiltinCurrentSpace() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        let externalSpace = SpaceRuntimeID(1)
        let savedFrame = CGRect(x: 1200, y: 100, width: 500, height: 700)

        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(
            1, bundleID: "com.app", frame: savedFrame, windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(externalSpace, "regular", order: 1, current: true)],
            memberships: [11: [externalSpace]]
        ))
        await controller.captureNow()

        gateway.windowsList = [window(
            1, bundleID: "com.app",
            frame: CGRect(x: 100, y: 100, width: 700, height: 500), windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(externalSpace, "regular", order: 1, current: true)],
            memberships: [11: [SpaceRuntimeID(100)]]
        ))

        await controller.externalScreensAppeared()

        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1])
        XCTAssertEqual(gateway.windowsList[0].frame, savedFrame)
    }

    func testManualRegularSpaceRestoreWorksWhileAutoSlotIsOff() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let relocator = FakeSpaceRelocator()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader,
            relocator: relocator, autoSlot: false,
            regularSpaceRestore: true, fullscreenRestore: false,
            directory: directory
        )
        controller.restoreMode = .manual
        let bound = SpaceRuntimeID(1)
        let externalCurrent = SpaceRuntimeID(2)
        let builtinCurrent = SpaceRuntimeID(100)
        let fullscreenFollower = SpaceRuntimeID(101)
        let savedFrame = CGRect(x: 1100, y: 100, width: 500, height: 700)

        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(
            1, bundleID: "com.app", frame: savedFrame, windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(bound, "return-me", order: 1, current: true)],
            memberships: [11: [bound]]
        ))
        await controller.captureNow()
        XCTAssertEqual(controller.restoreSource, .manual)
        XCTAssertNil(controller.lastCollectedAt)

        let before = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinCurrent, "builtin", order: 1, current: true),
                    space(bound, "return-me", order: 2),
                    space(fullscreenFollower, "fullscreen", order: 3, kind: .fullscreen),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalCurrent, "external", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [bound], 22: [fullscreenFollower]]
        )
        let after = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinCurrent, "builtin", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalCurrent, "external", order: 1, current: true),
                    space(fullscreenFollower, "fullscreen", order: 2, kind: .fullscreen),
                    space(bound, "return-me", order: 3),
                ]),
            ],
            membershipsByWindowServerID: [11: [bound], 22: [fullscreenFollower]]
        )
        reader.availability = .available(before)
        relocator.onRelocate = { request in
            reader.availability = .available(after)
            return true
        }
        gateway.windowsList = []

        await controller.restoreNow()

        XCTAssertEqual(relocator.requests, [SpaceRelocation(
            sourceScreenID: builtin.id,
            sourceLocalOrder: 2,
            destinationScreenID: external.id,
            expectedSourceCount: 3,
            expectedDestinationCount: 1
        )])

        let afterVisit = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(builtinCurrent, "builtin", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: [
                    space(externalCurrent, "external", order: 1),
                    space(fullscreenFollower, "fullscreen", order: 2, kind: .fullscreen),
                    space(bound, "return-me", order: 3, current: true),
                ]),
            ],
            membershipsByWindowServerID: [11: [bound], 22: [fullscreenFollower]]
        )
        gateway.windowsList = [window(
            1, bundleID: "com.app",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11
        )]
        reader.availability = .available(afterVisit)
        await controller.restoreNow()
        XCTAssertEqual(gateway.moveCalls.last?.target, savedFrame)

        controller.labRegularSpaceRestore = false
        reader.availability = .available(before)
        await controller.restoreNow()
        XCTAssertEqual(relocator.requests.count, 1, "스위치 OFF이면 Space 자체는 움직이지 않아야 한다")
    }

    func testAllSpaceFeaturesOffKeepManualCaptureOnLegacyPath() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader,
            autoSlot: false, regularSpaceRestore: false, fullscreenRestore: false,
            directory: directory
        )
        gateway.windowsList = [window(
            1, bundleID: "com.app",
            frame: CGRect(x: 1000, y: 0, width: 500, height: 1000),
            windowServerID: 11
        )]

        await controller.captureNow()

        XCTAssertTrue(reader.requestedWindowIDs.isEmpty)
        XCTAssertEqual(controller.restoreSource, .manual)
    }

    func testSpaceVisitCollectsOnlyWhileAutoSlotIsEnabled() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader,
            autoSlot: true, regularSpaceRestore: false, fullscreenRestore: false,
            directory: directory
        )
        controller.restoreMode = .manual
        let runtimeID = SpaceRuntimeID(1)
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(
            1, bundleID: "com.app",
            frame: CGRect(x: 1000, y: 0, width: 500, height: 1000),
            windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(runtimeID, "regular", order: 1, current: true)],
            memberships: [11: [runtimeID]]
        ))
        await controller.captureNow()

        gateway.runningBundleIDs.insert("com.new")
        gateway.windowsList = [window(
            1, bundleID: "com.app",
            frame: CGRect(x: 1500, y: 0, width: 500, height: 1000),
            windowServerID: 11
        ), window(
            2, bundleID: "com.new",
            frame: CGRect(x: 1000, y: 0, width: 500, height: 1000),
            windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(runtimeID, "regular", order: 1, current: true)],
            memberships: [11: [runtimeID], 22: [runtimeID]]
        ))
        await controller.activeSpaceChanged()
        XCTAssertNotNil(controller.lastCollectedAt)
        XCTAssertTrue(controller.hasPendingCollect)
        controller.confirmCandidates(for: [external.id])
        let stored = try? JSONDecoder().decode(
            [String: Profile].self,
            from: Data(contentsOf: directory.appendingPathComponent("profiles.json"))
        )
        XCTAssertEqual(stored?["EXTERNAL#auto"]?.apps.map(\.bundleID).sorted(), ["com.app", "com.new"])
        XCTAssertEqual(controller.restoreSource, .auto)
        XCTAssertEqual(
            controller.profile?.apps.map(\.bundleID).sorted(), ["com.app", "com.new"],
            "자동 슬롯은 방문한 Space에서 처음 본 앱도 등록해야 한다"
        )

        controller.labAutoSlot = false
        let collectedAt = controller.lastCollectedAt
        XCTAssertFalse(controller.hasPendingCollect)
        gateway.runningBundleIDs.insert("com.ignored")
        gateway.windowsList.append(window(
            3, bundleID: "com.ignored",
            frame: CGRect(x: 1200, y: 0, width: 500, height: 1000),
            windowServerID: 33
        ))
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(runtimeID, "regular", order: 1, current: true)],
            memberships: [11: [runtimeID], 22: [runtimeID], 33: [runtimeID]]
        ))
        await controller.activeSpaceChanged()
        XCTAssertEqual(controller.lastCollectedAt, collectedAt)
        XCTAssertFalse(controller.hasPendingCollect)
        controller.labAutoSlot = true
        XCTAssertEqual(controller.profile?.apps.map(\.bundleID).sorted(), ["com.app", "com.new"])
    }

    func testManualRestoreOnlyHandlesTheCurrentSpace() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        let e1 = SpaceRuntimeID(1)
        let e2 = SpaceRuntimeID(2)
        let firstFrame = CGRect(x: 1000, y: 0, width: 400, height: 1000)
        let secondFrame = CGRect(x: 1400, y: 0, width: 600, height: 1000)
        gateway.runningBundleIDs = ["com.first", "com.second"]

        gateway.windowsList = [window(
            1, bundleID: "com.first", frame: firstFrame, windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1, current: true),
                             space(e2, "desktop-4", order: 2)],
            memberships: [11: [e1]]
        ))
        await controller.captureNow()

        gateway.windowsList = [window(
            2, bundleID: "com.second", frame: secondFrame, windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1),
                             space(e2, "desktop-4", order: 2, current: true)],
            memberships: [22: [e2]]
        ))
        await controller.captureNow()
        controller.restoreMode = .manual

        gateway.windowsList = [window(
            1, bundleID: "com.first",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1, current: true),
                             space(e2, "desktop-4", order: 2)],
            memberships: [11: [e1]]
        ))
        await controller.restoreNow()
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1])

        let displacedSecondFrame = CGRect(x: 200, y: 100, width: 300, height: 300)
        gateway.windowsList = [window(
            2, bundleID: "com.second", frame: displacedSecondFrame, windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(e1, "desktop-3", order: 1),
                             space(e2, "desktop-4", order: 2, current: true)],
            memberships: [22: [e2]]
        ))
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1])
        XCTAssertEqual(gateway.windowsList[0].frame, displacedSecondFrame)
    }

    func testFullscreenBindingIsDetectedAndCompletedWithoutMoving() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        let regular = SpaceRuntimeID(1)
        let fullscreen = SpaceRuntimeID(2)
        gateway.runningBundleIDs = ["dev.zed.Zed"]

        gateway.windowsList = [window(
            1, bundleID: "dev.zed.Zed",
            frame: CGRect(x: 1000, y: 0, width: 500, height: 1000), windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(regular, "regular", order: 1, current: true)],
            memberships: [11: [regular]]
        ))
        await controller.captureNow() // regular Space에서 저장

        gateway.windowsList = [window(
            2, bundleID: "dev.zed.Zed",
            frame: external.frame, fullscreenState: .fullscreen, windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(regular, "regular", order: 1),
                             space(fullscreen, "zed-fullscreen", order: 2,
                                   kind: .fullscreen, current: true)],
            memberships: [22: [fullscreen]]
        ))
        guard case .restored(let results) = await controller.restoreNow() else {
            return XCTFail("restore did not run")
        }
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(results.first?.entries.first?.outcome, .skipped(.fullscreen))

        let readsAfterFullscreen = gateway.standardWindowsCalls
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.standardWindowsCalls, readsAfterFullscreen + 1,
                       "보호된 fullscreen은 다시 복원하지 않고 방문 수집만 한다")
    }

    func testFullscreenVisitIsCollectedThenRecreatedFromTheBuiltinScreen() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        controller.restoreMode = .manual
        let regular = SpaceRuntimeID(1)
        let externalFullscreen = SpaceRuntimeID(2)
        let builtinFullscreen = SpaceRuntimeID(100)
        let savedFrame = CGRect(x: 1100, y: 100, width: 500, height: 700)
        gateway.runningBundleIDs = ["com.app"]

        gateway.windowsList = [window(
            1, bundleID: "com.app", frame: savedFrame, windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(regular, "regular", order: 1, current: true)],
            memberships: [11: [regular]]
        ))
        await controller.captureNow()

        gateway.windowsList = [window(
            2, bundleID: "com.app", frame: external.frame,
            fullscreenState: .fullscreen, windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [
                space(regular, "regular", order: 1),
                space(externalFullscreen, "fullscreen", order: 2,
                      kind: .fullscreen, current: true),
            ],
            memberships: [22: [externalFullscreen]]
        ))
        await controller.activeSpaceChanged()
        XCTAssertTrue(controller.hasPendingCollect)
        controller.confirmCandidates(for: [external.id])
        XCTAssertFalse(controller.hasPendingCollect)

        gateway.windowsList = [window(
            2, bundleID: "com.app", frame: builtin.frame,
            fullscreenState: .fullscreen, windowServerID: 22
        )]
        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(
                    builtinFullscreen, "builtin-fullscreen", order: 1,
                    kind: .fullscreen, current: true
                )]),
                .init(screenID: external.id, spaces: [space(
                    regular, "regular", order: 1, current: true
                )]),
            ],
            membershipsByWindowServerID: [22: [builtinFullscreen]]
        ))
        guard case .restored(let recreated) = await controller.restoreNow() else {
            return XCTFail("restore did not run")
        }
        XCTAssertEqual(gateway.fullscreenCalls.map(\.fullscreen), [false, true])
        XCTAssertEqual(gateway.moveCalls.last?.target, savedFrame)
        XCTAssertEqual(recreated.first?.entries.first?.outcome, .moved)

        reader.availability = .available(makeSnapshot(
            externalSpaces: [
                space(regular, "regular", order: 1),
                space(externalFullscreen, "fullscreen", order: 2,
                      kind: .fullscreen, current: true),
            ],
            memberships: [22: [externalFullscreen]]
        ))
        guard case .restored(let verified) = await controller.restoreNow() else {
            return XCTFail("verification restore did not run")
        }
        XCTAssertEqual(gateway.fullscreenCalls.map(\.fullscreen), [false, true])
        XCTAssertEqual(verified.first?.entries.first?.outcome, .skipped(.fullscreen))
    }

    func testManualFullscreenRestoreWorksWhileAutoSlotIsOffAndHonorsItsSwitch() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader,
            autoSlot: false, regularSpaceRestore: false, fullscreenRestore: true,
            directory: directory
        )
        controller.restoreMode = .manual
        let regular = SpaceRuntimeID(1)
        let externalFullscreen = SpaceRuntimeID(2)
        let builtinFullscreen = SpaceRuntimeID(100)
        let savedFrame = CGRect(x: 1100, y: 100, width: 500, height: 700)
        gateway.runningBundleIDs = ["com.app"]

        gateway.windowsList = [window(
            1, bundleID: "com.app", frame: savedFrame, windowServerID: 11
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [space(regular, "regular", order: 1, current: true)],
            memberships: [11: [regular]]
        ))
        await controller.captureNow()

        gateway.windowsList = [window(
            2, bundleID: "com.app", frame: external.frame,
            fullscreenState: .fullscreen, windowServerID: 22
        )]
        reader.availability = .available(makeSnapshot(
            externalSpaces: [
                space(regular, "regular", order: 1),
                space(externalFullscreen, "fullscreen", order: 2,
                      kind: .fullscreen, current: true),
            ],
            memberships: [22: [externalFullscreen]]
        ))
        await controller.captureNow()
        XCTAssertEqual(controller.restoreSource, .manual)
        XCTAssertNil(controller.lastCollectedAt)

        let stranded = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(
                    builtinFullscreen, "builtin-fullscreen", order: 1,
                    kind: .fullscreen, current: true
                )]),
                .init(screenID: external.id, spaces: [space(
                    regular, "regular", order: 1, current: true
                )]),
            ],
            membershipsByWindowServerID: [22: [builtinFullscreen]]
        )
        gateway.windowsList = [window(
            2, bundleID: "com.app", frame: builtin.frame,
            fullscreenState: .fullscreen, windowServerID: 22
        )]
        reader.availability = .available(stranded)
        await controller.restoreNow()
        XCTAssertEqual(gateway.fullscreenCalls.map(\.fullscreen), [false, true])
        XCTAssertEqual(gateway.moveCalls.last?.target, savedFrame)

        let fullscreenCallCount = gateway.fullscreenCalls.count
        let moveCallCount = gateway.moveCalls.count
        controller.labFullscreenRestore = false
        gateway.windowsList = [window(
            2, bundleID: "com.app", frame: builtin.frame,
            fullscreenState: .fullscreen, windowServerID: 22
        )]
        reader.availability = .available(stranded)
        await controller.restoreNow()
        XCTAssertEqual(gateway.fullscreenCalls.count, fullscreenCallCount)
        XCTAssertEqual(gateway.moveCalls.count, moveCallCount)
    }

    func testUnavailableReaderKeepsTheLegacyRestorePath() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        reader.availability = .unavailable
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        let saved = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        gateway.runningBundleIDs = ["com.legacy"]
        gateway.windowsList = [window(
            1, bundleID: "com.legacy", frame: saved, windowServerID: 11
        )]
        await controller.captureNow()

        gateway.windowsList = [window(
            1, bundleID: "com.legacy",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11
        )]
        await controller.restoreNow()
        XCTAssertEqual(gateway.windowsList[0].frame, saved)
    }

    func testRestoreDrainsAnEarlierWindowReadBeforeAuthoritativeEnumeration() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        reader.availability = .unavailable
        let controller = makeController(
            gateway: gateway, screens: screens, reader: reader, directory: directory
        )
        gateway.runningBundleIDs = ["com.legacy"]
        gateway.windowsList = [window(
            1, bundleID: "com.legacy",
            frame: CGRect(x: 1000, y: 0, width: 500, height: 1000), windowServerID: 11
        )]
        await controller.captureNow()
        gateway.windowsList = [window(
            1, bundleID: "com.legacy",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11
        )]

        gateway.standardWindowsDelay = 0.03
        let callsBefore = gateway.standardWindowsCalls
        let prediction = Task { await controller.cardOpened() }
        while gateway.standardWindowsCalls == callsBefore { await Task.yield() }
        let restore = Task { await controller.restoreNow() }
        await prediction.value
        _ = await restore.value

        XCTAssertEqual(gateway.standardWindowsHighWater, 1)
        XCTAssertEqual(gateway.standardWindowsCallsAtMove.last.map { $0 + 2 },
                       gateway.standardWindowsCalls,
                       "authoritative 열거 뒤에는 move, 자동 수집, 예측 순서여야 한다")
    }

    func testActiveSpaceWatcherCompressesAnEventBurst() async {
        var fired = 0
        let watcher = ActiveSpaceWatcher(debounceInterval: 0.01) { fired += 1 }
        watcher.spaceChanged()
        watcher.spaceChanged()
        watcher.spaceChanged()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fired, 1)
        watcher.stop()
    }

    private func selection(
        _ resolved: ResolvedProfile, _ windows: [WindowInfo], _ snapshot: SpaceSnapshot?
    ) -> SpaceWindowSelection {
        RestoreEngine.selectSpaceWindow(
            bundleID: "com.app", in: resolved, on: external,
            windows: windows, snapshot: snapshot
        )
    }

    private func currentWithMembership(_ memberships: [SpaceRuntimeID]) -> SpaceSnapshot {
        let e1 = SpaceRuntimeID(1)
        let e2 = SpaceRuntimeID(2)
        return makeSnapshot(
            externalSpaces: [space(e1, "stable-name", order: 1, current: true),
                             space(e2, "other", order: 2)],
            memberships: [11: memberships]
        )
    }

    private func makeSnapshot(
        externalSpaces: [SpaceSnapshot.Space],
        memberships: [CGWindowID: [SpaceRuntimeID]],
        fullscreenCandidates: [FullscreenSpaceCandidate] = []
    ) -> SpaceSnapshot {
        SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [
                    space(SpaceRuntimeID(100), "builtin", order: 1, current: true),
                ]),
                .init(screenID: external.id, spaces: externalSpaces),
            ],
            membershipsByWindowServerID: memberships,
            fullscreenCandidates: fullscreenCandidates
        )
    }

    private func space(
        _ id: SpaceRuntimeID, _ name: String?, order: Int,
        kind: SpaceKind = .regular, current: Bool = false
    ) -> SpaceSnapshot.Space {
        .init(runtimeID: id, opaqueName: name, localOrder: order,
              kind: kind, isCurrent: current)
    }

    private func window(
        _ id: Int,
        bundleID: String,
        frame: CGRect = CGRect(x: 1000, y: 0, width: 500, height: 1000),
        fullscreenState: WindowFullscreenState = .windowed,
        isMinimized: Bool = false,
        windowServerID: CGWindowID?
    ) -> WindowInfo {
        WindowInfo(
            id: id, appBundleID: bundleID, appName: bundleID, frame: frame,
            fullscreenState: fullscreenState, isMinimized: isMinimized,
            windowServerID: windowServerID
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("space-aware-controller-\(UUID().uuidString)")
    }

    private func makeController(
        gateway: FakeWindowGateway,
        screens: FakeScreenProvider,
        reader: FakeSpaceReader,
        relocator: SpaceRelocating? = nil,
        autoSlot: Bool = true,
        regularSpaceRestore: Bool? = nil,
        fullscreenRestore: Bool? = nil,
        directory: URL
    ) -> PlugbackController {
        let defaults = UserDefaults(suiteName: "space-aware-controller-\(UUID().uuidString)")!
        defaults.set(autoSlot, forKey: "labAutoSlot")
        if let regularSpaceRestore {
            defaults.set(regularSpaceRestore, forKey: "labSpaceRelocation")
        }
        if let fullscreenRestore {
            defaults.set(fullscreenRestore, forKey: "labFullscreenRestore")
        }
        return PlugbackController(
            gateway: gateway,
            screenProvider: screens,
            store: ProfileStore(directory: directory),
            defaults: defaults,
            spaceReader: reader,
            spaceRelocator: relocator,
            activeSpaceDebounceInterval: 0.01
        )
    }
}

@MainActor
private final class FakeSpaceRelocator: SpaceRelocating {
    private(set) var requests: [SpaceRelocation] = []
    var onRelocate: ((SpaceRelocation) -> Bool)?

    func relocate(_ request: SpaceRelocation) async -> Bool {
        requests.append(request)
        return onRelocate?(request) ?? false
    }
}

@MainActor
private final class FakeSpaceReader: SpaceReading {
    var availability: SpaceSnapshotAvailability = .unavailable
    private(set) var requestedWindowIDs: [[CGWindowID]] = []

    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability {
        requestedWindowIDs.append(windowServerIDs)
        return availability
    }
}
