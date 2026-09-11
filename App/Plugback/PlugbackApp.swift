import AppKit
import PlugbackKit
import SwiftUI

@main
struct PlugbackApp: App {
    @NSApplicationDelegateAdaptor(PlugbackAppDelegate.self) private var appDelegate

    // 관찰은 자식 뷰들의 일 — App 씬은 인스턴스만 건넨다
    private let controller: PlugbackController

    init() {
#if DEBUG
        // 호스트 유닛 테스트는 실제 창 감시·자동 복원을 시작하지 않는다.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        controller = (SpaceProbe.isRequested || isTesting)
            ? SpaceProbe.placeholderController : AppServices.controller
#else
        controller = AppServices.controller
#endif
    }

    var body: some Scene {
#if DEBUG
        MenuBarExtra("Plugback Debug", image: "MenuBarGlyphDebug") {
            MenuBarCard(controller: controller)
        }
        .menuBarExtraStyle(.window)
#else
        MenuBarExtra("Plugback", image: "MenuBarGlyph") {
            MenuBarCard(controller: controller)
        }
        .menuBarExtraStyle(.window)
#endif

        // 「복원 확인」 상세 창 — 사용자가 「창 확인 필요 N개」를 눌렀을 때만 연다 (3.8절).
        Window("복원 확인", id: RestoreConfirmationView.windowID) {
            RestoreConfirmationView(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 480)

        Settings {
            SettingsView(controller: controller)
        }
    }
}

/// 정상 종료 전 저장 (4.4절). 저장에 실패하면 종료를 취소하고 재시도·저장 없이 종료를 묻는다.
/// `applicationWillTerminate`는 반환 뒤 종료되므로 판정은 여기서 끝낸다.
@MainActor
final class PlugbackAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        guard SpaceProbe.isRequested else { return }
        if SpaceProbe.isWatchRequested {
            SpaceProbe.startWatching()
        } else {
            SpaceProbe.runAndTerminate()
        }
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
#if DEBUG
        if SpaceProbe.isRequested { return .terminateNow }
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isTesting { return .terminateNow }
#endif
        let controller = AppServices.controller
        while true {
            switch controller.prepareForTermination() {
            case .proceed:
                return .terminateNow
            case .saveFailed:
                let alert = NSAlert()
                alert.messageText = CardPresentation.terminationSaveFailedTitle
                alert.informativeText = CardPresentation.terminationSaveFailedMessage
                alert.addButton(withTitle: "다시 시도")
                alert.addButton(withTitle: "저장하지 않고 종료")
                alert.addButton(withTitle: "취소")
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn: continue
                case .alertSecondButtonReturn: return .terminateNow
                default: return .terminateCancel
                }
            }
        }
    }
}
