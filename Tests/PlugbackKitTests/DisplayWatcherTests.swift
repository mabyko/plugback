import XCTest
@testable import PlugbackKit

// US-009: 창 튐 방지는 전부 DisplayWatcher 안에서 결판난다.
@MainActor
final class DisplayWatcherTests: XCTestCase {
    private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                     frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
    private let ext1 = ScreenInfo(id: "ext-1", name: "LG",
                                  frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
    private let ext2 = ScreenInfo(id: "ext-2", name: "DELL",
                                  frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testEventBurstCollapsesToSingleCallback() async {
        // 케이블을 꽂으면 이벤트가 3~6회 온다 — 복원은 한 번만 (F-01.2, US-001 AC-1)
        let provider = FakeScreenProvider()
        provider.screensList = [builtin]
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.05) { calls += 1 }

        provider.screensList = [builtin, ext1]
        watcher.screenParametersChanged()
        watcher.screenParametersChanged()
        watcher.screenParametersChanged()
        await wait(0.15)

        XCTAssertEqual(calls, 1)
    }

    func testUnchangedTopologyDoesNotFire() {
        // 해상도 변경·잠금 해제처럼 집합이 그대로면 조용하다 (F-01.3, US-009 AC-3·4)
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, ext1]
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.01) { calls += 1 }

        watcher.screenParametersChanged()
        let exp = expectation(description: "quiet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(calls, 0)
    }

    func testRemoveAndReturnWithinOneBurstDoesNotFire() async {
        // 잠자기 해제: 제거→복귀가 한 폭풍 안에서 일어나면 최종 집합이 같으므로 무동작 (US-009 AC-1)
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, ext1]
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.05) { calls += 1 }

        provider.screensList = [builtin]        // 화면이 잠깐 사라졌다가
        watcher.screenParametersChanged()
        provider.screensList = [builtin, ext1]  // 디바운스 안에 돌아온다
        watcher.screenParametersChanged()
        await wait(0.15)

        XCTAssertEqual(calls, 0)
    }

    func testWakeSuppressionBlocksButRealConnectionAfterwardFires() async {
        // 억제 중에는 추가가 보여도 무시, 억제가 끝난 진짜 연결은 정상 동작 (F-01.3, US-009 AC-5)
        let provider = FakeScreenProvider()
        provider.screensList = [builtin]
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
                                     wakeSuppressionInterval: 0.1) { calls += 1 }

        watcher.systemDidWake()
        provider.screensList = [builtin, ext1]
        watcher.screenParametersChanged()
        await wait(0.06) // 안정화됐지만 억제 창 안 — 무시, 기준선만 갱신
        XCTAssertEqual(calls, 0)

        await wait(0.1)  // 억제 종료
        provider.screensList = [builtin, ext1, ext2]
        watcher.screenParametersChanged()
        await wait(0.06)
        XCTAssertEqual(calls, 1) // 억제가 정상 동작까지 막지 않는다
    }

    func testDisconnectThenReconnectFires() async {
        // 진짜 뽑았다 꽂기: 안정화가 두 번 일어나면 복귀는 '새 추가'다 (US-001, US-003 AC-2)
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, ext1]
        var calls = 0
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02) { calls += 1 }

        provider.screensList = [builtin]
        watcher.screenParametersChanged()
        await wait(0.06) // 분리 상태로 안정화 — 콜백 없음 (F-01.5: 분리 시 무동작)
        XCTAssertEqual(calls, 0)

        provider.screensList = [builtin, ext1]
        watcher.screenParametersChanged()
        await wait(0.06)
        XCTAssertEqual(calls, 1)
    }

    // MARK: - 제거 (실험실 · 자동 슬롯 확정 트리거)

    func testRemovedScreensAreReportedWithTheirIdentifiers() async {
        // 확정은 "어느 화면이 빠졌나"를 알아야 하는데, 그 화면은 이미 목록에 없어 되물을 수 없다
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, ext1, ext2]
        var removed: [Set<String>] = []
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
                                     onExternalScreensRemoved: { removed.append($0) }) { }

        provider.screensList = [builtin, ext2]
        watcher.screenParametersChanged()
        await wait(0.06)

        XCTAssertEqual(removed, [["ext-1"]]) // 남아 있는 ext-2는 확정 대상이 아니다
    }

    func testUnchangedTopologyReportsNoRemoval() async {
        // 덮개 여닫기·잠자기 해제는 집합이 그대로다 — 확정도 일어나지 않는다 (US-009 AC-2·6)
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, ext1]
        var removed: [Set<String>] = []
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
                                     onExternalScreensRemoved: { removed.append($0) }) { }

        watcher.systemDidWake()
        watcher.screenParametersChanged()
        await wait(0.06)

        XCTAssertTrue(removed.isEmpty)
    }

    func testRemovalIsReportedBeforeReconnectCallback() async {
        // 화면을 바꿔 끼우면 확정이 재복원보다 앞서야 직전 배치를 잃지 않는다
        let provider = FakeScreenProvider()
        provider.screensList = [builtin, ext1]
        var order: [String] = []
        let watcher = DisplayWatcher(provider: provider, debounceInterval: 0.02,
                                     onExternalScreensRemoved: { _ in order.append("removed") }) {
            order.append("appeared")
        }

        provider.screensList = [builtin, ext2] // 한 번의 안정화 안에서 교체
        watcher.screenParametersChanged()
        await wait(0.06)

        XCTAssertEqual(order, ["removed", "appeared"])
    }
}
