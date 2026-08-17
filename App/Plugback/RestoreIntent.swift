import AppIntents
import PlugbackKit

/// 복원 동작의 시스템 노출 (F-05.5). 단축어·Spotlight·자동화·외부 런처가 이 동사를 실행한다.
/// 기본 단축키는 없다 — 사용자가 단축어 앱에서 지정한다.
struct RestoreLayoutIntent: AppIntent {
    static let title: LocalizedStringResource = "지금 레이아웃 복원"
    static let description = IntentDescription("저장된 프로필대로 대상 앱의 창을 복원합니다. 프로필에 없는 창은 건드리지 않습니다.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 반환값이 곧 결과다 — published 상태에서 추론하지 않는다. 문구 분기는 CardPresentation의 것.
        let outcome = await AppServices.controller.restoreNow()
        return .result(dialog: "\(CardPresentation.intentDialog(for: outcome))")
    }
}

/// 사용자 설정 없이도 Spotlight·Siri에 바로 나타나게 한다.
struct PlugbackShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RestoreLayoutIntent(),
                    phrases: ["\(.applicationName) 복원", "Restore \(.applicationName)"],
                    shortTitle: "레이아웃 복원",
                    systemImageName: "macwindow.on.rectangle")
    }
}
