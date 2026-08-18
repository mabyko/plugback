import CoreGraphics

/// 다른 앱의 창·프로세스를 만지는 유일한 심 (docs/ARCHITECTURE.md).
/// 어댑터 책임: 창 열거는 실행 중 앱 순회만 사용(F-06.1), 표준 창 필터(팝업·패널·시트 제외),
/// 좌표계를 좌상단 원점으로 통일, AX 호출당 응답 대기 한도 250ms(F-02.4).
///
/// 격리 계약: **구현이 자기 실행 흐름을 소유한다.** 실물 어댑터는 actor라 AX 왕복이
/// 메인 액터를 막지 않는다 (F-02.4 "복원은 UI를 막지 않는다"). 호출자는 어디서든 await만 하면 된다.
public protocol WindowGateway: Sendable {
    /// 실행 중인 앱들의 표준 창. bundleIDs가 nil이면 실행 중 전체.
    /// 실행 중이 아닌 앱은 결과에 나타나지 않는다 — 앱을 실행시키지 않는다 (F-02.1).
    /// 창 ID의 수명: **마지막 열거가 돌려준 ID만 유효하다.** 다시 열거하면 이전 ID는
    /// 죽은 것으로 취급하라 — 어댑터에 따라 조용히 다른 창을 가리킬 수 있다.
    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo]

    /// 창을 목표 프레임으로 옮기고 실제 프레임을 다시 읽어 돌려준다 (F-02.3 검증).
    /// 전체화면 창은 이동이 조용히 실패하므로 반환값 없이는 감지할 수 없다 (FUNCTIONAL_SPEC 부록 1).
    /// nil은 창이 사라졌거나 앱이 응답하지 않는 경우다.
    func move(windowID: Int, to frame: CGRect) async -> CGRect?

    /// 앱 실행 여부 — 건너뜀 사유(꺼짐 vs 이 화면에 창 없음) 구분용.
    /// 창 열거와 같은 앱 집합을 봐야 한다. 화면 열거는 여기가 아니라 ScreenProvider의 일이다.
    func isRunning(bundleID: String) async -> Bool

    /// Dock에 최소화된 창을 꺼내고 **실제 프레임을 다시 읽어 돌려준다** — 꺼내는 순간
    /// 프레임이 바뀔 수 있으므로 이전 스냅샷을 믿으면 안 된다 (move와 같은 처방).
    /// nil이면 창이 사라졌거나 앱이 거부한 것 — 호출자는 건너뜀으로 처리한다.
    func unminimize(windowID: Int) async -> CGRect?

    /// 실행 중인데 창이 없는 앱에 새 창을 열게 하고(Dock 클릭과 동일한 reopen),
    /// 표준 창이 실제로 나타날 때까지 기다린다. 창이 비동기로 나타난다는 플랫폼 현실은
    /// 이 구현 안의 일이다 — 호출자는 타이밍을 모른다.
    /// true = 표준 창이 지금 존재한다(다시 열거하면 나온다). false = 한도 내에 안 나타났거나 앱이 없다.
    /// 꺼진 앱을 실행하지는 않는다 — F-02.1은 유지된다.
    func openWindow(bundleID: String) async -> Bool

    /// 대상 앱의 창이 움직이거나 크기가 바뀌면 알린다 (실험실 · 자동 슬롯의 수집 트리거, F-08.3).
    /// 폴링이 아니라 구독이다 — 창이 가만히 있으면 아무것도 발화하지 않는다.
    ///
    /// **드래그 폭주는 구현이 압축한다.** 원시 알림은 드래그 내내 초당 수십 번 오지만
    /// 호출자가 받는 것은 "정착했다" 1회다 — DisplayWatcher가 연결 이벤트에 하는 것과 같은 처방이다.
    /// 멱등이다: 같은 목록으로 다시 불러도 중복 등록하지 않고, 꺼진 앱의 등록은 정리한다.
    /// 빈 목록을 주면 전부 해제한다.
    func observeWindowMoves(of bundleIDs: [String], onSettled: @escaping @Sendable () -> Void) async
}

public extension WindowGateway {
    /// 관찰을 지원하지 않는 어댑터의 기본값 — 무동작. 그런 어댑터에서는 앱 전환 신호만으로 수집한다.
    func observeWindowMoves(of bundleIDs: [String], onSettled: @escaping @Sendable () -> Void) async {}
}
