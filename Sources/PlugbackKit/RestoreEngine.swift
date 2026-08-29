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

/// 복원 예측 — 카드의 점이 쓰는 어휘. 진실(restore)과 같은 선택 규칙에서 계산된다.
/// 일치 범위: 식별자 정렬상 첫 화면(카드가 보여주는 화면)에서 **판정 규칙**이 진실과 일치한다.
/// 실행 시점 사건 — 이동 실패, 새 창 미등장, 지문 불일치의 화면 통째 건너뜀, 체크 해제 — 은 예측이 담지 않는다.
/// 뒷 화면에서는 앞 화면과 겹치는 앱이 다중 화면 중복 제거(F-01.6)로 빠질 수 있다 —
/// 예측은 화면 목록 맥락을 받지 않으므로 그 제거를 모른다.
public enum RestorePrediction: Equatable, Sendable {
    /// 복원하면 이 앱의 창이 옮겨진다 (새 창 열기 옵션으로 열려서 옮겨지는 경우 포함).
    case willMove
    /// 이미 제자리 — 옮길 필요가 없다.
    case alreadyInPlace
    /// 이 사유로 건너뛸 것이다.
    case willSkip(SkipReason)
}

/// Space-aware 경로의 순수 선택 결과. 이동과 pending 수명은 P4 controller의 일이다.
enum SpaceWindowSelection: Equatable, Sendable {
    case legacy
    case window(WindowInfo)
    case inactive
    case unavailable
    case fullscreen
}

/// 한 Space-aware pass의 결과와, 더는 다음 Space 방문을 기다릴 필요가 없는 binding들.
struct SpaceRestorePass: Equatable, Sendable {
    var results: [RestoreResult]
    var completedByScreen: [String: Set<String>]
}

/// 선택 복원 엔진 (F-02). 프로필에 없는 앱과 내장 화면의 창은 존재 자체를 모른다.
/// 격리 자유 — 어느 액터에도 묶이지 않는다. AX의 실행 흐름은 게이트웨이 어댑터의 것이다 (F-02.4).
/// 복원 정책 전부가 여기 산다: 창 선택, 건너뜀 판정, 지문 검증(F-01.4),
/// 다중 화면 중복 제거(F-01.6), 이동 검증·재시도(F-02.3), 새 창 열기 후 복원.
public enum RestoreEngine {
    /// 이동 후 검증 허용 오차. 실기기 측정 후 조정할 수 있는 초기값이다 (F-02.3).
    public static let tolerance: CGFloat = 5

    /// binding이 있는 bundle은 이 결과 하나만 따른다. 실패해도 legacy 선택으로 내려가지 않는다.
    static func selectSpaceWindow(
        bundleID: String,
        in resolved: ResolvedProfile,
        on screen: ScreenInfo,
        windows: [WindowInfo],
        snapshot: SpaceSnapshot?
    ) -> SpaceWindowSelection {
        guard let binding = resolved.overlay?.byBundle[bundleID] else { return .legacy }
        let hint: SpaceHint
        switch binding {
        case .regular(let value): hint = value
        case .unresolved(.fullscreen): return .fullscreen
        case .unresolved: return .unavailable
        }
        guard let snapshot else { return .unavailable }

        let displays = snapshot.displays.filter { $0.screenID == screen.id }
        guard displays.count == 1, let display = displays.first else { return .unavailable }
        let spaces = display.spaces.filter { $0.opaqueName == hint.opaqueName }
        guard spaces.count == 1, let boundSpace = spaces.first else { return .unavailable }
        switch boundSpace.kind {
        case .fullscreen: return .fullscreen
        case .unknown: return .unavailable
        case .regular: break
        }

        let candidates = windows.filter { $0.appBundleID == bundleID }
        // 저장 뒤 native fullscreen이 된 앱은 원래 regular Space가 비활성이어도 현재 type 4에서
        // AXFullScreen으로 보인다. 이 강한 신호를 먼저 소비해야 "대기"로 영원히 남지 않는다.
        if candidates.contains(where: { $0.fullscreenState == .fullscreen }) {
            return .fullscreen
        }
        guard !candidates.contains(where: { $0.fullscreenState == .unknown }) else {
            return .unavailable
        }
        guard boundSpace.isCurrent else { return .inactive }
        guard !candidates.isEmpty else { return .unavailable }

        var memberships: [SpaceRuntimeID] = []
        for window in candidates {
            guard let windowID = window.windowServerID,
                  let ids = snapshot.membershipsByWindowServerID[windowID],
                  ids.count == 1,
                  let runtimeID = ids.first else { return .unavailable }
            let joinedSpaces = snapshot.displays.flatMap(\.spaces).filter {
                $0.runtimeID == runtimeID
            }
            guard joinedSpaces.count == 1, let joinedSpace = joinedSpaces.first else {
                return .unavailable
            }
            switch joinedSpace.kind {
            case .fullscreen: return .fullscreen
            case .unknown: return .unavailable
            case .regular: memberships.append(runtimeID)
            }
        }
        guard Set(memberships) == [boundSpace.runtimeID], candidates.count == 1,
              let window = candidates.first else { return .unavailable }
        return .window(window)
    }

