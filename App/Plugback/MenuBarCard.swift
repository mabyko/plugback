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

// 액션은 목록 위(프로토타입 변형 B, 2026-09 확정) — 목록은 늘고 스크롤되므로 아래 두면 버튼 위치가
// 내용 따라 움직인다. 위에 두면 메뉴바 바로 아래 고정이라 손이 먼저 닿고, 저장 확인 문구도 그 버튼 밑에 붙는다.
private struct Card: View {
    @ObservedObject var controller: PlugbackController
    /// 앱 목록의 실측 콘텐츠 높이 — ScrollView는 이상 높이를 ≈0으로 보고해
    /// MenuBarExtra(.window)가 목록을 통째로 접는다. 실측으로 명시적 높이를 잡는다.
    @State private var listHeight: CGFloat = 0
    /// 목록 스크롤 캡 — 글자 크기에 비례해 같은 줄 수가 보이게 한다
    @ScaledMetric(relativeTo: .callout) private var listCap: CGFloat = 320

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
                    .font(.callout)
                }
            }
            // 연결된 모든 화면의 결과를 합산한다 — 두 번째 화면의 실패 사유도 여기서 보인다.
            // 지문 불일치로 통째 건너뛴 화면은 lastResults가 이미 뺐다 — 그건 위 경고 배너의 몫이다.
            if controller.isConnected, !controller.lastResults.isEmpty {
                Divider()
                resultStrip(controller.lastResults)
            }
            Divider()
            actions
            Divider()
            appList
            Divider()
            footer
        }
    }

    // 빈 상태에서도 카드는 비지 않는다 — 문구는 CardPresentation의 것, 여기는 배치와 색뿐
    private var header: some View {
        zone {
            HStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.body.weight(.medium))
                    // 주황은 연결됨의 신호 — 기억만·없음이면 회색. 배지 문구와 같은 말을 색으로도 한다.
                    .foregroundStyle(controller.isConnected ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text(CardPresentation.headerTitle(for: controller.screenPresence))
                    .font(.headline)
                Spacer()
                if let badge = CardPresentation.headerBadge(for: controller.screenPresence,
                                                           hasProfile: controller.hasRestorableProfile) {
                    Text(badge.text)
                        .font(.caption.weight(.medium))
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
    private func storeNotice(_ notice: ProfileStore.Trouble) -> some View {
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
                    .font(.callout)
                    HStack(spacing: 8) {
                        Button("백업 파일 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                        }
                        Button("확인") { controller.dismissStoreNotice() }
                    }
                    .font(.subheadline)
                case .unreadable:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("프로필 파일을 읽지 못해 이번 실행에서는 저장하지 않습니다.\n파일을 지키기 위해 덮어쓰기를 막았습니다 — 재시작하면 다시 시도합니다.")
                    }
                    .font(.callout)
                    Button("확인") { controller.dismissStoreNotice() }
                        .font(.subheadline)
                case .writeFailed:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("프로필을 저장하지 못했습니다.\n기존 프로필과 저장 대기 중인 배치는 그대로 두었습니다 — 다음 저장 때 다시 시도합니다.")
                    }
                    .font(.callout)
                    Button("확인") { controller.dismissStoreNotice() }
                        .font(.subheadline)
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
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("마지막 복원").fontWeight(.medium)
                            Spacer()
                            // 결과는 앱이 도는 동안 남는다 — 시각이 없으면 어제 결과가 방금 복원으로 읽힌다
                            if let at = controller.lastRestoredAt {
                                Text(CardPresentation.relative(at)).foregroundStyle(.secondary)
                            }
                        }
                        Text("이동 \(moved) · 건너뜀 \(skipped) · 실패 \(failed)").monospacedDigit()
                    }
                }
                .font(.callout)
                // 건너뜀·실패는 이유를 보여준다 — "왜 안 옮겨졌지?"의 유일한 답 (US-008).
                // 모든 화면의 결과를 편평하게 — 같은 앱은 중복 제거(F-01.6)로 한 화면에만 온다.
                ForEach(results, id: \.screenID) { result in
                    ForEach(result.entries.filter { $0.outcome != .moved }, id: \.bundleID) { entry in
                        // 실패만 붉다 — 건너뜀과 같은 회색이면 "실패 1"을 세어 읽어야 한다
                        let failed = entry.outcome == .failed
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: CardPresentation.symbolName(for: entry.outcome))
                                .foregroundStyle(failed ? Color.red : Color.secondary)
                                .accessibilityHidden(true)
                            Text("\(entry.displayName) — \(CardPresentation.describe(entry.outcome))")
                                .foregroundStyle(failed ? Color.primary : Color.secondary)
                        }
                        .font(.callout)
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
                    .font(.callout).foregroundStyle(.secondary)
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
                .frame(height: min(max(listHeight, 1), listCap))
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
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
                    .font(.callout).foregroundStyle(.secondary)
            }
            // 실험실 — 이 화면의 복원 소스. 이기는 슬롯은 화면마다 다를 수 있어 섹션에 붙는다.
            if controller.labAutoSlot, let slot = section.restoreSource {
                Text(CardPresentation.sourceLabel(
                    slot: slot, savedAt: section.profile?.savedAt,
                    pending: section.usesPendingSource
                ))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !controller.labAutoSlot, section.spaceConfigurationDiffers {
                Text(CardPresentation.manualSpaceConfigurationDifference)
                    .font(.subheadline).foregroundStyle(.tertiary)
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
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                if let status = CardPresentation.spaceGroupStatus(
                    for: group.kind, guide: group.guide
                ) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)

            if let guide = group.guide {
                Text(CardPresentation.spaceGuide(guide))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if group.apps.isEmpty {
                Text("저장된 앱 없음")
                    .font(.subheadline)
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
                   isRunning: isRunning(app.bundleID),
                   setTracked: { tracked in
                       Task { await controller.setTracked(app.bundleID, tracked, on: section.screenID) }
                   },
                   remove: {
                       Task { await controller.remove(app.bundleID, on: section.screenID) }
                   })
        }
    }

    /// 실행 여부는 AppKit에 묻는다 — 손쉬운 사용 권한도 폴링도 필요 없다.
    /// 카드를 열면 컨트롤러가 상태를 다시 공개하므로 그때 함께 다시 계산된다.
    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// 저장하지 않는 앱 — 껐던 대상 앱과 그 화면 프로필에 없는 앱이 같은 칸에 온다.
    /// 체크박스의 뜻은 위 묶음과 같다: 「이 앱을 다루나」. 프로필 소속 여부는 내부 사정이다.
    @ViewBuilder private func untrackedRows(for section: PlugbackController.ScreenSection) -> some View {
        if !section.untrackedApps.isEmpty {
            Divider().padding(.top, 4)
            Text(CardPresentation.untrackedHeader)
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(section.untrackedApps, id: \.bundleID) { app in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { false },
                        set: { tracked in Task { await controller.setTracked(app.bundleID, tracked, on: section.screenID) } }
                    )) {
                        Text(app.displayName).font(.callout).foregroundStyle(.secondary)
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
                .padding(.vertical, 3) // 위 묶음의 행과 같은 높이
            }
        }
    }

    private var actions: some View {
        zone {
            VStack(alignment: .leading, spacing: 6) {
                // 강조는 지금 할 수 있는 일을 따라간다 — 프로필이 없으면 저장이 유일한 다음 행동이고,
                // 그때 비활성 주황 복원 버튼은 못 누르는 쪽으로 눈을 끈다.
                let canSave = controller.isConnected && !controller.isRestoring && !controller.isSaveBlocked
                // 어느 화면에든 프로필이 있으면 복원할 수 있다 — 첫 화면만 보던 판정은 뒷 화면을 잠갔다
                let canRestore = controller.isConnected && controller.hasRestorableProfile && !controller.isRestoring
                HStack(spacing: 8) {
                    if controller.hasRestorableProfile {
                        saveButton(enabled: canSave, prominent: false).buttonStyle(.bordered)
                        restoreButton(enabled: canRestore, prominent: true).buttonStyle(.borderedProminent)
                    } else {
                        saveButton(enabled: canSave, prominent: true).buttonStyle(.borderedProminent)
                        restoreButton(enabled: canRestore, prominent: false).buttonStyle(.bordered)
                    }
                }
                .controlSize(.regular)
                if let notice = controller.captureNotice {
                    // 성공과 Space 관찰 실패 중 실제 마지막 결과 하나만 보여준다.
                    Text(CardPresentation.captureNotice(notice))
                        .font(.subheadline).foregroundStyle(.orange)
                }
                // 저장 금지는 알림을 닫아도 남는다 — 수동 저장도 막히므로 실험실과 무관하게 표시한다.
                // 복원 소스(지금 복원되는 값)는 화면마다 다를 수 있어 각 섹션에 붙고,
                // 여기는 수집(뽑을 때 저장될 값)의 전역 상태 한 줄이다.
                // 소스와 한 줄로 뭉치면 "수집됨"이 "저장됨"으로 읽힌다.
                if controller.isSaveBlocked {
                    Text(CardPresentation.saveBlockedStatus)
                        .font(.subheadline).foregroundStyle(.orange)
                } else if controller.labAutoSlot {
                    Text(CardPresentation.pendingLabel(collectedAt: controller.lastCollectedAt,
                                                       hasPending: controller.hasPendingCollect,
                                                       spaceConfigurationChanged:
                                                           controller.spaceConfigurationDiffers))
                        .font(.subheadline).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // 글자색은 라벨 안쪽에 건다 — 강조 스타일은 바깥의 foregroundStyle을 무시하고 흰 글자를 쓴다
    private func saveButton(enabled: Bool, prominent: Bool) -> some View {
        Button { Task { await controller.captureNow() } } label: {
            Label("지금 레이아웃 저장", systemImage: "tray.and.arrow.down")
                .frame(maxWidth: .infinity)
                .modifier(DarkOnAmber(on: prominent && enabled))
        }
        .disabled(!enabled)
    }

    private func restoreButton(enabled: Bool, prominent: Bool) -> some View {
        Button { Task { await controller.restoreNow() } } label: {
            Group {
                // 복원은 AX 호출·재시도로 몇 초 걸릴 수 있다 — 비활성만으로는 멈춘 것과 구별되지 않는다
                if controller.isRestoring {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("복원 중…")
                    }
                } else {
                    Label("지금 레이아웃 복원", systemImage: "arrow.counterclockwise")
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(DarkOnAmber(on: prominent && enabled))
        }
        .disabled(!enabled)
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
                Button("종료") { NSApp.terminate(nil) }.font(.callout)
                    .keyboardShortcut("q")
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
    let isRunning: Bool
    let setTracked: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { app.isEnabled }, set: setTracked)) {
                Text(app.displayName).font(.callout)
            }
            .toggleStyle(.checkbox)
            Spacer()
            // 복원 전에 「꺼져 있어 건너뜀」이 될 앱을 미리 알린다 — "아무 일도 안 일어남"의 원인 1위다.
            if !isRunning {
                Text(CardPresentation.notRunningLabel)
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3) // 행 간격을 클릭 영역 안으로 — 15pt 글줄만으로는 표적이 좁다
        .contentShape(Rectangle()) // 빈 곳을 눌러도 같은 행 — 컨텍스트 메뉴가 글자 위에서만 열리지 않게
        .contextMenu {
            Button("프로필에서 삭제", role: .destructive) { remove() }
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
            .font(.callout)
            .keyboardShortcut(",")
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
        .font(.callout)
        .keyboardShortcut(",")
    }
}

/// 앰버 강조 버튼의 글자 — 흰 글자는 앰버 위에서 대비가 모자라 검게 쓴다.
/// 비활성이면 바탕이 회색이라 손대지 않는다 — 고정한 검은 글자는 다크 모드에서 사라진다.
private struct DarkOnAmber: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.foregroundStyle(Color.black.opacity(0.82)) } else { content }
    }
}

// 권한 없음 전용 화면 (US-010). 시스템 프롬프트는 사용자가 버튼을 눌렀을 때만.
private struct PermissionOnboarding: View {
    let recheck: () -> Void
    @ScaledMetric(relativeTo: .title) private var badgeSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.14))
                Image(systemName: "display")
                    .font(.title.weight(.medium))
                    .foregroundStyle(.orange)
            }
            .frame(width: badgeSize, height: badgeSize)
            .accessibilityHidden(true)
            Text("손쉬운 사용 권한이 필요합니다")
                .font(.headline)
            Text("창을 읽고 옮기려면 이 권한 하나만 필요합니다.\n화면 기록 권한은 요구하지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { PermissionGate.requestPermission() } label: {
                Label("시스템 설정 열기", systemImage: "gearshape")
            }
                .keyboardShortcut(.defaultAction)
            HStack {
                Button("다시 확인") { recheck() }.font(.callout)
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.font(.callout)
                    .keyboardShortcut("q")
            }
        }
        .padding(20)
    }
}
