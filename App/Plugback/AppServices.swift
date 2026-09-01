import Foundation
import PlugbackKit

/// 앱 전역 서비스 — 컨트롤러 인스턴스를 UI 씬과 App Intent가 공유한다.
@MainActor
enum AppServices {
    static let controller: PlugbackController = {
        // 같은 어댑터가 두 인터페이스를 만족한다 — AX는 여전히 이 어댑터 안뿐이다.
        let ax = AXWindowGateway()
        let spaceReader: SpaceReading? = SpaceReader()
#if DEBUG
        let store = ProfileStore(directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plugback Debug", isDirectory: true))
#else
        let store = ProfileStore()
#endif
        let controller = PlugbackController(gateway: ax,
                                            screenProvider: SystemScreenProvider(),
                                            store: store,
                                            moveSource: ax,
                                            spaceReader: spaceReader)
        controller.authorizationCheck = { PermissionGate.isTrusted }
        controller.checkAuthorization() // 첫 카드가 열리기 전에도 상태가 맞도록
        controller.startWatching()
        LoginItem.registerOnFirstLaunchIfNeeded()
        return controller
    }()
}
