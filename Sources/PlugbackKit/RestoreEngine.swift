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
/// 실행 시점 사건 — 이동 실패, 새 창 미등장, 지문 불일치의 화면 통째 건너뜀,
/// 체크 해제, 한 pass의 두 번째 이후 fullscreen 전환 — 은 예측이 담지 않는다.
/// 방문 대기·판정 불가처럼 이번 회차에 결과가 없는 앱은 사전에도 들어가지 않는다.
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

/// Space-aware 경로의 순수 선택 결과. 이동과 방문 대기 수명은 RestoreSession의 일이다.
enum SpaceWindowSelection: Equatable, Sendable {
    case legacy
    case window(WindowInfo)
    case enterFullscreen(WindowInfo)
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

    static func isEligible(_ resolved: ResolvedProfile, on screen: ScreenInfo) -> Bool {
        guard let saved = resolved.profile.fingerprint, let live = screen.fingerprint else {
            return true
        }
        return saved == live
    }

    /// 한 복원 회차의 화면별 담당 앱. 지문 불일치 화면을 먼저 제외한 뒤 식별자 순으로
    /// 선점하므로 세션·엔진·Space 재배치가 같은 F-01.4/F-01.6 판정을 쓴다.
    static func claimedApps(
        in resolved: [String: ResolvedProfile], screens: [ScreenInfo]
    ) -> [(screenID: String, pair: ResolvedProfile, app: TargetApp)] {
        var claimed = Set<String>()
        var result: [(String, ResolvedProfile, TargetApp)] = []
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id], isEligible(pair, on: screen) else { continue }
            for app in pair.profile.apps
            where app.isEnabled && claimed.insert(app.bundleID).inserted {
                result.append((screen.id, pair, app))
            }
        }
        return result
    }

    /// binding이 있는 bundle은 이 결과 하나만 따른다. 실패해도 legacy 선택으로 내려가지 않는다.
    static func selectSpaceWindow(
        bundleID: String,
        in resolved: ResolvedProfile,
        on screen: ScreenInfo,
        windows: [WindowInfo],
        snapshot: SpaceSnapshot?,
        scope: SpaceRestoreScope = .all
    ) -> SpaceWindowSelection {
        guard let binding = resolved.overlay?.byBundle[bundleID] else { return .legacy }
        guard scope.restores(binding) else { return .legacy }
        let hint: SpaceHint
        switch binding {
        case .regular(let value):
            hint = value
        case .fullscreen:
            return selectFullscreenWindow(
                bundleID: bundleID, on: screen, windows: windows, snapshot: snapshot
            )
        case .unresolved(.fullscreen):
            return .fullscreen
        case .unresolved(.fullscreenUnknown):
            return .unavailable
        case .unresolved:
            return .unavailable
        }
        let boundPlacement = SpacePlacement.of(hint, on: screen.id, in: snapshot)
        let boundIsCurrent: Bool
        switch boundPlacement {
        case .current:
            boundIsCurrent = true
        case .inactive:
            boundIsCurrent = false
        case .fullscreen(let found) where found.screenID == screen.id:
            return .fullscreen
        default:
            return .unavailable
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
        guard boundIsCurrent else { return .inactive }
        guard !candidates.isEmpty else { return .unavailable }

        guard candidates.count == 1, let window = candidates.first else {
            return .unavailable
        }
        switch SpacePlacement.of(
            windowServerIDs: [window.windowServerID], on: screen.id, in: snapshot
        ) {
        case .fullscreen:
            return .fullscreen
        case .unsupported, .missing, .unknown:
            return .unavailable
        case .inactive:
            return .inactive
        case .current:
            break
        case .stranded(let found):
            // 분리 후 창은 다른 화면의 현재 일반 Space로 밀려난다. 목표 Space가 현재라면
            // 그 창을 데려오는 것이 복원이고, 숨겨진 Space의 창만 건드리지 않으면 된다.
            guard found.space.isCurrent else { return .inactive }
        }
        return .window(window)
    }

    private static func selectFullscreenWindow(
        bundleID: String,
        on screen: ScreenInfo,
        windows: [WindowInfo],
        snapshot: SpaceSnapshot?
    ) -> SpaceWindowSelection {
        guard let snapshot else { return .unavailable }
        let candidates = windows.filter { $0.appBundleID == bundleID }
        guard candidates.count == 1, let window = candidates.first else { return .unavailable }
        guard window.fullscreenState != .unknown else { return .unavailable }
        let placement = SpacePlacement.of(
            windowServerIDs: [window.windowServerID], on: screen.id, in: snapshot
        )
        guard let found = placement.found else { return .unavailable }
        guard found.space.isCurrent else { return .inactive }

        switch placement {
        case .unsupported:
            return .unavailable
        case .fullscreen:
            // 두 표준 창이 같은 type 4에 있으면 Split View다. 감지만 하고 건드리지 않는다.
            let joined = windows.filter { candidate in
                SpacePlacement.of(
                    windowServerIDs: [candidate.windowServerID],
                    on: screen.id,
                    in: snapshot
                ).found?.space.runtimeID == found.space.runtimeID
            }
            guard joined.count == 1, window.fullscreenState == .fullscreen else {
                return .fullscreen
            }
            return found.screenID == screen.id ? .fullscreen : .enterFullscreen(window)
        case .current, .inactive, .stranded:
            guard window.fullscreenState == .windowed else { return .unavailable }
            return .enterFullscreen(window)
        case .missing, .unknown:
            return .unavailable
        }
    }

    /// 이미 한 번 열거한 창과 같은 회차의 Space snapshot만 쓴다. 이 함수 안에서는 창을
    /// 다시 열거하지 않으므로 선택에 쓴 gateway window ID가 move가 끝날 때까지 유효하다.
    static func restore(
        resolved: [String: ResolvedProfile],
        screens: [ScreenInfo],
        windows: [WindowInfo],
        snapshot: SpaceSnapshot?,
        onlyBundles: [String: Set<String>]? = nil,
        scope: SpaceRestoreScope = .all,
        using gateway: WindowGateway,
        options: RestoreOptions = RestoreOptions()
    ) async -> SpaceRestorePass {
        var results: [RestoreResult] = []
        var completed: [String: Set<String>] = [:]
        let claimedByScreen = Dictionary(
            grouping: claimedApps(in: resolved, screens: screens),
            by: { $0.screenID }
        )
        // fullscreen 전환은 current Space와 AX 가시성을 바꾼다. 한 stable snapshot에서
        // 둘을 연달아 조작하지 않고 다음 Space 알림의 새 snapshot으로 이어간다.
        var attemptedFullscreenTransition = false

        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard let pair = resolved[screen.id] else { continue }
            if !isEligible(pair, on: screen) {
                results.append(RestoreResult(
                    screenID: screen.id, screenSkipReason: .fingerprintMismatch
                ))
                continue
            }

            let uniqueApps = claimedByScreen[screen.id]?.map(\.app) ?? []
            let selectedApps = if let onlyBundles {
                uniqueApps.filter { onlyBundles[screen.id]?.contains($0.bundleID) == true }
            } else {
                uniqueApps
            }
            if onlyBundles != nil, selectedApps.isEmpty { continue }
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
                var completesBinding = false
                switch selectSpaceWindow(
                    bundleID: app.bundleID, in: pair, on: screen,
                    windows: windows, snapshot: snapshot, scope: scope
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
                    completesBinding = outcome == .moved || outcome == .skipped(.alreadyInPlace)
                case .enterFullscreen(let window):
                    guard !attemptedFullscreenTransition else { continue }
                    attemptedFullscreenTransition = true
                    outcome = await restoreFullscreen(
                        app, window: window, on: screen, using: gateway, options: options
                    )
                case .fullscreen:
                    outcome = .skipped(.fullscreen)
                    completesBinding = true
                case .inactive, .unavailable:
                    continue
                }

                result.entries.append(.init(
                    bundleID: app.bundleID, displayName: app.displayName, outcome: outcome
                ))
                if completesBinding {
                    completed[screen.id, default: []].insert(app.bundleID)
                }
            }
            results.append(result)
        }
        return SpaceRestorePass(results: results, completedByScreen: completed)
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

    private static func restoreFullscreen(
        _ app: TargetApp, window: WindowInfo, on screen: ScreenInfo,
        using gateway: WindowGateway, options: RestoreOptions
    ) async -> RestoreResult.Outcome {
        if window.fullscreenState == .fullscreen {
            guard await gateway.setFullscreen(windowID: window.id, false) else {
                return .failed
            }
        }

        let placement = await restore(
            app, window: window, on: screen, using: gateway, options: options
        )
        guard placement == .moved || placement == .skipped(.alreadyInPlace) else {
            return placement
        }
        guard await gateway.setFullscreen(windowID: window.id, true) else { return .failed }
        // AX 상태 변화만으로 pending을 끝내지 않는다. 다음 stable Space snapshot에서
        // 목표 화면의 single type 4로 확인돼야 controller가 binding을 완료한다.
        return .moved
    }

    // MARK: - 예측 (점의 어휘) — 진실과 같은 선택 규칙

    /// 복원을 실행하면 각 대상 앱이 어떻게 될지의 사전 판정. 부수효과 없음 — 복원과 같은
    /// profile+Space overlay, 창, snapshot, 범위를 받아 같은 창 선택 결과에서 계산한다.
    /// 방문 대기·판정 불가처럼 이번 회차에 결과가 없는 앱은 사전에 넣지 않는다.
    static func predict(
        resolved: ResolvedProfile, on screen: ScreenInfo?, windows: [WindowInfo],
        snapshot: SpaceSnapshot?, running: Set<String>, scope: SpaceRestoreScope,
        options: RestoreOptions = RestoreOptions()
    ) -> [String: RestorePrediction] {
        var result: [String: RestorePrediction] = [:]
        for app in resolved.profile.apps {
            result[app.bundleID] = predictOne(
                app, in: resolved, on: screen, windows: windows, snapshot: snapshot,
                running: running, scope: scope, options: options
            )
        }
        return result
    }

    private static func predictOne(
        _ app: TargetApp, in resolved: ResolvedProfile, on screen: ScreenInfo?,
        windows: [WindowInfo], snapshot: SpaceSnapshot?, running: Set<String>,
        scope: SpaceRestoreScope, options: RestoreOptions
    ) -> RestorePrediction? {
        guard running.contains(app.bundleID) else { return .willSkip(.appNotRunning) }

        let selection: SpaceWindowSelection
        if let screen {
            selection = selectSpaceWindow(
                bundleID: app.bundleID, in: resolved, on: screen,
                windows: windows, snapshot: snapshot, scope: scope
            )
        } else if let binding = resolved.overlay?.byBundle[app.bundleID],
                  scope.restores(binding) {
            selection = .unavailable
        } else {
            selection = .legacy
        }

        switch selection {
        case .legacy:
            return predictLegacy(app, on: screen, windows: windows, options: options)
        case .window(let window):
            return predict(app, from: window, on: screen, options: options)
        case .enterFullscreen(let window):
            guard !window.isMinimized || options.restoreMinimized else {
                return .willSkip(.minimized)
            }
            return .willMove
        case .fullscreen:
            return .willSkip(.fullscreen)
        case .inactive, .unavailable:
            return nil
        }
    }

    private static func predictLegacy(
        _ app: TargetApp, on screen: ScreenInfo?, windows: [WindowInfo],
        options: RestoreOptions
    ) -> RestorePrediction {
        let all = windows.filter { $0.appBundleID == app.bundleID }
        if all.isEmpty {
            // 새 창 열기 옵션이 켜졌으면 복원이 창을 열어서 옮길 것이다
            return options.reopenWindowless ? .willMove : .willSkip(.noWindow)
        }
        switch pickWindow(from: all, on: screen, options: options) {
        case .skip(let reason): return .willSkip(reason)
        case .window(let window): return predict(app, from: window, on: screen, options: options)
        }
    }

    private static func predict(
        _ app: TargetApp, from window: WindowInfo, on screen: ScreenInfo?,
        options: RestoreOptions
    ) -> RestorePrediction {
        guard !window.isMinimized || options.restoreMinimized else {
            return .willSkip(.minimized)
        }
        guard let screen else { return .willMove }
        let target = app.unitRect.frame(in: screen.frame)
        return approximatelyEqual(window.frame, target) ? .alreadyInPlace : .willMove
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
