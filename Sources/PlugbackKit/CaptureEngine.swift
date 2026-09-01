import CoreGraphics

/// 저장 엔진 (F-03). 거의 순수 함수 — 게이트웨이가 준 스냅샷만 받는다.
public enum CaptureEngine {
    /// 지금 이 외장 화면에 창이 있는 앱의 항목만 갱신하고, 나머지 기존 항목은 그대로 유지한다 (F-03.3 병합).
    /// 창의 소속 화면은 중심점으로 판정한다 (F-03.2). 내장 화면이 오면 아무것도 갱신하지 않는다 — 내장 배치는 저장 대상이 아니다 (F-03.2).
    public static func capture(
        windows: [WindowInfo],
        on screen: ScreenInfo,
        merging existing: Profile?
    ) -> Profile {
        var profile = existing ?? Profile(screenID: screen.id, screenName: screen.name)
        profile.screenName = screen.name

        guard !screen.isBuiltin, screen.frame.width > 0, screen.frame.height > 0 else { return profile }

        // 앱별 첫 표준 창 하나 — 비율 좌표는 앱당 하나다 (F-04.1).
        // 창 목록의 순서(z-순서)를 유지해야 신규 앱의 목록 순서가 저장마다 뒤바뀌지 않는다.
        var ordered: [(bundleID: String, window: WindowInfo)] = []
        var seen = Set<String>()
        for window in windows
        where !window.isMinimized && !window.isFullscreen && screen.contains(window) {
            if seen.insert(window.appBundleID).inserted {
                ordered.append((window.appBundleID, window))
            }
        }

        for (bundleID, window) in ordered {
            merge(window, bundleID: bundleID, on: screen, into: &profile)
        }
        return profile
    }

    /// frame과 Space binding을 같은 창 선택 결과에서 만드는 Space-aware 캡처.
    /// 확실하지 않은 bundle은 기존 좌표를 유지하고 overlay만 unresolved로 바꾼다.
    static func capture(
        windows: [WindowInfo],
        on screen: ScreenInfo,
        merging existing: ResolvedProfile?,
        snapshot: SpaceSnapshot,
        updating bundleIDs: Set<String>? = nil
    ) -> ResolvedProfile {
        var result = existing ?? ResolvedProfile(
            profile: Profile(screenID: screen.id, screenName: screen.name),
            overlay: SlotSpaceOverlay()
        )
        result.profile.screenName = screen.name
        guard !screen.isBuiltin, screen.frame.width > 0, screen.frame.height > 0 else {
            return result
        }

        var overlay = result.overlay ?? SlotSpaceOverlay()
        if let regularSpaces = regularSpaces(on: screen, in: snapshot) {
            overlay.regularSpaces = regularSpaces
        }
        var seen = Set<String>()
        for selected in windows
        where !selected.isMinimized
            && selected.fullscreenState == .windowed
            && screen.contains(selected) {
            let bundleID = selected.appBundleID
            guard bundleIDs?.contains(bundleID) ?? true else { continue }
            guard seen.insert(bundleID).inserted else { continue }
            let bundleWindows = windows.filter { $0.appBundleID == bundleID }
            let binding = binding(
                bundleWindows: bundleWindows, on: screen, snapshot: snapshot
            )
            overlay.byBundle[bundleID] = binding
            switch binding {
            case .regular:
                merge(selected, bundleID: bundleID, on: screen, into: &result.profile)
            case .unresolved:
                continue
            }
        }
        overlay.keepOnly(Set(result.profile.apps.map(\.bundleID)))
        result.overlay = overlay
        return result
    }

