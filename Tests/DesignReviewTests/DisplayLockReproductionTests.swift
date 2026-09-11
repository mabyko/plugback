import CoreGraphics
import XCTest
@testable import PlugbackKit

// F-01.3 / US-009 probes against the real watcher with injected screen and lock
// state. These never lock the Mac, subscribe to OS notifications, or move windows.
@MainActor
final class DisplayLockReproductionTests: XCTestCase {
    private let a = ScreenInfo(id: "a", name: "A",
        frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let b = ScreenInfo(id: "b", name: "B",
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)

    private func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    func testLockedConnectionSurvivesUnlockBeforeDebounceDuringWakeSuppression() async {
        let provider = FakeScreenProvider()
        var locked = true
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
            wakeSuppressionInterval: 10, isLocked: { locked }) { calls += 1 }
        watcher.systemDidWake()
        provider.screensList = [a]
        watcher.screenParametersChanged()

        // Unlock before the queued stabilization runs: the connection occurred
        // while locked, so wake suppression must not consume it as an unlocked one.
        locked = false
        watcher.screenDidUnlock()
        await settle()

        XCTAssertEqual(calls, 1,
            "A connection received while locked was lost when unlock preceded stabilization")
    }

    func testRemovingTheNewDisplayWhileLockedDoesNotRestoreTheOriginalEnvironment() async {
        let provider = FakeScreenProvider()
        provider.screensList = [a]
        var locked = true
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
            isLocked: { locked }) { calls += 1 }
        provider.screensList = [a, b]
        watcher.screenParametersChanged()
        await settle()
        XCTAssertEqual(calls, 0)

        provider.screensList = [a]
        watcher.screenParametersChanged()
        await settle()
        locked = false
        watcher.screenDidUnlock()
        await settle()

        XCTAssertEqual(calls, 0,
            "The deferred connection was removed; unlocking must not restore pre-existing A")
    }

    func testControlEarlyUnlockWithoutWakeSuppressionRestores() async {
        let provider = FakeScreenProvider()
        var locked = true
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
            isLocked: { locked }) { calls += 1 }
        provider.screensList = [a]
        watcher.screenParametersChanged()
        locked = false
        watcher.screenDidUnlock()
        await settle()

        XCTAssertEqual(calls, 1)
    }

    func testControlSequentialLockedConnectionsRestoreLatestCombinationOnce() async {
        let provider = FakeScreenProvider()
        var locked = true
        var restored: [[String]] = []
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
            wakeSuppressionInterval: 10, isLocked: { locked }) {
                restored.append(provider.screens().map(\.id).sorted())
            }
        watcher.systemDidWake()
        provider.screensList = [a]
        watcher.screenParametersChanged()
        await settle()
        provider.screensList = [a, b]
        watcher.screenParametersChanged()
        await settle()
        XCTAssertTrue(restored.isEmpty)

        locked = false
        watcher.screenDidUnlock()
        await settle()
        watcher.screenDidUnlock()
        await settle()

        XCTAssertEqual(restored, [["a", "b"]])
    }

    func testControlRemovingAllDisplaysClearsDeferredRestore() async {
        let provider = FakeScreenProvider()
        var locked = true
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
            isLocked: { locked }) { calls += 1 }
        provider.screensList = [a]
        watcher.screenParametersChanged()
        await settle()
        provider.screensList = []
        watcher.screenParametersChanged()
        await settle()
        locked = false
        watcher.screenDidUnlock()
        await settle()

        XCTAssertEqual(calls, 0)
    }
}
