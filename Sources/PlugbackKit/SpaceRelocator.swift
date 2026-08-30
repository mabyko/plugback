import AppKit
import ApplicationServices
import CoreGraphics

public struct SpaceRelocation: Equatable, Sendable {
    public let sourceScreenID: String
    public let sourceLocalOrder: Int
    public let destinationScreenID: String
    public let expectedSourceCount: Int
    public let expectedDestinationCount: Int

    public init(
        sourceScreenID: String,
        sourceLocalOrder: Int,
        destinationScreenID: String,
        expectedSourceCount: Int,
        expectedDestinationCount: Int
    ) {
        self.sourceScreenID = sourceScreenID
        self.sourceLocalOrder = sourceLocalOrder
        self.destinationScreenID = destinationScreenID
        self.expectedSourceCount = expectedSourceCount
        self.expectedDestinationCount = expectedDestinationCount
    }
}

public protocol SpaceRelocating: Sendable {
    func relocate(_ request: SpaceRelocation) async -> Bool
}

struct PlannedSpaceRelocation: Equatable, Sendable {
    let runtimeID: SpaceRuntimeID
    let opaqueName: String
    let request: SpaceRelocation
}

enum SpaceRelocationPlan: Equatable, Sendable {
    case complete
    case blocked
    case move(PlannedSpaceRelocation)
}

enum SpaceRelocationPlanner {
    static func desiredCount(
        resolved: [String: ResolvedProfile], screens: [ScreenInfo]
    ) -> Int { desiredSpaces(resolved: resolved, screens: screens).count }

    static func next(
        resolved: [String: ResolvedProfile], screens: [ScreenInfo], snapshot: SpaceSnapshot
    ) -> SpaceRelocationPlan {
        let desired = desiredSpaces(resolved: resolved, screens: screens)
        var moves: [PlannedSpaceRelocation] = []
        var hasBlockedSpace = false

        for (destinationID, hint) in desired {
            let placement = SpacePlacement.of(hint, on: destinationID, in: snapshot)
            switch placement {
            case .current, .inactive:
                continue
            case .stranded(let found):
                guard let source = snapshot.onlyDisplay(found.screenID),
                      let destination = snapshot.onlyDisplay(destinationID),
                      !found.space.isCurrent,
                      source.spaces.filter({ $0.kind == .regular }).count > 1 else {
                    hasBlockedSpace = true
                    continue
                }
                moves.append(PlannedSpaceRelocation(
                    runtimeID: found.space.runtimeID,
                    opaqueName: hint.opaqueName,
                    request: SpaceRelocation(
                        sourceScreenID: source.screenID,
                        sourceLocalOrder: found.space.localOrder,
                        destinationScreenID: destination.screenID,
                        expectedSourceCount: source.spaces.count,
                        expectedDestinationCount: destination.spaces.count
                    )
                ))
            case .fullscreen, .unsupported, .missing, .unknown:
                hasBlockedSpace = true
            }
        }
        if let move = moves.first { return .move(move) }
        return hasBlockedSpace ? .blocked : .complete
    }

    static func verifies(
        _ move: PlannedSpaceRelocation, before: SpaceSnapshot, after: SpaceSnapshot
    ) -> Bool {
        let beforeIDs = before.displays.flatMap(\.spaces).map(\.runtimeID)
        let afterIDs = after.displays.flatMap(\.spaces).map(\.runtimeID)
        guard Set(beforeIDs).count == beforeIDs.count,
              Set(afterIDs).count == afterIDs.count,
              Set(beforeIDs) == Set(afterIDs),
              before.membershipsByWindowServerID == after.membershipsByWindowServerID,
              let old = SpacePlacement.of(
                  move.runtimeID, on: move.request.destinationScreenID, in: before
              ).found,
              let new = SpacePlacement.of(
                  move.runtimeID, on: move.request.destinationScreenID, in: after
              ).found,
              old.screenID == move.request.sourceScreenID,
              new.screenID == move.request.destinationScreenID,
              old.space.opaqueName == move.opaqueName,
              new.space.opaqueName == move.opaqueName else { return false }

        for runtimeID in beforeIDs {
            guard let oldLocation = SpacePlacement.of(
                runtimeID, on: move.request.destinationScreenID, in: before
            ).found,
            let newLocation = SpacePlacement.of(
                runtimeID, on: move.request.destinationScreenID, in: after
            ).found,
            oldLocation.space.kind == newLocation.space.kind,
            oldLocation.space.opaqueName == newLocation.space.opaqueName,
            oldLocation.space.isCurrent == newLocation.space.isCurrent else { return false }
            if runtimeID != move.runtimeID, oldLocation.space.kind == .regular,
               oldLocation.screenID != newLocation.screenID { return false }
        }

        let screenIDs = Set(before.displays.map(\.screenID) + after.displays.map(\.screenID))
        for screenID in screenIDs {
            let oldOrder = regularOrder(in: before, screenID: screenID, excluding: move.runtimeID)
            let newOrder = regularOrder(in: after, screenID: screenID, excluding: move.runtimeID)
            guard oldOrder == newOrder else { return false }
        }
        return true
    }

