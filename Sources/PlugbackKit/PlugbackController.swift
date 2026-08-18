import Combine
import CoreGraphics
import Foundation

/// 복원 모드 (F-05.4). 저장은 항상 수동이므로 설정이 없다.
public enum RestoreMode: String, Sendable {
    case automatic, manual
}

/// captureNow의 반환 — 조용한 거부가 없다 (restoreNow와 같은 원칙).
public enum CaptureOutcome: Equatable, Sendable {
    /// 저장 완료 — 카드가 보여주는 화면 기준 대상 앱 수.
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

    /// 카드가 가리키는 화면의 식별자 — 연결됐든 기억이든.
    private var currentScreenID: String? {
        switch screenPresence {
        case .connected(let screen, _): return screen.id
        case .remembered(let screenID, _): return screenID
        case .none: return nil
        }
    }
    /// 복원 진행 중 — 재진입 가드이자 버튼 비활성용 UI 상태.
    @Published public private(set) var isRestoring = false
    /// 대상 앱별 복원 예측 — "복원하면 이 앱이 어떻게 될까"의 답 (US-006 AC-1의 점이 이것을 그린다).
    /// 엔진의 창 선택 규칙 그대로 계산되고, 카드의 현재 화면 = 중복 제거의 첫 화면이므로
    /// 카드가 보여주는 화면에서는 판정 규칙이 어긋나지 않는다. 실행 시점 사건(이동 실패·새 창 미등장·
    /// 지문 불일치·체크 해제)은 예측 범위 밖 — 결과 스트립과 알림이 사후에 답한다.
    @Published public private(set) var predictions: [String: RestorePrediction] = [:]
    /// 방금 저장의 확인 표시용 대상 앱 수 (US-002 AC-1). 카드를 다시 열면 사라진다.
    @Published public private(set) var lastCaptureCount: Int?
    /// 저장소 문제 알림 (F-04.2). 사용자가 확인하면 사라진다 — 영구 배너가 아니다.
    @Published public private(set) var storeNotice: ProfileStore.LoadOutcome.Trouble?
    /// 읽지 못한 파일 위에 쓰지 않는다 — 알림을 닫아도 이 금지는 프로세스 수명 동안 유지된다.
    private let saveBlocked: Bool

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

