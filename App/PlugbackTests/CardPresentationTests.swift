import PlugbackKit
import XCTest
import CoreGraphics
@testable import Plugback

/// App/의 표현 매핑 검증 — 사용자가 읽는 문구·점·헤더·다이얼로그의 전 분기.
/// 렌더(SwiftUI)는 돌리지 않는다 — 뷰는 이 매핑의 배치일 뿐이다.
final class CardPresentationTests: XCTestCase {
    private let screen = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

    func testCaptureNoticeDistinguishesSuccessFromObservationFailure() {
        XCTAssertEqual(
            CardPresentation.captureNotice(.captured(appCount: 2)),
            "저장됨 · 대상 앱 2개"
        )
        XCTAssertEqual(
            CardPresentation.captureNotice(.spaceObservationUnavailable),
            "Space 상태를 확인하지 못해 저장하지 않았습니다.\n잠시 후 다시 시도해 주세요."
        )
    }

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

    func testResultSymbolSeparatesFailureFromSkip() {
        // 실패만 다른 기호 — 건너뜀과 같은 기호면 "실패 1"을 세어 읽어야 한다
        XCTAssertEqual(CardPresentation.symbolName(for: .failed), "xmark.circle.fill")
        XCTAssertEqual(CardPresentation.symbolName(for: .skipped(.fullscreen)), "minus.circle")
        XCTAssertEqual(CardPresentation.symbolName(for: .skipped(.alreadyInPlace)), "checkmark.circle")
        XCTAssertEqual(CardPresentation.symbolName(for: .moved), "checkmark.circle")
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
        XCTAssertEqual(CardPresentation.sourceLabel(slot: .auto, savedAt: nil, pending: true),
                       "복원 소스 · 현재 배치 · 저장 대기")
    }

    func testPendingLabelSeparatesCollectedFromSaved() {
        // "수집됨"이 "저장됨"으로 읽히면, 방금 옮겼는데 복원이 왜 다른 자리로 가는지 설명이 없다.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-3),
                                                     hasPending: true, now: now),
                       "저장 대기 · 방금 배치 — 뽑을 때 저장")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-120),
                                                     hasPending: true, now: now),
                       "저장 대기 · 2분 전 배치 — 뽑을 때 저장")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now,
                                                     hasPending: true,
                                                     spaceConfigurationChanged: true,
                                                     now: now),
                       "저장 대기 · Space 구성 변경 — 뽑을 때 저장")
        // 기다리는 것이 없어도 확인 시각은 보여준다 — 없으면 트리거가 죽은 것과
        // "바뀐 게 없다"가 구별되지 않는다. 「확인」이라 써서 「저장」으로 안 읽히게 한다.
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-30),
                                                     hasPending: false, now: now),
                       "대기 중 변경 없음 · 확인 30초 전")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-5),
                                                     hasPending: false, now: now),
                       "대기 중 변경 없음 · 확인 방금", "10초 미만은 「방금」으로 접힌다")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: nil, hasPending: false, now: now),
                       "대기 중 변경 없음 · 아직 확인 안 함")
    }

    func testSaveBlockedStatusRemainsAfterTheDismissibleBanner() {
        XCTAssertEqual(
            CardPresentation.saveBlockedStatus,
            "저장 중지됨 · 프로필 파일 확인 필요"
        )
    }

    func testSpaceGroupLabelsAndGuidanceDescribeTheAssistedFlow() {
        let current = PlugbackController.SpaceGroup.Kind.regular(number: 1, state: .current)
        let inactive = PlugbackController.SpaceGroup.Kind.regular(number: 2, state: .inactive)
        let other = PlugbackController.SpaceGroup.Kind.regular(number: 3, state: .otherDisplay)
        let missing = PlugbackController.SpaceGroup.Kind.regular(number: 4, state: .missing)
        let unknown = PlugbackController.SpaceGroup.Kind.regular(number: 5, state: .unknown)
        let visit = PlugbackController.SpaceGroup.Guide.visit(screenName: "LG UltraFine 27")

        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: current), "Space 1")
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: current, guide: nil), "현재")
        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: inactive), "Space 2")
        XCTAssertNil(CardPresentation.spaceGroupStatus(for: inactive, guide: nil))
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: inactive, guide: visit), "열면 복원")
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: other, guide: nil), "다른 화면")
        XCTAssertEqual(
            CardPresentation.spaceGroupStatus(
                for: other,
                guide: .move(sourceScreenName: "내장 화면", destinationScreenName: screen.name)
            ),
            "이동 필요"
        )
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: missing, guide: nil), "현재 없음")
        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: unknown), "Space 5")
        XCTAssertEqual(
            CardPresentation.spaceGroupStatus(for: unknown, guide: nil), "현재 상태 확인 불가"
        )
        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: .unresolved), "Space 확인 필요")
        XCTAssertEqual(
            CardPresentation.spaceGuide(.move(
                sourceScreenName: "내장 화면", destinationScreenName: "LG UltraFine 27"
            )),
            "내장 화면 → LG UltraFine 27\nMission Control에서 이 Space를 옮겨 주세요."
        )
        XCTAssertEqual(
            CardPresentation.spaceGuide(visit),
            "LG UltraFine 27에서 이 Space를 열면 창 위치를 자동 복원합니다."
        )
    }

    func testHeaderTitleForThreePresences() {
        // 빈 상태에서도 카드는 비지 않는다 (ARCHITECTURE 고정 결정)
        XCTAssertEqual(CardPresentation.headerTitle(for: .connected(screen, count: 1)), "LG UltraFine 27")
        XCTAssertEqual(CardPresentation.headerTitle(for: .connected(screen, count: 3)), "LG UltraFine 27 외 2대")
        XCTAssertEqual(CardPresentation.headerTitle(for: .remembered(screenID: "ext-1", name: "LG UltraFine 27")),
                       "LG UltraFine 27")
        XCTAssertEqual(CardPresentation.headerTitle(for: .none), "외장 화면 없음")
    }

    func testSectionTitlesNumberDuplicateNamesOnly() {
        // 같은 모델 두 대는 (1) (2)로 구별한다 — 이름만으로는 어느 화면의 목록인지 알 수 없다.
        XCTAssertEqual(CardPresentation.sectionTitles(names: ["LG HDR 4K", "LG HDR 4K"]),
                       ["LG HDR 4K (1)", "LG HDR 4K (2)"])
        // 이름이 유일하면 그대로 — 한 대에 (1)을 붙이면 없는 두 번째를 암시한다.
        XCTAssertEqual(CardPresentation.sectionTitles(names: ["LG HDR 4K", "DELL U2723QE"]),
                       ["LG HDR 4K", "DELL U2723QE"])
        XCTAssertEqual(CardPresentation.sectionTitles(names: ["LG HDR 4K"]), ["LG HDR 4K"])
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
