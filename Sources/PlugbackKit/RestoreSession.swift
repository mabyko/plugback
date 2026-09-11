import CoreGraphics
import Foundation

/// 복원 요청의 수명 (D8). 한 요청은 작업 환경 저장본을 시작할 때 고정하고, 저장 창마다 결과를 추적한다.
/// 방문 대기는 유효한 동안 이벤트를 기다리고, 확인 필요는 사용자의 「남은 창 복원」으로만 재개한다.
/// 이동·실행·생성 직전마다 요청 유효성·잠금·최신 옵션을 확인한다. 요청은 메모리에만 있다 — 재실행은 이어가지 않는다.
@MainActor
final class RestoreSession {
    enum Origin: Equatable, Sendable { case automatic, user }

    /// 어떤 항목을 다시 판정할지. 완료한 창은 어느 범위에서도 다시 옮기지 않는다.
    enum Scope { case all, waiting, user, unlock }

    struct Environment {
        var options: () -> RestoreOptions
        var lockState: () -> LockState
        var spaceObservationEnabled: Bool
        /// 자동 복원에서 요청 시작 뒤 사용자가 조작한 창인가 (D5 보호).
        var isTouched: (CGWindowID, Date) -> Bool
        /// Plugback이 직접 옮기기 직전 알림 — 자기 이동을 사용자 조작으로 오인하지 않기 위해서다.
        var willMove: (CGWindowID?) -> Void
        var diagnostics: (DiagnosticEvent, String?) -> Void

        init(options: @escaping () -> RestoreOptions, lockState: @escaping () -> LockState = { .unlocked },
             spaceObservationEnabled: Bool, isTouched: @escaping (CGWindowID, Date) -> Bool = { _, _ in false },
             willMove: @escaping (CGWindowID?) -> Void = { _ in },
             diagnostics: @escaping (DiagnosticEvent, String?) -> Void = { _, _ in }) {
            self.options = options; self.lockState = lockState
            self.spaceObservationEnabled = spaceObservationEnabled
            self.isTouched = isTouched; self.willMove = willMove; self.diagnostics = diagnostics
        }
    }

    struct Request {
        let id: Int
        let origin: Origin
        let key: WorkspaceKey
        let source: WorkspaceSnapshot
        let startedAt: Date
        var screens: [ScreenInfo]
        var outcomes: [UUID: RestoreResult.Outcome] = [:]
        var screenSkips: [String: ScreenSkipReason] = [:]
        var creationAttempted: Set<String> = []
        var userChoices: [UUID: CGWindowID] = [:]
        /// 실행 중 판정된 후보 창 — 확인 화면이 보여준다. 제목은 표시용이며 저장하지 않는다.
        var candidatesByPlacement: [UUID: [WindowInfo]] = [:]

        var openPlacementIDs: [UUID] {
            source.placements.map(\.id).filter { !RestoreSession.isTerminal(outcomes[$0]) }
        }
        // Request는 세션 안에서만 만들어지고 읽힌다 — nonisolated 판정 하나만 밖에서 부른다.
    }

    private let observation: DesktopObservation
    private let gateway: WindowGateway
    private let library: WorkspaceLibrary
    private(set) var request: Request?
    private var nextID = 0
    /// 취소·새 요청마다 오른다 — 비동기 대기 뒤에 이 값이 바뀌었으면 옛 실행은 아무것도 보내지 않는다.
    private var generation = 0
    /// 이번 실행이 옮겼거나 옮기려다 실패한 창의 실제 착지 위치 — 컨트롤러가 다음 수집에서 새 이력으로 승격하지 않는다 (R5).
    private(set) var landings: [CGWindowID: CGRect] = [:]

    init(observation: DesktopObservation, gateway: WindowGateway, library: WorkspaceLibrary) {
        self.observation = observation
        self.gateway = gateway
        self.library = library
    }

    // MARK: - 읽기

    nonisolated static func isTerminal(_ outcome: RestoreResult.Outcome?) -> Bool {
        switch outcome {
        case .moved, .skipped, .failed, .cancelled: return true
        case nil, .awaitingVisit, .awaitingSpaceMove, .needsConfirmation, .held: return false
        }
    }

    var hasOpenItems: Bool { !(request?.openPlacementIDs.isEmpty ?? true) }

    var isActive: Bool { request != nil }

