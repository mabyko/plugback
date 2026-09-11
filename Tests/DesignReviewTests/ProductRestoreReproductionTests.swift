import CoreGraphics
import Foundation
import XCTest
@testable import PlugbackKit

// Product-contract probes for R1–R6 (docs/PRODUCT_DESIGN_REVIEW.md). They ran red on 09f9d67 and
// must stay green on the workspace model. Isolated from the repository's test suite; never touch real windows.
@MainActor
final class ProductRestoreReproductionTests: XCTestCase {
    private let a = ScreenInfo(id: "a", name: "External A",
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let b = ScreenInfo(id: "b", name: "External B",
        frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let saved = CGRect(x: 1100, y: 100, width: 400, height: 500)
    private let elsewhere = CGRect(x: 2200, y: 200, width: 400, height: 500)
    private var pairKey: WorkspaceKey { WorkspaceKey(screenIDs: [a.id, b.id]) }

    // R1
    func testControlCurrentSavedSpaceRestoresWindowMovedToOtherExternalScreen() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true)
        XCTAssertEqual(observed.immediate, [saved])
        XCTAssertEqual(observed.afterVisit, [saved])
    }

    func testExplicitRestoreToSavedDesktop2SurvivesUntilUserVisitsIt() async {
        let observed = await savedSpaceScenario(targetIsCurrent: false)
        XCTAssertTrue(observed.hasVisitGuide, "Explicit restore must retain a visit instruction for saved Desktop 2")
        XCTAssertEqual(observed.afterVisit, [saved], "Window returns to saved Desktop 2 once it is visited")
    }

