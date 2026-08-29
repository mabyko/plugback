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
        XCTAssertEqual(gateway.standardWindowsCallsAtMove.last.map { $0 + 1 },
                       gateway.standardWindowsCalls,
                       "move가 끝난 뒤 예측 갱신 전까지 authoritative 열거가 마지막이어야 한다")

        let callsAfterCompletion = gateway.standardWindowsCalls
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1, 2])
        XCTAssertEqual(gateway.standardWindowsCalls, callsAfterCompletion,
                       "완료된 Space는 다음 알림에서 다시 읽거나 복원하지 않는다")
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
        XCTAssertEqual(gateway.standardWindowsCalls, readsAfterFullscreen,
                       "fullscreen도 완료이므로 pending에 남지 않는다")
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
        XCTAssertEqual(gateway.standardWindowsCallsAtMove.last.map { $0 + 1 },
                       gateway.standardWindowsCalls,
                       "authoritative 열거와 move 사이에는 다른 창 열거가 없어야 한다")
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
        directory: URL
    ) -> PlugbackController {
        let defaults = UserDefaults(suiteName: "space-aware-controller-\(UUID().uuidString)")!
        defaults.set(true, forKey: "labAutoSlot")
        return PlugbackController(
            gateway: gateway,
            screenProvider: screens,
            store: ProfileStore(directory: directory),
            defaults: defaults,
            spaceReader: reader,
            activeSpaceDebounceInterval: 0.01
        )
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
