import PlugbackKit
import SwiftUI

// 카드 5존 (docs/ARCHITECTURE.md MenuBarUI). UI 문구는 CONTEXT.md 용어 그대로, 은유 금지.
// 권한 미승인이면 카드를 통째로 교체한다 — 정상 카드에 배너를 얹지 않는다.
struct MenuBarCard: View {
    @ObservedObject var controller: PlugbackController
    @State private var trusted = PermissionGate.isTrusted

    var body: some View {
        Group {
            if trusted {
                Card(controller: controller)
            } else {
                PermissionOnboarding(recheck: { trusted = PermissionGate.isTrusted })
            }
        }
        .frame(width: 296)
        // 카드를 열 때마다 권한·화면·프로필을 재확인한다 (US-010 AC-3)
        .onAppear {
            trusted = PermissionGate.isTrusted
            controller.cardOpened()
        }
    }
}

// 액션·목록의 상하 순서는 미결(프로토타입 A/B) — M5에서 결정. 지금은 A(목록 위) 순서.
private struct Card: View {
    @ObservedObject var controller: PlugbackController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let backupURL = controller.corruptionBackupURL {
                Divider()
                corruptionNotice(backupURL)
            }
            if controller.identityMismatch {
                Divider()
                zone {
                    // UUID는 맞는데 지문이 다름 — 잘못된 화면에 옮기는 대신 아무것도 안 했다 (F-01.4)
                    Text("⚠ 화면 정보가 저장 당시와 달라 복원하지 않았습니다.\n지금 배치가 맞다면 저장을 다시 눌러 갱신하세요.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            if let result = controller.lastResult, result.screenSkipReason == nil,
               controller.isConnected, result.screenID == controller.currentScreen?.id {
                Divider()
                resultStrip(result)
            }
            Divider()
            appList
            Divider()
            actions
            Divider()
            footer
        }
    }

    // 빈 상태에서도 카드는 비지 않는다 — 마지막 화면과 프로필 유무를 남긴다 (ARCHITECTURE 고정 결정)
    private var header: some View {
        let name = controller.currentScreen?.name ?? "외장 화면 없음"
        let extra = controller.isConnected && controller.connectedScreenCount > 1
            ? " 외 \(controller.connectedScreenCount - 1)대" : ""
        return zone {
            HStack(alignment: .firstTextBaseline) {
                Text(name + extra)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if controller.isConnected {
                    Text(controller.profile == nil ? "프로필 없음" : "프로필 있음")
                        .font(.system(size: 11))
                        .foregroundStyle(controller.profile == nil ? Color.secondary : Color.orange)
                } else if controller.currentScreen != nil {
                    Text("연결 해제됨").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // 손상 복구를 조용히 넘기지 않는다 (F-04.2: 백업 후 초기화하고 사용자에게 알린다)
    private func corruptionNotice(_ backupURL: URL) -> some View {
        zone {
            VStack(alignment: .leading, spacing: 4) {
                Text("프로필 파일이 손상되어 초기화했습니다")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                Button("백업 파일 보기") {
                    NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                }
                .font(.system(size: 11))
            }
        }
    }

    private func resultStrip(_ result: RestoreResult) -> some View {
        zone {
            VStack(alignment: .leading, spacing: 4) {
                Text("마지막 복원 · 이동 \(result.movedCount) · 건너뜀 \(result.skippedCount) · 실패 \(result.failedCount)")
                    .font(.system(size: 12)).monospacedDigit()
                // 건너뜀·실패는 이유를 보여준다 — "왜 안 옮겨졌지?"의 유일한 답 (US-008)
                ForEach(result.entries.filter { $0.outcome != .moved }, id: \.bundleID) { entry in
                    Text("⚠ \(entry.displayName) — \(describe(entry.outcome))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appList: some View {
        zone {
            if let profile = controller.profile, !profile.apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(profile.apps, id: \.bundleID) { app in
                        AppRow(app: app,
                               isRunning: controller.runningBundleIDs.contains(app.bundleID),
                               hasWindow: controller.windowedBundleIDs.contains(app.bundleID),
                               setEnabled: { controller.setAppEnabled(app.bundleID, $0) },
                               remove: { controller.removeApp(app.bundleID) })
                    }
                }
            } else if controller.isConnected {
                Text("창을 원하는 자리에 배치한 뒤 저장을 누르면\n여기에 대상 앱이 나타납니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("외장 화면을 연결하면 그 화면의 프로필대로\n복원할 수 있습니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        zone {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("💾 지금 레이아웃 저장") { controller.captureNow() }
                        .disabled(!controller.isConnected)
                    Button("⚡ 지금 레이아웃 복원") { Task { await controller.restoreNow() } }
                        .disabled(!controller.isConnected || controller.profile == nil || controller.isRestoring)
                }
                if let count = controller.lastCaptureCount {
                    // 저장됐다는 것을 화면에서 확인할 수 있다 (US-002 AC-1)
                    Text("저장됨 · 대상 앱 \(count)개")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
    }

    private var footer: some View {
        zone {
            HStack(spacing: 12) {
                Toggle("자동 복원", isOn: Binding(
                    get: { controller.restoreMode == .automatic },
                    set: { controller.restoreMode = $0 ? .automatic : .manual }))
                    .toggleStyle(.switch).controlSize(.mini)
                Spacer()
                SettingsButton()
                Button("종료") { NSApp.terminate(nil) }.font(.system(size: 12))
            }
        }
    }

    private func describe(_ outcome: RestoreResult.Outcome) -> String {
        switch outcome {
        case .moved: return "이동"
        case .failed: return "이동 실패"
        case .skipped(.appNotRunning): return "꺼져 있어 건너뜀"
        case .skipped(.fullscreen): return "전체화면이라 건너뜀"
        case .skipped(.minimized): return "최소화되어 건너뜀"
        case .skipped(.alreadyInPlace): return "이미 제자리"
        case .skipped(.noWindow): return "창이 없어 건너뜀"
        }
    }

    private func zone(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct AppRow: View {
    let app: TargetApp
    let isRunning: Bool
    let hasWindow: Bool
    let setEnabled: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { app.isEnabled }, set: setEnabled)) {
                Text(app.displayName).font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            Spacer()
            // 점은 "복원하면 옮겨질까"를 답한다: 찬 주황=예, 빈 주황=실행 중이나 창 없음, 회색=꺼짐
            dot.frame(width: 7, height: 7)
            Text(isRunning ? (hasWindow ? "실행 중" : "창 없음") : "꺼짐")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("프로필에서 삭제", role: .destructive) { remove() }
        }
    }

    @ViewBuilder private var dot: some View {
        if !isRunning {
            Circle().fill(Color.secondary.opacity(0.4))
        } else if hasWindow {
            Circle().fill(Color.orange)
        } else {
            Circle().strokeBorder(Color.orange, lineWidth: 1.5)
        }
    }
}

// 설정 창 열기 — macOS 13은 셀렉터 경로, 14+는 공식 환경 액션.
private struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            ModernSettingsButton()
        } else {
            Button("설정") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .font(.system(size: 12))
        }
    }
}

@available(macOS 14.0, *)
private struct ModernSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("설정") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .font(.system(size: 12))
    }
}

// 권한 없음 전용 화면 (US-010). 시스템 프롬프트는 사용자가 버튼을 눌렀을 때만.
private struct PermissionOnboarding: View {
    let recheck: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 28)).foregroundStyle(.secondary)
            Text("손쉬운 사용 권한이 필요합니다")
                .font(.system(size: 13, weight: .semibold))
            Text("창을 읽고 옮기려면 이 권한 하나만 필요합니다.\n화면 기록 권한은 요구하지 않습니다.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("시스템 설정 열기") { PermissionGate.requestPermission() }
                .keyboardShortcut(.defaultAction)
            HStack {
                Button("다시 확인") { recheck() }.font(.system(size: 12))
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.font(.system(size: 12))
            }
        }
        .padding(16)
    }
}
