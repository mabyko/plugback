import Foundation

/// 프로필 저장소 (F-04.2). 파일 위치·직렬화·손상 복구를 숨긴다.
/// 실패는 한 어휘(LoadOutcome.Trouble)로 보고한다 — 호출자가 실패 종류마다 다른 채널을 배우지 않는다.
public final class ProfileStore {
    public struct LoadOutcome {
        public let profiles: [String: Profile]
        public let trouble: Trouble?

        /// 사용자에게 알려야 하는 저장소 문제.
        public enum Trouble: Equatable {
            /// 파일이 손상되어 백업 후 초기화됐다 — 백업 위치를 알려준다.
            case corruptionBackedUp(URL)
            /// 파일은 있는데 읽지 못했다 (권한·I/O). 첫 실행으로 위장하면
            /// 다음 저장이 파일을 덮어쓴다 — 호출자는 이번 실행의 저장을 막아야 한다.
            case unreadable
        }
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
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LoadOutcome(profiles: [:], trouble: nil) // 진짜 첫 실행
        } catch {
            // 읽기 실패 ≠ 첫 실행 — 파일을 건드리지 않고 보고만 한다 (덮어쓰기 방지)
            return LoadOutcome(profiles: [:], trouble: .unreadable)
        }
        if let profiles = try? JSONDecoder().decode([String: Profile].self, from: data) {
            return LoadOutcome(profiles: profiles, trouble: nil)
        }
        // 손상 — 백업 후 초기화. 앱은 종료되지 않는다 (F-04.2, US-011 AC-5)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("profiles.corrupted-\(stamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        return LoadOutcome(profiles: [:], trouble: .corruptionBackedUp(backupURL))
    }

    /// 저장. 실패(디스크 가득 등)는 조용히 넘긴다 — throws는 유일 호출자가 try?로 삼키던
    /// 죽은 표면이었다. 실패 UI가 필요해지면 그때 보고 채널을 단다.
    public func save(_ profiles: [String: Profile]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