    /// 실험실 · 자동 슬롯 (기본 꺼짐). 켜면 외장 화면을 쓰는 동안 배치를 모으고,
    /// 화면을 분리할 때 자동 슬롯에 확정한다. 수동 저장은 이 슬롯에 닿지 않는다.
    /// 끄면 자동 슬롯이 복원 소스 후보에서 빠진다 — 파일은 남아 다시 켜면 이어진다.
    @Published public var labAutoSlot: Bool {
        didSet {
            guard labAutoSlot != oldValue else { return }
            defaults.set(labAutoSlot, forKey: Keys.labAutoSlot)
            if labAutoSlot { seedAutoSlots() } else { candidates.removeAll() }
            syncCollectTrigger()
            refreshPredictionsAfterOptionChange() // 복원 소스가 바뀌면 점도 바뀐다
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

    @Published private var profiles: [String: Profile]
    @Published private var resultsByScreen: [String: RestoreResult] = [:]

    /// 복원 소스 판정 — **더 최근에 저장된 슬롯이 이긴다.** 저장된 "활성 슬롯"은 없다.
    /// 확정은 케이블을 뽑았다는 이유로 최신이 되고, 사람이 방금 저장했으면 그쪽이 최신이다.
    /// 규칙 하나가 두 경우를 다 설명하므로 어긋날 상태가 존재하지 않는다.
    /// 동점이면 수동이 이긴다 — 후보 배열에서 앞에 두면 `max(by:)`가 그렇게 고른다.
    /// 실험실이 꺼져 있으면 자동 슬롯은 후보에 아예 들어가지 않는다.
    func resolvedSource(for screenID: String) -> (slot: Slot, profile: Profile)? {
        var pool: [(Slot, Profile)] = []
        if let manual = profiles[Slot.manual.key(screenID)] { pool.append((.manual, manual)) }
        if labAutoSlot, let auto = profiles[Slot.auto.key(screenID)] { pool.append((.auto, auto)) }
        return pool
            .max { ($0.1.savedAt ?? .distantPast) < ($1.1.savedAt ?? .distantPast) }
            .map { (slot: $0.0, profile: $0.1) }
    }

    /// 파생 상태 — 수동 동기화 지점을 두지 않는다.
    public var profile: Profile? { currentScreenID.flatMap { resolvedSource(for: $0)?.profile } }
    /// 지금 복원에 쓰일 슬롯 — 카드가 표시한다. 파생이므로 표시와 동작이 어긋날 수 없다.
    public var restoreSource: Slot? { currentScreenID.flatMap { resolvedSource(for: $0)?.slot } }
    /// 카드가 보여주는 화면의 마지막 복원 결과.
    public var lastResult: RestoreResult? { currentScreenID.flatMap { resultsByScreen[$0] } }

    private let gateway: WindowGateway
    private let screenProvider: ScreenProvider
    private let store: ProfileStore
    private let defaults: UserDefaults
    private var externalScreens: [ScreenInfo] = []
    private var watcher: DisplayWatcher?
    /// 수집 신호는 이 모듈 하나로 들어온다 — 신호원이 둘이라는 사실은 그 뒤에 있다.
    private var collectTrigger: CollectTrigger?
    /// 창 이동 관찰의 어댑터. 게이트웨이와 같은 seam이지만 다른 인터페이스다 (WindowMoveSource).
    private let moveSource: WindowMoveSource?

    /// 수집 최소 간격 — 실기기 측정 후 조정하는 보정 노브 (테스트는 0을 준다).
    private let collectInterval: TimeInterval
    /// 화면별 수집 후보. **메모리에만 산다** — 확정 전까지 파일에 닿지 않는다.
    /// 앱이 죽으면 그 세션의 수집만 사라지고 두 슬롯은 온전하다.
    private var candidates: [String: Profile] = [:]

    /// 확정을 기다리는 변경이 있나 — 후보가 자동 슬롯과 다른 화면이 하나라도 있는가.
    /// 카드가 **"지금 복원되는 값"과 "뽑을 때 저장될 값"을 구별해** 보여주기 위한 것이다.
    /// 이 구별이 없으면 "수집됨"이 "저장됨"으로 읽혀서, 방금 옮겼는데 복원이 왜 다른
    /// 자리로 가는지 설명할 길이 없다 (2026-08-19에 실제로 그 질문을 받았다).
    public var hasPendingCollect: Bool {
        candidates.contains { id, candidate in
            candidate.apps != profiles[Slot.auto.key(id)]?.apps
        }
    }

    /// 마지막으로 수집이 실제로 돈 시각 (실험실). 카드가 보여준다.
    /// 수집은 눈에 보이는 일을 하지 않아서, 이게 없으면 "돌고 있는지"를 물어볼 곳이 없다 —
    /// 트리거가 잘못됐을 때 확정된 뒤에야 알게 된다 (2026-08-18에 실제로 그랬다).
    @Published public private(set) var lastCollectedAt: Date?

    public init(gateway: WindowGateway, screenProvider: ScreenProvider, store: ProfileStore,
                defaults: UserDefaults = .standard, collectInterval: TimeInterval = 10,
                moveSource: WindowMoveSource? = nil) {
        self.gateway = gateway
        self.screenProvider = screenProvider
        self.store = store
        self.defaults = defaults
        self.collectInterval = collectInterval
        self.moveSource = moveSource
        restoreMode = defaults.string(forKey: Keys.restoreMode).flatMap(RestoreMode.init) ?? .automatic
        restoreMinimized = defaults.bool(forKey: Keys.restoreMinimized)
        reopenWindowless = defaults.bool(forKey: Keys.reopenWindowless)
        labAutoSlot = defaults.bool(forKey: Keys.labAutoSlot)
        let outcome = store.load()
        profiles = outcome.profiles
        storeNotice = outcome.trouble
        saveBlocked = outcome.trouble == .unreadable
        // 시작 직후의 빈 상태에서도 마지막 화면 이름·프로필 유무를 보여준다.
        // 이름순 첫 프로필 — 사전 순회는 실행마다 순서가 바뀐다 (설정 창의 allProfiles와 같은 기준).
        // 자동 슬롯은 제외한다 — 같은 화면이 두 번 세어지면 "이름순 첫"이 뜻을 잃는다.
        if let stored = outcome.profiles.filter({ !Slot.isAutoKey($0.key) }).values
            .min(by: { $0.screenName < $1.screenName }) {
            screenPresence = .remembered(screenID: stored.screenID, name: stored.screenName)
        }
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
        syncCollectTrigger() // 실행 시점에 실험실이 켜져 있으면 수집도 같이 시작한다
    }

    /// 실험실 상태와 수집 트리거를 맞춘다. 꺼진 기능이 알림을 받고 있으면 "꺼짐"이 아니다.
    /// 신호원이 둘이라는 사실은 트리거 뒤에 있다 — 여기는 켜고 끄고 대상을 맞출 뿐이다.
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
        Task { await refreshCollectTargets() }
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

    /// [💾 지금 레이아웃 저장] (F-03). 연결된 모든 외장 화면의 프로필을 각각 갱신한다.
    /// async — 창 열거가 이 동작의 본체라서다. 반환값 = 실행/거부 사유 — 확인 표시는 진짜 저장됐을 때만 뜬다.
    @discardableResult
    public func captureNow() async -> CaptureOutcome {
        guard checkAuthorization() else { return .notAuthorized } // 권한 없이 빈 열거로 저장하지 않는다
        guard !isRestoring else { return .restoringInProgress }   // 반쯤 복원된 배치를 박제하지 않는다
        // 저장이 차단된 실행에서 메모리에만 담는 저장은 재시작에 증발하는 거짓 저장이다 —
        // 확인 표시("저장됨")가 거짓이 되지 않게 아예 거부한다. 이유는 저장소 알림 배너가 설명한다.
        guard !saveBlocked else { return .saveBlocked }
        syncScreens()
        guard isConnected else { return .notConnected }
        let windows = await gateway.standardWindows(of: nil)
        let now = Date()
        for screen in externalScreens {
            let key = Slot.manual.key(screen.id) // 사람은 수동 슬롯에만 쓴다 — 자동 슬롯에 닿지 않는다
            var merged = CaptureEngine.capture(windows: windows, on: screen, merging: profiles[key])
            merged.fingerprint = screen.fingerprint
            // 방금 저장한 것이 가장 최근이 된다 — 다음 복원이 이 배치를 쓴다.
            // 별도의 "활성 슬롯 전환"이 필요 없는 이유가 이것이다.
            merged.savedAt = now
            profiles[key] = merged
        }
        let count = profile?.apps.count ?? 0
        lastCaptureCount = count
        persist()
        await updatePredictions()
        return .captured(appCount: count)
    }

    // MARK: - 실험실 · 자동 슬롯 (수집 → 확정)

    /// 수집 — 지금 배치를 메모리 후보에 담는다. **파일에는 닿지 않는다.**
    /// internal — 테스트가 알림 없이 직접 호출한다.
    ///
    /// 대상 앱만 열거한다. 새 앱을 프로필에 등록하는 것은 수동 저장의 몫이고,
    /// 자동 슬롯은 이미 아는 앱의 위치만 따라간다 — 그래서 열거가 싸고, 수동 저장이 의미를 유지한다.
    func collectCandidate() async {
        guard labAutoSlot, !isRestoring else { return }
        syncScreens()
        guard isConnected else { return }

        let bases = collectBases()
        let targets = Set(bases.values.flatMap { $0.apps.map(\.bundleID) })
        guard !targets.isEmpty else { return } // 아는 앱이 없으면 따라갈 것도 없다

        let windows = await gateway.standardWindows(of: Array(targets))
        for screen in externalScreens {
            guard let base = bases[screen.id] else { continue }
            var next = CaptureEngine.capture(windows: windows, on: screen, merging: base)
            next.fingerprint = screen.fingerprint
            candidates[screen.id] = next
        }
        lastCollectedAt = Date()
        await refreshCollectTargets() // 이번에 켜진 앱을 다음 이동부터 따라간다 (등록은 멱등)
    }

    /// 화면별 수집 바탕 — 후보가 있으면 후보, 없으면 자동 슬롯, 그것도 없으면 수동 슬롯.
    private func collectBases() -> [String: Profile] {
        externalScreens.reduce(into: [String: Profile]()) { out, screen in
            out[screen.id] = candidates[screen.id]
                ?? profiles[Slot.auto.key(screen.id)]
                ?? profiles[Slot.manual.key(screen.id)]
        }
    }

    /// 수집 트리거가 따라갈 대상 앱을 지금 상태에 맞춘다.
    /// 수집 열거와 **같은 앱 집합**을 쓴다 — 어긋나면 관찰은 되는데 수집이 안 되는 앱이 생긴다.
    private func refreshCollectTargets() async {
        syncScreens() // 명령은 화면 상태를 스스로 동기화한다 — 호출자에게 순서 의식이 없다.
        // 이게 없으면 앱을 켤 때 화면이 이미 꽂혀 있는 경우 등록이 통째로 빠진다:
        // 시작 직후 화면 상태는 '기억만'이고, 연결 이벤트는 이미 지나갔기 때문이다.
        guard labAutoSlot, isConnected else {
            await collectTrigger?.retarget([])
            return
        }
        let targets = Set(collectBases().values.flatMap { $0.apps.map(\.bundleID) })
        await collectTrigger?.retarget(Array(targets))
    }

    /// 확정 — 사라진 화면의 후보를 자동 슬롯에 쓴다. internal — 테스트가 직접 호출한다.
    ///
    /// **이 시점에 창을 읽지 않는다.** macOS는 케이블이 빠지면 창을 내장 화면으로 먼저 옮기고
    /// 알림은 그 뒤에 온다 — 여기서 열거하면 이미 늦다. 수집과 확정을 나눈 이유가 이것이다.
    func confirmCandidates(for screenIDs: Set<String>) {
        guard labAutoSlot else { return }
        let now = Date()
        var wrote = false
        for id in screenIDs {
            guard var candidate = candidates.removeValue(forKey: id) else { continue }
            candidate.savedAt = now
            profiles[Slot.auto.key(id)] = candidate
            wrote = true
        }
        guard wrote else { return }
        persist()
        Task { await updatePredictions() }
    }

    /// 종료 직전 — 남은 후보를 전부 확정한다. 화면을 뽑기 전에 앱을 끄면 여기가 마지막 기회다.
    public func confirmAllCandidates() {
        confirmCandidates(for: Set(candidates.keys))
    }

    /// 실험실을 켤 때 수동 슬롯을 자동 슬롯의 씨앗으로 복사한다.
    /// 없으면 자동 슬롯이 빈 채로 시작해서, 오늘 켜지 않은 앱이 첫 확정에서 통째로 빠진다 (US-002 AC-4).
    /// savedAt은 그대로 옮긴다 — 내용이 같으니 수동이 계속 이겨도 복원 결과가 같다.
    private func seedAutoSlots() {
        var seeded = false
        for (key, manual) in profiles where !Slot.isAutoKey(key) {
            let autoKey = Slot.auto.key(key)
            guard profiles[autoKey] == nil else { continue } // 다시 켤 때 기존 자동 슬롯을 덮지 않는다
            profiles[autoKey] = manual
            seeded = true
        }
        if seeded { persist() }
    }

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
        isRestoring = true
        defer { isRestoring = false }

        var latest: [RestoreResult] = []
        repeat {
            pendingRestore = false
            // 슬롯 판정은 여기서 끝난다 — 엔진은 화면당 프로필 하나만 받고 슬롯을 모른다.
            var resolved: [String: Profile] = [:]
            for screen in externalScreens {
                if let source = resolvedSource(for: screen.id) { resolved[screen.id] = source.profile }
            }
            let results = await RestoreEngine.restore(
                profiles: resolved, screens: externalScreens, using: gateway,
                options: RestoreOptions(restoreMinimized: restoreMinimized, reopenWindowless: reopenWindowless))
            // 결과 수명 = 프로필 수명 — 복원 중 삭제된 프로필의 결과를 부활시키지 않는다
            for result in results where resolvedSource(for: result.screenID) != nil {
                resultsByScreen[result.screenID] = result
            }
            latest = results
            if pendingRestore { syncScreens() } // 보류된 새 화면을 반영해 한 바퀴 더 (멱등이라 수렴)
        } while pendingRestore && isConnected
        isRestoring = false // 예측 갱신 전에 해제 — updatePredictions는 복원 중엔 양보한다
        await updatePredictions()
        return .restored(latest)
    }

    /// 체크 해제는 복원 제외일 뿐, 프로필에서 지우지 않는다 (US-006 AC-2).
    public func setAppEnabled(_ bundleID: String, _ enabled: Bool) {
        mutateProfile { p in
            guard let i = p.apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
            p.apps[i].isEnabled = enabled
        }
    }

    /// 명시적 삭제 — 프로필에서 완전히 제거한다 (US-006 AC-4).
    public func removeApp(_ bundleID: String) {
        mutateProfile { p in p.apps.removeAll { $0.bundleID == bundleID } }
    }

    /// 저장된 모든 프로필 — 연결되지 않은 화면 포함 (F-05.6, US-012 AC-1).
    /// 자동 슬롯은 목록에 넣지 않는다 — 화면 하나가 두 줄로 보이면 어느 것을 지워야 할지 알 수 없다.
    public var allProfiles: [Profile] {
        profiles.filter { !Slot.isAutoKey($0.key) }.values.sorted { $0.screenName < $1.screenName }
    }

    /// 프로필 통째 삭제 (F-05.6). 그 화면을 다시 연결하면 프로필 없는 화면이다 (US-012 AC-3).
    public func removeProfile(_ screenID: String) {
        profiles.removeValue(forKey: Slot.manual.key(screenID))
        profiles.removeValue(forKey: Slot.auto.key(screenID)) // 슬롯 둘 다 — 한쪽만 남으면 지울 길 없는 유령이 된다
        candidates.removeValue(forKey: screenID)              // 모으던 것도 버린다 — 지운 화면을 되살리지 않는다
        resultsByScreen.removeValue(forKey: screenID) // 결과 수명 = 프로필 수명 — 전생의 결과를 남기지 않는다
        persist()
    }

    /// 카드가 보여주는 슬롯을 고친다. 목록은 이긴 슬롯의 것인데 수정이 수동 슬롯으로 가면,
    /// 눈에 보이는 것과 고쳐지는 것이 어긋난다 (체크를 껐는데 그대로 복원되는 증상).
    private func mutateProfile(_ change: (inout Profile) -> Void) {
        guard let id = currentScreenID, let slot = restoreSource else { return }
        let key = slot.key(id)
        guard var p = profiles[key] else { return }
        change(&p)
        profiles[key] = p
        persist()
    }

    private func updatePredictions() async {
        // 복원 진행 중엔 양보한다 — 여기의 재열거가 진행 중 복원이 든 창 ID를 무효화한다
        // (ID 수명 계약: 마지막 열거만 유효). 복원이 끝나면 스스로 갱신하므로 잃는 것이 없다.
        guard !isRestoring else { return }
        guard let profile else { predictions = [:]; return }
        let targets = profile.apps.map(\.bundleID)
        var running = Set<String>()
        for bundleID in targets where await gateway.isRunning(bundleID: bundleID) {
            running.insert(bundleID)
        }
        // 대상 앱만 열거 — 카드가 열릴 때뿐이라 AX 왕복 비용은 감당 범위
        let windows = await gateway.standardWindows(of: targets)
        let screen: ScreenInfo? = if case .connected(let s, _) = screenPresence { s } else { nil }
        predictions = RestoreEngine.predict(
            profile: profile, on: screen, windows: windows, running: running,
            options: RestoreOptions(restoreMinimized: restoreMinimized, reopenWindowless: reopenWindowless))
    }

    /// 저장소 알림 확인 — 배너만 사라진다. unreadable의 쓰기 금지는 남는다.
    public func dismissStoreNotice() { storeNotice = nil }

    /// UserDefaults 키 — 읽기·쓰기가 같은 이름을 쓰도록 한곳에 (오타는 조용한 버그다).
    private enum Keys {
        static let restoreMode = "restoreMode"
        static let restoreMinimized = "restoreMinimized"
        static let reopenWindowless = "reopenWindowless"
        static let labAutoSlot = "labAutoSlot"
    }

    private func persist() {
        guard !saveBlocked else { return } // 읽기 실패를 첫 실행처럼 덮어쓰면 손상보다 나쁜 손실이다
        store.save(profiles)
    }
}
