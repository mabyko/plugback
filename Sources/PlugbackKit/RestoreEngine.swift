import CoreGraphics
import Foundation

/// 복원 옵션 (F-02.2 예외 설정과 실험실). 옵션이 늘어도 plan 시그니처는 안 넓어진다.
struct RestoreOptions: Sendable, Equatable {
    /// 최소화된 창도 Dock에서 꺼내 복원 (기본 꺼짐 — 최소화는 사용자의 의도다).
    var restoreMinimized = false
    /// 실험실 · 종료된 앱 다시 열기 (부모). OFF이면 앱 실행·명시적 창 생성을 전부 막는다.
    var reopenClosedApps = false
    /// 실험실 · 실행 중인 앱 창 되살리기 — 실제 창이 0개일 때 기본 창 하나 열기 허용.
    var reviveWindowlessApps = false
    /// 실험실 · 부족한 창 추가로 열기 — 창이 하나 이상 있을 때 부족분 추가 열기 허용.
    var openMissingWindows = false
    /// 실험실 · 복원할 창 직접 지정 — 모호한 후보를 자동 배정하지 않고 사용자에게 맡긴다.
    var directAssignment = false

    init(restoreMinimized: Bool = false, reopenClosedApps: Bool = false,
         reviveWindowlessApps: Bool = false, openMissingWindows: Bool = false,
         directAssignment: Bool = false) {
        self.restoreMinimized = restoreMinimized
        self.reopenClosedApps = reopenClosedApps
        self.reviveWindowlessApps = reviveWindowlessApps
        self.openMissingWindows = openMissingWindows
        self.directAssignment = directAssignment
    }
}

/// 선택 복원 엔진 (F-02). 한 작업 환경 저장본과 한 번의 관찰을 받아 저장 창마다 할 일을 정한다.
/// 격리 자유 — 어느 액터에도 묶이지 않는 순수 정책 모듈. 실행(이동·실행·생성)은 RestoreSession의 일이다.
///
/// 정책 전부가 여기 산다: Space 조건 판정, 확인된 연결 우선·직접 지정·전체 이동 거리 배정(D3),
/// 닫힌 환경 판정과 다시 열기 허용(D9·3.5절), 건너뜀 사유, 지문 검증(F-01.4). 앱 전역 선점은 없다 —
/// 같은 실제 창을 두 자리에 배정하지 않는 것은 배정 단계가 보장한다.
enum RestoreEngine {
    /// 이동 후 검증 허용 오차. 실기기 측정 후 조정할 수 있는 초기값이다 (F-02.3).
    static let tolerance: CGFloat = 5

    struct Input {
        var source: WorkspaceSnapshot
        var enabled: (String) -> Bool
        var closedPlacementIDs: Set<UUID>
        var screens: [ScreenInfo]
        var windows: [WindowInfo]
        var unavailableBundleIDs: Set<String>
        var snapshot: SpaceSnapshot?
        /// reader가 있는데 snapshot이 없으면 Space 지정 기록을 평면 복원으로 강등하지 않는다 (O02).
        var spaceObservationEnabled: Bool
        var links: [UUID: WorkspaceLibrary.WindowLink]
        var userChoices: [UUID: CGWindowID]
        var runningBundleIDs: Set<String>
        var options: RestoreOptions
        /// 이 요청에서 이미 실행·생성을 요청한 앱 — 같은 요청을 반복 전송하지 않는다.
        var creationAttempted: Set<String>
    }

    enum Creation: Equatable, Sendable {
        case launch
        case revive
        case additional(missing: Int)
    }

    enum Decision: Equatable, Sendable {
        case move(windowID: Int, windowServerID: CGWindowID?, target: CGRect, minimized: Bool)
        case outcome(RestoreResult.Outcome)
    }

    struct Plan: Equatable, Sendable {
        var decisions: [UUID: Decision] = [:]
        var screenSkips: [String: ScreenSkipReason] = [:]
        /// 앱별 실행·생성 필요. 옵션과 닫힌 환경 판정을 이미 통과한 것만 담는다.
        var creations: [String: Creation] = [:]
    }

    static func isEligible(_ saved: ScreenRecord?, on screen: ScreenInfo) -> Bool {
        guard let saved = saved?.fingerprint, let live = screen.fingerprint else { return true }
        return saved == live
    }

    private enum SpaceCheck {
        case ready
        case blocked(RestoreResult.Outcome)
    }

