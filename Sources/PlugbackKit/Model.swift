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
public struct ScreenFingerprint: Codable, Equatable, Hashable, Sendable {
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor; self.model = model; self.serial = serial
    }
}

/// 맥 본체에서 케이블이 꽂힌 포트의 위치 (표시용 — 식별 키가 아니다, P20).
/// IORegistry의 `port-location` 문자열을 그대로 보존하고, 알려진 값만 이름으로 매핑한다.
public enum PortLocation: Codable, Equatable, Hashable, Sendable {
    case leftBack, leftFront, rightBack, rightFront, left, right
    case other(String)

    public init(rawLocation: String) {
        switch rawLocation {
        case "left-back": self = .leftBack
        case "left-front": self = .leftFront
        case "right-back": self = .rightBack
        case "right-front": self = .rightFront
        case "left": self = .left
        case "right": self = .right
        default: self = .other(rawLocation)
        }
    }
}

/// 화면 하나. id는 화면 식별자(WindowServer UUID) — 포트 변경 안정성은 실측 통과(2026-08-16), 동일 모델 2대·재부팅은 미측정 (ARCHITECTURE 스파이크).
public struct ScreenInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let frame: CGRect
    public let isBuiltin: Bool
    public let fingerprint: ScreenFingerprint?
    /// 지금 연결된 포트의 위치. 확인하지 못하면 nil — 추정 위치를 지어내지 않는다.
    public let portLocation: PortLocation?

    public init(id: String, name: String, frame: CGRect, isBuiltin: Bool,
                fingerprint: ScreenFingerprint? = nil, portLocation: PortLocation? = nil) {
        self.id = id; self.name = name; self.frame = frame; self.isBuiltin = isBuiltin
        self.fingerprint = fingerprint; self.portLocation = portLocation
    }

    /// 창의 소속 화면 판정 — 중심점 규칙 (F-03.2). 저장과 복원이 이 하나의 규칙을 공유한다.
    public func contains(_ window: WindowInfo) -> Bool { frame.contains(window.center) }
}

/// 카드 헤더의 화면 상태 — 상태는 이 셋뿐이다 (ARCHITECTURE 고정 결정: 빈 상태에서도 카드는 비지 않는다).
public enum ScreenPresence: Equatable, Sendable {
    /// 외장 화면이 지금 연결되어 있다. count는 연결된 외장 화면 수 (다중 화면 표시용).
    case connected(ScreenInfo, count: Int)
    /// 외장 화면이 없는 동안 아는 화면 하나(방금 분리된 화면, 재시작 직후엔 이름순 첫 저장본)의 이름과 저장본 유무를 보여준다.
    case remembered(screenID: String, name: String)
    /// 아는 화면이 없다 — 첫 실행.
    case none
}

/// Space 경로에서만 쓰는 전체화면 판정. 공개되지 않은 AX attribute를 읽지 못하면
/// 일반 창으로 낮추지 않고 unknown으로 남긴다.
public enum WindowFullscreenState: Equatable, Sendable {
    case windowed
    case fullscreen
    case unknown
}

/// 표준 창 하나. id는 마지막 게이트웨이 열거에만 유효하다. windowServerID는 창이 살아 있는 동안
/// 같은 실제 창을 가리키는 실행 중 식별자다 — 재시작을 넘는 창 식별자는 없다 (FUNCTIONAL_SPEC 부록 3).
public struct WindowInfo: Equatable, Sendable {
    public let id: Int
    public let appBundleID: String
    public let appName: String
    public let frame: CGRect
    public let fullscreenState: WindowFullscreenState
    public let isMinimized: Bool
    /// 앱이 ⌘H로 숨겨져 있다. 창 좌표는 남아 있지만 어떤 의미로도 화면에 있는 창이 아니다 —
    /// 저장·수집·카드 목록은 없는 창으로 보고, 복원은 그대로 옮긴다 (F-03.2).
    public let isHidden: Bool
    public let windowServerID: CGWindowID?
    /// 직접 지정 화면의 표시용 제목. 저장·진단 기록에는 넣지 않는다 (3.7절).
    public let title: String?

    public init(id: Int, appBundleID: String, appName: String, frame: CGRect,
                isFullscreen: Bool = false, isMinimized: Bool = false, isHidden: Bool = false,
                windowServerID: CGWindowID? = nil, title: String? = nil) {
        self.id = id; self.appBundleID = appBundleID; self.appName = appName
        self.frame = frame
        fullscreenState = isFullscreen ? .fullscreen : .windowed
        self.isMinimized = isMinimized; self.isHidden = isHidden
        self.windowServerID = windowServerID; self.title = title
    }

    public init(id: Int, appBundleID: String, appName: String, frame: CGRect,
                fullscreenState: WindowFullscreenState, isMinimized: Bool = false,
                isHidden: Bool = false, windowServerID: CGWindowID? = nil, title: String? = nil) {
        self.id = id; self.appBundleID = appBundleID; self.appName = appName
        self.frame = frame; self.fullscreenState = fullscreenState
        self.isMinimized = isMinimized; self.isHidden = isHidden
        self.windowServerID = windowServerID; self.title = title
    }

    public var isFullscreen: Bool { fullscreenState == .fullscreen }
    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

// MARK: - 구버전 파일 형식 (읽기·이전 전용)

/// 구버전(화면별 프로필) 대상 앱 항목. 새 파일에는 쓰지 않는다.
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

/// 구버전 프로필 — 화면 식별자 하나당 하나. `profiles.json`을 읽어 작업 환경으로 이전할 때만 쓴다.
public struct Profile: Codable, Equatable, Sendable {
    public let screenID: String
    public var screenName: String
    public var apps: [TargetApp]
    public var fingerprint: ScreenFingerprint?
    public var savedAt: Date?