    /// 현재 요청의 결과 — 화면 순서대로, 저장 창마다 한 항목. 아직 판정하지 않은 항목은 넣지 않는다.
    var results: [RestoreResult] {
        guard let request else { return [] }
        return request.screens.sorted { $0.id < $1.id }.compactMap { screen in
            if let skip = request.screenSkips[screen.id] {
                return RestoreResult(screenID: screen.id, screenSkipReason: skip)
            }
            let entries = request.source.placements(on: screen.id).compactMap { placement -> RestoreResult.Entry? in
                guard let outcome = request.outcomes[placement.id] else { return nil }
                return RestoreResult.Entry(placementID: placement.id, bundleID: placement.bundleID,
                                           displayName: placement.displayName, space: placement.space,
                                           outcome: outcome)
            }
            guard !entries.isEmpty else { return nil }
            return RestoreResult(screenID: screen.id, entries: entries)
        }
    }

    func outcome(of placementID: UUID) -> RestoreResult.Outcome? { request?.outcomes[placementID] }

    func candidates(for placementID: UUID) -> [WindowInfo] { request?.candidatesByPlacement[placementID] ?? [] }

    // MARK: - 명령

    /// 새 요청. 이전 요청의 남은 작업은 취소한다 (RQ05). 저장본이 없으면 nil.
    func start(origin: Origin, key: WorkspaceKey, screens: [ScreenInfo], environment: Environment) async -> [RestoreResult]? {
        guard let source = library.saved(for: key) else { return nil }
        cancel(reason: .newRequest)
        nextID += 1
        request = Request(id: nextID, origin: origin, key: key, source: source, startedAt: Date(), screens: screens)
        return await run(scope: .all, screens: screens, environment: environment)
    }

    /// 남은 항목 재판정. 재개할 항목이 없으면 nil — 창과 Space를 다시 읽지 않는다.
    func resume(scope: Scope, screens: [ScreenInfo], environment: Environment) async -> [RestoreResult]? {
        guard request != nil else { return nil }
        return await run(scope: scope, screens: screens, environment: environment)
    }

    /// 남은 작업 취소. 완료한 창·저장 기록은 그대로다. 자동 시작 요청만 고를 수 있다 (자동 복원 OFF).
    func cancel(reason: CancelReason, onlyAutomatic: Bool = false) {
        guard var current = request else { return }
        if onlyAutomatic, current.origin != .automatic { return }
        generation &+= 1
        for id in current.openPlacementIDs { current.outcomes[id] = .cancelled(reason) }
        request = current
    }

    /// 요청을 통째로 잊는다 — 작업 환경 삭제 등 결과까지 남길 이유가 없을 때.
    func drop() {
        generation &+= 1
        request = nil
    }

    /// 앱 제외·저장 기록 삭제 — 해당 미처리 항목만 끝내고 다른 유효한 항목은 유지한다 (7.1절).
    func cancelItems(bundleID: String) {
        guard var current = request else { return }
        for placement in current.source.placements where placement.bundleID == bundleID
            && !Self.isTerminal(current.outcomes[placement.id]) {
            current.outcomes[placement.id] = .cancelled(.targetRemoved)
        }
        request = current
    }

    func cancelItem(placementID: UUID) {
        guard var current = request, !Self.isTerminal(current.outcomes[placementID]) else { return }
        current.outcomes[placementID] = .cancelled(.targetRemoved)
        request = current
    }

    /// 요청에 남은 항목이 하나도 없으면 결과만 남긴다. 명시적 종료는 아니다.
    /// 직접 지정 (D3). 확정은 「남은 창 복원」에서 실제 창·자리 확인 뒤 이동으로 이어진다.
    func chooseWindow(placementID: UUID, windowServerID: CGWindowID?) {
        guard var current = request, current.source.placements.contains(where: { $0.id == placementID }) else { return }
        if let windowServerID {
            current.userChoices[placementID] = windowServerID
        } else {
            current.userChoices.removeValue(forKey: placementID)
        }
        request = current
    }

    /// 직접 지정 OFF 전환 — 미확정 선택만 취소한다. 확정한 연결·완료 배치는 유지한다.
    func discardUnconfirmedChoices() {
        guard var current = request else { return }
        current.userChoices.removeAll()
        request = current
    }

    /// 요청을 끝낸다 (Plugback 종료·작업 환경 변경 뒤 새 요청 없음). 결과 표시는 컨트롤러가 보관한다.
    func end(reason: CancelReason) {
        cancel(reason: reason)
    }

    // MARK: - 실행

    private enum Gate { case proceed, hold(HoldReason), invalid }

    private func gate(_ id: Int, _ environment: Environment) -> Gate {
        guard request?.id == id, generation == activeGeneration else { return .invalid }
        switch environment.lockState() {
        case .unlocked: return .proceed
        case .locked: return .hold(.screenLocked)
        case .undetermined: return .hold(.lockStateUndetermined)
        }
    }

