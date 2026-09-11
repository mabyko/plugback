import Combine
import CoreGraphics
import Foundation

/// 저장된 작업 환경 전부와 그것을 쓰는 규칙 전부 (D2·D4·D7·D9).
///
/// 숨기는 것: 작업 환경 키 규약, 마지막 저장본과 저장 대기 이력의 구별, 수동 저장이 옛 이력·늦은 관찰을 무효화하는
/// 순서 번호, 같은 내용의 자동 저장 생략, 실행 중 창 연결(저장 자리 ↔ windowServerID)의 수명, 같은 환경에서
/// 닫힌 창의 제외 목록, 앱 포함·제외, 읽기 실패 시 모든 변경을 동결하는 금지, 쓰기 성공 뒤에만 상태를 공개하는 순서.
///
/// ObservableObject다 — 카드가 이 상태를 직접 그린다. 컨트롤러는 변경을 자기 것으로 전달만 한다.
@MainActor
final class WorkspaceLibrary: ObservableObject {
    /// 실행 중 창 연결. windowServerID는 창이 살아 있는 동안만 같은 창을 뜻하며 파일에 쓰지 않는다.
    struct WindowLink: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case live
            /// 창이 사라진 것을 관찰한 작업 환경. nil은 외장 화면이 없던 때다 (W19·W20).
            case lost(in: WorkspaceKey?)
        }
        let bundleID: String
        let windowServerID: CGWindowID
        var status: Status
        /// 이 창을 외장 화면에서 마지막으로 확인한 작업 환경. 환경이 바뀌면 잊는다 — 같은 환경에서 외장에 있던 창이
        /// 내장으로 간 것만 사용자의 이동이고, 화면 분리·재연결로 macOS가 옮긴 창은 아니다 (W17·S17).
        var seenIn: WorkspaceKey? = nil
    }

    /// 저장 대기 이력 — 마지막 유효 관찰. 저장으로 확정되기 전에는 복원 기준을 바꾸지 않는다.
    struct PendingHistory: Equatable, Sendable {
        var snapshot: WorkspaceSnapshot
        var sequence: Int
        var collectedAt: Date
        /// 이번 이력에서 실제로 확인한 화면별 Space 이름 — 「이번에 확인함」과 「이전 기록 유지」를 구별한다 (4.2절).
        var observedSpaceNames: [String: Set<String>]
    }

    enum ConfirmOutcome: Equatable { case saved, nothingToSave, failed, disabled }

    enum AppEditOutcome: Equatable { case applied, unchanged, failed }

    private let store: ProfileStore
    @Published private(set) var records: [WorkspaceKey: WorkspaceRecord]
    @Published private(set) var pending: [WorkspaceKey: PendingHistory] = [:]
    @Published private(set) var lastCollectedAt: Date?
    @Published private(set) var trouble: ProfileStore.Trouble?
    private(set) var links: [UUID: WindowLink] = [:]
    /// 저장 자리의 소유 작업 환경 — 닫힘을 어느 환경에서 관찰했는지 판정할 때 쓴다.
    private var owners: [UUID: WorkspaceKey] = [:]
    /// 이 번호보다 오래된 관찰은 이력으로 받지 않는다 — 수동 저장 뒤 늦게 도착한 옛 관찰, 자동 저장 OFF 전의 관찰 (A22·A24).
    private var minimumSequence: [WorkspaceKey: Int] = [:]
    private var globalMinimumSequence = 0

    /// 읽기 실패·형식 미지원을 첫 실행처럼 보이지 않게 한다 — 알림을 닫아도 변경 금지는 유지된다.
    let isSaveBlocked: Bool
    let migratedFromLegacy: Bool

    /// 자동 저장 (D2, 최초 ON). 끄면 저장 대기 이력을 버리고 마지막 저장본은 유지한다 (D7).
    private(set) var isAutoSaveEnabled: Bool

    init(store: ProfileStore, isAutoSaveEnabled: Bool, preferLegacyAutoSlots: Bool = false) {
        self.store = store
        self.isAutoSaveEnabled = isAutoSaveEnabled
        let outcome = store.load(preferLegacyAutoSlots: preferLegacyAutoSlots)
        records = outcome.workspaces
        trouble = outcome.trouble
        migratedFromLegacy = outcome.migratedFromLegacy
        switch outcome.trouble {
        case .unreadable, .unsupportedVersion: isSaveBlocked = true
        default: isSaveBlocked = false
        }
        for (key, record) in records {
            for placement in record.saved?.placements ?? [] { owners[placement.id] = key }
        }
    }

    // MARK: - 읽기

    func record(for key: WorkspaceKey) -> WorkspaceRecord? { records[key] }
    /// 복원 소스 — 수동·자동 구분 없이 마지막으로 저장이 완료된 기록 (D2).
    func saved(for key: WorkspaceKey) -> WorkspaceSnapshot? { records[key]?.saved }
    var allRecords: [WorkspaceRecord] { records.values.sorted { $0.key < $1.key } }
    /// 이름순 첫 저장본의 첫 화면 — 시작 직후의 빈 상태에서 마지막 화면 이름을 보여주는 데 쓴다.
    var firstRememberedScreen: ScreenRecord? {
        records.values.compactMap { $0.saved?.screens.first }.sorted { $0.name < $1.name }.first
    }

    func hasPendingChanges(for key: WorkspaceKey) -> Bool {
        guard let history = pending[key] else { return false }
        guard let saved = records[key]?.saved else { return !history.snapshot.placements.isEmpty }
        return !saved.contentEquals(history.snapshot)
    }

    /// 현재 이력 또는 저장본에서 이 앱의 포함 여부. 기록이 없는 앱은 기본 포함이다 (D4).
    func isEnabled(_ bundleID: String, in key: WorkspaceKey) -> Bool {
        records[key]?.isEnabled(bundleID) ?? true
    }

    /// 실행 중 이동 관찰이 따라갈 앱 — 저장본·이력의 앱과 포함 상태의 앱 전부.
    func observedBundleIDs(for key: WorkspaceKey) -> [String] {
        var out = Set<String>()
        if let record = records[key] {
            out.formUnion(record.apps.filter(\.isEnabled).map(\.bundleID))
            out.formUnion(record.saved?.placements.map(\.bundleID) ?? [])
        }
        out.formUnion(pending[key]?.snapshot.placements.map(\.bundleID) ?? [])
        if let record = records[key] { out.subtract(record.excludedBundleIDs) }
        return Array(out).sorted()
    }

    // MARK: - 설정

    func setAutoSave(_ enabled: Bool, currentSequence: Int) {
        guard enabled != isAutoSaveEnabled else { return }
        isAutoSaveEnabled = enabled
        if enabled {
            // 다시 켠 뒤 시작한 관찰만 받는다 — OFF 전의 늦은 관찰이 이력을 되살리지 않는다 (A24).
            globalMinimumSequence = currentSequence
        } else {
            pending.removeAll() // 저장 전 이력을 지우고 마지막 저장본은 유지한다 (D7)
        }
    }

    // MARK: - 저장

    /// 수동 저장 (F-03). 관찰한 창은 갱신하고 관찰하지 못한 기록은 보존하되, 같은 환경에서 닫힌 창은 뺀다.
    /// 성공하면 이 환경의 저장 대기 이력·닫힌 창 제외를 정리하고 더 오래된 관찰을 무효화한다.
    @discardableResult
    func capture(key: WorkspaceKey, screens: [ScreenInfo], sample: DesktopObservation.Sample,
                 snapshot: SpaceSnapshot?) -> Bool {
        guard !isSaveBlocked else { return false }
        let record = records[key] ?? WorkspaceRecord(key: key)
        let base = pending[key]?.snapshot ?? record.saved
        var observation = CaptureEngine.observe(
            windows: sample.windows, screens: screens, snapshot: snapshot, base: base,
            links: liveLinks(for: base), excludedBundleIDs: record.excludedBundleIDs,
            closedPlacementIDs: record.closedPlacementIDs, droppable: droppable(in: key)
        )
        observation = Self.adoptUnlinkedPlacements(observation, base: base, links: liveLinks(for: base), screens: screens)
        var next = record
        next.apps = Self.mergeApps(record.apps, observed: observation.observedApps)
        next.saved = WorkspaceSnapshot(key: key, screens: observation.screens,
                                       placements: observation.placements, savedAt: Date(), savedBy: .manual)
        next.closedPlacementIDs = []
        var nextRecords = records
        nextRecords[key] = next
        guard persist(nextRecords) else { return false }
        adoptLinks(observation.links, bundleIDs: next.saved?.placements ?? [], seenIn: key)
        for placement in observation.placements { owners[placement.id] = key }
        pending.removeValue(forKey: key)
        minimumSequence[key] = sample.sequence
        return true
    }

    /// 수집 — 지금 배치를 저장 대기 이력에 담는다. 파일에는 닿지 않는다. 자동 저장 OFF에서도 창 연결·닫힘 판정은 갱신한다.
    /// - isComplete: 실행 중 전체 앱을 열거한 관찰만 창의 부재를 닫힘으로 판정한다.
    func collect(key: WorkspaceKey, screens: [ScreenInfo], sample: DesktopObservation.Sample,
                 snapshot: SpaceSnapshot?, runningBundleIDs: Set<String>) {
        guard !isSaveBlocked else { return }
        guard sample.sequence > max(minimumSequence[key] ?? 0, globalMinimumSequence) else { return }
        let record = records[key] ?? WorkspaceRecord(key: key)
        let base = pending[key]?.snapshot ?? record.saved
        var observation = CaptureEngine.observe(
            windows: sample.windows, screens: screens, snapshot: snapshot, base: base,
            links: liveLinks(for: base), excludedBundleIDs: record.excludedBundleIDs,
            closedPlacementIDs: record.closedPlacementIDs, droppable: droppable(in: key)
        )
        // 위치 기반 재대응 — 연결이 없는 창(재실행 뒤 등)이 같은 앱·화면·Space의 연결 없는 저장 자리에 놓여 있으면
        // 그 자리를 갱신한다. 그러지 않으면 재실행마다 같은 자리에 기록이 겹겹이 쌓인다.
        observation = Self.adoptUnlinkedPlacements(observation, base: base, links: liveLinks(for: base), screens: screens)

        var closedNow: Set<UUID> = []
        for (placementID, link) in links where link.status == .live && Self.vanished(link, in: sample) {
            links[placementID]?.status = .lost(in: key)
            if owners[placementID] == key { closedNow.insert(placementID) }
        }
        if !closedNow.isEmpty {
            observation.placements.removeAll { closedNow.contains($0.id) }
            var next = record
            next.closedPlacementIDs.formUnion(closedNow)
            var nextRecords = records
            nextRecords[key] = next
            // 제외는 안전장치라 쓰기 실패여도 메모리에서는 유지한다.
            if !persist(nextRecords) { records[key] = next }
        }
        adoptLinks(observation.links, bundleIDs: observation.placements, seenIn: key)
        for placement in observation.placements { owners[placement.id] = key }
        lastCollectedAt = Date()

        guard isAutoSaveEnabled else { return }
        var apps = records[key]?.apps ?? []
        let mergedApps = Self.mergeApps(apps, observed: observation.observedApps)
        if mergedApps != apps {
            apps = mergedApps
            var next = records[key] ?? WorkspaceRecord(key: key)
            next.apps = apps
            var nextRecords = records
            nextRecords[key] = next
            if !persist(nextRecords) { records[key] = next }
        }
        pending[key] = PendingHistory(
            snapshot: WorkspaceSnapshot(key: key, screens: observation.screens,
                                        placements: observation.placements, savedAt: nil, savedBy: .auto),
            sequence: sample.sequence, collectedAt: Date(),
            observedSpaceNames: observation.observedSpaceNames
        )
    }

    /// 외장 화면이 없거나 다른 환경에 있을 때도 창 연결의 생사는 따라간다 (W19·W20).
    func trackLinks(sample: DesktopObservation.Sample, currentKey: WorkspaceKey?) {
        for (placementID, link) in links where link.status == .live && Self.vanished(link, in: sample) {
            links[placementID]?.status = .lost(in: currentKey)
            if let currentKey, owners[placementID] == currentKey { markClosed([placementID], in: currentKey) }
        }
    }

    /// 작업 환경이 바뀌었다 — 외장에서 확인한 기록을 잊는다. 새 환경에서 외장에 있는 것을 다시 본 뒤에야 내장 이동을 판정한다.
    func noteWorkspaceChanged() {
        for id in links.keys { links[id]?.seenIn = nil }
    }

    /// 창 부재의 근거는 존재하는 창 전부의 목록이다 — 표준 창 열거는 다른 Space의 창을 빼먹는다 (F-03.6).
    /// 목록을 얻지 못했거나 그 앱의 조회에 실패했으면 닫힘으로 판정하지 않는다 (O05·O07).
    private static func vanished(_ link: WindowLink, in sample: DesktopObservation.Sample) -> Bool {
        guard let existing = sample.existingWindowServerIDs,
              !sample.unavailableBundleIDs.contains(link.bundleID) else { return false }
        return !existing.contains(link.windowServerID)
            && !sample.windows.contains { $0.windowServerID == link.windowServerID }
    }

    private func droppable(in key: WorkspaceKey) -> Set<UUID> {
        Set(links.filter { $0.value.status == .live && $0.value.seenIn == key }.keys)
    }

    /// 앱 종료 알림 — 그 앱의 살아 있던 창은 지금 환경에서 닫힌 것이다.
    func noteAppTerminated(_ bundleID: String, currentKey: WorkspaceKey?) {
        var closed: [WorkspaceKey: Set<UUID>] = [:]
        for (placementID, link) in links where link.bundleID == bundleID && link.status == .live {
            links[placementID]?.status = .lost(in: currentKey)
            if let currentKey, owners[placementID] == currentKey {
                closed[currentKey, default: []].insert(placementID)
            }
        }
        for (key, ids) in closed { markClosed(ids, in: key) }
    }

    /// 같은 환경에서 닫힌 것으로 확인한 저장 자리를 그 환경의 다음 저장 성공까지 제외한다 (D9).
    func markClosed(_ placementIDs: Set<UUID>, in key: WorkspaceKey) {
        guard !placementIDs.isEmpty else { return }
        var next = records[key] ?? WorkspaceRecord(key: key)
        next.closedPlacementIDs.formUnion(placementIDs)
        pending[key]?.snapshot.placements.removeAll { placementIDs.contains($0.id) }
        var nextRecords = records
        nextRecords[key] = next
        if !persist(nextRecords) { records[key] = next }
    }

    /// 자동 저장 확정 — 환경 이탈·정상 종료 전. 마지막 저장본과 내용이 같으면 저장을 생략한다 (D2).
    @discardableResult
    func confirm(key: WorkspaceKey) -> ConfirmOutcome {
        guard !isSaveBlocked else { return .failed }
        guard isAutoSaveEnabled else { return .disabled }
        guard let history = pending[key] else { return .nothingToSave }
        var next = records[key] ?? WorkspaceRecord(key: key)
        // 닫힌 창 제외가 남아 있으면 내용이 같아 보여도 저장한다 — 제외 정리와 새 창의 자리 확정은 저장 완료와 함께 간다 (W30).
        if let saved = next.saved, next.closedPlacementIDs.isEmpty, saved.contentEquals(history.snapshot) {
            pending.removeValue(forKey: key)
            return .nothingToSave
        }
        if next.saved == nil, history.snapshot.placements.isEmpty { return .nothingToSave }
        next.saved = WorkspaceSnapshot(key: key, screens: history.snapshot.screens,
                                       placements: history.snapshot.placements,
                                       savedAt: Date(), savedBy: .auto)
        next.closedPlacementIDs = []
        var nextRecords = records
        nextRecords[key] = next
        guard persist(nextRecords) else { return .failed }
        pending.removeValue(forKey: key)
        minimumSequence[key] = history.sequence
        return .saved
    }

    /// 모든 환경의 대기 이력을 확정한다 — 정상 종료 전 마지막 기회. 하나라도 쓰기에 실패하면 실패다.
    func confirmAll() -> ConfirmOutcome {
        var outcome = ConfirmOutcome.nothingToSave
        for key in Array(pending.keys) {
            switch confirm(key: key) {
            case .failed: return .failed
            case .saved: outcome = .saved
            case .nothingToSave, .disabled: continue
            }
        }
        return outcome
    }

    var hasAnyPendingChanges: Bool { pending.keys.contains { hasPendingChanges(for: $0) } }

    // MARK: - 창 연결

    func link(for placementID: UUID) -> WindowLink? { links[placementID] }

    /// 사용자가 확정한 연결 (D3). 같은 실제 창·저장 자리를 확인할 수 있는 동안 다음 복원에도 재사용한다.
    func confirmLink(placementID: UUID, bundleID: String, windowServerID: CGWindowID) {
        for (id, link) in links where link.windowServerID == windowServerID && id != placementID {
            links.removeValue(forKey: id) // 같은 실제 창을 두 자리에 두지 않는다
        }
        links[placementID] = WindowLink(bundleID: bundleID, windowServerID: windowServerID, status: .live)
    }

    private func liveLinks(for base: WorkspaceSnapshot?) -> [UUID: CGWindowID] {
        guard let base else { return [:] }
        var out: [UUID: CGWindowID] = [:]
        for placement in base.placements {
            if let link = links[placement.id], link.status == .live { out[placement.id] = link.windowServerID }
        }
        return out
    }

    private func adoptLinks(_ observed: [UUID: CGWindowID], bundleIDs placements: [WindowPlacement], seenIn key: WorkspaceKey) {
        let bundleByPlacement = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0.bundleID) })
        for (placementID, wsid) in observed {
            guard let bundleID = bundleByPlacement[placementID] else { continue }
            for (other, link) in links where link.windowServerID == wsid && other != placementID {
                links.removeValue(forKey: other)
            }
            links[placementID] = WindowLink(bundleID: bundleID, windowServerID: wsid, status: .live, seenIn: key)
        }
    }

    private static func adoptUnlinkedPlacements(
        _ observation: CaptureEngine.Observation, base: WorkspaceSnapshot?,
        links: [UUID: CGWindowID], screens: [ScreenInfo]
    ) -> CaptureEngine.Observation {
        guard let base else { return observation }
        let baseIDs = Set(base.placements.map(\.id))
        var unlinkedBase = base.placements.filter { links[$0.id] == nil && observation.placements.contains($0) }
        var newOnes = observation.placements.filter { !baseIDs.contains($0.id) }
        var result = observation

        // 1차: 같은 앱·화면·Space. 2차: Space 없는 옛 기록(구버전 이전·flat 저장)은 같은 앱·화면의 어느 Space 창이든
        // 이어받아 Space를 지정한다 — 「다시 저장하면 지정」이 중복 기록이 아니라 승격이어야 한다.
        for pass in 0..<2 {
            guard !unlinkedBase.isEmpty, !newOnes.isEmpty else { break }
            var groups: [String: ([WindowPlacement], [WindowPlacement])] = [:]
            for old in unlinkedBase where pass == 0 || old.space == nil {
                groups["\(old.bundleID)|\(old.screenID)|\(pass == 0 ? old.space?.opaqueName ?? "" : "*")", default: ([], [])].0.append(old)
            }
            for new in newOnes {
                groups["\(new.bundleID)|\(new.screenID)|\(pass == 0 ? new.space?.opaqueName ?? "" : "*")", default: ([], [])].1.append(new)
            }
            for (_, pair) in groups {
                let (olds, news) = pair
                guard !olds.isEmpty, !news.isEmpty,
                      let frame = screens.first(where: { $0.id == olds[0].screenID })?.frame else { continue }
                let slots = olds.map { WindowMatching.Slot(id: $0.id, target: $0.unitRect.frame(in: frame)) }
                let candidates = news.enumerated().map {
                    WindowMatching.Candidate(index: $0.offset, frame: $0.element.unitRect.frame(in: frame))
                }
                for (oldID, newIndex) in WindowMatching.assign(slots: slots, candidates: candidates) {
                    let new = news[newIndex]
                    guard let oldIndex = result.placements.firstIndex(where: { $0.id == oldID }) else { continue }
                    var adopted = result.placements[oldIndex]
                    adopted.displayName = new.displayName
                    adopted.unitRect = new.unitRect
                    adopted.space = new.space
                    result.placements[oldIndex] = adopted
                    result.placements.removeAll { $0.id == new.id }
                    if let wsid = result.links.removeValue(forKey: new.id) { result.links[oldID] = wsid }
                    unlinkedBase.removeAll { $0.id == oldID }
                    newOnes.removeAll { $0.id == new.id }
                }
            }
        }

        // Space 없는 옛 기록은 앱당 하나였다 — 같은 앱·화면의 창을 Space와 함께 확인했으면 그 기록에 흡수된 것이다.
        // ponytail: 흡수는 Space가 생긴 관찰에 한정한다. flat 저장끼리는 그대로 둔다.
        let observedNow = result.placements.filter { result.links[$0.id] != nil && $0.space != nil }
        for old in unlinkedBase where old.space == nil {
            guard observedNow.contains(where: { $0.bundleID == old.bundleID && $0.screenID == old.screenID }) else { continue }
            result.placements.removeAll { $0.id == old.id }
        }
        return result
    }

    // MARK: - 앱 선택·삭제

    /// 앱을 포함·제외한다 (D4). 제외해도 창 위치 기록은 남는다 — 다시 켜면 저장돼 있던 자리로 돌아온다 (US-006 AC-2).
    @discardableResult
    func setAppEnabled(_ bundleID: String, _ enabled: Bool, displayName: String, in key: WorkspaceKey) -> AppEditOutcome {
        guard !isSaveBlocked else { return .failed }
        var next = records[key] ?? WorkspaceRecord(key: key)
        if let index = next.apps.firstIndex(where: { $0.bundleID == bundleID }) {
            guard next.apps[index].isEnabled != enabled else { return .unchanged }
            next.apps[index].isEnabled = enabled
        } else {
            guard !enabled else { return .unchanged }
            next.apps.append(AppSelection(bundleID: bundleID, displayName: displayName, isEnabled: false))
        }
        var nextRecords = records
        nextRecords[key] = next
        guard persist(nextRecords) else { return .failed }
        return .applied // 이력의 기록도 남긴다 — 제외는 저장·복원 대상에서 빼는 것이지 기록을 지우는 것이 아니다
    }

    /// 앱의 저장 기록과 선택을 이 환경에서 지운다 (S10) — 창이 외장 화면에 남아 있으면 다음 저장에 다시 기본 포함된다.
    @discardableResult
    func removeApp(_ bundleID: String, in key: WorkspaceKey) -> Bool {
        guard !isSaveBlocked, var next = records[key] else { return false }
        let removedIDs = Set(next.saved?.placements.filter { $0.bundleID == bundleID }.map(\.id) ?? [])
        next.saved?.placements.removeAll { $0.bundleID == bundleID }
        next.closedPlacementIDs.subtract(removedIDs)
        next.apps.removeAll { $0.bundleID == bundleID } // 포함·제외 선택도 함께 잊는다 — 창이 남아 있으면 다시 기본 포함이다
        var nextRecords = records
        nextRecords[key] = next
        guard persist(nextRecords) else { return false }
        pending[key]?.snapshot.placements.removeAll { $0.bundleID == bundleID }
        for id in removedIDs { links.removeValue(forKey: id); owners.removeValue(forKey: id) }
        return true
    }

    /// 저장 자리 하나를 지운다 — 확인 목록에서 더 이상 필요 없는 자리를 정리할 때.
    @discardableResult
    func removePlacement(_ placementID: UUID, in key: WorkspaceKey) -> Bool {
        guard !isSaveBlocked, var next = records[key] else { return false }
        next.saved?.placements.removeAll { $0.id == placementID }
        next.closedPlacementIDs.remove(placementID)
        var nextRecords = records
        nextRecords[key] = next
        guard persist(nextRecords) else { return false }
        pending[key]?.snapshot.placements.removeAll { $0.id == placementID }
        links.removeValue(forKey: placementID)
        owners.removeValue(forKey: placementID)
        return true
    }

    /// 작업 환경 통째 삭제 (F-05.6). 저장본·앱 선택·제외 목록·이력을 함께 버린다.
    @discardableResult
    func remove(key: WorkspaceKey) -> Bool {
        guard !isSaveBlocked else { return false }
        var nextRecords = records
        nextRecords.removeValue(forKey: key)
        guard persist(nextRecords) else { return false }
        pending.removeValue(forKey: key)
        for (id, owner) in owners where owner == key { links.removeValue(forKey: id); owners.removeValue(forKey: id) }
        return true
    }

    func dismissTrouble() { trouble = nil }

    // MARK: - 내부

    private static func mergeApps(_ apps: [AppSelection], observed: [String: String]) -> [AppSelection] {
        var out = apps
        for (bundleID, name) in observed.sorted(by: { $0.key < $1.key }) {
            if let index = out.firstIndex(where: { $0.bundleID == bundleID }) {
                out[index].displayName = name
            } else {
                out.append(AppSelection(bundleID: bundleID, displayName: name, isEnabled: true))
            }
        }
        return out
    }

    /// 디스크가 성공한 뒤에만 메모리 상태를 공개한다.
    @discardableResult
    private func persist(_ next: [WorkspaceKey: WorkspaceRecord]) -> Bool {
        guard !isSaveBlocked else { return false }
        do {
            try store.save(next)
        } catch {
            trouble = .writeFailed
            return false
        }
        records = next
        if trouble == .writeFailed { trouble = nil }
        return true
    }
}
