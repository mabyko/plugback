import Combine
import CoreGraphics
import Foundation

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
    /// UUID는 맞는데 지문이 다른 화면이 있었다 — 복원하지 않았다 (F-01.4).
    @Published public private(set) var identityMismatch = false
    /// 프로필 대상 앱 중 지금 실행 중인 것들 (US-006 AC-1 표시용).
    @Published public private(set) var runningBundleIDs: Set<String> = []
    /// 방금 저장의 확인 표시용 대상 앱 수 (US-002 AC-1). 카드를 다시 열면 사라진다.
    @Published public private(set) var lastCaptureCount: Int?
    /// 프로필 파일이 손상돼 백업 후 초기화된 경우 그 위치 (F-04.2 알림용)
    @Published public private(set) var corruptionBackupURL: URL?

    @Published private var profiles: [String: Profile]
    @Published private var resultsByScreen: [String: RestoreResult] = [:]

    /// 파생 상태 — 수동 동기화 지점을 두지 않는다.
    public var profile: Profile? { currentScreen.flatMap { profiles[$0.id] } }
    /// 카드가 보여주는 화면의 마지막 복원 결과.
    public var lastResult: RestoreResult? { currentScreen.flatMap { resultsByScreen[$0.id] } }

    private let gateway: WindowGateway
    private let screenProvider: ScreenProvider
    private let store: ProfileStore
    private var externalScreens: [ScreenInfo] = []

    public init(gateway: WindowGateway, screenProvider: ScreenProvider, store: ProfileStore) {
        self.gateway = gateway
        self.screenProvider = screenProvider
        self.store = store
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

    /// 카드가 열릴 때 호출 — 화면·실행 상태를 동기화한다.
    public func refresh() {
        lastCaptureCount = nil
        externalScreens = screenProvider.screens().filter { !$0.isBuiltin }
        connectedScreenCount = externalScreens.count
        if let first = externalScreens.first {
            currentScreen = first
            isConnected = true
        } else {
            isConnected = false // currentScreen은 유지 — 마지막 화면 정보
        }
        updateRunningStates()
    }

    /// [💾 지금 레이아웃 저장] (F-03). 연결된 모든 외장 화면의 프로필을 각각 갱신한다.
    public func captureNow() {
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
    /// 같은 앱이 여러 프로필에 있으면 식별자 정렬 순서상 첫 화면만 적용한다 — 한 창을 두 번 옮기지 않는다 (F-01.6).
    public func restoreNow() {
        guard isConnected else { return }
        identityMismatch = false
        var claimed = Set<String>()
        for screen in externalScreens.sorted(by: { $0.id < $1.id }) {
            guard var profile = profiles[screen.id] else { continue }
            // UUID 일치 + 지문 불일치 = OS가 배정을 바꿨다는 신호. 오작동 대신 무작동 (F-01.4).
            if let saved = profile.fingerprint, let live = screen.fingerprint, saved != live {
                identityMismatch = true
                continue
            }
            profile.apps.removeAll { claimed.contains($0.bundleID) }
            resultsByScreen[screen.id] = RestoreEngine.restore(profile: profile, on: screen, using: gateway)
            claimed.formUnion(profile.apps.filter(\.isEnabled).map(\.bundleID))
        }
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

    public func isAppRunning(_ bundleID: String) -> Bool { gateway.isRunning(bundleID: bundleID) }

    private func mutateProfile(_ change: (inout Profile) -> Void) {
        guard let id = currentScreen?.id, var p = profiles[id] else { return }
        change(&p)
        profiles[id] = p
        persist()
    }

    private func updateRunningStates() {
        runningBundleIDs = Set((profile?.apps ?? []).map(\.bundleID).filter(gateway.isRunning))
    }

    private func persist() {
        // ponytail: 저장 실패(디스크 가득 등)는 조용히 넘긴다. 실패 UI가 필요해지면 그때 알림을 단다.
        try? store.save(profiles)
    }
}
