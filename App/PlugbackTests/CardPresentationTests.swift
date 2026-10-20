@testable import PlugbackKit
import XCTest
import CoreGraphics
@testable import Plugback

/// App/의 표현 매핑 검증 — 사용자가 읽는 문구·점·헤더·다이얼로그의 전 분기.
/// 렌더(SwiftUI)는 돌리지 않는다 — 뷰는 이 매핑의 배치일 뿐이다.
final class CardPresentationTests: XCTestCase {
    private let screen = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                                    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
    private let placementID = UUID()


    func testWaitingStillOffersSaveAndNewRestoreInAdditionalActions() {
        var facts = CardFacts(presence: .connected(screen, count: 1), hasSnapshot: true)
        facts.openItems = [.init(id: UUID(), screen: .init(name: "Studio Display"),
                                 spaceNumber: 2, outcome: .awaitingVisit)]
        let actions = CardPresentation.additionalButtons(facts)
        XCTAssertEqual(actions.map(\.action), [.save, .restore])
        XCTAssertTrue(actions.allSatisfy(\.isEnabled))
        facts.isRestoring = true
        XCTAssertTrue(CardPresentation.additionalButtons(facts).allSatisfy { !$0.isEnabled })
        facts.isRestoring = false
        facts.isSettling = true
        XCTAssertTrue(CardPresentation.additionalButtons(facts).allSatisfy { !$0.isEnabled })
        XCTAssertTrue(CardPresentation.buttons(for: .settling, facts: facts).allSatisfy { !$0.isEnabled })
        facts.isSettling = false
        facts.isSaveBlocked = true
        XCTAssertFalse(CardPresentation.additionalButtons(facts)[0].isEnabled)
    }

