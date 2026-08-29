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
        for selected in windows where !selected.isMinimized && screen.contains(selected) {
            let bundleID = selected.appBundleID
            guard bundleIDs?.contains(bundleID) ?? true else { continue }
            guard seen.insert(bundleID).inserted else { continue }
            let bundleWindows = windows.filter { $0.appBundleID == bundleID }
            let binding = binding(
                for: selected, bundleWindows: bundleWindows, allWindows: windows,
                on: screen, snapshot: snapshot
            )
            overlay.byBundle[bundleID] = binding
            switch binding {
            case .regular:
                merge(selected, bundleID: bundleID, on: screen, into: &result.profile)
            case .fullscreen:
                registerFullscreen(
                    selected, bundleID: bundleID, on: screen, into: &result.profile
                )
            case .unresolved:
                continue
            }
        }
        overlay.keepOnly(Set(result.profile.apps.map(\.bundleID)))
        result.overlay = overlay
        return result
    }

    /// 앱 membership과 무관하게 화면 소속을 기억한다. 이름이 없거나 snapshot 전체에서
    /// 중복인 Space는 되찾을 안전한 identity가 없으므로 기록하지 않는다.
    private static func regularSpaces(
        on screen: ScreenInfo, in snapshot: SpaceSnapshot
    ) -> [SpaceHint]? {
        let displays = snapshot.displays.filter { $0.screenID == screen.id }
        guard displays.count == 1, let display = displays.first else { return nil }
        let nameCounts = Dictionary(
            grouping: snapshot.displays.flatMap(\.spaces).compactMap(\.opaqueName),
            by: { $0 }
        ).mapValues(\.count)
        return display.spaces.compactMap { space in
            guard space.kind == .regular,
                  let name = space.opaqueName,
                  nameCounts[name] == 1 else { return nil }
            return SpaceHint(opaqueName: name, localOrderHint: space.localOrder)
        }
    }

    private static func binding(
        for selected: WindowInfo,
        bundleWindows: [WindowInfo],
        allWindows: [WindowInfo],
        on screen: ScreenInfo,
        snapshot: SpaceSnapshot
    ) -> SpaceBinding {
        if bundleWindows.contains(where: { $0.fullscreenState == .unknown }) {
            return .unresolved(.fullscreenUnknown)
        }
        if selected.fullscreenState == .fullscreen {
            return fullscreenBinding(
                for: selected, bundleWindows: bundleWindows, allWindows: allWindows,
                on: screen, snapshot: snapshot
            )
        }
        if bundleWindows.contains(where: { $0.fullscreenState == .fullscreen }) {
            return .unresolved(.fullscreen)
        }

        var runtimeIDs = Set<SpaceRuntimeID>()
        for window in bundleWindows {
            guard let windowID = window.windowServerID else {
                return .unresolved(.windowUnjoined)
            }
            guard let memberships = snapshot.membershipsByWindowServerID[windowID],
                  memberships.count == 1,
                  let runtimeID = memberships.first else {
                return .unresolved(.membershipUnavailable)
            }
            runtimeIDs.insert(runtimeID)
        }
        guard runtimeIDs.count == 1, let runtimeID = runtimeIDs.first else {
            return .unresolved(.multipleSpaces)
        }

        let locations = snapshot.displays.flatMap { display in
            display.spaces.filter { $0.runtimeID == runtimeID }.map { (display, $0) }
        }
        guard locations.count == 1, let location = locations.first else {
            return .unresolved(.spaceMissing)
        }
        guard location.0.screenID == screen.id else { return .unresolved(.stranded) }
        switch location.1.kind {
        case .fullscreen: return .unresolved(.fullscreen)
        case .unknown: return .unresolved(.unsupportedSpace)
        case .regular: break
        }
        guard location.1.isCurrent else { return .unresolved(.inactive) }
        guard let name = location.1.opaqueName,
              location.0.spaces.filter({ $0.opaqueName == name }).count == 1 else {
            return .unresolved(.nameUnavailable)
        }
        guard let selectedID = selected.windowServerID,
              snapshot.membershipsByWindowServerID[selectedID] == [runtimeID] else {
            return .unresolved(.membershipUnavailable)
        }
        return .regular(SpaceHint(opaqueName: name, localOrderHint: location.1.localOrder))
    }

    private static func fullscreenBinding(
        for selected: WindowInfo,
        bundleWindows: [WindowInfo],
        allWindows: [WindowInfo],
        on screen: ScreenInfo,
        snapshot: SpaceSnapshot
    ) -> SpaceBinding {
        guard bundleWindows.count == 1 else { return .unresolved(.multipleSpaces) }
        guard let windowID = selected.windowServerID else {
            return .unresolved(.windowUnjoined)
        }
        guard let memberships = snapshot.membershipsByWindowServerID[windowID],
              memberships.count == 1, let runtimeID = memberships.first else {
            return .unresolved(.membershipUnavailable)
        }
        let locations = snapshot.displays.flatMap { display in
            display.spaces.filter { $0.runtimeID == runtimeID }.map { (display, $0) }
        }
        guard locations.count == 1, let location = locations.first else {
            return .unresolved(.spaceMissing)
        }
        guard location.0.screenID == screen.id else { return .unresolved(.stranded) }
        guard location.1.kind == .fullscreen else { return .unresolved(.fullscreen) }
        guard location.1.isCurrent else { return .unresolved(.inactive) }

        // type 4 하나에 AX 표준 창이 둘이면 Split View다. 자동 수집은 single만 기록한다.
        let joined = allWindows.filter { window in
            guard let id = window.windowServerID else { return false }
            return snapshot.membershipsByWindowServerID[id] == [runtimeID]
        }
        guard joined.count == 1, joined[0].id == selected.id else {
            return .unresolved(.unsupportedSpace)
        }
        return .fullscreen
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

    private static func registerFullscreen(
        _ window: WindowInfo, bundleID: String, on screen: ScreenInfo,
        into profile: inout Profile
    ) {
        if let index = profile.apps.firstIndex(where: { $0.bundleID == bundleID }) {
            profile.apps[index].displayName = window.appName
            return // 마지막 일반 frame은 fullscreen 복원 전 화면 이동에 다시 쓴다.
        }
        // ponytail: fullscreen-only 앱은 실제 일반 frame을 읽을 수 없다. 현재 화면 bounds를
        // staging frame으로 쓰고, 실기기에서 이동 거부가 나오면 placement 모델을 분리한다.
        profile.apps.append(TargetApp(
            bundleID: bundleID, displayName: window.appName,
            unitRect: UnitRect(window.frame, in: screen.frame)
        ))
    }
}
