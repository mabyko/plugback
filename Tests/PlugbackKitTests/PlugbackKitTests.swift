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

final class RestoreEngineTests: XCTestCase {
    private var gateway: FakeWindowGateway!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
    }

    private func profileWith(_ apps: (String, UnitRect)...) -> Profile {
        Profile(screenID: external.id, screenName: external.name,
                apps: apps.map { TargetApp(bundleID: $0.0, displayName: $0.0, unitRect: $0.1) })
    }

    private let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1)

    func testClosedAppIsSkippedAndNotLaunched() {
        // 꺼둔 앱은 건너뛰고 실행하지 않는다 (US-004 AC-1)
        let profile = profileWith(("com.slack", leftHalf))
        let result = RestoreEngine.restore(profile: profile, on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .skipped(.appNotRunning))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testFullscreenWindowIsLeftAlone() {
        // 전체화면은 해제하지 않고 건너뛴다 (US-004 AC-3)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true)]
        let result = RestoreEngine.restore(profile: profileWith(("com.chrome", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .skipped(.fullscreen))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMinimizedWindowIsLeftAlone() {
        // 최소화는 복구하지 않는다 (US-004 AC-4)
        gateway.runningBundleIDs = ["com.vscode"]
        gateway.windowsList = [window(1, "com.vscode", x: 1600, y: 0, w: 800, h: 600, minimized: true)]
        let result = RestoreEngine.restore(profile: profileWith(("com.vscode", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .skipped(.minimized))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testWindowAlreadyInPlaceIsNotMoved() {
        // 불필요한 창 흔들림을 막는다 (F-02.2)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 1514, y: 1, w: 1278, h: 1439)] // 오차 5pt 이내
        let result = RestoreEngine.restore(profile: profileWith(("com.chrome", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .skipped(.alreadyInPlace))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testMoveIsVerified() {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 2000, y: 300, w: 800, h: 600)]
        let result = RestoreEngine.restore(profile: profileWith(("com.chrome", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.count, 1)
        XCTAssertEqual(gateway.moveCalls[0].target, CGRect(x: 1512, y: 0, width: 1280, height: 1440))
    }

    func testMinSizeConstraintRetriesOnceThenFails() {
        // 재시도 1회, 그래도 안 되면 성공한 척하지 않는다 (US-008 AC-3)
        gateway.runningBundleIDs = ["com.tiny"]
        gateway.windowsList = [window(1, "com.tiny", x: 2000, y: 300, w: 1400, h: 600)]
        gateway.moveBehavior = .clampWidth(min: 1400) // 목표 1280보다 큰 최소 폭
        let result = RestoreEngine.restore(profile: profileWith(("com.tiny", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(gateway.moveCalls.count, 2)
    }

    func testOneFailureDoesNotStopTheRest() {
        // 부분 실패에도 계속 진행 (US-008 AC-4)
        gateway.runningBundleIDs = ["com.a", "com.b"]
        gateway.windowsList = [
            window(1, "com.a", x: 2000, y: 300, w: 800, h: 600),
            window(2, "com.b", x: 2100, y: 400, w: 800, h: 600),
        ]
        gateway.perWindowBehavior[1] = .unresponsive
        let rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let result = RestoreEngine.restore(profile: profileWith(("com.a", leftHalf), ("com.b", rightHalf)),
                                           on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(result.entries[1].outcome, .moved)
        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testBuiltinWindowOfTargetAppIsNotTouched() {
        // 대상 앱이어도 내장 화면의 창은 그대로 (US-005 AC-2)
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 100, y: 100, w: 800, h: 600),  // 내장
            window(2, "com.chrome", x: 2000, y: 300, w: 800, h: 600), // 외장
        ]
        let result = RestoreEngine.restore(profile: profileWith(("com.chrome", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .moved)
        XCTAssertEqual(gateway.moveCalls.map(\.windowID), [2])
        XCTAssertEqual(gateway.windowsList[0].frame, CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    func testDisabledAppIsNotRestoredButKept() {
        // 체크 해제는 복원 제외일 뿐 삭제가 아니다 (US-006 AC-2)
        gateway.runningBundleIDs = ["com.slack"]
        gateway.windowsList = [window(1, "com.slack", x: 2000, y: 300, w: 800, h: 600)]
        var profile = profileWith(("com.slack", leftHalf))
        profile.apps[0].isEnabled = false
        let result = RestoreEngine.restore(profile: profile, on: external, using: gateway)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }

    func testSkipReasonPrefersFullscreenRegardlessOfWindowOrder() {
        // 창 순서가 불안정해도(부록 3) 사유는 결정적이어야 한다
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [
            window(1, "com.chrome", x: 1600, y: 0, w: 800, h: 600, minimized: true),
            window(2, "com.chrome", x: 1512, y: 0, w: 2560, h: 1440, fullscreen: true),
        ]
        let result = RestoreEngine.restore(profile: profileWith(("com.chrome", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .skipped(.fullscreen))
    }

    func testSilentMoveFailureIsDetected() {
        // 이동이 에러 없이 조용히 실패해도(부록 1) 검증이 잡아낸다 — 성공한 척 보고하지 않는다
        gateway.runningBundleIDs = ["com.stuck"]
        gateway.windowsList = [window(1, "com.stuck", x: 2000, y: 300, w: 800, h: 600)]
        gateway.moveBehavior = .silentFail
        let result = RestoreEngine.restore(profile: profileWith(("com.stuck", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .failed)
        XCTAssertEqual(gateway.moveCalls.count, 2)
    }

    func testResultCarriesScreenID() {
        // 결과는 어느 화면의 것인지 안다 — 다른 화면 카드에 보여주지 않기 위해 (US-007 AC-5)
        let result = RestoreEngine.restore(profile: profileWith(("com.x", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.screenID, external.id)
    }

    func testRunningAppWithNoWindowOnThisScreenIsSkipped() {
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [window(1, "com.chrome", x: 100, y: 100, w: 800, h: 600)] // 내장에만 있음
        let result = RestoreEngine.restore(profile: profileWith(("com.chrome", leftHalf)), on: external, using: gateway)
        XCTAssertEqual(result.entries[0].outcome, .skipped(.noWindowOnScreen))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
    }
}
