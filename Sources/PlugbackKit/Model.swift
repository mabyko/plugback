import CoreGraphics
import Foundation

// 용어는 CONTEXT.md를 따른다. 모든 프레임은 통일 좌표계(좌상단 원점, 전역)다 —
// 각 어댑터가 자기 API의 좌표계를 여기로 통일한다 — NSScreen 뒤집기는 ScreenProvider, AX는 무변환 (부록 2: 두 좌표계의 존재).

/// 비율 좌표 — 소속 화면 크기에 대한 비율 (F-03.4). 픽셀 절대 좌표는 저장하지 않는다.
public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// 화면이 음수 좌표 영역에 있어도 원점 차로 계산하므로 올바르다 (F-03.4).
    public init(_ frame: CGRect, in screen: CGRect) {
        x = (frame.minX - screen.minX) / screen.width
        y = (frame.minY - screen.minY) / screen.height
        width = frame.width / screen.width
        height = frame.height / screen.height
    }

    public func frame(in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + x * screen.width,
               y: screen.minY + y * screen.height,
               width: width * screen.width,
               height: height * screen.height)
    }
}

/// 화면 지문 — 키가 아니라 검증용이다 (ARCHITECTURE ScreenID).
/// UUID는 같은데 지문이 다르면 "OS가 UUID 배정을 바꿨다"는 신호이므로 복원하지 않는다.
public struct ScreenFingerprint: Codable, Equatable, Sendable {
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor; self.model = model; self.serial = serial
    }
}

/// 화면 하나. id는 화면 식별자(WindowServer UUID) — 포트 변경 안정성은 실측 통과(2026-08-16), 동일 모델 2대·재부팅은 미측정 (ARCHITECTURE 스파이크).
public struct ScreenInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let frame: CGRect
    public let isBuiltin: Bool
    public let fingerprint: ScreenFingerprint?

    public init(id: String, name: String, frame: CGRect, isBuiltin: Bool,
                fingerprint: ScreenFingerprint? = nil) {
        self.id = id; self.name = name; self.frame = frame; self.isBuiltin = isBuiltin
        self.fingerprint = fingerprint
    }

    /// 창의 소속 화면 판정 — 중심점 규칙 (F-03.2). 저장과 복원이 이 하나의 규칙을 공유한다.
    public func contains(_ window: WindowInfo) -> Bool { frame.contains(window.center) }
}

/// 카드 헤더의 화면 상태 — 상태는 이 셋뿐이다 (ARCHITECTURE 고정 결정: 빈 상태에서도 카드는 비지 않는다).
/// 기억 상태는 식별자와 이름만 든다 — frame을 지어낸 가짜 ScreenInfo를 만들지 않기 위해서다.
public enum ScreenPresence: Equatable, Sendable {
    /// 외장 화면이 지금 연결되어 있다. count는 연결된 외장 화면 수 (다중 화면 표시용).
    case connected(ScreenInfo, count: Int)
    /// 외장 화면이 없는 동안 아는 화면 하나(방금 분리된 화면, 재시작 직후엔 이름순 첫 프로필)의 이름과 프로필 유무를 보여준다.
    case remembered(screenID: String, name: String)
    /// 아는 화면이 없다 — 첫 실행.
    case none
}

/// 표준 창 하나. id는 게이트웨이 세션 한정이다 — 앱 재시작을 넘는 창 식별자는 없다 (FUNCTIONAL_SPEC 부록 3).
public struct WindowInfo: Equatable, Sendable {
    public let id: Int
    public let appBundleID: String
    public let appName: String
    public let frame: CGRect
    public let isFullscreen: Bool
    public let isMinimized: Bool

