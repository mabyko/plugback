import Foundation
import PlugbackKit

/// 카드·Intent·확인 창의 표현 매핑 — 뷰에서 분리한 순수 함수들. PlugbackTests가 여기에 닿는다.
/// 문구는 앱의 것이다 — 헤드리스 코어(PlugbackKit)에 UI 문자열을 넣지 않는다 (docs/ARCHITECTURE.md §2 MenuBarUI).
enum CardPresentation {
    // MARK: - 명시적 저장 결과

    static func captureNotice(_ notice: CaptureNotice) -> String {
        switch notice {
        case .captured(let appCount, let windowCount):
            return "저장됨 · 앱 \(appCount)개 · 창 \(windowCount)개"
        case .spaceObservationUnavailable:
            return "Space 상태를 확인하지 못해 저장하지 않았습니다.\n잠시 후 다시 시도해 주세요."
        case .spacesUnsupported(let support):
            return spacesSupportNotice(support)
        }
    }

    /// 버튼 아래의 일회성 저장 결과. 같은 문구의 개별 Spaces 안내가 이미 떠 있으면 겹쳐 보이지 않는다.
    static func captureFeedback(_ notice: CaptureNotice?, spacesSupport: SpacesSupport) -> CardNote? {
        guard let notice else { return nil }
        if case .spacesUnsupported(let support) = notice, spacesSupport != .separateSpaces,
           spacesSupportNotice(support) == spacesSupportNotice(spacesSupport) { return nil }
        if case .captured = notice { return CardNote(text: captureNotice(notice), isWarning: false) }
        return CardNote(text: captureNotice(notice), isWarning: true)
    }

    /// 개별 Spaces 지원 조건 안내 (D6). 위치 전용 복원으로 조용히 전환하지 않는다.
    static func spacesSupportNotice(_ support: SpacesSupport) -> String {
        switch support {
        case .separateSpaces:
            return ""
        case .sharedSpaces:
            return "시스템 설정 › 데스크탑 및 Dock에서 「각각의 Spaces가 있는 디스플레이」를 켜야 Space별로 저장·복원할 수 있습니다.\n기존 기록은 그대로 두었습니다."
        case .undetermined:
            return "「각각의 Spaces가 있는 디스플레이」 설정을 확인하지 못해 저장·복원을 보류했습니다.\n기존 기록은 그대로 두었습니다."
        }
    }

    // MARK: - 저장소·화면 경고 — 어느 것도 다른 상태 문구에 묻히지 않는다

    static func storeNotice(_ trouble: ProfileStore.Trouble) -> String {
        switch trouble {
        case .corruptionBackedUp:
            return "저장 파일이 손상되어 초기화했습니다. 손상된 파일은 백업해 두었습니다."
        case .unreadable:
            return "저장 파일을 읽지 못해 이번 실행에서는 저장하지 않습니다.\n파일을 지키기 위해 덮어쓰기를 막았습니다 — 재시작하면 다시 시도합니다."
        case .unsupportedVersion(let version):
            return "저장 파일이 더 새로운 형식(버전 \(version))입니다.\n원본을 지키기 위해 이번 실행에서는 저장하지 않습니다."
        case .writeFailed:
            return "저장하지 못했습니다. 이전 저장본과 저장 대기 이력은 그대로 두었고, 복원은 이전 저장본을 씁니다.\n다음 저장 때 다시 시도합니다."
        }
    }

    static let identityMismatchNotice = "화면 정보가 저장 당시와 달라 복원하지 않았습니다.\n지금 배치가 맞다면 저장을 다시 눌러 갱신하세요."

    // MARK: - 결과 — 저장 창별 사유 문구 (US-008: "왜 안 옮겨졌지?"의 유일한 답)

    static func describe(_ outcome: RestoreResult.Outcome) -> String {
        switch outcome {
        case .moved: return "이동"
        case .failed: return "이동 실패"
        case .skipped(.appNotRunning): return "꺼져 있어 건너뜀"
        case .skipped(.fullscreen): return "전체화면이라 건너뜀"
        case .skipped(.minimized): return "최소화되어 건너뜀"
        case .skipped(.alreadyInPlace): return "이미 제자리"
        case .skipped(.noWindow): return "창이 없어 건너뜀"
        case .skipped(.closedInWorkspace): return "이 환경에서 닫아 건너뜀"
        case .skipped(.userInteraction): return "직접 옮기는 중이라 건너뜀"
        case .awaitingVisit: return "Space 방문 대기"
        case .awaitingSpaceMove: return "Space 이동 필요"
        case .needsConfirmation(let reason): return "확인 필요 · \(describe(reason))"
        case .held(.screenLocked): return "잠금 해제 대기"
        case .held(.lockStateUndetermined): return "잠금 상태를 확인하지 못해 대기"
        case .cancelled(let reason): return "취소 · \(describe(reason))"
        }
    }

