import CoreGraphics
import Foundation

/// 복원 옵션 (F-02.2 예외 설정들). 옵션이 늘어도 restore 시그니처는 안 넓어진다.
public struct RestoreOptions: Sendable {
    /// 최소화된 창도 Dock에서 꺼내 복원 (기본 꺼짐 — 최소화는 사용자의 의도다).
    public var restoreMinimized: Bool
    /// 실행 중인데 창이 없는 앱에 새 창을 열게 해 복원 (기본 꺼짐). 꺼진 앱은 실행하지 않는다.
    public var reopenWindowless: Bool

    public init(restoreMinimized: Bool = false, reopenWindowless: Bool = false) {
        self.restoreMinimized = restoreMinimized
        self.reopenWindowless = reopenWindowless
    }
}

/// 선택 복원 엔진 (F-02). 프로필에 없는 앱과 내장 화면의 창은 존재 자체를 모른다.
/// 복원 정책 전부가 여기 산다: 창 선택, 건너뜀 판정, 지문 검증(F-01.4),
/// 다중 화면 중복 제거(F-01.6), 이동 검증·재시도(F-02.3), 새 창 열기 후 복원.
public enum RestoreEngine {
    /// 이동 후 검증 허용 오차. 실기기 측정 후 조정할 수 있는 초기값이다 (F-02.3).
    public static let tolerance: CGFloat = 5

    /// 연결된 외장 화면들에 각 프로필을 적용한다. 반환 시점 = 완료 시점 — 최종 결과다.
    /// 프로필 없는 화면은 결과를 만들지 않는다 (US-007 AC-5).
    /// 같은 앱이 여러 프로필에 있으면 식별자 정렬 순서상 첫 화면만 적용한다 — 한 창을 두 번 옮기지 않는다 (F-01.6).
    @MainActor
    public static func restore(
        profiles: [String: Profile],
        screens: [ScreenInfo],
        using gateway: WindowGateway,
        options: RestoreOptions = RestoreOptions()
    ) async -> [RestoreResult] {
        var results: [RestoreResult] = []
        var claimed = Set<String>()
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard var profile = profiles[screen.id] else { continue }
            // UUID 일치 + 지문 불일치 = OS가 배정을 바꿨다는 신호. 오작동 대신 무작동 (F-01.4).
            if let saved = profile.fingerprint, let live = screen.fingerprint, saved != live {
                results.append(RestoreResult(screenID: screen.id, screenSkipReason: .fingerprintMismatch))
                continue
            }
            profile.apps.removeAll { claimed.contains($0.bundleID) }

            var result = RestoreResult(screenID: screen.id)
            for app in profile.apps where app.isEnabled {
                let outcome = await restoreOne(app, on: screen, using: gateway, options: options)
                result.entries.append(.init(bundleID: app.bundleID, displayName: app.displayName, outcome: outcome))
            }
            results.append(result)
            claimed.formUnion(profile.apps.filter(\.isEnabled).map(\.bundleID))
        }
        return results
    }

    @MainActor
    private static func restoreOne(
        _ app: TargetApp, on screen: ScreenInfo, using gateway: WindowGateway, options: RestoreOptions
    ) async -> RestoreResult.Outcome {
        guard gateway.isRunning(bundleID: app.bundleID) else { return .skipped(.appNotRunning) }

        var all = gateway.standardWindows(of: [app.bundleID])
        if all.isEmpty {
            // 옵션이 켜졌으면 새 창을 열게 하고 창이 실재할 때까지 기다린다 — 발견 지점에서 바로 결정 (F-02.2 예외).
            // ponytail: 창 없는 앱이 여럿이면 대기가 순차다. 앱당 한도는 게이트웨이 노브 — 병렬화는 그게 느릴 때.
            guard options.reopenWindowless, await gateway.openWindow(bundleID: app.bundleID) else {
                return .skipped(.noWindow)
            }
            all = gateway.standardWindows(of: [app.bundleID])
            guard !all.isEmpty else { return .skipped(.noWindow) }
        }

        // 창 선택 (F-02.1의 4, 요구사항 다): 대상 화면의 창이 있으면 그중에서 —
        // 없으면 첫 표준 창을 어디서든 데려온다. 케이블을 뽑으면 macOS가 창을 내장으로
        // 옮겨두므로, 데려오지 못하면 핵심 시나리오가 성립하지 않는다.
        // 옮기는 건 앱당 이 한 창뿐 — 내장 화면의 나머지 창은 건드리지 않는다.
        let onScreen = all.filter { screen.contains($0) }
        let candidates = onScreen.isEmpty ? all : onScreen

        // 이동 가능한 첫 창. 전부 이동 불가면 사유는 창 순서와 무관하게 전체화면 우선 —
        // 창 순서는 불안정하다 (FUNCTIONAL_SPEC 부록 3)
        // 보이는 창을 우선하고, 옵션이 켜졌을 때만 최소화 창을 차선으로 쓴다.
        let movable = candidates.filter { !$0.isFullscreen }
        guard let window = movable.first(where: { !$0.isMinimized })
                ?? (options.restoreMinimized ? movable.first : nil) else {
            return .skipped(candidates.contains(where: \.isFullscreen) ? .fullscreen : .minimized)
        }
        // Dock에서 먼저 꺼낸다 — 최소화 상태로는 이동 결과가 보이지 않는다 (F-02.2)
        if window.isMinimized, !gateway.unminimize(windowID: window.id) {
            return .skipped(.minimized)
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