    /// 연결된 외장 화면들에 각 프로필을 적용한다. 반환 시점 = 완료 시점 — 최종 결과다.
    /// 프로필 없는 화면은 결과를 만들지 않는다 (US-007 AC-5).
    /// 같은 앱이 여러 프로필에 있으면 식별자 정렬 순서상 첫 화면만 적용한다 — 한 창을 두 번 옮기지 않는다 (F-01.6).
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

            // 사전 단계 (F-02.2 예외 옵션): 창 없는 실행 중 앱 전부에 동시 새 창 열기.
            // 대기가 병렬이라 총 지연은 앱 수와 무관하게 화면당 게이트웨이 한도(≤3초)다 (F-07).
            if options.reopenWindowless {
                var windowless: [String] = []
                for app in profile.apps where app.isEnabled {
                    if await gateway.isRunning(bundleID: app.bundleID),
                       await gateway.standardWindows(of: [app.bundleID]).isEmpty {
                        windowless.append(app.bundleID)
                    }
                }
                await withTaskGroup(of: Void.self) { group in
                    for bundleID in windowless {
                        group.addTask { _ = await gateway.openWindow(bundleID: bundleID) }
                    }
                }
            }

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

    /// 이미 한 번 열거한 창과 같은 회차의 Space snapshot만 쓴다. 이 함수 안에서는 창을
    /// 다시 열거하지 않으므로 선택에 쓴 gateway window ID가 move가 끝날 때까지 유효하다.
    static func restore(
        resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        windows: [WindowInfo],
        snapshot: SpaceSnapshot?,
        onlyBundles: [String: Set<String>]? = nil,
        using gateway: WindowGateway,
        options: RestoreOptions = RestoreOptions()
    ) async -> SpaceRestorePass {
        var results: [RestoreResult] = []
        var completed: [String: Set<String>] = [:]
        var claimed = Set<String>()

        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id] else { continue }
            let profile = pair.profile
            if let saved = profile.fingerprint, let live = screen.fingerprint, saved != live {
                results.append(RestoreResult(
                    screenID: screen.id, screenSkipReason: .fingerprintMismatch
                ))
                continue
            }

            let uniqueApps = profile.apps.filter { app in
                app.isEnabled && claimed.insert(app.bundleID).inserted
            }
            let selectedApps = if let onlyBundles {
                uniqueApps.filter { onlyBundles[screen.id]?.contains($0.bundleID) == true }
            } else {
                uniqueApps
            }
            guard !selectedApps.isEmpty else { continue }

