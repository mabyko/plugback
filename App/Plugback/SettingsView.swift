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
            }
            Section("단축키") {
                Text("복원 단축키는 단축어 앱에서 지정합니다.\n새 단축어 → 동작 추가 → Plugback → \"지금 레이아웃 복원\" → 키보드 단축키 설정")
                    .font(.caption).foregroundStyle(.secondary)
                Button("단축어 앱 열기") {
                    NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 400)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}
