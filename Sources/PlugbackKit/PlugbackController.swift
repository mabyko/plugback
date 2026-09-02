import Combine
import CoreGraphics
import Foundation

/// 복원 모드 (F-05.4). 자동 슬롯의 수집 on/off와는 독립이다.
public enum RestoreMode: String, Sendable {
    case automatic, manual
}

/// 실험실 · 자동 슬롯의 후보 사용과 기록 시점.
public enum AutoSlotUpdateMode: String, CaseIterable, Sendable {
    case onDisconnect
    case immediate
    case liveUntilDisconnect
}

/// captureNow의 반환 — 조용한 거부가 없다 (restoreNow와 같은 원칙).
public enum CaptureOutcome: Equatable, Sendable {
    /// 저장 완료 — 연결된 모든 외장 화면의 체크된 대상 앱 수 합.
    case captured(appCount: Int)
    case notAuthorized
    case notConnected
    case restoringInProgress
    /// 프로필 파일을 읽지 못한 실행 — 덮어쓰기 방지로 저장이 차단됐다 (F-04.2).
    case saveBlocked
    /// 실행 중 프로필 파일에 쓰지 못했다. 이전 상태는 유지되고 다음 저장에서 재시도할 수 있다.
    case saveFailed
    /// Space reader는 있지만 안정된 snapshot을 얻지 못해 기존 배치를 보존했다.
    case spaceObservationUnavailable
}

/// 카드에 잠깐 남기는 저장 관련 명시적 동작의 결과. 성공과 관찰 실패가 동시에 보일 수 없다.
public enum CaptureNotice: Equatable, Sendable {
    case captured(appCount: Int)
    case spaceObservationUnavailable
}

/// restoreNow의 반환 — 실행되지 않은 경로도 성공과 구별된다. 호출자는 published를 뒤져 추론하지 않는다.
public enum RestoreOutcome: Equatable, Sendable {
    /// 복원이 끝났다. 비어 있으면 프로필 있는 화면이 없었다는 뜻.
    case restored([RestoreResult])
    case notAuthorized
    case notConnected
    case alreadyRestoring
}

/// 헤드리스 파사드 — UI 없이 완결된다. UI는 이 상태의 표현일 뿐이다 (docs/ARCHITECTURE.md).
@MainActor
public final class PlugbackController: ObservableObject {
    /// 카드가 보여주는 화면 상태 (3상태). 분리돼도 기억으로 강등될 뿐 지워지지 않는다 —
    /// 빈 상태에서도 카드는 비지 않는다 (ARCHITECTURE 고정 결정).
    @Published public private(set) var screenPresence: ScreenPresence = .none

    /// 파생 편의 — 저장 플래그가 아니라 screenPresence에서 계산되므로 어긋날 수 없다.
    public var isConnected: Bool {
        if case .connected = screenPresence { return true } else { return false }
    }

    /// 복원 진행 중 — 재진입 가드이자 버튼 비활성용 UI 상태.
    @Published public private(set) var isRestoring = false
    /// 한 번의 창·Space 관찰에서 파생한 화면별 카드 값. 사전을 따로 발행하지 않아
    /// 화면 키와 갱신 시점이 갈라질 상태를 만들지 않는다. profile·복원 소스·결과는 slots와
    /// 복원 수명에 실시간으로 따라가므로 이 값에 복사하지 않고 section에서 붙인다.
    private struct ScreenProjection {
        let spaceGroups: [SpaceGroup]
        let spaceConfigurationDiffers: Bool
        let untrackedApps: [UntrackedApp]
    }
    @Published private var projectionsByScreen: [String: ScreenProjection] = [:]
    /// async 관찰은 MainActor에서도 완료 순서가 바뀔 수 있다. 더 오래된 sample은 게시하지 않는다.
    private var latestProjectionSequence = 0

    /// 방금 저장의 확인 또는 Space 관찰 실패. 카드를 다시 열면 사라진다.
    @Published public private(set) var captureNotice: CaptureNotice?
    /// 기존 성공 확인값 — transient notice 한곳에서 파생한다.
    public var lastCaptureCount: Int? {
        guard case .captured(let count) = captureNotice else { return nil }
        return count
    }
    /// 저장소 문제 알림 (F-04.2). 사용자가 확인하면 사라진다 — 영구 배너가 아니다.
    /// **파생이다** — 슬롯 모듈이 유일한 출처다. 사본을 들면 손으로 맞춰야 하고, 그러면 어긋난다.
    public var storeNotice: ProfileStore.Trouble? { slots.trouble }
    /// 알림을 닫아도 프로세스 수명 동안 유지되는 저장 금지 상태.
    public var isSaveBlocked: Bool { slots.isSaveBlocked }
    /// 복원 모드 (F-05.4). 기본값 자동, 변경은 보존된다.
    @Published public var restoreMode: RestoreMode {
        didSet { defaults.set(restoreMode.rawValue, forKey: Keys.restoreMode) }
    }

    /// 최소화된 창도 Dock에서 꺼내 복원할지 (F-02.2 예외 설정). 기본 꺼짐 — 최소화는 사용자의 의도다.
    @Published public var restoreMinimized: Bool {
        didSet {
            defaults.set(restoreMinimized, forKey: Keys.restoreMinimized)
        }
    }

    /// 실행 중인데 창이 없는 앱에 새 창을 열게 해 복원할지 (F-02.2 예외 설정). 기본 꺼짐.
    /// 꺼진 앱을 실행하지는 않는다 — F-02.1은 그대로다.
    @Published public var reopenWindowless: Bool {
        didSet {
            defaults.set(reopenWindowless, forKey: Keys.reopenWindowless)
        }
    }

