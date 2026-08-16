import PlugbackKit

/// 앱 전역 서비스 — 컨트롤러 인스턴스를 UI 씬과 App Intent가 공유한다.
@MainActor
enum AppServices {
    static let controller: PlugbackController = {
        let controller = PlugbackController(gateway: AXWindowGateway(),
                                            screenProvider: SystemScreenProvider(),
                                            store: ProfileStore())
        controller.isAuthorized = { PermissionGate.isTrusted }
        controller.startWatching()
        LoginItem.registerOnFirstLaunchIfNeeded()
        return controller
    }()
}