            var result = RestoreResult(screenID: screen.id)
            for app in selectedApps {
                guard await gateway.isRunning(bundleID: app.bundleID) else {
                    result.entries.append(.init(
                        bundleID: app.bundleID, displayName: app.displayName,
                        outcome: .skipped(.appNotRunning)
                    ))
                    continue
                }

                let outcome: RestoreResult.Outcome
                switch selectSpaceWindow(
                    bundleID: app.bundleID, in: pair, on: screen,
                    windows: windows, snapshot: snapshot
                ) {
                case .legacy:
                    let candidates = windows.filter { $0.appBundleID == app.bundleID }
                    guard !candidates.isEmpty else {
                        result.entries.append(.init(
                            bundleID: app.bundleID, displayName: app.displayName,
                            outcome: .skipped(.noWindow)
                        ))
                        continue
                    }
                    switch pickWindow(from: candidates, on: screen, options: options) {
                    case .skip(let reason): outcome = .skipped(reason)
                    case .window(let window):
                        outcome = await restore(app, window: window, on: screen,
                                                using: gateway, options: options)
                    }
                case .window(let window):
                    outcome = await restore(
                        app, window: window, on: screen, using: gateway, options: options
                    )
                case .fullscreen:
                    outcome = .skipped(.fullscreen)
                case .inactive, .unavailable:
                    continue
                }

                result.entries.append(.init(
                    bundleID: app.bundleID, displayName: app.displayName, outcome: outcome
                ))
                if outcome == .moved || outcome == .skipped(.alreadyInPlace)
                    || outcome == .skipped(.fullscreen) {
                    completed[screen.id, default: []].insert(app.bundleID)
                }
            }
            results.append(result)
        }
        return SpaceRestorePass(results: results, completedByScreen: completed)
    }

    private static func restoreOne(
        _ app: TargetApp, on screen: ScreenInfo, using gateway: WindowGateway, options: RestoreOptions
    ) async -> RestoreResult.Outcome {
        guard await gateway.isRunning(bundleID: app.bundleID) else { return .skipped(.appNotRunning) }

        // 새 창 열기는 사전 단계에서 병렬로 끝났다 — 여기서는 그 결과(창 유무)만 본다.
        let all = await gateway.standardWindows(of: [app.bundleID])
        guard !all.isEmpty else { return .skipped(.noWindow) }

        let window: WindowInfo
        switch pickWindow(from: all, on: screen, options: options) {
        case .skip(let reason): return .skipped(reason)
        case .window(let picked): window = picked
        }
        return await restore(app, window: window, on: screen, using: gateway, options: options)
    }

    private static func restore(
        _ app: TargetApp, window: WindowInfo, on screen: ScreenInfo,
        using gateway: WindowGateway, options: RestoreOptions
    ) async -> RestoreResult.Outcome {
        // Dock에서 먼저 꺼낸다 — 최소화 상태로는 이동 결과가 보이지 않는다 (F-02.2).
        // 꺼낸 뒤의 재판독 프레임으로 판정한다 — 열거 시점 스냅샷은 이미 스테일이다.
        var currentFrame = window.frame
        if window.isMinimized {
            guard options.restoreMinimized else { return .skipped(.minimized) }
            guard let fresh = await gateway.unminimize(windowID: window.id) else { return .skipped(.minimized) }
            currentFrame = fresh
        }

        let target = app.unitRect.frame(in: screen.frame)
        if approximatelyEqual(currentFrame, target) { return .skipped(.alreadyInPlace) }

        // 이동 → 검증 → 1회 재시도 (F-02.3). 재시도도 실패하면 실패로 기록하고 멈추지 않는다.
        for _ in 0..<2 {
            if let actual = await gateway.move(windowID: window.id, to: target),
               approximatelyEqual(actual, target) {
                return .moved
            }
        }
        return .failed
    }

    // MARK: - 예측 (점의 어휘) — 진실과 같은 선택 규칙

    /// 복원을 실행하면 각 대상 앱이 어떻게 될지의 사전 판정. 부수효과 없음 — 이미 열거된
    /// 스냅샷을 받는 거의 순수 함수다 (CaptureEngine과 같은 관계).
    /// screen이 nil이면(연결 해제 상태) 제자리 판정은 생략된다 — 연결되면 다시 계산된다.
    public static func predict(
        profile: Profile, on screen: ScreenInfo?, windows: [WindowInfo],
        running: Set<String>, options: RestoreOptions = RestoreOptions()
    ) -> [String: RestorePrediction] {
        var result: [String: RestorePrediction] = [:]
        for app in profile.apps {
            result[app.bundleID] = predictOne(app, on: screen, windows: windows,
                                              running: running, options: options)
        }
        return result
    }

    private static func predictOne(
        _ app: TargetApp, on screen: ScreenInfo?, windows: [WindowInfo],
        running: Set<String>, options: RestoreOptions
    ) -> RestorePrediction {
        guard running.contains(app.bundleID) else { return .willSkip(.appNotRunning) }
        let all = windows.filter { $0.appBundleID == app.bundleID }
        if all.isEmpty {
            // 새 창 열기 옵션이 켜졌으면 복원이 창을 열어서 옮길 것이다
            return options.reopenWindowless ? .willMove : .willSkip(.noWindow)
        }
        switch pickWindow(from: all, on: screen, options: options) {
        case .skip(let reason): return .willSkip(reason)
        case .window(let window):
            guard let screen else { return .willMove }
            let target = app.unitRect.frame(in: screen.frame)
            return approximatelyEqual(window.frame, target) ? .alreadyInPlace : .willMove
        }
    }

    // MARK: - 공유 코어

    /// 창 선택 규칙 (F-02.1의 4, 요구사항 다) — 진실(restore)과 예측(predict)이 공유하는 유일한 구현.
    /// 대상 화면의 창이 있으면 그중에서 — 없으면 첫 표준 창을 어디서든 데려온다.
    /// 케이블을 뽑으면 macOS가 창을 내장으로 옮겨두므로, 데려오지 못하면 핵심 시나리오가 성립하지 않는다.
    /// 이동 가능한 첫 창을 고르되 보이는 창 우선, 최소화 창은 옵션이 켜졌을 때만 차선.
    /// 전부 이동 불가면 사유는 창 순서와 무관하게 전체화면 우선 — 창 순서는 불안정하다 (부록 3).
    private enum Pick { case window(WindowInfo), skip(SkipReason) }

    private static func pickWindow(
        from all: [WindowInfo], on screen: ScreenInfo?, options: RestoreOptions
    ) -> Pick {
        let onScreen = screen.map { s in all.filter { s.contains($0) } } ?? []
        let candidates = onScreen.isEmpty ? all : onScreen
        let movable = candidates.filter { !$0.isFullscreen }
        guard let window = movable.first(where: { !$0.isMinimized })
                ?? (options.restoreMinimized ? movable.first : nil) else {
            return .skip(candidates.contains(where: \.isFullscreen) ? .fullscreen : .minimized)
        }
        return .window(window)
    }

    /// internal — CaptureEngine의 드리프트 방지가 같은 판정을 써야 한다.
    /// 복원이 "제자리"라고 본 차이를 저장이 "옮겨졌다"고 보면 두 엔진이 서로 어긋난다.
    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