    static func plan(_ input: Input) -> Plan {
        var plan = Plan()
        let screensByID = Dictionary(uniqueKeysWithValues: input.screens.map { ($0.id, $0) })
        for screen in input.screens where !isEligible(input.source.screen(screen.id), on: screen) {
            plan.screenSkips[screen.id] = .fingerprintMismatch
        }

        // 1. 자리별 선행 조건 — 화면·지문·닫힘·Space
        var ready: [UUID: (WindowPlacement, ScreenInfo)] = [:]
        for placement in input.source.placements where input.enabled(placement.bundleID) {
            guard let screen = screensByID[placement.screenID], plan.screenSkips[screen.id] == nil else { continue }
            if input.closedPlacementIDs.contains(placement.id) {
                plan.decisions[placement.id] = .outcome(.skipped(.closedInWorkspace))
                continue
            }
            switch spaceCheck(placement, on: screen, input: input) {
            case .ready: ready[placement.id] = (placement, screen)
            case .blocked(let outcome): plan.decisions[placement.id] = .outcome(outcome)
            }
        }

        // 2. 앱별 창 대응
        let readyByApp = Dictionary(grouping: ready.values, by: { $0.0.bundleID })
        for (bundleID, items) in readyByApp {
            assign(bundleID: bundleID, items: items.sorted { $0.0.id.uuidString < $1.0.id.uuidString },
                   input: input, plan: &plan)
        }
        return plan
    }

    private static func spaceCheck(_ placement: WindowPlacement, on screen: ScreenInfo, input: Input) -> SpaceCheck {
        guard let hint = placement.space else { return .ready }
        guard input.spaceObservationEnabled else { return .ready } // reader 없는 flat 실행 (테스트·프로브)
        guard let snapshot = input.snapshot else { return .blocked(.needsConfirmation(.spaceUnavailable)) }
        switch SpacePlacement.of(hint, on: screen.id, in: snapshot) {
        case .current: return .ready
        case .inactive: return .blocked(.awaitingVisit)
        case .stranded(let found): return .blocked(.awaitingSpaceMove(sourceScreenID: found.screenID))
        case .missing: return .blocked(.needsConfirmation(.spaceMissing))
        case .fullscreen, .unsupported, .unknown: return .blocked(.needsConfirmation(.spaceUnavailable))
        }
    }

    private enum Eligibility { case eligible, fullscreen, minimized, otherSpace, unknown }

    private static func eligibility(_ window: WindowInfo, input: Input) -> Eligibility {
        switch window.fullscreenState {
        case .fullscreen: return .fullscreen
        case .unknown where input.spaceObservationEnabled: return .unknown
        case .unknown, .windowed: break
        }
        if window.isMinimized && !input.options.restoreMinimized { return .minimized }
        guard input.spaceObservationEnabled, let snapshot = input.snapshot else { return .eligible }
        return spaceEligibility(of: window.windowServerID, in: snapshot)
    }

    /// 창이 어느 화면의 현재 일반 Space에 있으면 frame 이동으로 데려올 수 있다. 비활성 Space의 창은 옮겨도 그 Space에 남는다 (P05).
    private static func spaceEligibility(of windowServerID: CGWindowID?, in snapshot: SpaceSnapshot) -> Eligibility {
        guard let windowServerID, let memberships = snapshot.membershipsByWindowServerID[windowServerID],
              memberships.count == 1, let runtimeID = memberships.first else { return .unknown }
        for display in snapshot.displays {
            guard let space = display.spaces.first(where: { $0.runtimeID == runtimeID }) else { continue }
            switch space.kind {
            case .fullscreen: return .fullscreen
            case .unknown: return .unknown
            case .regular: return space.isCurrent ? .eligible : .otherSpace
            }
        }
        return .unknown
    }