    public init(screenID: String, screenName: String, apps: [TargetApp] = [],
                fingerprint: ScreenFingerprint? = nil, savedAt: Date? = nil) {
        self.screenID = screenID; self.screenName = screenName; self.apps = apps
        self.fingerprint = fingerprint; self.savedAt = savedAt
    }
}

/// 저장이 어느 경로로 완료됐는지 (표시용). 구버전의 슬롯 키 접미사도 여기서 해석한다.
public enum Slot: String, Codable, Equatable, Sendable {
    case manual, auto

    static let autoSuffix = "#auto"
    func key(_ screenID: String) -> String { self == .auto ? screenID + Slot.autoSuffix : screenID }
    static func isAutoKey(_ key: String) -> Bool { key.hasSuffix(autoSuffix) }
}

/// 이 외장 화면에 창이 있지만 저장본에 없는 앱 — 다음 저장에 기본 포함된다(D4). 제외하려면 체크를 끈다.
public struct UntrackedApp: Equatable, Sendable {
    public let bundleID: String
    public let displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID; self.displayName = displayName
    }
}

// MARK: - 복원 결과

/// 건너뜀 사유 (F-02.2). 사용자가 이해할 문구로의 변환은 UI의 몫이다.
public enum SkipReason: Equatable, Sendable {
    case appNotRunning
    case fullscreen
    case minimized
    case alreadyInPlace
    /// 앱은 실행 중인데 배정할 표준 창이 없다.
    case noWindow
    /// 같은 작업 환경에서 닫힌 것으로 확인한 저장 창 — 다음 저장 성공까지 제외 (D9).
    case closedInWorkspace
    /// 자동 복원 도중 사용자가 직접 조작한 창 — 이번 자동 복원에서 보호 (D5).
    case userInteraction
}

/// 확인이 필요한 이유 — 사용자의 「남은 창 복원」으로만 재개한다 (D8).
public enum ConfirmationReason: Equatable, Sendable {
    /// 같은 앱의 후보 창이 여럿이고 직접 지정이 켜져 있다. 후보의 windowServerID를 함께 전한다.
    case ambiguousCandidates([CGWindowID])
    /// 저장한 창이 현재 없고, 닫힌 시점·환경을 확인할 수 없다 (W21).
    case closureUnknown
    /// 저장한 Space를 현재 찾을 수 없다 (P06).
    case spaceMissing
    /// Space 상태를 확인할 수 없다 (snapshot 없음·판정 불가).
    case spaceUnavailable
    /// 개별 Spaces 설정이 꺼져 있거나 확인할 수 없다 (D6).
    case spacesUnsupported
    /// 후보 창이 목적 화면의 다른 Space에 있다 — 사용자가 옮긴 뒤 재개 (P05).
    case windowOnAnotherSpace
    /// 앱 실행·창 생성을 요청했으나 창을 확인하지 못했다.
    case windowCreationFailed
}

/// 미전송 조작을 보류한 이유.
public enum HoldReason: Equatable, Sendable {
    case screenLocked
    case lockStateUndetermined
}

/// 요청이 취소된 이유.
public enum CancelReason: Equatable, Sendable {
    case userCancelled
    case newRequest
    case newSave
    case workspaceChanged
    case targetRemoved
    case automaticRestoreDisabled
    case spacesUnsupported
}

/// 화면 통째 건너뜀 사유 — 앱 단위(SkipReason)가 아니라 그 화면의 복원 자체를 하지 않은 이유.
public enum ScreenSkipReason: Equatable, Sendable {
    /// UUID는 같은데 지문이 다르다 — OS가 배정을 바꿨다는 신호. 오작동 대신 무작동 (F-01.4).
    case fingerprintMismatch
}

/// 복원 결과 — 저장 창 하나마다 항목 하나 (D1). 모든 대상 기록이 결과에 남는다.
/// 어느 화면의 결과인지 함께 기록한다 — 다른 화면의 카드에 이 결과를 보여주면 안 된다.
public struct RestoreResult: Equatable, Sendable {
    public let screenID: String
    /// nil이면 정상 복원. 값이 있으면 이 화면은 통째로 건너뛰었고 entries는 비어 있다.
    public let screenSkipReason: ScreenSkipReason?

    public enum Outcome: Equatable, Sendable {
        case moved
        case skipped(SkipReason)
        case failed
        /// 목적 Space가 비활성 — 유효한 요청 동안 방문 이벤트를 기다린다 (시간 제한 없음, D8).
        case awaitingVisit
        /// 저장 Space가 다른 화면에 남아 있다 — 사용자가 Mission Control에서 옮겨야 한다.
        case awaitingSpaceMove(sourceScreenID: String)
        case needsConfirmation(ConfirmationReason)
        case held(HoldReason)
        case cancelled(CancelReason)
    }

    public struct Entry: Equatable, Sendable {
        public let placementID: UUID
        public let bundleID: String
        public let displayName: String
        public let space: SpaceHint?
        public let outcome: Outcome

        public init(placementID: UUID, bundleID: String, displayName: String,
                    space: SpaceHint? = nil, outcome: Outcome) {
            self.placementID = placementID; self.bundleID = bundleID
            self.displayName = displayName; self.space = space; self.outcome = outcome
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
    public var waitingCount: Int {
        entries.filter {
            switch $0.outcome {
            case .awaitingVisit, .awaitingSpaceMove, .held: return true
            default: return false
            }
        }.count
    }
    public var confirmationCount: Int {
        entries.filter { if case .needsConfirmation = $0.outcome { return true } else { return false } }.count
    }
    public var cancelledCount: Int {
        entries.filter { if case .cancelled = $0.outcome { return true } else { return false } }.count
    }
}
