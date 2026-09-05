import PlugbackKit
import SwiftUI

// 카드 7존 — 고정 5존(헤더·결과 스트립·앱 목록·액션·푸터) + 조건부 2존(저장소 알림·지문 불일치 경고)
// (docs/ARCHITECTURE.md MenuBarUI). UI 문구는 CONTEXT.md 용어 그대로, 은유 금지.
// 권한 미승인이면 카드를 통째로 교체한다 — 정상 카드에 배너를 얹지 않는다.
struct MenuBarCard: View {
    @ObservedObject var controller: PlugbackController
    private var appearance = CardAppearance()
    @Environment(\.colorScheme) private var systemScheme

    init(controller: PlugbackController) {
        self.controller = controller
    }

    var body: some View {
        let palette = appearance.palette(systemScheme: systemScheme)
        Group {
            if controller.isAuthorized {
                Card(controller: controller, layout: appearance.layout, palette: palette)
            } else {
                // 시스템 프롬프트 열기(requestPermission)만 앱의 일 — 판정은 컨트롤러에 바인딩
                PermissionOnboarding(palette: palette, recheck: { controller.checkAuthorization() })
            }
        }
        .modifier(CardSurface(layout: appearance.layout, palette: palette))
        .preferredColorScheme(appearance.brightness.colorScheme)
        // 카드를 열 때마다 권한·화면·프로필을 재확인한다 (US-010 AC-3)
        .onAppear { Task { await controller.cardOpened() } }
    }
}