    public init(id: Int, appBundleID: String, appName: String, frame: CGRect,
                isFullscreen: Bool = false, isMinimized: Bool = false) {
        self.id = id; self.appBundleID = appBundleID; self.appName = appName
        self.frame = frame; self.isFullscreen = isFullscreen; self.isMinimized = isMinimized
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// 대상 앱 항목 (F-04.1). 비율 좌표는 앱당 하나 — 복원은 첫 표준 창에 한다 (US-005 AC-3).
public struct TargetApp: Codable, Equatable, Sendable {
    public let bundleID: String
    public var displayName: String
    public var isEnabled: Bool
    public var unitRect: UnitRect

    public init(bundleID: String, displayName: String, isEnabled: Bool = true, unitRect: UnitRect) {
        self.bundleID = bundleID; self.displayName = displayName
        self.isEnabled = isEnabled; self.unitRect = unitRect
    }
}

/// 프로필 — 화면 식별자 하나당 하나 (F-04.1).
public struct Profile: Codable, Equatable, Sendable {
    public let screenID: String
    public var screenName: String
    public var apps: [TargetApp]
    /// 저장 당시 화면 지문. 복원 직전 검증에 쓴다 — 없으면(구버전 파일) 검증을 건너뛴다.
    public var fingerprint: ScreenFingerprint?
    /// 이 슬롯이 마지막으로 저장된 시각. 복원 소스 판정("더 최근 것이 이긴다")의 유일한 근거다.
    /// 구버전 파일은 nil — 아주 오래된 것으로 취급한다.
    public var savedAt: Date?

    public init(screenID: String, screenName: String, apps: [TargetApp] = [],
                fingerprint: ScreenFingerprint? = nil, savedAt: Date? = nil) {
        self.screenID = screenID; self.screenName = screenName; self.apps = apps
        self.fingerprint = fingerprint; self.savedAt = savedAt
    }
}

/// 프로필 슬롯 (실험실 · 자동 슬롯). 수동 슬롯의 키는 화면 식별자 그대로다 —
/// 실험을 걷어내도 기존 파일이 그대로 읽히고 마이그레이션이 없다.
public enum Slot: String, Equatable, Sendable {
    case manual, auto

    /// 자동 슬롯만 접미사를 단다. 화면 식별자에는 '#'이 없다(WindowServer UUID).
    static let autoSuffix = "#auto"

    public func key(_ screenID: String) -> String {
        self == .auto ? screenID + Slot.autoSuffix : screenID
    }

    /// 저장소 키가 자동 슬롯의 것인가 — 프로필 목록에서 걸러낼 때 쓴다.
    public static func isAutoKey(_ key: String) -> Bool { key.hasSuffix(autoSuffix) }
}

/// 건너뜀 사유 (F-02.2). 사용자가 이해할 문구로의 변환은 UI의 몫이다.
public enum SkipReason: Equatable, Sendable {
    case appNotRunning
    case fullscreen
    case minimized
    case alreadyInPlace
    /// 앱은 실행 중인데 표준 창이 하나도 없다.
    case noWindow
}

/// 화면 통째 건너뜀 사유 — 앱 단위(SkipReason)가 아니라 그 화면의 복원 자체를 하지 않은 이유.
public enum ScreenSkipReason: Equatable, Sendable {
    /// UUID는 같은데 지문이 다르다 — OS가 배정을 바꿨다는 신호. 오작동 대신 무작동 (F-01.4).
    case fingerprintMismatch
}

/// 복원 결과 (F-05.1: 이동 n · 건너뜀 n · 실패 n + 사유).
/// 어느 화면의 결과인지 함께 기록한다 — 다른 화면의 카드에 이 결과를 보여주면 안 된다 (화면별 프로필 원칙, US-003).
public struct RestoreResult: Equatable, Sendable {
    public let screenID: String
    /// nil이면 정상 복원. 값이 있으면 이 화면은 통째로 건너뛰었고 entries는 비어 있다.
    public let screenSkipReason: ScreenSkipReason?

    public enum Outcome: Equatable, Sendable {
        case moved
        case skipped(SkipReason)
        case failed
    }

    public struct Entry: Equatable, Sendable {
        public let bundleID: String
        public let displayName: String
        public let outcome: Outcome

        public init(bundleID: String, displayName: String, outcome: Outcome) {
            self.bundleID = bundleID; self.displayName = displayName; self.outcome = outcome
        }
    }

    public var entries: [Entry]

    public init(screenID: String, screenSkipReason: ScreenSkipReason? = nil, entries: [Entry] = []) {
        self.screenID = screenID
        self.screenSkipReason = screenSkipReason
        self.entries = entries
    }

    public var movedCount: Int { entries.filter { $0.outcome == .moved }.count }
    public var failedCount: Int { entries.filter { $0.outcome == .failed }.count }
    public var skippedCount: Int {
        entries.filter { if case .skipped = $0.outcome { return true } else { return false } }.count
    }
}