    private static func assign(bundleID: String, items: [(WindowPlacement, ScreenInfo)], input: Input, plan: inout Plan) {
        let appWindows = input.windows.filter { $0.appBundleID == bundleID }
        let sourceIDs = Set(input.source.placements.filter { $0.bundleID == bundleID }.map(\.id))
        // 이 앱의 살아 있는 연결 — 그 창은 해당 자리 전용이다.
        var reservedByWindow: [CGWindowID: UUID] = [:]
        for id in sourceIDs {
            if let link = input.links[id], link.status == .live { reservedByWindow[link.windowServerID] = id }
        }
        for (id, wsid) in input.userChoices where sourceIDs.contains(id) { reservedByWindow[wsid] = id }

        var assigned: [UUID: WindowInfo] = [:]
        var remaining: [(WindowPlacement, ScreenInfo)] = []
        var eligible: [WindowInfo] = []
        var ineligible: [Eligibility] = []
        for window in appWindows {
            switch eligibility(window, input: input) {
            case .eligible: eligible.append(window)
            case let other: ineligible.append(other)
            }
        }
        // 확인된 연결·사용자 지정을 먼저 고정한다.
        for (placement, screen) in items {
            let preferred = input.userChoices[placement.id]
                ?? input.links[placement.id].flatMap { $0.status == .live ? $0.windowServerID : nil }
            if let preferred, let window = eligible.first(where: { $0.windowServerID == preferred }) {
                assigned[placement.id] = window
            } else {
                remaining.append((placement, screen))
            }
        }
        let assignedIDs = Set(assigned.values.compactMap(\.windowServerID))
        var candidates = eligible.filter { window in
            guard let wsid = window.windowServerID else { return true }
            if assignedIDs.contains(wsid) { return false }
            if let owner = reservedByWindow[wsid], assigned[owner] == nil, !remaining.contains(where: { $0.0.id == owner }) {
                return false // 다른 자리(대기 중)의 창은 데려오지 않는다
            }
            return true
        }
        candidates.sort { ($0.windowServerID ?? 0, $0.id) < ($1.windowServerID ?? 0, $1.id) }

        if !remaining.isEmpty, !candidates.isEmpty {
            let ambiguous = candidates.count >= 2 || remaining.count >= 2
            if input.options.directAssignment && ambiguous {
                let ids = candidates.compactMap(\.windowServerID)
                for (placement, _) in remaining {
                    plan.decisions[placement.id] = .outcome(.needsConfirmation(.ambiguousCandidates(ids)))
                }
                remaining.removeAll()
            } else {
                let slots = remaining.map { WindowMatching.Slot(id: $0.0.id, target: $0.0.unitRect.frame(in: $0.1.frame)) }
                let pool = candidates.enumerated().map { WindowMatching.Candidate(index: $0.offset, frame: $0.element.frame) }
                let matches = WindowMatching.assign(slots: slots, candidates: pool)
                for (placementID, index) in matches { assigned[placementID] = candidates[index] }
                remaining.removeAll { matches[$0.0.id] != nil }
            }
        }

        for (placement, screen) in items {
            guard let window = assigned[placement.id] else { continue }
            let target = placement.unitRect.frame(in: screen.frame)
            if !window.isMinimized && approximatelyEqual(window.frame, target) {
                plan.decisions[placement.id] = .outcome(.skipped(.alreadyInPlace))
            } else {
                plan.decisions[placement.id] = .move(windowID: window.id, windowServerID: window.windowServerID,
                                                     target: target, minimized: window.isMinimized)
            }
        }

        // 3. 창이 부족한 자리 — 닫힌 환경과 다시 열기 옵션 (D9·3.5절)
        guard !remaining.isEmpty else { return }
        let running = input.runningBundleIDs.contains(bundleID)
        let options = input.options
        let attempted = { (kind: String) in input.creationAttempted.contains("\(bundleID)|\(kind)") }

        // 옵션이 허용하는 생성 경로. 창이 있는데 전체화면·최소화·다른 Space라서 못 쓰는 경우는 생성 대상이 아니다.
        let base: RestoreResult.Outcome
        var creation: Creation?
        if !running {
            base = .skipped(.appNotRunning)
            if options.reopenClosedApps, !attempted("launch") { creation = .launch }
        } else if appWindows.isEmpty {
            base = .skipped(.noWindow)
            if options.reopenClosedApps, options.reviveWindowlessApps, !attempted("revive") { creation = .revive }
        } else if eligible.isEmpty {
            if ineligible.contains(.fullscreen) { base = .skipped(.fullscreen) }
            else if ineligible.contains(.minimized) { base = .skipped(.minimized) }
            else if ineligible.contains(.otherSpace) { base = .needsConfirmation(.windowOnAnotherSpace) }
            else { base = .needsConfirmation(.spaceUnavailable) }
        } else {
            base = .skipped(.noWindow) // 창은 있지만 자리보다 적다 (W10)
            if options.reopenClosedApps, options.openMissingWindows, !attempted("additional") {
                creation = .additional(missing: remaining.count)
            }
        }
        guard let creation else {
            for (placement, _) in remaining { plan.decisions[placement.id] = .outcome(base) }
            return
        }
        // 생성은 다른 환경·연결 해제 중 닫힌 것으로 확인한 자리에만 한다. 닫힌 시점·환경을 모르면 보류한다 (W21).
        var creatable = 0
        for (placement, _) in remaining {
            if case .lost(let key)? = input.links[placement.id]?.status, key != input.source.key {
                plan.decisions[placement.id] = .outcome(base)
                creatable += 1
            } else {
                plan.decisions[placement.id] = .outcome(.needsConfirmation(.closureUnknown))
            }
        }
        guard creatable > 0 else { return }
        if case .additional = creation { plan.creations[bundleID] = .additional(missing: creatable) }
        else { plan.creations[bundleID] = creation }
    }

    /// internal — CaptureEngine의 드리프트 방지가 같은 판정을 써야 한다.
    /// 복원이 "제자리"라고 본 차이를 저장이 "옮겨졌다"고 보면 두 엔진이 서로 어긋난다.
    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
