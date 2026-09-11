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

    /// 결과 요약 한 줄 — 모든 대상이 결과에 남는다 (6장): 이동·건너뜀·대기·확인 필요·실패·취소.
    static func summary(_ results: [RestoreResult]) -> String {
        let moved = results.reduce(0) { $0 + $1.movedCount }
        let skipped = results.reduce(0) { $0 + $1.skippedCount }
        let waiting = results.reduce(0) { $0 + $1.waitingCount }
        let confirmation = results.reduce(0) { $0 + $1.confirmationCount }
        let failed = results.reduce(0) { $0 + $1.failedCount }
        let cancelled = results.reduce(0) { $0 + $1.cancelledCount }
        var parts = ["이동 \(moved)", "건너뜀 \(skipped)"]
        if waiting > 0 { parts.append("대기 \(waiting)") }
        if confirmation > 0 { parts.append("확인 필요 \(confirmation)") }
        parts.append("실패 \(failed)")
        if cancelled > 0 { parts.append("취소 \(cancelled)") }
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
        let parts = [label.portLocation.flatMap(portLocationName), label.letter].compactMap { $0 }
        guard !parts.isEmpty else { return label.name }
        return "\(label.name) (\(parts.joined(separator: " · ")))"
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

    // MARK: - 헤더 — 화면 상태 3상태 (빈 상태에서도 카드는 비지 않는다)

    static func headerTitle(for presence: ScreenPresence) -> String {
        switch presence {
        case .connected(let screen, let count):
            return count > 1 ? "\(screen.name) 외 \(count - 1)대" : screen.name
        case .remembered(_, let name):
            return name
        case .none:
            return "외장 화면 없음"
        }
    }

    struct HeaderBadge: Equatable {
        let text: String
        let highlighted: Bool
    }

    static func headerBadge(for presence: ScreenPresence, hasProfile: Bool) -> HeaderBadge? {
        switch presence {
        case .connected:
            return hasProfile ? HeaderBadge(text: "저장본 있음", highlighted: true)
                              : HeaderBadge(text: "저장본 없음", highlighted: false)
        case .remembered:
            return HeaderBadge(text: "연결 해제됨", highlighted: false)
        case .none:
            return nil
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

    // MARK: - 복원 소스 — 어느 저장본이 쓰이는지 카드가 말한다 (D2)

    static func sourceLabel(savedBy: Slot, savedAt: Date?, now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        let name = savedBy == .auto ? "자동" : "수동"
        guard let savedAt else { return "복원 소스 · \(name)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = calendar.isDate(savedAt, inSameDayAs: now) ? "a h:mm" : "M월 d일 a h:mm"
        return "복원 소스 · \(name) · \(formatter.string(from: savedAt))"
    }

    /// 저장 대기 이력 — **복원은 아직 이 값을 쓰지 않는다.** 환경을 떠나거나 종료할 때 저장된다.
    static func pendingLabel(collectedAt: Date?, hasPending: Bool,
                             spaceConfigurationChanged: Bool = false,
                             now: Date = Date()) -> String {
        guard hasPending else {
            guard let collectedAt else { return "대기 중 변경 없음 · 아직 확인 안 함" }
            return "대기 중 변경 없음 · 확인 \(relative(collectedAt, now))"
        }
        if spaceConfigurationChanged {
            return "저장 대기 · Space 구성 변경 — 환경을 떠날 때 저장"
        }
        return "저장 대기 · \(relative(collectedAt, now)) 배치 — 환경을 떠날 때 저장"
    }

    static let manualSpaceConfigurationDifference =
        "현재 Space 구성이 저장본과 다름 · 저장하면 갱신"

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
            guard !results.isEmpty else { return "이 작업 환경의 저장본이 없습니다." }
            return summary(results)
        }
    }

    /// 종료 전 저장 실패 안내 (4.4절).
    static let terminationSaveFailedTitle = "저장 대기 중인 배치를 저장하지 못했습니다"
    static let terminationSaveFailedMessage = "마지막 저장본과 저장 대기 이력은 그대로 두었습니다. 다시 시도하거나 저장하지 않고 종료할 수 있습니다."
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
