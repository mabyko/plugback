import Combine
import CoreGraphics
import Foundation

/// 복원 모드 (F-05.4). 자동 저장과는 독립이다.
public enum RestoreMode: String, Sendable {
    case automatic, manual
}

/// captureNow의 반환 — 조용한 거부가 없다 (restoreNow와 같은 원칙).
public enum CaptureOutcome: Equatable, Sendable {
    /// 저장 완료 — 이 작업 환경의 포함 앱 수와 창 위치 기록 수.
    case captured(appCount: Int, windowCount: Int)
    case notAuthorized
    case notConnected
    case restoringInProgress
    /// 저장 파일을 읽지 못한 실행 — 덮어쓰기 방지로 저장이 차단됐다 (F-04.2).
    case saveBlocked
    /// 실행 중 파일에 쓰지 못했다. 이전 상태는 유지되고 다음 저장에서 재시도할 수 있다.
    case saveFailed
    /// Space reader는 있지만 안정된 snapshot을 얻지 못해 기존 배치를 보존했다.
    case spaceObservationUnavailable
    /// 개별 Spaces 구성이 아니거나 확인할 수 없어 새 Space 기록을 보류했다 (D6).
    case spacesUnsupported(SpacesSupport)
}

/// 카드에 잠깐 남기는 저장 관련 명시적 동작의 결과. 성공과 실패가 동시에 보일 수 없다.
public enum CaptureNotice: Equatable, Sendable {
    case captured(appCount: Int, windowCount: Int)
    case spaceObservationUnavailable
    case spacesUnsupported(SpacesSupport)
}

/// restoreNow의 반환 — 실행되지 않은 경로도 성공과 구별된다.
public enum RestoreOutcome: Equatable, Sendable {
    /// 복원 요청이 한 바퀴 돌았다. 비어 있으면 이 작업 환경의 저장본이 없었다는 뜻.
    case restored([RestoreResult])
    case notAuthorized
    case notConnected
    case alreadyRestoring
    case spacesUnsupported(SpacesSupport)
}

/// 정상 종료 전 저장의 결과 (4.4절). 실패하면 앱이 종료를 취소하고 사용자에게 묻는다.
public enum TerminationOutcome: Equatable, Sendable {
    case proceed
    case saveFailed
}

/// 화면 표시 이름의 재료 — 모니터 이름 + 포트 위치, 구분이 안 되면 A/B (P20). 문구는 앱이 만든다.
public struct ScreenLabel: Equatable, Hashable, Sendable {
    public let name: String
    public let portLocation: PortLocation?
    public let letter: String?

    public init(name: String, portLocation: PortLocation? = nil, letter: String? = nil) {
        self.name = name; self.portLocation = portLocation; self.letter = letter
    }
}

/// 헤드리스 파사드 — UI 없이 완결된다. UI는 이 상태의 표현일 뿐이다 (docs/ARCHITECTURE.md).
@MainActor
public final class PlugbackController: ObservableObject {
    /// 카드가 보여주는 화면 상태 (3상태). 분리돼도 기억으로 강등될 뿐 지워지지 않는다.
    @Published public private(set) var screenPresence: ScreenPresence = .none

    public var isConnected: Bool {
        if case .connected = screenPresence { return true } else { return false }
    }

    /// 복원 진행 중 — 재진입 가드이자 버튼 비활성용 UI 상태.
    @Published public private(set) var isRestoring = false
    /// 화면 구성 변경 신호 뒤 안정화를 기다리는 중 — 카드가 「화면 연결 확인 중」을 보여준다.
    @Published public private(set) var isSettlingScreens = false

    private struct ScreenProjection {
        let spaceGroups: [SpaceGroup]
        let spaceConfigurationDiffers: Bool
        /// 이 화면에 표준 창이 있는 앱 전부 (저장·제외와 무관). 세 묶음은 여기와 저장본에서 파생한다.
        let visibleApps: [UntrackedApp]
    }
    @Published private var projectionsByScreen: [String: ScreenProjection] = [:]
    private var latestProjectionSequence = 0
    /// 마지막 관찰의 Space snapshot — 표시 번호는 현재 순서를 따른다 (P20).
    private var latestSnapshot: SpaceSnapshot?

    @Published public private(set) var captureNotice: CaptureNotice?
    public var lastCaptureCount: Int? {
        guard case .captured(let count, _) = captureNotice else { return nil }
        return count
    }
    public var storeNotice: ProfileStore.Trouble? { library.trouble }
    public var isSaveBlocked: Bool { library.isSaveBlocked }
    /// 구버전 화면별 프로필을 이번 실행에서 화면 하나짜리 작업 환경으로 가져왔다 — 조합·Space 정보는 새 저장이 필요하다.
    public var migratedFromLegacy: Bool { library.migratedFromLegacy }
    /// 개별 Spaces 지원 판정 — 마지막 관찰 기준.
    @Published public private(set) var spacesSupport: SpacesSupport = .separateSpaces

    /// 복원 모드 (F-05.4). 기본값 자동, 변경은 보존된다. 수동으로 바꾸면 자동으로 시작한 요청의 남은 작업만 취소한다 (D8).
    @Published public var restoreMode: RestoreMode {
        didSet {
            guard restoreMode != oldValue else { return }
            defaults.set(restoreMode.rawValue, forKey: Keys.restoreMode)
            if restoreMode == .manual {
                restoreSession.cancel(reason: .automaticRestoreDisabled, onlyAutomatic: true)
                publishResults()
            }
        }
    }

    /// 최소화된 창도 Dock에서 꺼내 복원할지 (F-02.2 예외 설정). 기본 꺼짐.
    @Published public var restoreMinimized: Bool {
        didSet { defaults.set(restoreMinimized, forKey: Keys.restoreMinimized) }
    }

    /// 자동 저장 (D2). 최초 ON. 끄면 저장 대기 이력을 버리고 마지막 저장본은 유지한다 (D7).
    @Published public var autoSave: Bool {
        didSet {
            guard autoSave != oldValue else { return }
            defaults.set(autoSave, forKey: Keys.autoSave)
            library.setAutoSave(autoSave, currentSequence: observation.latestSequence)
            if autoSave { Task { await collectCandidate() } }
        }
    }

    /// 실험실 · 종료된 앱 다시 열기 (부모, 최초 OFF).
    @Published public var reopenClosedApps: Bool {
        didSet { defaults.set(reopenClosedApps, forKey: Keys.reopenClosedApps) }
    }
    /// 실험실 · 실행 중인 앱 창 되살리기 (자식, 최초 OFF). 부모 OFF면 효력이 없지만 값은 유지한다.
    @Published public var reviveWindowlessApps: Bool {
        didSet { defaults.set(reviveWindowlessApps, forKey: Keys.reviveWindowlessApps) }
    }
    /// 실험실 · 부족한 창 추가로 열기 (자식, 최초 OFF).
    @Published public var openMissingWindows: Bool {
        didSet { defaults.set(openMissingWindows, forKey: Keys.openMissingWindows) }
    }
    /// 실험실 · 복원할 창 직접 지정 (최초 OFF). OFF 전환은 미확정 선택만 취소한다 (D3).
    @Published public var directWindowAssignment: Bool {
        didSet {
            guard directWindowAssignment != oldValue else { return }
            defaults.set(directWindowAssignment, forKey: Keys.directWindowAssignment)
            if !directWindowAssignment { restoreSession.discardUnconfirmedChoices() }
        }
    }

