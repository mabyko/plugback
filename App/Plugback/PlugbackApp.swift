import PlugbackKit
import SwiftUI

@main
struct PlugbackApp: App {
    // 관찰은 자식 뷰들의 일 — App 씬은 인스턴스만 건넨다
    private let controller = AppServices.controller

    var body: some Scene {
        MenuBarExtra("Plugback", image: "MenuBarGlyph") {
            MenuBarCard(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
    }
}
