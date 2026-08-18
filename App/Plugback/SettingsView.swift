import PlugbackKit
import SwiftUI

// 설정 창 (F-05.6) — 설정은 카드가 아니라 별도 창이다 (조사 표본 전수 관례).
struct SettingsView: View {
    @ObservedObject var controller: PlugbackController
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
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
                Button("단축어 앱 열기") {
                    NSWorkspace.shared.open(URL(string: "shortcuts://")!)
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 400)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}