    /// 실험실 · 자동 슬롯 (기본 꺼짐). 켜면 방문한 외장 Space의 표준 창 배치를 모으고,
    /// 화면을 분리할 때 자동 슬롯에 확정한다. 수동 저장은 이 슬롯에 닿지 않는다.
    /// 끄면 자동 슬롯이 복원 소스 후보에서 빠진다 — 파일은 남아 다시 켜면 이어진다.
    @Published public var labAutoSlot: Bool {
        didSet {
            guard labAutoSlot != oldValue else { return }
            defaults.set(labAutoSlot, forKey: Keys.labAutoSlot)
            slots.isLabEnabled = labAutoSlot // 씨앗 복사·후보 폐기는 슬롯 모듈의 일이다
            resetRestoreSession() // 복원 소스가 manual ↔ auto로 바뀌었으므로 진행 중 안내 폐기
            pendingSpaceRefresh = false
            syncCollectTrigger()
            refreshProjectionAfterStateChange()
        }
    }

    /// 실험실 · 자동 슬롯의 반영 방식. 기존 사용자는 분리/종료 확정을 그대로 쓴다.
    @Published public var autoSlotUpdateMode: AutoSlotUpdateMode {
        didSet {
            guard autoSlotUpdateMode != oldValue else { return }
            defaults.set(autoSlotUpdateMode.rawValue, forKey: Keys.autoSlotUpdateMode)
            slots.updateMode = autoSlotUpdateMode
            resetRestoreSession()
            pendingSpaceRefresh = false
            refreshProjectionAfterStateChange()
        }
    }

    /// 설정 창과 카드가 나란히 열려 있어도 Space 그룹과 복원 소스가 낡지 않게 갱신한다.
    private func refreshProjectionAfterStateChange() {
        Task { await refreshProjection() }
    }

    /// UUID는 맞는데 지문이 다른 화면이 있었다 — 복원하지 않았다 (F-01.4).
    /// 결과에서 파생한다 — 별도 저장 플래그를 두지 않는다.
    public var identityMismatch: Bool {
        externalScreens.contains { resultsByScreen[$0.id]?.screenSkipReason == .fingerprintMismatch }
    }

    /// 권한 판정 어댑터 — 앱이 주입한다 (US-010 AC-2). 기본 true — 페이크 없는 테스트 편의.
    public var authorizationCheck: () -> Bool = { true }

    /// 마지막으로 확인한 권한 상태. UI는 시스템 API를 직접 읽지 않고 여기 바인딩한다.
    @Published public private(set) var isAuthorized = true

    /// 권한을 다시 판정해 상태를 갱신한다. 모든 명령이 내부에서 이 게이트를 지난다 —
    /// 새 호출자가 게이트를 잊을 방법이 없다.
    @discardableResult
    public func checkAuthorization() -> Bool {
        let ok = authorizationCheck()
        if ok != isAuthorized { isAuthorized = ok }
        return ok
    }

    /// 슬롯 규칙 전부가 여기 산다 — 컨트롤러는 「이 화면의 프로필」만 묻는다.
    private let slots: ProfileSlots
    private var slotChanges: AnyCancellable?
    @Published private var resultsByScreen: [String: RestoreResult] = [:]
    /// 마지막 복원 회차가 끝난 시각. 결과는 앱이 도는 동안 남으므로,
    /// 시각이 없으면 어제의 「이동 2」가 방금 복원으로 읽힌다.
    @Published public private(set) var lastRestoredAt: Date?

    /// 카드가 화면 하나를 그리는 단위 — 프로필·복원 소스·저장하지 않는 앱·마지막 결과가
    /// 전부 그 화면의 것이다. 첫 화면만 보여주던 카드가 화면을 빠뜨리지 않게 하는 인터페이스.
    public struct SpaceGroup: Identifiable, Equatable, Sendable {
        public enum RegularState: Equatable, Sendable {
            case current
            case inactive
            case otherDisplay
            case missing
            case unknown
        }

        public enum Kind: Equatable, Sendable {
            case regular(number: Int, state: RegularState)
            case unresolved
        }

        public enum Guide: Equatable, Sendable {
            case move(sourceScreenName: String, destinationScreenName: String)
            case visit(screenName: String)
            case unavailable
        }

        public let id: String
        public let kind: Kind
        public let apps: [TargetApp]
        public let guide: Guide?
    }

    public struct ScreenSection: Identifiable, Equatable, Sendable {
        public var id: String { screenID }
        public let screenID: String
        public let name: String
        public let profile: Profile?
        public let restoreSource: Slot?
        public let usesPendingSource: Bool
        public let spaceGroups: [SpaceGroup]
        public let spaceConfigurationDiffers: Bool
        public let untrackedApps: [UntrackedApp]
        public let lastResult: RestoreResult?
    }

    /// 연결된 모든 외장 화면의 섹션 — 식별자 정렬 순서(복원의 화면 순서와 같다).
    /// 연결이 없으면 기억한 화면 하나가 섹션이 된다 (빈 상태에서도 카드는 비지 않는다).
    public var sections: [ScreenSection] {
        if isConnected {
            return externalScreens.map { section(screenID: $0.id, name: $0.name) }
        }
        if case .remembered(let screenID, let name) = screenPresence {
            return [section(screenID: screenID, name: name)]
        }
        return []
    }

