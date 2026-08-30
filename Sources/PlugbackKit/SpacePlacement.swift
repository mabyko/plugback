import CoreGraphics

/// 한 stable snapshot 안에서만 유효한 Space 위치 사실.
/// 저장·복원·표시 정책은 담지 않고, 판정할 수 없으면 항상 unknown으로 닫는다.
enum SpacePlacement: Equatable, Sendable {
    struct Found: Equatable, Sendable {
        let screenID: String
        let space: SpaceSnapshot.Space
        /// snapshot 전체에서 유일한 이름을 가진 일반 Space만 저장 identity가 있다.
        let identity: SpaceHint?
    }

    enum Ambiguity: Equatable, Sendable {
        case noSnapshot
        case display
        case name
        case runtimeID
        case windowUnjoined
        case membership(Int)
        case multipleSpaces
    }

    case current(Found)
    case inactive(Found)
    case stranded(Found)
    case fullscreen(Found)
    case unsupported(Found)
    case missing
    case unknown(Ambiguity)

    var found: Found? {
        switch self {
        case .current(let found), .inactive(let found), .stranded(let found),
             .fullscreen(let found), .unsupported(let found):
            return found
        case .missing, .unknown:
            return nil
        }
    }

    var onTarget: Found? {
        switch self {
        case .current(let found), .inactive(let found): return found
        default: return nil
        }
    }

    static func of(
        _ hint: SpaceHint,
        on screenID: String,
        in snapshot: SpaceSnapshot?
    ) -> SpacePlacement {
        locate(on: screenID, in: snapshot, ambiguity: .name) {
            $0.opaqueName == hint.opaqueName
        }
    }

    static func of(
        _ runtimeID: SpaceRuntimeID,
        on screenID: String,
        in snapshot: SpaceSnapshot?
    ) -> SpacePlacement {
        locate(on: screenID, in: snapshot, ambiguity: .runtimeID) {
            $0.runtimeID == runtimeID
        }
    }

    private static func locate(
        on screenID: String,
        in snapshot: SpaceSnapshot?,
        ambiguity: Ambiguity,
        where matches: (SpaceSnapshot.Space) -> Bool
    ) -> SpacePlacement {
        guard let snapshot else { return .unknown(.noSnapshot) }
        guard snapshot.onlyDisplay(screenID) != nil else {
            return .unknown(.display)
        }
        let locations = snapshot.displays.flatMap { display in
            display.spaces.filter(matches)
                .map { (display.screenID, $0) }
        }
        guard !locations.isEmpty else { return .missing }
        guard locations.count == 1, let location = locations.first else {
            return .unknown(ambiguity)
        }
        return classify(location, targetScreenID: screenID, in: snapshot)
    }

    static func of(
        windowServerIDs: [CGWindowID?],
        on screenID: String,
        in snapshot: SpaceSnapshot?
    ) -> SpacePlacement {
        guard let snapshot else { return .unknown(.noSnapshot) }
        guard !windowServerIDs.isEmpty else { return .unknown(.membership(0)) }
        var runtimeIDs = Set<SpaceRuntimeID>()
        for optionalID in windowServerIDs {
            guard let windowID = optionalID else { return .unknown(.windowUnjoined) }
            let memberships = snapshot.membershipsByWindowServerID[windowID] ?? []
            guard memberships.count == 1, let runtimeID = memberships.first else {
                return .unknown(.membership(memberships.count))
            }
            runtimeIDs.insert(runtimeID)
        }
        guard runtimeIDs.count == 1, let runtimeID = runtimeIDs.first else {
            return .unknown(.multipleSpaces)
        }
        return of(runtimeID, on: screenID, in: snapshot)
    }

    private static func classify(
        _ location: (screenID: String, space: SpaceSnapshot.Space),
        targetScreenID: String,
        in snapshot: SpaceSnapshot
    ) -> SpacePlacement {
        let space = location.space
        let identity: SpaceHint?
        if space.kind == .regular,
           let name = space.opaqueName,
           !name.isEmpty,
           snapshot.displays.flatMap(\.spaces).filter({ $0.opaqueName == name }).count == 1 {
            identity = SpaceHint(opaqueName: name, localOrderHint: space.localOrder)
        } else {
            identity = nil
        }
        let found = Found(screenID: location.screenID, space: space, identity: identity)
        switch space.kind {
        case .fullscreen:
            return .fullscreen(found)
        case .unknown:
            return .unsupported(found)
        case .regular:
            guard location.screenID == targetScreenID else { return .stranded(found) }
            return space.isCurrent ? .current(found) : .inactive(found)
        }
    }
}

extension SpaceSnapshot {
    func onlyDisplay(_ screenID: String) -> Display? {
        let matches = displays.filter { $0.screenID == screenID }
        return matches.count == 1 ? matches[0] : nil
    }
}
