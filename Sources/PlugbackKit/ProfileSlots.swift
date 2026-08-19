import Combine
import Foundation

/// 저장된 프로필 전부와, 그것을 쓰는 규칙 전부 (F-04, F-08).
///
/// 화면 하나가 슬롯 둘을 갖는다는 사실은 이 안에서 끝난다 — 바깥은 「이 화면의 프로필」만 묻는다.
/// 숨기는 것: 슬롯 키 규약, 복원 소스 판정(더 최근 것·동점은 수동), 씨앗 복사, 수집 후보의 수명,
/// 확정, 병합, 실험실 on/off가 후보 판정에 미치는 영향, 그리고 읽지 못한 파일에 쓰지 않는 금지.
///
/// ObservableObject다 — 카드가 이 상태를 직접 그린다. 컨트롤러는 변경을 자기 것으로 전달만 한다.
@MainActor
final class ProfileSlots: ObservableObject {
    private let store: ProfileStore
    @Published private var profiles: [String: Profile]

    /// 화면별 수집 후보. **메모리에만 산다** — 확정 전까지 파일에 닿지 않는다.
    /// 앱이 죽으면 그 세션의 수집만 사라지고 두 슬롯은 온전하다.
    @Published private var candidates: [String: Profile] = [:]

    /// 마지막으로 수집이 실제로 돈 시각. 수집은 눈에 보이는 일을 하지 않아서,
    /// 이게 없으면 "돌고 있는지"를 물어볼 곳이 없다 (2026-08-18 실기기에서 실제로 그랬다).
    @Published private(set) var lastCollectedAt: Date?

    /// 로드 중 만난 문제. 표시는 바깥의 일이다.
    @Published private(set) var trouble: ProfileStore.LoadOutcome.Trouble?

    /// 읽지 못한 파일 위에 쓰지 않는다 — 알림을 닫아도 이 금지는 프로세스 수명 동안 유지된다.
    let isSaveBlocked: Bool

    /// 실험실 · 자동 슬롯. 켜면 수동 슬롯을 씨앗으로 복사하고, 끄면 후보를 버린다.
    /// 꺼져 있는 동안 자동 슬롯은 **복원 소스 후보에 아예 들어가지 않는다** — 파일은 남는다.
    @Published var isLabEnabled: Bool {
        didSet {
            guard isLabEnabled != oldValue else { return }
            if isLabEnabled { seed() } else { candidates.removeAll() }
        }
    }

    init(store: ProfileStore, isLabEnabled: Bool) {
        self.store = store
        self.isLabEnabled = isLabEnabled
        let outcome = store.load()
        profiles = outcome.profiles
        trouble = outcome.trouble
        isSaveBlocked = outcome.trouble == .unreadable
    }

    // MARK: - 읽기

    /// 복원 소스 판정 — **더 최근에 저장된 슬롯이 이긴다.** 저장된 "활성 슬롯"은 없다.
    /// 확정은 케이블을 뽑았다는 이유로 최신이 되고, 사람이 방금 저장했으면 그쪽이 최신이다.
    /// 규칙 하나가 두 경우를 다 설명하므로 어긋날 상태가 존재하지 않는다.
    /// 동점이면 수동이 이긴다 — 후보 배열에서 앞에 두면 `max(by:)`가 그렇게 고른다.
    func source(for screenID: String) -> (slot: Slot, profile: Profile)? {
        var pool: [(Slot, Profile)] = []
        if let manual = profiles[Slot.manual.key(screenID)] { pool.append((.manual, manual)) }
        if isLabEnabled, let auto = profiles[Slot.auto.key(screenID)] { pool.append((.auto, auto)) }
        return pool
            .max { ($0.1.savedAt ?? .distantPast) < ($1.1.savedAt ?? .distantPast) }
            .map { (slot: $0.0, profile: $0.1) }
    }

