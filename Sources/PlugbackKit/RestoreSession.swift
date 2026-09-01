import Foundation

/// 명시적으로 시작한 한 복원에서, 다른 화면에 남은 일반 Space만 끝까지 추적한다.
/// 처음부터 목표 화면에 있던 비활성 Space는 다루지 않는다.
@MainActor
final class RestoreSession {
    struct RecoveryID: Hashable, Sendable {
        let targetScreenID: String
        let opaqueName: String
    }

    struct Recovery: Equatable, Sendable {
        enum Step: Equatable, Sendable {
            case move(sourceScreenID: String)
            case visit
            case unavailable
        }

        let id: RecoveryID
        let spaceNumber: Int
        var bundleIDs: Set<String>
        var step: Step
    }

    private struct Pending {
        let hint: SpaceHint
        var recovery: Recovery
    }

    private let observation: DesktopObservation
    private let gateway: WindowGateway
    private var pending: [RecoveryID: Pending] = [:]
    private var generation = 0

    init(observation: DesktopObservation, gateway: WindowGateway) {
        self.observation = observation
        self.gateway = gateway
    }

    var recoveries: [Recovery] {
        pending.values.map(\.recovery).sorted {
            ($0.id.targetScreenID, $0.spaceNumber, $0.id.opaqueName)
                < ($1.id.targetScreenID, $1.spaceNumber, $1.id.opaqueName)
        }
    }

    var hasPendingRecovery: Bool { !pending.isEmpty }

    /// 새 복원 요청. 이전 안내는 폐기하고, 이번 관찰에서 실제로 잘못된 화면에 있는
    /// 일반 Space만 회복 대상으로 잡는다.
    func restore(
        resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        options: RestoreOptions
    ) async -> [RestoreResult] {
        generation &+= 1
        let startedGeneration = generation
        pending.removeAll()
        await observation.drain()
        guard startedGeneration == generation else {
            return []
        }
        await reopenLegacyWindowless(in: resolved, screens: screens, options: options)
        guard startedGeneration == generation else {
            return []
        }
        let sample = await observation.sample()
        guard startedGeneration == generation else {
            return []
        }
        let snapshot: SpaceSnapshot?
        switch sample.spaceAvailability {
        case .some(.available(let available)):
            snapshot = available
        case nil, .some(.unavailable):
            // unavailable에서도 overlay 없는 legacy 앱은 기존 flat 경로를 유지한다.
            // Space binding이 있는 앱은 RestoreEngine이 snapshot 부재로 fail-close한다.
            snapshot = nil
        }
        addRecoveries(from: resolved, screens: screens, snapshot: snapshot)
        let results = await RestoreEngine.restore(
            resolved: resolved,
            screens: screens,
            windows: sample.windows,
            snapshot: snapshot,
            using: gateway,
            options: options
        )
        guard startedGeneration == generation else {
            return results
        }
        return results
    }

