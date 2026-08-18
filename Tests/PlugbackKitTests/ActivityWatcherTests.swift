import AppKit
import XCTest
@testable import PlugbackKit

/// 수집 트리거. 어느 알림을 구독하느냐가 이 기능의 성패를 갈랐다 —
/// 활성화만 구독했더니 확정된 후보가 씨앗과 좌표가 같았다 (2026-08-18 실기기).
@MainActor
final class ActivityWatcherTests: XCTestCase {
    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testFiresOnDeactivationNotJustActivation() async {
        // 활성화는 상호작용의 **시작**에 온다 — 그 순간의 배치는 사용자가 창을 옮기기 전의 것이다.
        // 앱에서 빠져나오는 순간이 그 앱 창의 최종 상태이므로, 비활성화가 본 신호다.
        var calls = 0
        let watcher = ActivityWatcher(minimumInterval: 0) { calls += 1 }
        watcher.start()
        defer { watcher.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        await wait(0.1)
        XCTAssertEqual(calls, 1, "비활성화를 구독하지 않으면 옮긴 뒤의 배치를 영영 못 잡는다")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await wait(0.1)
        XCTAssertEqual(calls, 2, "활성화도 받는다 — 빠져나온 적 없는 첫 회차를 잡는다")
    }

    func testMinimumIntervalThinsTheStorm() async {
        // 앱 전환은 하루에 수백 번이다. 간격이 곧 자동 슬롯의 오차 상한이 된다.
        var calls = 0
        let watcher = ActivityWatcher(minimumInterval: 60) { calls += 1 }
        watcher.start()
        defer { watcher.stop() }

        for _ in 0..<5 {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        }
        await wait(0.1)
        XCTAssertEqual(calls, 1)
    }

    func testStopEndsSubscription() async {
        // 꺼진 기능이 알림을 받고 있으면 "꺼짐"이 아니다.
        var calls = 0
        let watcher = ActivityWatcher(minimumInterval: 0) { calls += 1 }
        watcher.start()
        watcher.stop()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        await wait(0.1)
        XCTAssertEqual(calls, 0)
    }
}
