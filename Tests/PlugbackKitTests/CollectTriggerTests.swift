import AppKit
import XCTest
@testable import PlugbackKit

/// 이동 관찰 어댑터의 페이크 — 등록 대상과 콜백을 들고 있어 테스트가 직접 발화시킨다.
@MainActor
private final class FakeMoveSource: WindowMoveSource, @unchecked Sendable {
    private(set) var registered: [String] = []
    private(set) var registrations = 0
    private var onSettled: (@Sendable () -> Void)?

    nonisolated func observeWindowMoves(of bundleIDs: [String],
                                        onSettled: @escaping @Sendable () -> Void) async {
        await MainActor.run {
            registered = bundleIDs.sorted()
            registrations += 1
            self.onSettled = bundleIDs.isEmpty ? nil : onSettled
        }
    }

    func settle() { onSettled?() }
}

/// 수집 트리거를 자기 인터페이스에서 검증한다.
/// 여러 신호원이 있다는 사실을 이 모듈이 덮는다 — 쓰는 쪽은 「수집할 때가 됐다」 하나만 안다.
@MainActor
final class CollectTriggerTests: XCTestCase {
    private func wait(_ seconds: TimeInterval = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testWindowMoveReachesTheCollectCallback() async {
        // 창을 옮기는 것만으로 수집이 돌아야 한다 — 앱 전환을 기다리면 늦는다.
        let source = FakeMoveSource()
        var collects = 0
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { collects += 1 }
        trigger.start()
        await trigger.retarget(["com.chrome"])

        XCTAssertEqual(source.registered, ["com.chrome"])
        source.settle()
        await wait()
        XCTAssertEqual(collects, 1)
    }

    func testAppSwitchAlsoReachesTheCollectCallback() async {
        // 두 신호원이 서로를 메운다 — AX 알림이 불안정한 앱은 전환 신호로 잡는다.
        //
        // **비활성화가 본 신호다.** 활성화는 상호작용의 시작에 오므로 그 순간의 배치는
        // 창을 옮기기 전의 것이다 — 활성화만 구독했더니 확정된 후보가 씨앗과 좌표가 같았다
        // (2026-08-18 실기기). 앱에서 빠져나오는 순간이 그 앱 창의 최종 상태다.
        let source = FakeMoveSource()
        var collects = 0
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { collects += 1 }
        trigger.start()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        await wait()
        XCTAssertEqual(collects, 1, "비활성화를 놓치면 옮긴 뒤의 배치를 영영 못 잡는다")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await wait()
        XCTAssertEqual(collects, 2, "활성화도 받는다 — 빠져나온 적 없는 첫 회차를 잡는다")
        await trigger.stop()
    }

    func testMinimumIntervalThinsTheAppSwitchStorm() async {
        // 앱 전환은 하루에 수백 번이다. 이 간격이 곧 자동 슬롯의 오차 상한이 된다.
        // 창 이동에는 걸리지 않는다 — 이동은 끝날 때 1회만 오고, 스로틀을 걸면 마지막 배치를 놓친다.
        let source = FakeMoveSource()
        var collects = 0
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 60) { collects += 1 }
        trigger.start()

        for _ in 0..<5 {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        }
        await wait()
        XCTAssertEqual(collects, 1)

        await trigger.retarget(["com.chrome"])
        source.settle()
        source.settle()
        await wait()
        XCTAssertEqual(collects, 3, "창 이동은 스로틀을 타지 않는다")
        await trigger.stop()
    }

    func testRetargetBeforeStartIsIgnored() async {
        let source = FakeMoveSource()
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { }
        await trigger.retarget(["com.chrome"])

        XCTAssertEqual(source.registrations, 0, "시작하지 않은 트리거가 관찰을 걸면 안 된다")
    }

    func testStopReleasesAllSources() async {
        let source = FakeMoveSource()
        var collects = 0
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { collects += 1 }
        trigger.start()
        await trigger.retarget(["com.chrome"])

        await trigger.stop()

        XCTAssertTrue(source.registered.isEmpty, "빈 목록이 해제다")
        source.settle()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        await wait()
        XCTAssertEqual(collects, 0, "꺼진 기능이 신호를 받고 있으면 꺼짐이 아니다")
    }

    func testRetargetIsIdempotentInShape() async {
        let source = FakeMoveSource()
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { }
        trigger.start()
        await trigger.retarget(["com.chrome", "com.slack"])
        await trigger.retarget(["com.chrome", "com.slack"])

        XCTAssertEqual(source.registered, ["com.chrome", "com.slack"], "차이만 반영된다 — 목록이 중복되지 않는다")
        await trigger.stop()
    }

    func testEmptyTargetsKeepTheAppSwitchSubscription() async {
        // 대상 앱이 없어도 전환 신호는 살아 있어야 한다 — 프로필이 생기는 순간을 놓치지 않게.
        let source = FakeMoveSource()
        var collects = 0
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { collects += 1 }
        trigger.start()
        await trigger.retarget([])

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        await wait()
        XCTAssertEqual(collects, 1)
        await trigger.stop()
    }

    func testMissionControlCloseReachesTheCollectCallbackOnce() async {
        var collects = 0
        let watcher = MissionControlWatcher(settleDelay: 0) { collects += 1 }

        watcher.treeChanged(isOpen: false)
        watcher.treeChanged(isOpen: true)
        watcher.treeChanged(isOpen: true)
        watcher.treeChanged(isOpen: false)
        watcher.treeChanged(isOpen: false)
        await wait()

        XCTAssertEqual(collects, 1)
    }
}