// 액션은 목록 위(프로토타입 변형 B, 2026-09 확정) — 목록은 늘고 스크롤되므로 아래 두면 버튼 위치가
// 내용 따라 움직인다. 위에 두면 메뉴바 바로 아래 고정이라 손이 먼저 닿고, 저장 확인 문구도 그 버튼 밑에 붙는다.
struct Card: View {
    @ObservedObject var controller: PlugbackController
    let layout: CardLayout
    let palette: CardPalette
    /// 목록 스크롤 캡 — 글자 크기에 비례해 같은 줄 수가 보이게 한다
    @ScaledMetric(relativeTo: .callout) private var listCap: CGFloat = 320
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 21
    @ScaledMetric(relativeTo: .headline) private var compactTitleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .title) private var displaySize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, layout == .comfortable ? 8 : layout == .grouped ? 6 : layout == .command ? 1 : 4)
                .background(layout == .command ? palette.soft : palette.background)
            if let notice = controller.storeNotice {
                separator
                storeNotice(notice)
            }
            if controller.identityMismatch {
                separator
                zone {
                    // UUID는 맞는데 지문이 다름 — 잘못된 화면에 옮기는 대신 아무것도 안 했다 (F-01.4)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("화면 정보가 저장 당시와 달라 복원하지 않았습니다.\n지금 배치가 맞다면 저장을 다시 눌러 갱신하세요.")
                            .foregroundStyle(palette.text)
                    }
                    .font(.callout)
                }
            }
            if layout == .command { separator }
            actions
            if layout == .compact || layout == .command { separator }
            if layout == .comfortable { paperSummary }
            appList
            // 연결된 모든 화면의 결과를 합산한다 — 두 번째 화면의 실패 사유도 여기서 보인다.
            // 지문 불일치로 통째 건너뛴 화면은 lastResults가 이미 뺐다 — 그건 위 경고 배너의 몫이다.
            // 버튼(다음 행동) 아래, 목록 다음에 둔다 — 결과는 참고 정보라 맨 아래가 맞다.
            if controller.isConnected, !controller.lastResults.isEmpty {
                if layout != .grouped { separator }
                zone {
                    CardResultStrip(results: controller.lastResults,
                                    restoredAt: controller.lastRestoredAt, palette: palette)
                }
                .background(layout == .grouped ? palette.background : palette.soft)
            }
            separator
            footer
        }
        .font(.body)
    }

    private var separator: some View {
        palette.border.frame(height: 1).accessibilityHidden(true)
    }

    private var targetCount: Int {
        controller.sections.reduce(0) { $0 + ($1.profile?.apps.filter(\.isEnabled).count ?? 0) }
    }

    // 헤더·목록 밀도는 layout, 색은 palette만 따른다. 어느 쪽도 다른 설정을 바꾸지 않는다.
    @ViewBuilder private var header: some View {
        switch layout {
        case .compact:
            zone {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { displaySymbol; screenTitle; Spacer(); headerBadge }
                    profileSummary
                }
            }
        case .comfortable:
            zone {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        displaySymbol.font(.system(size: displaySize))
                        Spacer()
                        headerBadge
                    }
                    Text(CardPresentation.headerTitle(for: controller.screenPresence))
                        .font(.system(size: titleSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("꽂으면, 제자리로.")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
            }
        case .command:
            zone {
                VStack(alignment: .leading, spacing: 8) {
                    Text("plugback / 외장 화면")
                        .font(.caption).foregroundStyle(palette.secondary)
                    HStack(spacing: 8) { displaySymbol; screenTitle; Spacer(); headerBadge }
                }
            }
            .background(palette.soft)
        case .grouped:
            zone {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("plugback").font(.subheadline.weight(.semibold))
                        Spacer()
                        headerBadge
                    }
                    HStack(spacing: 12) {
                        displaySymbol.font(.title)
                        VStack(alignment: .leading, spacing: 4) { screenTitle; profileSummary }
                    }
                }
            }
        }
    }

    private var displaySymbol: some View {
        Image(systemName: "display")
            .foregroundStyle(controller.isConnected ? palette.accent : palette.secondary)
            .accessibilityHidden(true)
    }

    private var screenTitle: some View {
        Text(CardPresentation.headerTitle(for: controller.screenPresence))
            .font(.system(size: compactTitleSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var profileSummary: some View {
        Text("\(controller.hasRestorableProfile ? "프로필 있음" : "프로필 없음") · 대상 앱 \(targetCount)개")
            .font(.subheadline).foregroundStyle(palette.secondary)
    }

    private var paperSummary: some View {
        VStack(spacing: 15) {
            separator
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(targetCount)").font(.title3.weight(.semibold))
                    Text("대상 앱").font(.caption).foregroundStyle(palette.secondary)
                }
                let spaceCount = controller.sections.reduce(0) { total, section in
                    total + section.spaceGroups.filter {
                        if case .regular = $0.kind { return true }
                        return false
                    }.count
                }
                if spaceCount > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(spaceCount)").font(.title3.weight(.semibold))
                        Text("저장된 Space").font(.caption).foregroundStyle(palette.secondary)
                    }
                }
                Text(controller.hasRestorableProfile ? "프로필 있음" : "프로필 없음")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, layout.inset).padding(.top, 9).padding(.bottom, 18)
    }

    @ViewBuilder private var headerBadge: some View {
        if let badge = CardPresentation.headerBadge(for: controller.screenPresence,
                                                   hasProfile: controller.hasRestorableProfile) {
            HStack(spacing: 5) {
                Circle().fill(controller.isConnected ? Color.green : palette.secondary)
                    .frame(width: 5, height: 5).accessibilityHidden(true)
                Text(controller.isConnected ? "연결됨" : badge.text)
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
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

    // 연결된 모든 화면의 섹션을 다 그린다 — 첫 화면만 보여주면 뒷 화면의 앱이 사라진 것처럼 보인다.
    private var appList: some View {
        Group {
            let sections = controller.sections
            if !controller.isConnected, !sections.contains(where: { $0.profile?.apps.isEmpty == false }) {
                Text("외장 화면을 연결하면 그 화면의 프로필대로\n복원할 수 있습니다")
                    .font(.callout).foregroundStyle(palette.secondary)
            } else {
                // 앱이 많으면 목록 부분만 스크롤된다 — 카드 전체가 화면을 넘지 않게.
                // maxHeight만 두면 MenuBarExtra가 목록을 최소 높이로 접어 아무것도 안 보인다 —
                // 콘텐츠 실측 높이로 명시적 높이를 잡고, 캡(320)을 넘을 때만 스크롤한다.
                CardScrollView(maxHeight: listCap) {
                    VStack(alignment: .leading, spacing: 12) {
                        let titles = CardPresentation.sectionTitles(names: sections.map(\.name))
                        ForEach(Array(zip(sections, titles)), id: \.0.id) { section, title in
                            screenSection(section, title: title, showTitle: sections.count > 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, layout == .grouped ? 13 : layout.inset)
        .padding(.top, layout == .comfortable || layout == .grouped ? 0 : 7)
        .padding(.bottom, layout == .comfortable ? 20 : 14)
    }

    /// 화면 하나의 섹션 — 그 화면의 프로필 앱, 저장하지 않는 앱, (실험실) 복원 소스.
    /// 화면이 하나면 제목을 생략한다 — 헤더가 이미 그 이름이다.
    @ViewBuilder
    private func screenSection(_ section: PlugbackController.ScreenSection,
                               title: String, showTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTitle {
                Text(title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
            }
            if let profile = section.profile, !profile.apps.isEmpty {
                if section.spaceGroups.isEmpty {
                    VStack(spacing: 0) {
                        appRows(profile.apps.filter(\.isEnabled), in: section)
                    }
                    .padding(layout == .grouped ? 12 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(layout == .grouped ? palette.surface : Color.clear,
                                in: RoundedRectangle(cornerRadius: 11))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(section.spaceGroups) { group in
                            spaceGroup(group, in: section)
                        }
                    }
                }
            } else if controller.isConnected {
                Text("창을 원하는 자리에 배치한 뒤 저장을 누르면\n여기에 대상 앱이 나타납니다")
                    .font(.callout).foregroundStyle(palette.secondary)
            }
            // 실험실 — 이 화면의 복원 소스. 이기는 슬롯은 화면마다 다를 수 있어 섹션에 붙는다.
            if controller.labAutoSlot, let slot = section.restoreSource {
                Text(CardPresentation.sourceLabel(
                    slot: slot, savedAt: section.profile?.savedAt,
                    pending: section.usesPendingSource
                ))
                    .font(.subheadline).foregroundStyle(palette.secondary)
            }
            if !controller.labAutoSlot, section.spaceConfigurationDiffers {
                Text(CardPresentation.manualSpaceConfigurationDifference)
                    .font(.subheadline).foregroundStyle(palette.secondary)
            }
            untrackedRows(for: section)
        }
    }

    private func spaceGroup(
        _ group: PlugbackController.SpaceGroup,
        in section: PlugbackController.ScreenSection
    ) -> some View {
        let alternate: Bool = {
            if case .regular(let number, _) = group.kind { return number % 2 == 0 }
            return false
        }()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if layout == .grouped {
                    Group {
                        if case .regular(let number, _) = group.kind {
                            Text(String(format: "%02d", number)).font(.caption.monospacedDigit())
                        } else { Image(systemName: "square.stack").font(.caption) }
                    }
                    .frame(width: 21, height: 21)
                    .foregroundStyle(alternate ? palette.groupAccent : palette.accent)
                    .background(alternate ? palette.groupAccent.opacity(0.18) : palette.accentSoft,
                                in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                }
                Text(CardPresentation.spaceGroupTitle(for: group.kind))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer()
                if let status = CardPresentation.spaceGroupStatus(for: group.kind, guide: group.guide) {
                    Text(status).font(.caption).foregroundStyle(palette.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .foregroundStyle(layout == .grouped ? palette.text : palette.secondary)
            .padding(.top, layout == .grouped ? 0 : 9)
            .padding(.bottom, 2)

            if group.apps.isEmpty {
                Text("저장된 앱 없음").font(.subheadline).foregroundStyle(palette.secondary)
            } else {
                appRows(group.apps, in: section)
            }
            if let guide = group.guide {
                Label(CardPresentation.spaceGuide(guide), systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(layout == .grouped ? palette.background : palette.accentSoft,
                                in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(layout == .grouped ? 12 : 0)
        .background(layout == .grouped
                    ? (alternate ? palette.groupAccent.opacity(0.10) : palette.surface) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private func appRows(
        _ apps: [TargetApp],
        in section: PlugbackController.ScreenSection
    ) -> some View {
        // 체크된 앱만 위에 — 중요한 것이 위에 고정되고 나머지는 아래로 간다.
        ForEach(apps, id: \.bundleID) { app in
            CardAppRow(bundleID: app.bundleID, name: app.displayName,
                   isEnabled: app.isEnabled, isRunning: isRunning(app.bundleID),
                   layout: layout, palette: palette,
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
            separator.padding(.top, 4)
            Text(CardPresentation.untrackedHeader)
                .font(.subheadline).foregroundStyle(palette.secondary)
                .padding(.top, 2)
            ForEach(section.untrackedApps, id: \.bundleID) { app in
                CardAppRow(bundleID: app.bundleID, name: app.displayName,
                    isEnabled: false, isRunning: nil, layout: layout, palette: palette,
                    setTracked: { tracked in
                        Task { await controller.setTracked(app.bundleID, tracked, on: section.screenID) }
                    },
                    remove: section.profile?.apps.contains(where: { $0.bundleID == app.bundleID }) == true
                        ? { Task { await controller.remove(app.bundleID, on: section.screenID) } } : nil)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
                // 강조는 지금 할 수 있는 일을 따라간다 — 프로필이 없으면 저장을 강조한다.
                let canSave = controller.isConnected && !controller.isRestoring && !controller.isSaveBlocked
                // 어느 화면에든 프로필이 있으면 복원할 수 있다 — 첫 화면만 보던 판정은 뒷 화면을 잠갔다
                let canRestore = controller.isConnected && controller.hasRestorableProfile && !controller.isRestoring
                if layout == .command {
                    VStack(spacing: 6) {
                        CardCommandButton(title: controller.isRestoring ? "복원 중…" : "지금 레이아웃 복원",
                            detail: "저장된 프로필의 대상 앱만 복원", symbol: "arrow.counterclockwise",
                            prominent: controller.hasRestorableProfile, isBusy: controller.isRestoring,
                            palette: palette) { Task { await controller.restoreNow() } }
                            .disabled(!canRestore)
                        CardCommandButton(title: "지금 레이아웃 저장",
                            detail: "현재 외장 화면의 창 위치 저장", symbol: "tray.and.arrow.down",
                            prominent: !controller.hasRestorableProfile, isBusy: false,
                            palette: palette) { Task { await controller.captureNow() } }
                            .disabled(!canSave)
                    }
                } else {
                    HStack(spacing: 8) {
                        if controller.hasRestorableProfile {
                            restoreButton(enabled: canRestore, prominent: true).buttonStyle(CardActionStyle(palette: palette, prominent: true, tall: layout == .comfortable))
                            saveButton(enabled: canSave, prominent: false).buttonStyle(CardActionStyle(palette: palette, prominent: false, tall: layout == .comfortable))
                        } else {
                            saveButton(enabled: canSave, prominent: true).buttonStyle(CardActionStyle(palette: palette, prominent: true, tall: layout == .comfortable))
                            restoreButton(enabled: canRestore, prominent: false).buttonStyle(CardActionStyle(palette: palette, prominent: false, tall: layout == .comfortable))
                        }
                    }
                    .controlSize(layout == .comfortable ? .large : .regular)
                }
                if let notice = controller.captureNotice {
                    // 성공과 Space 관찰 실패 중 실제 마지막 결과 하나만 보여준다.
                    Text(CardPresentation.captureNotice(notice))
                        .font(.subheadline).foregroundStyle(palette.accent)
                }
                // 저장 금지는 알림을 닫아도 남는다 — 수동 저장도 막히므로 실험실과 무관하게 표시한다.
                // 복원 소스(지금 복원되는 값)는 화면마다 다를 수 있어 각 섹션에 붙고,
                // 여기는 수집(뽑을 때 저장될 값)의 전역 상태 한 줄이다.
                // 소스와 한 줄로 뭉치면 "수집됨"이 "저장됨"으로 읽힌다.
                if controller.isSaveBlocked {
                    Text(CardPresentation.saveBlockedStatus)
                        .font(.subheadline).foregroundStyle(palette.accent)
                } else if controller.labAutoSlot {
                    Text(CardPresentation.pendingLabel(collectedAt: controller.lastCollectedAt,
                                                       hasPending: controller.hasPendingCollect,
                                                       spaceConfigurationChanged:
                                                           controller.spaceConfigurationDiffers))
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
        }
        .padding(.horizontal, layout == .command ? 10 : layout.inset)
        .padding(.top, layout == .command ? 10 : 5)
        .padding(.bottom, layout == .command ? 10 : 18)
    }

    // 글자색은 라벨 안쪽에 건다 — 강조 스타일은 바깥의 foregroundStyle을 무시하고 흰 글자를 쓴다
    private func saveButton(enabled: Bool, prominent: Bool) -> some View {
        Button { Task { await controller.captureNow() } } label: {
            Text(prominent ? "지금 레이아웃 저장" : "저장")
                .frame(maxWidth: prominent ? .infinity : nil)
        }
        .disabled(!enabled)
        .accessibilityLabel("지금 레이아웃 저장")
        .help("지금 레이아웃 저장")
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

        }
        .disabled(!enabled)
    }

    private var footer: some View {
        HStack(spacing: 8) {
                Toggle("자동 복원", isOn: Binding(
                    get: { controller.restoreMode == .automatic },
                    set: { controller.restoreMode = $0 ? .automatic : .manual }))
                    .toggleStyle(CardToggleStyle(palette: palette, isSwitch: true))
                Spacer()
                SettingsButton()
                Button { NSApp.terminate(nil) } label: {
                    Text("종료").padding(.horizontal, 6).frame(minHeight: 28)
                }
                    .keyboardShortcut("q")
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(layout == .grouped ? palette.surface : palette.background)
    }

    private func zone(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, layout.inset).padding(.vertical, layout == .comfortable ? 18 : 14)
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
                Text("설정").padding(.horizontal, 6).frame(minHeight: 28)
            }
            .font(.caption)
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
            Text("설정").padding(.horizontal, 6).frame(minHeight: 28)
        }
        .font(.caption)
        .keyboardShortcut(",")
    }
}

// 권한 없음 전용 화면 (US-010). 시스템 프롬프트는 사용자가 버튼을 눌렀을 때만.
private struct PermissionOnboarding: View {
    let palette: CardPalette
    let recheck: () -> Void
    @ScaledMetric(relativeTo: .title) private var badgeSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(palette.surface)
                Image(systemName: "display")
                    .font(.title.weight(.medium))
                    .foregroundStyle(palette.accent)
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

#if DEBUG
#Preview("빈 카드 · B + Porcelain") {
    Card(controller: SpaceProbe.placeholderController, layout: .comfortable,
         palette: CardColors.porcelain.palette(for: .light))
        .frame(width: CardLayout.comfortable.width)
        .background(CardColors.porcelain.palette(for: .light).background)
        .environment(\.colorScheme, .light)
}
#endif
