#if DEBUG
import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import PlugbackKit

/// PROTOTYPE: Mission Control Space read-only 실기기 게이트. 제품 경로에서 호출하지 않는다.
/// `--space-probe`는 한 번 읽고 종료하고, `--space-probe-watch`는 Space 변경마다 JSON을 출력한다.
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
    static let isRequested = isReaderRequested || isWatchRequested
        || ProcessInfo.processInfo.arguments.contains("--space-probe")

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
