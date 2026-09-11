import Foundation

/// 작업 환경 저장소 (F-04.2). 파일 위치·직렬화·손상 복구·구버전 이전을 숨긴다.
/// 실패는 한 어휘(Trouble)로 보고한다 — 호출자가 읽기·쓰기마다 다른 채널을 배우지 않는다.
public final class ProfileStore {
    /// 사용자에게 알려야 하는 저장소 문제.
    public enum Trouble: Equatable {
        /// 파일이 손상되어 백업 후 초기화됐다 — 백업 위치를 알려준다.
        case corruptionBackedUp(URL)
        /// 파일은 있는데 읽지 못했다 (권한·I/O). 첫 실행으로 위장하면
        /// 다음 저장이 파일을 덮어쓴다 — 호출자는 이번 실행의 저장을 막아야 한다.
        case unreadable
        /// 이후 버전의 파일 형식이다. 원본을 보존하고 이번 실행의 쓰기를 막는다 (DSK10).
        case unsupportedVersion(Int)
        /// 정상 로드 뒤 파일에 쓰지 못했다. 메모리 상태를 성공처럼 공개하지 않고 재시도할 수 있다.
        case writeFailed
    }

    public struct LoadOutcome {
        public let workspaces: [WorkspaceKey: WorkspaceRecord]
        public let trouble: Trouble?
        /// 구버전 `profiles.json`에서 이번에 가져왔다. 원본 파일은 그대로 둔다.
        public let migratedFromLegacy: Bool
    }

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("workspaces.json") }
    /// 구버전 화면별 프로필. 읽기 전용 — 이전 뒤에도 수정·삭제하지 않는다 (DSK05 원본 보존).
    private var legacyURL: URL { directory.appendingPathComponent("profiles.json") }

    /// directory 기본값은 ~/Library/Application Support/Plugback
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plugback", isDirectory: true)
    }

    /// 구버전 `labAutoSlot` 선택이 있었으면 자동 슬롯도 복원 소스 후보였으므로 더 최근 쪽을 가져온다.
    public func load(preferLegacyAutoSlots: Bool = false) -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return loadLegacy(preferAutoSlots: preferLegacyAutoSlots)
        } catch {
            // 읽기 실패 ≠ 첫 실행 — 파일을 건드리지 않고 보고만 한다 (덮어쓰기 방지)
            return LoadOutcome(workspaces: [:], trouble: .unreadable, migratedFromLegacy: false)
        }
        if let file = try? JSONDecoder.plugback.decode(StoreFile.self, from: data) {
            guard file.version <= StoreFile.currentVersion else {
                return LoadOutcome(workspaces: [:], trouble: .unsupportedVersion(file.version),
                                   migratedFromLegacy: false)
            }
            var out: [WorkspaceKey: WorkspaceRecord] = [:]
            for (raw, record) in file.workspaces {
                guard let key = WorkspaceKey(raw: raw) else { continue }
                out[key] = record
            }
            return LoadOutcome(workspaces: out, trouble: nil, migratedFromLegacy: false)
        }
        // 손상 — 백업 후 초기화. 앱은 종료되지 않는다 (F-04.2, US-011 AC-5).
        // 백업 이동이 실패하면 원본을 덮지 않도록 읽기 실패로 취급한다 (DSK09).
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = directory.appendingPathComponent("workspaces.corrupted-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
        } catch {
            return LoadOutcome(workspaces: [:], trouble: .unreadable, migratedFromLegacy: false)
        }
        return LoadOutcome(workspaces: [:], trouble: .corruptionBackedUp(backupURL), migratedFromLegacy: false)
    }

    /// 구버전 화면별 프로필을 화면 하나짜리 작업 환경으로 가져온다. 화면 조합·개별 창·Space 정보는 지어내지 않는다 —
    /// 앱당 좌표 하나가 Space 없는 창 위치 기록 하나가 된다. 읽지 못하면 이전하지 않고 첫 실행처럼 시작한다.
    private func loadLegacy(preferAutoSlots: Bool) -> LoadOutcome {
        guard let data = try? Data(contentsOf: legacyURL),
              let profiles = try? JSONDecoder.plugback.decode([String: Profile].self, from: data)
        else { return LoadOutcome(workspaces: [:], trouble: nil, migratedFromLegacy: false) }

        var out: [WorkspaceKey: WorkspaceRecord] = [:]
        for (key, manual) in profiles where !Slot.isAutoKey(key) {
            var chosen = manual
            var savedBy = Slot.manual
            if preferAutoSlots, let auto = profiles[Slot.auto.key(key)],
               (auto.savedAt ?? .distantPast) > (manual.savedAt ?? .distantPast) {
                chosen = auto
                savedBy = .auto
            }
            out[WorkspaceKey(screenIDs: [manual.screenID])] = Self.record(from: chosen, savedBy: savedBy)
        }
        // 자동 슬롯만 있는 화면 — 옛 자동 슬롯이 켜져 있었으면 그것이 유일한 복원 소스였다. 꺼져 있었으면 옛 규칙대로 쓰지 않는다.
        if preferAutoSlots {
            for (key, auto) in profiles where Slot.isAutoKey(key) {
                let workspaceKey = WorkspaceKey(screenIDs: [auto.screenID])
                guard out[workspaceKey] == nil else { continue }
                out[workspaceKey] = Self.record(from: auto, savedBy: .auto)
            }
        }
        return LoadOutcome(workspaces: out, trouble: nil, migratedFromLegacy: !out.isEmpty)
    }

    static func record(from profile: Profile, savedBy: Slot) -> WorkspaceRecord {
        let key = WorkspaceKey(screenIDs: [profile.screenID])
        let apps = profile.apps.map {
            AppSelection(bundleID: $0.bundleID, displayName: $0.displayName, isEnabled: $0.isEnabled)
        }
        let placements = profile.apps.map {
            WindowPlacement(bundleID: $0.bundleID, displayName: $0.displayName,
                            screenID: profile.screenID, space: nil, unitRect: $0.unitRect)
        }
        let snapshot = WorkspaceSnapshot(
            key: key,
            screens: [ScreenRecord(id: profile.screenID, name: profile.screenName,
                                   fingerprint: profile.fingerprint)],
            placements: placements, savedAt: profile.savedAt, savedBy: savedBy
        )
        return WorkspaceRecord(key: key, apps: apps, saved: snapshot)
    }

    /// 저장. atomic write가 끝나야 성공이다 — 호출자가 메모리 상태를 공개할지 결정할 수 있게
    /// 디렉터리 생성·직렬화·쓰기 실패를 그대로 돌려준다.
    public func save(_ workspaces: [WorkspaceKey: WorkspaceRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = StoreFile(
            version: StoreFile.currentVersion,
            workspaces: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.key.raw, $0.value) })
        )
        try JSONEncoder.plugback.encode(file).write(to: fileURL, options: .atomic)
    }
}

extension JSONDecoder {
    static var plugback: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

extension JSONEncoder {
    static var plugback: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }
}