    private func section(screenID: String, name: String) -> ScreenSection {
        let source = slots.source(for: screenID)
        let projection = projectionsByScreen[screenID]
        return ScreenSection(screenID: screenID, name: name,
                             profile: source?.profile, restoreSource: source?.slot,
                             usesPendingSource: slots.usesCandidate(for: screenID),
                             spaceGroups: projection?.spaceGroups ?? [],
                             spaceConfigurationDiffers:
                                 projection?.spaceConfigurationDiffers ?? false,
                             untrackedApps: projection?.untrackedApps ?? [],
                             lastResult: resultsByScreen[screenID])
    }

    /// 저장 identity는 opaque name 그대로 두고, 저장된 일반 Space 순서만 표시값으로 붙인다.
    /// live snapshot은 저장 행을 늘리거나 지우지 않고 현재 위치 상태만 붙인다.
    static func spaceGroups(
        in resolved: ResolvedProfile, snapshot: SpaceSnapshot?, targetConnected: Bool = true,
        recoveries: [RestoreSession.Recovery] = [],
        screenNamesByID: [String: String] = [:]
    ) -> [SpaceGroup] {
        guard let overlay = resolved.overlay else { return [] }

        var hintsByName: [String: SpaceHint] = [:]
        for hint in overlay.regularSpaces where hintsByName[hint.opaqueName] == nil {
            hintsByName[hint.opaqueName] = hint
        }
        var appsByName: [String: [TargetApp]] = [:]
        var unresolvedApps: [TargetApp] = []
        for app in resolved.profile.apps where app.isEnabled {
            switch overlay.byBundle[app.bundleID] {
            case .regular(let hint):
                if hintsByName[hint.opaqueName] == nil { hintsByName[hint.opaqueName] = hint }
                appsByName[hint.opaqueName, default: []].append(app)
            case .unresolved, nil:
                unresolvedApps.append(app)
            }
        }

        let recoveriesByID = Dictionary(uniqueKeysWithValues: recoveries.map { ($0.id, $0) })
        let destinationName = screenNamesByID[resolved.profile.screenID]
            ?? resolved.profile.screenName

        var groups = hintsByName.values.sorted {
            ($0.localOrderHint, $0.opaqueName) < ($1.localOrderHint, $1.opaqueName)
        }.enumerated().map { index, hint in
            let state: SpaceGroup.RegularState
            let guide: SpaceGroup.Guide?
            if !targetConnected {
                state = .unknown
                guide = nil
            } else {
                let placement = SpacePlacement.of(
                    hint, on: resolved.profile.screenID, in: snapshot
                )
                let recovery = recoveriesByID[RestoreSession.RecoveryID(
                    targetScreenID: resolved.profile.screenID,
                    opaqueName: hint.opaqueName
                )]
                switch placement {
                case .current:
                    state = .current
                    guide = recovery?.step == .unavailable ? .unavailable : nil
                case .inactive:
                    state = .inactive
                    guide = recovery?.step == .visit
                        ? .visit(screenName: destinationName) : nil
                case .stranded(let found):
                    state = .otherDisplay
                    if recovery == nil {
                        guide = nil
                    } else {
                        guide = .move(
                            sourceScreenName: screenNamesByID[found.screenID] ?? "다른 화면",
                            destinationScreenName: destinationName
                        )
                    }
                case .missing:
                    state = .missing
                    guide = recovery?.step == .unavailable ? .unavailable : nil
                case .fullscreen, .unsupported, .unknown:
                    state = .unknown
                    guide = recovery?.step == .unavailable ? .unavailable : nil
                }
            }
            let apps = appsByName[hint.opaqueName] ?? []
            return SpaceGroup(
                id: "regular:\(hint.opaqueName)",
                kind: .regular(number: index + 1, state: state),
                apps: apps,
                guide: guide
            )
        }
        if !unresolvedApps.isEmpty {
            groups.append(SpaceGroup(
                id: "unresolved", kind: .unresolved, apps: unresolvedApps,
                guide: nil
            ))
        }
        return groups
    }

    /// 저장 계획과 현재 대상 화면의 일반 Space 식별자·순서가 다른지 비교한다.
    /// 연결 해제·snapshot 누락·이름 누락은 차이라고 지어내지 않는다.
    static func spaceConfigurationDiffers(
        in resolved: ResolvedProfile, snapshot: SpaceSnapshot?, targetConnected: Bool
    ) -> Bool {
        guard targetConnected,
              let saved = resolved.overlay?.regularSpaces, !saved.isEmpty,
              let snapshot,
              let display = snapshot.onlyDisplay(resolved.profile.screenID) else { return false }

        let savedNames = saved.sorted {
            ($0.localOrderHint, $0.opaqueName) < ($1.localOrderHint, $1.opaqueName)
        }.map(\.opaqueName)
        let live = display.spaces.filter { $0.kind == .regular }.sorted {
            $0.localOrder < $1.localOrder
        }
        guard live.count == savedNames.count else { return true }
        let liveNames = live.compactMap {
            SpacePlacement.of($0.runtimeID, on: display.screenID, in: snapshot)
                .onTarget?.identity?.opaqueName
        }
        guard liveNames.count == live.count else { return false }
        return liveNames != savedNames
    }

