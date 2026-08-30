import Foundation

struct SpaceRestoreScope: Equatable, Sendable {
    let regular: Bool
    let fullscreen: Bool

    static let none = Self(regular: false, fullscreen: false)
    static let all = Self(regular: true, fullscreen: true)

    var isEnabled: Bool { regular || fullscreen }

    func restores(_ binding: SpaceBinding) -> Bool {
        switch binding {
        case .regular:
            return regular
        case .fullscreen, .unresolved(.fullscreen), .unresolved(.fullscreenUnknown):
            return fullscreen
        case .unresolved:
            return isEnabled
        }
    }
}

/// 외장 화면이 연결된 동안 여러 복원 회차와 방문 대기를 이어가는 실행 단위.
/// 슬롯 선택과 UI 상태는 바깥에 두고, 선택이 끝난 값만 받아 복원 순서를 완결한다.
@MainActor
final class RestoreSession {
    private let scope: SpaceRestoreScope

    private let observation: DesktopObservation
    private let gateway: WindowGateway
    private let spaceRelocator: SpaceRelocating?
    private var awaitingVisitByScreen: [String: Set<String>] = [:]

    init(
        scope: SpaceRestoreScope,
        observation: DesktopObservation,
        gateway: WindowGateway,
        spaceRelocator: SpaceRelocating?
    ) {
        self.scope = scope
        self.observation = observation
        self.gateway = gateway
        self.spaceRelocator = spaceRelocator
    }

    func restoreAll(
        resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        options: RestoreOptions
    ) async -> [RestoreResult] {
        await observation.drain()
        await relocateBoundRegularSpaces(resolved: resolved, screens: screens)
        awaitingVisitByScreen.removeAll()
        if scope.isEnabled {
            addAwaitingVisits(from: resolved, screens: screens)
        }
        return await restoreSpacePass(
            resolved: resolved, screens: screens, onlyBundles: nil, options: options
        )
    }

    func restoreVisited(
        resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        options: RestoreOptions
    ) async -> [RestoreResult] {
        guard scope.isEnabled else { return [] }
        await observation.drain()
        let awaitingVisit = currentAwaitingVisits(in: resolved)
        guard !awaitingVisit.isEmpty else { return [] }
        await relocateBoundRegularSpaces(resolved: resolved, screens: screens)
        return await restoreSpacePass(
            resolved: resolved, screens: screens,
            onlyBundles: awaitingVisit, options: options
        )
    }

    func invalidate(screens screenIDs: Set<String>) {
        for screenID in screenIDs { awaitingVisitByScreen.removeValue(forKey: screenID) }
    }

    func hasAwaitingVisit(in resolved: [String: ResolvedProfile]) -> Bool {
        !currentAwaitingVisits(in: resolved).isEmpty
    }

    func awaitingBundleIDs(in resolved: [String: ResolvedProfile]) -> Set<String> {
        Set(currentAwaitingVisits(in: resolved).values.flatMap { $0 })
    }

    private func relocateBoundRegularSpaces(
        resolved: [String: ResolvedProfile], screens: [ScreenInfo]
    ) async {
        guard scope.regular, let spaceRelocator else { return }
        let moveLimit = SpaceRelocationPlanner.desiredCount(
            resolved: resolved, screens: screens
        )
        for _ in 0..<moveLimit {
            let windows = await observation.windows(of: nil)
            guard let before = await observation.stableSnapshot(for: windows) else { return }
            switch SpaceRelocationPlanner.next(
                resolved: resolved, screens: screens, snapshot: before
            ) {
            case .complete, .blocked:
                return
            case .move(let planned):
                guard await spaceRelocator.relocate(planned.request),
                      let after = await observation.stableSnapshot(for: windows),
                      SpaceRelocationPlanner.verifies(
                        planned, before: before, after: after
                      ) else { return }
            }
        }
    }

    private func restoreSpacePass(
        resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        onlyBundles: [String: Set<String>]?,
        options: RestoreOptions
    ) async -> [RestoreResult] {
        await reopenLegacyWindowless(
            in: resolved, screens: screens, only: onlyBundles, options: options
        )
        let windows = await observation.windows(of: nil)
        let snapshot = scope.isEnabled
            ? await observation.stableSnapshot(for: windows)
            : nil
        let pass = await RestoreEngine.restore(
            resolved: resolved,
            screens: screens,
            windows: windows,
            snapshot: snapshot,
            onlyBundles: onlyBundles,
            scope: scope,
            using: gateway,
            options: options
        )
        removeCompleted(pass.completedByScreen)
        return pass.results
    }

    private func addAwaitingVisits(
        from resolved: [String: ResolvedProfile], screens: [ScreenInfo]
    ) {
        for item in claimedApps(in: resolved, screens: screens)
        where item.pair.overlay?.byBundle[item.app.bundleID].map(scope.restores) == true {
            awaitingVisitByScreen[item.screenID, default: []].insert(item.app.bundleID)
        }
    }

    private func currentAwaitingVisits(
        in resolved: [String: ResolvedProfile]
    ) -> [String: Set<String>] {
        awaitingVisitByScreen.reduce(into: [:]) { result, entry in
            guard let pair = resolved[entry.key] else { return }
            let enabled = Set(pair.profile.apps.compactMap { app -> String? in
                guard app.isEnabled,
                      pair.overlay?.byBundle[app.bundleID].map(scope.restores) == true
                else { return nil }
                return app.bundleID
            })
            let current = entry.value.intersection(enabled)
            if !current.isEmpty { result[entry.key] = current }
        }
    }

    private func reopenLegacyWindowless(
        in resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        only: [String: Set<String>]?,
        options: RestoreOptions
    ) async {
        guard options.reopenWindowless else { return }
        var windowless: [String] = []
        for item in claimedApps(in: resolved, screens: screens) {
            guard only == nil || only?[item.screenID]?.contains(item.app.bundleID) == true,
                  item.pair.overlay?.byBundle[item.app.bundleID].map(scope.restores) != true,
                  await gateway.isRunning(bundleID: item.app.bundleID),
                  await observation.windows(of: [item.app.bundleID]).isEmpty else { continue }
            windowless.append(item.app.bundleID)
        }
        await withTaskGroup(of: Void.self) { group in
            for bundleID in windowless {
                group.addTask { _ = await self.gateway.openWindow(bundleID: bundleID) }
            }
        }
    }

    private func claimedApps(
        in resolved: [String: ResolvedProfile], screens: [ScreenInfo]
    ) -> [(screenID: String, pair: ResolvedProfile, app: TargetApp)] {
        var claimed = Set<String>()
        var result: [(String, ResolvedProfile, TargetApp)] = []
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id] else { continue }
            for app in pair.profile.apps
            where app.isEnabled && claimed.insert(app.bundleID).inserted {
                result.append((screen.id, pair, app))
            }
        }
        return result
    }

    private func removeCompleted(_ completed: [String: Set<String>]) {
        for (screenID, bundleIDs) in completed {
            awaitingVisitByScreen[screenID]?.subtract(bundleIDs)
            if awaitingVisitByScreen[screenID]?.isEmpty == true {
                awaitingVisitByScreen.removeValue(forKey: screenID)
            }
        }
    }
}
