import CoreGraphics

/// 선택 복원 엔진 (F-02). 프로필에 없는 앱과 내장 화면의 창은 존재 자체를 모른다.
public enum RestoreEngine {
    /// 이동 후 검증 허용 오차. 실기기 측정 후 조정할 수 있는 초기값이다 (F-02.3).
    public static let tolerance: CGFloat = 5

    public static func restore(
        profile: Profile,
        on screen: ScreenInfo,
        using gateway: WindowGateway
    ) -> RestoreResult {
        var result = RestoreResult(screenID: screen.id)

        for app in profile.apps where app.isEnabled {
            let outcome = restoreOne(app, on: screen, using: gateway)
            result.entries.append(.init(bundleID: app.bundleID, displayName: app.displayName, outcome: outcome))
        }
        return result
    }

    private static func restoreOne(
        _ app: TargetApp, on screen: ScreenInfo, using gateway: WindowGateway
    ) -> RestoreResult.Outcome {
        guard gateway.isRunning(bundleID: app.bundleID) else { return .skipped(.appNotRunning) }

        // 이 외장 화면에 중심점이 있는 창만 대상이다 — 내장 화면의 창은 건드리지 않는다 (F-02.5)
        let candidates = gateway.standardWindows(of: [app.bundleID])
            .filter { screen.contains($0) }
        guard !candidates.isEmpty else { return .skipped(.noWindowOnScreen) }

        // 이동 가능한 첫 창. 전부 이동 불가면 사유는 창 순서와 무관하게 전체화면 우선 —
        // 창 순서는 불안정하다 (FUNCTIONAL_SPEC 부록 3)
        guard let window = candidates.first(where: { !$0.isFullscreen && !$0.isMinimized }) else {
            return .skipped(candidates.contains(where: \.isFullscreen) ? .fullscreen : .minimized)
        }

        let target = app.unitRect.frame(in: screen.frame)
        if approximatelyEqual(window.frame, target) { return .skipped(.alreadyInPlace) }

        // 이동 → 검증 → 1회 재시도 (F-02.3). 재시도도 실패하면 실패로 기록하고 멈추지 않는다.
        for _ in 0..<2 {
            if let actual = gateway.move(windowID: window.id, to: target),
               approximatelyEqual(actual, target) {
                return .moved
            }
        }
        return .failed
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
