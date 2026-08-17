import Combine
import CoreGraphics
import Foundation

/// 복원 모드 (F-05.4). 저장은 항상 수동이므로 설정이 없다.
public enum RestoreMode: String, Sendable {
    case automatic, manual
}

/// 헤드리스 파사드 — UI 없이 완결된다. UI는 이 상태의 표현일 뿐이다 (docs/ARCHITECTURE.md).
@MainActor
public final class PlugbackController: ObservableObject {
    /// 카드가 보여주는 화면(첫 외장). 분리돼도 지우지 않는다 —
    /// 빈 상태에서도 카드는 비지 않는다 (ARCHITECTURE 고정 결정).
    @Published public private(set) var currentScreen: ScreenInfo?
    /// currentScreen이 지금 실제로 연결되어 있는가.
    @Published public private(set) var isConnected = false
    /// 지금 연결된 외장 화면 수 (다중 화면 표시용).
    @Published public private(set) var connectedScreenCount = 0
    /// 복원 진행 중 — 재진입 가드이자 버튼 비활성용 UI 상태.
    @Published public private(set) var isRestoring = false
    /// 프로필 대상 앱 중 지금 실행 중인 것들 (US-006 AC-1 표시용).
    @Published public private(set) var runningBundleIDs: Set<String> = []
    /// 그중 표준 창이 하나라도 있는 것들 — "복원하면 옮겨질까"를 미리 답한다.
    /// 실행 중인데 여기 없으면 복원 시 .skipped(.noWindow)가 될 앱이다.
    @Published public private(set) var windowedBundleIDs: Set<String> = []
    /// 방금 저장의 확인 표시용 대상 앱 수 (US-002 AC-1). 카드를 다시 열면 사라진다.
    @Published public private(set) var lastCaptureCount: Int?
    /// 프로필 파일이 손상돼 백업 후 초기화된 경우 그 위치 (F-04.2 알림용)
    @Published public private(set) var corruptionBackupURL: URL?

    /// 복원 모드 (F-05.4). 기본값 자동, 변경은 보존된다.
    @Published public var restoreMode: RestoreMode {
        didSet { defaults.set(restoreMode.rawValue, forKey: "restoreMode") }
    }

    /// 최소화된 창도 Dock에서 꺼내 복원할지 (F-02.2 예외 설정). 기본 꺼짐 — 최소화는 사용자의 의도다.
    @Published public var restoreMinimized: Bool {
        didSet { defaults.set(restoreMinimized, forKey: "restoreMinimized") }
    }

