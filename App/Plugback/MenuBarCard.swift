import PlugbackKit
import SwiftUI

// 카드 7존 — 고정 5존(헤더·결과 스트립·앱 목록·액션·푸터) + 조건부 2존(저장소 알림·지문 불일치 경고)
// (docs/ARCHITECTURE.md MenuBarUI). UI 문구는 CONTEXT.md 용어 그대로, 은유 금지.
// 권한 미승인이면 카드를 통째로 교체한다 — 정상 카드에 배너를 얹지 않는다.
struct MenuBarCard: View {
    @ObservedObject var controller: PlugbackController

    var body: some View {
        Group {
            if controller.isAuthorized {
                Card(controller: controller)
            } else {
                // 시스템 프롬프트 열기(requestPermission)만 앱의 일 — 판정은 컨트롤러에 바인딩
                PermissionOnboarding(recheck: { controller.checkAuthorization() })
            }
        }
        .frame(width: 320)
        .tint(.orange)
        // 카드를 열 때마다 권한·화면·프로필을 재확인한다 (US-010 AC-3)
        .onAppear { Task { await controller.cardOpened() } }
    }
}

// 액션·목록의 상하 순서는 미결(프로토타입 A/B) — M5에서 결정. 지금은 A(목록 위) 순서.
private struct Card: View {
    @ObservedObject var controller: PlugbackController
    /// 앱 목록의 실측 콘텐츠 높이 — ScrollView는 이상 높이를 ≈0으로 보고해
    /// MenuBarExtra(.window)가 목록을 통째로 접는다. 실측으로 명시적 높이를 잡는다.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = controller.storeNotice {
                Divider()
                storeNotice(notice)
            }
            if controller.identityMismatch {
                Divider()
                zone {
                    // UUID는 맞는데 지문이 다름 — 잘못된 화면에 옮기는 대신 아무것도 안 했다 (F-01.4)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("화면 정보가 저장 당시와 달라 복원하지 않았습니다.\n지금 배치가 맞다면 저장을 다시 눌러 갱신하세요.")
                            .foregroundStyle(.primary)
                    }
                    .font(.system(size: 12))
                }
            }
            // 연결된 모든 화면의 결과를 합산한다 — 두 번째 화면의 실패 사유도 여기서 보인다.
            // 지문 불일치로 통째 건너뛴 화면은 lastResults가 이미 뺐다 — 그건 위 경고 배너의 몫이다.
            if controller.isConnected, !controller.lastResults.isEmpty {
                Divider()
                resultStrip(controller.lastResults)
            }
            Divider()
            appList
            Divider()
            actions
            Divider()
            footer
        }
    }

    // 빈 상태에서도 카드는 비지 않는다 — 문구는 CardPresentation의 것, 여기는 배치와 색뿐
    private var header: some View {
        zone {
            HStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(CardPresentation.headerTitle(for: controller.screenPresence))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let badge = CardPresentation.headerBadge(for: controller.screenPresence,
                                                           hasProfile: controller.hasRestorableProfile) {
                    Text(badge.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(badge.highlighted ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            badge.highlighted ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                }
            }
        }
    }

    // 저장소 문제를 조용히 넘기지 않는다 (F-04.2). 확인하면 배너는 사라진다.
    private func storeNotice(_ notice: ProfileStore.LoadOutcome.Trouble) -> some View {
        zone {
            VStack(alignment: .leading, spacing: 4) {
                switch notice {
                case .corruptionBackedUp(let backupURL):
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("프로필 파일이 손상되어 초기화했습니다")
                    }
                    .font(.system(size: 12))
                    HStack(spacing: 8) {
                        Button("백업 파일 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                        }
                        Button("확인") { controller.dismissStoreNotice() }
                    }
                    .font(.system(size: 11))
                case .unreadable:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("프로필 파일을 읽지 못해 이번 실행에서는 저장하지 않습니다.\n파일을 지키기 위해 덮어쓰기를 막았습니다 — 재시작하면 다시 시도합니다.")
                    }
                    .font(.system(size: 12))
                    Button("확인") { controller.dismissStoreNotice() }
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func resultStrip(_ results: [RestoreResult]) -> some View {
        zone {
            VStack(alignment: .leading, spacing: 4) {
                let moved = results.map(\.movedCount).reduce(0, +)
                let skipped = results.map(\.skippedCount).reduce(0, +)
                let failed = results.map(\.failedCount).reduce(0, +)
                HStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("마지막 복원 · 이동 \(moved) · 건너뜀 \(skipped) · 실패 \(failed)")
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                // 건너뜀·실패는 이유를 보여준다 — "왜 안 옮겨졌지?"의 유일한 답 (US-008).
                // 모든 화면의 결과를 편평하게 — 같은 앱은 중복 제거(F-01.6)로 한 화면에만 온다.
                ForEach(results, id: \.screenID) { result in
                    ForEach(result.entries.filter { $0.outcome != .moved }, id: \.bundleID) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "exclamationmark.circle")
                                .accessibilityHidden(true)
                            Text("\(entry.displayName) — \(CardPresentation.describe(entry.outcome))")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // 연결된 모든 화면의 섹션을 다 그린다 — 첫 화면만 보여주면 뒷 화면의 앱이 사라진 것처럼 보인다.
    private var appList: some View {
        zone {
            let sections = controller.sections
            if !controller.isConnected, !sections.contains(where: { $0.profile?.apps.isEmpty == false }) {
                Text("외장 화면을 연결하면 그 화면의 프로필대로\n복원할 수 있습니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                // 앱이 많으면 목록 부분만 스크롤된다 — 카드 전체가 화면을 넘지 않게.
                // maxHeight만 두면 MenuBarExtra가 목록을 최소 높이로 접어 아무것도 안 보인다 —
                // 콘텐츠 실측 높이로 명시적 높이를 잡고, 캡(320)을 넘을 때만 스크롤한다.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        let titles = CardPresentation.sectionTitles(names: sections.map(\.name))
                        ForEach(Array(zip(sections, titles)), id: \.0.id) { section, title in
                            screenSection(section, title: title, showTitle: sections.count > 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), 320))
            }
        }
    }

    /// 화면 하나의 섹션 — 그 화면의 프로필 앱, 저장하지 않는 앱, (실험실) 복원 소스.
    /// 화면이 하나면 제목을 생략한다 — 헤더가 이미 그 이름이다.
    @ViewBuilder
    private func screenSection(_ section: PlugbackController.ScreenSection,
                               title: String, showTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTitle {
                Text(title)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            if let profile = section.profile, !profile.apps.isEmpty {
                if section.spaceGroups.isEmpty {
                    appRows(profile.apps.filter(\.isEnabled), in: section)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(section.spaceGroups) { group in
                            spaceGroup(group, in: section)
                        }
                    }
                }
            } else if controller.isConnected {
                Text("창을 원하는 자리에 배치한 뒤 저장을 누르면\n여기에 대상 앱이 나타납니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            // 실험실 — 이 화면의 복원 소스. 이기는 슬롯은 화면마다 다를 수 있어 섹션에 붙는다.
            if controller.labAutoSlot, let slot = section.restoreSource {
                Text(CardPresentation.sourceLabel(
                    slot: slot, savedAt: section.profile?.savedAt,
                    pending: section.usesPendingSource
                ))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !controller.labAutoSlot, section.spaceConfigurationDiffers {
                Text(CardPresentation.manualSpaceConfigurationDifference)
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            untrackedRows(for: section)
        }
    }

    private func spaceGroup(
        _ group: PlugbackController.SpaceGroup,
        in section: PlugbackController.ScreenSection
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(CardPresentation.spaceGroupTitle(for: group.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                if let status = CardPresentation.spaceGroupStatus(for: group.kind) {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)

            if group.apps.isEmpty {
                Text("저장된 앱 없음")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                appRows(group.apps, in: section)
            }
        }
    }

    @ViewBuilder
    private func appRows(
        _ apps: [TargetApp],
        in section: PlugbackController.ScreenSection
    ) -> some View {
        // 체크된 앱만 위에 — 중요한 것이 위에 고정되고 나머지는 아래로 간다.
        ForEach(apps, id: \.bundleID) { app in
            AppRow(app: app,
                   prediction: section.predictions[app.bundleID],
                   setTracked: { tracked in
                       Task { await controller.setTracked(app.bundleID, tracked, on: section.screenID) }
                   },
                   remove: {
                       Task { await controller.remove(app.bundleID, on: section.screenID) }
                   })
        }
    }

    /// 저장하지 않는 앱 — 껐던 대상 앱과 그 화면 프로필에 없는 앱이 같은 칸에 온다.
    /// 체크박스의 뜻은 위 묶음과 같다: 「이 앱을 다루나」. 프로필 소속 여부는 내부 사정이다.
    @ViewBuilder private func untrackedRows(for section: PlugbackController.ScreenSection) -> some View {
        if !section.untrackedApps.isEmpty {
            Divider().padding(.top, 4)
            Text(CardPresentation.untrackedHeader)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(section.untrackedApps, id: \.bundleID) { app in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { false },
                        set: { tracked in Task { await controller.setTracked(app.bundleID, tracked, on: section.screenID) } }
                    )) {
                        Text(app.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    if section.profile?.apps.contains(where: { $0.bundleID == app.bundleID }) == true {
                        Spacer(minLength: 0)
                        Button {
                            Task { await controller.remove(app.bundleID, on: section.screenID) }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("프로필에서 삭제")
                        .accessibilityLabel("\(app.displayName) 프로필에서 삭제")
                    }
                }
            }
        }
    }

    private var actions: some View {
        zone {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button { Task { await controller.captureNow() } } label: {
                        Label("지금 레이아웃 저장", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(
                        !controller.isConnected || controller.isRestoring
                            || controller.isSaveBlocked
                    )
                    // 어느 화면에든 프로필이 있으면 복원할 수 있다 — 첫 화면만 보던 판정은 뒷 화면을 잠갔다
                    Button { Task { await controller.restoreNow() } } label: {
                        Label("지금 레이아웃 복원", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Color.black.opacity(0.82))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                        .disabled(!controller.isConnected || !controller.hasRestorableProfile || controller.isRestoring)
                }
                if let count = controller.lastCaptureCount {
                    // 저장됐다는 것을 화면에서 확인할 수 있다 (US-002 AC-1)
                    Text("저장됨 · 대상 앱 \(count)개")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                // 저장 금지는 알림을 닫아도 남는다 — 수동 저장도 막히므로 실험실과 무관하게 표시한다.
                // 복원 소스(지금 복원되는 값)는 화면마다 다를 수 있어 각 섹션에 붙고,
                // 여기는 수집(뽑을 때 저장될 값)의 전역 상태 한 줄이다.
                // 소스와 한 줄로 뭉치면 "수집됨"이 "저장됨"으로 읽힌다.
                if controller.isSaveBlocked {
                    Text(CardPresentation.saveBlockedStatus)
                        .font(.system(size: 11)).foregroundStyle(.orange)
                } else if controller.labAutoSlot {
                    Text(CardPresentation.pendingLabel(collectedAt: controller.lastCollectedAt,
                                                       hasPending: controller.hasPendingCollect,
                                                       spaceConfigurationChanged:
                                                           controller.spaceConfigurationDiffers))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
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

    private func zone(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct AppRow: View {
    let app: TargetApp
    /// nil = 아직 계산 안 됐거나 이번 회차 결과 없음 — "모름"을 지어내지 않고 점을 그리지 않는다
    let prediction: RestorePrediction?
    let setTracked: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { app.isEnabled }, set: setTracked)) {
                Text(app.displayName).font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            Spacer()
            // 점은 엔진의 복원 예측을 그린다 — 스타일·문구 매핑은 CardPresentation의 것
            if let prediction {
                dot(for: prediction).frame(width: 7, height: 7)
                Text(CardPresentation.dotLabel(for: prediction))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("프로필에서 삭제", role: .destructive) { remove() }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private func dot(for prediction: RestorePrediction) -> some View {
        switch CardPresentation.dotStyle(for: prediction) {
        case .filled: Circle().fill(Color.orange)
        case .off: Circle().fill(Color.secondary.opacity(0.4))
        case .hollow: Circle().strokeBorder(Color.orange, lineWidth: 1.5)
        }
    }
}

// 설정 창 열기 — macOS 13은 셀렉터 경로, 14+는 공식 환경 액션.
private struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            ModernSettingsButton()
        } else {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("설정", systemImage: "gearshape")
            }
            .font(.system(size: 12))
        }
    }
}

@available(macOS 14.0, *)
private struct ModernSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            Label("설정", systemImage: "gearshape")
        }
        .font(.system(size: 12))
    }
}

// 권한 없음 전용 화면 (US-010). 시스템 프롬프트는 사용자가 버튼을 눌렀을 때만.
private struct PermissionOnboarding: View {
    let recheck: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.14))
                Image(systemName: "display")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.orange)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            Text("손쉬운 사용 권한이 필요합니다")
                .font(.system(size: 14, weight: .semibold))
            Text("창을 읽고 옮기려면 이 권한 하나만 필요합니다.\n화면 기록 권한은 요구하지 않습니다.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { PermissionGate.requestPermission() } label: {
                Label("시스템 설정 열기", systemImage: "gearshape")
            }
                .keyboardShortcut(.defaultAction)
            HStack {
                Button("다시 확인") { recheck() }.font(.system(size: 12))
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.font(.system(size: 12))
            }
        }
        .padding(20)
    }
}
