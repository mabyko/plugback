import PlugbackKit
import SwiftUI

@main
struct PlugbackApp: App {
#if DEBUG
    @NSApplicationDelegateAdaptor(SpaceProbeAppDelegate.self) private var spaceProbeDelegate
#endif

    // 관찰은 자식 뷰들의 일 — App 씬은 인스턴스만 건넨다
    private let controller: PlugbackController

    init() {
#if DEBUG
        controller = SpaceProbe.isRequested ? SpaceProbe.placeholderController : AppServices.controller
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

        Settings {
            SettingsView(controller: controller)
        }
    }
}
