import Combine
import Foundation

struct SpaceHint: Equatable, Sendable {
    let opaqueName: String
    let localOrderHint: Int
}

enum SpaceBlockReason: Equatable, Sendable {
    case windowUnjoined
    case membershipUnavailable
    case spaceMissing
    case stranded
    case inactive
    case unsupportedSpace
    case nameUnavailable
    case fullscreen
    case fullscreenUnknown
    case multipleSpaces
}

enum SpaceBinding: Equatable, Sendable {
    case regular(SpaceHint)
    /// 이 화면에서 single native fullscreen으로 다시 만들 의도.
    /// 화면은 슬롯이 이미 정하므로 별도 식별자를 중복 저장하지 않는다.
    case fullscreen
    case unresolved(SpaceBlockReason)
}

struct SlotSpaceOverlay: Equatable, Sendable {
    var byBundle: [String: SpaceBinding] = [:]
    /// 이 화면에 속해야 하는 식별 가능한 일반 Space 전체. 앱이 하나도 없어도 남는다.
    var regularSpaces: [SpaceHint] = []

    var isEmpty: Bool { byBundle.isEmpty && regularSpaces.isEmpty }

    mutating func keepOnly(_ bundleIDs: Set<String>) {
        byBundle = byBundle.filter { bundleIDs.contains($0.key) }
    }
}

