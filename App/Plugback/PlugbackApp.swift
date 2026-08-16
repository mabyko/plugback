import PlugbackKit
import SwiftUI

@main
struct PlugbackApp: App {
    @StateObject private var controller = PlugbackController(gateway: AXWindowGateway(),
                                                             screenProvider: SystemScreenProvider(),
                                                             store: ProfileStore())

    var body: some Scene {
        MenuBarExtra("Plugback", image: "MenuBarGlyph") {
            MenuBarCard(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
