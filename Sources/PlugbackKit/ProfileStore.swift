import Foundation

/// 프로필 저장소 (F-04.2). 파일 위치·직렬화·손상 복구를 숨긴다.
public final class ProfileStore {
    public struct LoadOutcome {
        public let profiles: [String: Profile]
        /// 파일이 손상되어 백업 후 초기화됐다면 그 백업 위치. 사용자에게 알려야 한다.
        public let corruptionBackupURL: URL?
    }

    private let fileURL: URL

    /// directory 기본값은 ~/Library/Application Support/Plugback
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plugback", isDirectory: true)
        fileURL = base.appendingPathComponent("profiles.json")
    }

    public func load() -> LoadOutcome {
        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadOutcome(profiles: [:], corruptionBackupURL: nil) // 첫 실행
        }
        if let profiles = try? JSONDecoder().decode([String: Profile].self, from: data) {
            return LoadOutcome(profiles: profiles, corruptionBackupURL: nil)
        }
        // 손상 — 백업 후 초기화. 앱은 종료되지 않는다 (F-04.2, US-011 AC-5)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("profiles.corrupted-\(stamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        return LoadOutcome(profiles: [:], corruptionBackupURL: backupURL)
    }

    public func save(_ profiles: [String: Profile]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
