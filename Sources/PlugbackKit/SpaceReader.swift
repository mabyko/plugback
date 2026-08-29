import CoreGraphics
import Darwin
import Foundation

/// WindowServer Space ID의 메모리 한정 표현. Codable을 채택하지 않아 프로필에 저장되지 않는다.
public struct SpaceRuntimeID: Hashable, Sendable {
    let rawValue: UInt64

    init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

public enum SpaceKind: Equatable, Sendable {
    case regular
    case fullscreen
    case unknown(Int32)
}

/// 한 번의 안정된 read-only WindowServer 관찰값. 모든 숫자 ID는 이 값의 수명에만 유효하다.
public struct SpaceSnapshot: Equatable, Sendable {
    public struct Display: Equatable, Sendable {
        public let screenID: String
        public let spaces: [Space]

        public init(screenID: String, spaces: [Space]) {
            self.screenID = screenID; self.spaces = spaces
        }
    }

    public struct Space: Equatable, Sendable {
        public let runtimeID: SpaceRuntimeID
        public let opaqueName: String?
        public let localOrder: Int
        public let kind: SpaceKind
        public let isCurrent: Bool

        public init(runtimeID: SpaceRuntimeID, opaqueName: String?, localOrder: Int,
                    kind: SpaceKind, isCurrent: Bool) {
            self.runtimeID = runtimeID; self.opaqueName = opaqueName
            self.localOrder = localOrder; self.kind = kind; self.isCurrent = isCurrent
        }
    }

    public let displays: [Display]
    public let membershipsByWindowServerID: [CGWindowID: [SpaceRuntimeID]]

    public init(displays: [Display],
                membershipsByWindowServerID: [CGWindowID: [SpaceRuntimeID]]) {
        self.displays = displays
        self.membershipsByWindowServerID = membershipsByWindowServerID
    }
}

public enum SpaceSnapshotAvailability: Equatable, Sendable {
    case available(SpaceSnapshot)
    case unavailable
}

public protocol SpaceReading: Sendable {
    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability
}

/// private 심볼이 없거나 반환 형식이 달라지면 snapshot 전체를 버리는 read-only adapter.
public actor SpaceReader: SpaceReading {
    private let api: SkyLightAPI?

    public init() { api = SkyLightAPI() }

    public func stableSnapshot(
        windowServerIDs: [CGWindowID]
    ) async -> SpaceSnapshotAvailability {
        guard let api else { return .unavailable }
        return Self.settledSnapshot(
            first: api.snapshot(windowServerIDs: windowServerIDs),
            second: api.snapshot(windowServerIDs: windowServerIDs)
        )
    }

    static func settledSnapshot(
        first: SpaceSnapshot?, second: SpaceSnapshot?
    ) -> SpaceSnapshotAvailability {
        guard let first, first == second else { return .unavailable }
        return .available(first)
    }
}

public struct UnavailableSpaceReader: SpaceReading {
    public init() {}

    public func stableSnapshot(
        windowServerIDs: [CGWindowID]
    ) async -> SpaceSnapshotAvailability { .unavailable }
}

private typealias SLSMainConnectionID = @convention(c) () -> Int32
private typealias SLSCopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias SLSCopySpacesForWindows = @convention(c) (
    Int32, Int32, CFArray
) -> Unmanaged<CFArray>?
private typealias SLSSpaceGetType = @convention(c) (Int32, UInt64) -> Int32
private typealias SLSSpaceCopyName = @convention(c) (
    Int32, UInt64
) -> Unmanaged<CFString>?
private typealias SLSManagedDisplayGetCurrentSpace = @convention(c) (
    Int32, CFString
) -> UInt64

private struct SkyLightAPI {
    let mainConnection: SLSMainConnectionID
    let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpaces
    let copySpacesForWindows: SLSCopySpacesForWindows
    let spaceType: SLSSpaceGetType
    let spaceName: SLSSpaceCopyName
    let currentSpace: SLSManagedDisplayGetCurrentSpace

