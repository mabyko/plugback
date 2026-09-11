import CoreGraphics

/// 다른 앱의 창·프로세스를 만지는 유일한 심 (docs/ARCHITECTURE.md).
/// 어댑터 책임: 창 열거는 실행 중 앱 순회만 사용(F-06.1), 표준 창 필터(팝업·패널·시트 제외),
/// 좌표계를 좌상단 원점으로 통일, AX 호출당 응답 대기 한도 250ms(F-02.4).
///
/// 격리 계약: **구현이 자기 실행 흐름을 소유한다.** 실물 어댑터는 actor라 AX 왕복이
/// 메인 액터를 막지 않는다 (F-02.4 "복원은 UI를 막지 않는다"). 호출자는 어디서든 await만 하면 된다.
public protocol WindowGateway: Sendable {
    /// 실행 중인 앱들의 표준 창. bundleIDs가 nil이면 실행 중 전체.
    /// 실행 중이 아닌 앱은 결과에 나타나지 않는다. 앱 실행은 `launch`만 한다.
    /// 창 ID의 수명: **마지막 열거가 돌려준 ID만 유효하다.** 다시 열거하면 이전 ID는
    /// 죽은 것으로 취급하라 — 어댑터에 따라 조용히 다른 창을 가리킬 수 있다.
    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo]

    /// 마지막 열거에서 창 목록을 읽지 못한 앱. 조회 실패는 「창 없음」이 아니다 (O05·O07).
    func enumerationFailures() async -> Set<String>

    /// 지금 존재하는 창 전부의 WindowServer ID — 다른 Space·최소화·숨김 창을 포함한다.
    /// 표준 창 열거(AX)는 다른 Space의 창을 빼먹으므로 닫힘 판정은 이 집합으로만 한다. nil은 알 수 없음이다.
    func existingWindowServerIDs() async -> Set<CGWindowID>?

    /// 창을 목표 프레임으로 옮기고 실제 프레임을 다시 읽어 돌려준다 (F-02.3 검증).
    /// 전체화면 창은 이동이 조용히 실패하므로 반환값 없이는 감지할 수 없다 (FUNCTIONAL_SPEC 부록 1).
    /// nil은 창이 사라졌거나 앱이 응답하지 않는 경우다.
    func move(windowID: Int, to frame: CGRect) async -> CGRect?

    /// 앱 실행 여부 — 건너뜀 사유(꺼짐 vs 이 화면에 창 없음) 구분용.
    func isRunning(bundleID: String) async -> Bool

    /// Dock에 최소화된 창을 꺼내고 **실제 프레임을 다시 읽어 돌려준다**.
    func unminimize(windowID: Int) async -> CGRect?

    /// 실행 중인데 창이 없는 앱에 기본 창을 열게 하고(Dock 클릭과 동일한 reopen),
    /// 표준 창이 실제로 나타날 때까지 기다린다. 「실행 중인 앱 창 되살리기」의 실행 경로.
    func openWindow(bundleID: String) async -> Bool

    /// 종료된 앱을 실행하고(포커스를 가져오지 않음) 표준 창이 나타날 때까지 기다린다.
    /// 「종료된 앱 다시 열기」의 실행 경로. false = 실행 요청 실패이거나 한도 안에 창이 없음.
    func launch(bundleID: String) async -> Bool

    /// 창이 하나 이상 있는 앱에 창을 하나 더 열게 하고 창 수가 늘 때까지 기다린다.
    /// 「부족한 창 추가로 열기」의 실행 경로. 앱이 지원하지 않으면 false.
    func openAdditionalWindow(bundleID: String) async -> Bool

    /// 창을 앞으로 가져온다 — 직접 지정 화면의 「창 확인」. 포커스 이동은 앱마다 다르다.
    func raise(windowID: Int) async -> Bool
}

public extension WindowGateway {
    func enumerationFailures() async -> Set<String> { [] }
    func existingWindowServerIDs() async -> Set<CGWindowID>? { nil }
    func launch(bundleID: String) async -> Bool { false }
    func openAdditionalWindow(bundleID: String) async -> Bool { false }
    func raise(windowID: Int) async -> Bool { false }
}
