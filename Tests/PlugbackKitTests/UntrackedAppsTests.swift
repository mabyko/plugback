import XCTest
@testable import PlugbackKit

/// 「대상 아님」 행의 선정 규칙. 저장이 잡아갈 창과 **같은 규칙**이어야 한다 —
/// 어긋나면 「추가」를 눌렀는데 아무 일도 안 일어나는 행이 생긴다.
@MainActor
final class UntrackedAppsTests: XCTestCase {
    private let screen = ScreenInfo(id: "ext-1", name: "LG",
                                    frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let builtin = ScreenInfo(id: "builtin", name: "내장",
                                     frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: true)

    private func window(_ id: Int, _ bundleID: String, _ frame: CGRect,
                        minimized: Bool = false, fullscreen: Bool = false, hidden: Bool = false) -> WindowInfo {
        WindowInfo(id: id, appBundleID: bundleID, appName: bundleID, frame: frame,
                   isFullscreen: fullscreen, isMinimized: minimized, isHidden: hidden)
    }

    private let onScreen = CGRect(x: 1100, y: 100, width: 400, height: 400)
    private let onBuiltin = CGRect(x: 100, y: 100, width: 400, height: 400)

    func testListsAppsOnThisScreenThatAreNotTargets() {
        let result = PlugbackController.untracked(
            in: [window(1, "com.chrome", onScreen), window(2, "com.linear", onScreen)],
            on: screen, excluding: ["com.chrome"])

        XCTAssertEqual(result.map(\.bundleID), ["com.linear"])
    }

    func testIgnoresWindowsOnAnotherScreen() {
        // 중심점 규칙 (F-03.2) — 내장 화면의 창은 이 제품이 다루지 않는다.
        let result = PlugbackController.untracked(
            in: [window(1, "com.linear", onBuiltin)], on: screen, excluding: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testIgnoresMinimizedAndFullscreen() {
        // 저장이 안 잡아가는 창이다 — 보여주면 「추가」가 무동작이 된다.
        let result = PlugbackController.untracked(
            in: [window(1, "com.a", onScreen, minimized: true),
                 window(2, "com.b", onScreen, fullscreen: true)],
            on: screen, excluding: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testIgnoresHiddenApps() {
        // ⌘H로 숨긴 앱 — 창 좌표는 화면에 남지만 사용자에겐 없는 창이다. 저장도 안 잡아간다 (F-03.2).
        let result = PlugbackController.untracked(
            in: [window(1, "com.discord", onScreen, hidden: true)], on: screen, excluding: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testOneRowPerApp() {
        let result = PlugbackController.untracked(
            in: [window(1, "com.linear", onScreen), window(2, "com.linear", onScreen)],
            on: screen, excluding: [])
        XCTAssertEqual(result.count, 1)
    }

    func testNothingWithoutAConnectedExternalScreen() {
        XCTAssertTrue(PlugbackController.untracked(
            in: [window(1, "com.linear", onScreen)], on: nil, excluding: []).isEmpty)
        XCTAssertTrue(PlugbackController.untracked(
            in: [window(1, "com.linear", onBuiltin)], on: builtin, excluding: []).isEmpty)
    }
}
