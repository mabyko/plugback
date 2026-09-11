import PlugbackKit
import SwiftUI

// 설정 창 (F-05.6) — 설정은 카드가 아니라 별도 창이다 (조사 표본 전수 관례).
struct SettingsView: View {
    @ObservedObject var controller: PlugbackController
    private var appearance = CardAppearance()
    @State private var pane: SettingsPane
    @Environment(\.colorScheme) private var systemScheme
    @State private var launchAtLogin = LoginItem.isEnabled
    /// 삭제 확인을 기다리는 작업 환경 — 되돌릴 수 없는 유일한 명시적 동작이라 한 번 묻는다
    @State private var workspaceToDelete: PlugbackController.WorkspaceSummary?
    @State private var exportError: String?

    init(controller: PlugbackController, initialPane: SettingsPane = .appearance,
         store: UserDefaults? = nil) {
        self.controller = controller
        appearance = CardAppearance(store: store)
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plugback 설정")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text(pane.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.version)
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            Picker("설정 항목", selection: $pane) {
                ForEach(SettingsPane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20).padding(.vertical, 12)

            Group {
                switch pane {
                case .appearance:
                    Form {
                        AppearanceSection(layout: appearance.$layout, colors: appearance.$colors,
                                          brightness: appearance.$brightness)
                    }
                    .formStyle(.grouped)
                case .general: generalSettings
                case .workspaces: workspaceSettings
                case .lab: labSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(appearance.palette(systemScheme: systemScheme).accent)
        .preferredColorScheme(appearance.brightness.colorScheme)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
        .confirmationDialog(
            "\(workspaceToDelete.map(Self.workspaceTitle) ?? "") 기록을 삭제할까요?",
            isPresented: Binding(get: { workspaceToDelete != nil },
                                 set: { if !$0 { workspaceToDelete = nil } }),
            titleVisibility: .visible,
            presenting: workspaceToDelete
        ) { workspace in
            Button("삭제", role: .destructive) { controller.removeWorkspace(workspace.key) }
        } message: { workspace in
            Text("앱 \(workspace.appCount)개 · 창 위치 기록 \(workspace.windowCount)개가 지워집니다. 되돌릴 수 없습니다.")
        }
    }

    static func workspaceTitle(_ workspace: PlugbackController.WorkspaceSummary) -> String {
        workspace.screens.map(CardPresentation.screenName).joined(separator: " + ")
    }

    private var generalSettings: some View {
        Form {
            Section("시작") {
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LoginItem.set($0) }))
            }
            Section("저장") {
                Toggle("자동 저장", isOn: $controller.autoSave)
                Text("작업 중 배치를 저장 대기 이력으로 모아 두었다가, 화면을 추가·분리해 작업 환경을 떠날 때와 Plugback을 종료할 때 저장합니다.\n복원은 수동·자동 구분 없이 마지막으로 저장이 완료된 배치를 씁니다. 끄면 저장 대기 이력을 버리고 마지막 저장본은 그대로 둡니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("복원 옵션") {
                Toggle("최소화된 창도 복원", isOn: $controller.restoreMinimized)
                Text("켜면 Dock에 최소화된 창을 꺼내서 저장된 자리로 옮깁니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("단축키") {
                Text("복원 단축키는 단축어 앱에서 지정합니다. 단축어는 실행 전 잠금 해제를 요구합니다.\n새 단축어 → 동작 추가 → Plugback → \"지금 레이아웃 복원\" → 키보드 단축키 설정")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                } label: {
                    Label("단축어 앱 열기", systemImage: "command")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var workspaceSettings: some View {
        Form {
            if controller.migratedFromLegacy {
                Section {
                    Text(CardPresentation.migrationNotice).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("저장된 작업 환경") {
                if controller.allWorkspaces.isEmpty {
                    Text("저장된 작업 환경이 없습니다")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.allWorkspaces) { workspace in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.workspaceTitle(workspace))
                                Text("앱 \(workspace.appCount)개 · 복원 대상 \(workspace.enabledAppCount)개 · 창 위치 \(workspace.windowCount)개"
                                     + (workspace.savedBy.map { " · " + CardPresentation.sourceLabel(savedBy: $0, savedAt: workspace.savedAt) } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("삭제", role: .destructive) { workspaceToDelete = workspace }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var labSettings: some View {
        Form {
            // 실험은 본 설정과 섞지 않는다 — 걷어낼 때 이 구획만 들어내면 된다. 모든 실험실 설정은 최초 OFF다.
            Section("종료된 앱 다시 열기") {
                Toggle("종료된 앱 다시 열기", isOn: $controller.reopenClosedApps)
                Text("다른 작업 환경이나 연결 해제 중에 닫힌 것으로 확인한 창의 앱이 꺼져 있으면 실행한 뒤 배치합니다.\n이 작업 환경에서 닫은 창의 자리는 다음 저장까지 채우지 않고, 닫힌 시점을 알 수 없는 창은 열지 않습니다. 탭·문서 내용은 복구하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("실행 중인 앱 창 되살리기", isOn: $controller.reviveWindowlessApps)
                    .disabled(!controller.reopenClosedApps)
                Text("앱은 실행 중인데 창이 하나도 없으면 기본 창 하나를 열게 합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("부족한 창 추가로 열기", isOn: $controller.openMissingWindows)
                    .disabled(!controller.reopenClosedApps)
                Text("창이 하나 이상 있는데 저장한 자리보다 적으면 부족한 만큼 새 창을 열게 합니다. 어떤 창이 열리는지는 앱마다 다릅니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if !controller.reopenClosedApps && (controller.reviveWindowlessApps || controller.openMissingWindows) {
                    Text("「종료된 앱 다시 열기」가 꺼져 있어 아래 선택은 지금 동작하지 않습니다. 선택값은 유지됩니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("창 대응") {
                Toggle("복원할 창 직접 지정", isOn: $controller.directWindowAssignment)
                Text("같은 앱의 창 여러 개 중 어느 창을 어느 자리에 놓을지 구별하기 어려우면, 자동 배정 대신 「복원 확인」 창에서 직접 고릅니다.\n꺼져 있으면 전체 이동 거리가 가장 짧은 배치를 자동으로 고릅니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("진단") {
                Text("창 확인 실패·잠금 판정 실패 사례를 최근 \(controller.diagnostics.events.count)건 로컬에만 보관합니다. 창 제목·탭·문서 내용은 기록하지 않으며 자동으로 보내지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("진단 기록 내보내기…") { exportDiagnostics() }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "plugback-diagnostics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.exportDiagnostics(to: url)
            exportError = nil
        } catch {
            exportError = "내보내지 못했습니다: \(error.localizedDescription)"
        }
    }
}

private extension SettingsView {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

enum SettingsPane: String, CaseIterable {
    case appearance, general, workspaces, lab

    var title: String {
        switch self {
        case .appearance: "모양"
        case .general: "일반"
        case .workspaces: "작업 환경"
        case .lab: "실험실"
        }
    }

    var detail: String {
        switch self {
        case .appearance: "레이아웃과 색상을 각각 골라 보세요."
        case .general: "실행 방식, 자동 저장과 복원 옵션을 설정합니다."
        case .workspaces: "외장 화면 조합별로 저장된 앱과 창 위치를 관리합니다."
        case .lab: "종료된 앱 다시 열기와 창 직접 지정을 실험합니다. 모두 기본 꺼짐입니다."
        }
    }
}
