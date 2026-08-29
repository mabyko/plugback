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

    /// 첫 화면 편의용 식별자 — 연결 시 식별자 정렬상 첫 화면, 아니면 기억한 화면.
    /// **카드는 이것에 의존하지 않는다** — 카드는 sections로 모든 화면을 그린다.
    /// 화면 식별자를 받지 않은 호출(테스트·기존 API)의 기본값으로만 쓴다.
    private var currentScreenID: String? {
        switch screenPresence {
        case .connected(let screen, _): return screen.id
        case .remembered(let screenID, _): return screenID
        case .none: return nil
        }
    }
    /// 복원 진행 중 — 재진입 가드이자 버튼 비활성용 UI 상태.
    @Published public private(set) var isRestoring = false
    /// 화면별 · 대상 앱별 복원 예측 — "복원하면 이 앱이 어떻게 될까"의 답 (US-006 AC-1의 점이 이것을 그린다).
    /// 바깥 키는 화면 식별자, 안쪽 키는 번들 ID. 엔진의 창 선택 규칙 그대로 계산된다.
    /// 실행 시점 사건(이동 실패·새 창 미등장·지문 불일치·체크 해제)은 예측 범위 밖 —
    /// 결과 스트립과 알림이 사후에 답한다. 뒷 화면의 예측은 다중 화면 중복 제거(F-01.6)를 모른다.
    @Published public private(set) var predictionsByScreen: [String: [String: RestorePrediction]] = [:]
    /// 카드 표시용 Space 그룹. 번호는 이 외장 화면에 저장된 일반 Space의 로컬 순서다.
    @Published private var spaceGroupsByScreen: [String: [SpaceGroup]] = [:]
    /// 저장된 일반 Space 구성과 지금 대상 화면의 구성이 다른가. 연결 중·안정 snapshot에서만 판단한다.
    @Published private var spaceConfigurationDiffersByScreen: [String: Bool] = [:]
    /// 화면별 · 저장하지 않는 앱 — 체크를 껐던 대상 앱과, 그 화면에 있지만 프로필에 없는 앱.
    /// **화면에서는 같은 칸이다**: 체크 해제는 「아무것도 안 한다」 하나의 뜻이고,
    /// 프로필 소속 여부는 내부 사정이다. 껐던 앱은 좌표가 남아 있어 다시 켜면 그 자리로 돌아온다.
    /// 프로필에 없는 앱은 저장이 잡아갈 창과 같은 규칙으로 고른다 — 체크했는데 아무 일도
    /// 안 일어나는 행을 만들지 않기 위해서다.
    @Published public private(set) var untrackedAppsByScreen: [String: [UntrackedApp]] = [:]

    /// 첫 화면 파생 편의 — 테스트·기존 호출용. 카드는 sections를 쓴다.
    public var predictions: [String: RestorePrediction] {
        currentScreenID.flatMap { predictionsByScreen[$0] } ?? [:]
    }
    public var untrackedApps: [UntrackedApp] {
        currentScreenID.flatMap { untrackedAppsByScreen[$0] } ?? []
    }
    /// 방금 저장의 확인 표시용 대상 앱 수 (US-002 AC-1). 카드를 다시 열면 사라진다.
    @Published public private(set) var lastCaptureCount: Int?
    /// 저장소 문제 알림 (F-04.2). 사용자가 확인하면 사라진다 — 영구 배너가 아니다.
    /// **파생이다** — 슬롯 모듈이 유일한 출처다. 사본을 들면 손으로 맞춰야 하고, 그러면 어긋난다.
    public var storeNotice: ProfileStore.LoadOutcome.Trouble? { slots.trouble }
    /// 복원 모드 (F-05.4). 기본값 자동, 변경은 보존된다.
    @Published public var restoreMode: RestoreMode {
        didSet { defaults.set(restoreMode.rawValue, forKey: Keys.restoreMode) }
    }

    /// 최소화된 창도 Dock에서 꺼내 복원할지 (F-02.2 예외 설정). 기본 꺼짐 — 최소화는 사용자의 의도다.
    @Published public var restoreMinimized: Bool {
        didSet {
            defaults.set(restoreMinimized, forKey: Keys.restoreMinimized)
            refreshPredictionsAfterOptionChange() // 옵션은 예측을 바꾼다 — 갱신 의무를 변이 지점에
        }
    }

    /// 실행 중인데 창이 없는 앱에 새 창을 열게 해 복원할지 (F-02.2 예외 설정). 기본 꺼짐.
    /// 꺼진 앱을 실행하지는 않는다 — F-02.1은 그대로다.
    @Published public var reopenWindowless: Bool {
        didSet {
            defaults.set(reopenWindowless, forKey: Keys.reopenWindowless)
            refreshPredictionsAfterOptionChange()
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
            pendingSpaceBundles.removeAll() // 복원 소스가 manual ↔ auto로 바뀌었으므로 낡은 pending 폐기
            pendingSpaceRefresh = false
            syncCollectTrigger()
            syncSpaceWatcher()
            refreshPredictionsAfterOptionChange() // 복원 소스가 바뀌면 점도 바뀐다
        }
    }

    /// 실험실 · 자동 슬롯의 반영 방식. 기존 사용자는 분리/종료 확정을 그대로 쓴다.
    @Published public var autoSlotUpdateMode: AutoSlotUpdateMode {
        didSet {
            guard autoSlotUpdateMode != oldValue else { return }
            defaults.set(autoSlotUpdateMode.rawValue, forKey: Keys.autoSlotUpdateMode)
            slots.updateMode = autoSlotUpdateMode
            pendingSpaceBundles.removeAll()
            pendingSpaceRefresh = false
            refreshPredictionsAfterOptionChange()
        }
    }

    /// 실험실 · 일반 Space 복원. Space 자체의 화면 소속과 Space별 창 위치를 함께 복원한다.
    /// 자동 슬롯과 독립이므로 수동 슬롯만으로도 동작한다.
    @Published public var labRegularSpaceRestore: Bool {
        didSet {
            guard labRegularSpaceRestore != oldValue else { return }
            defaults.set(labRegularSpaceRestore, forKey: Keys.labRegularSpaceRestore)
            pendingSpaceBundles.removeAll()
            pendingSpaceRefresh = false
            syncSpaceWatcher()
            refreshPredictionsAfterOptionChange()
        }
    }

    /// 실험실 · 확인된 single native fullscreen 복원. 일반 Space 복원과 독립이다.
    @Published public var labFullscreenRestore: Bool {
        didSet {
            guard labFullscreenRestore != oldValue else { return }
            defaults.set(labFullscreenRestore, forKey: Keys.labFullscreenRestore)
            pendingSpaceBundles.removeAll()
            pendingSpaceRefresh = false
            syncSpaceWatcher()
            refreshPredictionsAfterOptionChange()
        }
    }

    /// 설정 창과 카드가 나란히 열려 있어도 점이 스테일하지 않게 — didSet에서 비동기로 쏜다.
    private func refreshPredictionsAfterOptionChange() {
        Task { await updatePredictions() }
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

    /// 파생 상태 — 수동 동기화 지점을 두지 않는다. 첫 화면 편의 — 카드는 sections를 쓴다.
    public var profile: Profile? { currentScreenID.flatMap { slots.source(for: $0)?.profile } }
    /// 지금 복원에 쓰일 슬롯 — 첫 화면 편의. 파생이므로 표시와 동작이 어긋날 수 없다.
    public var restoreSource: Slot? { currentScreenID.flatMap { slots.source(for: $0)?.slot } }
    /// 첫 화면의 마지막 복원 결과 — 편의. 카드는 lastResults로 모든 화면을 본다.
    public var lastResult: RestoreResult? { currentScreenID.flatMap { resultsByScreen[$0] } }

    /// 카드가 화면 하나를 그리는 단위 — 프로필·복원 소스·예측·저장하지 않는 앱·마지막 결과가
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
            case fullscreen
            case unresolved
        }

        public let id: String
        public let kind: Kind
        public let apps: [TargetApp]
    }

    public struct ScreenSection: Identifiable, Equatable, Sendable {
        public var id: String { screenID }
        public let screenID: String
        public let name: String
        public let profile: Profile?
        public let restoreSource: Slot?
        public let usesPendingSource: Bool
        public let predictions: [String: RestorePrediction]
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
        return ScreenSection(screenID: screenID, name: name,
                             profile: source?.profile, restoreSource: source?.slot,
                             usesPendingSource: slots.usesCandidate(for: screenID),
                             predictions: predictionsByScreen[screenID] ?? [:],
                             spaceGroups: spaceGroupsByScreen[screenID] ?? [],
                             spaceConfigurationDiffers: spaceConfigurationDiffersByScreen[screenID] ?? false,
                             untrackedApps: untrackedAppsByScreen[screenID] ?? [],
                             lastResult: resultsByScreen[screenID])
    }

    /// 저장 identity는 opaque name 그대로 두고, 저장된 일반 Space 순서만 표시값으로 붙인다.
    /// live snapshot은 저장 행을 늘리거나 지우지 않고 현재 위치 상태만 붙인다.
    static func spaceGroups(
        in resolved: ResolvedProfile, snapshot: SpaceSnapshot?, targetConnected: Bool = true
    ) -> [SpaceGroup] {
        guard let overlay = resolved.overlay else { return [] }

        var liveByName: [String: [(screenID: String, isCurrent: Bool)]] = [:]
        for display in snapshot?.displays ?? [] {
            for space in display.spaces {
                guard space.kind == .regular, let name = space.opaqueName else { continue }
                liveByName[name, default: []].append((display.screenID, space.isCurrent))
            }
        }

        var hintsByName: [String: SpaceHint] = [:]
        for hint in overlay.regularSpaces where hintsByName[hint.opaqueName] == nil {
            hintsByName[hint.opaqueName] = hint
        }
        var appsByName: [String: [TargetApp]] = [:]
        var fullscreenApps: [TargetApp] = []
        var unresolvedApps: [TargetApp] = []
        for app in resolved.profile.apps where app.isEnabled {
            switch overlay.byBundle[app.bundleID] {
            case .regular(let hint):
                if hintsByName[hint.opaqueName] == nil { hintsByName[hint.opaqueName] = hint }
                appsByName[hint.opaqueName, default: []].append(app)
            case .fullscreen:
                fullscreenApps.append(app)
            case .unresolved, nil:
                unresolvedApps.append(app)
            }
        }

        var groups = hintsByName.values.sorted {
            ($0.localOrderHint, $0.opaqueName) < ($1.localOrderHint, $1.opaqueName)
        }.enumerated().map { index, hint in
            let matches = liveByName[hint.opaqueName] ?? []
            let state: SpaceGroup.RegularState
            if !targetConnected || snapshot == nil || matches.count > 1 {
                state = .unknown
            } else if let match = matches.first {
                if match.screenID != resolved.profile.screenID {
                    state = .otherDisplay
                } else {
                    state = match.isCurrent ? .current : .inactive
                }
            } else {
                state = .missing
            }
            return SpaceGroup(
                id: "regular:\(hint.opaqueName)",
                kind: .regular(number: index + 1, state: state),
                apps: appsByName[hint.opaqueName] ?? []
            )
        }
        if !fullscreenApps.isEmpty {
            groups.append(SpaceGroup(id: "fullscreen", kind: .fullscreen, apps: fullscreenApps))
        }
        if !unresolvedApps.isEmpty {
            groups.append(SpaceGroup(id: "unresolved", kind: .unresolved, apps: unresolvedApps))
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
              let display = snapshot?.displays.first(where: {
                  $0.screenID == resolved.profile.screenID
              }) else { return false }

        let savedNames = saved.sorted {
            ($0.localOrderHint, $0.opaqueName) < ($1.localOrderHint, $1.opaqueName)
        }.map(\.opaqueName)
        let live = display.spaces.filter { $0.kind == .regular }.sorted {
            $0.localOrder < $1.localOrder
        }
        guard live.count == savedNames.count else { return true }
        let liveNames = live.compactMap(\.opaqueName)
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
        if isConnected { return externalScreens.contains { slots.source(for: $0.id) != nil } }
        return profile != nil
    }
    /// 카드가 그리는 실험실 상태 — 전부 슬롯 모듈에서 파생된다.
    public var hasPendingCollect: Bool { slots.hasPendingCollect }
    public var lastCollectedAt: Date? { slots.lastCollectedAt }
    public var spaceConfigurationDiffers: Bool {
        spaceConfigurationDiffersByScreen.values.contains(true)
    }

    private let gateway: WindowGateway
    private let screenProvider: ScreenProvider
    private let defaults: UserDefaults
    private var externalScreens: [ScreenInfo] = []
    private var watcher: DisplayWatcher?
    /// 수집 신호는 이 모듈 하나로 들어온다 — 신호원들의 차이는 그 뒤에 있다.
    private var collectTrigger: CollectTrigger?
    /// 창 이동 관찰의 어댑터. 게이트웨이와 같은 seam이지만 다른 인터페이스다 (WindowMoveSource).
    private let moveSource: WindowMoveSource?
    /// 실험실용 read-only Space adapter. nil이거나 관련 토글이 모두 OFF면 기존 제품 경로 그대로다.
    private let spaceReader: SpaceReading?
    /// 실험실용 visible Mission Control adapter. 「일반 Space 복원」이 ON일 때만 쓴다.
    private let spaceRelocator: SpaceRelocating?
    private let activeSpaceDebounceInterval: TimeInterval
    private var activeSpaceWatcher: ActiveSpaceWatcher?
    /// 연결 직후 아직 방문하지 않은 Space binding. 일반 창 완료·제자리와
    /// 목표 화면에서 확인된 fullscreen만 여기서 빠진다.
    private var pendingSpaceBundles: [String: Set<String>] = [:]
    private var pendingSpaceRefresh = false

    /// AX window ID는 마지막 열거에만 유효하다. 복원 전에는 먼저 시작한 read가 모두 끝나길 기다린다.
    private var windowReadsInFlight = 0
    private var windowReadWaiters: [CheckedContinuation<Void, Never>] = []

    /// 수집 최소 간격 — 실기기 측정 후 조정하는 보정 노브 (테스트는 0을 준다).
    private let collectInterval: TimeInterval
    public init(gateway: WindowGateway, screenProvider: ScreenProvider, store: ProfileStore,
                defaults: UserDefaults = .standard, collectInterval: TimeInterval = 10,
                moveSource: WindowMoveSource? = nil,
                spaceReader: SpaceReading? = nil,
                spaceRelocator: SpaceRelocating? = nil,
                activeSpaceDebounceInterval: TimeInterval = 1.5) {
        self.gateway = gateway
        self.screenProvider = screenProvider
        self.defaults = defaults
        self.collectInterval = collectInterval
        self.moveSource = moveSource
        self.spaceReader = spaceReader
        self.spaceRelocator = spaceRelocator
        self.activeSpaceDebounceInterval = activeSpaceDebounceInterval
        restoreMode = defaults.string(forKey: Keys.restoreMode).flatMap(RestoreMode.init) ?? .automatic
        restoreMinimized = defaults.bool(forKey: Keys.restoreMinimized)
        reopenWindowless = defaults.bool(forKey: Keys.reopenWindowless)
        let lab = defaults.bool(forKey: Keys.labAutoSlot)
        labAutoSlot = lab
        let updateMode = defaults.string(forKey: Keys.autoSlotUpdateMode)
            .flatMap(AutoSlotUpdateMode.init(rawValue:)) ?? .onDisconnect
        autoSlotUpdateMode = updateMode
        // 기존 실험실 사용자는 업그레이드 뒤 동작이 갑자기 꺼지지 않게 한 번 이어받는다.
        let savedRegularRestore = defaults.object(forKey: Keys.labRegularSpaceRestore) as? Bool
        labRegularSpaceRestore = savedRegularRestore ?? lab
        if savedRegularRestore == nil { defaults.set(lab, forKey: Keys.labRegularSpaceRestore) }
        let savedFullscreenRestore = defaults.object(forKey: Keys.labFullscreenRestore) as? Bool
        labFullscreenRestore = savedFullscreenRestore ?? lab
        if savedFullscreenRestore == nil { defaults.set(lab, forKey: Keys.labFullscreenRestore) }
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
        guard labAutoSlot else {
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
        // 시작·ON 전환 직후 한 번 읽어야, 이미 비활성인 fullscreen도 방문 없이 후보가 된다.
        Task { await collectCandidate() }
    }

    /// 공개 Space 알림이 필요한 경우. 자동 슬롯은 수집에, 두 복원 토글은 방문 복원에 쓴다.
    private var spaceObservationEnabled: Bool {
        spaceReader != nil && (labAutoSlot || labRegularSpaceRestore || labFullscreenRestore)
    }

    /// Space-aware 복원 범위가 하나라도 켜졌는가. 자동 슬롯은 복원 기능이 아니다.
    private var spaceRestoreEnabled: Bool {
        spaceReader != nil && (labRegularSpaceRestore || labFullscreenRestore)
    }

    /// Space 관찰 기능이 모두 꺼져 있으면 private read뿐 아니라 공개 Space 알림 구독도 존재하지 않는다.
    private func syncSpaceWatcher() {
        guard spaceObservationEnabled else {
            activeSpaceWatcher?.stop()
            activeSpaceWatcher = nil
            pendingSpaceBundles.removeAll()
            pendingSpaceRefresh = false
            return
        }
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
        await updatePredictions() // 카드가 열려 있는 채로 연결돼도 점이 맞게 (예측 갱신)
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
        lastCaptureCount = nil
        syncScreens()
        await updatePredictions()
    }

    /// 화면 상태 동기화. 명령이 스스로 호출한다 — 호출자에게 순서 의식이 없다.
    private func syncScreens() {
        // 식별자 정렬 — "첫 화면"의 정의를 복원의 중복 제거(F-01.6)와 공유한다.
        // NSScreen 열거 순서는 불안정하고, 다르게 고르면 카드의 예측이 진실과 어긋난다.
        externalScreens = screenProvider.screens().filter { !$0.isBuiltin }.sorted { $0.id < $1.id }
        if let first = externalScreens.first {
            screenPresence = .connected(first, count: externalScreens.count)
        } else if case .connected(let last, _) = screenPresence {
            screenPresence = .remembered(screenID: last.id, name: last.name) // 마지막 화면은 기억으로
        }
    }

    /// 컨트롤러에서 시작하는 모든 AX 창 열거의 단일 입구. 복원은 이 카운터를 drain한 뒤
    /// authoritative 열거를 시작하므로, 더 오래된 열거가 그 ID를 뒤늦게 무효화하지 못한다.
    private func readWindows(of bundleIDs: [String]?) async -> [WindowInfo] {
        windowReadsInFlight += 1
        defer {
            windowReadsInFlight -= 1
            if windowReadsInFlight == 0 {
                let waiters = windowReadWaiters
                windowReadWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return await gateway.standardWindows(of: bundleIDs)
    }

    private func drainWindowReads() async {
        guard windowReadsInFlight > 0 else { return }
        await withCheckedContinuation { windowReadWaiters.append($0) }
    }

    private func stableSpaceSnapshot(for windows: [WindowInfo]) async -> SpaceSnapshot? {
        guard let spaceReader else { return nil }
        let ids = Array(Set(windows.compactMap(\.windowServerID))).sorted()
        let availability = await spaceReader.stableSnapshot(windowServerIDs: ids)
        guard case .available(let snapshot) = availability else { return nil }
        return snapshot
    }

    /// [💾 지금 레이아웃 저장] (F-03). 연결된 모든 외장 화면의 프로필을 각각 갱신한다.
    /// async — 창 열거가 이 동작의 본체라서다. 반환값 = 실행/거부 사유 — 확인 표시는 진짜 저장됐을 때만 뜬다.
    @discardableResult
    public func captureNow() async -> CaptureOutcome {
        guard checkAuthorization() else { return .notAuthorized } // 권한 없이 빈 열거로 저장하지 않는다
        guard !isRestoring else { return .restoringInProgress }   // 반쯤 복원된 배치를 박제하지 않는다
        // 저장이 차단된 실행에서 메모리에만 담는 저장은 재시작에 증발하는 거짓 저장이다 —
        // 확인 표시("저장됨")가 거짓이 되지 않게 아예 거부한다. 이유는 저장소 알림 배너가 설명한다.
        guard !slots.isSaveBlocked else { return .saveBlocked }
        syncScreens()
        guard isConnected else { return .notConnected }
        let windows = await readWindows(of: nil)
        let snapshot = spaceObservationEnabled
            ? await stableSpaceSnapshot(for: windows)
            : nil
        slots.capture(windows: windows, on: externalScreens, snapshot: snapshot)
        // 사람이 지금 배치를 다시 선언했으므로 이전 재연결 회차의 pending은 더 이상 유효하지 않다.
        for screen in externalScreens { pendingSpaceBundles.removeValue(forKey: screen.id) }
        // 연결된 모든 화면의 합이다 — 저장이 모든 화면에 썼는데 첫 화면만 세면 「저장됨 · n개」가 거짓이다.
        // 체크된 앱만 센다 — 해제한 앱은 저장 대상이 아니므로 세면 역시 거짓이다.
        let count = externalScreens
            .compactMap { slots.source(for: $0.id)?.profile }
            .reduce(0) { $0 + $1.apps.filter(\.isEnabled).count }
        lastCaptureCount = count
        await updatePredictions()
        return .captured(appCount: count)
    }

    // MARK: - 실험실 · 자동 슬롯 (수집 → 확정)

    /// 수집 — 지금 배치를 메모리 후보에 담는다. **파일에는 닿지 않는다.**
    /// internal — 테스트가 알림 없이 직접 호출한다.
    ///
    /// 자동 슬롯이 켜져 있으면 방문한 외장 Space의 새 앱도 candidate에 등록한다.
    /// Space 경로는 Split View 판별까지 같은 snapshot에서 끝내도록 전체 표준 창을 한 번 열거한다.
    func collectCandidate() async {
        guard labAutoSlot, !isRestoring else { return }
        syncScreens()
        guard isConnected else { return }
        let windows = await readWindows(of: nil)
        guard labAutoSlot, !isRestoring else { return }
        if spaceReader != nil {
            guard let snapshot = await stableSpaceSnapshot(for: windows) else { return }
            guard labAutoSlot, !isRestoring else { return }
            let pending = Set(pendingSpaceBundles.values.flatMap { $0 })
            slots.collect(
                windows: windows, on: externalScreens, snapshot: snapshot,
                excluding: pending
            )
        } else {
            slots.collect(windows: windows, on: externalScreens)
        }
        await refreshCollectTargets() // 이번에 켜진 앱을 다음 이동부터 따라간다 (등록은 멱등)
    }

    /// 창 이동 observer가 따라갈 기존 대상 앱을 지금 상태에 맞춘다.
    /// 처음 본 앱은 전체 창 수집으로 등록된 다음 이 명부에 들어온다.
    private func refreshCollectTargets() async {
        syncScreens() // 명령은 화면 상태를 스스로 동기화한다 — 호출자에게 순서 의식이 없다.
        // 이게 없으면 앱을 켤 때 화면이 이미 꽂혀 있는 경우 등록이 통째로 빠진다:
        // 시작 직후 화면 상태는 '기억만'이고, 연결 이벤트는 이미 지나갔기 때문이다.
        guard labAutoSlot, isConnected else {
            await collectTrigger?.retarget([])
            return
        }
        await collectTrigger?.retarget(slots.targets(for: externalScreens))
    }

    /// 확정 — 사라진 화면의 후보를 자동 슬롯에 쓴다. internal — 테스트가 직접 호출한다.
    /// 이 시점에 창을 읽지 않는다는 것이 이 경로의 핵심이며, 그 이유는 슬롯 모듈에 적혀 있다.
    func confirmCandidates(for screenIDs: Set<String>) {
        for id in screenIDs { pendingSpaceBundles.removeValue(forKey: id) }
        guard slots.confirm(screenIDs) else { return }
        Task { await updatePredictions() }
    }

    /// 종료 직전 — 남은 후보를 전부 확정한다. 화면을 뽑기 전에 앱을 끄면 여기가 마지막 기회다.
    public func confirmAllCandidates() { slots.confirmAll() }

    /// 복원 중 새 화면이 연결됐다 — 지금 복원이 끝난 직후 1회 재복원한다 (조용한 소실 방지).
    private var pendingRestore = false

    /// [⚡ 지금 레이아웃 복원] (F-02). 연결된 모든 외장 화면에 각 프로필을 적용한다.
    /// 반환 시점 = 완료 시점, 반환값 = 결과 — 정책은 전부 RestoreEngine의 일이고, 여기는 배선뿐이다.
    @discardableResult
    public func restoreNow() async -> RestoreOutcome {
        guard checkAuthorization() else { return .notAuthorized } // 수동 복원도 게이트를 지난다 (US-010 AC-2)
        syncScreens()
        guard isConnected else { return .notConnected }
        guard !isRestoring else { return .alreadyRestoring }
        let results = await performRestore(seedSpacePending: spaceRestoreEnabled)
        return .restored(results)
    }

    /// ActiveSpaceWatcher의 무페이로드 이벤트가 들어오는 단일 지점. 복원 중이면 새 열거를
    /// 시작하지 않고, 현재 pass가 끝난 뒤 최신 Space를 한 번만 다시 읽는다.
    func activeSpaceChanged() async {
        guard spaceObservationEnabled else { return }
        if isRestoring {
            pendingSpaceRefresh = true
            return
        }
        syncScreens()
        guard isConnected, checkAuthorization() else { return }
        if restoreMode == .automatic,
           pendingSpaceBundles.values.contains(where: { !$0.isEmpty }) {
            _ = await performRestore(seedSpacePending: false)
        } else if labAutoSlot {
            await collectCandidate()
        }
    }

    private func performRestore(seedSpacePending: Bool) async -> [RestoreResult] {
        isRestoring = true
        // capture·collect·prediction이 먼저 시작한 열거가 있다면 authoritative read보다 앞에서 끝낸다.
        await drainWindowReads()

        let latest: [RestoreResult]
        if spaceRestoreEnabled {
            await relocateBoundRegularSpaces()
            latest = await restoreWithSpaces(seedPending: seedSpacePending)
        } else {
            latest = await restoreLegacy()
        }
        isRestoring = false // 수집·예측 전에 해제 — 둘 다 복원 중엔 양보한다
        await collectCandidate() // pending은 제외하고, 복원으로 정착한 현재 Space만 후보에 담는다
        await updatePredictions()
        return latest
    }

    private func relocateBoundRegularSpaces() async {
        guard labRegularSpaceRestore, let spaceRelocator else { return }
        let resolved = slots.resolvedWithSpaces(for: externalScreens)
        let moveLimit = SpaceRelocationPlanner.desiredCount(
            resolved: resolved, screens: externalScreens
        )
        for _ in 0..<moveLimit {
            guard labRegularSpaceRestore else { return }
            let windows = await readWindows(of: nil)
            guard let before = await stableSpaceSnapshot(for: windows) else { return }
            switch SpaceRelocationPlanner.next(
                resolved: resolved, screens: externalScreens, snapshot: before
            ) {
            case .complete, .blocked:
                return
            case .move(let planned):
                guard await spaceRelocator.relocate(planned.request),
                      let after = await stableSpaceSnapshot(for: windows),
                      SpaceRelocationPlanner.verifies(
                        planned, before: before, after: after
                      ) else { return }
            }
        }
    }

    private func restoreLegacy() async -> [RestoreResult] {
        var latest: [RestoreResult] = []
        repeat {
            pendingRestore = false
            // 엔진은 화면당 프로필 하나만 받고 슬롯을 모른다 — 판정은 슬롯 모듈에서 끝났다.
            let resolved = slots.resolved(for: externalScreens)
            let results = await RestoreEngine.restore(
                profiles: resolved, screens: externalScreens, using: gateway,
                options: RestoreOptions(restoreMinimized: restoreMinimized, reopenWindowless: reopenWindowless))
            // 결과 수명 = 프로필 수명 — 복원 중 삭제된 프로필의 결과를 부활시키지 않는다
            for result in results where slots.source(for: result.screenID) != nil {
                resultsByScreen[result.screenID] = result
            }
            latest = results
            if pendingRestore { syncScreens() } // 보류된 새 화면을 반영해 한 바퀴 더 (멱등이라 수렴)
        } while pendingRestore && isConnected
        return latest
    }

    private func restoreWithSpaces(seedPending: Bool) async -> [RestoreResult] {
        if seedPending { pendingSpaceBundles.removeAll() }
        var shouldSeed = seedPending
        var latest: [RestoreResult] = []

        repeat {
            pendingRestore = false
            pendingSpaceRefresh = false
            let resolved = slots.resolvedWithSpaces(for: externalScreens)
            if shouldSeed { addSpacePending(from: resolved) }

            let onlyBundles: [String: Set<String>]? = shouldSeed ? nil : pendingSpaceBundles
            let bundleIDs = selectedBundleIDs(in: resolved, only: onlyBundles)
            guard !bundleIDs.isEmpty else { break }

            // 새 창 polling은 AX ID를 확보하기 전에 끝낸다. Space-bound 앱은 잘못된 Space에
            // 새 창을 만들 수 있으므로 legacy 앱만 이 옵션을 적용한다.
            await reopenLegacyWindowless(in: resolved, only: onlyBundles)
            // desired fullscreen이 Split View인지 판별하려면 같은 type 4의 비대상 창도 필요하다.
            // 선택·이동은 여전히 selectedApps만 다루므로 비대상 앱은 건드리지 않는다.
            let windows = await readWindows(of: nil)
            let snapshot = await stableSpaceSnapshot(for: windows)
            let pass = await RestoreEngine.restore(
                resolved: resolved,
                screens: externalScreens,
                windows: windows,
                snapshot: snapshot,
                onlyBundles: onlyBundles,
                regularSpacesEnabled: labRegularSpaceRestore,
                fullscreenEnabled: labFullscreenRestore,
                using: gateway,
                options: RestoreOptions(
                    restoreMinimized: restoreMinimized,
                    reopenWindowless: reopenWindowless
                )
            )
            removeCompletedSpaceBindings(pass.completedByScreen)
            record(pass.results)
            latest = pass.results

            if pendingRestore {
                syncScreens()
                shouldSeed = true
            } else {
                shouldSeed = false
            }
        } while isConnected && (pendingRestore || pendingSpaceRefresh)
        return latest
    }

    private func addSpacePending(from resolved: [String: ResolvedProfile]) {
        var claimed = Set<String>()
        for screen in externalScreens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id] else { continue }
            for app in pair.profile.apps where app.isEnabled
                && claimed.insert(app.bundleID).inserted
                && pair.overlay?.byBundle[app.bundleID].map(shouldRestore) == true {
                pendingSpaceBundles[screen.id, default: []].insert(app.bundleID)
            }
        }
    }

    private func shouldRestore(_ binding: SpaceBinding) -> Bool {
        switch binding {
        case .regular:
            return labRegularSpaceRestore
        case .fullscreen, .unresolved(.fullscreen), .unresolved(.fullscreenUnknown):
            return labFullscreenRestore
        case .unresolved:
            return labRegularSpaceRestore || labFullscreenRestore
        }
    }

    private func selectedBundleIDs(
        in resolved: [String: ResolvedProfile], only: [String: Set<String>]?
    ) -> [String] {
        var claimed = Set<String>()
        var selected: [String] = []
        for screen in externalScreens.sorted(by: { $0.id < $1.id }) {
            guard let profile = resolved[screen.id]?.profile else { continue }
            for app in profile.apps where app.isEnabled && claimed.insert(app.bundleID).inserted {
                if only == nil || only?[screen.id]?.contains(app.bundleID) == true {
                    selected.append(app.bundleID)
                }
            }
        }
        return selected
    }

    private func reopenLegacyWindowless(
        in resolved: [String: ResolvedProfile], only: [String: Set<String>]?
    ) async {
        guard reopenWindowless else { return }
        var claimed = Set<String>()
        var windowless: [String] = []
        for screen in externalScreens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id] else { continue }
            for app in pair.profile.apps where app.isEnabled && claimed.insert(app.bundleID).inserted {
                guard only == nil || only?[screen.id]?.contains(app.bundleID) == true,
                      pair.overlay?.byBundle[app.bundleID] == nil,
                      await gateway.isRunning(bundleID: app.bundleID),
                      await readWindows(of: [app.bundleID]).isEmpty else { continue }
                windowless.append(app.bundleID)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for bundleID in windowless {
                group.addTask { _ = await self.gateway.openWindow(bundleID: bundleID) }
            }
        }
    }

    private func removeCompletedSpaceBindings(_ completed: [String: Set<String>]) {
        for (screenID, bundleIDs) in completed {
            pendingSpaceBundles[screenID]?.subtract(bundleIDs)
            if pendingSpaceBundles[screenID]?.isEmpty == true {
                pendingSpaceBundles.removeValue(forKey: screenID)
            }
        }
    }

    private func record(_ results: [RestoreResult]) {
        // 결과 수명 = 프로필 수명 — 복원 중 삭제된 프로필의 결과를 부활시키지 않는다.
        for result in results where slots.source(for: result.screenID) != nil {
            resultsByScreen[result.screenID] = result
        }
    }

    /// 체크 해제는 복원 제외일 뿐, 프로필에서 지우지 않는다 (US-006 AC-2).
    /// screenID nil = 첫 화면 (기존 호출 호환) — 카드는 항상 자기 섹션의 화면을 넘긴다.
    public func setAppEnabled(_ bundleID: String, _ enabled: Bool, on screenID: String? = nil) {
        mutateProfile(on: screenID) { p in
            guard let i = p.apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
            p.apps[i].isEnabled = enabled
        }
    }

    /// 명시적 삭제 — 프로필에서 완전히 제거한다 (US-006 AC-4).
    public func removeApp(_ bundleID: String, on screenID: String? = nil) {
        mutateProfile(on: screenID) { p in p.apps.removeAll { $0.bundleID == bundleID } }
    }

    /// 저장된 모든 프로필 — 연결되지 않은 화면 포함 (F-05.6, US-012 AC-1).
    public var allProfiles: [Profile] { slots.all }

    /// 프로필 통째 삭제 (F-05.6). 그 화면을 다시 연결하면 프로필 없는 화면이다 (US-012 AC-3).
    public func removeProfile(_ screenID: String) {
        slots.remove(screenID: screenID)
        pendingSpaceBundles.removeValue(forKey: screenID)
        resultsByScreen.removeValue(forKey: screenID) // 결과 수명 = 프로필 수명 — 전생의 결과를 남기지 않는다
    }

    private func mutateProfile(on screenID: String?, _ change: (inout Profile) -> Void) {
        guard let id = screenID ?? currentScreenID else { return }
        slots.edit(screenID: id, change)
        let enabled = Set((slots.source(for: id)?.profile.apps ?? [])
            .filter(\.isEnabled).map(\.bundleID))
        pendingSpaceBundles[id]?.formIntersection(enabled)
        if pendingSpaceBundles[id]?.isEmpty == true { pendingSpaceBundles.removeValue(forKey: id) }
    }

    private func updatePredictions() async {
        // 복원 진행 중엔 양보한다 — 여기의 재열거가 진행 중 복원이 든 창 ID를 무효화한다
        // (ID 수명 계약: 마지막 열거만 유효). 복원이 끝나면 스스로 갱신하므로 잃는 것이 없다.
        guard !isRestoring else { return }
        // 화면별로 계산하되 열거는 한 번이다 — 카드가 「그 화면에 뭐가 있나」도 답하기 때문이다(대상 아님 행).
        // 게이트웨이가 actor라 메인은 막히지 않고, 점은 원래 비동기로 채워진다.
        let windows = await readWindows(of: nil)
        let snapshot = spaceObservationEnabled
            ? await stableSpaceSnapshot(for: windows)
            : nil
        // (화면, 실제 ScreenInfo?) 쌍 — 기억만 상태에서는 화면이 없어 제자리 판정이 생략된다.
        let targets: [(screenID: String, screen: ScreenInfo?)] = if isConnected {
            externalScreens.map { ($0.id, $0) }
        } else if case .remembered(let screenID, _) = screenPresence {
            [(screenID, nil)]
        } else {
            []
        }

        var newPredictions: [String: [String: RestorePrediction]] = [:]
        var newSpaceGroups: [String: [SpaceGroup]] = [:]
        var newSpaceConfigurationDiffers: [String: Bool] = [:]
        var newUntracked: [String: [UntrackedApp]] = [:]
        for (screenID, screen) in targets {
            let resolved = slots.resolvedWithSpaces(for: screenID)
            let profile = resolved?.profile
            let bundleIDs = profile?.apps.map(\.bundleID) ?? []
            var running = Set<String>()
            for bundleID in bundleIDs where await gateway.isRunning(bundleID: bundleID) {
                running.insert(bundleID)
            }
            newPredictions[screenID] = profile.map {
                RestoreEngine.predict(
                    profile: $0, on: screen, windows: windows, running: running,
                    options: RestoreOptions(restoreMinimized: restoreMinimized, reopenWindowless: reopenWindowless))
            } ?? [:]
            if spaceObservationEnabled, let resolved {
                newSpaceGroups[screenID] = Self.spaceGroups(
                    in: resolved, snapshot: snapshot, targetConnected: screen != nil
                )
                newSpaceConfigurationDiffers[screenID] = Self.spaceConfigurationDiffers(
                    in: resolved, snapshot: snapshot, targetConnected: screen != nil
                )
            }
            // 껐던 대상 앱이 먼저다 — 좌표가 남아 있어 되돌리기 쉬운 쪽을 위에 둔다.
            let disabled = (profile?.apps.filter { !$0.isEnabled } ?? [])
                .map { UntrackedApp(bundleID: $0.bundleID, displayName: $0.displayName) }
            newUntracked[screenID] = disabled + Self.untracked(in: windows, on: screen,
                                                               excluding: Set(bundleIDs))
        }
        predictionsByScreen = newPredictions
        spaceGroupsByScreen = newSpaceGroups
        spaceConfigurationDiffersByScreen = newSpaceConfigurationDiffers
        untrackedAppsByScreen = newUntracked
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

    /// 카드 체크박스의 유일한 동작 — 「이 앱을 다루나」. screenID nil = 첫 화면 (기존 호출 호환).
    /// 켜면: 그 화면 프로필에 있으면 다시 복원 대상으로(저장된 좌표 그대로), 없으면 지금 자리로 등록한다.
    /// 끄면: 복원에서 빼되 **프로필에서 지우지 않는다** (US-006 AC-2 — 좌표는 남는다).
    /// 화면에서는 이 셋이 한 질문의 답이라 체크박스 하나로 족하다.
    public func setTracked(_ bundleID: String, _ tracked: Bool, on screenID: String? = nil) async {
        let profile = (screenID ?? currentScreenID).flatMap { slots.source(for: $0)?.profile }
        if profile?.apps.contains(where: { $0.bundleID == bundleID }) == true {
            setAppEnabled(bundleID, tracked, on: screenID)
            await updatePredictions() // 켜고 끈 행이 곧바로 제 묶음으로 간다
        } else if tracked {
            await addTargetApp(bundleID) // 창이 실재하는 화면의 프로필에 오른다 — 스스로 갱신한다
        }
    }

    /// 체크를 꺼 프로필에 남아 있는 앱을 완전히 제거한다. 나중에 외장 화면에서 다시
    /// 관찰되면 프로필 밖 앱으로 자연히 목록에 나타난다.
    public func removeUntrackedApp(_ bundleID: String, on screenID: String? = nil) async {
        guard let id = screenID ?? currentScreenID,
              slots.source(for: id)?.profile.apps.contains(where: {
                  $0.bundleID == bundleID && !$0.isEnabled
              }) == true else {
            return
        }
        removeApp(bundleID, on: id)
        await updatePredictions()
    }

    /// 프로필에 없던 앱을 대상 앱 명부에 올린다. **저장이 아니다**:
    /// 다른 앱의 좌표를 덮지 않고, 복원 소스를 뒤집지 않으며, 모으던 후보도 안 버린다.
    @discardableResult
    private func addTargetApp(_ bundleID: String) async -> CaptureOutcome {
        guard checkAuthorization() else { return .notAuthorized }
        guard !isRestoring else { return .restoringInProgress }
        guard !slots.isSaveBlocked else { return .saveBlocked }
        syncScreens()
        guard isConnected else { return .notConnected }
        let windows = await readWindows(of: [bundleID])
        let snapshot = spaceObservationEnabled
            ? await stableSpaceSnapshot(for: windows)
            : nil
        slots.addTarget(windows: windows, on: externalScreens, snapshot: snapshot)
        await refreshCollectTargets() // 새 대상 앱을 이동 관찰에도 넣는다
        await updatePredictions()
        return .captured(appCount: profile?.apps.filter(\.isEnabled).count ?? 0)
    }

    /// 저장소 알림 확인 — 배너만 사라진다. unreadable의 쓰기 금지는 남는다.
    public func dismissStoreNotice() { slots.dismissTrouble() }

    /// UserDefaults 키 — 읽기·쓰기가 같은 이름을 쓰도록 한곳에 (오타는 조용한 버그다).
    private enum Keys {
        static let restoreMode = "restoreMode"
        static let restoreMinimized = "restoreMinimized"
        static let reopenWindowless = "reopenWindowless"
        static let labAutoSlot = "labAutoSlot"
        static let autoSlotUpdateMode = "autoSlotUpdateMode"
        // 기존 defaults key를 유지해 현재 실험 설정을 마이그레이션 없이 이어간다.
        static let labRegularSpaceRestore = "labSpaceRelocation"
        static let labFullscreenRestore = "labFullscreenRestore"
    }

}