    private static func desiredSpaces(
        resolved: [String: ResolvedProfile], screens: [ScreenInfo]
    ) -> [(String, SpaceHint)] {
        var claimedBundles = Set<String>()
        var seenNames = Set<String>()
        var desired: [(String, SpaceHint)] = []
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id],
                  pair.profile.fingerprint == nil || screen.fingerprint == nil
                    || pair.profile.fingerprint == screen.fingerprint else { continue }
            for hint in pair.overlay?.regularSpaces ?? []
            where seenNames.insert(hint.opaqueName).inserted {
                desired.append((screen.id, hint))
            }
            for app in pair.profile.apps where app.isEnabled
                && claimedBundles.insert(app.bundleID).inserted {
                guard case .regular(let hint)? = pair.overlay?.byBundle[app.bundleID],
                      seenNames.insert(hint.opaqueName).inserted else { continue }
                desired.append((screen.id, hint))
            }
        }
        return desired.sorted {
            ($0.0, $0.1.localOrderHint, $0.1.opaqueName)
                < ($1.0, $1.1.localOrderHint, $1.1.opaqueName)
        }
    }

    private static func regularOrder(
        in snapshot: SpaceSnapshot, screenID: String, excluding: SpaceRuntimeID
    ) -> [SpaceRuntimeID] {
        snapshot.onlyDisplay(screenID)?.spaces
            .filter { $0.kind == .regular && $0.runtimeID != excluding }
            .sorted { $0.localOrder < $1.localOrder }
            .map(\.runtimeID) ?? []
    }
}