    /// 자동 슬롯의 수집 정책. 현재 외장 화면에서 갱신할 앱과 다른 화면으로 명확히
    /// 떠난 앱을 한 pair 안에서 처리한다.
    static func collect(
        windows: [WindowInfo],
        on screen: ScreenInfo,
        merging existing: ResolvedProfile,
        snapshot: SpaceSnapshot?
    ) -> ResolvedProfile {
        let disabled = Set(
            existing.profile.apps.filter { !$0.isEnabled }.map(\.bundleID)
        )
        let updating = Set(windows.map(\.appBundleID)).subtracting(disabled)
        let presentElsewhere = Set(windows.lazy
            .filter { !$0.isMinimized }
            .map(\.appBundleID))
            .subtracting(Set(windows.lazy
                .filter { screen.contains($0) }
                .map(\.appBundleID)))
            .subtracting(disabled)

        var result: ResolvedProfile
        if let snapshot {
            result = capture(
                windows: windows, on: screen, merging: existing,
                snapshot: snapshot, updating: updating
            )
        } else {
            let selected = windows.filter { updating.contains($0.appBundleID) }
            result = ResolvedProfile(
                profile: capture(
                    windows: selected, on: screen, merging: existing.profile
                ),
                overlay: nil
            )
        }

        result.profile.apps.removeAll { presentElsewhere.contains($0.bundleID) }
        var overlay = result.overlay ?? SlotSpaceOverlay()
        overlay.keepOnly(Set(result.profile.apps.map(\.bundleID)))

        result.overlay = overlay.isEmpty ? nil : overlay
        return result
    }

    /// 앱 membership과 무관하게 화면 소속을 기억한다. 이름이 없거나 snapshot 전체에서
    /// 중복인 Space는 되찾을 안전한 identity가 없으므로 기록하지 않는다.
    private static func regularSpaces(
        on screen: ScreenInfo, in snapshot: SpaceSnapshot
    ) -> [SpaceHint]? {
        guard let display = snapshot.onlyDisplay(screen.id) else { return nil }
        return display.spaces.compactMap { space in
            SpacePlacement.of(space.runtimeID, on: screen.id, in: snapshot)
                .onTarget?.identity
        }
    }

    private static func binding(
        bundleWindows: [WindowInfo],
        on screen: ScreenInfo,
        snapshot: SpaceSnapshot
    ) -> SpaceBinding {
        if bundleWindows.contains(where: { $0.fullscreenState == .unknown }) {
            return .unresolved(reason: .fullscreenUnknown)
        }
        if bundleWindows.contains(where: { $0.fullscreenState == .fullscreen }) {
            return .unresolved(reason: .fullscreen)
        }

        let placement = SpacePlacement.of(
            windowServerIDs: bundleWindows.map(\.windowServerID),
            on: screen.id,
            in: snapshot
        )
        if let found = placement.found, found.screenID != screen.id {
            return .unresolved(reason: .stranded)
        }
        switch placement {
        case .current(let found):
            guard let identity = found.identity else {
                return .unresolved(reason: .nameUnavailable)
            }
            return .regular(identity)
        case .inactive:
            return .unresolved(reason: .inactive)
        case .stranded:
            return .unresolved(reason: .stranded)
        case .fullscreen:
            return .unresolved(reason: .fullscreen)
        case .unsupported:
            return .unresolved(reason: .unsupportedSpace)
        case .missing:
            return .unresolved(reason: .spaceMissing)
        case .unknown(let ambiguity):
            return .unresolved(reason: blockReason(for: ambiguity))
        }
    }

    private static func blockReason(
        for ambiguity: SpacePlacement.Ambiguity
    ) -> SpaceBlockReason {
        switch ambiguity {
        case .windowUnjoined: return .windowUnjoined
        case .membership: return .membershipUnavailable
        case .multipleSpaces: return .multipleSpaces
        case .name: return .nameUnavailable
        case .noSnapshot, .display, .runtimeID: return .spaceMissing
        }
    }

    private static func merge(
        _ window: WindowInfo, bundleID: String, on screen: ScreenInfo, into profile: inout Profile
    ) {
        let rect = UnitRect(window.frame, in: screen.frame)
        if let index = profile.apps.firstIndex(where: { $0.bundleID == bundleID }) {
            profile.apps[index].displayName = window.appName
            // 허용 오차 안의 차이는 좌표를 갱신하지 않는다 (드리프트 방지).
            let stored = profile.apps[index].unitRect.frame(in: screen.frame)
            guard !RestoreEngine.approximatelyEqual(window.frame, stored) else { return }
            profile.apps[index].unitRect = rect
        } else {
            profile.apps.append(TargetApp(
                bundleID: bundleID, displayName: window.appName, unitRect: rect
            ))
        }
    }

}
