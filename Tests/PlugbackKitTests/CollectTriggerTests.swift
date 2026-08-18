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
/// 신호원이 둘이라는 사실을 이 모듈이 덮는다 — 쓰는 쪽은 「수집할 때가 됐다」 하나만 안다.
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
        let source = FakeMoveSource()
        var collects = 0
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { collects += 1 }
        trigger.start()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        await wait()
        XCTAssertEqual(collects, 1)
        await trigger.stop()
    }

    func testRetargetBeforeStartIsIgnored() async {
        let source = FakeMoveSource()
        let trigger = CollectTrigger(moveSource: source, minimumInterval: 0) { }
        await trigger.retarget(["com.chrome"])

        XCTAssertEqual(source.registrations, 0, "시작하지 않은 트리거가 관찰을 걸면 안 된다")
    }

    func testStopReleasesBothSources() async {
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
}
