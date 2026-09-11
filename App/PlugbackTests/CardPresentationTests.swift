import PlugbackKit
import XCTest
import CoreGraphics
@testable import Plugback

/// App/의 표현 매핑 검증 — 사용자가 읽는 문구·점·헤더·다이얼로그의 전 분기.
/// 렌더(SwiftUI)는 돌리지 않는다 — 뷰는 이 매핑의 배치일 뿐이다.
final class CardPresentationTests: XCTestCase {
    private let screen = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
    private let placementID = UUID()

    func testCaptureNoticeDistinguishesSuccessFromObservationFailure() {
        XCTAssertEqual(CardPresentation.captureNotice(.captured(appCount: 2, windowCount: 3)),
                       "저장됨 · 앱 2개 · 창 3개")
        XCTAssertEqual(CardPresentation.captureNotice(.spaceObservationUnavailable),
                       "Space 상태를 확인하지 못해 저장하지 않았습니다.\n잠시 후 다시 시도해 주세요.")
        XCTAssertTrue(CardPresentation.captureNotice(.spacesUnsupported(.sharedSpaces)).contains("각각의 Spaces가 있는 디스플레이"))
        XCTAssertTrue(CardPresentation.captureNotice(.spacesUnsupported(.undetermined)).contains("확인하지 못해"))
    }

