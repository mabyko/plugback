import Foundation
import ServiceManagement

// 로그인 항목 — 얇은 유틸로 유지한다. 모듈로 키우지 않는다 (docs/ARCHITECTURE.md).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        // 실패는 조용히 넘긴다 — 설정 창을 다시 열면 실제 상태로 보정된다.
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    /// 첫 실행 시 기본값 켬 (F-06.3). 사용자가 껐다면 다시 켜지 않는다.
    static func registerOnFirstLaunchIfNeeded() {
        // 개발 빌드는 제외 — DerivedData 경로의 앱이 로그인 항목에 등록되는 것을 막는다.
        #if !DEBUG
        let key = "didConfigureLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
        #endif
    }
}