    public var identityMismatch: Bool {
        externalScreens.contains { resultsByScreen[$0.id]?.screenSkipReason == .fingerprintMismatch }
    }

    /// 권한 판정 어댑터 — 앱이 주입한다 (US-010 AC-2). 기본 true — 페이크 없는 테스트 편의.
    public var authorizationCheck: () -> Bool = { true }
    /// 잠금 판정 어댑터 (D8). 기본은 비공식 세션 키. 테스트가 주입한다.
    public var lockStateCheck: () -> LockState = { .unlocked }
    /// 개별 Spaces 설정 판정 어댑터 (D6). 테스트가 주입한다.
    public var spacesPreferenceCheck: () -> SpacesSupport = { .separateSpaces }

    @Published public private(set) var isAuthorized = true

    @discardableResult
    public func checkAuthorization() -> Bool {
        let ok = authorizationCheck()
        if ok != isAuthorized { isAuthorized = ok }
        return ok
    }

    private let library: WorkspaceLibrary
    private var libraryChanges: AnyCancellable?
    @Published private var resultsByScreen: [String: RestoreResult] = [:]
    @Published public private(set) var lastRestoredAt: Date?
    public let diagnostics: DiagnosticsLog

    // MARK: - 카드 모델

    public struct AppRow: Equatable, Sendable, Identifiable {
        public var id: String { bundleID }
        public let bundleID: String
        public let displayName: String
        public let isEnabled: Bool
        /// 이 화면에 저장된 창 위치 기록 수. 0이면 아직 저장 전이다.
        public let windowCount: Int
        public var isSaved: Bool { windowCount > 0 }

        public init(bundleID: String, displayName: String, isEnabled: Bool, windowCount: Int) {
            self.bundleID = bundleID; self.displayName = displayName; self.isEnabled = isEnabled; self.windowCount = windowCount
        }
    }

    public struct SpaceGroup: Identifiable, Equatable, Sendable {
        public enum RegularState: Equatable, Sendable { case current, inactive, otherDisplay, missing, unknown }
        public enum Kind: Equatable, Sendable {
            case regular(number: Int, state: RegularState)
            case unresolved
        }
        public enum Guide: Equatable, Sendable {
            case move(source: ScreenLabel, destination: ScreenLabel)
            case visit(destination: ScreenLabel)
            case unavailable
        }
        public let id: String
        public let kind: Kind
        public let apps: [AppRow]
        public let guide: Guide?
    }

    public struct ScreenSection: Identifiable, Equatable, Sendable {
        public var id: String { screenID }
        public let screenID: String
        public let label: ScreenLabel
        public let hasSnapshot: Bool
        public let savedAt: Date?
        public let savedBy: Slot?
        /// 이 화면에 저장 기록이 있는 포함 앱 (지금 창 유무와 무관).
        public let apps: [AppRow]
        /// 지금 이 화면에 창이 있는 포함 앱 — 저장했든 아직이든 다음 저장의 대상이다 (D4). 카드의 첫 묶음.
        public let presentApps: [AppRow]
        /// 저장 기록은 있지만 지금 이 화면에 창이 없는 포함 앱 — 복원 대상은 유지된다.
        public let absentSavedApps: [AppRow]
        /// 사용자가 제외한 앱 — 이 화면에 창이나 기록이 있는 것, 없으면 첫 화면에 모아 보인다.
        public let excludedApps: [AppRow]
        public let spaceGroups: [SpaceGroup]
        public let spaceConfigurationDiffers: Bool
        public let lastResult: RestoreResult?

        public init(screenID: String, label: ScreenLabel, hasSnapshot: Bool, savedAt: Date?, savedBy: Slot?,
                    apps: [AppRow], presentApps: [AppRow], absentSavedApps: [AppRow], excludedApps: [AppRow],
                    spaceGroups: [SpaceGroup], spaceConfigurationDiffers: Bool, lastResult: RestoreResult?) {
            self.screenID = screenID; self.label = label; self.hasSnapshot = hasSnapshot
            self.savedAt = savedAt; self.savedBy = savedBy; self.apps = apps
            self.presentApps = presentApps; self.absentSavedApps = absentSavedApps; self.excludedApps = excludedApps
            self.spaceGroups = spaceGroups; self.spaceConfigurationDiffers = spaceConfigurationDiffers
            self.lastResult = lastResult
        }
    }

    /// 확인 화면의 항목 — 저장 창 하나마다 하나 (3.8절).
    public struct ConfirmationItem: Identifiable, Equatable, Sendable {
        public struct Candidate: Equatable, Sendable, Identifiable {
            public var id: CGWindowID { windowServerID }
            public let windowServerID: CGWindowID
            public let title: String?
            public let frame: CGRect
        }
        public var id: UUID { placementID }
        public let placementID: UUID
        public let bundleID: String
        public let displayName: String
        public let screen: ScreenLabel
        public let spaceNumber: Int?
        public let unitRect: UnitRect
        public let outcome: RestoreResult.Outcome
        public let candidates: [Candidate]
        public let chosenWindowServerID: CGWindowID?
    }

    /// 방문·이동 대기 항목의 한 줄 안내 재료 — 화면 소속을 항상 포함한다.
    public struct WaitingItem: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let screen: ScreenLabel
        public let spaceNumber: Int?
        public let outcome: RestoreResult.Outcome

