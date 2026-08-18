import XCTest
@testable import PlugbackKit

/// 창 이동 알림의 노이즈 압축. AX 없이 검증되는 부분만 여기서 본다 —
/// 코드가 `windowMoved()`를 internal로 열어두고 "테스트가 AX 없이 직접 주입한다"고 약속해 뒀는데,
/// 그 약속을 쓰는 테스트가 없었다 (4차 리뷰 V1).
///
/// AX 등록 자체(AXObserverCreate·실행 루프 소스·실제 알림 전달)는 실기기 검증 항목이다.
/// 테스트 프로세스에는 접근성 권한이 없어 등록은 조용히 실패하고, 그 경로도 코드가 의도한 것이다.
@MainActor
final class WindowMoveObserverTests: XCTestCase {
    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 등록 대상이 있는 상태를 만든다. 테스트 프로세스에서는 AX 등록이 실패하지만
    /// 콜백은 설정되므로, 압축 정책은 그대로 검증된다.
    private func observing(_ observer: WindowMoveObserver, _ onSettled: @escaping @Sendable () -> Void) {
        observer.observe(pids: [-1], onSettled: onSettled)
    }

    func testABurstCollapsesIntoOneCallback() async {
        // 창 여러 개를 연달아 옮기면 알림이 여러 번 온다 — 소비자가 받는 것은 "정착했다" 1회다.
        let observer = WindowMoveObserver(settleInterval: 0.05)
        var settled = 0
        observing(observer) { settled += 1 }

        for _ in 0..<5 { observer.windowMoved() }
        await wait(0.15)

        XCTAssertEqual(settled, 1)
    }

    func testNothingFiresBeforeTheIntervalElapses() async {
        // 대기가 끝나기 전에는 조용하다 — 드래그 중간 좌표를 수집하지 않는다.
        let observer = WindowMoveObserver(settleInterval: 0.2)
        var settled = 0
        observing(observer) { settled += 1 }

        observer.windowMoved()
        await wait(0.05)
        XCTAssertEqual(settled, 0)

        await wait(0.25)
        XCTAssertEqual(settled, 1)
    }

    func testSeparateBurstsFireSeparately() async {
        // 압축은 한 번의 정착에만 적용된다 — 다음 이동을 삼키면 마지막 배치를 놓친다.
        let observer = WindowMoveObserver(settleInterval: 0.05)
        var settled = 0
        observing(observer) { settled += 1 }

        observer.windowMoved()
        await wait(0.15)
        observer.windowMoved()
        await wait(0.15)

        XCTAssertEqual(settled, 2)
    }

    func testReleasingStopsTheOldConsumerFromBeingCalled() async {
        // 빈 목록은 해제다 — 해제 뒤의 이동이 이전 소비자에게 닿으면 "꺼짐"이 아니게 된다.
        //
        // 예약돼 있던 발화의 취소는 이 인터페이스로 관측되지 않는다(콜백이 어차피 교체되므로).
        // 관측 가능한 계약은 "해제 뒤에는 이전 소비자가 더 이상 불리지 않는다"쪽이고, 그걸 고정한다.
        let observer = WindowMoveObserver(settleInterval: 0.05)
        var settled = 0
        observing(observer) { settled += 1 }

        observer.observe(pids: [], onSettled: {}) // 해제
        observer.windowMoved()
        await wait(0.15)

        XCTAssertEqual(settled, 0)
    }

    func testRetargetingKeepsCompressingWithTheNewCallback() async {
        // 대상이 바뀌어도 압축은 이어진다 — 등록 갱신이 대기 중 발화를 잃어버리면 안 된다.
        let observer = WindowMoveObserver(settleInterval: 0.05)
        var first = 0
        var second = 0
        observing(observer) { first += 1 }
        observing(observer) { second += 1 }

        for _ in 0..<3 { observer.windowMoved() }
        await wait(0.15)

        XCTAssertEqual(first, 0, "마지막으로 등록한 콜백만 받는다")
        XCTAssertEqual(second, 1)
    }
}
