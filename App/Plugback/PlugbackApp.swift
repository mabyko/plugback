import PlugbackKit
import SwiftUI

@main
struct PlugbackApp: App {
    @ObservedObject private var controller = AppServices.controller

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
