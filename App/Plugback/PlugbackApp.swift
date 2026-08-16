import PlugbackKit
import SwiftUI

@main
struct PlugbackApp: App {
    @StateObject private var controller = PlugbackController(gateway: AXWindowGateway(),
                                                             screenProvider: SystemScreenProvider(),
                                                             store: ProfileStore())

    var body: some Scene {
        // ponytail: 글리프는 SF Symbol 플레이스홀더. BRANDING.md의 커스텀 템플릿 이미지로 교체 예정.
        MenuBarExtra("Plugback", systemImage: "display") {
            MenuBarCard(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
