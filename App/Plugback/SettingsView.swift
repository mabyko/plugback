import PlugbackKit
import SwiftUI

// 설정 창 (F-05.6) — 설정은 카드가 아니라 별도 창이다 (조사 표본 전수 관례).
struct SettingsView: View {
    @ObservedObject var controller: PlugbackController
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("plugback")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("꽂으면, 제자리로")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

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
                                    Text("대상 앱 \(profile.apps.count)개")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("삭제", role: .destructive) {
                                    controller.removeProfile(profile.screenID)
                                }
                            }
                        }
                    }
                }
                Section("일반") {
                    Toggle("로그인 시 자동 실행", isOn: Binding(
                        get: { launchAtLogin },
                        set: { launchAtLogin = $0; LoginItem.set($0) }))
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
                // 실험은 본 설정과 섞지 않는다 — 걷어낼 때 이 구획만 들어내면 된다.
                Section("실험실") {
                    Toggle("자동 슬롯", isOn: $controller.labAutoSlot)
                    Text("""
                         외장 화면을 쓰는 동안 배치를 기록하고, 화면을 분리할 때 자동 슬롯에 저장합니다.
                         복원은 자동·수동 중 더 최근에 저장된 쪽을 씁니다.
                         수동 저장은 영향받지 않습니다 — 끄면 자동 슬롯은 복원에 쓰이지 않습니다.
                         """)
                        .font(.caption).foregroundStyle(.secondary)
#if DEBUG
                    Toggle("일반 Space 자체 복원", isOn: $controller.labSpaceRelocation)
                        .disabled(!controller.labAutoSlot)
                    Text("저장된 일반 Space가 다른 화면에 남으면 Mission Control을 열어 외장 화면으로 되돌립니다. 자동 슬롯이 켜져 있을 때만 동작합니다.")
                        .font(.caption).foregroundStyle(.secondary)
#endif
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440, height: 480)
        .tint(.orange)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}
