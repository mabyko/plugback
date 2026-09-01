#if DEBUG
import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import ObjectiveC
import PlugbackKit

/// PROTOTYPE: Space read와 빈 희생 Space 왕복 실기기 게이트. 제품 경로에서 호출하지 않는다.
/// read/watch는 조회만 하고, `--space-relocation-probe`의 명시적 확인 뒤에만 A→B→A를
/// 한 번 수행한다.
@MainActor
final class SpaceProbeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SpaceProbe.isRequested else { return }
        if SpaceProbe.isWatchRequested {
            SpaceProbe.startWatching()
        } else {
            SpaceProbe.runAndTerminate()
        }
    }
}

@MainActor
enum SpaceProbe {
    static let isReaderRequested = ProcessInfo.processInfo.arguments.contains("--space-reader-probe")
    static let isWatchRequested = ProcessInfo.processInfo.arguments.contains("--space-probe-watch")
    static let isRelocationRequested = ProcessInfo.processInfo.arguments.contains(
        "--space-relocation-probe"
    )
    static let isRequested = isReaderRequested || isWatchRequested
        || isRelocationRequested || ProcessInfo.processInfo.arguments.contains("--space-probe")

    private static var spaceObserver: NSObjectProtocol?
    private static var notificationSequence = 0

    /// Scene의 타입을 바꾸지 않기 위한 무영속 자리 채움. watcher·권한 요청·로그인 등록은 시작하지 않는다.
    static let placeholderController: PlugbackController = {
        let nonce = UUID().uuidString
        let defaults = UserDefaults(suiteName: "plugback-space-probe-\(nonce)")!
        let store = ProfileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("plugback-space-probe-\(nonce)", isDirectory: true))
        return PlugbackController(
            gateway: AXWindowGateway(),
            screenProvider: SystemScreenProvider(),
            store: store,
            defaults: defaults
        )
    }()

    static func runAndTerminate() {
        if isRelocationRequested {
            Task { await runRelocationAndTerminate() }
            return
        }
        if isReaderRequested {
            Task { await runReaderAndTerminate() }
            return
        }
        writeReport(trigger: "launch", notificationSequence: nil)
        NSApp.terminate(nil)
    }

    private static func runReaderAndTerminate() async {
        let windows = await AXWindowGateway().standardWindows(of: nil)
        let windowIDs = windows.compactMap(\.windowServerID)
        let result = await SpaceReader().stableSnapshot(windowServerIDs: windowIDs)
        let report: ReaderProbeReport
        switch result {
        case .unavailable:
            report = ReaderProbeReport(
                available: false, publicScreenCount: 0, mappedDisplayCount: 0,
                standardWindowCount: windows.count, joinedWindowCount: windowIDs.count,
                spaceKinds: [:], membershipCounts: [:], fullscreenStates: fullscreenCounts(windows)
            )
        case .available(let snapshot):
            let screenIDs = Set(SystemScreenProvider().screens().map(\.id))
            var spaceKinds: [String: Int] = [:]
            for space in snapshot.displays.flatMap(\.spaces) {
                let key = switch space.kind {
                case .regular: "regular"
                case .fullscreen: "fullscreen"
                case .unknown: "unknown"
                }
                spaceKinds[key, default: 0] += 1
            }
            var membershipCounts: [String: Int] = [:]
            for windowID in windowIDs {
                let count = snapshot.membershipsByWindowServerID[windowID, default: []].count
                membershipCounts[count == 0 ? "zero" : (count == 1 ? "one" : "many"), default: 0] += 1
            }
            report = ReaderProbeReport(
                available: true,
                publicScreenCount: screenIDs.count,
                mappedDisplayCount: snapshot.displays.filter { screenIDs.contains($0.screenID) }.count,
                standardWindowCount: windows.count,
                joinedWindowCount: windowIDs.count,
                spaceKinds: spaceKinds,
                membershipCounts: membershipCounts,
                fullscreenStates: fullscreenCounts(windows)
            )
        }
        write(report)
        NSApp.terminate(nil)
    }

    private static func runRelocationAndTerminate() async {
        let report: RelocationProbeReport
        do {
            let request = try RelocationProbeRequest.parse(ProcessInfo.processInfo.arguments)
            report = try await performRelocationProbe(request)
        } catch {
            report = RelocationProbeReport(
                schema: 1,
                outcome: "rejected-before-write",
                osBuild: kernelBuild(),
                spaceToken: nil,
                destinationDisplayToken: nil,
                movedExactly: false,
                rollbackAttempted: false,
                restoredExactly: false,
                dockUnchanged: nil,
                before: nil,
                afterMove: nil,
                afterRollback: nil,
                errors: [error.localizedDescription]
            )
        }
        write(report)
        NSApp.terminate(nil)
    }

    private static func performRelocationProbe(
        _ request: RelocationProbeRequest
    ) async throws -> RelocationProbeReport {
        let build = kernelBuild()
        guard build == "25G83" else {
            throw RelocationProbeError(message: "unsupported macOS build \(build ?? "unknown")")
        }
        guard NSScreen.screensHaveSeparateSpaces else {
            throw RelocationProbeError(message: "Displays have separate Spaces is disabled")
        }
        let originalDockPID = try closedDockPID()
        let bridge = try SkyLightRelocationBridge()
        try bridge.verifyReadOperation()
        let api = PrivateAPI()
        let before = try await stableRelocationTopology(api: api)
        let plan = try RelocationProbeValidator.plan(request: request, topology: before)
        guard try closedDockPID() == originalDockPID else {
            throw RelocationProbeError(message: "Dock changed during preflight")
        }
        guard bridge.move(
            spaceID: plan.spaceID,
            displayIdentifier: plan.destinationIdentifier,
            index: UInt32(plan.destinationIndex)
        ) else {
            throw RelocationProbeError(message: "SkyLight move operation could not be dispatched")
        }

        let afterMove = await observeRelocation(after: before, api: api)
        var errors = afterMove.error.map { [$0] } ?? []
        var rollbackAttempted = false
        var afterRollback: RelocationObservation?
        if targetDisplayIdentifier(spaceID: plan.spaceID, in: afterMove.topology)
            == plan.destinationIdentifier {
            rollbackAttempted = true
            if bridge.move(
                spaceID: plan.spaceID,
                displayIdentifier: plan.sourceIdentifier,
                index: UInt32(plan.sourceIndex)
            ) {
                afterRollback = await observeRelocation(
                    after: afterMove.topology ?? plan.expectedMoved,
                    api: api
                )
                if let error = afterRollback?.error { errors.append(error) }
            } else {
                errors.append("rollback operation could not be dispatched")
            }
        } else {
            errors.append("target Space was not observed on the destination; rollback was not guessed")
        }

        let finalDockPID = try? closedDockPID()
        let dockUnchanged = finalDockPID == originalDockPID
        if !dockUnchanged { errors.append("Dock changed or Mission Control opened during the probe") }
        let movedExactly = afterMove.stable && afterMove.topology == plan.expectedMoved
        if afterMove.stable && !movedExactly {
            errors.append("stable destination topology did not match the single-Space move")
        }
        let restoredExactly = rollbackAttempted && afterRollback?.stable == true
            && afterRollback?.topology == before && dockUnchanged
        if afterRollback?.stable == true && afterRollback?.topology != before {
            errors.append("stable rollback topology did not match the baseline")
        }
        let outcome = movedExactly && restoredExactly
            ? "passed"
            : (restoredExactly ? "unexpected-move-restored" : "failed")
        return RelocationProbeReport(
            schema: 1,
            outcome: outcome,
            osBuild: build,
            spaceToken: request.spaceToken,
            destinationDisplayToken: request.destinationDisplayToken,
            movedExactly: movedExactly,
            rollbackAttempted: rollbackAttempted,
            restoredExactly: restoredExactly,
            dockUnchanged: dockUnchanged,
            before: redact(before),
            afterMove: afterMove.topology.map(redact),
            afterRollback: afterRollback?.topology.map(redact),
            errors: errors
        )
    }

    static func startWatching() {
        writeReport(trigger: "launch", notificationSequence: nil)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { _ in
            Task { @MainActor in
                notificationSequence += 1
                writeReport(
                    trigger: "activeSpaceDidChange",
                    notificationSequence: notificationSequence
                )
            }
        }
    }

    private static func writeReport(trigger: String, notificationSequence: Int?) {
        let report = makeReport(trigger: trigger, notificationSequence: notificationSequence)
        write(report)
    }

    private static func write<T: Encodable>(_ report: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(report) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("Space probe report encoding failed\n".utf8))
        }
    }

    private static func fullscreenCounts(_ windows: [WindowInfo]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for window in windows {
            let key = switch window.fullscreenState {
            case .windowed: "windowed"
            case .fullscreen: "fullscreen"
            case .unknown: "unknown"
            }
            counts[key, default: 0] += 1
        }
        return counts
    }

    private static func stableRelocationTopology(
        api: PrivateAPI
    ) async throws -> RelocationTopology {
        var previous: RelocationTopology?
        var lastError: Error?
        for attempt in 0..<12 {
            do {
                let current = try readRelocationTopology(api: api)
                if current == previous { return current }
                previous = current
            } catch {
                previous = nil
                lastError = error
            }
            if attempt < 11 { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        throw lastError ?? RelocationProbeError(message: "Space topology did not stabilize")
    }

    private static func observeRelocation(
        after baseline: RelocationTopology,
        api: PrivateAPI
    ) async -> RelocationObservation {
        var previous: RelocationTopology?
        var last: RelocationTopology?
        var sawChange = false
        var lastReadError: String?
        for attempt in 0..<32 {
            do {
                let current = try readRelocationTopology(api: api)
                last = current
                if current != baseline { sawChange = true }
                if sawChange, current == previous {
                    return RelocationObservation(topology: current, stable: true, error: nil)
                }
                previous = current
            } catch {
                previous = nil
                lastReadError = error.localizedDescription
            }
            if attempt < 31 { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        let message = sawChange
            ? "changed Space topology did not stabilize within 8 seconds"
            : "no Space topology change was observed within 8 seconds"
        return RelocationObservation(
            topology: last,
            stable: false,
            error: [message, lastReadError].compactMap { $0 }.joined(separator: "; ")
        )
    }

    private static func readRelocationTopology(api: PrivateAPI) throws -> RelocationTopology {
        guard let mainConnection = api.mainConnection,
              let copyManagedDisplaySpaces = api.copyManagedDisplaySpaces,
              let copySpacesForWindows = api.copySpacesForWindows,
              let spaceType = api.spaceType,
              let spaceName = api.spaceName,
              let currentSpace = api.currentSpace else {
            throw RelocationProbeError(message: "required read-only SkyLight symbols are unavailable")
        }
        let connection = mainConnection()
        guard let managed = copyManagedDisplaySpaces(connection)?.takeRetainedValue() else {
            throw RelocationProbeError(message: "managed display Space snapshot is unavailable")
        }

        var displays: [RelocationTopology.Display] = []
        for case let display as NSDictionary in managed as NSArray {
            guard let identifier = display["Display Identifier"] as? String,
                  let rawSpaces = display["Spaces"] as? [Any] else {
                throw RelocationProbeError(message: "unexpected managed display dictionary shape")
            }
            let current = currentSpace(connection, identifier as CFString)
            var spaces: [RelocationTopology.Space] = []
            for item in rawSpaces {
                guard let dictionary = item as? NSDictionary,
                      let id = number(dictionary["id64"])
                        ?? number(dictionary["ManagedSpaceID"]) else {
                    throw RelocationProbeError(message: "Space dictionary is missing an ID")
                }
                let copiedName = spaceName(connection, id)?.takeRetainedValue()
                spaces.append(.init(
                    id: id,
                    token: token("sid:\(id)"),
                    name: copiedName as String?,
                    type: spaceType(connection, id),
                    isCurrent: current == id
                ))
            }
            displays.append(.init(
                identifier: identifier,
                token: token(identifier),
                spaces: spaces
            ))
        }

        guard let rawNumbers = NSWindow.windowNumbers(options: [.allApplications, .allSpaces]) else {
            throw RelocationProbeError(message: "all-Spaces WindowServer window list is unavailable")
        }
        let allWindowIDs = try Set(rawNumbers.map { value -> UInt32 in
            guard let id = UInt32(exactly: value.uint64Value) else {
                throw RelocationProbeError(message: "WindowServer window ID is outside UInt32")
            }
            return id
        })
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else {
            throw RelocationProbeError(message: "WindowServer window metadata is unavailable")
        }
        var layersByWindowID: [UInt32: Int] = [:]
        for row in windowInfo {
            guard let number = row[kCGWindowNumber as String] as? NSNumber,
                  let id = UInt32(exactly: number.uint64Value),
                  let layer = row[kCGWindowLayer as String] as? NSNumber else { continue }
            layersByWindowID[id] = layer.intValue
        }
        let windowIDs = try RelocationProbeValidator.blockingWindowIDs(
            from: layersByWindowID, allWindowIDs: allWindowIDs
        )
        var memberships: [UInt32: [UInt64]] = [:]
        for windowID in windowIDs.sorted() {
            let windows = [NSNumber(value: windowID)] as CFArray
            guard let copied = copySpacesForWindows(connection, 0x7, windows)?.takeRetainedValue()
            else {
                throw RelocationProbeError(message: "window Space membership is unavailable")
            }
            let values = copied as NSArray
            let ids = try values.map { value -> UInt64 in
                guard let id = number(value) else {
                    throw RelocationProbeError(message: "window Space membership is malformed")
                }
                return id
            }
            memberships[windowID] = Array(Set(ids)).sorted()
        }
        return RelocationTopology(displays: displays, membershipsByWindowID: memberships)
    }

    private static func closedDockPID() throws -> pid_t {
        guard AXIsProcessTrusted() else {
            throw RelocationProbeError(message: "Accessibility permission is required")
        }
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock" && !$0.isTerminated
        }) else {
            throw RelocationProbeError(message: "Dock is unavailable")
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let children: [AXUIElement] = axCopy(application, kAXChildrenAttribute) else {
            throw RelocationProbeError(message: "Dock accessibility tree is unavailable")
        }
        guard !children.contains(where: { containsAXIdentifier($0, "mc") }) else {
            throw RelocationProbeError(message: "Mission Control must be closed")
        }
        return dock.processIdentifier
    }

    private static func containsAXIdentifier(
        _ element: AXUIElement, _ identifier: String, depth: Int = 0
    ) -> Bool {
        guard depth <= 12 else { return false }
        let value: String? = axCopy(element, "AXIdentifier")
        if value == identifier { return true }
        let children: [AXUIElement] = axCopy(element, kAXChildrenAttribute) ?? []
        return children.contains { containsAXIdentifier($0, identifier, depth: depth + 1) }
    }

    private static func targetDisplayIdentifier(
        spaceID: UInt64, in topology: RelocationTopology?
    ) -> String? {
        guard let topology else { return nil }
        let matches = topology.displays.compactMap { display in
            display.spaces.contains(where: { $0.id == spaceID }) ? display.identifier : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func redact(_ topology: RelocationTopology) -> RelocationTopologyReport {
        RelocationTopologyReport(displays: topology.displays.map { display in
            .init(displayToken: display.token, spaces: display.spaces.enumerated().map { index, space in
                .init(
                    localIndex: index,
                    spaceToken: space.token,
                    nameToken: space.name.map { token("name:\($0)") },
                    type: space.type,
                    isCurrent: space.isCurrent,
                    windowCount: topology.membershipsByWindowID.values.filter {
                        $0.contains(space.id)
                    }.count
                )
            })
        })
    }

    private static func kernelBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes {
            sysctlbyname("kern.osversion", $0.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func makeReport(
        trigger: String,
        notificationSequence: Int?
    ) -> ProbeReport {
        let api = PrivateAPI()
        var errors: [String] = []
        let screens = SystemScreenProvider().screens()
        let screenKinds = Dictionary(uniqueKeysWithValues: screens.map {
            (normalizeUUID($0.id), $0.isBuiltin ? "builtin" : "external")
        })
        let publicScreens = screens.map {
            PublicScreen(token: token($0.id), kind: $0.isBuiltin ? "builtin" : "external")
        }
        let rawWindowIDs = (NSWindow.windowNumbers(
            options: [.allApplications, .allSpaces]
        ) ?? []).compactMap { UInt32(exactly: $0.uint64Value) }

        let connection = api.mainConnection?()
        if connection == nil { errors.append("SLSMainConnectionID unavailable") }
        let rawWindows = readAXWindows(api: api)
        let first = readSnapshot(api: api, connection: connection, screenKinds: screenKinds,
                                 rawWindows: rawWindows, rawWindowIDs: rawWindowIDs, errors: &errors)
        let second = readSnapshot(api: api, connection: connection, screenKinds: screenKinds,
                                  rawWindows: rawWindows, rawWindowIDs: rawWindowIDs, errors: &errors)

        let stability = Stability(
            topologyEqual: first.displays == second.displays,
            membershipEqual: first.windows.map(\.memberships) == second.windows.map(\.memberships),
            identical: first == second
        )
        return ProbeReport(
            schema: 1,
            trigger: trigger,
            notificationSequence: notificationSequence,
            capturedAt: Date(),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            bundleToken: token(Bundle.main.bundleIdentifier ?? "missing"),
            screensHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces,
            accessibilityTrusted: AXIsProcessTrusted(),
            publicScreens: publicScreens,
            allSpacesRawWindowCount: rawWindowIDs.count,
            symbols: api.symbols,
            first: first,
            second: second,
            stability: stability,
            errors: Array(Set(errors)).sorted()
        )
    }

    private static func readAXWindows(api: PrivateAPI) -> [RawWindow] {
        guard AXIsProcessTrusted() else { return [] }
        var result: [RawWindow] = []
        var fallbackID = 0
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            guard let windows: [AXUIElement] = axCopy(appElement, kAXWindowsAttribute) else { continue }
            for element in windows {
                AXUIElementSetMessagingTimeout(element, 0.25)
                guard let subrole: String = axCopy(element, kAXSubroleAttribute),
                      subrole == kAXStandardWindowSubrole as String else { continue }
                fallbackID += 1
                var windowID: UInt32 = 0
                let joined = api.axWindowID?(element, &windowID) == .success
                result.append(RawWindow(
                    appToken: token(app.bundleIdentifier ?? "pid:\(app.processIdentifier)"),
                    windowToken: joined ? token("window:\(windowID)") : "unjoined-\(fallbackID)",
                    windowID: joined ? windowID : nil,
                    frameReadable: axFrameReadable(element),
                    fullscreen: axFullscreen(element)
                ))
            }
        }
        return result.sorted {
            ($0.appToken, $0.windowToken) < ($1.appToken, $1.windowToken)
        }
    }

    private static func readSnapshot(
        api: PrivateAPI,
        connection: Int32?,
        screenKinds: [String: String],
        rawWindows: [RawWindow],
        rawWindowIDs: [UInt32],
        errors: inout [String]
    ) -> ProbeSnapshot {
        guard let connection,
              let copyManagedDisplaySpaces = api.copyManagedDisplaySpaces,
              let managed = copyManagedDisplaySpaces(connection)?.takeRetainedValue()
        else {
            errors.append("managed display Space snapshot unavailable")
            return ProbeSnapshot(displays: [], windows: rawWindows.map {
                WindowObservation(raw: $0, memberships: [])
            })
        }

        var displays: [DisplayObservation] = []
        var spacesByID: [UInt64: SpaceMeta] = [:]
        let rawWindowCounts = membershipCounts(
            api: api, connection: connection, windowIDs: rawWindowIDs
        )
        var globalOrder = 0
        for case let display as NSDictionary in managed as NSArray {
            guard let identifier = display["Display Identifier"] as? String,
                  let rawSpaces = display["Spaces"] as? [Any] else {
                errors.append("unexpected managed display dictionary shape")
                continue
            }
            let normalized = normalizeUUID(identifier)
            let displayToken = token(identifier)
            let current = api.currentSpace?(connection, identifier as CFString)
            var observations: [SpaceObservation] = []
            for (index, item) in rawSpaces.enumerated() {
                guard let dictionary = item as? NSDictionary,
                      let sid = number(dictionary["id64"]) ?? number(dictionary["ManagedSpaceID"])
                else {
                    errors.append("Space dictionary missing numeric ID")
                    continue
                }
                globalOrder += 1
                let type = api.spaceType?(connection, sid)
                let name = api.spaceName?(connection, sid)?.takeRetainedValue() as String?
                let state = name == nil ? "nil" : (name!.isEmpty ? "empty" : "nonEmpty")
                let meta = SpaceMeta(
                    sidToken: token("sid:\(sid)"),
                    type: type,
                    isCurrent: current == sid
                )
                spacesByID[sid] = meta
                observations.append(SpaceObservation(
                    localOrder: index + 1,
                    globalOrder: globalOrder,
                    sidToken: meta.sidToken,
                    type: type,
                    nameState: state,
                    nameToken: name.flatMap { $0.isEmpty ? nil : token("name:\($0)") },
                    isCurrent: meta.isCurrent,
                    rawWindowCount: rawWindowCounts[sid, default: 0]
                ))
            }
            displays.append(DisplayObservation(
                displayToken: displayToken,
                kind: screenKinds[normalized] ?? "unknown",
                spaces: observations
            ))
        }

        let windows = rawWindows.map { raw -> WindowObservation in
            guard let windowID = raw.windowID,
                  let copySpaces = api.copySpacesForWindows else {
                return WindowObservation(raw: raw, memberships: [])
            }
            let list = [NSNumber(value: windowID)] as CFArray
            let rawMemberships = copySpaces(connection, 0x7, list)?.takeRetainedValue()
            let ids = (rawMemberships as NSArray?)?.compactMap { number($0) } ?? []
            let memberships = ids.map { sid -> Membership in
                let meta = spacesByID[sid]
                return Membership(
                    sidToken: meta?.sidToken ?? token("sid:\(sid)"),
                    type: meta?.type,
                    location: meta == nil ? "unknown" : (meta!.isCurrent ? "current" : "inactive")
                )
            }.sorted { $0.sidToken < $1.sidToken }
            return WindowObservation(raw: raw, memberships: memberships)
        }
        return ProbeSnapshot(displays: displays, windows: windows)
    }

    private static func membershipCounts(
        api: PrivateAPI, connection: Int32, windowIDs: [UInt32]
    ) -> [UInt64: Int] {
        guard let copySpaces = api.copySpacesForWindows else { return [:] }
        var counts: [UInt64: Int] = [:]
        for windowID in windowIDs {
            let list = [NSNumber(value: windowID)] as CFArray
            let memberships = copySpaces(connection, 0x7, list)?.takeRetainedValue()
            let ids = Set((memberships as NSArray?)?.compactMap { number($0) } ?? [])
            for sid in ids { counts[sid, default: 0] += 1 }
        }
        return counts
    }

    private static func number(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func normalizeUUID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased()
    }

    private static func token(_ value: String) -> String {
        SHA256.hash(data: Data(("plugback-space-probe-v1:" + value).utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func axCopy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? T
    }

    private static func axFrameReadable(_ element: AXUIElement) -> Bool {
        guard let position: CFTypeRef = axCopy(element, kAXPositionAttribute),
              let size: CFTypeRef = axCopy(element, kAXSizeAttribute) else { return false }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        return AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            && AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    }

    private static func axFullscreen(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success,
              let fullscreen = value as? Bool else { return "nil" }
        return fullscreen ? "true" : "false"
    }
}

struct RelocationProbeError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

struct RelocationProbeRequest: Equatable {
    let spaceToken: String
    let destinationDisplayToken: String

    static func parse(_ arguments: [String]) throws -> Self {
        let values = Array(arguments.dropFirst())
        guard values.count == 4,
              values[0] == "--space-relocation-probe",
              values[3] == "--confirm-empty-sacrificial-space" else {
            throw RelocationProbeError(message:
                "usage: --space-relocation-probe <space-token> <display-token> "
                + "--confirm-empty-sacrificial-space")
        }
        let tokens = values[1...2].map { $0.lowercased() }
        guard tokens.allSatisfy({ token in
            token.count == 12 && token.allSatisfy(\.isHexDigit)
        }) else {
            throw RelocationProbeError(message: "probe tokens must be 12 hexadecimal characters")
        }
        return Self(spaceToken: tokens[0], destinationDisplayToken: tokens[1])
    }
}

struct RelocationTopology: Equatable {
    struct Display: Equatable {
        let identifier: String
        let token: String
        var spaces: [Space]
    }

    struct Space: Equatable {
        let id: UInt64
        let token: String
        let name: String?
        let type: Int32
        let isCurrent: Bool
    }

    var displays: [Display]
    let membershipsByWindowID: [UInt32: [UInt64]]

    func moving(spaceID: UInt64, toDisplayIdentifier identifier: String, index: Int) -> Self? {
        let locations = displays.indices.flatMap { displayIndex in
            displays[displayIndex].spaces.indices.compactMap { spaceIndex in
                displays[displayIndex].spaces[spaceIndex].id == spaceID
                    ? (displayIndex, spaceIndex) : nil
            }
        }
        guard locations.count == 1,
              let destinationIndex = displays.firstIndex(where: { $0.identifier == identifier }),
              locations[0].0 != destinationIndex,
              index >= 0, index <= displays[destinationIndex].spaces.count else { return nil }
        var copy = self
        let source = locations[0]
        let space = copy.displays[source.0].spaces.remove(at: source.1)
        copy.displays[destinationIndex].spaces.insert(space, at: index)
        return copy
    }
}

struct RelocationProbePlan {
    let spaceID: UInt64
    let sourceIdentifier: String
    let sourceIndex: Int
    let destinationIdentifier: String
    let destinationIndex: Int
    let expectedMoved: RelocationTopology
}

enum RelocationProbeValidator {
    static func blockingWindowIDs(
        from layersByWindowID: [UInt32: Int], allWindowIDs: Set<UInt32>
    ) throws -> Set<UInt32> {
        guard allWindowIDs.isSubset(of: Set(layersByWindowID.keys)) else {
            throw RelocationProbeError(message: "WindowServer window metadata is incomplete")
        }
        return Set(allWindowIDs.filter { layersByWindowID[$0] == 0 })
    }

    static func plan(
        request: RelocationProbeRequest,
        topology: RelocationTopology
    ) throws -> RelocationProbePlan {
        let displays = topology.displays
        guard Set(displays.map(\.identifier)).count == displays.count,
              Set(displays.map(\.token)).count == displays.count,
              displays.allSatisfy({ !$0.identifier.isEmpty && !$0.token.isEmpty }) else {
            throw RelocationProbeError(message: "display topology is ambiguous")
        }
        let spaces = displays.flatMap(\.spaces)
        guard Set(spaces.map(\.id)).count == spaces.count,
              Set(spaces.map(\.token)).count == spaces.count else {
            throw RelocationProbeError(message: "Space topology is ambiguous")
        }
        guard displays.allSatisfy({ $0.spaces.filter(\.isCurrent).count == 1 }) else {
            throw RelocationProbeError(message: "each display must have exactly one current Space")
        }

        let matches = displays.indices.flatMap { displayIndex in
            displays[displayIndex].spaces.indices.compactMap { spaceIndex in
                displays[displayIndex].spaces[spaceIndex].token == request.spaceToken
                    ? (displayIndex, spaceIndex) : nil
            }
        }
        guard matches.count == 1 else {
            throw RelocationProbeError(message: "sacrificial Space token is missing or ambiguous")
        }
        let source = matches[0]
        let sourceDisplay = displays[source.0]
        let target = sourceDisplay.spaces[source.1]
        guard target.type == 0, !target.isCurrent else {
            throw RelocationProbeError(message: "sacrificial Space must be inactive type 0")
        }
        guard let name = target.name, !name.isEmpty,
              spaces.filter({ $0.name == name }).count == 1 else {
            throw RelocationProbeError(message: "sacrificial Space must have a unique opaque name")
        }
        guard !topology.membershipsByWindowID.values.contains(where: {
            $0.contains(target.id)
        }) else {
            throw RelocationProbeError(message: "sacrificial Space contains a window")
        }
        let regularIndices = sourceDisplay.spaces.indices.filter {
            sourceDisplay.spaces[$0].type == 0
        }
        guard regularIndices.count > 1, regularIndices.last == source.1 else {
            throw RelocationProbeError(message:
                "sacrificial Space must be the source display's final regular Space")
        }

        let destinations = displays.indices.filter {
            displays[$0].token == request.destinationDisplayToken
        }
        guard destinations.count == 1, destinations[0] != source.0 else {
            throw RelocationProbeError(message: "destination display is missing, ambiguous, or unchanged")
        }
        let destination = displays[destinations[0]]
        guard source.1 <= Int(UInt32.max), destination.spaces.count <= Int(UInt32.max),
              let expected = topology.moving(
                  spaceID: target.id,
                  toDisplayIdentifier: destination.identifier,
                  index: destination.spaces.count
              ) else {
            throw RelocationProbeError(message: "Space index is outside the bridge ABI")
        }
        return RelocationProbePlan(
            spaceID: target.id,
            sourceIdentifier: sourceDisplay.identifier,
            sourceIndex: source.1,
            destinationIdentifier: destination.identifier,
            destinationIndex: destination.spaces.count,
            expectedMoved: expected
        )
    }

}

private struct RelocationObservation {
    let topology: RelocationTopology?
    let stable: Bool
    let error: String?
}

private struct SkyLightRelocationBridge {
    private typealias AllocFn =
        @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias InitFn =
        @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias InitMoveFn =
        @convention(c) (AnyObject, Selector, UInt64, AnyObject, UInt32)
        -> Unmanaged<AnyObject>?
    private typealias SyncPerformFn =
        @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias AsyncPerformFn =
        @convention(c) (AnyObject, Selector) -> Void

    private let send: UnsafeMutableRawPointer
    private let readClass: AnyClass
    private let moveClass: AnyClass
    private let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")

    init() throws {
        guard dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ) != nil,
        let send = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend"),
        let readClass = NSClassFromString("SLSBridgedCopyManagedDisplaySpacesOperation"),
        let moveClass = NSClassFromString("SLSBridgedMoveManagedSpaceToDisplayIndexOperation")
        else {
            throw RelocationProbeError(message: "SkyLight AppKit bridge is unavailable")
        }
        try Self.requireEncoding(readClass, "init", "@16@0:8")
        try Self.requireEncoding(
            readClass, "performWithWMBridgeDelegate", "@16@0:8"
        )
        try Self.requireEncoding(
            moveClass, "initWithSpaceID:displayIdentifier:index:", "@36@0:8Q16@24I32"
        )
        try Self.requireEncoding(
            moveClass, "performWithWMBridgeDelegate", "v16@0:8"
        )
        self.send = send
        self.readClass = readClass
        self.moveClass = moveClass
    }

    func verifyReadOperation() throws {
        let allocate: AllocFn = sender()
        let initialize: InitFn = sender()
        let perform: SyncPerformFn = sender()
        guard let allocation = allocate(readClass, NSSelectorFromString("alloc")),
              let operation = initialize(
                  allocation.takeUnretainedValue(), NSSelectorFromString("init")
              )?.takeRetainedValue(),
              perform(operation, performSelector)?.takeUnretainedValue() != nil else {
            throw RelocationProbeError(message: "SkyLight read bridge validation failed")
        }
    }

    func move(spaceID: UInt64, displayIdentifier: String, index: UInt32) -> Bool {
        let allocate: AllocFn = sender()
        let initialize: InitMoveFn = sender()
        let perform: AsyncPerformFn = sender()
        guard let allocation = allocate(moveClass, NSSelectorFromString("alloc")),
              let operation = initialize(
                  allocation.takeUnretainedValue(),
                  NSSelectorFromString("initWithSpaceID:displayIdentifier:index:"),
                  spaceID,
                  displayIdentifier as NSString,
                  index
              )?.takeRetainedValue() else { return false }
        perform(operation, performSelector)
        return true
    }

    private func sender<T>() -> T {
        unsafeBitCast(send, to: T.self)
    }

    private static func requireEncoding(
        _ cls: AnyClass, _ selectorName: String, _ expected: String
    ) throws {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, selector),
              let raw = method_getTypeEncoding(method),
              String(cString: raw) == expected else {
            throw RelocationProbeError(message:
                "unexpected SkyLight ABI for \(NSStringFromClass(cls)).\(selectorName)")
        }
    }
}

struct RelocationProbeReport: Codable {
    let schema: Int
    let outcome: String
    let osBuild: String?
    let spaceToken: String?
    let destinationDisplayToken: String?
    let movedExactly: Bool
    let rollbackAttempted: Bool
    let restoredExactly: Bool
    let dockUnchanged: Bool?
    fileprivate let before: RelocationTopologyReport?
    fileprivate let afterMove: RelocationTopologyReport?
    fileprivate let afterRollback: RelocationTopologyReport?
    let errors: [String]
}

private struct RelocationTopologyReport: Codable {
    struct Display: Codable {
        let displayToken: String
        let spaces: [Space]
    }

    struct Space: Codable {
        let localIndex: Int
        let spaceToken: String
        let nameToken: String?
        let type: Int32
        let isCurrent: Bool
        let windowCount: Int
    }

    let displays: [Display]
}

private struct ProbeReport: Codable {
    let schema: Int
    let trigger: String
    let notificationSequence: Int?
    let capturedAt: Date
    let os: String
    let bundleToken: String
    let screensHaveSeparateSpaces: Bool
    let accessibilityTrusted: Bool
    let publicScreens: [PublicScreen]
    let allSpacesRawWindowCount: Int
    let symbols: SymbolAvailability
    let first: ProbeSnapshot
    let second: ProbeSnapshot
    let stability: Stability
    let errors: [String]
}

private struct ReaderProbeReport: Codable {
    let available: Bool
    let publicScreenCount: Int
    let mappedDisplayCount: Int
    let standardWindowCount: Int
    let joinedWindowCount: Int
    let spaceKinds: [String: Int]
    let membershipCounts: [String: Int]
    let fullscreenStates: [String: Int]
}

private struct PublicScreen: Codable { let token: String; let kind: String }

private struct ProbeSnapshot: Codable, Equatable {
    let displays: [DisplayObservation]
    let windows: [WindowObservation]
}

private struct DisplayObservation: Codable, Equatable {
    let displayToken: String
    let kind: String
    let spaces: [SpaceObservation]
}

private struct SpaceObservation: Codable, Equatable {
    let localOrder: Int
    let globalOrder: Int
    let sidToken: String
    let type: Int32?
    let nameState: String
    let nameToken: String?
    let isCurrent: Bool
    let rawWindowCount: Int
}

private struct WindowObservation: Codable, Equatable {
    let appToken: String
    let windowToken: String
    let cgWindowJoined: Bool
    let frameReadable: Bool
    let fullscreen: String
    let memberships: [Membership]

    init(raw: RawWindow, memberships: [Membership]) {
        appToken = raw.appToken
        windowToken = raw.windowToken
        cgWindowJoined = raw.windowID != nil
        frameReadable = raw.frameReadable
        fullscreen = raw.fullscreen
        self.memberships = memberships
    }
}

private struct Membership: Codable, Equatable {
    let sidToken: String
    let type: Int32?
    let location: String
}

private struct Stability: Codable {
    let topologyEqual: Bool
    let membershipEqual: Bool
    let identical: Bool
}

private struct RawWindow {
    let appToken: String
    let windowToken: String
    let windowID: UInt32?
    let frameReadable: Bool
    let fullscreen: String
}

private struct SpaceMeta {
    let sidToken: String
    let type: Int32?
    let isCurrent: Bool
}

private typealias SLSMainConnectionID = @convention(c) () -> Int32
private typealias SLSCopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias SLSCopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias SLSSpaceGetType = @convention(c) (Int32, UInt64) -> Int32
private typealias SLSSpaceCopyName = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
private typealias SLSManagedDisplayGetCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
private typealias AXUIElementGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

private struct PrivateAPI {
    let mainConnection: SLSMainConnectionID?
    let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpaces?
    let copySpacesForWindows: SLSCopySpacesForWindows?
    let spaceType: SLSSpaceGetType?
    let spaceName: SLSSpaceCopyName?
    let currentSpace: SLSManagedDisplayGetCurrentSpace?
    let axWindowID: AXUIElementGetWindow?
    let symbols: SymbolAvailability

    init() {
        let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        )
        let applicationServices = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
            RTLD_LAZY | RTLD_LOCAL
        )
        let hiServices = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/HIServices",
            RTLD_LAZY | RTLD_LOCAL
        )
        mainConnection = Self.load(skyLight, "SLSMainConnectionID", as: SLSMainConnectionID.self)
        copyManagedDisplaySpaces = Self.load(
            skyLight, "SLSCopyManagedDisplaySpaces", as: SLSCopyManagedDisplaySpaces.self
        )
        copySpacesForWindows = Self.load(
            skyLight, "SLSCopySpacesForWindows", as: SLSCopySpacesForWindows.self
        )
        spaceType = Self.load(skyLight, "SLSSpaceGetType", as: SLSSpaceGetType.self)
        spaceName = Self.load(skyLight, "SLSSpaceCopyName", as: SLSSpaceCopyName.self)
        currentSpace = Self.load(
            skyLight, "SLSManagedDisplayGetCurrentSpace", as: SLSManagedDisplayGetCurrentSpace.self
        )
        axWindowID = Self.load(applicationServices, "_AXUIElementGetWindow", as: AXUIElementGetWindow.self)
            ?? Self.load(hiServices, "_AXUIElementGetWindow", as: AXUIElementGetWindow.self)
        symbols = SymbolAvailability(
            skyLightLoaded: skyLight != nil,
            mainConnection: mainConnection != nil,
            managedDisplaySpaces: copyManagedDisplaySpaces != nil,
            spacesForWindows: copySpacesForWindows != nil,
            spaceType: spaceType != nil,
            spaceName: spaceName != nil,
            currentSpace: currentSpace != nil,
            axWindowID: axWindowID != nil
        )
    }

    private static func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private struct SymbolAvailability: Codable {
    let skyLightLoaded: Bool
    let mainConnection: Bool
    let managedDisplaySpaces: Bool
    let spacesForWindows: Bool
    let spaceType: Bool
    let spaceName: Bool
    let currentSpace: Bool
    let axWindowID: Bool
}
#endif
