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
    /// 카드가 보여주는 화면에서는 실제 복원 결과와 어긋나지 않는다.
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
        didSet { defaults.set(restoreMinimized, forKey: Keys.restoreMinimized) }
    }

    /// 실행 중인데 창이 없는 앱에 새 창을 열게 해 복원할지 (F-02.2 예외 설정). 기본 꺼짐.
    /// 꺼진 앱을 실행하지는 않는다 — F-02.1은 그대로다.
    @Published public var reopenWindowless: Bool {
        didSet { defaults.set(reopenWindowless, forKey: Keys.reopenWindowless) }
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
    public var profile: Profile? { currentScreenID.flatMap { profiles[$0] } }
    /// 카드가 보여주는 화면의 마지막 복원 결과.
    public var lastResult: RestoreResult? { currentScreenID.flatMap { resultsByScreen[$0] } }

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
        restoreMode = defaults.string(forKey: Keys.restoreMode).flatMap(RestoreMode.init) ?? .automatic
        restoreMinimized = defaults.bool(forKey: Keys.restoreMinimized)
        reopenWindowless = defaults.bool(forKey: Keys.reopenWindowless)
        let outcome = store.load()
        profiles = outcome.profiles
        storeNotice = outcome.trouble
        saveBlocked = outcome.trouble == .unreadable
        // 시작 직후의 빈 상태에서도 마지막 화면 이름·프로필 유무를 보여준다.
        // 이름순 첫 프로필 — 사전 순회는 실행마다 순서가 바뀐다 (설정 창의 allProfiles와 같은 기준).
        if let stored = outcome.profiles.values.min(by: { $0.screenName < $1.screenName }) {
            screenPresence = .remembered(screenID: stored.screenID, name: stored.screenName)
        }
    }

    /// 화면 연결 감시 시작 (M4). 새 외장 화면이 나타나면 자동 모드일 때 복원한다 (F-01.1).
    /// 시간 상수는 DisplayWatcher의 것 — 여기서 다시 선언하지 않는다.
    public func startWatching() {
        guard watcher == nil else { return }
        let w = DisplayWatcher(provider: screenProvider) { [weak self] in
            guard let self else { return }
            Task { await self.externalScreensAppeared() }
        }
        w.start()
        watcher = w
    }

    // internal — DisplayWatcher 콜백. 테스트가 직접 호출한다.
    func externalScreensAppeared() async {
        syncScreens()
        await updatePredictions() // 카드가 열려 있는 채로 연결돼도 점이 맞게 (예측 갱신)
        guard restoreMode == .automatic else { return } // 수동 모드면 연결돼도 복원하지 않는다 (US-007 AC-4)
        // 권한 게이트는 restoreNow 내부에 있다 — 여기서 중복 검사하지 않는다
        if isRestoring {
            pendingRestore = true // 진행 중 복원이 끝난 직후 1회 재복원 — 새 화면이 조용히 소실되지 않는다
            return
        }
        // 새 화면에 프로필이 없으면 restoreNow가 자연히 아무것도 하지 않는다 (F-01.1 조건 3).
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
        for screen in externalScreens {
            var merged = CaptureEngine.capture(windows: windows, on: screen, merging: profiles[screen.id])
            merged.fingerprint = screen.fingerprint
            profiles[screen.id] = merged
        }
        let count = profile?.apps.count ?? 0
        lastCaptureCount = count
        persist()
        await updatePredictions()
        return .captured(appCount: count)
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
            let results = await RestoreEngine.restore(
                profiles: profiles, screens: externalScreens, using: gateway,
                options: RestoreOptions(restoreMinimized: restoreMinimized, reopenWindowless: reopenWindowless))
            // 결과 수명 = 프로필 수명 — 복원 중 삭제된 프로필의 결과를 부활시키지 않는다
            for result in results where profiles[result.screenID] != nil {
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
    public var allProfiles: [Profile] {
        profiles.values.sorted { $0.screenName < $1.screenName }
    }

    /// 프로필 통째 삭제 (F-05.6). 그 화면을 다시 연결하면 프로필 없는 화면이다 (US-012 AC-3).
    public func removeProfile(_ screenID: String) {
        profiles.removeValue(forKey: screenID)
        resultsByScreen.removeValue(forKey: screenID) // 결과 수명 = 프로필 수명 — 전생의 결과를 남기지 않는다
        persist()
    }

    private func mutateProfile(_ change: (inout Profile) -> Void) {
        guard let id = currentScreenID, var p = profiles[id] else { return }
        change(&p)
        profiles[id] = p
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
    }

    private func persist() {
        guard !saveBlocked else { return } // 읽기 실패를 첫 실행처럼 덮어쓰면 손상보다 나쁜 손실이다
        store.save(profiles)
    }
}