    init?() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        )
        guard
            let mainConnection = loadUndocumentedSymbol(
                from: [handle], named: "SLSMainConnectionID", as: SLSMainConnectionID.self
            ),
            let copyManagedDisplaySpaces = loadUndocumentedSymbol(
                from: [handle], named: "SLSCopyManagedDisplaySpaces",
                as: SLSCopyManagedDisplaySpaces.self
            ),
            let copySpacesForWindows = loadUndocumentedSymbol(
                from: [handle], named: "SLSCopySpacesForWindows",
                as: SLSCopySpacesForWindows.self
            ),
            let spaceType = loadUndocumentedSymbol(
                from: [handle], named: "SLSSpaceGetType", as: SLSSpaceGetType.self
            ),
            let spaceName = loadUndocumentedSymbol(
                from: [handle], named: "SLSSpaceCopyName", as: SLSSpaceCopyName.self
            ),
            let currentSpace = loadUndocumentedSymbol(
                from: [handle], named: "SLSManagedDisplayGetCurrentSpace",
                as: SLSManagedDisplayGetCurrentSpace.self
            )
        else { return nil }

        self.mainConnection = mainConnection
        self.copyManagedDisplaySpaces = copyManagedDisplaySpaces
        self.copySpacesForWindows = copySpacesForWindows
        self.spaceType = spaceType
        self.spaceName = spaceName
        self.currentSpace = currentSpace
    }

    func snapshot(windowServerIDs: [CGWindowID]) -> SpaceSnapshot? {
        let connection = mainConnection()
        guard let managed = copyManagedDisplaySpaces(connection)?.takeRetainedValue()
        else { return nil }

        var displays: [SpaceSnapshot.Display] = []
        var seenScreenIDs = Set<String>()
        var seenRuntimeIDs = Set<SpaceRuntimeID>()
        for rawDisplay in managed as NSArray {
            guard let dictionary = rawDisplay as? NSDictionary,
                  let identifier = dictionary["Display Identifier"] as? String,
                  let screenID = canonicalScreenID(identifier),
                  let rawSpaces = dictionary["Spaces"] as? NSArray,
                  rawSpaces.count > 0,
                  seenScreenIDs.insert(screenID).inserted else { return nil }

            let currentID = SpaceRuntimeID(currentSpace(connection, identifier as CFString))
            var spaces: [SpaceSnapshot.Space] = []
            for (index, rawSpace) in rawSpaces.enumerated() {
                guard let dictionary = rawSpace as? NSDictionary,
                      let numericID = number(dictionary["id64"])
                        ?? number(dictionary["ManagedSpaceID"]) else { return nil }
                let runtimeID = SpaceRuntimeID(numericID)
                guard seenRuntimeIDs.insert(runtimeID).inserted else { return nil }

                let rawName = spaceName(connection, numericID)?.takeRetainedValue() as String?
                let opaqueName = rawName.flatMap { $0.isEmpty ? nil : $0 }
                let rawType = spaceType(connection, numericID)
                let kind: SpaceKind = switch rawType {
                case 0: .regular
                case 4: .fullscreen
                default: .unknown(rawType)
                }
                spaces.append(SpaceSnapshot.Space(
                    runtimeID: runtimeID,
                    opaqueName: opaqueName,
                    localOrder: index + 1,
                    kind: kind,
                    isCurrent: runtimeID == currentID
                ))
            }
            guard spaces.contains(where: \.isCurrent) else { return nil }
            displays.append(SpaceSnapshot.Display(screenID: screenID, spaces: spaces))
        }
        guard !displays.isEmpty else { return nil }

        var memberships: [CGWindowID: [SpaceRuntimeID]] = [:]
        for windowID in Set(windowServerIDs).sorted() {
            let input = [NSNumber(value: windowID)] as CFArray
            guard let raw = copySpacesForWindows(connection, 0x7, input)?.takeRetainedValue()
            else {
                memberships[windowID] = []
                continue
            }
            var ids: [SpaceRuntimeID] = []
            for value in raw as NSArray {
                guard let numericID = number(value) else { return nil }
                ids.append(SpaceRuntimeID(numericID))
            }
            memberships[windowID] = Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }
        }
        return SpaceSnapshot(displays: displays, membershipsByWindowServerID: memberships)
    }

    private func canonicalScreenID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        return UUID(uuidString: trimmed)?.uuidString
    }

    private func number(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.uint64Value
    }
}

func loadUndocumentedSymbol<T>(
    from handles: [UnsafeMutableRawPointer?], named name: String, as type: T.Type
) -> T? {
    for handle in handles {
        guard let handle, let symbol = dlsym(handle, name) else { continue }
        return unsafeBitCast(symbol, to: T.self)
    }
    return nil
}
