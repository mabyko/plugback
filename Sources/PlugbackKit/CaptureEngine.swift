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
            let rect = UnitRect(window.frame, in: screen.frame)
            if let index = profile.apps.firstIndex(where: { $0.bundleID == bundleID }) {
                profile.apps[index].displayName = window.appName
                // 허용 오차 안의 차이는 좌표를 갱신하지 않는다 (드리프트 방지).
                // 복원은 몇 px 어긋나게 착지해도 성공으로 기록한다(F-02.3). 그 값을 저장하면
                // 다음 회차가 그것을 목표로 삼아 또 어긋나고, 검증을 통과한 채로 창이 계속 밀린다.
                // 사용자가 실제로 옮긴 거리는 이 오차보다 크다.
                let stored = profile.apps[index].unitRect.frame(in: screen.frame)
                if RestoreEngine.approximatelyEqual(window.frame, stored) { continue }
                profile.apps[index].unitRect = rect
            } else {
                profile.apps.append(TargetApp(bundleID: bundleID, displayName: window.appName, unitRect: rect))
            }
        }
        return profile
    }
}