    /// 저장된 모든 프로필 — 연결되지 않은 화면 포함 (F-05.6, US-012 AC-1).
    /// 자동 슬롯은 넣지 않는다 — 화면 하나가 두 줄로 보이면 어느 것을 지워야 할지 알 수 없다.
    var all: [Profile] {
        profiles.filter { !Slot.isAutoKey($0.key) }.values.sorted { $0.screenName < $1.screenName }
    }

    /// 이름순 첫 프로필 — 시작 직후의 빈 상태에서 마지막 화면 이름을 보여주는 데 쓴다.
    var firstByName: Profile? { all.first }

    /// 확정을 기다리는 변경이 있나 — 후보가 자동 슬롯과 다른 화면이 하나라도 있는가.
    /// 카드가 "지금 복원되는 값"과 "뽑을 때 저장될 값"을 구별해 보여주기 위한 것이다.
    var hasPendingCollect: Bool {
        candidates.contains { id, candidate in
            candidate.apps != profiles[Slot.auto.key(id)]?.apps
        }
    }

    /// 수집·관찰이 따라갈 대상 앱. 수집 열거와 이동 관찰이 **같은 집합**을 써야 한다 —
    /// 어긋나면 관찰은 되는데 수집이 안 되는 앱이 생긴다.
    ///
    /// **명부는 합집합이고, 좌표 바탕(`bases`)은 우선순위다.** 한 값으로 답하면
    /// 수동 저장으로 갓 등록한 앱이 자동 슬롯 명부에 영영 못 들어간다 — 수집이 그 앱을
    /// 열거하지 않으니 후보에 안 생기고, 확정이 더 새 시각으로 자동 슬롯을 덮어 그 앱을 잃는다.
    /// 합집합이어도 「수집은 새 앱을 등록하지 않는다」는 유지된다 — 어느 슬롯엔가 이미 있는 앱들이다.
    func targets(for screens: [ScreenInfo]) -> [String] {
        var out = Set<String>()
        for screen in screens {
            for profile in [candidates[screen.id],
                            profiles[Slot.auto.key(screen.id)],
                            profiles[Slot.manual.key(screen.id)]].compactMap({ $0 }) {
                out.formUnion(profile.apps.map(\.bundleID))
            }
        }
        return Array(out)
    }

    /// 복원 엔진에 넘길 화면당 프로필 하나 — 슬롯은 여기서 끝난다.
    func resolved(for screens: [ScreenInfo]) -> [String: Profile] {
        screens.reduce(into: [String: Profile]()) { out, screen in
            if let found = source(for: screen.id) { out[screen.id] = found.profile }
        }
    }

    // MARK: - 쓰기

    /// 수동 저장 (F-03). **수동 슬롯에만 쓴다** — 사람이 저장한 배치를 앱이 덮지 않는다.
    /// 방금 저장한 것이 가장 최근이 되므로 다음 복원이 이 배치를 쓴다 — 슬롯 전환 조작이 필요 없는 이유다.
    func capture(windows: [WindowInfo], on screens: [ScreenInfo]) {
        let now = Date()
        for screen in screens {
            let key = Slot.manual.key(screen.id)
            var merged = CaptureEngine.capture(windows: windows, on: screen, merging: profiles[key])
            merged.fingerprint = screen.fingerprint
            merged.savedAt = now
            profiles[key] = merged
            // 사람이 방금 이 배치를 선언했다 — 그 전에 모아둔 후보는 낡았다.
            // 버리지 않으면 종료·분리 시 확정이 낡은 배치를 더 새 시각으로 써서 방금 저장한 것을 이긴다.
            candidates.removeValue(forKey: screen.id)
        }
        persist()
    }

    /// 수집 — 지금 배치를 메모리 후보에 담는다. **파일에는 닿지 않는다.**
    /// 프로필에 이미 있는 앱만 따라간다. 새 앱 등록은 수동 저장의 몫이다.
    func collect(windows: [WindowInfo], on screens: [ScreenInfo]) {
        let bases = bases(for: screens)
        for screen in screens {
            guard let base = bases[screen.id] else { continue }
            var next = CaptureEngine.capture(windows: windows, on: screen, merging: base)
            next.fingerprint = screen.fingerprint
            candidates[screen.id] = next
        }
        lastCollectedAt = Date()
    }