    /// Mission Control이 닫히거나, 안내한 Space를 사용자가 방문했을 때만 호출한다.
    /// 진행 중인 안내가 없으면 창과 Space를 다시 읽지 않는다.
    func recheck(
        resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        options: RestoreOptions
    ) async -> [RestoreResult]? {
        guard !pending.isEmpty else { return nil }
        let startedGeneration = generation
        await observation.drain()
        guard startedGeneration == generation, !pending.isEmpty else { return nil }
        let sample = await observation.sample()
        guard startedGeneration == generation, !pending.isEmpty else { return nil }
        guard case .some(.available(let snapshot)) = sample.spaceAvailability else {
            for id in pending.keys { pending[id]?.recovery.step = .unavailable }
            return []
        }

        var currentIDs: [RecoveryID] = []
        var onlyBundles: [String: Set<String>] = [:]
        for id in Array(pending.keys) {
            guard var item = pending[id] else { continue }
            switch SpacePlacement.of(item.hint, on: id.targetScreenID, in: snapshot) {
            case .stranded(let found):
                item.recovery.step = .move(sourceScreenID: found.screenID)
            case .inactive:
                if item.recovery.bundleIDs.isEmpty {
                    pending.removeValue(forKey: id)
                    continue
                }
                item.recovery.step = .visit
            case .current:
                if item.recovery.bundleIDs.isEmpty {
                    pending.removeValue(forKey: id)
                    continue
                }
                item.recovery.step = .visit
                currentIDs.append(id)
                onlyBundles[id.targetScreenID, default: []]
                    .formUnion(item.recovery.bundleIDs)
            case .fullscreen, .unsupported, .missing, .unknown:
                item.recovery.step = .unavailable
            }
            pending[id] = item
        }

        guard !currentIDs.isEmpty else {
            return []
        }
        let results = await RestoreEngine.restore(
            resolved: resolved,
            screens: screens,
            windows: sample.windows,
            snapshot: snapshot,
            onlyBundles: onlyBundles,
            using: gateway,
            options: options
        )
        let attempted = Set(results.flatMap(\.entries).map(\.bundleID))
        for id in currentIDs {
            guard var item = pending[id] else { continue }
            item.recovery.bundleIDs.subtract(attempted)
            if item.recovery.bundleIDs.isEmpty {
                pending.removeValue(forKey: id)
            } else {
                item.recovery.step = .unavailable
                pending[id] = item
            }
        }
        return results
    }

    func cancel() {
        generation &+= 1
        pending.removeAll()
    }

    private func addRecoveries(
        from resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        snapshot: SpaceSnapshot?
    ) {
        guard let snapshot else { return }
        let claimed = RestoreEngine.claimedApps(in: resolved, screens: screens)
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id],
                  RestoreEngine.isEligible(pair, on: screen),
                  let overlay = pair.overlay else { continue }

            var hintsByName: [String: SpaceHint] = [:]
            for hint in overlay.regularSpaces {
                hintsByName[hint.opaqueName] = hintsByName[hint.opaqueName] ?? hint
            }
            for binding in overlay.byBundle.values {
                if case .regular(let hint) = binding {
                    hintsByName[hint.opaqueName] = hintsByName[hint.opaqueName] ?? hint
                }
            }
            let ordered = hintsByName.values.sorted {
                ($0.localOrderHint, $0.opaqueName) < ($1.localOrderHint, $1.opaqueName)
            }
            for (index, hint) in ordered.enumerated() {
                guard case .stranded(let found) = SpacePlacement.of(
                    hint, on: screen.id, in: snapshot
                ) else { continue }
                let bundleIDs = Set(claimed.compactMap { item -> String? in
                    guard item.screenID == screen.id,
                          case .regular(let appHint) = item.pair.overlay?
                            .byBundle[item.app.bundleID],
                          appHint.opaqueName == hint.opaqueName else { return nil }
                    return item.app.bundleID
                })
                guard !bundleIDs.isEmpty else { continue }
                let id = RecoveryID(
                    targetScreenID: screen.id,
                    opaqueName: hint.opaqueName
                )
                pending[id] = Pending(
                    hint: hint,
                    recovery: Recovery(
                        id: id,
                        spaceNumber: index + 1,
                        bundleIDs: bundleIDs,
                        step: .move(sourceScreenID: found.screenID)
                    )
                )
            }
        }
    }

    private func reopenLegacyWindowless(
        in resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        options: RestoreOptions
    ) async {
        guard options.reopenWindowless else { return }
        var windowless: [String] = []
        for item in RestoreEngine.claimedApps(in: resolved, screens: screens) {
            guard item.pair.overlay?.byBundle[item.app.bundleID] == nil,
                  await gateway.isRunning(bundleID: item.app.bundleID),
                  await observation.sample(
                    of: [item.app.bundleID], includeSpaces: false
                  ).windows.isEmpty else { continue }
            windowless.append(item.app.bundleID)
        }
        await withTaskGroup(of: Void.self) { group in
            for bundleID in windowless {
                group.addTask { _ = await self.gateway.openWindow(bundleID: bundleID) }
            }
        }
    }
}
