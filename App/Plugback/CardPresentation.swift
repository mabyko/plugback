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

    /// 화면 섹션 제목 — 같은 이름의 화면이 여럿이면 (1) (2)를 붙인다 (식별자 정렬 순서 = 입력 순서).
    /// 이름이 유일하면 그대로 둔다 — 화면 한 대에 (1)을 붙이면 없는 두 번째를 암시한다.
    static func sectionTitles(names: [String]) -> [String] {
        var total: [String: Int] = [:]
        for name in names { total[name, default: 0] += 1 }
        var ordinal: [String: Int] = [:]
        return names.map { name in
            guard total[name, default: 0] > 1 else { return name }
            ordinal[name, default: 0] += 1
            return "\(name) (\(ordinal[name]!))"
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
    /// 톤을 정확성보다 앞에 둔 선택이다. 「저장되지 않은 앱」이 더 정확하지만 "네가 안 했다"로
    /// 읽히고, 「감지」는 앱이 주어라 그 톤이 없다. **다만 「새로」는 반복해서 볼 때 거짓이다** —
    /// 등록하지 않은 앱은 카드를 열 때마다 같은 자리에 뜨고, 그때마다 "새로"라고 말하게 된다.
    /// 첫 대면을 기준으로 한 문구이며, 그 대가를 알고 고른 것이다 (2026-08-19).
    ///
    /// 쓸 수 없는 말들: 「건너뜀」은 복원 대상인데 안 옮기는 것이고(CONTEXT 정의어) 이 앱은
    /// 애초에 대상이 아니다. 「그대로 둠」은 「제자리」와 겹친다. 「미등록」은 대상 앱의
    /// 금지어(등록 앱)에 스친다.
    static let untrackedHeader = "저장하지 않는 앱"

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
        guard hasPending else {
            // 변경이 없을 때도 **마지막으로 확인한 시각**은 보여준다.
            // 없으면 수집이 도는지 알 길이 없다 — 창을 안 옮긴 상태에서는 화면이 계속 같아서,
            // 트리거가 죽은 것과 "바뀐 게 없다"가 구별되지 않는다.
            // 「확인」이라고 쓴다: 「저장」으로 읽히면 안 된다.
            guard let collectedAt else { return "대기 중 변경 없음 · 아직 확인 안 함" }
            return "대기 중 변경 없음 · 확인 \(relative(collectedAt, now))"
        }
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