/// Mission Control이 공개하는 Dock AX tree에서 썸네일 하나를 보이는 drag로 옮긴다.
/// 성공 반환은 입력 합성이 끝났다는 뜻뿐이고, 호출자가 stable Space snapshot으로 검증한다.
public actor MissionControlSpaceRelocator: SpaceRelocating {
    private let openDelay: TimeInterval
    private let hoverDelay: TimeInterval
    private let dropDelay: TimeInterval

    public init(
        openDelay: TimeInterval = 2,
        hoverDelay: TimeInterval = 1,
        dropDelay: TimeInterval = 1.5
    ) {
        self.openDelay = openDelay
        self.hoverDelay = hoverDelay
        self.dropDelay = dropDelay
    }

    public func relocate(_ request: SpaceRelocation) async -> Bool {
        guard AXIsProcessTrusted(),
              let sourceDisplayID = displayID(for: request.sourceScreenID),
              let destinationDisplayID = displayID(for: request.destinationScreenID),
              sourceDisplayID != destinationDisplayID else { return false }
        let dockPID = await MainActor.run {
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == "com.apple.dock"
            }?.processIdentifier
        }
        guard let dockPID else { return false }
        let dockBeforeOpen = AXUIElementCreateApplication(dockPID)
        guard firstDescendant(of: dockBeforeOpen, where: {
            stringAttribute($0, "AXIdentifier") == "mc"
        }) == nil else { return false }

        let opened = await MainActor.run {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            )
        }
        guard opened else { return false }
        let originalCursor = CGEvent(source: nil)?.location
        defer {
            postKey(53)
            if let originalCursor { moveMouse(to: originalCursor) }
        }
        return performDrag(
            request, dockPID: dockPID,
            sourceDisplayID: sourceDisplayID,
            destinationDisplayID: destinationDisplayID
        )
    }

    private func performDrag(
        _ request: SpaceRelocation,
        dockPID: pid_t,
        sourceDisplayID: CGDirectDisplayID,
        destinationDisplayID: CGDirectDisplayID
    ) -> Bool {
        Thread.sleep(forTimeInterval: openDelay)

        let collapsedRoot = AXUIElementCreateApplication(dockPID)
        guard let collapsedSource = spacesList(in: collapsedRoot, displayID: sourceDisplayID),
              let collapsedFrame = frame(of: collapsedSource) else { return false }
        moveMouse(to: CGPoint(x: collapsedFrame.midX, y: collapsedFrame.minY + 10))
        Thread.sleep(forTimeInterval: hoverDelay)

        let expandedRoot = AXUIElementCreateApplication(dockPID)
        guard let sourceList = spacesList(in: expandedRoot, displayID: sourceDisplayID),
              let destinationList = spacesList(
                in: expandedRoot, displayID: destinationDisplayID
              ),
              let sourceItems: [AXUIElement] = attribute(sourceList, kAXChildrenAttribute),
              let destinationItems: [AXUIElement] = attribute(
                destinationList, kAXChildrenAttribute
              ),
              sourceItems.count == request.expectedSourceCount,
              destinationItems.count == request.expectedDestinationCount,
              sourceItems.indices.contains(request.sourceLocalOrder - 1),
              let destinationFrame = frame(of: destinationList),
              let lastDestinationFrame = destinationItems.last.flatMap({ frame(of: $0) })
        else { return false }

        let source = sourceItems[request.sourceLocalOrder - 1]
        guard actionNames(source).contains("AXRemoveDesktop"),
              let sourceFrame = frame(of: source) else { return false }

        // ponytail: 검증된 A→B→A 시나리오는 destination tail drop이면 순서를 보존했다.
        // 중간 삽입이 필요한 실기기 사례가 생기면 local-order drop zone을 추가한다.
        let endX = min(
            lastDestinationFrame.maxX + min(40, lastDestinationFrame.width / 3),
            destinationFrame.maxX - 40
        )
        guard endX > lastDestinationFrame.maxX else { return false }
        let start = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        let end = CGPoint(x: endX, y: lastDestinationFrame.midY)

        var mouseIsDown = false
        defer {
            if mouseIsDown { postMouse(.leftMouseUp, at: end) }
        }
        moveMouse(to: start)
        Thread.sleep(forTimeInterval: 0.2)
        postMouse(.leftMouseDown, at: start)
        mouseIsDown = true
        Thread.sleep(forTimeInterval: 0.2)
        for step in 1...30 {
            let progress = CGFloat(step) / 30
            postMouse(.leftMouseDragged, at: CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            ))
            usleep(20_000)
        }
        Thread.sleep(forTimeInterval: 0.4)
        postMouse(.leftMouseUp, at: end)
        mouseIsDown = false
        Thread.sleep(forTimeInterval: dropDelay)
        return true
    }

    private func displayID(for screenID: String) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { displayID in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            else { return false }
            return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String)?.uuidString
                == UUID(uuidString: screenID)?.uuidString
        }
    }

    private func spacesList(
        in root: AXUIElement, displayID: CGDirectDisplayID
    ) -> AXUIElement? {
        guard let display = firstDescendant(of: root, where: {
            stringAttribute($0, "AXIdentifier") == "mc.display"
                && (attribute($0, "AXDisplayID") as NSNumber?)?.uint32Value == displayID
        }) else { return nil }
        return firstDescendant(of: display, where: {
            stringAttribute($0, "AXIdentifier") == "mc.spaces.list"
        })
    }

    private func firstDescendant(
        of element: AXUIElement, depth: Int = 0,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard depth <= 12 else { return nil }
        if matches(element) { return element }
        guard let children: [AXUIElement] = attribute(element, kAXChildrenAttribute)
        else { return nil }
        for child in children {
            if let match = firstDescendant(of: child, depth: depth + 1, where: matches) {
                return match
            }
        }
        return nil
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, name as CFString, &value
        ) == .success else { return nil }
        return value as? T
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position: CFTypeRef = attribute(element, kAXPositionAttribute),
              let sizeValue: CFTypeRef = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func postKey(_ code: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?
                .post(tap: .cghidEventTap)
        }
    }

    private func moveMouse(to point: CGPoint) { postMouse(.mouseMoved, at: point) }

    private func postMouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}