    private func targets(in scope: Scope, of current: Request) -> [UUID] {
        current.source.placements.map(\.id).filter { id in
            let outcome = current.outcomes[id]
            if Self.isTerminal(outcome) { return false }
            switch scope {
            case .all, .user: return true
            case .waiting:
                switch outcome {
                case .awaitingVisit, .awaitingSpaceMove: return true
                default: return false
                }
            case .unlock:
                if case .held = outcome { return true }
                return false
            }
        }
    }

    private var activeGeneration = 0

    private func run(scope: Scope, screens: [ScreenInfo], environment: Environment) async -> [RestoreResult]? {
        guard var current = request else { return nil }
        let id = current.id
        activeGeneration = generation
        let isValid = { [weak self] in self?.request?.id == id && self?.generation == self?.activeGeneration }
        current.screens = screens
        request = current
        let targetIDs = targets(in: scope, of: current)
        guard !targetIDs.isEmpty else { return nil }
        let targetSet = Set(targetIDs)
        landings.removeAll()

        await observation.drain()
        guard isValid() else { return nil }

        for pass in 0..<3 {
            let sample = await observation.sample(includeSpaces: environment.spaceObservationEnabled)
            guard isValid(), var current = request else { return nil }
            let bundleIDs = Set(current.source.placements.filter { targetSet.contains($0.id) }.map(\.bundleID))
            var running = Set<String>()
            for bundleID in bundleIDs where await gateway.isRunning(bundleID: bundleID) { running.insert(bundleID) }
            guard isValid() else { return nil }

            let options = environment.options()
            let plan = RestoreEngine.plan(RestoreEngine.Input(
                source: current.source,
                enabled: { [library] in library.isEnabled($0, in: current.key) },
                closedPlacementIDs: library.record(for: current.key)?.closedPlacementIDs ?? [],
                screens: screens, windows: sample.windows,
                unavailableBundleIDs: sample.unavailableBundleIDs,
                snapshot: sample.snapshot, spaceObservationEnabled: environment.spaceObservationEnabled,
                links: library.links, userChoices: current.userChoices, runningBundleIDs: running,
                options: options, creationAttempted: current.creationAttempted
            ))
            current.screenSkips = plan.screenSkips
            for placement in current.source.placements where targetSet.contains(placement.id) {
                current.candidatesByPlacement[placement.id] = sample.windows.filter {
                    $0.appBundleID == placement.bundleID && $0.fullscreenState != .fullscreen
                }
            }
            request = current

            // 실행·생성은 옵션과 닫힌 환경 판정을 통과한 앱에만, 요청당 한 번씩. 요청 직전 최신 설정을 다시 본다 (RQ25).
            let creations = plan.creations.filter { bundleIDs.contains($0.key) }
            if !creations.isEmpty, pass < 2 {
                var performed = false
                for (bundleID, creation) in creations.sorted(by: { $0.key < $1.key }) {
                    switch gate(id, environment) {
                    case .invalid: return nil
                    case .hold(let reason):
                        hold(reason, ids: targetIDs.filter { current.outcomes[$0].map(Self.isTerminal) != true }, environment: environment)
                        return results
                    case .proceed: break
                    }
                    let latest = environment.options()
                    guard latest.reopenClosedApps else { continue }
                    let kind: String
                    let ok: Bool
                    switch creation {
                    case .launch:
                        kind = "launch"
                        current.creationAttempted.insert("\(bundleID)|\(kind)"); request = current
                        ok = await gateway.launch(bundleID: bundleID)
                    case .revive:
                        guard latest.reviveWindowlessApps else { continue }
                        kind = "revive"
                        current.creationAttempted.insert("\(bundleID)|\(kind)"); request = current
                        ok = await gateway.openWindow(bundleID: bundleID)
                    case .additional(let missing):
                        guard latest.openMissingWindows else { continue }
                        kind = "additional"
                        current.creationAttempted.insert("\(bundleID)|\(kind)"); request = current
                        var opened = true
                        for _ in 0..<missing where opened {
                            guard case .proceed = gate(id, environment) else { opened = false; break }
                            opened = await gateway.openAdditionalWindow(bundleID: bundleID)
                        }
                        ok = opened
                    }
                    performed = true
                    guard isValid(), let refreshed = request else { return nil }
                    current = refreshed
                    if !ok {
                        environment.diagnostics(DiagnosticEvent(
                            kind: "windowCreationFailed", reason: kind, bundleID: bundleID,
                            requestOrigin: current.origin == .automatic ? "automatic" : "user",
                            savedWindowCount: current.source.placements.filter { $0.bundleID == bundleID }.count,
                            observedWindowCount: sample.windows.filter { $0.appBundleID == bundleID }.count,
                            screenCount: screens.count,
                            spaceObservation: sample.spaceAvailability.map { "\($0)" } ?? "flat"
                        ), "\(id)|\(bundleID)|\(kind)")
                    }
                }
                if performed { continue }
            }

            // 결정 적용
            var creationFailedApps = Set<String>()
            for key in current.creationAttempted { creationFailedApps.insert(String(key.split(separator: "|")[0])) }
            var moves: [(UUID, Int, CGWindowID?, CGRect, Bool)] = []
            for placement in current.source.placements where targetSet.contains(placement.id) {
                guard plan.screenSkips[placement.screenID] == nil else { continue }
                guard library.isEnabled(placement.bundleID, in: current.key) else {
                    // 제외한 앱의 자리는 결과에 넣지 않는다. 진행 중 제외됐다면 그 항목만 끝낸다 (RQ12).
                    if current.outcomes[placement.id] != nil { current.outcomes[placement.id] = .cancelled(.targetRemoved) }
                    continue
                }
                switch plan.decisions[placement.id] {
                case .none:
                    continue
                case .outcome(let outcome):
                    var final = outcome
                    if creationFailedApps.contains(placement.bundleID) {
                        switch outcome {
                        case .skipped(.appNotRunning), .skipped(.noWindow):
                            final = .needsConfirmation(.windowCreationFailed)
                        default: break
                        }
                    }
                    if case .needsConfirmation(let reason) = final {
                        environment.diagnostics(DiagnosticEvent(
                            kind: "needsConfirmation", reason: "\(reason)", bundleID: placement.bundleID,
                            requestOrigin: current.origin == .automatic ? "automatic" : "user",
                            savedWindowCount: current.source.placements.filter { $0.bundleID == placement.bundleID }.count,
                            observedWindowCount: sample.windows.filter { $0.appBundleID == placement.bundleID }.count,
                            candidateCount: current.candidatesByPlacement[placement.id]?.count,
                            screenCount: screens.count,
                            spaceObservation: sample.spaceAvailability.map { "\($0)" } ?? "flat"
                        ), "\(id)|\(placement.id)|\(reason)")
                    }
                    current.outcomes[placement.id] = final
                case .move(let windowID, let wsid, let target, let minimized):
                    moves.append((placement.id, windowID, wsid, target, minimized))
                }
            }
            request = current

            for (index, move) in moves.enumerated() {
                let (placementID, windowID, wsid, target, minimized) = move
                switch gate(id, environment) {
                case .invalid: return nil
                case .hold(let reason):
                    hold(reason, ids: moves[index...].map(\.0), environment: environment)
                    return results
                case .proceed: break
                }
                guard var live = request else { return nil }
                if live.origin == .automatic, let wsid, environment.isTouched(wsid, live.startedAt) {
                    live.outcomes[placementID] = .skipped(.userInteraction)
                    request = live
                    continue
                }
                let outcome = await perform(windowID: windowID, windowServerID: wsid, target: target,
                                            minimized: minimized, options: environment.options(),
                                            environment: environment)
                guard isValid(), var after = request else { return nil }
                after.outcomes[placementID] = outcome
                if outcome == .moved, let chosen = after.userChoices[placementID],
                   let placement = after.source.placements.first(where: { $0.id == placementID }) {
                    library.confirmLink(placementID: placementID, bundleID: placement.bundleID, windowServerID: chosen)
                }
                request = after
            }
            break
        }
        return results
    }

