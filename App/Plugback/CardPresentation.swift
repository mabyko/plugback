import Foundation
import PlugbackKit

/// 카드·Intent의 표현 매핑 — 뷰에서 분리한 순수 함수들. PlugbackTests가 여기에 닿는다.
/// 문구는 앱의 것이다 — 헤드리스 코어(PlugbackKit)에 UI 문자열을 넣지 않는다 (docs/ARCHITECTURE.md §2 MenuBarUI).
enum CardPresentation {
    // MARK: - 결과 스트립 — 건너뜀·실패 사유 문구 (US-008: "왜 안 옮겨졌지?"의 유일한 답)

    static func describe(_ outcome: RestoreResult.Outcome) -> String {
        switch outcome {
        case .moved: return "이동"
        case .failed: return "이동 실패"
        case .skipped(.appNotRunning): return "꺼져 있어 건너뜀"
        case .skipped(.fullscreen): return "전체화면이라 건너뜀"
        case .skipped(.minimized): return "최소화되어 건너뜀"
        case .skipped(.alreadyInPlace): return "이미 제자리"
        case .skipped(.noWindow): return "창이 없어 건너뜀"
        }
    }

    // MARK: - 대상 앱 점 — 복원 예측의 표현 (US-006 AC-1)

    enum DotStyle: Equatable {
        case filled  // 복원하면 옮겨지거나 이미 제자리
        case hollow  // 실행 중이지만 건너뜀 예정
        case off     // 꺼짐
    }

    static func dotStyle(for prediction: RestorePrediction) -> DotStyle {
        switch prediction {
        case .willMove, .alreadyInPlace: return .filled
        case .willSkip(.appNotRunning): return .off
        case .willSkip: return .hollow
        }
    }

    static func dotLabel(for prediction: RestorePrediction) -> String {
        switch prediction {
        case .willMove: return "복원 대상"
        case .alreadyInPlace: return "제자리"
        case .willSkip(.appNotRunning): return "꺼짐"
        case .willSkip(.noWindow): return "창 없음"
        case .willSkip(.fullscreen): return "전체화면"
        case .willSkip(.minimized): return "최소화"
        case .willSkip(.alreadyInPlace): return "제자리" // 예측은 .alreadyInPlace 케이스로 오지만 방어
        }
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
        let highlighted: Bool // 주황 강조 — 프로필 있음일 때만
    }

    static func headerBadge(for presence: ScreenPresence, hasProfile: Bool) -> HeaderBadge? {
        switch presence {
        case .connected:
            return hasProfile ? HeaderBadge(text: "프로필 있음", highlighted: true)
                              : HeaderBadge(text: "프로필 없음", highlighted: false)
        case .remembered:
            return HeaderBadge(text: "연결 해제됨", highlighted: false)
        case .none:
            return nil
        }
    }

    // MARK: - 비침해를 눈에 보이게

    /// 프로필에 없는 앱들의 묶음 머리말. **행마다 붙이는 라벨이 아니라 문장 하나다** —
    /// 「대상 아님」 같은 두 글자 칩은 "왜 이 앱은 안 움직이나"를 설명하지 못한다.
    ///
    /// 「건너뜀」은 쓸 수 없다 — 건너뜀은 복원 대상인데 안 옮기는 것이고(CONTEXT 정의어),
    /// 이 앱은 애초에 대상이 아니다. 「그대로 둠」은 「제자리」와 겹치고,
    /// 「미등록」은 대상 앱의 금지어(등록 앱)에 스친다.
    static let untrackedHeader = "복원이 건드리지 않는 앱"

    // MARK: - 복원 소스 (실험실 · 자동 슬롯) — 어느 슬롯이 이겼는지 카드가 말한다

    /// 자동으로 뭔가 저장되는데 사용자가 그 사실을 볼 수 없으면, 조용한 게 아니라 불투명한 것이다.
    /// 시각까지 붙여야 "어제 수동" vs "오늘 자동"을 보고 고를 수 있다.
    static func sourceLabel(slot: Slot, savedAt: Date?, now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        let name = slot == .auto ? "자동" : "수동"
        guard let savedAt else { return "복원 소스 · \(name)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = calendar.isDate(savedAt, inSameDayAs: now) ? "a h:mm" : "M월 d일 a h:mm"
        return "복원 소스 · \(name) · \(formatter.string(from: savedAt))"
    }

    /// 확정을 기다리는 배치 — **복원은 아직 이 값을 쓰지 않는다.**
    /// 위의 복원 소스 줄과 짝이다: 하나는 "지금 복원되는 값", 하나는 "뽑을 때 저장될 값".
    /// 한 줄로 뭉치면 "수집됨"이 "저장됨"으로 읽혀, 방금 옮겼는데 복원이 왜 다른 자리로
    /// 가는지 설명할 길이 없어진다.
    static func pendingLabel(collectedAt: Date?, hasPending: Bool, now: Date = Date()) -> String {
        guard hasPending else { return "대기 중 변경 없음" }
        return "대기 중 · \(relative(collectedAt, now)) 배치 — 뽑을 때 저장"
    }

    private static func relative(_ date: Date?, _ now: Date) -> String {
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
        case .restored(let results):
            guard !results.isEmpty else { return "복원할 프로필이 없습니다." }
            let moved = results.map(\.movedCount).reduce(0, +)
            let skipped = results.map(\.skippedCount).reduce(0, +)
            let failed = results.map(\.failedCount).reduce(0, +)
            return "이동 \(moved) · 건너뜀 \(skipped) · 실패 \(failed)"
        }
    }
}