    func testOutcomeWordingCoversEveryOutcome() {
        // US-008: "왜 안 옮겨졌지?"의 답 전부 — 이전엔 컴파일러의 exhaustive switch만 방어했다
        XCTAssertEqual(CardPresentation.describe(.moved), "이동")
        XCTAssertEqual(CardPresentation.describe(.failed), "이동 실패")
        XCTAssertEqual(CardPresentation.describe(.skipped(.appNotRunning)), "꺼져 있어 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.fullscreen)), "전체화면이라 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.minimized)), "최소화되어 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.alreadyInPlace)), "이미 제자리")
        XCTAssertEqual(CardPresentation.describe(.skipped(.noWindow)), "창이 없어 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.closedInWorkspace)), "이 환경에서 닫아 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.skipped(.userInteraction)), "직접 옮기는 중이라 건너뜀")
        XCTAssertEqual(CardPresentation.describe(.awaitingVisit), "Space 방문 대기")
        XCTAssertEqual(CardPresentation.describe(.awaitingSpaceMove(sourceScreenID: "x")), "Space 이동 필요")
        XCTAssertEqual(CardPresentation.describe(.needsConfirmation(.ambiguousCandidates([1, 2]))),
                       "확인 필요 · 같은 앱 창 2개 중 어느 창인지 확인")
        XCTAssertEqual(CardPresentation.describe(.needsConfirmation(.closureUnknown)),
                       "확인 필요 · 저장된 창을 현재 확인할 수 없음 · 닫힌 시점을 알 수 없어 열지 않음")
        XCTAssertEqual(CardPresentation.describe(.needsConfirmation(.spaceMissing)), "확인 필요 · 저장한 Space를 현재 찾을 수 없음")
        XCTAssertEqual(CardPresentation.describe(.needsConfirmation(.spaceUnavailable)), "확인 필요 · Space 상태를 확인할 수 없음")
        XCTAssertEqual(CardPresentation.describe(.needsConfirmation(.windowOnAnotherSpace)), "확인 필요 · 창이 다른 Space에 있음 · 옮긴 뒤 다시 시도")
        XCTAssertEqual(CardPresentation.describe(.needsConfirmation(.windowCreationFailed)), "확인 필요 · 앱 실행·창 열기를 요청했으나 창을 확인하지 못함")
        XCTAssertEqual(CardPresentation.describe(.held(.screenLocked)), "잠금 해제 대기")
        XCTAssertEqual(CardPresentation.describe(.held(.lockStateUndetermined)), "잠금 상태를 확인하지 못해 대기")
        XCTAssertEqual(CardPresentation.describe(.cancelled(.userCancelled)), "취소 · 사용자가 취소")
        XCTAssertEqual(CardPresentation.describe(.cancelled(.automaticRestoreDisabled)), "취소 · 자동 복원 OFF로 취소")
        XCTAssertEqual(CardPresentation.describe(.cancelled(.workspaceChanged)), "취소 · 작업 환경 변경")
    }

    func testResultSymbolSeparatesFailureFromSkip() {
        XCTAssertEqual(CardPresentation.symbolName(for: .failed), "xmark.circle.fill")
        XCTAssertEqual(CardPresentation.symbolName(for: .skipped(.fullscreen)), "minus.circle")
        XCTAssertEqual(CardPresentation.symbolName(for: .skipped(.alreadyInPlace)), "checkmark.circle")
        XCTAssertEqual(CardPresentation.symbolName(for: .moved), "checkmark.circle")
        XCTAssertEqual(CardPresentation.symbolName(for: .awaitingVisit), "clock")
        XCTAssertEqual(CardPresentation.symbolName(for: .needsConfirmation(.spaceMissing)), "questionmark.circle")
    }

    func testSummaryListsEveryKindOfOutcome() {
        // 모든 대상이 결과에 남는다 — 「이동 0 · 건너뜀 0 · 실패 0」만 보이는 경로는 없다 (6장)
        let entries: [RestoreResult.Entry] = [
            .init(placementID: UUID(), bundleID: "a", displayName: "A", outcome: .moved),
            .init(placementID: UUID(), bundleID: "a", displayName: "A", outcome: .moved),
            .init(placementID: UUID(), bundleID: "b", displayName: "B", outcome: .skipped(.minimized)),
            .init(placementID: UUID(), bundleID: "c", displayName: "C", outcome: .awaitingVisit),
            .init(placementID: UUID(), bundleID: "d", displayName: "D", outcome: .needsConfirmation(.closureUnknown)),
            .init(placementID: UUID(), bundleID: "e", displayName: "E", outcome: .cancelled(.userCancelled)),
        ]
        XCTAssertEqual(CardPresentation.summary([RestoreResult(screenID: "x", entries: entries)]),
                       "이동 2 · 건너뜀 1 · 대기 1 · 확인 필요 1 · 실패 0 · 취소 1")
        XCTAssertEqual(CardPresentation.summary([RestoreResult(screenID: "x", entries: [
            .init(placementID: UUID(), bundleID: "a", displayName: "A", outcome: .skipped(.alreadyInPlace)),
        ])]), "이동 0 · 건너뜀 1 · 실패 0")
    }

    func testSourceLabelNamesTheSaveKindAndItsTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 20))!
        let sameDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 18, minute: 2))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 15, minute: 12))!

        XCTAssertEqual(CardPresentation.sourceLabel(savedBy: .auto, savedAt: sameDay, now: now, calendar: calendar),
                       "복원 소스 · 자동 · 오후 6:02")
        XCTAssertEqual(CardPresentation.sourceLabel(savedBy: .manual, savedAt: earlier, now: now, calendar: calendar),
                       "복원 소스 · 수동 · 8월 15일 오후 3:12")
        XCTAssertEqual(CardPresentation.sourceLabel(savedBy: .manual, savedAt: nil, now: now, calendar: calendar),
                       "복원 소스 · 수동")
    }

    func testPendingLabelSeparatesCollectedFromSaved() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-3), hasPending: true, now: now),
                       "저장 대기 · 방금 배치 — 환경을 떠날 때 저장")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-120), hasPending: true, now: now),
                       "저장 대기 · 2분 전 배치 — 환경을 떠날 때 저장")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now, hasPending: true, spaceConfigurationChanged: true, now: now),
                       "저장 대기 · Space 구성 변경 — 환경을 떠날 때 저장")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-30), hasPending: false, now: now),
                       "대기 중 변경 없음 · 확인 30초 전")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: now.addingTimeInterval(-5), hasPending: false, now: now),
                       "대기 중 변경 없음 · 확인 방금")
        XCTAssertEqual(CardPresentation.pendingLabel(collectedAt: nil, hasPending: false, now: now),
                       "대기 중 변경 없음 · 아직 확인 안 함")
    }

    func testSaveBlockedStatusRemainsAfterTheDismissibleBanner() {
        XCTAssertEqual(CardPresentation.saveBlockedStatus, "저장 중지됨 · 저장 파일 확인 필요")
    }

    func testScreenNamesUsePortLocationThenLetters() {
        // 모니터 이름 + 맥 본체 포트 위치, 구분이 안 되면 A/B (P20)
        XCTAssertEqual(CardPresentation.screenName(ScreenLabel(name: "LG Fine 24", portLocation: .leftBack)), "LG Fine 24 (왼쪽 위)")
        XCTAssertEqual(CardPresentation.screenName(ScreenLabel(name: "LG Fine 24", portLocation: .leftFront)), "LG Fine 24 (왼쪽 아래)")
        XCTAssertEqual(CardPresentation.screenName(ScreenLabel(name: "LG Fine 24", portLocation: .right, letter: "A")), "LG Fine 24 (오른쪽 · A)")
        XCTAssertEqual(CardPresentation.screenName(ScreenLabel(name: "LG Fine 24", letter: "B")), "LG Fine 24 (B)")
        XCTAssertEqual(CardPresentation.screenName(ScreenLabel(name: "LG Fine 24", portLocation: .other("dock-3"))), "LG Fine 24",
                       "모르는 위치 문자열은 추정해서 표시하지 않는다")
        XCTAssertEqual(CardPresentation.screenName(ScreenLabel(name: "DELL")), "DELL")
    }

    func testSpaceGroupLabelsAndGuidanceDescribeTheAssistedFlow() {
        let current = PlugbackController.SpaceGroup.Kind.regular(number: 1, state: .current)
        let inactive = PlugbackController.SpaceGroup.Kind.regular(number: 2, state: .inactive)
        let other = PlugbackController.SpaceGroup.Kind.regular(number: 3, state: .otherDisplay)
        let missing = PlugbackController.SpaceGroup.Kind.regular(number: 4, state: .missing)
        let unknown = PlugbackController.SpaceGroup.Kind.regular(number: 5, state: .unknown)
        let destination = ScreenLabel(name: "LG UltraFine 27", portLocation: .right)
        let visit = PlugbackController.SpaceGroup.Guide.visit(destination: destination)

        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: current), "Space 1")
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: current, guide: nil), "현재")
        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: inactive), "Space 2")
        XCTAssertNil(CardPresentation.spaceGroupStatus(for: inactive, guide: nil))
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: inactive, guide: visit), "열면 복원")
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: other, guide: nil), "다른 화면")
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: other, guide: .move(source: ScreenLabel(name: "내장 화면"), destination: destination)), "이동 필요")
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: missing, guide: nil), "현재 없음")
        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: unknown), "Space 5")
        XCTAssertEqual(CardPresentation.spaceGroupStatus(for: unknown, guide: nil), "현재 상태 확인 불가")
        XCTAssertEqual(CardPresentation.spaceGroupTitle(for: .unresolved), "Space 미지정")
        XCTAssertEqual(CardPresentation.spaceGuide(.move(source: ScreenLabel(name: "내장 화면"), destination: destination)),
                       "내장 화면 → LG UltraFine 27 (오른쪽)\nMission Control에서 이 Space를 옮겨 주세요.")
        XCTAssertEqual(CardPresentation.spaceGuide(visit), "LG UltraFine 27 (오른쪽)에서 이 Space를 열면 창 위치를 자동 복원합니다.")
    }

    func testWaitingLinesAlwaysNameTheScreen() {
        // 단독 항목에도 화면 소속을 붙인다 — 「Space 2 방문 대기」만으로는 어느 화면인지 알 수 없다 (P20)
        let screen = ScreenLabel(name: "LG Fine 24", portLocation: .right)
        XCTAssertEqual(CardPresentation.waitingLine(.init(id: placementID, screen: screen, spaceNumber: 2, outcome: .awaitingVisit)),
                       "LG Fine 24 (오른쪽) · Space 2 방문 대기")
        XCTAssertEqual(CardPresentation.waitingLine(.init(id: placementID, screen: screen, spaceNumber: 1, outcome: .awaitingSpaceMove(sourceScreenID: "b"))),
                       "LG Fine 24 (오른쪽) · Space 1 이동 필요")
        XCTAssertEqual(CardPresentation.waitingLine(.init(id: placementID, screen: screen, spaceNumber: nil, outcome: .held(.lockStateUndetermined))),
                       "LG Fine 24 (오른쪽) · 잠금 상태를 확인하지 못해 복원 대기 중")
    }

    func testPlacementDescriptionReadsTheUnitRect() {
        XCTAssertEqual(CardPresentation.placementDescription(UnitRect(x: 0, y: 0, width: 0.5, height: 1)), "왼쪽 · 50%×100%")
        XCTAssertEqual(CardPresentation.placementDescription(UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)), "오른쪽 아래 · 50%×50%")
        XCTAssertEqual(CardPresentation.placementDescription(UnitRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8)), "가운데 · 50%×80%")
    }

    func testHeaderTitleForThreePresences() {
        XCTAssertEqual(CardPresentation.headerTitle(for: .connected(screen, count: 1)), "LG UltraFine 27")
        XCTAssertEqual(CardPresentation.headerTitle(for: .connected(screen, count: 3)), "LG UltraFine 27 외 2대")
        XCTAssertEqual(CardPresentation.headerTitle(for: .remembered(screenID: "ext-1", name: "LG UltraFine 27")), "LG UltraFine 27")
        XCTAssertEqual(CardPresentation.headerTitle(for: .none), "외장 화면 없음")
    }

    func testHeaderBadge() {
        XCTAssertEqual(CardPresentation.headerBadge(for: .connected(screen, count: 1), hasProfile: true),
                       .init(text: "저장본 있음", highlighted: true))
        XCTAssertEqual(CardPresentation.headerBadge(for: .connected(screen, count: 1), hasProfile: false),
                       .init(text: "저장본 없음", highlighted: false))
        XCTAssertEqual(CardPresentation.headerBadge(for: .remembered(screenID: "x", name: "y"), hasProfile: true),
                       .init(text: "연결 해제됨", highlighted: false))
        XCTAssertNil(CardPresentation.headerBadge(for: .none, hasProfile: false))
    }

    func testIntentDialogCoversEveryOutcome() {
        XCTAssertEqual(CardPresentation.intentDialog(for: .notAuthorized), "손쉬운 사용 권한이 필요합니다. 메뉴바에서 Plugback을 여세요.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .notConnected), "외장 화면이 연결되어 있지 않습니다.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .alreadyRestoring), "이미 복원 중입니다.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .restored([])), "이 작업 환경의 저장본이 없습니다.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .spacesUnsupported(.sharedSpaces)), "「각각의 Spaces가 있는 디스플레이」 설정을 켜야 복원할 수 있습니다.")

        let a = RestoreResult(screenID: "ext-1", entries: [
            .init(placementID: UUID(), bundleID: "com.a", displayName: "A", outcome: .moved),
            .init(placementID: UUID(), bundleID: "com.b", displayName: "B", outcome: .skipped(.minimized)),
        ])
        let b = RestoreResult(screenID: "ext-2", entries: [
            .init(placementID: UUID(), bundleID: "com.c", displayName: "C", outcome: .moved),
            .init(placementID: UUID(), bundleID: "com.d", displayName: "D", outcome: .failed),
        ])
        XCTAssertEqual(CardPresentation.intentDialog(for: .restored([a, b])), "이동 2 · 건너뜀 1 · 실패 1")
    }
}
