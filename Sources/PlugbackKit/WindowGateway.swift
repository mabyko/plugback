import CoreGraphics

/// 접근성 API를 만지는 유일한 심 (docs/ARCHITECTURE.md).
/// 어댑터 책임: 창 열거는 실행 중 앱 순회만 사용(F-06.1), 표준 창 필터(팝업·패널·시트 제외),
/// 좌표계를 좌상단 원점으로 통일, 앱당 응답 대기 한도 250ms(F-02.4).
public protocol WindowGateway {
    /// 실행 중인 앱들의 표준 창. bundleIDs가 nil이면 실행 중 전체.
    /// 실행 중이 아닌 앱은 결과에 나타나지 않는다 — 앱을 실행시키지 않는다 (F-02.1).
    /// 창 ID의 수명: **마지막 열거가 돌려준 ID만 유효하다.** 다시 열거하면 이전 ID는
    /// 죽은 것으로 취급하라 — 어댑터에 따라 조용히 다른 창을 가리킬 수 있다.
    func standardWindows(of bundleIDs: [String]?) -> [WindowInfo]

    /// 창을 목표 프레임으로 옮기고 실제 프레임을 다시 읽어 돌려준다 (F-02.3 검증).
    /// 전체화면 창은 이동이 조용히 실패하므로 반환값 없이는 감지할 수 없다 (FUNCTIONAL_SPEC 부록 1).
    /// nil은 창이 사라졌거나 앱이 응답하지 않는 경우다.
    func move(windowID: Int, to frame: CGRect) -> CGRect?

    /// 앱 실행 여부 — 건너뜀 사유(꺼짐 vs 이 화면에 창 없음) 구분용.
    /// 창 열거와 같은 앱 집합을 봐야 한다. 화면 열거는 여기가 아니라 ScreenProvider의 일이다.
    func isRunning(bundleID: String) -> Bool

    /// Dock에 최소화된 창을 꺼내고 **실제 프레임을 다시 읽어 돌려준다** — 꺼내는 순간
    /// 프레임이 바뀔 수 있으므로 이전 스냅샷을 믿으면 안 된다 (move와 같은 처방).
    /// nil이면 창이 사라졌거나 앱이 거부한 것 — 호출자는 건너뜀으로 처리한다.
    func unminimize(windowID: Int) -> CGRect?

    /// 실행 중인데 창이 없는 앱에 새 창을 열게 하고(Dock 클릭과 동일한 reopen),
    /// 표준 창이 실제로 나타날 때까지 기다린다. 창이 비동기로 나타난다는 플랫폼 현실은
    /// 이 구현 안의 일이다 — 호출자는 타이밍을 모른다.
    /// true = 표준 창이 지금 존재한다(다시 열거하면 나온다). false = 한도 내에 안 나타났거나 앱이 없다.
    /// 꺼진 앱을 실행하지는 않는다 — F-02.1은 유지된다.
    func openWindow(bundleID: String) async -> Bool
}