    static func describe(_ reason: ConfirmationReason) -> String {
        switch reason {
        case .ambiguousCandidates(let ids): return "같은 앱 창 \(ids.count)개 중 어느 창인지 확인"
        case .closureUnknown: return "저장된 창을 현재 확인할 수 없음 · 닫힌 시점을 알 수 없어 열지 않음"
        case .spaceMissing: return "저장한 Space를 현재 찾을 수 없음"
        case .spaceUnavailable: return "Space 상태를 확인할 수 없음"
        case .spacesUnsupported: return "개별 Spaces 설정이 꺼져 있거나 확인 불가"
        case .windowOnAnotherSpace: return "창이 다른 Space에 있음 · 옮긴 뒤 다시 시도"
        case .windowCreationFailed: return "앱 실행·창 열기를 요청했으나 창을 확인하지 못함"
        }
    }

    static func describe(_ reason: CancelReason) -> String {
        switch reason {
        case .userCancelled: return "사용자가 취소"
        case .newRequest: return "새 복원 요청"
        case .newSave: return "새 저장"
        case .workspaceChanged: return "작업 환경 변경"
        case .targetRemoved: return "대상 제외"
        case .automaticRestoreDisabled: return "자동 복원 OFF로 취소"
        case .spacesUnsupported: return "개별 Spaces 설정 변경"
        }
    }

    /// 결과 행의 기호 — 실패만 다르게 그린다. 대기·확인은 정보 기호다.
    static func symbolName(for outcome: RestoreResult.Outcome) -> String {
        switch outcome {
        case .moved, .skipped(.alreadyInPlace): return "checkmark.circle"
        case .skipped, .cancelled: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        case .awaitingVisit, .awaitingSpaceMove, .held: return "clock"
        case .needsConfirmation: return "questionmark.circle"
        }
    }

