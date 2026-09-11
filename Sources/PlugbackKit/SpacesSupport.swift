import CoreFoundation
import CoreGraphics
import Foundation

/// 「각각의 Spaces가 있는 디스플레이」 지원 조건 (D6). 첫 구현은 ON 구성만 지원한다.
/// OFF·판정 불가에서는 새 Space 저장·복원을 보류하고 기록·안내를 유지한다. 위치 전용 복원으로 조용히 전환하지 않는다.
public enum SpacesSupport: Equatable, Sendable {
    case separateSpaces
    case sharedSpaces
    case undetermined

    /// 설정 값은 `com.apple.spaces`의 `spans-displays`다 — 없으면 macOS 기본값(개별 Spaces ON)이다.
    /// 값이 예상한 형식이 아니면 판정 불가로 둔다. 실제 설정 전환·재로그인 뒤의 값은 실기기 검증 항목이다.
    public static func fromPreferences() -> SpacesSupport {
        guard let value = CFPreferencesCopyAppValue("spans-displays" as CFString,
                                                    "com.apple.spaces" as CFString) else {
            return .separateSpaces
        }
        if let number = value as? NSNumber { return number.boolValue ? .sharedSpaces : .separateSpaces }
        return .undetermined
    }

    /// 설정과 관찰을 교차 확인한다 — 개별 Spaces가 켜져 있으면 연결된 화면마다 managed display가 하나씩 있다.
    /// 화면이 둘 이상인데 snapshot의 display가 더 적으면 공유 구성으로 본다.
    public static func combine(preference: SpacesSupport, snapshot: SpaceSnapshot?,
                               connectedScreenCount: Int) -> SpacesSupport {
        if preference == .sharedSpaces { return .sharedSpaces }
        if let snapshot, connectedScreenCount > 1, snapshot.displays.count < connectedScreenCount {
            return .sharedSpaces
        }
        return preference
    }
}

/// 화면 잠금 판정 (D8). 비공식 세션 키를 읽는다 — docs/UNDOCUMENTED_APIS.md.
/// 세션 조회 실패는 판정 불가로 구별하고, 정상 조회에서 키가 없으면 잠기지 않은 것으로 본다
/// (2026-09-11 잠금 해제 상태의 조회 두 번에서 키가 없었다. 실제 잠금 중의 값은 실기기 검증 항목이다).
public enum LockState: Equatable, Sendable {
    case unlocked
    case locked
    case undetermined
}

public enum ScreenLock {
    public nonisolated static func current() -> LockState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .undetermined }
        guard let value = session["CGSSessionScreenIsLocked"] else { return .unlocked }
        if let flag = value as? Bool { return flag ? .locked : .unlocked }
        return .undetermined
    }
}
