import CoreGraphics
import Foundation

/// 작업 환경 — 연결된 외장 화면 식별자의 집합 (D5). `{A, B}`와 `{B, A}`는 같고 `{A}`는 다르다.
/// 내장 화면은 조합에 넣지 않는다. 연결 순서·좌우 배치·해상도는 키가 아니다.
public struct WorkspaceKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let screenIDs: [String]

    public init(screenIDs: some Sequence<String>) {
        self.screenIDs = Array(Set(screenIDs)).sorted()
    }

    public init?(raw: String) {
        guard !raw.isEmpty else { return nil }
        self.init(screenIDs: raw.split(separator: "+").map(String.init))
    }

    public var raw: String { screenIDs.joined(separator: "+") }
    public var isEmpty: Bool { screenIDs.isEmpty }
    public var description: String { raw }
    public func contains(_ screenID: String) -> Bool { screenIDs.contains(screenID) }

    public static func < (lhs: WorkspaceKey, rhs: WorkspaceKey) -> Bool { lhs.raw < rhs.raw }
}

/// 저장된 일반 Space의 identity. opaque name은 실행을 넘어 안정적이라고 보장하지 않으므로,
/// 다음 복원 요청에서 현재 목록에 대응시키지 못하면 확인 필요로 남긴다 (DSK04).
public struct SpaceHint: Codable, Equatable, Hashable, Sendable {
    public let opaqueName: String
    public let localOrderHint: Int

    public init(opaqueName: String, localOrderHint: Int) {
        self.opaqueName = opaqueName; self.localOrderHint = localOrderHint
    }
}

/// 창 위치 기록 — 한 일반 Space에 놓인 대상 앱 표준 창 하나의 목적 화면·Space·위치·크기 (D1).
/// 같은 앱의 다른 창은 별도 기록이다. id는 저장 자리의 identity이며 같은 창으로 확인되는 동안 유지된다.
public struct WindowPlacement: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let bundleID: String
    public var displayName: String
    public var screenID: String
    /// nil은 Space를 관찰하지 않은 기록(구버전 이전·flat 관찰)이다. Space 지정이 있는 기록을 조회 실패 때문에 평면 복원으로 강등하지 않는다 (O02).
    public var space: SpaceHint?
    public var unitRect: UnitRect

    public init(id: UUID = UUID(), bundleID: String, displayName: String, screenID: String,
                space: SpaceHint?, unitRect: UnitRect) {
        self.id = id; self.bundleID = bundleID; self.displayName = displayName
        self.screenID = screenID; self.space = space; self.unitRect = unitRect
    }
}

/// 작업 환경 구성원 화면의 저장 당시 정보.
public struct ScreenRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var fingerprint: ScreenFingerprint?
    /// 마지막 확인 당시의 포트 위치 — 연결 해제 중에는 「마지막 확인」 정보다.
    public var portLocation: PortLocation?
    /// 이 화면에 속해야 하는 식별 가능한 일반 Space 전체 (저장 순서). 앱이 없어도 남는다.
    public var regularSpaces: [SpaceHint]

    public init(id: String, name: String, fingerprint: ScreenFingerprint? = nil,
                portLocation: PortLocation? = nil, regularSpaces: [SpaceHint] = []) {
        self.id = id; self.name = name; self.fingerprint = fingerprint
        self.portLocation = portLocation; self.regularSpaces = regularSpaces
    }
}

/// 앱 포함·제외의 단위 (D4). 작업 환경의 모든 구성원 화면에 공유된다.
public struct AppSelection: Codable, Equatable, Sendable {
    public let bundleID: String
    public var displayName: String
    public var isEnabled: Bool

    public init(bundleID: String, displayName: String, isEnabled: Bool = true) {
        self.bundleID = bundleID; self.displayName = displayName; self.isEnabled = isEnabled
    }
}

/// 작업 환경 저장본 — 화면 정보와 창 위치 기록 전체를 한 번에 확정한 값 (D2).
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var key: WorkspaceKey
    public var screens: [ScreenRecord]
    public var placements: [WindowPlacement]
    public var savedAt: Date?
    public var savedBy: Slot

    public init(key: WorkspaceKey, screens: [ScreenRecord], placements: [WindowPlacement],
                savedAt: Date? = nil, savedBy: Slot = .manual) {
        self.key = key; self.screens = screens; self.placements = placements
        self.savedAt = savedAt; self.savedBy = savedBy
    }

    public func screen(_ id: String) -> ScreenRecord? { screens.first { $0.id == id } }
    public func placements(on screenID: String) -> [WindowPlacement] {
        placements.filter { $0.screenID == screenID }
    }

    /// 내용 비교 — 저장·관찰 시각과 저장 자리 id는 제외하고 화면의 Space 목록·창별 화면·Space·위치·크기를 비교한다 (D2).
    /// 좌표는 비율 좌표의 미세 오차(0.003 ≈ 1600px에서 5pt)를 같다고 본다.
    public func contentEquals(_ other: WorkspaceSnapshot) -> Bool {
        guard key == other.key else { return false }
        let mine = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.regularSpaces) })
        let theirs = Dictionary(uniqueKeysWithValues: other.screens.map { ($0.id, $0.regularSpaces) })
        guard mine == theirs else { return false }
        guard placements.count == other.placements.count else { return false }
        var remaining = other.placements
        for placement in placements {
            guard let index = remaining.firstIndex(where: { candidate in
                candidate.bundleID == placement.bundleID
                    && candidate.screenID == placement.screenID
                    && candidate.space == placement.space
                    && Self.approximatelyEqual(candidate.unitRect, placement.unitRect)
            }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    static let unitTolerance = 0.003

    static func approximatelyEqual(_ a: UnitRect, _ b: UnitRect) -> Bool {
        abs(a.x - b.x) <= unitTolerance && abs(a.y - b.y) <= unitTolerance
            && abs(a.width - b.width) <= unitTolerance && abs(a.height - b.height) <= unitTolerance
    }
}

/// 작업 환경 하나의 영구 기록 — 앱 선택, 마지막 저장본, 같은 환경에서 닫힌 저장 창의 제외 목록 (D9).
public struct WorkspaceRecord: Codable, Equatable, Sendable {
    public var key: WorkspaceKey
    public var apps: [AppSelection]
    public var saved: WorkspaceSnapshot?
    /// 같은 환경에서 닫힌 것으로 확인한 저장 자리. 그 환경의 다음 저장 성공까지 유지되며 재실행을 넘어 보존된다.
    public var closedPlacementIDs: Set<UUID>

    public init(key: WorkspaceKey, apps: [AppSelection] = [], saved: WorkspaceSnapshot? = nil,
                closedPlacementIDs: Set<UUID> = []) {
        self.key = key; self.apps = apps; self.saved = saved; self.closedPlacementIDs = closedPlacementIDs
    }

    public func isEnabled(_ bundleID: String) -> Bool {
        apps.first { $0.bundleID == bundleID }?.isEnabled ?? true
    }

    public var excludedBundleIDs: Set<String> {
        Set(apps.filter { !$0.isEnabled }.map(\.bundleID))
    }
}

/// 저장 파일 전체. 버전은 형식 미지원(이후 버전)을 손상과 구별하기 위한 값이다 (DSK10).
struct StoreFile: Codable, Equatable {
    static let currentVersion = 2
    var version: Int
    var workspaces: [String: WorkspaceRecord]
}