    /// 결과 요약 한 줄 — 모든 대상이 어느 칸엔가 남는다 (6장). 이동과 이미 제자리는 다른 칸이다.
    /// 이동·실패는 0이어도 적고, 나머지는 있을 때만 적는다.
    static func summary(_ results: [RestoreResult]) -> String {
        let tally = ResultTally(results)
        var parts = ["이동 \(tally.moved)"]
        if tally.inPlace > 0 { parts.append("이미 제자리 \(tally.inPlace)") }
        if tally.skipped > 0 { parts.append("건너뜀 \(tally.skipped)") }
        if tally.waiting > 0 { parts.append("대기 \(tally.waiting)") }
        if tally.confirmation > 0 { parts.append("확인 필요 \(tally.confirmation)") }
        parts.append("실패 \(tally.failed)")
        if tally.cancelled > 0 { parts.append("취소 \(tally.cancelled)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 화면 이름 — 모니터 이름 + 포트 위치, 구분이 안 되면 A/B (P20)

    static func portLocationName(_ location: PortLocation) -> String? {
        switch location {
        case .leftBack: return "왼쪽 위"
        case .leftFront: return "왼쪽 아래"
        case .rightBack: return "오른쪽 위"
        case .rightFront: return "오른쪽 아래"
        case .left: return "왼쪽"
        case .right: return "오른쪽"
        case .other: return nil
        }
    }

    static func screenName(_ label: ScreenLabel) -> String {
        let parts = [label.portLocation.flatMap { portLocationName($0) }, label.letter].compactMap { $0 }
        guard !parts.isEmpty else { return label.name }
        return "\(label.name) (\(parts.joined(separator: " · ")))"
    }

    /// 작업 환경 이름 — 화면 표시 이름의 조합(A + B). 카드 헤더와 설정 창이 같은 이름을 쓴다.
    static func workspaceName(_ screens: [ScreenLabel]) -> String {
        screens.map(screenName).joined(separator: " + ")
    }

    // MARK: - Space 그룹 — 번호는 화면 안의 일반 Space 현재 순서다

    static func spaceGroupTitle(for kind: PlugbackController.SpaceGroup.Kind) -> String {
        switch kind {
        case .regular(let number, _): return "Space \(number)"
        case .unresolved: return "Space 미지정"
        }
    }

    static func spaceGroupStatus(for kind: PlugbackController.SpaceGroup.Kind,
                                 guide: PlugbackController.SpaceGroup.Guide?) -> String? {
        guard case .regular(_, let state) = kind else { return "저장 시 Space 정보 없음 · 다시 저장하면 지정" }
        switch state {
        case .current: return "현재"
        case .inactive:
            if case .visit = guide { return "열면 복원" }
            return nil
        case .otherDisplay:
            if case .move = guide { return "이동 필요" }
            return "다른 화면"
        case .missing: return "현재 없음"
        case .unknown: return "현재 상태 확인 불가"
        }
    }

    static func spaceGuide(_ guide: PlugbackController.SpaceGroup.Guide) -> String {
        switch guide {
        case .move(let source, let destination):
            return "\(screenName(source)) → \(screenName(destination))\nMission Control에서 이 Space를 옮겨 주세요."
        case .visit(let destination):
            return "\(screenName(destination))에서 이 Space를 열면 창 위치를 자동 복원합니다."
        case .unavailable:
            return "현재 상태를 확실히 확인할 수 없어 창을 옮기지 않았습니다."
        }
    }

    /// 대기 항목 한 줄 — 화면 소속을 항상 포함한다 (P20).
    static func waitingLine(_ item: PlugbackController.WaitingItem) -> String {
        let place = item.spaceNumber.map { "\(screenName(item.screen)) · Space \($0)" } ?? screenName(item.screen)
        switch item.outcome {
        case .awaitingVisit: return "\(place) 방문 대기"
        case .awaitingSpaceMove: return "\(place) 이동 필요"
        case .held(.screenLocked): return "\(place) · 잠금 해제 대기"
        case .held(.lockStateUndetermined): return "\(place) · 잠금 상태를 확인하지 못해 복원 대기 중"
        case .needsConfirmation: return "\(place) · 창 확인 필요"
        default: return place
        }
    }

    /// 저장 위치의 짧은 설명 — 비율 좌표를 사람이 읽는 말로.
    static func placementDescription(_ rect: UnitRect) -> String {
        let horizontal = rect.x + rect.width / 2 < 0.34 ? "왼쪽" : (rect.x + rect.width / 2 > 0.66 ? "오른쪽" : "가운데")
        let vertical = rect.y + rect.height / 2 < 0.34 ? "위" : (rect.y + rect.height / 2 > 0.66 ? "아래" : "")
        let position = [horizontal, vertical].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(position) · \(Int((rect.width * 100).rounded()))%×\(Int((rect.height * 100).rounded()))%"
    }

    // MARK: - 헤더 — 작업 환경 이름과 화면 상태 (빈 상태에서도 카드는 비지 않는다)

    /// 화면이 여럿이어도 작업 환경 하나다 — 모든 화면 표시 이름을 조합으로 보인다.
    static func headerTitle(screens: [ScreenLabel]) -> String {
        screens.isEmpty ? "외장 화면 없음" : workspaceName(screens)
    }

    struct HeaderBadge: Equatable {
        let text: String
        let highlighted: Bool
    }

    /// 연결 여부만 말한다. 저장본 유무·복원 결과는 상태 구획이 말한다 — 「연결됨」은 「복원 완료」가 아니다.
    static func headerBadge(for presence: ScreenPresence) -> HeaderBadge? {
        switch presence {
        case .connected: return HeaderBadge(text: "연결됨", highlighted: true)
        case .remembered: return HeaderBadge(text: "연결 해제됨", highlighted: false)
        case .none: return nil
        }
    }

    // MARK: - 비침해를 눈에 보이게

    /// 앱 목록의 세 묶음 (F-05.3). 첫 묶음은 지금 화면에 있는 앱 — D4에 따라 저장했든 아직이든 다음 저장의 대상이다.
    /// 저장 기록만 있고 창이 없는 앱과 제외한 앱은 접힌 묶음으로 내려간다.
    static let presentHeader = "지금 화면에 있는 앱"
    static func absentHeader(_ count: Int) -> String { "화면에 없는 저장 앱 \(count)개" }
    static func excludedHeader(_ count: Int) -> String { "제외한 앱 \(count)개" }
    /// 화면에는 있지만 아직 저장하지 않은 앱 — 체크가 켜져 있어도 기록은 다음 저장 때 생긴다.
    static let unsavedBadge = "저장 전"
    static let notRunningLabel = "꺼짐"
    static let saveBlockedStatus = "저장 중지됨 · 저장 파일 확인 필요"
    static let settlingStatus = "화면 연결 확인 중"
    static let migrationNotice = "이전 버전의 화면별 기록을 화면 하나짜리 작업 환경으로 가져왔습니다.\n여러 화면 조합과 Space별 위치는 다시 저장해야 기록됩니다."
    /// 묶음·Space 목록은 보기만 바꾼다 — 복원 범위는 체크한 대상 앱 전체다.
    static let selectionScopeNote = "포함·제외는 이 작업 환경 전체에 적용돼요. 제외해도 창 위치 기록은 남아요."

    /// 상태 카드의 대상 앱 요약. 저장 전에는 다음 저장에 들어갈 지금 화면의 앱을 센다 (D4).
    static func targetSummary(hasSnapshot: Bool, appCount: Int, windowCount: Int, spaceCount: Int,
                              presentAppCount: Int) -> String {
        guard hasSnapshot else { return "저장 전 · 지금 화면에 있는 앱 \(presentAppCount)개" }
        return "앱 \(appCount)개 · 창 \(windowCount)개" + (spaceCount > 0 ? " · Space \(spaceCount)개" : "")
    }

    // MARK: - 삭제 — 제외(체크 끄기)와 다르게, 되돌릴 수 없으므로 한 번 묻는다

    static let removeRecordsAction = "저장 기록 삭제"
    static func removalTitle(_ name: String) -> String { "\(name)의 저장 기록을 삭제할까요?" }
    static func removalDetail(windowCount: Int) -> String {
        "이 작업 환경의 창 위치 기록 \(windowCount)개를 지웁니다. 되돌릴 수 없습니다.\n기록을 남기려면 체크만 끄세요."
    }
    static let placementRemovalTitle = "이 저장 자리를 삭제할까요?"
    static func placementRemovalMessage(name: String, place: String) -> String {
        "\(name) · \(place) 자리를 작업 환경 기록에서 지웁니다. 되돌릴 수 없습니다."
    }

    // MARK: - 복원 소스 — 어느 저장본이 쓰이는지 카드가 말한다 (D2)

    static func sourceLabel(savedBy: Slot, savedAt: Date?, now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        let name = savedBy == .auto ? "자동" : "수동"
        guard let savedAt else { return "복원 소스 · \(name)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(savedAt, inSameDayAs: now) ? "a h:mm" : "M월 d일 a h:mm"
        return "복원 소스 · \(name) · \(formatter.string(from: savedAt))"
    }

    /// 복원 소스는 작업 환경마다 한 줄이다 — 외장 화면이 몇 대든 같은 저장본이다 (D2).
    static func sourceLabel(for sections: [PlugbackController.ScreenSection], now: Date = Date(),
                            calendar: Calendar = .current) -> String? {
        guard let section = sections.first(where: { $0.savedBy != nil }), let savedBy = section.savedBy else { return nil }
        return sourceLabel(savedBy: savedBy, savedAt: section.savedAt, now: now, calendar: calendar)
    }

    /// 저장 대기 이력 — **복원은 아직 이 값을 쓰지 않는다.** 환경을 떠나거나 종료할 때 저장된다.
    static func pendingLabel(collectedAt: Date?, hasPending: Bool,
                             spaceConfigurationChanged: Bool = false,
                             now: Date = Date()) -> String {
        guard hasPending else {
            guard let collectedAt else { return "저장 대기 이력 · 아직 수집 안 함" }
            return "대기 중 변경 없음 · 확인 \(relative(collectedAt, now))"
        }
        if spaceConfigurationChanged {
            return "저장 대기 · Space 구성 변경 — 환경을 떠날 때 저장"
        }
        return "저장 대기 · \(relative(collectedAt, now)) 배치 — 환경을 떠날 때 저장"
    }

    static let manualSpaceConfigurationDifference =
        "현재 Space 구성이 저장본과 다름 · 저장하면 갱신"
    static let autoSaveOffLabel = "자동 저장 꺼짐 · 직접 저장할 때만 복원 소스가 바뀝니다"

    /// 복원 소스 아래 줄 — 저장 대기 이력·저장 중지·자동 저장 꺼짐 중 하나. 저장본 줄과 다른 모양으로 그린다.
    static func pendingStatus(autoSave: Bool, isSaveBlocked: Bool, isConnected: Bool,
                              collectedAt: Date?, hasPending: Bool, spaceConfigurationDiffers: Bool,
                              now: Date = Date()) -> CardNote? {
        if isSaveBlocked { return CardNote(text: saveBlockedStatus, isWarning: true) }
        if autoSave {
            guard isConnected else { return nil }
            return CardNote(text: pendingLabel(collectedAt: collectedAt, hasPending: hasPending,
                                               spaceConfigurationChanged: spaceConfigurationDiffers, now: now),
                            isWarning: false)
        }
        return CardNote(text: spaceConfigurationDiffers ? manualSpaceConfigurationDifference : autoSaveOffLabel,
                        isWarning: false)
    }

    static func relative(_ date: Date?, _ now: Date = Date()) -> String {
        guard let date else { return "확인 안 됨" }
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<10:   return "방금"
        case ..<60:   return "\(seconds)초 전"
        case ..<3600: return "\(seconds / 60)분 전"
        default:      return "\(seconds / 3600)시간 전"
        }
    }

    // MARK: - 단축어 다이얼로그 (F-05.5) — restoreNow 반환값이 곧 문구 분기

    static func intentDialog(for outcome: RestoreOutcome) -> String {
        switch outcome {
        case .notAuthorized:
            return "손쉬운 사용 권한이 필요합니다. 메뉴바에서 Plugback을 여세요."
        case .notConnected:
            return "외장 화면이 연결되어 있지 않습니다."
        case .alreadyRestoring:
            return "이미 복원 중입니다."
        case .spacesUnsupported:
            return "「각각의 Spaces가 있는 디스플레이」 설정을 켜야 복원할 수 있습니다."
        case .restored(let results):
            guard !results.isEmpty else { return "아직 확인된 복원 결과가 없습니다. 메뉴바에서 저장본과 진행 상태를 확인하세요." }
            return summary(results)
        }
    }

    /// 종료 전 저장 실패 안내 (4.4절).
    static let terminationSaveFailedTitle = "저장 대기 중인 배치를 저장하지 못했습니다"
    static let terminationSaveFailedMessage = "마지막 저장본과 저장 대기 이력은 그대로 두었습니다. 다시 시도하거나 저장하지 않고 종료할 수 있습니다."
}

/// 한 줄 안내와 그 성격 — 경고면 기호와 함께 그린다.
struct CardNote: Equatable {
    let text: String
    let isWarning: Bool
}

/// 결과 칸별 수 — 이동과 이미 제자리를 나눈다. 항목은 정확히 한 칸에 들어간다.
struct ResultTally: Equatable {
    var moved = 0, inPlace = 0, skipped = 0, waiting = 0, confirmation = 0, failed = 0, cancelled = 0
    var total: Int { moved + inPlace + skipped + waiting + confirmation + failed + cancelled }
}

extension ResultTally {
    init(_ results: [RestoreResult]) {
        self.init()
        for entry in results.flatMap(\.entries) {
            switch entry.outcome {
            case .moved: moved += 1
            case .skipped(.alreadyInPlace): inPlace += 1
            case .skipped: skipped += 1
            case .awaitingVisit, .awaitingSpaceMove, .held: waiting += 1
            case .needsConfirmation: confirmation += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            }
        }
    }
}

// MARK: - 카드 상태 — 첫 구획이 답하는 하나의 상태와 다음 행동

/// 카드가 읽는 사실 — 컨트롤러의 공개 상태를 옮긴 값이다. 판정은 코어가 이미 끝냈고, 여기서는 보일 순서만 정한다.
struct CardFacts: Equatable {
    var presence: ScreenPresence
    var hasSnapshot = false
    var isRestoring = false
    var isSettling = false
    var isSaveBlocked = false
    var autoSave = true
    var restoreMode: RestoreMode = .automatic
    /// 현재 요청에서 판정이 끝나지 않은 저장 창(`waitingItems`) — 확인 필요 포함.
    var openItems: [PlugbackController.WaitingItem] = []
    var results: [RestoreResult] = []

    var isConnected: Bool {
        if case .connected = presence { return true } else { return false }
    }

    /// 저장본이 없는 작업 환경에 남은 결과는 이 환경의 결과가 아니다 — 보이지 않는다.
    var visibleResults: [RestoreResult] { hasSnapshot ? results : [] }
}

/// 카드 상태 — 위에서부터 우선한다. 사용자가 할 일이 있는 남은 항목이 결과·준비보다 먼저다.
enum CardStatus: Equatable {
    case restoring
    case awaitingSpaceMove
    case needsConfirmation(count: Int)
    case held(HoldReason)
    case awaitingVisit(count: Int)
    case settling
    case disconnected(hasSnapshot: Bool)
    case noScreen
    case firstSave
    case finished(ResultTally)
    case ready
}

struct CardStatusText: Equatable {
    enum Tone: Equatable { case neutral, attention, done, failure }
    let title: String
    let detail: String?
    /// nil이면 기호 대신 진행 표시를 그린다. 시간을 모르므로 퍼센트·남은 시간은 없다.
    let symbol: String?
    let tone: Tone
}

/// 카드 동작 — 뷰는 이 ID를 기존 컨트롤러 명령에 그대로 잇는다. 실행 직전 안전 검사는 코어가 다시 한다.
enum CardAction: Equatable {
    case save, restore, resumeRemaining, cancelRemaining, openConfirmation
}

struct CardButton: Equatable, Identifiable {
    let action: CardAction
    let title: String
    let isEnabled: Bool
    var id: CardAction { action }
    var accessibilityLabel: String { action == .save ? "지금 레이아웃 저장" : title }
    var symbol: String? { action == .restore ? "arrow.counterclockwise" : nil }
}

/// 남은 항목 한 줄 — 같은 화면·Space·상태의 저장 창은 한 줄로 묶는다.
struct RequestLine: Equatable, Identifiable {
    let text: String
    let symbol: String
    var id: String { text }
}

extension CardPresentation {
    static func status(_ facts: CardFacts) -> CardStatus {
        if facts.isRestoring { return .restoring }
        let outcomes = facts.openItems.map(\.outcome)
        if outcomes.contains(where: { if case .awaitingSpaceMove = $0 { return true } else { return false } }) {
            return .awaitingSpaceMove
        }
        let confirmations = outcomes.filter { if case .needsConfirmation = $0 { return true } else { return false } }.count
        if confirmations > 0 { return .needsConfirmation(count: confirmations) }
        let holds = outcomes.compactMap { outcome -> HoldReason? in
            if case .held(let reason) = outcome { return reason } else { return nil }
        }
        // 판정 불가가 섞여 있으면 사용자가 재개해야 하므로 그쪽을 보인다 (D8)
        if !holds.isEmpty { return .held(holds.contains(.lockStateUndetermined) ? .lockStateUndetermined : .screenLocked) }
        let visits = outcomes.filter { $0 == .awaitingVisit }.count
        if visits > 0 { return .awaitingVisit(count: visits) }
        if facts.isSettling { return .settling }
        switch facts.presence {
        case .none: return .noScreen
        case .remembered: return .disconnected(hasSnapshot: facts.hasSnapshot)
        case .connected: break
        }
        guard facts.hasSnapshot else { return .firstSave }
        let tally = ResultTally(facts.results)
        return tally.total > 0 ? .finished(tally) : .ready
    }

    static func statusText(_ status: CardStatus, facts: CardFacts) -> CardStatusText {
        switch status {
        case .restoring:
            return CardStatusText(title: "저장한 자리로 창을 옮기는 중이에요", detail: nil, symbol: nil, tone: .neutral)
        case .awaitingSpaceMove:
            return CardStatusText(title: "Space를 옮겨 주세요",
                                  detail: "저장한 Space가 다른 화면에 있어요. Mission Control에서 옮기면 이어서 복원해요.",
                                  symbol: "arrow.left.arrow.right", tone: .attention)
        case .needsConfirmation(let count):
            return CardStatusText(title: "창 \(count)개를 확인해 주세요",
                                  detail: "확인 창에서 사유를 보고 「남은 창 복원」을 눌러야 이어서 복원해요.",
                                  symbol: "questionmark.circle", tone: .attention)
        case .held(.screenLocked):
            return CardStatusText(title: "잠금 해제를 기다려요",
                                  detail: "아직 보내지 않은 이동을 멈췄어요. 잠금 해제가 확인되면 남은 창만 이어서 복원해요.",
                                  symbol: "lock", tone: .neutral)
        case .held(.lockStateUndetermined):
            return CardStatusText(title: "잠금 상태를 확인하지 못했어요",
                                  detail: "아직 보내지 않은 이동을 멈췄어요. 잠금이 풀려 있으면 「남은 창 복원」을 눌러 주세요.",
                                  symbol: "lock", tone: .attention)
        case .awaitingVisit(let count):
            return CardStatusText(title: "창 \(count)개가 Space 방문을 기다려요",
                                  detail: "아래 Space를 열면 그 Space의 창을 이어서 복원해요.",
                                  symbol: "clock", tone: .neutral)
        case .settling:
            return CardStatusText(title: "화면 연결을 확인하고 있어요",
                                  detail: "외장 화면 조합이 안정되면 그 작업 환경의 저장본을 써요.",
                                  symbol: "display.and.arrow.down", tone: .neutral)
        case .disconnected(let hasSnapshot):
            let detail = !hasSnapshot ? "이 화면 조합에는 저장본이 없어요."
                : facts.restoreMode == .automatic ? "저장본은 그대로 있어요. 같은 화면 조합을 다시 연결하면 자동으로 복원해요."
                : "저장본은 그대로 있어요. 다시 연결한 뒤 「지금 복원」을 누르세요."
            return CardStatusText(title: "외장 화면 연결이 해제됐어요", detail: detail, symbol: "display", tone: .neutral)
        case .noScreen:
            return CardStatusText(title: "외장 화면을 연결해 주세요",
                                  detail: "외장 화면 조합마다 창 배치를 따로 저장해요.",
                                  symbol: "display", tone: .neutral)
        case .firstSave:
            let detail = facts.autoSave && !facts.isSaveBlocked
                ? "이 화면 조합에는 아직 저장본이 없어요. 지금 저장하거나, 이 조합을 떠날 때 자동으로 저장돼요."
                : "이 화면 조합에는 아직 저장본이 없어요. 창을 배치한 뒤 저장해 주세요."
            return CardStatusText(title: "지금 배치를 저장해 두세요", detail: detail,
                                  symbol: "square.and.arrow.down", tone: .neutral)
        case .finished(let tally):
            let reasons = "창별 사유는 아래 「마지막 복원」에서 볼 수 있어요."
            if tally.failed > 0 {
                return CardStatusText(title: "창 \(tally.failed)개를 옮기지 못했어요", detail: reasons,
                                      symbol: "exclamationmark.circle.fill", tone: .failure)
            }
            if tally.inPlace == tally.total {
                return CardStatusText(title: "모든 창이 이미 제자리예요", detail: nil, symbol: "checkmark.circle.fill", tone: .done)
            }
            if tally.moved + tally.inPlace == tally.total {
                return CardStatusText(title: "저장한 자리로 모두 복원했어요", detail: nil, symbol: "checkmark.circle.fill", tone: .done)
            }
            return CardStatusText(title: "복원 요청을 마쳤어요", detail: reasons, symbol: "checkmark.circle", tone: .neutral)
        case .ready:
            return CardStatusText(title: "복원할 준비가 됐어요", detail: nil, symbol: "arrow.counterclockwise", tone: .neutral)
        }
    }

    /// 첫 버튼이 강조 동작이다. 남은 항목이 있으면 재개·취소만 둔다 — 새 저장·새 요청은 남은 작업을 취소하므로 먼저 취소하게 한다.
    static func buttons(for status: CardStatus, facts: CardFacts) -> [CardButton] {
        let canRun = facts.isConnected && !facts.isRestoring && !facts.isSettling
        let cancel = CardButton(action: .cancelRemaining, title: "남은 복원 취소", isEnabled: !facts.isRestoring)
        switch status {
        case .needsConfirmation:
            return [CardButton(action: .openConfirmation, title: "창 확인하기", isEnabled: true), cancel]
        case .awaitingSpaceMove, .held, .awaitingVisit:
            return [CardButton(action: .resumeRemaining, title: "남은 창 복원", isEnabled: canRun), cancel]
        default:
            let restore = CardButton(action: .restore, title: facts.isRestoring ? "복원 중…" : "지금 복원",
                                     isEnabled: canRun && facts.hasSnapshot)
            let save = CardButton(action: .save, title: facts.hasSnapshot ? "저장" : "지금 레이아웃 저장",
                                  isEnabled: canRun && !facts.isSaveBlocked)
            return facts.hasSnapshot ? [restore, save] : [save, restore]
        }
    }

    /// 남은 작업을 끝내고 새 배치를 선언하는 명령도 접근 가능해야 한다.
    static func additionalButtons(_ facts: CardFacts) -> [CardButton] {
        guard !facts.openItems.isEmpty else { return [] }
        let canRun = facts.isConnected && !facts.isRestoring && !facts.isSettling
        return [CardButton(action: .save, title: "지금 레이아웃 저장", isEnabled: canRun && !facts.isSaveBlocked),
                CardButton(action: .restore, title: "새로 복원", isEnabled: canRun && facts.hasSnapshot)]
    }

    static func saveFailureNotice(_ workspace: PlugbackController.WorkspaceSummary) -> String {
        let source = workspace.savedBy.map { sourceLabel(savedBy: $0, savedAt: workspace.savedAt) }
        let preserved = source.map { "복원은 이전 저장 완료본(\($0))을 사용합니다." }
            ?? "저장 완료본이 아직 없습니다. 저장 대기 이력은 유지합니다."
        return "\(workspaceName(workspace.screens)) 저장 실패. \(preserved)"
    }

    /// 남은 항목 줄 — 사용자가 할 일이 먼저다(이동 > 잠금 > 방문). 확인 필요는 「복원 확인」 진입점이 맡는다.
    static func requestLines(_ items: [PlugbackController.WaitingItem]) -> [RequestLine] {
        var groups: [(rank: Int, symbol: String, text: String, count: Int)] = []
        for item in items {
            let kind: (rank: Int, symbol: String)
            switch item.outcome {
            case .awaitingSpaceMove: kind = (0, "arrow.left.arrow.right")
            case .held: kind = (1, "lock")
            case .awaitingVisit: kind = (2, "clock")
            default: continue
            }
            let text = waitingLine(item)
            if let index = groups.firstIndex(where: { $0.text == text }) {
                groups[index].count += 1
            } else {
                groups.append((kind.rank, kind.symbol, text, 1))
            }
        }
        return groups.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { RequestLine(text: $0.element.count > 1 ? "\($0.element.text) · 창 \($0.element.count)개" : $0.element.text,
                               symbol: $0.element.symbol) }
    }

    /// 남은 항목의 Space 안내 — 출발·목적 화면 이동과 확인 불가. 방문 대기는 대기 줄이 이미 말한다.
    static func requestGuides(in sections: [PlugbackController.ScreenSection]) -> [String] {
        var out: [String] = []
        for guide in sections.flatMap(\.spaceGroups).compactMap(\.guide) {
            if case .visit = guide { continue }
            let text = spaceGuide(guide)
            if !out.contains(text) { out.append(text) }
        }
        return out
    }
}

/// 같은 Space ID라도 화면이 다르면 별개다. 제외 앱은 실제 Space로 취급하지 않는다.
struct CardSpaceSelection: Hashable {
    enum Category: Hashable { case all, group(String), excluded }
    let screenID: String
    let category: Category
}

extension CardPresentation {
    static func spaceSelections(in sections: [PlugbackController.ScreenSection]) -> [CardSpaceSelection] {
        sections.flatMap { section in
            let groups: [CardSpaceSelection.Category] = section.spaceGroups.isEmpty
                ? [.all] : section.spaceGroups.map { .group($0.id) }
            return (groups + (section.excludedApps.isEmpty ? [] : [.excluded])).map {
                CardSpaceSelection(screenID: section.screenID, category: $0)
            }
        }
    }

    static func resolvedSpaceSelection(_ selection: CardSpaceSelection?,
                                       in sections: [PlugbackController.ScreenSection]) -> CardSpaceSelection? {
        let items = spaceSelections(in: sections)
        if let selection, items.contains(selection) { return selection }
        return items.first
    }
}
