import CoreGraphics
import Foundation
import XCTest
@testable import PlugbackKit

// Product-contract probes. Failures record gaps in current behavior; they are
// isolated from the repository's test suite and never manipulate real windows.
@MainActor
final class ProductRestoreReproductionTests: XCTestCase {
    private let a = ScreenInfo(id: "a", name: "External A",
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let b = ScreenInfo(id: "b", name: "External B",
        frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let saved = CGRect(x: 1100, y: 100, width: 400, height: 500)
    private let elsewhere = CGRect(x: 2200, y: 200, width: 400, height: 500)

    func testControlCurrentSavedSpaceRestoresWindowMovedToOtherExternalScreen() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true)
        XCTAssertEqual(observed.immediate, [saved])
        XCTAssertEqual(observed.afterVisit, [saved])
    }

    func testExplicitRestoreToSavedDesktop2SurvivesUntilUserVisitsIt() async {
        let observed = await savedSpaceScenario(targetIsCurrent: false)
        XCTAssertTrue(observed.hasVisitGuide,
            "Explicit restore must retain a visit instruction for saved Desktop 2")
        XCTAssertEqual(observed.afterVisit, [saved],
            "Window moved to External B never returns to saved Desktop 2 on External A")
    }

    func testControlSingleDisplacedWindowOnItsTargetScreenRestores() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true, displacedWithinA: true)
        XCTAssertEqual(observed.immediate, [saved])
    }

    func testSiblingWindowOnOtherExternalScreenDoesNotBlockSavedWindow() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true,
            displacedWithinA: true, addSibling: true)
        XCTAssertEqual(observed.immediate, [saved],
            "A second window on B suppresses restoration of the saved window on A")
    }

    func testControlFlatProfileRestoresDespiteSiblingOnOtherExternalScreen() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true,
            displacedWithinA: true, addSibling: true, includeSpaces: false)
        XCTAssertEqual(observed.immediate, [saved])
    }

    func testSavingGroupAfterMovingAppFromAToBUpdatesItsSingleDestination() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "PlugbackDesignReview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.test.app"]
        gateway.windowsList = [window(saved)]
        let reader = ReviewSpaceReader(snapshot(aCurrent: 12, membership: 12))
        let controller = PlugbackController(gateway: gateway,
            screenProvider: ReviewScreens([a, b]),
            store: ProfileStore(directory: directory), defaults: defaults,
            spaceReader: reader)
        let firstCapture = await controller.captureNow()
        XCTAssertEqual(firstCapture, .captured(appCount: 1))

        // B starts with no targets. Both saved Spaces stay current throughout.
        gateway.windowsList = [window(elsewhere)]
        reader.snapshot = snapshot(aCurrent: 12, membership: 21)
        let secondCapture = await controller.captureNow()
        guard case .captured = secondCapture else {
            XCTFail("Second manual save failed: \(secondCapture)")
            return
        }
        let destinations = controller.sections.filter {
            $0.profile?.apps.contains { $0.bundleID == "com.test.app" } == true
        }.map(\.screenID).sorted()
        print("Manual destinations after A-to-B resave: \(destinations)")

        gateway.windowsList = [window(CGRect(x: 2400, y: 300, width: 400, height: 500))]
        _ = await controller.restoreNow()
        XCTAssertEqual(gateway.moveCalls.map(\.target), [elsewhere],
            "Old A entry wins by sorted screen ID after manual resave, including the Space-aware controller path")
    }

    func testGroupRetainsAppDestinationWhenOnlyOneExternalScreenDisconnects() async {
        let destinations = await collectThenConfirm(screenIDs: ["a"])
        XCTAssertEqual(destinations, ["b"],
            "A confirms app removal while B's matching addition remains an uncommitted candidate")
    }

    func testControlConfirmingBothScreensKeepsMovedAppDestination() async {
        let destinations = await collectThenConfirm(screenIDs: ["a", "b"])
        XCTAssertEqual(destinations, ["b"])
    }

    func testControlNewAppRoutesCollectOnlyItsFinalExternalDestination() async {
        let routes: [(String, CGRect?, UInt64)] = [
            ("opened on B", nil, 21),
            ("built-in to B", CGRect(x: 100, y: 100, width: 400, height: 500), 1),
            ("A to B", saved, 12),
        ]
        for (route, initialFrame, initialSpace) in routes {
            await withSlots { slots in
                let existing = WindowInfo(id: 2, appBundleID: "com.test.existing",
                    appName: "Existing", frame: elsewhere, fullscreenState: .windowed,
                    isMinimized: false, windowServerID: 102)
                XCTAssertTrue(slots.capture(windows: [existing], on: [a, b],
                    snapshot: snapshot(aCurrent: 12, membership: 21)))
                slots.isLabEnabled = true
                if let initialFrame {
                    slots.collect(windows: [existing, window(initialFrame)], on: [a, b],
                        snapshot: snapshot(aCurrent: 12, membership: initialSpace))
                    XCTAssertEqual(slots.targets(for: [a, b]).contains("com.test.app"),
                        initialSpace == 12, route)
                }
                slots.collect(windows: [existing, window(elsewhere)], on: [a, b],
                    snapshot: snapshot(aCurrent: 12, membership: 21))
                XCTAssertFalse(slots.source(for: b.id)?.profile.apps.contains {
                    $0.bundleID == "com.test.app"
                } ?? false, "Collection must not change the saved source: \(route)")
                XCTAssertTrue(slots.confirmAll(), route)
                let resolved = slots.resolvedWithSpaces(for: [a, b])
                let destinations = resolved.filter {
                    $0.value.profile.apps.contains { $0.bundleID == "com.test.app" }
                }.map(\.key).sorted()
                XCTAssertEqual(destinations, [b.id], route)
                XCTAssertEqual(resolved[b.id]?.profile.apps.first {
                    $0.bundleID == "com.test.app"
                }?.unitRect.frame(in: b.frame), elsewhere, route)
                XCTAssertEqual(resolved[b.id]?.overlay?.byBundle["com.test.app"],
                    .regular(SpaceHint(opaqueName: "b-desktop-1", localOrderHint: 1)), route)
                print("New app route \(route): confirmed destinations \(destinations)")
            }
        }
    }

    func testManualSaveIncludesNewlyArrivedAppOnAnAlreadyConfiguredScreen() async {
        for automatic in [false, true] {
            await withSlots { slots in
                let existing = WindowInfo(id: 2, appBundleID: "com.test.existing",
                    appName: "Existing", frame: elsewhere, fullscreenState: .windowed,
                    isMinimized: false, windowServerID: 102)
                let currentSnapshot = snapshot(aCurrent: 12, membership: 21)
                XCTAssertTrue(slots.capture(windows: [existing], on: [a, b],
                    snapshot: currentSnapshot))
                slots.isLabEnabled = automatic
                let arrived = [existing, window(elsewhere)]
                if automatic {
                    slots.collect(windows: arrived, on: [a, b], snapshot: currentSnapshot)
                    XCTAssertTrue(slots.targets(for: [a, b]).contains("com.test.app"))
                }
                XCTAssertTrue(slots.capture(windows: arrived, on: [a, b],
                    snapshot: currentSnapshot))
                XCTAssertTrue(slots.source(for: b.id)?.profile.apps.contains {
                    $0.bundleID == "com.test.app"
                } ?? false, "Manual save drops the new app, including a discovered candidate; auto=\(automatic)")
            }
        }
    }

    func testFailedRestoreDoesNotReplaceItsSourceWithTheFailedLanding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "PlugbackDesignReview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "labAutoSlot")
        defaults.set(AutoSlotUpdateMode.immediate.rawValue, forKey: "autoSlotUpdateMode")
        let store = ProfileStore(directory: directory)
        try store.save([a.id: Profile(screenID: a.id, screenName: a.name,
            apps: [TargetApp(bundleID: "com.test.app", displayName: "App",
                unitRect: UnitRect(saved, in: a.frame))], savedAt: .distantPast)])
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.test.app"]
        gateway.windowsList = [window(CGRect(x: 1400, y: 200, width: 400, height: 500))]
        gateway.moveBehavior = .silentFail
        let controller = PlugbackController(gateway: gateway,
            screenProvider: ReviewScreens([a, b]), store: store, defaults: defaults)

        _ = await controller.restoreNow()
        XCTAssertEqual(controller.lastResults.reduce(0) { $0 + $1.failedCount }, 1)
        let nextTarget = controller.sections.first { $0.screenID == a.id }?
            .profile?.apps.first?.unitRect.frame(in: a.frame)
        XCTAssertEqual(nextTarget, saved,
            "Automatic post-restore collection promotes the failed landing to the next restore source")
    }

    private func collectThenConfirm(screenIDs: Set<String>) async -> [String] {
        var destinations: [String] = []
        await withSlots { slots in
            XCTAssertTrue(slots.capture(windows: [window(saved)], on: [a, b]))
            slots.isLabEnabled = true
            slots.collect(windows: [window(elsewhere)], on: [a, b])
            XCTAssertTrue(slots.confirm(screenIDs))
            destinations = slots.resolvedWithSpaces(for: [a, b])
                .filter { !$0.value.profile.apps.isEmpty }.map(\.key).sorted()
        }
        return destinations
    }

    private func withSlots(_ check: (ProfileSlots) async -> Void) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await check(ProfileSlots(store: ProfileStore(directory: directory), isLabEnabled: false))
    }

    private func savedSpaceScenario(targetIsCurrent: Bool,
        displacedWithinA: Bool = false, addSibling: Bool = false,
        includeSpaces: Bool = true) async -> (
        immediate: [CGRect], hasVisitGuide: Bool, afterVisit: [CGRect]
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "PlugbackDesignReview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.test.app"]
        gateway.windowsList = [window(saved)]
        let reader = ReviewSpaceReader(snapshot(aCurrent: 12, membership: 12))
        let controller = PlugbackController(gateway: gateway,
            screenProvider: ReviewScreens([a, b]),
            store: ProfileStore(directory: directory), defaults: defaults,
            spaceReader: includeSpaces ? reader : nil, activeSpaceDebounceInterval: 0)
        let captured = await controller.captureNow()
        XCTAssertEqual(captured, .captured(appCount: 1))

        gateway.windowsList = [window(displacedWithinA
            ? CGRect(x: 1400, y: 200, width: 400, height: 500) : elsewhere)]
        if addSibling {
            gateway.windowsList.append(WindowInfo(id: 2, appBundleID: "com.test.app",
                appName: "App", frame: elsewhere, fullscreenState: .windowed,
                isMinimized: false, windowServerID: 102))
        }
        reader.snapshot = snapshot(aCurrent: targetIsCurrent ? 12 : 11,
            membership: displacedWithinA ? 12 : 21)
        _ = await controller.restoreNow()
        let immediate = gateway.moveCalls.map(\.target)
        let guide = controller.sections.flatMap(\.spaceGroups).contains {
            if case .visit = $0.guide { return true }
            return false
        }
        reader.snapshot = snapshot(aCurrent: 12, membership: displacedWithinA ? 12 : 21)
        await controller.activeSpaceChanged()
        return (immediate, guide, gateway.moveCalls.map(\.target))
    }

    private func window(_ frame: CGRect) -> WindowInfo {
        WindowInfo(id: 1, appBundleID: "com.test.app", appName: "App",
            frame: frame, fullscreenState: .windowed, isMinimized: false,
            windowServerID: 101)
    }

    private func snapshot(aCurrent: UInt64, membership: UInt64) -> SpaceSnapshot {
        func space(_ id: UInt64, _ name: String, _ order: Int, _ current: Bool) -> SpaceSnapshot.Space {
            .init(runtimeID: SpaceRuntimeID(id), opaqueName: name,
                localOrder: order, kind: .regular, isCurrent: current)
        }
        return SpaceSnapshot(displays: [
            .init(screenID: a.id, spaces: [
                space(11, "a-desktop-1", 1, aCurrent == 11),
                space(12, "a-desktop-2", 2, aCurrent == 12),
            ]),
            .init(screenID: b.id, spaces: [space(21, "b-desktop-1", 1, true)]),
        ], membershipsByWindowServerID: [101: [SpaceRuntimeID(membership)],
            102: [SpaceRuntimeID(21)]])
    }
}

private final class ReviewScreens: ScreenProvider {
    var values: [ScreenInfo]
    init(_ values: [ScreenInfo]) { self.values = values }
    func screens() -> [ScreenInfo] { values }
}

@MainActor
private final class ReviewSpaceReader: SpaceReading {
    var snapshot: SpaceSnapshot
    init(_ snapshot: SpaceSnapshot) { self.snapshot = snapshot }
    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability {
        .available(snapshot)
    }
}