    // R2
    func testControlSingleDisplacedWindowOnItsTargetScreenRestores() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true, displacedWithinA: true)
        XCTAssertEqual(observed.immediate, [saved])
    }

    func testSiblingWindowOnOtherExternalScreenDoesNotBlockSavedWindow() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true, displacedWithinA: true, addSibling: true)
        XCTAssertEqual(observed.immediate, [saved], "A second window on B must not suppress the saved window on A")
    }

    func testControlFlatProfileRestoresDespiteSiblingOnOtherExternalScreen() async {
        let observed = await savedSpaceScenario(targetIsCurrent: true, displacedWithinA: true, addSibling: true, includeSpaces: false)
        XCTAssertEqual(observed.immediate, [saved])
    }

    // R3
    func testSavingWorkspaceAfterMovingAppFromAToBUpdatesItsSingleDestination() async {
        let directory = temporaryDirectory("review")
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
        let controller = PlugbackController(gateway: gateway, screenProvider: ReviewScreens([a, b]),
            store: ProfileStore(directory: directory), defaults: defaults, spaceReader: reader)
        let awaited1 = await controller.captureNow()
        XCTAssertEqual(awaited1, .captured(appCount: 1, windowCount: 1))

        gateway.windowsList = [window(elsewhere)]
        reader.snapshot = snapshot(aCurrent: 12, membership: 21)
        guard case .captured = await controller.captureNow() else { return XCTFail("Second manual save failed") }
        let destinations = controller.allWorkspaces.first?.windowCount
        XCTAssertEqual(destinations, 1, "The same window keeps one destination after the A-to-B resave")

        gateway.windowsList = [window(CGRect(x: 2400, y: 300, width: 400, height: 500))]
        _ = await controller.restoreNow()
        XCTAssertEqual(gateway.moveCalls.map(\.target), [elsewhere], "The new destination B wins, not the sorted screen ID")
    }

    // R4
    func testWorkspaceKeepsAppDestinationWhenOnlyOneExternalScreenDisconnects() async {
        let directory = temporaryDirectory("review")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(directory: directory)
        XCTAssertTrue(library.capture(key: pairKey, screens: [a, b], sample: sample([window(saved)], 1), snapshot: nil))
        library.collect(key: pairKey, screens: [a, b], sample: sample([window(elsewhere)], 2), snapshot: nil, runningBundleIDs: ["com.test.app"])
        XCTAssertEqual(library.confirm(key: pairKey), .saved, "Leaving the workspace confirms the whole group at once")
        XCTAssertEqual(library.saved(for: pairKey)?.placements.map(\.screenID), [b.id])
    }

    // D4 new-app routes
    func testNewAppRoutesCollectOnlyItsFinalExternalDestination() async {
        let routes: [(String, CGRect?, UInt64)] = [
            ("opened on B", nil, 21),
            ("built-in to B", CGRect(x: 100, y: 100, width: 400, height: 500), 1),
            ("A to B", saved, 12),
        ]
        for (route, initialFrame, initialSpace) in routes {
            let directory = temporaryDirectory("review")
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = makeLibrary(directory: directory)
            let existing = WindowInfo(id: 2, appBundleID: "com.test.existing", appName: "Existing",
                                      frame: elsewhere, fullscreenState: .windowed, windowServerID: 102)
            XCTAssertTrue(library.capture(key: pairKey, screens: [a, b], sample: sample([existing], 1),
                                          snapshot: snapshot(aCurrent: 12, membership: 21)))
            if let initialFrame {
                library.collect(key: pairKey, screens: [a, b], sample: sample([existing, window(initialFrame)], 2),
                                snapshot: snapshot(aCurrent: 12, membership: initialSpace), runningBundleIDs: ["com.test.app", "com.test.existing"])
                XCTAssertEqual(library.observedBundleIDs(for: pairKey).contains("com.test.app"), initialSpace == 12, route)
            }
            library.collect(key: pairKey, screens: [a, b], sample: sample([existing, window(elsewhere)], 3),
                            snapshot: snapshot(aCurrent: 12, membership: 21), runningBundleIDs: ["com.test.app", "com.test.existing"])
            XCTAssertFalse(library.saved(for: pairKey)!.placements.contains { $0.bundleID == "com.test.app" },
                           "Collection must not change the saved source: \(route)")
            XCTAssertEqual(library.confirm(key: pairKey), .saved, route)
            let placements = library.saved(for: pairKey)!.placements.filter { $0.bundleID == "com.test.app" }
            XCTAssertEqual(placements.map(\.screenID), [b.id], route)
            XCTAssertEqual(placements.first?.unitRect.frame(in: b.frame), elsewhere, route)
            XCTAssertEqual(placements.first?.space, SpaceHint(opaqueName: "b-desktop-1", localOrderHint: 1), route)
        }
    }

    // R6
    func testManualSaveIncludesNewlyArrivedAppOnAnAlreadyConfiguredScreen() async {
        for automatic in [false, true] {
            let directory = temporaryDirectory("review")
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = makeLibrary(directory: directory, autoSave: automatic)
            let existing = WindowInfo(id: 2, appBundleID: "com.test.existing", appName: "Existing",
                                      frame: elsewhere, fullscreenState: .windowed, windowServerID: 102)
            let currentSnapshot = snapshot(aCurrent: 12, membership: 21)
            XCTAssertTrue(library.capture(key: pairKey, screens: [a, b], sample: sample([existing], 1), snapshot: currentSnapshot))
            let arrived = [existing, window(elsewhere)]
            if automatic {
                library.collect(key: pairKey, screens: [a, b], sample: sample(arrived, 2), snapshot: currentSnapshot, runningBundleIDs: ["com.test.app", "com.test.existing"])
                XCTAssertTrue(library.observedBundleIDs(for: pairKey).contains("com.test.app"))
            }
            XCTAssertTrue(library.capture(key: pairKey, screens: [a, b], sample: sample(arrived, 3), snapshot: currentSnapshot))
            XCTAssertTrue(library.saved(for: pairKey)!.placements.contains { $0.bundleID == "com.test.app" },
                          "Manual save must include the new app; auto=\(automatic)")
        }
    }

    // R5
    func testFailedRestoreDoesNotReplaceItsSourceWithTheFailedLanding() async throws {
        let directory = temporaryDirectory("review")
        let suite = "PlugbackDesignReview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let screens = ReviewScreens([a, b])
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.test.app"]
        gateway.windowsList = [window(saved)]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
            store: ProfileStore(directory: directory), defaults: defaults, collectInterval: 0)
        controller.startWatching()
        let awaited2 = await controller.captureNow()
        XCTAssertEqual(awaited2, .captured(appCount: 1, windowCount: 1))

        gateway.windowsList = [window(CGRect(x: 1400, y: 200, width: 400, height: 500))]
        gateway.moveBehavior = .silentFail
        _ = await controller.restoreNow()
        XCTAssertEqual(controller.lastResults.reduce(0) { $0 + $1.failedCount }, 1)
        await controller.collectCandidate()
        screens.values = []
        await controller.workspaceChanged() // leaving the workspace would confirm any pending history
        let stored = try JSONDecoder.plugback.decode(StoreFile.self, from: Data(contentsOf: directory.appendingPathComponent("workspaces.json")))
        XCTAssertEqual(stored.workspaces[pairKey.raw]?.saved?.placements.first?.unitRect.frame(in: a.frame), saved,
                       "The failed landing must not become the next restore source")
    }

    private func sample(_ windows: [WindowInfo], _ sequence: Int) -> DesktopObservation.Sample {
        DesktopObservation.Sample(sequence: sequence, windows: windows, unavailableBundleIDs: [], spaceAvailability: nil)
    }

    private func savedSpaceScenario(targetIsCurrent: Bool, displacedWithinA: Bool = false, addSibling: Bool = false,
                                    includeSpaces: Bool = true) async -> (immediate: [CGRect], hasVisitGuide: Bool, afterVisit: [CGRect]) {
        let directory = temporaryDirectory("review")
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
        let controller = PlugbackController(gateway: gateway, screenProvider: ReviewScreens([a, b]),
            store: ProfileStore(directory: directory), defaults: defaults,
            spaceReader: includeSpaces ? reader : nil, activeSpaceDebounceInterval: 0)
        let awaited3 = await controller.captureNow()
        XCTAssertEqual(awaited3, .captured(appCount: 1, windowCount: 1))

        gateway.windowsList = [window(displacedWithinA ? CGRect(x: 1400, y: 200, width: 400, height: 500) : elsewhere)]
        if addSibling {
            gateway.windowsList.append(WindowInfo(id: 2, appBundleID: "com.test.app", appName: "App",
                frame: elsewhere, fullscreenState: .windowed, windowServerID: 102))
        }
        reader.snapshot = snapshot(aCurrent: targetIsCurrent ? 12 : 11, membership: displacedWithinA ? 12 : 21)
        _ = await controller.restoreNow()
        let immediate = gateway.moveCalls.map(\.target)
        let guide = controller.waitingItems.contains { $0.outcome == .awaitingVisit }
        reader.snapshot = snapshot(aCurrent: 12, membership: displacedWithinA ? 12 : 21)
        await controller.activeSpaceChanged()
        return (immediate, guide, gateway.moveCalls.map(\.target))
    }

    private func window(_ frame: CGRect) -> WindowInfo {
        WindowInfo(id: 1, appBundleID: "com.test.app", appName: "App", frame: frame,
                   fullscreenState: .windowed, windowServerID: 101)
    }

    private func snapshot(aCurrent: UInt64, membership: UInt64) -> SpaceSnapshot {
        func space(_ id: UInt64, _ name: String, _ order: Int, _ current: Bool) -> SpaceSnapshot.Space {
            .init(runtimeID: SpaceRuntimeID(id), opaqueName: name, localOrder: order, kind: .regular, isCurrent: current)
        }
        return SpaceSnapshot(displays: [
            .init(screenID: a.id, spaces: [space(11, "a-desktop-1", 1, aCurrent == 11), space(12, "a-desktop-2", 2, aCurrent == 12)]),
            .init(screenID: b.id, spaces: [space(21, "b-desktop-1", 1, true)]),
        ], membershipsByWindowServerID: [101: [SpaceRuntimeID(membership)], 102: [SpaceRuntimeID(21)]])
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
    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability { .available(snapshot) }
}