    /// 실행 중인데 창이 없는 앱에 새 창을 열게 해 복원할지 (F-02.2 예외 설정). 기본 꺼짐.
    /// 꺼진 앱을 실행하지는 않는다 — F-02.1은 그대로다.
    @Published public var reopenWindowless: Bool {
        didSet { defaults.set(reopenWindowless, forKey: "reopenWindowless") }
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

    /// 파생 상태 — 수동 동기화 지점을 두지 않는다.
    public var profile: Profile? { currentScreen.flatMap { profiles[$0.id] } }
    /// 카드가 보여주는 화면의 마지막 복원 결과.
    public var lastResult: RestoreResult? { currentScreen.flatMap { resultsByScreen[$0.id] } }

    private let gateway: WindowGateway
    private let screenProvider: ScreenProvider
    private let store: ProfileStore
    private let defaults: UserDefaults
    private var externalScreens: [ScreenInfo] = []
    private var watcher: DisplayWatcher?

    public init(gateway: WindowGateway, screenProvider: ScreenProvider, store: ProfileStore,
                defaults: UserDefaults = .standard) {
        self.gateway = gateway
        self.screenProvider = screenProvider
        self.store = store
        self.defaults = defaults
        restoreMode = defaults.string(forKey: "restoreMode").flatMap(RestoreMode.init) ?? .automatic
        restoreMinimized = defaults.bool(forKey: "restoreMinimized")
        reopenWindowless = defaults.bool(forKey: "reopenWindowless")
        let outcome = store.load()
        profiles = outcome.profiles
        corruptionBackupURL = outcome.corruptionBackupURL
        // 시작 직후의 빈 상태에서도 마지막 화면 이름·프로필 유무를 보여준다.
        // frame은 연결 전엔 쓰이지 않는다(모든 동작이 isConnected로 막힘).
        if let stored = outcome.profiles.values.first {
            currentScreen = ScreenInfo(id: stored.screenID, name: stored.screenName,
                                       frame: .zero, isBuiltin: false)
        }
    }

    /// 화면 연결 감시 시작 (M4). 새 외장 화면이 나타나면 자동 모드일 때 복원한다 (F-01.1).
    public func startWatching(debounceInterval: TimeInterval = 1.5) {
        guard watcher == nil else { return }
        let w = DisplayWatcher(provider: screenProvider, debounceInterval: debounceInterval) { [weak self] ids in
            guard let self else { return }
            Task { await self.externalScreensAppeared(ids) }
        }
        w.start()
        watcher = w
    }

    // internal — DisplayWatcher 콜백. 테스트가 직접 호출한다.
    func externalScreensAppeared(_ ids: [String]) async {
        syncScreens()
        updateRunningStates() // 카드가 열려 있는 채로 연결돼도 점이 맞게
        guard restoreMode == .automatic else { return } // 수동 모드면 연결돼도 복원하지 않는다 (US-007 AC-4)
        // 권한 게이트는 restoreNow 내부에 있다 — 여기서 중복 검사하지 않는다
        // 새 화면에 프로필이 없으면 restoreNow가 자연히 아무것도 하지 않는다 (F-01.1 조건 3).
        // 이미 제자리인 창은 건너뛰므로 기존 화면까지 포함해 복원해도 창이 흔들리지 않는다 (F-02.2).
        await restoreNow()
    }

    /// 카드가 열리는 순간의 통지 — 화면·실행 상태를 동기화하고,
    /// 일회성 저장 확인 표시를 만료시킨다 (US-002 AC-1: 카드를 다시 열면 사라진다).
    public func cardOpened() {
        checkAuthorization()
        lastCaptureCount = nil
        syncScreens()
        updateRunningStates()
    }

    /// 화면 상태 동기화. 명령이 스스로 호출한다 — 호출자에게 순서 의식이 없다.
    private func syncScreens() {
        externalScreens = screenProvider.screens().filter { !$0.isBuiltin }
        connectedScreenCount = externalScreens.count
        if let first = externalScreens.first {
            currentScreen = first
            isConnected = true
        } else {
            isConnected = false // currentScreen은 유지 — 마지막 화면 정보
        }
    }

    /// [💾 지금 레이아웃 저장] (F-03). 연결된 모든 외장 화면의 프로필을 각각 갱신한다.
    public func captureNow() {
        guard checkAuthorization() else { return } // 권한 없이 빈 열거로 저장하지 않는다
        syncScreens()
        guard isConnected else { return }
        let windows = gateway.standardWindows(of: nil)
        for screen in externalScreens {
            var merged = CaptureEngine.capture(windows: windows, on: screen, merging: profiles[screen.id])
            merged.fingerprint = screen.fingerprint
            profiles[screen.id] = merged
        }
        lastCaptureCount = profile?.apps.count
        persist()
        updateRunningStates()
    }

    /// [⚡ 지금 레이아웃 복원] (F-02). 연결된 모든 외장 화면에 각 프로필을 적용한다.
    /// 반환 시점 = 완료 시점 — 정책은 전부 RestoreEngine의 일이고, 여기는 배선뿐이다.
    public func restoreNow() async {
        guard checkAuthorization() else { return } // 수동 복원도 게이트를 지난다 (US-010 AC-2)
        syncScreens()
        guard isConnected, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        let results = await RestoreEngine.restore(
            profiles: profiles, screens: externalScreens, using: gateway,
            options: RestoreOptions(restoreMinimized: restoreMinimized, reopenWindowless: reopenWindowless))
        for result in results { resultsByScreen[result.screenID] = result }
        updateRunningStates()
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
    public var allProfiles: [Profile] {
        profiles.values.sorted { $0.screenName < $1.screenName }
    }

    /// 프로필 통째 삭제 (F-05.6). 그 화면을 다시 연결하면 프로필 없는 화면이다 (US-012 AC-3).
    public func removeProfile(_ screenID: String) {
        profiles.removeValue(forKey: screenID)
        persist()
    }

    public func isAppRunning(_ bundleID: String) -> Bool { gateway.isRunning(bundleID: bundleID) }

    private func mutateProfile(_ change: (inout Profile) -> Void) {
        guard let id = currentScreen?.id, var p = profiles[id] else { return }
        change(&p)
        profiles[id] = p
        persist()
    }

    private func updateRunningStates() {
        let targets = (profile?.apps ?? []).map(\.bundleID)
        runningBundleIDs = Set(targets.filter(gateway.isRunning))
        // 대상 앱만 열거 — 카드가 열릴 때뿐이라 AX 왕복 비용은 감당 범위
        windowedBundleIDs = Set(gateway.standardWindows(of: targets).map(\.appBundleID))
    }

    private func persist() {
        // ponytail: 저장 실패(디스크 가득 등)는 조용히 넘긴다. 실패 UI가 필요해지면 그때 알림을 단다.
        try? store.save(profiles)
    }
}
