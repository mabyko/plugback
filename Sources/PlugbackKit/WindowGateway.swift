import CoreGraphics

/// 접근성 API를 만지는 유일한 심 (docs/ARCHITECTURE.md).
/// 어댑터 책임: 창 열거는 실행 중 앱 순회만 사용(F-06.1), 표준 창 필터(팝업·패널·시트 제외),
/// 좌표계를 좌상단 원점으로 통일, 앱당 응답 대기 한도 250ms(F-02.4).
public protocol WindowGateway {
    /// 실행 중인 앱들의 표준 창. bundleIDs가 nil이면 실행 중 전체.
    /// 실행 중이 아닌 앱은 결과에 나타나지 않는다 — 앱을 실행시키지 않는다 (F-02.1).
    func standardWindows(of bundleIDs: [String]?) -> [WindowInfo]

    /// 창을 목표 프레임으로 옮기고 실제 프레임을 다시 읽어 돌려준다 (F-02.3 검증).
    /// 전체화면 창은 이동이 조용히 실패하므로 반환값 없이는 감지할 수 없다 (FUNCTIONAL_SPEC 부록 1).
    /// nil은 창이 사라졌거나 앱이 응답하지 않는 경우다.
    func move(windowID: Int, to frame: CGRect) -> CGRect?

    /// 앱 실행 여부 — 건너뜀 사유(꺼짐 vs 이 화면에 창 없음) 구분용.
    /// 창 열거와 같은 앱 집합을 봐야 한다. 화면 열거는 여기가 아니라 ScreenProvider의 일이다.
    func isRunning(bundleID: String) -> Bool
}