    private func hold(_ reason: HoldReason, ids: [UUID], environment: Environment) {
        guard var current = request else { return }
        for id in ids where !Self.isTerminal(current.outcomes[id]) { current.outcomes[id] = .held(reason) }
        request = current
        environment.diagnostics(DiagnosticEvent(kind: "held", reason: "\(reason)",
                                                requestOrigin: current.origin == .automatic ? "automatic" : "user"),
                                "\(current.id)|held|\(reason)")
    }

    private func perform(windowID: Int, windowServerID: CGWindowID?, target: CGRect, minimized: Bool,
                         options: RestoreOptions, environment: Environment) async -> RestoreResult.Outcome {
        var currentFrame: CGRect?
        if minimized {
            guard options.restoreMinimized else { return .skipped(.minimized) }
            guard let fresh = await gateway.unminimize(windowID: windowID) else { return .skipped(.minimized) }
            currentFrame = fresh
        }
        if let currentFrame, RestoreEngine.approximatelyEqual(currentFrame, target) {
            return .skipped(.alreadyInPlace)
        }
        // 이동 → 검증 → 1회 재시도 (F-02.3). 재시도도 실패하면 실패로 기록하고 멈추지 않는다.
        for _ in 0..<2 {
            environment.willMove(windowServerID)
            let actual = await gateway.move(windowID: windowID, to: target)
            if let windowServerID, let actual { landings[windowServerID] = actual }
            if let actual, RestoreEngine.approximatelyEqual(actual, target) {
                return .moved
            }
        }
        return .failed
    }
}