struct ResolvedProfile: Equatable, Sendable {
    var profile: Profile
    var overlay: SlotSpaceOverlay?
}

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

    /// 프로필 슬롯과 같은 키를 쓰는 메모리 전용 Space overlay. 앱 재시작을 넘지 않는다.
    private var overlays: [String: SlotSpaceOverlay] = [:]
    private var candidateOverlays: [String: SlotSpaceOverlay] = [:]

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
            if isLabEnabled {
                seed()
            } else {
                candidates.removeAll()
                candidateOverlays.removeAll()
            }
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
                || candidateOverlays[id] != overlays[Slot.auto.key(id)]
        }
    }

    /// 창 이동 observer가 따라갈 기존 대상 앱. 수집 자체는 현재 표준 창 전체를 읽으므로
    /// 처음 본 앱은 Space 방문·앱 전환 때 등록되고, 그다음 이동부터 이 명부로 관찰된다.
    /// 명부는 candidate/auto/manual 합집합이다 — 소스가 바뀌어도 관찰 대상을 잃지 않는다.
    func targets(for screens: [ScreenInfo]) -> [String] {
        var out = Set<String>()
        for screen in screens {
            for profile in [candidates[screen.id],
                            profiles[Slot.auto.key(screen.id)],
                            profiles[Slot.manual.key(screen.id)]].compactMap({ $0 }) {
                out.formUnion(profile.apps.filter(\.isEnabled).map(\.bundleID))
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

    /// Space-aware 경로용 pair. profile과 overlay는 반드시 같은 슬롯에서 나온다.
    func resolvedWithSpaces(for screens: [ScreenInfo]) -> [String: ResolvedProfile] {
        screens.reduce(into: [String: ResolvedProfile]()) { out, screen in
            out[screen.id] = resolvedWithSpaces(for: screen.id)
        }
    }

    /// 카드처럼 ScreenInfo가 없어도 저장 화면 하나의 같은-slot pair를 읽는 경로.
    func resolvedWithSpaces(for screenID: String) -> ResolvedProfile? {
        guard let found = source(for: screenID) else { return nil }
        return ResolvedProfile(
            profile: found.profile,
            overlay: overlays[found.slot.key(screenID)]
        )
    }

    // MARK: - 쓰기

    /// 수동 저장 (F-03). **수동 슬롯에만 쓴다** — 사람이 저장한 배치를 앱이 덮지 않는다.
    /// 방금 저장한 것이 가장 최근이 되므로 다음 복원이 이 배치를 쓴다 — 슬롯 전환 조작이 필요 없는 이유다.
    func capture(
        windows: [WindowInfo], on screens: [ScreenInfo], snapshot: SpaceSnapshot? = nil
    ) {
        let now = Date()
        for screen in screens {
            let key = Slot.manual.key(screen.id)
            // 체크 해제한 앱의 창은 넘기지 않는다 — 「저장하지 않고 감지하지 않는다」가 해제의 뜻이다.
            // 프로필 항목과 좌표는 그대로 남는다(병합) — 다시 켜면 그 자리로 돌아온다 (US-006 AC-2).
            let selected = kept(windows, for: key)
            var merged: Profile
            if let snapshot {
                let captured = CaptureEngine.capture(
                    windows: selected,
                    on: screen,
                    merging: profiles[key].map {
                        ResolvedProfile(profile: $0, overlay: overlays[key])
                    },
                    snapshot: snapshot
                )
                merged = captured.profile
                setOverlay(captured.overlay, for: key)
            } else {
                merged = CaptureEngine.capture(windows: selected, on: screen,
                                               merging: profiles[key])
                overlays.removeValue(forKey: key)
            }
            merged.fingerprint = screen.fingerprint
            merged.savedAt = now
            profiles[key] = merged
            // 사람이 방금 이 배치를 선언했다 — 그 전에 모아둔 후보는 낡았다.
            // 버리지 않으면 종료·분리 시 확정이 낡은 배치를 더 새 시각으로 써서 방금 저장한 것을 이긴다.
            candidates.removeValue(forKey: screen.id)
            candidateOverlays.removeValue(forKey: screen.id)
        }
        persist()
    }

    /// 대상 앱 하나를 명부에 올린다 (체크를 켰는데 프로필에 없던 앱). **저장이 아니다** —
    /// 배치를 선언하는 게 아니라 이름을 올리는 것이라, 저장의 두 부작용을 갖지 않는다:
    /// savedAt을 올리지 않고(복원 소스를 뒤집지 않는다), 모으던 후보도 버리지 않는다.
    ///
    /// 두 슬롯과 후보 모두에 넣는다 — **명부는 슬롯마다 다를 이유가 없다.**
    /// 한쪽에만 넣으면 그 슬롯이 이길 때만 보이고, 이기는 슬롯이 바뀌는 순간 사라진다.
    func addTarget(
        windows: [WindowInfo], on screens: [ScreenInfo], snapshot: SpaceSnapshot? = nil
    ) {
        for screen in screens {
            let manualKey = Slot.manual.key(screen.id)
            var manual = capturePair(
                windows: windows, on: screen, key: manualKey, snapshot: snapshot
            )
            manual.fingerprint = screen.fingerprint
            // 이 화면의 첫 앱이면 프로필이 방금 생긴 것이라 시각이 없다 — 그때만 채운다.
            if manual.savedAt == nil { manual.savedAt = Date() }
            profiles[manualKey] = manual

            let autoKey = Slot.auto.key(screen.id)
            if let auto = profiles[autoKey] {
                profiles[autoKey] = capturePair(
                    windows: windows, on: screen, key: autoKey, existing: auto,
                    snapshot: snapshot
                )
            }
            if let candidate = candidates[screen.id] {
                let captured = captureCandidatePair(
                    windows: windows, on: screen, existing: candidate, snapshot: snapshot
                )
                candidates[screen.id] = captured
            }
        }
        persist()
    }

    /// 수집 — 지금 배치를 메모리 후보에 담는다. **파일에는 닿지 않는다.**
    /// 자동 슬롯이 켜진 동안 방문한 외장 Space의 새 앱도 candidate에 등록한다.
    /// 체크 해제된 앱과 복원 pending 앱은 갱신하지 않는다.
    func collect(
        windows: [WindowInfo], on screens: [ScreenInfo], snapshot: SpaceSnapshot? = nil,
        excluding excludedBundleIDs: Set<String> = []
    ) {
        let bases = spaceBases(for: screens)
        var collected = false
        for screen in screens {
            let base = bases[screen.id] ?? ResolvedProfile(
                profile: Profile(screenID: screen.id, screenName: screen.name),
                overlay: SlotSpaceOverlay()
            )
            let disabled = Set(base.profile.apps.filter { !$0.isEnabled }.map(\.bundleID))
            let updating = Set(windows.map(\.appBundleID))
                .subtracting(disabled)
                .subtracting(excludedBundleIDs)
            let presentElsewhere = Set(windows.lazy
                .filter { !$0.isMinimized }
                .map(\.appBundleID))
                .subtracting(Set(windows.lazy
                    .filter { screen.contains($0) }
                    .map(\.appBundleID)))
                .subtracting(disabled)
                .subtracting(excludedBundleIDs)
            let selected = windows.filter { updating.contains($0.appBundleID) }
            var next: Profile
            if let snapshot {
                let captured = CaptureEngine.capture(
                    windows: windows, on: screen, merging: base, snapshot: snapshot,
                    updating: updating
                )
                next = captured.profile
                setCandidateOverlay(captured.overlay, for: screen.id)
            } else {
                next = CaptureEngine.capture(windows: selected, on: screen,
                                             merging: base.profile)
                candidateOverlays.removeValue(forKey: screen.id)
            }
            next.apps.removeAll { presentElsewhere.contains($0.bundleID) }
            var overlay = candidateOverlays[screen.id] ?? SlotSpaceOverlay()
            overlay.keepOnly(Set(next.apps.map(\.bundleID)))

            // 비활성 native fullscreen은 AX 표준 창 열거에 없으므로 WindowServer가 확실히
            // 식별한 후보로 보충한다. 같은 앱의 fullscreen이 둘이면 앱 단위 프로필로는 모호하다.
            let fullscreen = snapshot?.fullscreenCandidates.filter {
                $0.screenID == screen.id
                    && !disabled.contains($0.bundleID)
                    && !excludedBundleIDs.contains($0.bundleID)
            } ?? []
            let counts = Dictionary(grouping: fullscreen, by: \.bundleID)
            for candidate in fullscreen where counts[candidate.bundleID]?.count == 1 {
                if let index = next.apps.firstIndex(where: { $0.bundleID == candidate.bundleID }) {
                    next.apps[index].displayName = candidate.displayName
                } else {
                    next.apps.append(TargetApp(
                        bundleID: candidate.bundleID, displayName: candidate.displayName,
                        unitRect: UnitRect(screen.frame, in: screen.frame)
                    ))
                }
                overlay.byBundle[candidate.bundleID] = .fullscreen
            }
            setCandidateOverlay(overlay.isEmpty ? nil : overlay, for: screen.id)
            next.fingerprint = screen.fingerprint
            candidates[screen.id] = next
            collected = true
        }
        if collected { lastCollectedAt = Date() }
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
            let autoKey = Slot.auto.key(id)
            profiles[autoKey] = candidate
            setOverlay(candidateOverlays.removeValue(forKey: id), for: autoKey)
            wrote = true
        }
        guard wrote else { return false }
        persist()
        return true
    }

    /// 종료 직전 — 남은 후보를 전부 확정한다. 화면을 뽑기 전에 앱을 끄면 여기가 마지막 기회다.
    @discardableResult
    func confirmAll() -> Bool { confirm(Set(candidates.keys)) }

    /// 대상 앱 편집 — 체크 켜고 끄기, 프로필에서 삭제.
    ///
    /// **두 슬롯과 후보에 모두 적용한다.** 체크 상태와 명부는 슬롯마다 다를 이유가 없다 —
    /// 한쪽만 고치면 이기는 슬롯이 바뀌는 순간 되살아난다. (체크를 껐는데 자동 슬롯엔
    /// 켜진 채 남아 수집이 계속 따라가던 버그가 이것이었다.)
    ///
    /// 창 위치는 건드리지 않으므로 「자동은 자동 슬롯만, 사람은 수동 슬롯만 쓴다」는 유지된다.
    func edit(screenID: String, _ change: (inout Profile) -> Void) {
        for key in [Slot.manual.key(screenID), Slot.auto.key(screenID)] {
            guard var profile = profiles[key] else { continue }
            change(&profile)
            profiles[key] = profile
            pruneOverlay(at: key, to: profile)
        }
        if var candidate = candidates[screenID] {
            change(&candidate)
            candidates[screenID] = candidate
            if var overlay = candidateOverlays[screenID] {
                overlay.keepOnly(Set(candidate.apps.map(\.bundleID)))
                candidateOverlays[screenID] = overlay
            }
        }
        persist()
    }

    /// 프로필 통째 삭제 (F-05.6). 슬롯 둘과 모으던 후보를 함께 버린다 —
    /// 한쪽만 남으면 목록에 안 보이면서 복원에는 쓰이는 유령이 된다.
    func remove(screenID: String) {
        profiles.removeValue(forKey: Slot.manual.key(screenID))
        profiles.removeValue(forKey: Slot.auto.key(screenID))
        candidates.removeValue(forKey: screenID)
        overlays.removeValue(forKey: Slot.manual.key(screenID))
        overlays.removeValue(forKey: Slot.auto.key(screenID))
        candidateOverlays.removeValue(forKey: screenID)
        persist()
    }

    func dismissTrouble() { trouble = nil }

    // MARK: - 내부

    /// 그 슬롯에서 체크 해제된 앱의 창을 걸러낸다.
    private func kept(_ windows: [WindowInfo], for key: String) -> [WindowInfo] {
        let disabled = Set((profiles[key]?.apps.filter { !$0.isEnabled } ?? []).map(\.bundleID))
        guard !disabled.isEmpty else { return windows }
        return windows.filter { !disabled.contains($0.appBundleID) }
    }

    /// 화면별 수집 바탕 — profile과 overlay가 같은 candidate/auto/manual pair에서 나온다.
    private func spaceBases(for screens: [ScreenInfo]) -> [String: ResolvedProfile] {
        screens.reduce(into: [String: ResolvedProfile]()) { out, screen in
            if let candidate = candidates[screen.id] {
                out[screen.id] = ResolvedProfile(
                    profile: candidate, overlay: candidateOverlays[screen.id]
                )
            } else if let source = source(for: screen.id) {
                out[screen.id] = ResolvedProfile(
                    profile: source.profile, overlay: overlays[source.slot.key(screen.id)]
                )
            }
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
            setOverlay(overlays[key], for: autoKey)
            seeded = true
        }
        if seeded { persist() }
    }

    private func persist() {
        guard !isSaveBlocked else { return } // 읽기 실패를 첫 실행처럼 덮어쓰면 손상보다 나쁜 손실이다
        store.save(profiles)
    }

    private func capturePair(
        windows: [WindowInfo], on screen: ScreenInfo, key: String,
        existing: Profile? = nil, snapshot: SpaceSnapshot?
    ) -> Profile {
        let profile = existing ?? profiles[key]
        guard let snapshot else {
            removeBindings(for: windows, at: key)
            return CaptureEngine.capture(windows: windows, on: screen, merging: profile)
        }
        let captured = CaptureEngine.capture(
            windows: windows,
            on: screen,
            merging: profile.map { ResolvedProfile(profile: $0, overlay: overlays[key]) },
            snapshot: snapshot
        )
        setOverlay(captured.overlay, for: key)
        return captured.profile
    }

    private func captureCandidatePair(
        windows: [WindowInfo], on screen: ScreenInfo, existing: Profile,
        snapshot: SpaceSnapshot?
    ) -> Profile {
        guard let snapshot else {
            if var overlay = candidateOverlays[screen.id] {
                for bundleID in Set(windows.map(\.appBundleID)) {
                    overlay.byBundle.removeValue(forKey: bundleID)
                }
                setCandidateOverlay(overlay, for: screen.id)
            }
            return CaptureEngine.capture(windows: windows, on: screen, merging: existing)
        }
        let captured = CaptureEngine.capture(
            windows: windows,
            on: screen,
            merging: ResolvedProfile(profile: existing, overlay: candidateOverlays[screen.id]),
            snapshot: snapshot
        )
        setCandidateOverlay(captured.overlay, for: screen.id)
        return captured.profile
    }

    private func setOverlay(_ overlay: SlotSpaceOverlay?, for key: String) {
        if let overlay, !overlay.isEmpty {
            overlays[key] = overlay
        } else {
            overlays.removeValue(forKey: key)
        }
    }

    private func setCandidateOverlay(_ overlay: SlotSpaceOverlay?, for screenID: String) {
        if let overlay, !overlay.isEmpty {
            candidateOverlays[screenID] = overlay
        } else {
            candidateOverlays.removeValue(forKey: screenID)
        }
    }

    private func removeBindings(for windows: [WindowInfo], at key: String) {
        guard var overlay = overlays[key] else { return }
        for bundleID in Set(windows.map(\.appBundleID)) {
            overlay.byBundle.removeValue(forKey: bundleID)
        }
        setOverlay(overlay, for: key)
    }

    private func pruneOverlay(at key: String, to profile: Profile) {
        guard var overlay = overlays[key] else { return }
        overlay.keepOnly(Set(profile.apps.map(\.bundleID)))
        setOverlay(overlay, for: key)
    }
}
