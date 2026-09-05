import PlugbackKit
import SwiftUI

// 설정 창 (F-05.6) — 설정은 카드가 아니라 별도 창이다 (조사 표본 전수 관례).
struct SettingsView: View {
    @ObservedObject var controller: PlugbackController
    private var appearance = CardAppearance()
    @State private var pane: SettingsPane
    @Environment(\.colorScheme) private var systemScheme
    @State private var launchAtLogin = LoginItem.isEnabled
    /// 삭제 확인을 기다리는 프로필 — 되돌릴 수 없는 유일한 명시적 동작이라 한 번 묻는다
    @State private var profileToDelete: Profile?

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
                // 버전은 문의의 첫 질문이다 — Dock 아이콘도 About 창도 없어 여기 말고는 볼 데가 없다
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
                case .profiles: profileSettings
                case .lab: labSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(appearance.palette(systemScheme: systemScheme).accent)
        .preferredColorScheme(appearance.brightness.colorScheme)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
        .confirmationDialog(
            "\(profileToDelete?.screenName ?? "") 프로필을 삭제할까요?",
            isPresented: Binding(get: { profileToDelete != nil },
                                 set: { if !$0 { profileToDelete = nil } }),
            titleVisibility: .visible,
            presenting: profileToDelete
        ) { profile in
            Button("삭제", role: .destructive) { controller.removeProfile(profile.screenID) }
        } message: { profile in
            Text("저장된 앱 \(profile.apps.count)개의 창 위치 기록이 지워집니다. 되돌릴 수 없습니다.")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("시작") {
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LoginItem.set($0) }))
            }
            Section("복원 옵션") {
                Toggle("최소화된 창도 복원", isOn: $controller.restoreMinimized)
                Text("켜면 Dock에 최소화된 창을 꺼내서 저장된 자리로 옮깁니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("창이 없는 앱은 새 창을 열어 복원", isOn: $controller.reopenWindowless)
                Text("켜면 실행 중이지만 창이 없는 앱에 새 창을 열게 한 뒤 저장된 자리로 옮깁니다.\n꺼져 있는 앱을 실행하지는 않습니다. 어떤 창이 열리는지는 앱마다 다릅니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("단축키") {
                Text("복원 단축키는 단축어 앱에서 지정합니다.\n새 단축어 → 동작 추가 → Plugback → \"지금 레이아웃 복원\" → 키보드 단축키 설정")
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

    private var profileSettings: some View {
        Form {
            Section("저장된 프로필") {
                if controller.allProfiles.isEmpty {
                    Text("저장된 프로필이 없습니다")
                        .foregroundStyle(.secondary)
                } else {
                    // 연결되지 않은 화면의 프로필도 보인다 (US-012 AC-1)
                    ForEach(controller.allProfiles, id: \.screenID) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.screenName)
                                Text("저장된 앱 \(profile.apps.count)개 · 복원 대상 \(profile.apps.filter(\.isEnabled).count)개")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("삭제", role: .destructive) { profileToDelete = profile }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var labSettings: some View {
        Form {
            // 실험은 본 설정과 섞지 않는다 — 걷어낼 때 이 구획만 들어내면 된다.
            Section("실험실") {
                Toggle("자동 슬롯", isOn: $controller.labAutoSlot)
                Text("""
                     외장 화면을 쓰는 동안 배치를 기록합니다.
                     복원은 자동·수동 중 더 최근에 저장된 쪽을 씁니다.
                     수동 저장은 영향받지 않습니다 — 끄면 자동 슬롯은 복원에 쓰이지 않습니다.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
                Picker("자동 슬롯 반영", selection: $controller.autoSlotUpdateMode) {
                    ForEach(AutoSlotUpdateMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!controller.labAutoSlot)
                Text(controller.autoSlotUpdateMode.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

private extension AutoSlotUpdateMode {
    var title: String {
        switch self {
        case .onDisconnect: "분리할 때 저장"
        case .immediate: "변경 즉시 저장"
        case .liveUntilDisconnect: "복원 즉시 반영 · 분리 시 저장"
        }
    }

    var detail: String {
        switch self {
        case .onDisconnect:
            "변경을 모아두고 화면을 분리하거나 Plugback을 종료할 때 저장합니다. 그전 복원은 마지막 저장값을 씁니다."
        case .immediate:
            "배치가 바뀔 때마다 자동 슬롯에 바로 저장하고, 그 값을 복원에 씁니다."
        case .liveUntilDisconnect:
            "현재 연결 중에는 방금 감지한 배치를 복원에 바로 사용합니다.\n파일에는 화면을 분리하거나 Plugback을 종료할 때 저장합니다."
        }
    }
}

enum SettingsPane: String, CaseIterable {
    case appearance, general, profiles, lab

    var title: String {
        switch self {
        case .appearance: "모양"
        case .general: "일반"
        case .profiles: "프로필"
        case .lab: "실험실"
        }
    }

    var detail: String {
        switch self {
        case .appearance: "레이아웃과 색상을 각각 골라 보세요."
        case .general: "실행 방식과 복원 옵션을 설정합니다."
        case .profiles: "화면별로 저장된 앱과 배치를 관리합니다."
        case .lab: "자동 배치 기록과 반영 방식을 설정합니다."
        }
    }
}