    /// 연결된 화면들의 마지막 복원 결과 — 화면 순서대로. 카드의 결과 스트립이 합산해 그린다.
    /// 지문 불일치로 통째 건너뛴 화면은 뺀다 — 그 사유는 별도 경고 배너의 몫이다.
    public var lastResults: [RestoreResult] {
        externalScreens.compactMap { resultsByScreen[$0.id] }.filter { $0.screenSkipReason == nil }
    }

    /// 프로필 있는 화면이 하나라도 있나 — 복원 버튼 활성 판정. 첫 화면만 보던 판정을 대체한다.
    public var hasRestorableProfile: Bool {
        sections.contains { $0.profile != nil }
    }
    /// 카드가 그리는 실험실 상태 — 전부 슬롯 모듈에서 파생된다.
    public var hasPendingCollect: Bool { slots.hasPendingCollect }
    public var lastCollectedAt: Date? { slots.lastCollectedAt }
    public var spaceConfigurationDiffers: Bool {
        projectionsByScreen.values.contains { $0.spaceConfigurationDiffers }
    }

    private let gateway: WindowGateway
    private let observation: DesktopObservation
    private lazy var restoreSession = RestoreSession(
        observation: observation, gateway: gateway
    )
    private let screenProvider: ScreenProvider
    private let defaults: UserDefaults
    private var externalScreens: [ScreenInfo] = []
    private var screenNamesByID: [String: String] = [:]
    private var watcher: DisplayWatcher?
    /// 수집 신호는 이 모듈 하나로 들어온다 — 신호원들의 차이는 그 뒤에 있다.
    private var collectTrigger: CollectTrigger?
    /// 창 이동 관찰의 어댑터. 게이트웨이와 같은 seam이지만 다른 인터페이스다 (WindowMoveSource).
    private let moveSource: WindowMoveSource?
    /// 안내형 복원과 자동 슬롯이 공유하는 read-only Space adapter.
    private let spaceReader: SpaceReading?
    private let activeSpaceDebounceInterval: TimeInterval
    private var activeSpaceWatcher: ActiveSpaceWatcher?
    private lazy var missionControlWatcher = MissionControlWatcher { [weak self] in
        guard let self else { return }
        Task { await self.missionControlClosed() }
    }
    private var pendingSpaceRefresh = false

