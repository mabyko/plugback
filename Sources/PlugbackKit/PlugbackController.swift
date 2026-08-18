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

    /// 실험실 · 자동 슬롯 (기본 꺼짐). 켜면 외장 화면을 쓰는 동안 배치를 모으고,
    /// 화면을 분리할 때 자동 슬롯에 확정한다. 수동 저장은 이 슬롯에 닿지 않는다.
    /// 끄면 자동 슬롯이 복원 소스 후보에서 빠진다 — 파일은 남아 다시 켜면 이어진다.
    @Published public var labAutoSlot: Bool {
        didSet {
            guard labAutoSlot != oldValue else { return }
            defaults.set(labAutoSlot, forKey: Keys.labAutoSlot)
            slots.isLabEnabled = labAutoSlot // 씨앗 복사·후보 폐기는 슬롯 모듈의 일이다
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

    /// 슬롯 규칙 전부가 여기 산다 — 컨트롤러는 「이 화면의 프로필」만 묻는다.
    private let slots: ProfileSlots
    private var slotChanges: AnyCancellable?
    @Published private var resultsByScreen: [String: RestoreResult] = [:]

    /// 파생 상태 — 수동 동기화 지점을 두지 않는다.
    public var profile: Profile? { currentScreenID.flatMap { slots.source(for: $0)?.profile } }
    /// 지금 복원에 쓰일 슬롯 — 카드가 표시한다. 파생이므로 표시와 동작이 어긋날 수 없다.
    public var restoreSource: Slot? { currentScreenID.flatMap { slots.source(for: $0)?.slot } }
    /// 카드가 보여주는 화면의 마지막 복원 결과.
    public var lastResult: RestoreResult? { currentScreenID.flatMap { resultsByScreen[$0] } }
    /// 카드가 그리는 실험실 상태 — 전부 슬롯 모듈에서 파생된다.
    public var hasPendingCollect: Bool { slots.hasPendingCollect }
    public var lastCollectedAt: Date? { slots.lastCollectedAt }

    private let gateway: WindowGateway
    private let screenProvider: ScreenProvider
    private let defaults: UserDefaults
    private var externalScreens: [ScreenInfo] = []
    private var watcher: DisplayWatcher?
    /// 수집 신호는 이 모듈 하나로 들어온다 — 신호원이 둘이라는 사실은 그 뒤에 있다.
    private var collectTrigger: CollectTrigger?
    /// 창 이동 관찰의 어댑터. 게이트웨이와 같은 seam이지만 다른 인터페이스다 (WindowMoveSource).
    private let moveSource: WindowMoveSource?

    /// 수집 최소 간격 — 실기기 측정 후 조정하는 보정 노브 (테스트는 0을 준다).
    private let collectInterval: TimeInterval
    public init(gateway: WindowGateway, screenProvider: ScreenProvider, store: ProfileStore,
                defaults: UserDefaults = .standard, collectInterval: TimeInterval = 10,
                moveSource: WindowMoveSource? = nil) {
        self.gateway = gateway
        self.screenProvider = screenProvider
        self.defaults = defaults
        self.collectInterval = collectInterval
        self.moveSource = moveSource
        restoreMode = defaults.string(forKey: Keys.restoreMode).flatMap(RestoreMode.init) ?? .automatic
        restoreMinimized = defaults.bool(forKey: Keys.restoreMinimized)
        reopenWindowless = defaults.bool(forKey: Keys.reopenWindowless)
        let lab = defaults.bool(forKey: Keys.labAutoSlot)
        labAutoSlot = lab
        slots = ProfileSlots(store: store, isLabEnabled: lab)
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
        guard !slots.isSaveBlocked else { return .saveBlocked }
        syncScreens()
        guard isConnected else { return .notConnected }
        let windows = await gateway.standardWindows(of: nil)
        slots.capture(windows: windows, on: externalScreens)
        // 「카드가 보여주는 화면 기준」은 컨트롤러의 규칙이다 — 저장소가 알 일이 아니다.
        let count = profile?.apps.count ?? 0
        lastCaptureCount = count
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
        let targets = slots.targets(for: externalScreens)
        guard !targets.isEmpty else { return } // 아는 앱이 없으면 따라갈 것도 없다

        slots.collect(windows: await gateway.standardWindows(of: targets), on: externalScreens)
        await refreshCollectTargets() // 이번에 켜진 앱을 다음 이동부터 따라간다 (등록은 멱등)
    }

    /// 수집 트리거가 따라갈 대상 앱을 지금 상태에 맞춘다.
    /// 수집 열거와 **같은 앱 집합**을 쓴다 — 슬롯 모듈이 그 집합의 유일한 출처다.
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
        isRestoring = true
        defer { isRestoring = false }

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
    public var allProfiles: [Profile] { slots.all }

    /// 프로필 통째 삭제 (F-05.6). 그 화면을 다시 연결하면 프로필 없는 화면이다 (US-012 AC-3).
    public func removeProfile(_ screenID: String) {
        slots.remove(screenID: screenID)
        resultsByScreen.removeValue(forKey: screenID) // 결과 수명 = 프로필 수명 — 전생의 결과를 남기지 않는다
    }

    private func mutateProfile(_ change: (inout Profile) -> Void) {
        guard let id = currentScreenID else { return }
        slots.edit(screenID: id, change)
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
    public func dismissStoreNotice() { slots.dismissTrouble() }

    /// UserDefaults 키 — 읽기·쓰기가 같은 이름을 쓰도록 한곳에 (오타는 조용한 버그다).
    private enum Keys {
        static let restoreMode = "restoreMode"
        static let restoreMinimized = "restoreMinimized"
        static let reopenWindowless = "reopenWindowless"
        static let labAutoSlot = "labAutoSlot"
    }

}