    func testSaveFailureNamesItsWorkspaceAndThePreservedSource() {
        let workspace = PlugbackController.WorkspaceSummary(
            key: WorkspaceKey(screenIDs: [screen.id]), screens: [.init(name: "Studio Display")],
            appCount: 1, enabledAppCount: 1, windowCount: 1, savedAt: nil, savedBy: .manual)
        let message = CardPresentation.saveFailureNotice(workspace)
        XCTAssertTrue(message.contains("Studio Display"))
        XCTAssertTrue(message.contains("이전 저장 완료본"))
        XCTAssertTrue(message.contains("수동"))
    }

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
        // 이미 제자리는 건너뜀이 아니라 별도 칸이다 — 「이동 0 · 건너뜀 1」로 읽히면 실패처럼 보인다
        XCTAssertEqual(CardPresentation.summary([RestoreResult(screenID: "x", entries: [
            .init(placementID: UUID(), bundleID: "a", displayName: "A", outcome: .skipped(.alreadyInPlace)),
        ])]), "이동 0 · 이미 제자리 1 · 실패 0")
        XCTAssertEqual(CardPresentation.summary(results([.moved, .moved, .skipped(.alreadyInPlace), .skipped(.fullscreen)])),
                       "이동 2 · 이미 제자리 1 · 건너뜀 1 · 실패 0")
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
                       "저장 대기 이력 · 아직 수집 안 함")
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

    func testHeaderNamesEveryScreenOfTheWorkspace() {
        // 작업 환경 = 외장 화면 조합 — 「첫 화면 외 N대」로 줄이면 A와 A+B가 같은 이름으로 보인다
        XCTAssertEqual(CardPresentation.headerTitle(screens: [ScreenLabel(name: "LG UltraFine 27")]), "LG UltraFine 27")
        XCTAssertEqual(CardPresentation.headerTitle(screens: [ScreenLabel(name: "LG Fine 24", portLocation: .leftBack),
                                                              ScreenLabel(name: "DELL", portLocation: .right)]),
                       "LG Fine 24 (왼쪽 위) + DELL (오른쪽)")
        XCTAssertEqual(CardPresentation.headerTitle(screens: []), "외장 화면 없음")
        XCTAssertEqual(CardPresentation.workspaceName([ScreenLabel(name: "A"), ScreenLabel(name: "B")]), "A + B")
    }

    func testHeaderBadgeOnlySaysWhetherScreensAreConnected() {
        // 「연결됨」은 「복원 완료」가 아니다 — 저장본·결과는 상태 구획이 말한다
        XCTAssertEqual(CardPresentation.headerBadge(for: .connected(screen, count: 1)), .init(text: "연결됨", highlighted: true))
        XCTAssertEqual(CardPresentation.headerBadge(for: .connected(screen, count: 3)), .init(text: "연결됨", highlighted: true))
        XCTAssertEqual(CardPresentation.headerBadge(for: .remembered(screenID: "x", name: "y")),
                       .init(text: "연결 해제됨", highlighted: false))
        XCTAssertNil(CardPresentation.headerBadge(for: .none))
    }

    func testIntentDialogCoversEveryOutcome() {
        XCTAssertEqual(CardPresentation.intentDialog(for: .notAuthorized), "손쉬운 사용 권한이 필요합니다. 메뉴바에서 Plugback을 여세요.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .notConnected), "외장 화면이 연결되어 있지 않습니다.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .alreadyRestoring), "이미 복원 중입니다.")
        XCTAssertEqual(CardPresentation.intentDialog(for: .restored([])), "아직 확인된 복원 결과가 없습니다. 메뉴바에서 저장본과 진행 상태를 확인하세요.")
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

    // MARK: - 카드 상태 (2026-10 재설계) — 상태 한 문장과 다음 행동

    private var connected: ScreenPresence { .connected(screen, count: 1) }

    private func waiting(_ outcome: RestoreResult.Outcome, screen name: String = "LG Fine 24",
                         space: Int? = 2) -> PlugbackController.WaitingItem {
        .init(id: UUID(), screen: ScreenLabel(name: name), spaceNumber: space, outcome: outcome)
    }

    private func results(_ outcomes: [RestoreResult.Outcome]) -> [RestoreResult] {
        [RestoreResult(screenID: "ext-1", entries: outcomes.map {
            .init(placementID: UUID(), bundleID: "a", displayName: "A", outcome: $0)
        })]
    }

    private func section(_ id: String = "ext-1", savedBy: Slot? = .manual, savedAt: Date? = nil,
                         spaceGroups: [PlugbackController.SpaceGroup] = []) -> PlugbackController.ScreenSection {
        .init(screenID: id, label: ScreenLabel(name: id), hasSnapshot: savedBy != nil, savedAt: savedAt, savedBy: savedBy,
              apps: [], presentApps: [], absentSavedApps: [], excludedApps: [], spaceGroups: spaceGroups,
              spaceConfigurationDiffers: false, lastResult: nil)
    }

    func testRemainingWorkComesBeforeSettlingAndResults() {
        var facts = CardFacts(presence: connected, hasSnapshot: true, isSettling: true, results: results([.moved]))
        facts.openItems = [waiting(.awaitingVisit), waiting(.held(.screenLocked)),
                           waiting(.needsConfirmation(.closureUnknown)), waiting(.awaitingSpaceMove(sourceScreenID: "builtin"))]
        XCTAssertEqual(CardPresentation.status(facts), .awaitingSpaceMove, "사용자가 옮겨야 하는 일이 먼저다")
        facts.openItems.removeLast()
        XCTAssertEqual(CardPresentation.status(facts), .needsConfirmation(count: 1))
        facts.openItems.removeLast()
        XCTAssertEqual(CardPresentation.status(facts), .held(.screenLocked))
        facts.openItems.append(waiting(.held(.lockStateUndetermined)))
        XCTAssertEqual(CardPresentation.status(facts), .held(.lockStateUndetermined), "판정 불가는 사용자가 재개해야 한다")
        facts.openItems = [waiting(.awaitingVisit), waiting(.awaitingVisit, space: 3)]
        XCTAssertEqual(CardPresentation.status(facts), .awaitingVisit(count: 2))
        facts.openItems = []
        XCTAssertEqual(CardPresentation.status(facts), .settling)
        facts.isRestoring = true
        facts.openItems = [waiting(.awaitingVisit)]
        XCTAssertEqual(CardPresentation.status(facts), .restoring)
        XCTAssertNil(CardPresentation.statusText(.restoring, facts: facts).symbol, "진행은 퍼센트 없는 진행 표시다")
    }

    func testEachRemainingStateKeepsItsOwnMeaning() {
        let facts = CardFacts(presence: connected, hasSnapshot: true)
        let move = CardPresentation.statusText(.awaitingSpaceMove, facts: facts)
        XCTAssertEqual(move.title, "Space를 옮겨 주세요")
        XCTAssertTrue(move.detail?.contains("Mission Control") == true)
        let confirm = CardPresentation.statusText(.needsConfirmation(count: 2), facts: facts)
        XCTAssertEqual(confirm.title, "창 2개를 확인해 주세요")
        XCTAssertTrue(confirm.detail?.contains("「남은 창 복원」을 눌러야") == true, "확인 필요는 명시적 재개로만 이어진다")
        XCTAssertEqual(CardPresentation.statusText(.held(.screenLocked), facts: facts).title, "잠금 해제를 기다려요")
        XCTAssertEqual(CardPresentation.statusText(.held(.lockStateUndetermined), facts: facts).tone, .attention)
        let visit = CardPresentation.statusText(.awaitingVisit(count: 3), facts: facts)
        XCTAssertEqual(visit.title, "창 3개가 Space 방문을 기다려요")
        XCTAssertTrue(visit.detail?.contains("열면") == true, "Space는 사용자가 연다 — 앱이 열어 주는 버튼처럼 쓰지 않는다")
        let titles = [move, confirm, visit].map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testReadyIsNotRestoredAndFinishedSeparatesInPlaceFromMoved() {
        let ready = CardFacts(presence: connected, hasSnapshot: true)
        XCTAssertEqual(CardPresentation.status(ready), .ready)
        XCTAssertEqual(CardPresentation.statusText(.ready, facts: ready).title, "복원할 준비가 됐어요")

        func finished(_ outcomes: [RestoreResult.Outcome]) -> (CardStatus, CardStatusText) {
            var facts = ready
            facts.results = results(outcomes)
            let status = CardPresentation.status(facts)
            return (status, CardPresentation.statusText(status, facts: facts))
        }
        let all = finished([.moved, .moved, .skipped(.alreadyInPlace)])
        XCTAssertEqual(all.0, .finished(ResultTally(moved: 2, inPlace: 1)))
        XCTAssertEqual(all.1.title, "저장한 자리로 모두 복원했어요")
        XCTAssertEqual(all.1.tone, .done)
        XCTAssertEqual(finished([.skipped(.alreadyInPlace), .skipped(.alreadyInPlace)]).1.title, "모든 창이 이미 제자리예요")
        let failed = finished([.moved, .failed])
        XCTAssertEqual(failed.1.title, "창 1개를 옮기지 못했어요")
        XCTAssertEqual(failed.1.tone, .failure)
        XCTAssertNotNil(failed.1.detail, "실패 사유로 가는 길을 알려 준다")
        let mixed = finished([.moved, .skipped(.appNotRunning), .cancelled(.userCancelled)])
        XCTAssertEqual(mixed.1.title, "복원 요청을 마쳤어요", "건너뜀·취소가 있으면 모두 복원했다고 말하지 않는다")
        XCTAssertNotNil(mixed.1.detail)
    }

    func testWorkspaceWithoutSnapshotIsFirstSaveEvenWithAnotherWorkspaceResult() {
        // T4 — 저장본 없는 A에 A+B 결과가 남아 있어도 첫 저장 상태이며 그 결과는 보이지 않는다
        var facts = CardFacts(presence: connected, hasSnapshot: false, results: results([.moved]))
        XCTAssertEqual(CardPresentation.status(facts), .firstSave)
        XCTAssertTrue(facts.visibleResults.isEmpty)
        XCTAssertTrue(CardPresentation.statusText(.firstSave, facts: facts).detail?.contains("떠날 때 자동으로 저장") == true)
        facts.autoSave = false
        XCTAssertFalse(CardPresentation.statusText(.firstSave, facts: facts).detail?.contains("자동") == true,
                       "자동 저장이 꺼져 있으면 자동 저장을 약속하지 않는다")
    }

    func testDisconnectedAndNoScreenStates() {
        var gone = CardFacts(presence: .remembered(screenID: "ext-1", name: "LG"), hasSnapshot: true)
        XCTAssertEqual(CardPresentation.status(gone), .disconnected(hasSnapshot: true))
        XCTAssertTrue(CardPresentation.statusText(.disconnected(hasSnapshot: true), facts: gone).detail?.contains("자동으로 복원") == true)
        gone.restoreMode = .manual
        XCTAssertTrue(CardPresentation.statusText(.disconnected(hasSnapshot: true), facts: gone).detail?.contains("「지금 복원」") == true)
        gone.hasSnapshot = false
        XCTAssertEqual(CardPresentation.status(gone), .disconnected(hasSnapshot: false))
        let none = CardFacts(presence: .none)
        XCTAssertEqual(CardPresentation.status(none), .noScreen)
        XCTAssertEqual(CardPresentation.statusText(.noScreen, facts: none).title, "외장 화면을 연결해 주세요")
    }

    func testButtonsFollowTheStatus() {
        let ready = CardFacts(presence: connected, hasSnapshot: true)
        XCTAssertEqual(CardPresentation.buttons(for: .ready, facts: ready).map(\.action), [.restore, .save])
        XCTAssertEqual(CardPresentation.buttons(for: .ready, facts: ready).last?.accessibilityLabel, "지금 레이아웃 저장")
        var blocked = ready
        blocked.isSaveBlocked = true
        XCTAssertEqual(CardPresentation.buttons(for: .ready, facts: blocked).map(\.isEnabled), [true, false])

        let first = CardFacts(presence: connected)
        XCTAssertEqual(CardPresentation.buttons(for: .firstSave, facts: first).map(\.title), ["지금 레이아웃 저장", "지금 복원"])
        XCTAssertEqual(CardPresentation.buttons(for: .firstSave, facts: first).map(\.isEnabled), [true, false])

        let visit = CardFacts(presence: connected, hasSnapshot: true, openItems: [waiting(.awaitingVisit)])
        XCTAssertEqual(CardPresentation.buttons(for: .awaitingVisit(count: 1), facts: visit).map(\.action),
                       [.resumeRemaining, .cancelRemaining])
        XCTAssertEqual(CardPresentation.buttons(for: .needsConfirmation(count: 1), facts: visit).map(\.action),
                       [.openConfirmation, .cancelRemaining])
        var running = visit
        running.isRestoring = true
        XCTAssertEqual(CardPresentation.buttons(for: .restoring, facts: running).map(\.isEnabled), [false, false])
        XCTAssertEqual(CardPresentation.buttons(for: .restoring, facts: running).first?.title, "복원 중…")
        let gone = CardFacts(presence: .remembered(screenID: "ext-1", name: "LG"), hasSnapshot: true)
        XCTAssertEqual(CardPresentation.buttons(for: .disconnected(hasSnapshot: true), facts: gone).map(\.isEnabled), [false, false])
    }

    func testRequestLinesGroupSamePlaceAndPutUserActionFirst() {
        let lg = ScreenLabel(name: "LG Fine 24", portLocation: .right)
        let dell = ScreenLabel(name: "DELL")
        let items: [PlugbackController.WaitingItem] = [
            .init(id: UUID(), screen: lg, spaceNumber: 2, outcome: .awaitingVisit),
            .init(id: UUID(), screen: lg, spaceNumber: 2, outcome: .awaitingVisit),
            .init(id: UUID(), screen: dell, spaceNumber: nil, outcome: .held(.screenLocked)),
            .init(id: UUID(), screen: lg, spaceNumber: 1, outcome: .needsConfirmation(.closureUnknown)),
            .init(id: UUID(), screen: dell, spaceNumber: nil, outcome: .awaitingSpaceMove(sourceScreenID: "builtin")),
        ]
        XCTAssertEqual(CardPresentation.requestLines(items).map(\.text), [
            "DELL 이동 필요",
            "DELL · 잠금 해제 대기",
            "LG Fine 24 (오른쪽) · Space 2 방문 대기 · 창 2개",
        ], "확인 필요는 「복원 확인」 진입점이 따로 맡는다")
    }

    func testRequestGuidesSkipVisitAndRepeatNothing() {
        let destination = ScreenLabel(name: "LG UltraFine 27", portLocation: .right)
        let move = PlugbackController.SpaceGroup.Guide.move(source: ScreenLabel(name: "내장 화면"), destination: destination)
        let groups = [
            PlugbackController.SpaceGroup(id: "a", kind: .regular(number: 1, state: .otherDisplay), apps: [], guide: move),
            PlugbackController.SpaceGroup(id: "b", kind: .regular(number: 2, state: .inactive), apps: [],
                                          guide: .visit(destination: destination)),
            PlugbackController.SpaceGroup(id: "c", kind: .regular(number: 3, state: .otherDisplay), apps: [], guide: move),
        ]
        XCTAssertEqual(CardPresentation.requestGuides(in: [section(spaceGroups: groups)]),
                       ["내장 화면 → LG UltraFine 27 (오른쪽)\nMission Control에서 이 Space를 옮겨 주세요."])
    }

    func testRestoreSourceIsOneLinePerWorkspaceWithManyScreens() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20))!
        let saved = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18, minute: 2))!
        let sections = [section("ext-1", savedBy: .auto, savedAt: saved), section("ext-2", savedBy: .auto, savedAt: saved),
                        section("ext-3", savedBy: .auto, savedAt: saved)]
        XCTAssertEqual(CardPresentation.sourceLabel(for: sections, now: now, calendar: calendar), "복원 소스 · 자동 · 오후 6:02")
        XCTAssertNil(CardPresentation.sourceLabel(for: [section(savedBy: nil)]), "저장본이 없으면 복원 소스도 없다")
        XCTAssertNil(CardPresentation.sourceLabel(for: []))
    }

    func testPendingHistoryNeverReadsAsTheRestoreSource() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func pending(autoSave: Bool = true, blocked: Bool = false, connected: Bool = true, differs: Bool = false) -> CardNote? {
            CardPresentation.pendingStatus(autoSave: autoSave, isSaveBlocked: blocked, isConnected: connected,
                                           collectedAt: now.addingTimeInterval(-120), hasPending: true,
                                           spaceConfigurationDiffers: differs, now: now)
        }
        XCTAssertEqual(pending(), CardNote(text: "저장 대기 · 2분 전 배치 — 환경을 떠날 때 저장", isWarning: false))
        XCTAssertEqual(pending(blocked: true), CardNote(text: "저장 중지됨 · 저장 파일 확인 필요", isWarning: true))
        XCTAssertNil(pending(connected: false))
        XCTAssertEqual(pending(autoSave: false)?.text, CardPresentation.autoSaveOffLabel)
        XCTAssertEqual(pending(autoSave: false, differs: true)?.text, CardPresentation.manualSpaceConfigurationDifference)
        for note in [pending(), pending(blocked: true), pending(autoSave: false)].compactMap({ $0 }) {
            XCTAssertFalse(note.text.hasPrefix("복원 소스"), "저장 대기 이력은 복원 기준이 아니다")
        }
    }

    func testTargetSummaryCountsCurrentAppsBeforeTheFirstSave() {
        XCTAssertEqual(CardPresentation.targetSummary(hasSnapshot: true, appCount: 8, windowCount: 11, spaceCount: 3,
                                                      presentAppCount: 2), "앱 8개 · 창 11개 · Space 3개")
        XCTAssertEqual(CardPresentation.targetSummary(hasSnapshot: true, appCount: 8, windowCount: 11, spaceCount: 0,
                                                      presentAppCount: 2), "앱 8개 · 창 11개")
        XCTAssertEqual(CardPresentation.targetSummary(hasSnapshot: false, appCount: 0, windowCount: 0, spaceCount: 0,
                                                      presentAppCount: 6), "저장 전 · 지금 화면에 있는 앱 6개")
    }

    func testRemovalNamesSavedRecordsAndDiffersFromExclusion() {
        XCTAssertEqual(CardPresentation.removeRecordsAction, "저장 기록 삭제")
        XCTAssertEqual(CardPresentation.removalTitle("Safari"), "Safari의 저장 기록을 삭제할까요?")
        let detail = CardPresentation.removalDetail(windowCount: 3)
        XCTAssertTrue(detail.contains("창 위치 기록 3개"))
        XCTAssertTrue(detail.contains("되돌릴 수 없습니다"))
        XCTAssertTrue(detail.contains("체크만 끄세요"), "기록을 남기는 제외와 지우는 삭제를 구별한다")
        let placement = CardPresentation.placementRemovalMessage(name: "Slack", place: "DELL · Space 2")
        XCTAssertTrue(placement.hasPrefix("Slack · DELL · Space 2"))
        for text in [CardPresentation.removeRecordsAction, CardPresentation.removalTitle("Safari"), detail,
                     CardPresentation.placementRemovalTitle, placement, CardPresentation.selectionScopeNote] {
            XCTAssertFalse(text.contains("프로필"), "CONTEXT 금지어")
        }
    }

    func testStoreNoticesSayWhatWasKept() {
        XCTAssertTrue(CardPresentation.storeNotice(.writeFailed).contains("복원은 이전 저장본을 씁니다"))
        XCTAssertTrue(CardPresentation.storeNotice(.unreadable).contains("덮어쓰기를 막았습니다"))
        XCTAssertTrue(CardPresentation.storeNotice(.unsupportedVersion(3)).contains("버전 3"))
        XCTAssertTrue(CardPresentation.storeNotice(.corruptionBackedUp(URL(fileURLWithPath: "/tmp/backup.json"))).contains("백업"))
    }

    func testCaptureFeedbackDoesNotRepeatTheSpacesNotice() {
        XCTAssertEqual(CardPresentation.captureFeedback(.captured(appCount: 2, windowCount: 3), spacesSupport: .separateSpaces),
                       CardNote(text: "저장됨 · 앱 2개 · 창 3개", isWarning: false))
        XCTAssertNil(CardPresentation.captureFeedback(.spacesUnsupported(.sharedSpaces), spacesSupport: .sharedSpaces),
                     "같은 개별 Spaces 안내는 경고 구획에 이미 있다")
        XCTAssertEqual(CardPresentation.captureFeedback(.spacesUnsupported(.sharedSpaces), spacesSupport: .separateSpaces)?.isWarning, true)
        XCTAssertEqual(CardPresentation.captureFeedback(.spaceObservationUnavailable, spacesSupport: .separateSpaces)?.isWarning, true)
        XCTAssertNil(CardPresentation.captureFeedback(nil, spacesSupport: .separateSpaces))
    }
}