    /// 수집 최소 간격 — 실기기 측정 후 조정하는 보정 노브 (테스트는 0을 준다).
    private let collectInterval: TimeInterval
    public init(gateway: WindowGateway, screenProvider: ScreenProvider, store: ProfileStore,
                defaults: UserDefaults = .standard, collectInterval: TimeInterval = 10,
                moveSource: WindowMoveSource? = nil,
                spaceReader: SpaceReading? = nil,
                activeSpaceDebounceInterval: TimeInterval = 1.5) {
        self.gateway = gateway
        observation = DesktopObservation(gateway: gateway, spaceReader: spaceReader)
        self.screenProvider = screenProvider
        self.defaults = defaults
        self.collectInterval = collectInterval
        self.moveSource = moveSource
        self.spaceReader = spaceReader
        self.activeSpaceDebounceInterval = activeSpaceDebounceInterval
        restoreMode = defaults.string(forKey: Keys.restoreMode).flatMap(RestoreMode.init) ?? .automatic
        restoreMinimized = defaults.bool(forKey: Keys.restoreMinimized)
        reopenWindowless = defaults.bool(forKey: Keys.reopenWindowless)
        let lab = defaults.bool(forKey: Keys.labAutoSlot)
        labAutoSlot = lab
        let updateMode = defaults.string(forKey: Keys.autoSlotUpdateMode)
            .flatMap(AutoSlotUpdateMode.init(rawValue:)) ?? .onDisconnect
        autoSlotUpdateMode = updateMode
        slots = ProfileSlots(store: store, isLabEnabled: lab, updateMode: updateMode)
        // 시작 직후의 빈 상태에서도 마지막 화면 이름·프로필 유무를 보여준다 (이름순 첫 프로필).
        if let stored = slots.firstByName {
            screenPresence = .remembered(screenID: stored.screenID, name: stored.screenName)
        }
        // 슬롯 상태가 바뀌면 카드도 다시 그려야 한다 — 바인딩은 컨트롤러 하나만 본다.
        slotChanges = slots.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// 화면 연결 감시 시작 (M4). 새 외장 화면이 나타나면 자동 모드일 때 복원한다 (F-01.1).
    /// 시간 상수는 DisplayWatcher의 것 — 여기서 다시 선언하지 않는다.
    public func startWatching() {
        guard watcher == nil else { return }
        let w = DisplayWatcher(
            provider: screenProvider,
            // 확정은 동기다 — 화면이 빠진 뒤 창을 읽지 않고, 이미 모아둔 후보를 쓸 뿐이다.
            onExternalScreensRemoved: { [weak self] ids in self?.confirmCandidates(for: ids) }
        ) { [weak self] in
            guard let self else { return }
            Task { await self.externalScreensAppeared() }
        }
        w.start()
        watcher = w
        syncSpaceWatcher()
        syncCollectTrigger() // 실행 시점에 실험실이 켜져 있으면 수집도 같이 시작한다
    }

    /// 실험실 상태와 수집 트리거를 맞춘다. 꺼진 기능이 알림을 받고 있으면 "꺼짐"이 아니다.
    /// 신호원들의 차이는 트리거 뒤에 있다 — 여기는 켜고 끄고 대상을 맞출 뿐이다.
    private func syncCollectTrigger() {
        guard labAutoSlot, !isSaveBlocked else {
            let stopping = collectTrigger
            collectTrigger = nil
            Task { await stopping?.stop() }
            return
        }
        if collectTrigger == nil {
            let trigger = CollectTrigger(
                moveSource: moveSource,
                minimumInterval: collectInterval,
                onTerminating: { [weak self] in self?.confirmAllCandidates() }
            ) { [weak self] in
                guard let self else { return }
                Task { await self.collectCandidate() }
            }
            trigger.start()
            collectTrigger = trigger
        }
        // 시작·ON 전환 직후 한 번 읽어 이미 열린 배치를 후보에 담는다.
        Task { await collectCandidate() }
    }

    /// 안내형 복원과 자동 슬롯이 공유하는 read-only Space 관찰 capability.
    private var spaceObservationEnabled: Bool { spaceReader != nil }

    private func resetRestoreSession() {
        restoreSession.cancel()
    }

    /// reader가 없으면 기존 flat 복원만 남고 공개 Space 알림도 구독하지 않는다.
    private func syncSpaceWatcher() {
        guard spaceObservationEnabled else {
            missionControlWatcher.stop()
            activeSpaceWatcher?.stop()
            activeSpaceWatcher = nil
            return
        }
        missionControlWatcher.start()
        guard activeSpaceWatcher == nil else { return }
        let watcher = ActiveSpaceWatcher(
            debounceInterval: activeSpaceDebounceInterval
        ) { [weak self] in
            guard let self else { return }
            Task { await self.activeSpaceChanged() }
        }
        watcher.start()
        activeSpaceWatcher = watcher
    }

    // internal — DisplayWatcher 콜백. 테스트가 직접 호출한다.
    func externalScreensAppeared() async {
        syncScreens()
        await refreshCollectTargets() // 새 화면의 대상 앱까지 이동 관찰에 넣는다
        await refreshProjection()
        guard restoreMode == .automatic else { return } // 수동 모드면 연결돼도 복원하지 않는다 (US-007 AC-4)
        // 권한 게이트는 restoreNow 내부에 있다 — 여기서 중복 검사하지 않는다
        if isRestoring {
            pendingRestore = true // 진행 중 복원이 끝난 직후 1회 재복원 — 새 화면이 조용히 소실되지 않는다
            return
        }
        // 프로필 있는 화면이 하나도 없으면 restoreNow가 자연히 아무것도 하지 않는다 (F-01.1 조건 3).
        // 새 화면에 프로필이 없어도 기존 프로필 화면들은 멱등 복원된다.
        // 이미 제자리인 창은 건너뛰므로 기존 화면까지 포함해 복원해도 창이 흔들리지 않는다 (F-02.2).
        await restoreNow()
    }

    /// 카드가 열리는 순간의 통지 — 화면·실행 상태를 동기화하고,
    /// 일회성 저장 확인 표시를 만료시킨다 (US-002 AC-1: 카드를 다시 열면 사라진다).
    /// async — 실행 상태 갱신이 게이트웨이 왕복이라서다. 메인은 막히지 않는다.
    public func cardOpened() async {
        checkAuthorization()
        syncSpaceWatcher() // 권한을 방금 허용한 첫 실행도 재시작 없이 붙인다
        captureNotice = nil
        syncScreens()
        await refreshProjection()
    }

    /// 화면 상태 동기화. 명령이 스스로 호출한다 — 호출자에게 순서 의식이 없다.
    private func syncScreens() {
        // 식별자 정렬 — 카드와 복원의 중복 제거(F-01.6)가 같은 화면 순서를 쓴다.
        // NSScreen 열거 순서는 불안정하므로 그대로 노출하지 않는다.
        let screens = screenProvider.screens()
        screenNamesByID = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.name) })
        externalScreens = screens.filter { !$0.isBuiltin }.sorted { $0.id < $1.id }
        if let first = externalScreens.first {
            screenPresence = .connected(first, count: externalScreens.count)
        } else if case .connected(let last, _) = screenPresence {
            screenPresence = .remembered(screenID: last.id, name: last.name) // 마지막 화면은 기억으로
        }
    }

    /// [💾 지금 레이아웃 저장] (F-03). 연결된 모든 외장 화면의 프로필을 각각 갱신한다.
    /// async — 창 열거가 이 동작의 본체라서다. 반환값 = 실행/거부 사유 — 확인 표시는 진짜 저장됐을 때만 뜬다.
    @discardableResult
    public func captureNow() async -> CaptureOutcome {
        captureNotice = nil
        guard checkAuthorization() else { return .notAuthorized } // 권한 없이 빈 열거로 저장하지 않는다
        guard !isRestoring else { return .restoringInProgress }   // 반쯤 복원된 배치를 박제하지 않는다
        // 저장이 차단된 실행에서 메모리에만 담는 저장은 재시작에 증발하는 거짓 저장이다 —
        // 확인 표시("저장됨")가 거짓이 되지 않게 아예 거부한다. 이유는 저장소 알림 배너가 설명한다.
        guard !slots.isSaveBlocked else { return .saveBlocked }
        syncScreens()
        guard isConnected else { return .notConnected }
        let sample = await observation.sample(includeSpaces: spaceObservationEnabled)
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
        guard slots.capture(
            windows: sample.windows, on: externalScreens, snapshot: snapshot
        ) else {
            return .saveFailed
        }
        // 사람이 지금 배치를 다시 선언했으므로 이전 복원 세션의 안내는 더 이상 유효하지 않다.
        restoreSession.cancel()
        // 연결된 모든 화면의 합이다 — 저장이 모든 화면에 썼는데 첫 화면만 세면 「저장됨 · n개」가 거짓이다.
        // 체크된 앱만 센다 — 해제한 앱은 저장 대상이 아니므로 세면 역시 거짓이다.
        let count = externalScreens
            .compactMap { slots.source(for: $0.id)?.profile }
            .reduce(0) { $0 + $1.apps.filter(\.isEnabled).count }
        captureNotice = .captured(appCount: count)
        await refreshProjection()
        return .captured(appCount: count)
    }

    // MARK: - 실험실 · 자동 슬롯 (수집 → 확정)

    /// 수집 — 지금 배치를 메모리 후보에 담는다. **파일에는 닿지 않는다.**
    /// internal — 테스트가 알림 없이 직접 호출한다.
    ///
    /// 자동 슬롯이 켜져 있으면 방문한 외장 Space의 새 앱도 candidate에 등록한다.
    /// Space binding도 같은 snapshot에서 끝내도록 전체 표준 창을 한 번 열거한다.
    func collectCandidate() async {
        guard labAutoSlot, !isSaveBlocked, !isRestoring,
              !restoreSession.hasPendingRecovery else { return }
        syncScreens()
        guard isConnected else { return }
        let sample = await observation.sample()
        guard labAutoSlot, !isSaveBlocked, !isRestoring,
              !restoreSession.hasPendingRecovery else { return }
        switch sample.spaceAvailability {
        case nil:
            slots.collect(windows: sample.windows, on: externalScreens)
        case .some(.available(let snapshot)):
            slots.collect(
                windows: sample.windows, on: externalScreens, snapshot: snapshot
            )
        case .some(.unavailable):
            applyProjection(sample)
            return
        }
        await refreshCollectTargets() // 이번에 켜진 앱을 다음 이동부터 따라간다 (등록은 멱등)
    }

    /// 창 이동 observer가 따라갈 기존 대상 앱을 지금 상태에 맞춘다.
    /// 처음 본 앱은 전체 창 수집으로 등록된 다음 이 명부에 들어온다.
    private func refreshCollectTargets() async {
        syncScreens() // 명령은 화면 상태를 스스로 동기화한다 — 호출자에게 순서 의식이 없다.
        // 이게 없으면 앱을 켤 때 화면이 이미 꽂혀 있는 경우 등록이 통째로 빠진다:
        // 시작 직후 화면 상태는 '기억만'이고, 연결 이벤트는 이미 지나갔기 때문이다.
        guard labAutoSlot, !isSaveBlocked, isConnected else {
            await collectTrigger?.retarget([])
            return
        }
        await collectTrigger?.retarget(slots.targets(for: externalScreens))
    }

    /// 확정 — 사라진 화면의 후보를 자동 슬롯에 쓴다. internal — 테스트가 직접 호출한다.
    /// 이 시점에 창을 읽지 않는다는 것이 이 경로의 핵심이며, 그 이유는 슬롯 모듈에 적혀 있다.
    func confirmCandidates(for screenIDs: Set<String>) {
        restoreSession.cancel()
        if slots.confirm(screenIDs) {
            Task { await refreshProjection() }
        }
    }

    /// 종료 직전 — 남은 후보를 전부 확정한다. 화면을 뽑기 전에 앱을 끄면 여기가 마지막 기회다.
    public func confirmAllCandidates() { slots.confirmAll() }

    /// 복원 중 새 화면이 연결됐다 — 지금 복원이 끝난 직후 1회 재복원한다 (조용한 소실 방지).
    private var pendingRestore = false

    /// [⚡ 지금 레이아웃 복원] (F-02). 연결된 모든 외장 화면에 각 프로필을 적용한다.
    /// 반환 시점 = 완료 시점, 반환값 = 결과 — 복원 순서는 RestoreSession 안에서 끝난다.
    @discardableResult
    public func restoreNow() async -> RestoreOutcome {
        guard checkAuthorization() else { return .notAuthorized } // 수동 복원도 게이트를 지난다 (US-010 AC-2)
        syncScreens()
        guard isConnected else { return .notConnected }
        guard !isRestoring else { return .alreadyRestoring }
        let results = await performRestore(startingWithAll: true)
        return .restored(results)
    }

    /// ActiveSpaceWatcher의 무페이로드 이벤트가 들어오는 단일 지점. 복원 중이면 새 열거를
    /// 시작하지 않고, 현재 pass가 끝난 뒤 최신 Space를 한 번만 다시 읽는다.
    func activeSpaceChanged() async {
        await desktopStateChanged()
    }

    /// 비활성 Space의 화면 간 이동은 activeSpace 알림을 내지 않는다. Mission Control이
    /// 닫힌 뒤 같은 재평가 경로를 타고, 복원이 끝난 다음에만 자동 슬롯을 수집한다.
    func missionControlClosed() async {
        await desktopStateChanged()
    }

    private func desktopStateChanged() async {
        guard spaceObservationEnabled else { return }
        if isRestoring {
            pendingSpaceRefresh = true
            return
        }
        syncScreens()
        guard isConnected, checkAuthorization() else { return }
        if restoreSession.hasPendingRecovery {
            for attempt in 0..<2 {
                if attempt == 1 {
                    // Space 알림 뒤 첫 snapshot이 직전 Space로 안정돼 보일 수 있다.
                    // 같은 정착 간격 뒤 딱 한 번만 다시 읽고, 주기 폴링은 만들지 않는다.
                    try? await Task.sleep(
                        nanoseconds: UInt64(activeSpaceDebounceInterval * 1_000_000_000)
                    )
                    if isRestoring {
                        pendingSpaceRefresh = true
                        return
                    }
                    syncScreens()
                    guard isConnected, checkAuthorization() else { return }
                }
                guard restoreSession.hasPendingRecovery else { return }
                _ = await performRestore(startingWithAll: false)
            }
        } else {
            await collectCandidate()
            await refreshProjection()
        }
    }

    private func performRestore(startingWithAll: Bool) async -> [RestoreResult] {
        isRestoring = true

        // 설정 변경은 안내를 취소하고, 이미 시작한 회차는 이 인스턴스로 끝낸다.
        let session = restoreSession
        var runAll = startingWithAll
        var latest: [RestoreResult] = []
        repeat {
            pendingRestore = false
            pendingSpaceRefresh = false
            let screens = externalScreens
            let resolved = slots.resolvedWithSpaces(for: screens)
            let options = RestoreOptions(
                restoreMinimized: restoreMinimized,
                reopenWindowless: reopenWindowless
            )
            if runAll {
                latest = await session.restore(
                    resolved: resolved, screens: screens, options: options
                )
            } else {
                latest = await session.recheck(
                    resolved: resolved, screens: screens, options: options
                ) ?? []
            }
            record(latest)
            if pendingRestore {
                syncScreens()
                runAll = true
            } else {
                runAll = false
            }
        } while isConnected && (
            pendingRestore || (session.hasPendingRecovery && pendingSpaceRefresh)
        )

        isRestoring = false // 수집·카드 갱신 전에 해제 — 둘 다 복원 중엔 양보한다
        await collectCandidate() // 안내가 남아 있으면 collectCandidate 자체가 저장값 보호를 위해 양보한다
        await refreshProjection()
        return latest
    }

    private func record(_ results: [RestoreResult]) {
        // 결과 수명 = 프로필 수명 — 복원 중 삭제된 프로필의 결과를 부활시키지 않는다.
        for result in results where slots.source(for: result.screenID) != nil {
            resultsByScreen[result.screenID] = result
        }
        if !results.isEmpty { lastRestoredAt = Date() }
    }

    /// 저장된 모든 프로필 — 연결되지 않은 화면 포함 (F-05.6, US-012 AC-1).
    public var allProfiles: [Profile] { slots.all }

    /// 프로필 통째 삭제 (F-05.6). 그 화면을 다시 연결하면 프로필 없는 화면이다 (US-012 AC-3).
    public func removeProfile(_ screenID: String) {
        guard slots.remove(screenID: screenID) else { return }
        restoreSession.cancel()
        resultsByScreen.removeValue(forKey: screenID) // 결과 수명 = 프로필 수명 — 전생의 결과를 남기지 않는다
        projectionsByScreen.removeValue(forKey: screenID)
    }

    private func refreshProjection() async {
        // 복원 진행 중엔 양보한다 — 여기의 재열거가 진행 중 복원이 든 창 ID를 무효화한다
        // (ID 수명 계약: 마지막 열거만 유효). 복원이 끝나면 스스로 갱신하므로 잃는 것이 없다.
        guard !isRestoring else { return }
        // 화면별로 계산하되 열거는 한 번이다 — 카드가 「그 화면에 뭐가 있나」도 답하기 때문이다(대상 아님 행).
        // 게이트웨이가 actor라 메인은 막히지 않고, 카드 값은 비동기로 채워진다.
        let sample = await observation.sample(includeSpaces: spaceObservationEnabled)
        applyProjection(sample)
    }

    /// 이미 얻은 관찰을 카드 값으로 투영한다. 실패한 변경이 같은 관찰을 재사용해
    /// 즉시 재시도하지 않고도 저장 Space의 현재 상태를 unknown으로 보여준다.
    private func applyProjection(
        _ sample: DesktopObservation.Sample,
        preservingUntrackedApps: Bool = false
    ) {
        guard sample.sequence > latestProjectionSequence else { return }
        latestProjectionSequence = sample.sequence
        let snapshot: SpaceSnapshot?
        switch sample.spaceAvailability {
        case nil, .some(.unavailable):
            snapshot = nil
        case .some(.available(let available)):
            snapshot = available
        }
        // (화면, 실제 ScreenInfo?) 쌍 — 기억만 상태에서는 화면이 없어 제자리 판정이 생략된다.
        let targets: [(screenID: String, screen: ScreenInfo?)] = if isConnected {
            externalScreens.map { ($0.id, $0) }
        } else if case .remembered(let screenID, _) = screenPresence {
            [(screenID, nil)]
        } else {
            []
        }

        var next: [String: ScreenProjection] = [:]
        for (screenID, screen) in targets {
            let resolved = slots.resolvedWithSpaces(for: screenID)
            let profile = resolved?.profile
            let bundleIDs = profile?.apps.map(\.bundleID) ?? []
            var spaceGroups: [SpaceGroup] = []
            var spaceConfigurationDiffers = false
            if spaceObservationEnabled, let resolved {
                spaceGroups = Self.spaceGroups(
                    in: resolved,
                    snapshot: snapshot,
                    targetConnected: screen != nil,
                    recoveries: restoreSession.recoveries,
                    screenNamesByID: screenNamesByID
                )
                spaceConfigurationDiffers = Self.spaceConfigurationDiffers(
                    in: resolved, snapshot: snapshot,
                    targetConnected: screen != nil
                )
            }
            // 껐던 대상 앱이 먼저다 — 좌표가 남아 있어 되돌리기 쉬운 쪽을 위에 둔다.
            let disabled = (profile?.apps.filter { !$0.isEnabled } ?? [])
                .map { UntrackedApp(bundleID: $0.bundleID, displayName: $0.displayName) }
            let untrackedApps = if preservingUntrackedApps,
                                   let existing = projectionsByScreen[screenID] {
                existing.untrackedApps
            } else {
                disabled + Self.untracked(
                    in: sample.windows, on: screen, excluding: Set(bundleIDs)
                )
            }
            next[screenID] = ScreenProjection(
                spaceGroups: spaceGroups,
                spaceConfigurationDiffers: spaceConfigurationDiffers,
                untrackedApps: untrackedApps
            )
        }
        projectionsByScreen = next
    }

    /// 저장이 잡아갈 창과 같은 규칙 — 중심점이 이 화면이고, 최소화·전체화면이 아닌 표준 창.
    /// 순수 함수라 규칙이 저장과 어긋나면 테스트가 잡는다.
    static func untracked(in windows: [WindowInfo], on screen: ScreenInfo?,
                          excluding targets: Set<String>) -> [UntrackedApp] {
        guard let screen, !screen.isBuiltin else { return [] }
        var seen = targets
        var out: [UntrackedApp] = []
        for window in windows
        where !window.isMinimized && !window.isFullscreen && screen.contains(window) {
            if seen.insert(window.appBundleID).inserted {
                out.append(UntrackedApp(bundleID: window.appBundleID, displayName: window.appName))
            }
        }
        return out
    }

    /// 카드 체크박스의 유일한 동작 — 「이 앱을 다루나」.
    /// 켜면: 그 화면 프로필에 있으면 다시 복원 대상으로(저장된 좌표 그대로), 없으면 지금 자리로 등록한다.
    /// 끄면: 복원에서 빼되 **프로필에서 지우지 않는다** (US-006 AC-2 — 좌표는 남는다).
    /// 화면에서는 이 셋이 한 질문의 답이라 체크박스 하나로 족하다.
    public func setTracked(_ bundleID: String, _ tracked: Bool, on screenID: String) async {
        switch slots.setTargetEnabled(bundleID, tracked, on: screenID) {
        case .applied:
            captureNotice = nil
            restoreSession.cancel()
            await refreshCollectTargets()
            await refreshProjection() // 켜고 끈 행이 곧바로 제 묶음으로 간다
        case .missing:
            if tracked { await addTargetApp(bundleID, on: screenID) }
        case .failed:
            return
        }
    }

    /// 프로필에서 완전히 제거한다. 창이 해당 외장 화면에 남아 있으면 프로필 밖 앱으로
    /// 즉시 다시 보이고, 화면에도 없으면 행이 사라진다.
    public func remove(_ bundleID: String, on screenID: String) async {
        guard slots.removeTarget(bundleID, on: screenID) else { return }
        restoreSession.cancel()
        await refreshCollectTargets()
        await refreshProjection()
    }

    /// 프로필에 없던 앱을 대상 앱 명부에 올린다. **저장이 아니다**:
    /// 다른 앱의 좌표를 덮지 않고, 복원 소스를 뒤집지 않으며, 모으던 후보도 안 버린다.
    @discardableResult
    private func addTargetApp(_ bundleID: String, on screenID: String) async -> CaptureOutcome {
        captureNotice = nil
        guard checkAuthorization() else { return .notAuthorized }
        guard !isRestoring else { return .restoringInProgress }
        guard !slots.isSaveBlocked else { return .saveBlocked }
        syncScreens()
        guard let screen = externalScreens.first(where: { $0.id == screenID })
        else { return .notConnected }
        let sample = await observation.sample(
            of: [bundleID], includeSpaces: spaceObservationEnabled
        )
        let snapshot: SpaceSnapshot?
        switch sample.spaceAvailability {
        case nil:
            snapshot = nil
        case .some(.available(let available)):
            snapshot = available
        case .some(.unavailable):
            captureNotice = .spaceObservationUnavailable
            // 앱 하나만 열거한 sample이므로 다른 비대상 앱 목록은 기존 projection을 보존한다.
            applyProjection(sample, preservingUntrackedApps: true)
            return .spaceObservationUnavailable
        }
        guard slots.addTarget(
            windows: sample.windows, on: [screen], snapshot: snapshot
        ) else {
            return .saveFailed
        }
        restoreSession.cancel()
        await refreshCollectTargets() // 새 대상 앱을 이동 관찰에도 넣는다
        await refreshProjection()
        let count = slots.source(for: screenID)?.profile.apps.filter(\.isEnabled).count ?? 0
        return .captured(appCount: count)
    }

    /// 저장소 알림 확인 — 배너만 사라진다. unreadable의 쓰기 금지는 남고,
    /// writeFailed는 다음 저장 동작에서 다시 시도한다.
    public func dismissStoreNotice() { slots.dismissTrouble() }

    /// UserDefaults 키 — 읽기·쓰기가 같은 이름을 쓰도록 한곳에 (오타는 조용한 버그다).
    private enum Keys {
        static let restoreMode = "restoreMode"
        static let restoreMinimized = "restoreMinimized"
        static let reopenWindowless = "reopenWindowless"
        static let labAutoSlot = "labAutoSlot"
        static let autoSlotUpdateMode = "autoSlotUpdateMode"
    }

}
