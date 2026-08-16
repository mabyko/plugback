import SwiftUI

// 카드 5존 뼈대 (docs/ARCHITECTURE.md MenuBarUI).
// 권한 미승인이면 카드를 통째로 교체한다 — 정상 카드에 배너를 얹지 않는다.
struct MenuBarCard: View {
    @State private var trusted = PermissionGate.isTrusted

    var body: some View {
        Group {
            if trusted {
                CardSkeleton()
            } else {
                PermissionOnboarding(recheck: { trusted = PermissionGate.isTrusted })
            }
        }
        .frame(width: 296)
        // 카드를 열 때마다 권한을 재확인한다 (US-010 AC-3: 재시작 없이 반영)
        .onAppear { trusted = PermissionGate.isTrusted }
    }
}

// 액션·목록의 상하 순서는 미결(프로토타입 A/B) — M5에서 결정. 지금은 A(목록 위) 순서.
private struct CardSkeleton: View {
    // ponytail: M1 검증 ②(결과 스트립 유무에 따른 카드 높이 변화)용 가짜 토글. M2에서 실제 복원 결과로 교체.
    @State private var debugShowResult = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            zone {
                HStack(alignment: .firstTextBaseline) {
                    Text("외장 화면 없음").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("프로필 없음").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if debugShowResult {
                Divider()
                zone {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("방금 자동 복원 · 이동 2 · 건너뜀 1 · 실패 0")
                            .font(.system(size: 12)).monospacedDigit()
                        Text("⚠ Chrome — 전체화면이라 건너뜀")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            zone {
                Text("대상 앱이 없습니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            zone {
                HStack(spacing: 8) {
                    Button("💾 지금 레이아웃 저장") {}.disabled(true)
                    Button("⚡ 지금 레이아웃 복원") {}.disabled(true)
                }
            }
            Divider()
            zone {
                HStack(spacing: 12) {
                    Toggle("자동 복원", isOn: .constant(true))
                        .toggleStyle(.switch).controlSize(.mini).disabled(true)
                    Spacer()
                    #if DEBUG
                    Button("결과±") { withAnimation { debugShowResult.toggle() } }
                        .font(.system(size: 11))
                    #endif
                    Button("종료") { NSApp.terminate(nil) }.font(.system(size: 12))
                }
            }
        }
    }

    private func zone(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// 권한 없음 전용 화면 (US-010). 시스템 프롬프트는 띄우지 않는다 — 조용한 유틸리티.
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
