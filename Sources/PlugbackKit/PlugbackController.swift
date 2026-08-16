import Combine
import CoreGraphics
import Foundation

/// 헤드리스 파사드 — UI 없이 완결된다. UI는 이 상태의 표현일 뿐이다 (docs/ARCHITECTURE.md).
@MainActor
public final class PlugbackController: ObservableObject {
    /// 마지막으로 본 외장 화면. 분리돼도 지우지 않는다 —
    /// 빈 상태에서도 카드는 비지 않는다 (ARCHITECTURE 고정 결정).
    /// ponytail: M2는 첫 외장 화면 하나만 본다 — 다중 화면은 M3(F-01.6).
    @Published public private(set) var currentScreen: ScreenInfo?
    /// currentScreen이 지금 실제로 연결되어 있는가.
    @Published public private(set) var isConnected = false
    @Published public private(set) var lastResult: RestoreResult?
    /// 프로필 대상 앱 중 지금 실행 중인 것들 (US-006 AC-1 표시용).
    @Published public private(set) var runningBundleIDs: Set<String> = []
    /// 방금 저장의 확인 표시용 대상 앱 수 (US-002 AC-1). 카드를 다시 열면 사라진다.
    @Published public private(set) var lastCaptureCount: Int?
    /// 프로필 파일이 손상돼 백업 후 초기화된 경우 그 위치 (F-04.2 알림용)
    @Published public private(set) var corruptionBackupURL: URL?

    @Published private var profiles: [String: Profile]

    /// 파생 상태 — 수동 동기화 지점을 두지 않는다.
    public var profile: Profile? { currentScreen.flatMap { profiles[$0.id] } }

    private let gateway: WindowGateway
    private let screenProvider: ScreenProvider
    private let store: ProfileStore

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
        if let live = screenProvider.screens().first(where: { !$0.isBuiltin }) {
            currentScreen = live
            isConnected = true
        } else {
            isConnected = false // currentScreen은 유지 — 마지막 화면 정보
        }
        updateRunningStates()
    }

    /// [💾 지금 레이아웃 저장] (F-03). 저장 시점은 항상 사용자가 정한다.
    public func captureNow() {
        guard isConnected, let screen = currentScreen else { return }
        let merged = CaptureEngine.capture(windows: gateway.standardWindows(of: nil),
                                           on: screen, merging: profiles[screen.id])
        profiles[screen.id] = merged
        lastCaptureCount = merged.apps.count
        persist()
        updateRunningStates()
    }

    /// [⚡ 지금 레이아웃 복원] (F-02). 프로필 없는 화면에서는 아무 창도 움직이지 않는다 (US-007 AC-5).
    public func restoreNow() {
        guard isConnected, let screen = currentScreen, let profile = profiles[screen.id] else { return }
        // ponytail: 동기 실행 — 게이트웨이의 요소별 250ms 한도가 최악을 막는다.
        // 자동 복원이 생기는 M4에서 별도 실행 흐름으로 옮긴다 (F-02.4).
        lastResult = RestoreEngine.restore(profile: profile, on: screen, using: gateway)
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