        public init(id: UUID, screen: ScreenLabel, spaceNumber: Int?, outcome: RestoreResult.Outcome) {
            self.id = id; self.screen = screen; self.spaceNumber = spaceNumber; self.outcome = outcome
        }
    }

    public struct WorkspaceSummary: Identifiable, Equatable, Sendable {
        public var id: String { key.raw }
        public let key: WorkspaceKey
        public let screens: [ScreenLabel]
        public let appCount: Int
        public let enabledAppCount: Int
        public let windowCount: Int
        public let savedAt: Date?
        public let savedBy: Slot?
    }

    /// 지금 연결된 작업 환경. 외장이 없으면 nil.
    public var currentWorkspace: WorkspaceKey? { externalScreens.isEmpty ? nil : WorkspaceKey(screenIDs: externalScreens.map(\.id)) }

    public var sections: [ScreenSection] {
        let targets: [(String, ScreenLabel)]
        if isConnected {
            let labels = Self.screenLabels(for: externalScreens.map { ($0.id, $0.name, $0.portLocation) })
            targets = externalScreens.map { ($0.id, labels[$0.id] ?? ScreenLabel(name: $0.name)) }
        } else if case .remembered(let screenID, let name) = screenPresence {
            targets = [(screenID, ScreenLabel(name: name))]
        } else {
            return []
        }
        // 어느 화면에도 창·기록이 없는 제외 앱은 첫 화면 묶음에 모아 보인다 — 어딘가에는 보여야 다시 포함할 수 있다.
        let record = displayedKey.flatMap { library.record(for: $0) }
        let placedSomewhere = Set((record?.saved?.placements.map(\.bundleID) ?? [])
            + targets.flatMap { projectionsByScreen[$0.0]?.visibleApps.map(\.bundleID) ?? [] })
        let leftovers = (record?.apps ?? []).filter { !$0.isEnabled && !placedSomewhere.contains($0.bundleID) }
        return targets.enumerated().map { index, target in
            section(screenID: target.0, label: target.1, extraExcluded: index == 0 ? leftovers : [])
        }
    }

    private var displayedKey: WorkspaceKey? {
        if let currentWorkspace { return currentWorkspace }
        if case .remembered(let screenID, _) = screenPresence { return rememberedKey ?? WorkspaceKey(screenIDs: [screenID]) }
        return nil
    }

    private func section(screenID: String, label: ScreenLabel, extraExcluded: [AppSelection] = []) -> ScreenSection {
        let key = displayedKey
        let record = key.flatMap { library.record(for: $0) }
        let saved = record?.saved
        let projection = projectionsByScreen[screenID]
        let placements = saved?.placements(on: screenID) ?? []
        let visible = projection?.visibleApps ?? []
        let visibleIDs = Set(visible.map(\.bundleID))
        let enabled = { (bundleID: String) in record?.isEnabled(bundleID) ?? true }

        var countByBundle: [String: (name: String, count: Int)] = [:]
        var savedOrder: [String] = []
        for placement in placements {
            if countByBundle[placement.bundleID] == nil { savedOrder.append(placement.bundleID) }
            countByBundle[placement.bundleID] = (placement.displayName, (countByBundle[placement.bundleID]?.count ?? 0) + 1)
        }
        let savedRows = savedOrder.filter(enabled).map {
            AppRow(bundleID: $0, displayName: countByBundle[$0]!.name, isEnabled: true, windowCount: countByBundle[$0]!.count)
        }
        // 지금 화면에 있는 앱 — 창 순서(z-순서)대로. 저장한 앱은 기록 수를, 아직 저장 전인 앱은 0을 갖는다.
        let present = visible.filter { enabled($0.bundleID) }.map {
            AppRow(bundleID: $0.bundleID, displayName: countByBundle[$0.bundleID]?.name ?? $0.displayName,
                   isEnabled: true, windowCount: countByBundle[$0.bundleID]?.count ?? 0)
        }
        let absent = savedRows.filter { !visibleIDs.contains($0.bundleID) }
        let excludedSelections = (record?.apps ?? []).filter { selection in
            !selection.isEnabled && (visibleIDs.contains(selection.bundleID) || countByBundle[selection.bundleID] != nil)
        } + extraExcluded
        let excluded = excludedSelections.map {
            AppRow(bundleID: $0.bundleID, displayName: countByBundle[$0.bundleID]?.name ?? $0.displayName,
                   isEnabled: false, windowCount: countByBundle[$0.bundleID]?.count ?? 0)
        }
        return ScreenSection(screenID: screenID, label: label, hasSnapshot: saved != nil,
                             savedAt: saved?.savedAt, savedBy: saved?.savedBy, apps: savedRows,
                             presentApps: present, absentSavedApps: absent, excludedApps: excluded,
                             spaceGroups: projection?.spaceGroups ?? [],
                             spaceConfigurationDiffers: projection?.spaceConfigurationDiffers ?? false,
                             lastResult: resultsByScreen[screenID])
    }

    /// 화면 표시 이름 규칙 (P20): 같은 이름이 여럿이면 포트 위치로 구분하고, 위치까지 같거나 알 수 없으면 A/B를 붙인다.
    /// 식별자 순서가 곧 A/B 순서다. 표시용이며 저장·복원의 키가 아니다.
    public static func screenLabels(for screens: [(id: String, name: String, portLocation: PortLocation?)]) -> [String: ScreenLabel] {
        var groups: [String: [(String, String, PortLocation?)]] = [:]
        for screen in screens {
            let locationKey = screen.portLocation.map { "\($0)" } ?? "?"
            groups["\(screen.name)|\(locationKey)", default: []].append(screen)
        }
        var out: [String: ScreenLabel] = [:]
        let letters = Array("ABCDEFGH")
        for (_, members) in groups {
            let sorted = members.sorted { $0.0 < $1.0 }
            for (index, member) in sorted.enumerated() {
                // 같은 이름·같은 위치(또는 위치 불명)가 둘 이상일 때만 A/B가 붙는다. 이름이 유일하면 위치만 붙는다.
                let letter: String? = sorted.count > 1 ? String(letters[min(index, letters.count - 1)]) : nil
                out[member.0] = ScreenLabel(name: member.1, portLocation: member.2, letter: letter)
            }
        }
        return out
    }

    /// 저장 identity는 opaque name 그대로 두고, 현재 화면의 일반 Space 순서로 표시 번호를 붙인다 (P20).
    /// 현재 목록에서 찾지 못한 저장 Space는 저장 순서의 번호와 확인 필요 상태로 구분한다.
    static func spaceGroups(
        record: WorkspaceRecord?, screenID: String, snapshot: SpaceSnapshot?, targetConnected: Bool,
        outcomes: [UUID: RestoreResult.Outcome], labels: [String: ScreenLabel]
    ) -> [SpaceGroup] {
        guard let saved = record?.saved, let screen = saved.screen(screenID) else { return [] }
        let enabled = { (bundleID: String) in record?.isEnabled(bundleID) ?? true }
        var hints: [SpaceHint] = screen.regularSpaces
        for placement in saved.placements(on: screenID) {
            if let hint = placement.space, !hints.contains(hint) { hints.append(hint) }
        }
        let liveNumbers = liveSpaceNumbers(on: screenID, snapshot: snapshot)
        let destination = labels[screenID] ?? ScreenLabel(name: screen.name)

        var groups: [SpaceGroup] = []
        for (savedIndex, hint) in hints.enumerated() {
            let placements = saved.placements(on: screenID).filter { $0.space == hint && enabled($0.bundleID) }
            let state: SpaceGroup.RegularState
            var guide: SpaceGroup.Guide?
            var placement: SpacePlacement?
            if targetConnected {
                placement = SpacePlacement.of(hint, on: screenID, in: snapshot)
                switch placement {
                case .current: state = .current
                case .inactive: state = .inactive
                case .stranded: state = .otherDisplay
                case .missing: state = .missing
                case .fullscreen, .unsupported, .unknown, nil: state = .unknown
                }
            } else {
                state = .unknown
            }
            for item in placements {
                switch outcomes[item.id] {
                case .awaitingSpaceMove(let sourceID):
                    guide = .move(source: labels[sourceID] ?? ScreenLabel(name: "다른 화면"), destination: destination)
                case .awaitingVisit: if guide == nil { guide = .visit(destination: destination) }
                case .needsConfirmation(.spaceMissing), .needsConfirmation(.spaceUnavailable):
                    if guide == nil { guide = .unavailable }
                default: break
                }
            }
            let number = liveNumbers[hint.opaqueName] ?? (savedIndex + 1)
            groups.append(SpaceGroup(id: "regular:\(hint.opaqueName)",
                                     kind: .regular(number: number, state: state),
                                     apps: rows(placements), guide: guide))
        }
        let flat = saved.placements(on: screenID).filter { $0.space == nil && enabled($0.bundleID) }
        if !flat.isEmpty {
            groups.append(SpaceGroup(id: "unresolved", kind: .unresolved, apps: rows(flat), guide: nil))
        }
        return groups
    }

    static func liveSpaceNumbers(on screenID: String, snapshot: SpaceSnapshot?) -> [String: Int] {
        guard let snapshot, let display = snapshot.onlyDisplay(screenID) else { return [:] }
        var out: [String: Int] = [:]
        var number = 0
        for space in display.spaces where space.kind == .regular {
            number += 1
            if let name = space.opaqueName { out[name] = number }
        }
        return out
    }

    private static func rows(_ placements: [WindowPlacement]) -> [AppRow] {
        var out: [AppRow] = []
        for placement in placements {
            if let index = out.firstIndex(where: { $0.bundleID == placement.bundleID }) {
                out[index] = AppRow(bundleID: placement.bundleID, displayName: placement.displayName,
                                    isEnabled: true, windowCount: out[index].windowCount + 1)
            } else {
                out.append(AppRow(bundleID: placement.bundleID, displayName: placement.displayName, isEnabled: true, windowCount: 1))
            }
        }
        return out
    }

    /// 저장 계획과 현재 대상 화면의 일반 Space 식별자·순서가 다른지 비교한다.
    static func spaceConfigurationDiffers(saved: ScreenRecord?, snapshot: SpaceSnapshot?, targetConnected: Bool) -> Bool {
        guard targetConnected, let saved, !saved.regularSpaces.isEmpty, let snapshot,
              let display = snapshot.onlyDisplay(saved.id) else { return false }
        let savedNames = saved.regularSpaces.map(\.opaqueName)
        let live = display.spaces.filter { $0.kind == .regular }.sorted { $0.localOrder < $1.localOrder }
        guard live.count == savedNames.count else { return true }
        let liveNames = live.compactMap {
            SpacePlacement.of($0.runtimeID, on: display.screenID, in: snapshot).onTarget?.identity?.opaqueName
        }
        guard liveNames.count == live.count else { return false }
        return liveNames != savedNames
    }

    public var lastResults: [RestoreResult] {
        externalScreens.compactMap { resultsByScreen[$0.id] }.filter { $0.screenSkipReason == nil }
    }

    public var hasRestorableProfile: Bool {
        guard let key = displayedKey else { return false }
        return library.saved(for: key) != nil
    }
    public var hasPendingCollect: Bool { currentWorkspace.map { library.hasPendingChanges(for: $0) } ?? false }
    public var lastCollectedAt: Date? { library.lastCollectedAt }
    public var spaceConfigurationDiffers: Bool { projectionsByScreen.values.contains { $0.spaceConfigurationDiffers } }
    public var enabledAppCount: Int {
        guard let key = displayedKey, let record = library.record(for: key) else { return 0 }
        let saved = Set(record.saved?.placements.map(\.bundleID) ?? [])
        return saved.filter { record.isEnabled($0) }.count
    }
    public var savedWindowCount: Int {
        guard let key = displayedKey, let record = library.record(for: key) else { return 0 }
        return record.saved?.placements.filter { record.isEnabled($0.bundleID) }.count ?? 0
    }

    /// 현재 요청의 남은 항목 — 방문·이동·잠금 대기와 확인 필요.
    public var waitingItems: [WaitingItem] {
        guard let request = restoreSession.request else { return [] }
        let labels = Self.screenLabels(for: externalScreens.map { ($0.id, $0.name, $0.portLocation) })
        return request.source.placements.compactMap { placement in
            guard let outcome = request.outcomes[placement.id], !RestoreSession.isTerminal(outcome) else { return nil }
            let numbers = Self.liveSpaceNumbers(on: placement.screenID, snapshot: latestSnapshot)
            return WaitingItem(id: placement.id,
                               screen: labels[placement.screenID] ?? ScreenLabel(name: request.source.screen(placement.screenID)?.name ?? ""),
                               spaceNumber: placement.space.flatMap { numbers[$0.opaqueName] },
                               outcome: outcome)
        }
    }
    public var hasOpenRestoreItems: Bool { restoreSession.hasOpenItems }
    public var confirmationCount: Int {
        waitingItems.filter { if case .needsConfirmation = $0.outcome { return true } else { return false } }.count
    }

    public var confirmationItems: [ConfirmationItem] {
        guard let request = restoreSession.request else { return [] }
        let labels = Self.screenLabels(for: externalScreens.map { ($0.id, $0.name, $0.portLocation) })
        return request.source.placements.compactMap { placement in
            guard let outcome = request.outcomes[placement.id],
                  case .needsConfirmation = outcome else { return nil }
            let numbers = Self.liveSpaceNumbers(on: placement.screenID, snapshot: latestSnapshot)
            let candidates = restoreSession.candidates(for: placement.id).compactMap { window -> ConfirmationItem.Candidate? in
                guard let wsid = window.windowServerID else { return nil }
                return ConfirmationItem.Candidate(windowServerID: wsid, title: window.title, frame: window.frame)
            }
            return ConfirmationItem(
                placementID: placement.id, bundleID: placement.bundleID, displayName: placement.displayName,
                screen: labels[placement.screenID] ?? ScreenLabel(name: request.source.screen(placement.screenID)?.name ?? ""),
                spaceNumber: placement.space.flatMap { numbers[$0.opaqueName] },
                unitRect: placement.unitRect, outcome: outcome, candidates: candidates,
                chosenWindowServerID: request.userChoices[placement.id]
            )
        }
    }

    public var allWorkspaces: [WorkspaceSummary] {
        library.allRecords.map { record in
            let screens = record.saved?.screens ?? record.key.screenIDs.map { ScreenRecord(id: $0, name: $0) }
            let labels = Self.screenLabels(for: screens.map { ($0.id, $0.name, $0.portLocation) })
            return WorkspaceSummary(
                key: record.key,
                screens: screens.map { labels[$0.id] ?? ScreenLabel(name: $0.name) },
                appCount: Set(record.saved?.placements.map(\.bundleID) ?? []).count,
                enabledAppCount: Set(record.saved?.placements.map(\.bundleID) ?? []).filter { record.isEnabled($0) }.count,
                windowCount: record.saved?.placements.count ?? 0,
                savedAt: record.saved?.savedAt, savedBy: record.saved?.savedBy
            )
        }
    }

    // MARK: - 배선

    private let gateway: WindowGateway
    private let observation: DesktopObservation
    private lazy var restoreSession = RestoreSession(observation: observation, gateway: gateway, library: library)
    private let screenProvider: ScreenProvider
    private let defaults: UserDefaults
    private var externalScreens: [ScreenInfo] = []
    private var watcher: DisplayWatcher?
    private var collectTrigger: CollectTrigger?
    private let moveSource: WindowMoveSource?
    private let spaceReader: SpaceReading?
    private let activeSpaceDebounceInterval: TimeInterval
    private var activeSpaceWatcher: ActiveSpaceWatcher?
    private lazy var missionControlWatcher = MissionControlWatcher { [weak self] in
        guard let self else { return }
        Task { await self.missionControlClosed() }
    }
    private var pendingSpaceRefresh = false
    private var pendingWorkspaceRestart = false
    /// 마지막으로 선택한 작업 환경 — 환경 이탈 때 이 환경의 이력을 확정한다.
    private var selectedKey: WorkspaceKey?
    private var rememberedKey: WorkspaceKey?
    /// 원시 화면 변경 신호의 횟수 — 관찰 도중 신호가 오면 그 관찰을 버린다.
    private var rawChangeCount = 0
    /// 사용자 조작 보호 — 창별 마지막 이동 알림 시각과 Plugback 자신의 이동 시각.
    private var touchedWindows: [CGWindowID: Date] = [:]
    private var selfMoves: [CGWindowID: Date] = [:]
    /// 복원이 남긴 착지 위치 — 사용자가 옮기기 전까지 새 이력으로 승격하지 않는다 (R5·A09).
    private var restoreLandings: [CGWindowID: CGRect] = [:]

    private let collectInterval: TimeInterval
    public init(gateway: WindowGateway, screenProvider: ScreenProvider, store: ProfileStore,
                defaults: UserDefaults = .standard, collectInterval: TimeInterval = 10,
                moveSource: WindowMoveSource? = nil,
                spaceReader: SpaceReading? = nil,
                activeSpaceDebounceInterval: TimeInterval = 1.5,
                diagnosticsDirectory: URL? = nil) {
        self.gateway = gateway
        observation = DesktopObservation(gateway: gateway, spaceReader: spaceReader)
        self.screenProvider = screenProvider
        self.defaults = defaults
        self.collectInterval = collectInterval
        self.moveSource = moveSource
        self.spaceReader = spaceReader
        self.activeSpaceDebounceInterval = activeSpaceDebounceInterval
        diagnostics = DiagnosticsLog(directory: diagnosticsDirectory)

        Self.migrateSettingsIfNeeded(defaults)
        restoreMode = defaults.string(forKey: Keys.restoreMode).flatMap(RestoreMode.init) ?? .automatic
        restoreMinimized = defaults.bool(forKey: Keys.restoreMinimized)
        let autoSaveValue = defaults.object(forKey: Keys.autoSave) as? Bool ?? true // D2: 선택 이력이 없으면 ON
        autoSave = autoSaveValue
        reopenClosedApps = defaults.bool(forKey: Keys.reopenClosedApps)
        reviveWindowlessApps = defaults.bool(forKey: Keys.reviveWindowlessApps)
        openMissingWindows = defaults.bool(forKey: Keys.openMissingWindows)
        directWindowAssignment = defaults.bool(forKey: Keys.directWindowAssignment)
        library = WorkspaceLibrary(store: store, isAutoSaveEnabled: autoSaveValue,
                                   preferLegacyAutoSlots: defaults.bool(forKey: Keys.legacyLabAutoSlot))
        if let remembered = library.firstRememberedScreen {
            screenPresence = .remembered(screenID: remembered.id, name: remembered.name)
            rememberedKey = library.allRecords.first { $0.saved?.screens.first?.id == remembered.id }?.key
        }
        libraryChanges = library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// 기존 설정의 한 번 이전 (7.1절). 명시적인 옛 선택은 보존하고, 새 키에 이미 값이 있으면 덮지 않는다.
    static func migrateSettingsIfNeeded(_ defaults: UserDefaults) {
        guard defaults.object(forKey: Keys.settingsVersion) == nil else { return }
        if defaults.object(forKey: Keys.autoSave) == nil, let legacy = defaults.object(forKey: Keys.legacyLabAutoSlot) as? Bool {
            defaults.set(legacy, forKey: Keys.autoSave)
        }
        if defaults.object(forKey: Keys.reviveWindowlessApps) == nil,
           let legacy = defaults.object(forKey: Keys.legacyReopenWindowless) as? Bool {
            defaults.set(legacy, forKey: Keys.reviveWindowlessApps)
        }
        defaults.set(2, forKey: Keys.settingsVersion)
    }

    public func startWatching() {
        guard watcher == nil else { return }
        let w = DisplayWatcher(
            provider: screenProvider,
            isLocked: { [weak self] in (self?.lockStateCheck() ?? .unlocked) == .locked },
            onExternalScreensRemoved: { [weak self] _ in
                guard let self else { return }
                Task { await self.workspaceChanged() }
            },
            onRawChange: { [weak self] in
                guard let self else { return }
                rawChangeCount += 1
                isSettlingScreens = true
            },
            onScreenUnlocked: { [weak self] in
                guard let self else { return }
                Task { await self.screenUnlocked() }
            }
        ) { [weak self] in
            guard let self else { return }
            Task { await self.externalScreensAppeared() }
        }
        w.start()
        watcher = w
        syncScreens()
        selectedKey = currentWorkspace
        syncSpaceWatcher()
        syncCollectTrigger()
    }

    private func syncCollectTrigger() {
        guard !isSaveBlocked else {
            let stopping = collectTrigger
            collectTrigger = nil
            Task { await stopping?.stop() }
            return
        }
        if collectTrigger == nil {
            let trigger = CollectTrigger(
                moveSource: moveSource,
                minimumInterval: collectInterval,
                onTerminating: { [weak self] in _ = self?.library.confirmAll() },
                onAppTerminated: { [weak self] bundleID in
                    guard let self else { return }
                    library.noteAppTerminated(bundleID, currentKey: currentWorkspace)
                }
            ) { [weak self] in
                guard let self else { return }
                Task { await self.collectCandidate() }
            }
            trigger.start()
            collectTrigger = trigger
            Task { [weak self] in
                await self?.moveSource?.observeWindowInteractions { wsid in
                    Task { @MainActor in self?.windowTouched(wsid) }
                }
            }
        }
        Task { await collectCandidate() }
    }

    private func windowTouched(_ windowServerID: CGWindowID) {
        // Plugback 자신의 이동 알림은 짧은 시간 안에 온다 — ponytail: 1초 안의 알림은 자기 이동으로 본다. 실기기에서 조정한다.
        if let own = selfMoves[windowServerID], Date().timeIntervalSince(own) < 1.0 { return }
        touchedWindows[windowServerID] = Date()
        restoreLandings.removeValue(forKey: windowServerID) // 사용자가 옮겼다 — 착지 보호를 푼다
        selfMoves = selfMoves.filter { Date().timeIntervalSince($0.value) < 10 }
    }

    private var spaceObservationEnabled: Bool { spaceReader != nil }

    private func syncSpaceWatcher() {
        guard spaceObservationEnabled else {
            missionControlWatcher.stop()
            activeSpaceWatcher?.stop()
            activeSpaceWatcher = nil
            return
        }
        missionControlWatcher.start()
        guard activeSpaceWatcher == nil else { return }
        let watcher = ActiveSpaceWatcher(debounceInterval: activeSpaceDebounceInterval) { [weak self] in
            guard let self else { return }
            Task { await self.activeSpaceChanged() }
        }
        watcher.start()
        activeSpaceWatcher = watcher
    }

    private func sessionEnvironment() -> RestoreSession.Environment {
        RestoreSession.Environment(
            options: { [weak self] in self?.restoreOptions ?? RestoreOptions() },
            lockState: { [weak self] in self?.lockStateCheck() ?? .unlocked },
            spaceObservationEnabled: spaceObservationEnabled,
            isTouched: { [weak self] wsid, since in
                guard let touched = self?.touchedWindows[wsid] else { return false }
                return touched > since
            },
            willMove: { [weak self] wsid in
                guard let self, let wsid else { return }
                selfMoves[wsid] = Date()
                touchedWindows.removeValue(forKey: wsid)
            },
            diagnostics: { [weak self] event, key in self?.diagnostics.record(event, dedupKey: key) }
        )
    }

    private var restoreOptions: RestoreOptions {
        RestoreOptions(restoreMinimized: restoreMinimized, reopenClosedApps: reopenClosedApps,
                       reviveWindowlessApps: reviveWindowlessApps, openMissingWindows: openMissingWindows,
                       directAssignment: directWindowAssignment)
    }

    // MARK: - 화면 이벤트

    // internal — DisplayWatcher 콜백. 테스트가 직접 호출한다.
    func externalScreensAppeared() async {
        await workspaceChanged()
    }

    /// 안정된 화면 조합이 바뀌었다 — 떠나는 환경의 이력을 확정하고, 새 환경을 선택하며, 자동 모드면 그 환경의 저장본으로 새 요청을 시작한다 (D5).
    func workspaceChanged() async {
        syncScreens()
        isSettlingScreens = false
        let previous = selectedKey
        let next = currentWorkspace
        if previous != next {
            if let previous, autoSave { _ = library.confirm(key: previous) }
            library.noteWorkspaceChanged() // 화면 구성 변경으로 macOS가 옮긴 창을 사용자의 내장 이동으로 보지 않는다
            if let request = restoreSession.request, request.key != next {
                restoreSession.cancel(reason: .workspaceChanged)
                publishResults()
            }
            selectedKey = next
            if let next { rememberedKey = next }
            touchedWindows.removeAll()
            restoreLandings.removeAll()
        }
        await refreshCollectTargets()
        await refreshProjection()
        guard next != nil, restoreMode == .automatic, checkAuthorization() else { return }
        if isRestoring {
            pendingWorkspaceRestart = true // 진행 중 복원이 끝난 직후 새 환경으로 다시 시작한다
            return
        }
        guard previous != next || pendingWorkspaceRestart else { return }
        pendingWorkspaceRestart = false
        guard let key = next, library.saved(for: key) != nil else { return }
        _ = await performRestore(origin: .automatic, key: key)
    }

    func screenUnlocked() async {
        guard !isRestoring, restoreSession.hasOpenItems else { return }
        syncScreens()
        guard isConnected, checkAuthorization(), let key = currentWorkspace,
              restoreSession.request?.key == key else { return }
        _ = await performResume(scope: .unlock)
    }

    public func cardOpened() async {
        checkAuthorization()
        syncSpaceWatcher()
        captureNotice = nil
        syncScreens()
        await refreshProjection()
    }

    private func syncScreens() {
        let screens = screenProvider.screens()
        externalScreens = screens.filter { !$0.isBuiltin }.sorted { $0.id < $1.id }
        if let first = externalScreens.first {
            screenPresence = .connected(first, count: externalScreens.count)
        } else if case .connected(let last, _) = screenPresence {
            screenPresence = .remembered(screenID: last.id, name: last.name)
        }
    }

    private func determineSpacesSupport(_ snapshot: SpaceSnapshot?) -> SpacesSupport {
        guard spaceObservationEnabled else { return .separateSpaces }
        let total = screenProvider.screens().count
        let support = SpacesSupport.combine(preference: spacesPreferenceCheck(), snapshot: snapshot,
                                            connectedScreenCount: total)
        if support != spacesSupport { spacesSupport = support }
        return support
    }

    // MARK: - 저장

    /// [💾 지금 레이아웃 저장] (F-03). 연결된 작업 환경의 저장본을 한 번에 갱신한다.
    @discardableResult
    public func captureNow() async -> CaptureOutcome {
        captureNotice = nil
        guard checkAuthorization() else { return .notAuthorized }
        guard !isRestoring else { return .restoringInProgress }
        guard !library.isSaveBlocked else { return .saveBlocked }
        syncScreens()
        guard let key = currentWorkspace else { return .notConnected }
        let changeCountBefore = rawChangeCount
        let sample = await observation.sample(includeSpaces: spaceObservationEnabled)
        guard rawChangeCount == changeCountBefore, currentWorkspace == key else { return .notConnected }
        let snapshot: SpaceSnapshot?
        switch sample.spaceAvailability {
        case nil:
            snapshot = nil
        case .some(.available(let available)):
            snapshot = available
        case .some(.unavailable):
            captureNotice = .spaceObservationUnavailable
            applyProjection(sample)
            return .spaceObservationUnavailable
        }
        let support = determineSpacesSupport(snapshot)
        guard support == .separateSpaces else {
            captureNotice = .spacesUnsupported(support)
            applyProjection(sample)
            return .spacesUnsupported(support)
        }
        guard library.capture(key: key, screens: externalScreens, sample: sample, snapshot: snapshot) else {
            return .saveFailed
        }
        // 사람이 지금 배치를 다시 선언했으므로 이전 복원 요청의 남은 작업은 더 이상 유효하지 않다.
        restoreSession.cancel(reason: .newSave)
        publishResults()
        let appCount = enabledAppCount
        let windowCount = savedWindowCount
        captureNotice = .captured(appCount: appCount, windowCount: windowCount)
        applyProjection(sample)
        await refreshCollectTargets()
        return .captured(appCount: appCount, windowCount: windowCount)
    }

    // MARK: - 수집 (저장 대기 이력)

    /// 수집 — 지금 배치를 저장 대기 이력에 담고 창 연결·닫힘을 갱신한다. 파일에는 닿지 않는다 (제외 목록 제외).
    /// internal — 테스트가 알림 없이 직접 호출한다.
    func collectCandidate() async {
        guard !isSaveBlocked, !isRestoring, checkAuthorization(), watcher?.isSettling != true else { return }
        syncScreens()
        let key = currentWorkspace
        let changeCountBefore = rawChangeCount
        let sample = await observation.sample(includeSpaces: spaceObservationEnabled)
        guard !isRestoring, rawChangeCount == changeCountBefore, currentWorkspace == key,
              watcher?.isSettling != true else { return }
        guard let key else {
            library.trackLinks(sample: sample, currentKey: nil)
            return
        }
        let snapshot: SpaceSnapshot?
        switch sample.spaceAvailability {
        case nil: snapshot = nil
        case .some(.available(let available)): snapshot = available
        case .some(.unavailable):
            applyProjection(sample)
            return
        }
        guard determineSpacesSupport(snapshot) == .separateSpaces else {
            library.trackLinks(sample: sample, currentKey: key)
            applyProjection(sample)
            return
        }
        var running = Set<String>()
        for bundleID in Set(library.links.values.map(\.bundleID)) where await gateway.isRunning(bundleID: bundleID) {
            running.insert(bundleID)
        }
        // 복원이 남긴 착지 위치는 사용자가 옮기기 전까지 새 이력이 아니다 — 그 창은 이번 관찰에서 뺀다.
        let frozen = Set(sample.windows.compactMap { window -> CGWindowID? in
            guard let wsid = window.windowServerID, let landing = restoreLandings[wsid],
                  RestoreEngine.approximatelyEqual(landing, window.frame) else { return nil }
            return wsid
        })
        let filtered = DesktopObservation.Sample(
            sequence: sample.sequence,
            windows: sample.windows.filter { $0.windowServerID.map { !frozen.contains($0) } ?? true },
            unavailableBundleIDs: sample.unavailableBundleIDs.union(
                Set(sample.windows.filter { $0.windowServerID.map(frozen.contains) ?? false }.map(\.appBundleID))),
            spaceAvailability: sample.spaceAvailability,
            existingWindowServerIDs: sample.existingWindowServerIDs
        )
        library.collect(key: key, screens: externalScreens, sample: filtered, snapshot: snapshot, runningBundleIDs: running)
        applyProjection(sample)
        await refreshCollectTargets()
    }

    private func refreshCollectTargets() async {
        syncScreens()
        guard !isSaveBlocked, let key = currentWorkspace else {
            await collectTrigger?.retarget([])
            return
        }
        await collectTrigger?.retarget(library.observedBundleIDs(for: key))
    }

    /// 정상 종료 전 — 자동 저장 ON이고 저장할 변경이 있으면 마지막 유효 이력을 저장한다 (4.4절).
    public func prepareForTermination() -> TerminationOutcome {
        restoreSession.end(reason: .newRequest)
        guard autoSave, !isSaveBlocked else { return .proceed }
        switch library.confirmAll() {
        case .failed: return .saveFailed
        case .saved, .nothingToSave, .disabled: return .proceed
        }
    }

    /// 저장할 변경이 남아 있는가 — 종료 확인 문구용.
    public var hasUnsavedHistory: Bool { autoSave && library.hasAnyPendingChanges }

    // MARK: - 복원

    /// [↶ 지금 복원] (F-02). 현재 작업 환경의 마지막 저장 완료본으로 새 요청을 시작한다.
    @discardableResult
    public func restoreNow() async -> RestoreOutcome {
        guard checkAuthorization() else { return .notAuthorized }
        syncScreens()
        guard let key = currentWorkspace else { return .notConnected }
        guard !isRestoring else { return .alreadyRestoring }
        guard library.saved(for: key) != nil else { return .restored([]) }
        if spaceObservationEnabled {
            let support = determineSpacesSupport(latestSnapshot)
            guard support == .separateSpaces else { return .spacesUnsupported(support) }
        }
        return .restored(await performRestore(origin: .user, key: key))
    }

    /// 「남은 창 복원」 — 확인 필요·대기 항목을 현재 조건으로 다시 판정한다 (D8). 재개는 사용자 요청이다.
    @discardableResult
    public func resumeRemaining() async -> RestoreOutcome {
        guard checkAuthorization() else { return .notAuthorized }
        syncScreens()
        guard let key = currentWorkspace else { return .notConnected }
        guard !isRestoring else { return .alreadyRestoring }
        guard restoreSession.request?.key == key, restoreSession.hasOpenItems else { return .restored(lastResults) }
        return .restored(await performResume(scope: .user))
    }

    /// 「남은 복원 취소」 — 표시 중인 요청의 남은 작업을 취소한다. 완료한 창·저장 기록은 그대로다.
    public func cancelRemaining() {
        restoreSession.cancel(reason: .userCancelled)
        publishResults()
    }

    /// 직접 지정 (실험실 ON일 때만). 확정은 「남은 창 복원」에서 실제 창·자리 확인 뒤 이동으로 이어진다.
    public func chooseWindow(placementID: UUID, windowServerID: CGWindowID?) {
        guard directWindowAssignment else { return }
        restoreSession.chooseWindow(placementID: placementID, windowServerID: windowServerID)
        objectWillChange.send()
    }

    /// 「창 확인」 — 후보 창을 앞으로 가져온다. 마지막 열거의 참조만 유효하므로 그 앱을 다시 열거한다.
    public func raiseWindow(bundleID: String, windowServerID: CGWindowID) async -> Bool {
        guard !isRestoring else { return false }
        let sample = await observation.sample(of: [bundleID], includeSpaces: false)
        guard let window = sample.windows.first(where: { $0.windowServerID == windowServerID }) else { return false }
        return await gateway.raise(windowID: window.id)
    }

    func activeSpaceChanged() async { await desktopStateChanged() }
    func missionControlClosed() async { await desktopStateChanged() }

    private func desktopStateChanged() async {
        guard spaceObservationEnabled else { return }
        if isRestoring {
            pendingSpaceRefresh = true
            return
        }
        syncScreens()
        guard isConnected, checkAuthorization() else { return }
        if restoreSession.hasOpenItems, restoreSession.request?.key == currentWorkspace, hasWaitingItems {
            for attempt in 0..<2 {
                if attempt == 1 {
                    // Space 알림 뒤 첫 snapshot이 직전 Space로 안정돼 보일 수 있다.
                    // 같은 정착 간격 뒤 딱 한 번만 다시 읽고, 주기 폴링은 만들지 않는다.
                    try? await Task.sleep(nanoseconds: UInt64(activeSpaceDebounceInterval * 1_000_000_000))
                    if isRestoring { pendingSpaceRefresh = true; return }
                    syncScreens()
                    guard isConnected, checkAuthorization() else { return }
                }
                guard hasWaitingItems else { break }
                _ = await performResume(scope: .waiting)
            }
            await collectCandidate() // 방문 대기가 남아 있어도 확인된 다른 Space의 작업 이력은 모은다 (A29)
        } else {
            await collectCandidate()
            await refreshProjection()
        }
    }

    private var hasWaitingItems: Bool {
        waitingItems.contains {
            switch $0.outcome {
            case .awaitingVisit, .awaitingSpaceMove: return true
            default: return false
            }
        }
    }

    private func performRestore(origin: RestoreSession.Origin, key: WorkspaceKey) async -> [RestoreResult] {
        isRestoring = true
        pendingSpaceRefresh = false
        var latest: [RestoreResult] = []
        var runKey = key
        var runOrigin = origin
        repeat {
            pendingWorkspaceRestart = false
            let results = await restoreSession.start(origin: runOrigin, key: runKey, screens: externalScreens,
                                                     environment: sessionEnvironment())
            latest = results ?? []
            publishResults()
            if pendingWorkspaceRestart, restoreMode == .automatic {
                syncScreens()
                guard let next = currentWorkspace, library.saved(for: next) != nil else { break }
                runKey = next
                runOrigin = .automatic
            }
        } while pendingWorkspaceRestart && isConnected
        pendingWorkspaceRestart = false
        finishRestore()
        await refreshProjection()
        return latest
    }

    private func performResume(scope: RestoreSession.Scope) async -> [RestoreResult] {
        isRestoring = true
        pendingSpaceRefresh = false
        let results = await restoreSession.resume(scope: scope, screens: externalScreens, environment: sessionEnvironment())
        publishResults()
        finishRestore()
        await refreshProjection()
        return results ?? lastResults
    }

    private func finishRestore() {
        isRestoring = false
        // 복원이 옮긴(또는 옮기려다 실패한) 창의 착지 위치를 기억한다 — 다음 수집이 이를 새 이력으로 승격하지 않는다.
        for (wsid, frame) in restoreSession.landings { restoreLandings[wsid] = frame }
    }

    private func publishResults() {
        // 결과 수명 = 저장본 수명 — 삭제된 작업 환경의 결과를 되살리지 않는다.
        guard let key = restoreSession.request?.key, library.record(for: key) != nil else { return }
        let results = restoreSession.results
        for result in results {
            resultsByScreen[result.screenID] = result
        }
        if !results.isEmpty { lastRestoredAt = Date() }
        objectWillChange.send()
    }

    // MARK: - 관리

    public func removeWorkspace(_ key: WorkspaceKey) {
        guard library.remove(key: key) else { return }
        if restoreSession.request?.key == key {
            restoreSession.drop() // 결과 수명 = 저장본 수명 — 전생의 결과를 남기지 않는다
        }
        for screenID in key.screenIDs {
            resultsByScreen.removeValue(forKey: screenID)
            projectionsByScreen.removeValue(forKey: screenID)
        }
        if rememberedKey == key { rememberedKey = nil }
        Task { await refreshProjection() }
    }

    /// 저장 자리 하나 삭제 — 확인 화면에서.
    public func removePlacement(_ placementID: UUID) {
        guard let key = restoreSession.request?.key ?? currentWorkspace else { return }
        guard library.removePlacement(placementID, in: key) else { return }
        restoreSession.cancelItem(placementID: placementID)
        publishResults()
        Task { await refreshProjection() }
    }

    private func refreshProjection() async {
        guard !isRestoring else { return }
        let sample = await observation.sample(includeSpaces: spaceObservationEnabled)
        applyProjection(sample)
    }

    private func applyProjection(_ sample: DesktopObservation.Sample) {
        guard sample.sequence > latestProjectionSequence else { return }
        latestProjectionSequence = sample.sequence
        let snapshot = sample.snapshot
        if snapshot != nil || sample.spaceAvailability == nil { latestSnapshot = snapshot }
        _ = determineSpacesSupport(snapshot)
        let targets: [(screenID: String, screen: ScreenInfo?)] = if isConnected {
            externalScreens.map { ($0.id, $0) }
        } else if case .remembered(let screenID, _) = screenPresence {
            [(screenID, nil)]
        } else {
            []
        }
        let key = displayedKey
        let record = key.flatMap { library.record(for: $0) }
        let labels = Self.screenLabels(for: screenProvider.screens().map { ($0.id, $0.name, $0.portLocation) })
        let outcomes = restoreSession.request?.key == key ? (restoreSession.request?.outcomes ?? [:]) : [:]

        var next: [String: ScreenProjection] = [:]
        for (screenID, screen) in targets {
            var spaceGroups: [SpaceGroup] = []
            var differs = false
            if spaceObservationEnabled {
                spaceGroups = Self.spaceGroups(record: record, screenID: screenID, snapshot: snapshot,
                                               targetConnected: screen != nil, outcomes: outcomes, labels: labels)
                differs = Self.spaceConfigurationDiffers(saved: record?.saved?.screen(screenID), snapshot: snapshot,
                                                         targetConnected: screen != nil)
            }
            next[screenID] = ScreenProjection(spaceGroups: spaceGroups, spaceConfigurationDiffers: differs,
                                              visibleApps: Self.untracked(in: sample.windows, on: screen, excluding: []))
        }
        projectionsByScreen = next
    }

    /// 저장이 잡아갈 창과 같은 규칙 — 중심점이 이 화면이고, 최소화·전체화면·숨김이 아닌 표준 창.
    static func untracked(in windows: [WindowInfo], on screen: ScreenInfo?,
                          excluding targets: Set<String>) -> [UntrackedApp] {
        guard let screen, !screen.isBuiltin else { return [] }
        var seen = targets
        var out: [UntrackedApp] = []
        for window in windows
        where !window.isMinimized && !window.isFullscreen && !window.isHidden && screen.contains(window) {
            if seen.insert(window.appBundleID).inserted {
                out.append(UntrackedApp(bundleID: window.appBundleID, displayName: window.appName))
            }
        }
        return out
    }

    /// 카드 체크박스의 유일한 동작 — 「이 앱을 다루나」 (작업 환경 전체에 적용, D4).
    /// 끄면 저장·수집·복원에서 빠지되 창 위치 기록은 남는다. 켜면 다시 기본 포함이다.
    public func setTracked(_ bundleID: String, _ tracked: Bool, on screenID: String) async {
        guard let key = displayedKey else { return }
        let rows = sections.flatMap { $0.presentApps + $0.absentSavedApps + $0.excludedApps }
        let name = rows.first { $0.bundleID == bundleID }?.displayName ?? bundleID
        switch library.setAppEnabled(bundleID, tracked, displayName: name, in: key) {
        case .applied:
            captureNotice = nil
            if !tracked { restoreSession.cancelItems(bundleID: bundleID); publishResults() }
            await refreshCollectTargets()
            await refreshProjection()
        case .unchanged, .failed:
            return
        }
    }

    /// 앱의 저장 기록을 이 환경에서 지운다 (S10). 창이 외장 화면에 남아 있으면 다음 저장에 다시 포함된다.
    public func remove(_ bundleID: String, on screenID: String) async {
        guard let key = displayedKey, library.removeApp(bundleID, in: key) else { return }
        restoreSession.cancelItems(bundleID: bundleID)
        publishResults()
        await refreshCollectTargets()
        await refreshProjection()
    }

    public func dismissStoreNotice() { library.dismissTrouble() }

    public func exportDiagnostics(to url: URL) throws { try diagnostics.export(to: url) }

    /// UserDefaults 키 — 읽기·쓰기가 같은 이름을 쓰도록 한곳에 (오타는 조용한 버그다).
    enum Keys {
        static let settingsVersion = "settingsVersion"
        static let restoreMode = "restoreMode"
        static let restoreMinimized = "restoreMinimized"
        static let autoSave = "autoSave"
        static let reopenClosedApps = "lab.reopenClosedApps"
        static let reviveWindowlessApps = "lab.reviveWindowlessApps"
        static let openMissingWindows = "lab.openMissingWindows"
        static let directWindowAssignment = "lab.directWindowAssignment"
        static let legacyLabAutoSlot = "labAutoSlot"
        static let legacyReopenWindowless = "reopenWindowless"
    }
}
