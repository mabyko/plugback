import XCTest
@testable import PlugbackKit

// 화면 배치: 내장(0,0,1512×982) 오른쪽에 외장(1512,0,2560×1440). 좌상단 원점 통일 좌표계.
private let builtin = ScreenInfo(id: "builtin", name: "내장 화면", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let external = ScreenInfo(id: "ext-1", name: "LG UltraFine 27", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

private func window(_ id: Int, _ app: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                    fullscreen: Bool = false, minimized: Bool = false) -> WindowInfo {
    WindowInfo(id: id, appBundleID: app, appName: app, frame: CGRect(x: x, y: y, width: w, height: h),
               isFullscreen: fullscreen, isMinimized: minimized)
}

// MARK: - UnitRect (F-03.4)

final class UnitRectTests: XCTestCase {
    func testRoundTripOnNegativeOriginScreen() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = CGRect(x: -960, y: 340, width: 960, height: 540)
        let rect = UnitRect(frame, in: screen)
        XCTAssertEqual(rect.frame(in: screen), frame)
    }

    func testRatioSurvivesResolutionChange() {
        // 우측 50%는 해상도가 바뀌어도 우측 50%다 (US-001 AC-4)
        let rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let smaller = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(rightHalf.frame(in: smaller), CGRect(x: 1512 + 960, y: 0, width: 960, height: 1080))
    }
}

// MARK: - 저장 (F-03, US-002)

final class CaptureEngineTests: XCTestCase {
    func testCenterPointDecidesScreen() {
        // 두 화면에 걸친 창은 중심점이 있는 화면 소속이다 (US-002 AC-3)
        let straddlingCenterOnExternal = window(1, "com.chrome", x: 1400, y: 100, w: 800, h: 600) // 중심 x=1800 → 외장
        let straddlingCenterOnBuiltin = window(2, "com.slack", x: 1200, y: 100, w: 400, h: 300)   // 중심 x=1400 → 내장
        let profile = CaptureEngine.capture(windows: [straddlingCenterOnExternal, straddlingCenterOnBuiltin],
                                            on: external, merging: nil)
        XCTAssertEqual(profile.apps.map(\.bundleID), ["com.chrome"])
    }

    func testMergeKeepsAppWithoutWindowToday() {
        // 오늘 Slack을 안 켰어도 저장하면 Slack 항목은 남는다 (US-002 AC-4)
        let slackRect = UnitRect(x: 0, y: 0, width: 0.3, height: 0.5)
        let existing = Profile(screenID: external.id, screenName: external.name, apps: [
            TargetApp(bundleID: "com.slack", displayName: "Slack", unitRect: slackRect),
            TargetApp(bundleID: "com.chrome", displayName: "Chrome", unitRect: UnitRect(x: 0, y: 0, width: 1, height: 1)),
        ])
        let chromeNow = window(1, "com.chrome", x: 1512 + 1280, y: 0, w: 1280, h: 1440) // 우측 절반
        let profile = CaptureEngine.capture(windows: [chromeNow], on: external, merging: existing)

        XCTAssertEqual(profile.apps.first { $0.bundleID == "com.slack" }?.unitRect, slackRect)
        XCTAssertEqual(profile.apps.first { $0.bundleID == "com.chrome" }?.unitRect,
                       UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    func testNewAppOnExternalScreenIsAdded() {
        let code = window(1, "com.vscode", x: 1512, y: 0, w: 1280, h: 1440)
        let profile = CaptureEngine.capture(windows: [code], on: external, merging: nil)
        XCTAssertEqual(profile.apps.map(\.bundleID), ["com.vscode"])
        XCTAssertTrue(profile.apps[0].isEnabled)
    }

    func testBuiltinScreenIsNeverCaptured() {
        // 방어: 내장 화면이 오면 아무것도 갱신하지 않는다 (요구사항 다)
        let onBuiltin = window(1, "com.notes", x: 100, y: 100, w: 400, h: 300)
        let profile = CaptureEngine.capture(windows: [onBuiltin], on: builtin, merging: nil)
        XCTAssertTrue(profile.apps.isEmpty)
    }

    func testMinimizedAndFullscreenWindowsAreNotCaptured() {
        let minimized = window(1, "com.a", x: 1600, y: 0, w: 800, h: 600, minimized: true)
        let fullscreen = window(2, "com.b", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true)
        let profile = CaptureEngine.capture(windows: [minimized, fullscreen], on: external, merging: nil)
        XCTAssertTrue(profile.apps.isEmpty)
    }

    func testNewAppsKeepWindowOrder() {
        // 신규 앱의 목록 순서는 창 z-순서를 따르고, 저장을 반복해도 뒤바뀌지 않는다
        let windows = [
            window(1, "com.b", x: 1600, y: 0, w: 800, h: 600),
            window(2, "com.a", x: 2500, y: 0, w: 800, h: 600),
            window(3, "com.c", x: 1700, y: 500, w: 800, h: 600),
        ]
        let first = CaptureEngine.capture(windows: windows, on: external, merging: nil)
        XCTAssertEqual(first.apps.map(\.bundleID), ["com.b", "com.a", "com.c"])
        let second = CaptureEngine.capture(windows: windows, on: external, merging: first)
        XCTAssertEqual(second.apps.map(\.bundleID), ["com.b", "com.a", "com.c"])
    }
}

// MARK: - 선택 복원 (F-02, US-004·005·007·008)

@MainActor
final class RestoreEngineTests: XCTestCase {
    // XCTest는 테스트마다 새 인스턴스 — setUp 없이 프로퍼티 초기화로 충분하다
    private var gateway = FakeWindowGateway()

    private func profileWith(_ apps: (String, UnitRect)...) -> Profile {
        Profile(screenID: external.id, screenName: external.name,
                apps: apps.map { TargetApp(bundleID: $0.0, displayName: $0.0, unitRect: $0.1) })
    }

    private let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1)

    /// 단일 화면 복원 — 엔진 인터페이스의 테스트용 축약.
    private func restore(_ profile: Profile, options: RestoreOptions = RestoreOptions()) async -> RestoreResult {
        await RestoreEngine.restore(profiles: [external.id: profile], screens: [external],
                                    using: gateway, options: options)[0]
    }

    func testClosedAppIsSkippedAndNotLaunched() async {
        // 꺼둔 앱은 건너뛰고 실행하지 않는다 (US-004 AC-1)
        let result = await restore(profileWith(("com.slack", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.appNotRunning))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testFullscreenWindowIsLeftAlone() async {
        // 전체화면은 해제하지 않고 건너뛴다 (US-004 AC-3)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true)]
        let result = await restore(profileWith(("com.chrome", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.fullscreen))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMinimizedWindowIsLeftAlone() async {
        // 최소화는 복구하지 않는다 (US-004 AC-4)
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true)]
        let result = await restore(profileWith(("com.vscode", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.minimized))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMinimizedWindowIsRestoredWhenOptedIn() async {
        // 옵션 "최소화된 창도 복원"이 켜지면 Dock에서 꺼내서 옮긴다 (F-02.2 예외)
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true)]
        let result = await restore(profileWith(("com.vscode", leftHalf)),
                                   options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertFalse(gateway.windowsList[0].isMinimized)
    }

    func testOptedInStillPrefersVisibleWindow() async {
        // 보이는 창이 있으면 최소화 창을 꺼내지 않는다
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [
            window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true),
            window(2, "com.vscode", x: 2000, y: 100, w: 800, h: 600),
        ]
        let result = await restore(profileWith(("com.vscode", leftHalf)),
                                   options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [2])
        XCTAssertTrue(gateway.windowsList[0].isMinimized)
    }

    func testUnminimizeRefusalFallsBackToSkip() async {
        // 앱이 최소화 해제를 거부하면 이동을 시도하지 않고 건너뜀으로 보고한다
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true)]
        gateway.unminimizeFails = true
        let result = await restore(profileWith(("com.vscode", leftHalf)),
                                   options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.minimized))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testUnminimizedFrameIsJudgedFresh() async {
        // Dock에서 나오며 프레임이 바뀌면 열거 스냅샷이 아니라 재판독 프레임으로 판정한다 —
        // 이미 목표 자리로 나왔으면 흔들지 않는다 (F-02.2)
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 2500, y: 500, w: 800, h: 600, minimized: true)]
        gateway.frameOnUnminimize[1] = CGRect(x: 1512, y: 0, width: 1280, height: 1440) // 목표 자리
        let result = await restore(profileWith(("com.vscode", leftHalf)),
                                   options: RestoreOptions(restoreMinimized: true))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.alreadyInPlace))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testWindowAlreadyInPlaceIsNotMoved() async {
        // 불필요한 창 흔들림을 막는다 (F-02.2)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 1514, y: 1, w: 1278, h: 1439)] // 오차 5pt 이내
        let result = await restore(profileWith(("com.chrome", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.alreadyInPlace))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMoveIsVerified() async {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 2000, y: 300, w: 800, h: 600)]
        let result = await restore(profileWith(("com.chrome", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.count, 1)
        XCTAssertEqual(gateway.moveCalls[0].target, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testMinSizeConstraintRetriesOnceThenFails() async {
        // 재시도 1회, 그래도 안 되면 성공한 척하지 않는다 (US-008 AC-3)
        gateway.runningBundleIDs = ["com.tiny"]
        gateway.windowsList = [window(1, "com.tiny", x: 2000, y: 300, w: 1400, h: 600)]
        gateway.moveBehavior = .clampWidth(min: 1400) // 목표 1280보다 큰 최소 폭
        let result = await restore(profileWith(("com.tiny", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(gateway.moveCalls.count, 2)
    }

    func testOneFailureDoesNotStopTheRest() async {
        // 부분 실패에도 계속 진행 (US-008 AC-4)
        gateway.runningBundleIDs = ["com.a", "com.b"]
        gateway.windowsList = [
            window(1, "com.a", x: 2000, y: 300, w: 800, h: 600),
            window(2, "com.b", x: 2100, y: 400, w: 800, h: 600),
        ]
        gateway.perWindowBehavior[1] = .unresponsive
        let rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let result = await restore(profileWith(("com.a", leftHalf), ("com.b", rightHalf)))
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(result.entries[1].outcome, .moved)
        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testBuiltinWindowOfTargetAppIsNotTouched() async {
        // 대상 앱이어도 내장 화면의 창은 그대로 (US-005 AC-2)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 100, y: 100, w: 800, h: 600),  // 내장
            window(2, "com.chrome", x: 2000, y: 300, w: 800, h: 600), // 외장
        ]
        let result = await restore(profileWith(("com.chrome", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [2])
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    func testDisabledAppIsNotRestoredButKept() async {
        // 체크 해제는 복원 제외일 뿐 삭제가 아니다 (US-006 AC-2)
        gateway.runningBundleIDs = ["com.slack"]
        gateway.windowsList = [window(1, "com.slack", x: 2000, y: 300, w: 800, h: 600)]
        var profile = profileWith(("com.slack", leftHalf))
        profile.apps[0].isEnabled = false
        let result = await restore(profile)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testSkipReasonPrefersFullscreenRegardlessOfWindowOrder() async {
        // 창 순서가 불안정해도(부록 3) 사유는 결정적이어야 한다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 1600, y: 0, w: 800, h: 600, minimized: true),
            window(2, "com.chrome", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true),
        ]
        let result = await restore(profileWith(("com.chrome", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.fullscreen))
    }

    func testSilentMoveFailureIsDetected() async {
        // 이동이 에러 없이 조용히 실패해도(부록 1) 검증이 잡아낸다 — 성공한 척 보고하지 않는다
        gateway.runningBundleIDs = ["com.stuck"]
        gateway.windowsList = [window(1, "com.stuck", x: 2000, y: 300, w: 800, h: 600)]
        gateway.moveBehavior = .silentFail
        let result = await restore(profileWith(("com.stuck", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(gateway.moveCalls.count, 2)
    }

    func testResultCarriesScreenID() async {
        // 결과는 어느 화면의 것인지 안다 — 다른 화면 카드에 보여주지 않기 위해 (US-007 AC-5)
        let result = await restore(profileWith(("com.x", leftHalf)))
        XCTAssertEqual(result.screenID, external.id)
    }

    func testWindowOnBuiltinIsPulledBackToExternal() async {
        // 기본 원칙: 저장된 앱의 창은 어디 있든 데려온다 — 연결 해제로 내장에 내려온 창 포함
        // (요구사항 다, US-001 핵심 시나리오)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 100, y: 100, w: 800, h: 600)] // 내장에만 있음
        let result = await restore(profileWith(("com.chrome", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls[0].target, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testRunningAppWithNoWindowsIsSkipped() async {
        // 실행 중인데 표준 창이 하나도 없으면 건너뛴다 — 기본값에선 새 창을 열게 하지 않는다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = []
        let result = await restore(profileWith(("com.chrome", leftHalf)))
        XCTAssertEqual(result.entries[0].outcome, .skipped(.noWindow))
        XCTAssertTrue(gateway.openWindowCalls.isEmpty)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testWindowlessAppOpensWindowAndPlacesItWhenOptedIn() async {
        // 옵션 "창이 없는 앱은 새 창을 열어 복원": openWindow 완료 후 그 창을 배치 (F-02.2 예외)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowOnReopen["com.chrome"] = window(2, "com.chrome", x: 2500, y: 500, w: 800, h: 600)
        let result = await restore(profileWith(("com.chrome", leftHalf)),
                                   options: RestoreOptions(reopenWindowless: true))
        XCTAssertEqual(gateway.openWindowCalls, ["com.chrome"])
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testWindowlessAppStaysSkippedWhenNoWindowAppears() async {
        // 한도까지 창이 안 나타나면 그대로 건너뜀으로 보고한다
        gateway.runningBundleIDs = ["com.chrome"]
        let result = await restore(profileWith(("com.chrome", leftHalf)),
                                   options: RestoreOptions(reopenWindowless: true))
        XCTAssertEqual(gateway.openWindowCalls, ["com.chrome"])
        XCTAssertEqual(result.entries[0].outcome, .skipped(.noWindow))
    }

    func testFingerprintMismatchSkipsScreenWhole() async {
        // UUID는 같은데 지문이 다르면 그 화면은 통째로 건너뛴다 — 오작동 대신 무작동 (F-01.4)
        let mismatched = ScreenInfo(id: external.id, name: external.name, frame: external.frame,
                                    isBuiltin: false,
                                    fingerprint: ScreenFingerprint(vendor: 1, model: 2, serial: 999))
        var profile = profileWith(("com.chrome", leftHalf))
        profile.fingerprint = ScreenFingerprint(vendor: 1, model: 2, serial: 3)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 2000, y: 300, w: 800, h: 600)]

        let results = await RestoreEngine.restore(profiles: [mismatched.id: profile], screens: [mismatched],
                                                  using: gateway)
        XCTAssertEqual(results[0].screenSkipReason, .fingerprintMismatch)
        XCTAssertTrue(results[0].entries.isEmpty)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMultiScreenDedupRestoresSharedAppOnce() async {
        // 같은 앱이 두 프로필에 있으면 식별자 정렬 순서상 첫 화면만 적용한다 (F-01.6, US-003 AC-5)
        let external2 = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                                   frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        let profiles = [
            external.id: profileWith(("com.chrome", leftHalf)),
            external2.id: Profile(screenID: external2.id, screenName: external2.name, apps: [
                TargetApp(bundleID: "com.chrome", displayName: "com.chrome", unitRect: leftHalf),
            ]),
        ]
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 2500, y: 500, w: 800, h: 600),  // ext-1 소속(중심점) — 어질러짐
            window(2, "com.chrome", x: 4500, y: 300, w: 800, h: 600),  // ext-2 소속 — 어질러짐
        ]
        let results = await RestoreEngine.restore(profiles: profiles, screens: [external2, external],
                                                  using: gateway)
        // ext-1(정렬상 첫 화면)만 적용, ext-2는 이미 처리된 앱이라 항목 자체가 빠진다
        XCTAssertEqual(results.map(\.screenID), [external.id, external2.id])
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [1])
        XCTAssertTrue(results[1].entries.isEmpty)
    }
}
