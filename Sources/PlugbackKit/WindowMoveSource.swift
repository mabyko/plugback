import CoreGraphics

/// 창이 움직였다는 신호의 출처 (수집 트리거와 사용자 조작 보호).
///
/// WindowGateway와 **같은 seam에 있는 다른 인터페이스**다. 게이트웨이는 요청/응답이고
/// 이쪽은 수명주기가 있는 구독이라, 한 프로토콜에 섞으면 호출자가 알아야 할 사실이
/// 두 종류로 늘어난다. 실물 어댑터(AXWindowGateway)는 둘 다 만족하므로
/// "다른 앱의 AX를 만지는 것은 어댑터 안뿐"이라는 불변식은 그대로다.
///
/// 인터페이스가 보증하는 것:
/// - **멱등**이다. 같은 목록으로 다시 불러도 중복 등록하지 않고, 꺼진 앱의 등록은 정리한다.
/// - **빈 목록은 해제**다.
/// - `onSettled`는 **압축된 뒤에** 온다. 원시 알림이 몇 번 오든 호출자가 받는 것은 "정착했다" 1회다.
/// - `onWindowMoved`는 원시 알림마다 그 창의 windowServerID로 온다 — 드래그 중에도 온다(2026-09-11 Chrome 실측).
///   누가 옮겼는지는 담지 않는다. 사용자 조작 판정은 소비자가 자기 이동과 대조해 한다.
public protocol WindowMoveSource: Sendable {
    func observeWindowMoves(of bundleIDs: [String], onSettled: @escaping @Sendable () -> Void) async
    func observeWindowInteractions(_ onWindowMoved: @escaping @Sendable (CGWindowID) -> Void) async
}

public extension WindowMoveSource {
    func observeWindowInteractions(_ onWindowMoved: @escaping @Sendable (CGWindowID) -> Void) async {}
}
