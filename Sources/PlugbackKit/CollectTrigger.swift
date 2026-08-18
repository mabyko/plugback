import Foundation

/// 언제 자동 슬롯이 움직여야 하는지를 답하는 모듈 (실험실, F-08.3).
///
/// 신호원이 둘이다 — **창 이동**(직접 옮긴 것)과 **앱 전환**(옵저버가 못 받는 앱·나중에 켠 앱).
/// 서로를 메우므로 둘 다 필요하지만, 컨트롤러가 알아야 할 것은 「수집할 때가 됐다」 하나다.
/// 두 수명주기·두 압축 정책·등록 대상 갱신은 전부 이 안에 있다.
///
/// 어댑터가 실제로 둘이라 이 seam은 지어낸 것이 아니다.
/// 세 번째 신호원이 생겨도 컨트롤러 쪽은 바뀌지 않는다.
@MainActor
public final class CollectTrigger {
    private let moveSource: WindowMoveSource?
    private let activity: ActivityWatcher
    /// 창 이동 경로가 쓰는 참조. ActivityWatcher도 같은 클로저를 들지만 둘 다 불변이라 어긋날 수 없다 —
    /// 하나로 합치려면 ActivityWatcher의 콜백을 var로 열어야 해서, 그 대가가 이 중복보다 크다.
    private let onCollect: () -> Void
    private var started = false

    /// 최소 간격은 앱 전환 쪽에만 걸린다. 창 이동은 이동이 끝날 때 1회만 오므로
    /// 스로틀이 필요 없고, 걸면 사용자가 옮긴 마지막 배치를 놓친다.
    public init(moveSource: WindowMoveSource?,
                minimumInterval: TimeInterval = 10,
                onTerminating: @escaping () -> Void = {},
                onCollect: @escaping () -> Void) {
        self.moveSource = moveSource
        self.onCollect = onCollect
        self.activity = ActivityWatcher(minimumInterval: minimumInterval,
                                        onTerminating: onTerminating,
                                        onCollect: onCollect)
    }

    /// 앱 전환 구독을 시작한다. 창 이동은 대상이 정해져야 하므로 `retarget`이 켠다.
    public func start() {
        guard !started else { return }
        started = true
        activity.start()
    }

    /// 두 신호원을 모두 끊는다. 꺼진 기능이 알림을 받고 있으면 "꺼짐"이 아니다.
    public func stop() async {
        started = false
        activity.stop()
        await moveSource?.observeWindowMoves(of: [], onSettled: {})
    }

    /// 창 이동을 관찰할 대상 앱을 지금 상태에 맞춘다. 멱등이다 — 등록 차이만 반영된다.
    /// 빈 목록이면 이동 관찰만 해제되고 앱 전환 구독은 남는다.
    public func retarget(_ bundleIDs: [String]) async {
        guard started else { return }
        await moveSource?.observeWindowMoves(of: bundleIDs) { [weak self] in
            Task { @MainActor in self?.onCollect() }
        }
    }
}
