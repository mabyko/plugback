import Foundation

/// 창 확인·잠금 판정 실패 사례의 로컬 기록 (3.9절). 최근 100건을 보관하고 사용자가 내보낼 때만 파일로 제공한다.
/// 창 제목·탭 URL·문서 내용·화면 캡처·세션 사전 원문은 넣지 않는다. 자동 원격 전송은 없다.
/// 기록 실패는 저장본이나 복원 결과를 바꾸지 않는다.
public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public var date: Date
    public var kind: String
    public var reason: String
    public var bundleID: String?
    public var appVersion: String?
    public var requestOrigin: String?
    public var savedWindowCount: Int?
    public var observedWindowCount: Int?
    public var candidateCount: Int?
    public var screenCount: Int?
    public var spaceObservation: String?
    public var plugbackVersion: String?
    public var macOSVersion: String

    public init(date: Date = Date(), kind: String, reason: String, bundleID: String? = nil,
                appVersion: String? = nil, requestOrigin: String? = nil, savedWindowCount: Int? = nil,
                observedWindowCount: Int? = nil, candidateCount: Int? = nil, screenCount: Int? = nil,
                spaceObservation: String? = nil, plugbackVersion: String? = nil,
                macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.date = date; self.kind = kind; self.reason = reason; self.bundleID = bundleID
        self.appVersion = appVersion; self.requestOrigin = requestOrigin
        self.savedWindowCount = savedWindowCount; self.observedWindowCount = observedWindowCount
        self.candidateCount = candidateCount; self.screenCount = screenCount
        self.spaceObservation = spaceObservation; self.plugbackVersion = plugbackVersion
        self.macOSVersion = macOSVersion
    }
}

@MainActor
public final class DiagnosticsLog: ObservableObject {
    @Published public private(set) var events: [DiagnosticEvent] = []
    private let fileURL: URL?
    private let limit: Int
    /// 같은 요청·저장 창의 반복 관찰을 별개 사례로 늘리지 않는다.
    private var seenKeys: Set<String> = []

    public init(directory: URL?, limit: Int = 100) {
        self.limit = limit
        fileURL = directory?.appendingPathComponent("diagnostics.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder.plugback.decode([DiagnosticEvent].self, from: data) {
            events = Array(stored.suffix(limit))
        }
    }

    public func record(_ event: DiagnosticEvent, dedupKey: String? = nil) {
        if let dedupKey {
            guard seenKeys.insert(dedupKey).inserted else { return }
        }
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder.plugback.encode(events).write(to: fileURL, options: .atomic)
    }

    /// 사용자가 고른 위치로 내보낸다. 실패는 호출자에게 던진다 — 조용히 성공한 척하지 않는다.
    public func export(to url: URL) throws {
        try JSONEncoder.plugback.encode(events).write(to: url, options: .atomic)
    }
}