    /// 확정 — 사라진 화면의 후보를 자동 슬롯에 쓴다.
    /// **이 시점에 창을 읽지 않는다.** macOS는 케이블이 빠지면 창을 내장 화면으로 먼저 옮기고
    /// 알림은 그 뒤에 온다 — 여기서 열거하면 이미 늦다. 수집과 확정을 나눈 이유가 이것이다.
    @discardableResult
    func confirm(_ screenIDs: Set<String>) -> Bool {
        guard isLabEnabled else { return false }
        let now = Date()
        var wrote = false
        for id in screenIDs {
            guard var candidate = candidates.removeValue(forKey: id) else { continue }
            candidate.savedAt = now
            profiles[Slot.auto.key(id)] = candidate
            wrote = true
        }
        guard wrote else { return false }
        persist()
        return true
    }

    /// 종료 직전 — 남은 후보를 전부 확정한다. 화면을 뽑기 전에 앱을 끄면 여기가 마지막 기회다.
    @discardableResult
    func confirmAll() -> Bool { confirm(Set(candidates.keys)) }

    /// 대상 앱 편집(체크 해제·삭제)은 **카드에 보이는 슬롯**을 고친다.
    /// 목록은 이긴 슬롯의 것인데 수정이 수동 슬롯으로 가면 보이는 것과 고쳐지는 것이 어긋난다
    /// (체크를 껐는데 그대로 복원되는 증상). 창 위치를 건드리지 않으므로 위 안전장치는 유지된다.
    func edit(screenID: String, _ change: (inout Profile) -> Void) {
        guard let slot = source(for: screenID)?.slot else { return }
        let key = slot.key(screenID)
        guard var profile = profiles[key] else { return }
        change(&profile)
        profiles[key] = profile
        persist()
    }

    /// 프로필 통째 삭제 (F-05.6). 슬롯 둘과 모으던 후보를 함께 버린다 —
    /// 한쪽만 남으면 목록에 안 보이면서 복원에는 쓰이는 유령이 된다.
    func remove(screenID: String) {
        profiles.removeValue(forKey: Slot.manual.key(screenID))
        profiles.removeValue(forKey: Slot.auto.key(screenID))
        candidates.removeValue(forKey: screenID)
        persist()
    }

    func dismissTrouble() { trouble = nil }

    // MARK: - 내부

    /// 화면별 수집 바탕 — 후보가 있으면 후보, 없으면 자동 슬롯, 그것도 없으면 수동 슬롯.
    private func bases(for screens: [ScreenInfo]) -> [String: Profile] {
        screens.reduce(into: [String: Profile]()) { out, screen in
            out[screen.id] = candidates[screen.id]
                ?? profiles[Slot.auto.key(screen.id)]
                ?? profiles[Slot.manual.key(screen.id)]
        }
    }

    /// 실험실을 켤 때 수동 슬롯을 자동 슬롯의 씨앗으로 복사한다.
    /// 없으면 자동 슬롯이 빈 채로 시작해서, 오늘 켜지 않은 앱이 첫 확정에서 통째로 빠진다 (US-002 AC-4).
    /// savedAt은 그대로 옮긴다 — 내용이 같으니 동점이 되고, 동점은 수동이 이긴다.
    private func seed() {
        var seeded = false
        for (key, manual) in profiles where !Slot.isAutoKey(key) {
            let autoKey = Slot.auto.key(key)
            guard profiles[autoKey] == nil else { continue } // 다시 켤 때 기존 자동 슬롯을 덮지 않는다
            profiles[autoKey] = manual
            seeded = true
        }
        if seeded { persist() }
    }

    private func persist() {
        guard !isSaveBlocked else { return } // 읽기 실패를 첫 실행처럼 덮어쓰면 손상보다 나쁜 손실이다
        store.save(profiles)
    }
}
