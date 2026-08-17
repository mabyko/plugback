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
        // 반환값이 곧 결과다 — published 상태에서 추론하지 않는다
        switch await AppServices.controller.restoreNow() {
        case .notAuthorized:
            return .result(dialog: "손쉬운 사용 권한이 필요합니다. 메뉴바에서 Plugback을 여세요.")
        case .notConnected:
            return .result(dialog: "외장 화면이 연결되어 있지 않습니다.")
        case .alreadyRestoring:
            return .result(dialog: "이미 복원 중입니다.")
        case .restored(let results):
            guard !results.isEmpty else { return .result(dialog: "복원할 프로필이 없습니다.") }
            let moved = results.map(\.movedCount).reduce(0, +)
            let skipped = results.map(\.skippedCount).reduce(0, +)
            let failed = results.map(\.failedCount).reduce(0, +)
            return .result(dialog: "이동 \(moved) · 건너뜀 \(skipped) · 실패 \(failed)")
        }
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
