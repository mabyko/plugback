import PlugbackKit
import XCTest
import CoreGraphics
@testable import Plugback

/// App/의 표현 매핑 검증 — 사용자가 읽는 문구·점·헤더·다이얼로그의 전 분기.
/// 렌더(SwiftUI)는 돌리지 않는다 — 뷰는 이 매핑의 배치일 뿐이다.
final class CardPresentationTests: XCTestCase {
    private let screen = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

    func testSkipReasonWordingCoversEveryOutcome() {
        // US-008: "왜 안 옮겨졌지?"의 답 전부 — 이전엔 컴파일러의 exhaustive switch만 방어했다
        XCTAssertEqual(CardPresentation.describe(.moved), "이동")
        XCTAssertEqual(CardPresentation.describe(.failed), "이동 실패")
        XCTAssertEqual(CardPresentation.describe(.skipped(.appNotRunning)), "꺼져 있어 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.fullscreen)), "전체화면이라 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.minimized)), "최소화되어 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.alreadyInPlace)), "이미 제자리")
        XCTAssertEqual(CardPresentation.describe(.skipped(.noWindow)), "창이 없어 건너뜀")
    }

    func testSourceLabelNamesTheWinningSlotAndItsTime() {
        // 자동으로 뭔가 저장되는데 볼 수 없으면 조용한 게 아니라 불투명한 것이다.
        // 날짜를 고정해 넣는다 — 오늘/오늘 아님 두 분기를 시계 없이 검증한다.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 20))!
        let sameDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 18, minute: 2))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 15, minute: 12))!

        XCTAssertEqual(CardPresentation.sourceLabel(slot: .auto, savedAt: sameDay, now: now, calendar: calendar),
                       "복원 소스 · 자동 · 오후 6:02")
        XCTAssertEqual(CardPresentation.sourceLabel(slot: .manual, savedAt: earlier, now: now, calendar: calendar),
                       "복원 소스 · 수동 · 8월 15일 오후 3:12")
        // 구버전 파일에는 시각이 없다 — 지어내지 않고 슬롯만 말한다
        XCTAssertEqual(CardPresentation.sourceLabel(slot: .manual, savedAt: nil, now: now, calendar: calendar),
                       "복원 소스 · 수동")
    }

    func testDotFollowsPrediction() {
        // 점의 제품 약속: 찬 점 = 복원이 잘 될 것, 빈 점 = 건너뜀 예정, 회색 = 꺼짐 (US-006 AC-1)
        XCTAssertEqual(CardPresentation.dotStyle(for: .willMove), .filled)
        XCTAssertEqual(CardPresentation.dotStyle(for: .alreadyInPlace), .filled)
        XCTAssertEqual(CardPresentation.dotStyle(for: .willSkip(.appNotRunning)), .off)
        XCTAssertEqual(CardPresentation.dotStyle(for: .willSkip(.noWindow)), .hollow)
        XCTAssertEqual(CardPresentation.dotStyle(for: .willSkip(.fullscreen)), .hollow)
        XCTAssertEqual(CardPresentation.dotStyle(for: .willSkip(.minimized)), .hollow)

        XCTAssertEqual(CardPresentation.dotLabel(for: .willMove), "복원 대상")
        XCTAssertEqual(CardPresentation.dotLabel(for: .alreadyInPlace), "제자리")
        XCTAssertEqual(CardPresentation.dotLabel(for: .willSkip(.appNotRunning)), "꺼짐")
        XCTAssertEqual(CardPresentation.dotLabel(for: .willSkip(.noWindow)), "창 없음")
        XCTAssertEqual(CardPresentation.dotLabel(for: .willSkip(.fullscreen)), "전체화면")
        XCTAssertEqual(CardPresentation.dotLabel(for: .willSkip(.minimized)), "최소화")
    }

    func testHeaderTitleForThreePresences() {
        // 빈 상태에서도 카드는 비지 않는다 (ARCHITECTURE 고정 결정)
        XCTAssertEqual(CardPresentation.headerTitle(for: .connected(screen, count: 1)), "LG UltraFine 27")
        XCTAssertEqual(CardPresentation.headerTitle(for: .connected(screen, count: 3)), "LG UltraFine 27 외 2대")
        XCTAssertEqual(CardPresentation.headerTitle(for: .remembered(screenID: "ext-1", name: "LG UltraFine 27")),
                       "LG UltraFine 27")
        XCTAssertEqual(CardPresentation.headerTitle(for: .none), "외장 화면 없음")
    }

    func testHeaderBadge() {
        XCTAssertEqual(CardPresentation.headerBadge(for: .connected(screen, count: 1), hasProfile: true),
                       .init(text: "프로필 있음", highlighted: true))
        XCTAssertEqual(CardPresentation.headerBadge(for: .connected(screen, count: 1), hasProfile: false),
                       .init(text: "프로필 없음", highlighted: false))
        XCTAssertEqual(CardPresentation.headerBadge(for: .remembered(screenID: "x", name: "y"), hasProfile: true),
                       .init(text: "연결 해제됨", highlighted: false))
        XCTAssertNil(CardPresentation.headerBadge(for: .none, hasProfile: false))
    }

    func testIntentDialogCoversEveryOutcome() {
        // F-05.5: 단축어 사용자가 보는 문구 전부 — 실행 안 된 경로도 성공과 구별돼 보인다
        XCTAssertEqual(CardPresentation.intentDialog(for: .notAuthorized),
                       "손쉬운 사용 권한이 필요합니다. 메뉴바에서 Plugback을 여세요.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .notConnected), "외장 화면이 연결되어 있지 않습니다.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .alreadyRestoring), "이미 복원 중입니다.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .restored([])), "복원할 프로필이 없습니다.")

        // 다중 화면 결과는 합산해서 보고한다
        let a = RestoreResult(screenID: "ext-1", entries: [
            .init(bundleID: "com.a", displayName: "A", outcome: .moved),
            .init(bundleID: "com.b", displayName: "B", outcome: .skipped(.minimized)),
        ])
        let b = RestoreResult(screenID: "ext-2", entries: [
            .init(bundleID: "com.c", displayName: "C", outcome: .moved),
            .init(bundleID: "com.d", displayName: "D", outcome: .failed),
        ])
        XCTAssertEqual(CardPresentation.intentDialog(for: .restored([a, b])), "이동 2 · 건너뜀 1 · 실패 1")
    }
}
