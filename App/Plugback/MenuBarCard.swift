import PlugbackKit
import SwiftUI

// 공통 헤더·액션·결과·푸터와 레이아웃별 대상 앱 탐색. 오류·권한 안내는 레이아웃과 무관하다.
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
                PermissionOnboarding(palette: palette, recheck: { controller.checkAuthorization() })
            }
        }
        .modifier(CardSurface(layout: appearance.layout, palette: palette))
        .preferredColorScheme(appearance.brightness.colorScheme)
        // 카드를 열 때마다 권한·화면·저장본을 재확인한다 (US-010 AC-3)
        .onAppear { Task { await controller.cardOpened() } }
    }
}

// 액션은 모든 레이아웃의 목록 위(2026-09 밀도 시안) — 목록은 늘고 스크롤되므로 아래 두면 버튼 위치가
// 내용 따라 움직인다. 위에 두면 메뉴바 바로 아래 고정이라 손이 먼저 닿고, 저장 확인 문구도 그 버튼 밑에 붙는다.
struct Card: View {
    @ObservedObject var controller: PlugbackController
    let layout: CardLayout
    let palette: CardPalette
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 17
    @ScaledMetric(relativeTo: .headline) private var compactTitleSize: CGFloat = 15
    @State private var showingManager = false
    @Environment(\.openWindow) private var openWindow

    private var isManaging: Bool { layout == .status && showingManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isManaging { managerHeader } else { header }
            if let notice = controller.storeNotice {
                separator
                storeNotice(notice)
            }
            if controller.identityMismatch {
                separator
                zone {
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
            if controller.spacesSupport != .separateSpaces {
                separator
                zone {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(CardPresentation.spacesSupportNotice(controller.spacesSupport))
                            .foregroundStyle(palette.text)
                    }
                    .font(.callout)
                }
            }
            if !isManaging { actions }
            if !isManaging, controller.hasOpenRestoreItems || controller.isSettlingScreens {
                separator
                zone { requestStatus }
                    .background(palette.accentSoft.opacity(0.4))
            }
            if layout == .status && !isManaging {
                summary
            } else {
                CardAppBrowser(controller: controller, layout: layout, palette: palette)
            }
            if !isManaging, controller.isConnected, !controller.lastResults.isEmpty {
                separator
                zone {
                    CardResultStrip(results: controller.lastResults,
                                    restoredAt: controller.lastRestoredAt, palette: palette)
                }
                .background(palette.background)
            }
            separator
            footer
        }
        .font(.body)
    }

    private var separator: some View {
        palette.border.frame(height: 1).accessibilityHidden(true)
    }

    private var header: some View {
        zone {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    displaySymbol.font(.system(size: layout == .status ? 28 : 20))
                    screenTitle
                    Spacer(minLength: 4)
                    headerBadge
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
            .font(.system(size: layout == .status ? titleSize : compactTitleSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var managerHeader: some View {
        zone {
            HStack(spacing: 8) {
                Button { showingManager = false } label: {
                    Label("돌아가기", systemImage: "chevron.left").labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("card.manager.back")
                Text("대상 앱 관리").font(.headline)
            }
        }
    }

    /// 진행 중 복원 요청의 남은 항목 — 방문·이동·잠금 대기는 화면 소속과 함께, 확인 필요는 상세 창 진입점으로 (3.8·3.12절).
    private var requestStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isSettlingScreens {
                Label(CardPresentation.settlingStatus, systemImage: "display.and.arrow.down")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            let waiting = controller.waitingItems.filter {
                if case .needsConfirmation = $0.outcome { return false } else { return true }
            }
            if !waiting.isEmpty {
                // 대기 항목은 저장 창 수만큼 늘 수 있다 — 카드 높이를 제한하고 스크롤한다
                CardScrollView(maxHeight: 96) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(waiting) { item in
                            Label(CardPresentation.waitingLine(item), systemImage: "clock")
                                .font(.caption).foregroundStyle(palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if controller.confirmationCount > 0 {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: RestoreConfirmationView.windowID)
                } label: {
                    Label("창 확인 필요 \(controller.confirmationCount)개", systemImage: "questionmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(palette.accent)
                .accessibilityIdentifier("card.confirmation.open")
                .help("어떤 앱의 어떤 저장 창을 확인해야 하는지 보여줍니다.")
            }
            if controller.hasOpenRestoreItems {
                HStack(spacing: 8) {
                    Button("남은 창 복원") { Task { await controller.resumeRemaining() } }
                        .buttonStyle(CardActionStyle(palette: palette, prominent: false))
                        .disabled(controller.isRestoring || !controller.isConnected)
                    Button("남은 복원 취소") { controller.cancelRemaining() }
                        .buttonStyle(CardActionStyle(palette: palette, prominent: false))
                        .disabled(controller.isRestoring)
                }
                .controlSize(.small)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            separator
            HStack(spacing: 3) {
                // 지금 화면에 있는 앱이 먼저, 화면에 없는 저장 앱은 뒤에 — 첫인상이 지금 화면과 맞아야 한다
                let apps = controller.sections.flatMap(\.presentApps) + controller.sections.flatMap(\.absentSavedApps)
                let unique = apps.reduce(into: [PlugbackController.AppRow]()) { result, app in
                    if !result.contains(where: { $0.bundleID == app.bundleID }) { result.append(app) }
                }
                ForEach(Array(unique.prefix(6))) { app in
                    CardAppIcon(bundleID: app.bundleID, size: 24)
                }
                Spacer(minLength: 4)
                let spaces = controller.sections.flatMap(\.spaceGroups).filter {
                    if case .regular = $0.kind { return true }; return false
                }.count
                Text("앱 \(controller.enabledAppCount)개 · 창 \(controller.savedWindowCount)개" + (spaces > 0 ? " · Space \(spaces)개" : ""))
                    .font(.caption).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { showingManager = true } label: {
                HStack {
                    Text("대상 앱 관리")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(palette.secondary)
            .accessibilityIdentifier("card.manager.open")
            if controller.sections.count > 1 {
                CardScrollView(maxHeight: 80) {
                    ForEach(controller.sections) { section in
                        Text(CardPresentation.screenName(section.label)).font(.caption.weight(.medium))
                    }
                }
            }
            let groups = controller.sections.flatMap(\.spaceGroups).filter { $0.guide != nil }
            if !groups.isEmpty {
                CardScrollView(maxHeight: 100) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if let guide = group.guide {
                            Label(CardPresentation.spaceGuide(guide), systemImage: "info.circle")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, layout.inset).padding(.vertical, 10)
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

    private func storeNotice(_ notice: ProfileStore.Trouble) -> some View {
        zone {
            VStack(alignment: .leading, spacing: 4) {
                switch notice {
                case .corruptionBackedUp(let backupURL):
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("저장 파일이 손상되어 초기화했습니다")
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
                        Text("저장 파일을 읽지 못해 이번 실행에서는 저장하지 않습니다.\n파일을 지키기 위해 덮어쓰기를 막았습니다 — 재시작하면 다시 시도합니다.")
                    }
                    .font(.callout)
                    Button("확인") { controller.dismissStoreNotice() }
                        .font(.subheadline)
                case .unsupportedVersion(let version):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("저장 파일이 더 새로운 형식(버전 \(version))입니다.\n원본을 지키기 위해 이번 실행에서는 저장하지 않습니다.")
                    }
                    .font(.callout)
                    Button("확인") { controller.dismissStoreNotice() }
                        .font(.subheadline)
                case .writeFailed:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("저장하지 못했습니다.\n기존 저장본과 저장 대기 이력은 그대로 두었습니다 — 다음 저장 때 다시 시도합니다.")
                    }
                    .font(.callout)
                    Button("확인") { controller.dismissStoreNotice() }
                        .font(.subheadline)
                }
            }
        }
    }

    private func sourceStatus(for section: PlugbackController.ScreenSection) -> some View {
        CardSourceStatus(section: section, autoSave: controller.autoSave, palette: palette)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            let canSave = controller.isConnected && !controller.isRestoring && !controller.isSaveBlocked
            let canRestore = controller.isConnected && controller.hasRestorableProfile && !controller.isRestoring
            HStack(spacing: 8) {
                if controller.hasRestorableProfile {
                    restoreButton(enabled: canRestore, prominent: true).buttonStyle(CardActionStyle(palette: palette, prominent: true))
                    saveButton(enabled: canSave, prominent: false).buttonStyle(CardActionStyle(palette: palette, prominent: false))
                } else {
                    saveButton(enabled: canSave, prominent: true).buttonStyle(CardActionStyle(palette: palette, prominent: true))
                    restoreButton(enabled: canRestore, prominent: false).buttonStyle(CardActionStyle(palette: palette, prominent: false))
                }
            }
            .controlSize(.regular)
            if !controller.isConnected {
                Text("모니터를 연결하면 복원할 수 있어요").font(.caption).foregroundStyle(palette.secondary)
            } else if !controller.hasRestorableProfile {
                Text("이 화면 조합의 저장본이 없어요 · 현재 배치를 저장하고 시작하세요").font(.caption).foregroundStyle(palette.secondary)
            }
            if layout == .spaces {
                Text("대상 앱 \(controller.enabledAppCount)개 · 창 \(controller.savedWindowCount)개 복원").font(.caption).foregroundStyle(palette.secondary)
            }
            if controller.sections.count == 1, let section = controller.sections.first {
                sourceStatus(for: section)
            }
            if let notice = controller.captureNotice {
                Text(CardPresentation.captureNotice(notice))
                    .font(.subheadline).foregroundStyle(palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.isSaveBlocked {
                Text(CardPresentation.saveBlockedStatus)
                    .font(.subheadline).foregroundStyle(palette.accent)
            } else if controller.autoSave, controller.isConnected {
                Text(CardPresentation.pendingLabel(collectedAt: controller.lastCollectedAt,
                                                   hasPending: controller.hasPendingCollect,
                                                   spaceConfigurationChanged: controller.spaceConfigurationDiffers))
                    .font(.subheadline).foregroundStyle(palette.secondary)
            }
        }
        .padding(.horizontal, layout.inset)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

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
                if controller.isRestoring {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("복원 중…")
                    }
                } else {
                    Label("지금 복원", systemImage: "arrow.counterclockwise")
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
        .padding(.horizontal, layout.inset).padding(.vertical, 6)
        .background(palette.background)
    }

    private func zone(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, layout.inset).padding(.vertical, 10)
    }
}

/// 화면 선택은 탐색 상태다. 저장·복원 범위는 컨트롤러가 그대로 결정한다.
private struct CardAppBrowser: View {
    @ObservedObject var controller: PlugbackController
    let layout: CardLayout
    let palette: CardPalette
    @State private var search = ""
    @State private var expandedScreens: Set<String> = []
    @State private var selection: CardSpaceSelection?
    @State private var showsExcluded = false
    @ScaledMetric(relativeTo: .callout) private var listCap: CGFloat = 326

    private var sections: [PlugbackController.ScreenSection] { controller.sections }
    private var secondaryCount: Int { sections.reduce(0) { $0 + $1.absentSavedApps.count + $1.excludedApps.count } }
    private var targetCount: Int { controller.enabledAppCount }

    var body: some View {
        if layout == .spaces && !sections.isEmpty {
            spaceBrowser
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    TextField("앱 검색", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("card.appSearch")
                    if layout == .board {
                        Button("그 외 \(secondaryCount)") { showsExcluded.toggle() }
                            .buttonStyle(CardActionStyle(palette: palette, prominent: showsExcluded))
                            .accessibilityValue(showsExcluded ? "선택됨" : "선택 안 됨")
                    } else {
                        Text("\(targetCount)개 대상").font(.caption).foregroundStyle(palette.secondary)
                            .fixedSize()
                    }
                }
                .padding(.trailing, layout.inset)
                CardScrollView(maxHeight: layout == .board ? listCap + 24 : listCap) {
                    VStack(alignment: .leading, spacing: 12) {
                        if sections.isEmpty { emptyMessage }
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                if sections.count > 1 {
                                    Text(CardPresentation.screenName(section.label)).font(.callout.weight(.semibold))
                                    CardSourceStatus(section: section, autoSave: controller.autoSave, palette: palette)
                                }
                                if layout == .board && showsExcluded {
                                    secondaryRows(section)
                                } else {
                                    targets(section)
                                    if layout != .board {
                                        absentDisclosure(section)
                                        excludedDisclosure(section)
                                    }
                                }
                            }
                        }
                    }
                }
                if layout == .board {
                    HStack {
                        Text(showsExcluded ? "화면에 없는 저장 앱 · 제외한 앱" : "\(targetCount)개 앱 선택됨")
                        Spacer()
                        Text("• 실행하지 않은 앱")
                    }
                    .font(.caption2).foregroundStyle(palette.secondary)
                    .padding(.trailing, layout.inset)
                }
            }
            .padding(.leading, layout.inset).padding(.top, 8).padding(.bottom, 12)
        }
    }

    private var emptyMessage: some View {
        Text(controller.isConnected ? "창을 원하는 자리에 배치한 뒤 저장을 눌러 주세요." : "외장 화면을 연결하면 저장된 배치로 복원할 수 있습니다.")
            .font(.callout).foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func matches(_ name: String, _ bundleID: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
            || bundleID.localizedCaseInsensitiveContains(query)
    }

    @ViewBuilder private func targets(_ section: PlugbackController.ScreenSection) -> some View {
        let apps = section.presentApps.filter { matches($0.displayName, $0.bundleID) }
        if apps.isEmpty {
            Text(search.isEmpty
                 ? (section.absentSavedApps.isEmpty ? "이 화면에 창이 있는 앱이 없습니다. 창을 놓고 저장해 주세요."
                                                    : "지금 이 화면에 창이 있는 앱이 없습니다. 저장한 앱은 아래 묶음에 있습니다.")
                 : "검색 결과가 없어요")
                .font(.callout).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if layout == .board {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(apps) { app in
                    CardAppTile(app: app, isRunning: isRunning(app.bundleID), palette: palette,
                                setTracked: { setTracked(app.bundleID, $0, in: section) },
                                remove: { Task { await controller.remove(app.bundleID, on: section.screenID) } })
                }
            }
        } else {
            appRows(apps, in: section)
        }
        ForEach(section.spaceGroups.filter { $0.guide != nil }) { group in
            guide(group)
        }
    }

    private func appRows(_ apps: [PlugbackController.AppRow], in section: PlugbackController.ScreenSection) -> some View {
        VStack(spacing: 0) {
            ForEach(apps) { app in
                CardAppRow(bundleID: app.bundleID, name: app.displayName,
                    isEnabled: app.isEnabled, isRunning: isRunning(app.bundleID), windowCount: app.windowCount,
                    isSaved: app.isSaved, layout: layout, palette: palette,
                    setTracked: { setTracked(app.bundleID, $0, in: section) },
                    remove: app.isSaved ? { Task { await controller.remove(app.bundleID, on: section.screenID) } } : nil)
            }
        }
    }

    private func setTracked(_ bundleID: String, _ tracked: Bool, in section: PlugbackController.ScreenSection) {
        if !tracked { expandedScreens.insert(disclosureKey(section, "excluded")) }
        Task { await controller.setTracked(bundleID, tracked, on: section.screenID) }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @ViewBuilder private func excludedRows(_ section: PlugbackController.ScreenSection) -> some View {
        let apps = section.excludedApps.filter { matches($0.displayName, $0.bundleID) }
        if apps.isEmpty {
            Text(search.isEmpty ? "제외한 앱이 없습니다" : "검색 결과가 없어요")
                .font(.callout).foregroundStyle(palette.secondary)
        }
        VStack(spacing: 0) {
            ForEach(apps) { app in
                CardAppRow(bundleID: app.bundleID, name: app.displayName, isEnabled: false,
                    isRunning: nil, windowCount: app.windowCount, isSaved: true, layout: layout, palette: palette,
                    setTracked: { setTracked(app.bundleID, $0, in: section) },
                    remove: app.windowCount > 0 ? { Task { await controller.remove(app.bundleID, on: section.screenID) } } : nil)
            }
        }
    }

    /// 보드 레이아웃의 「그 외」 — 화면에 없는 저장 앱과 제외한 앱을 작은 머리말로 나눠 보여준다.
    @ViewBuilder private func secondaryRows(_ section: PlugbackController.ScreenSection) -> some View {
        if !section.absentSavedApps.isEmpty {
            Text(CardPresentation.absentHeader(section.absentSavedApps.count)).font(.caption).foregroundStyle(palette.secondary)
            appRows(section.absentSavedApps.filter { matches($0.displayName, $0.bundleID) }, in: section)
        }
        Text(CardPresentation.excludedHeader(section.excludedApps.count)).font(.caption).foregroundStyle(palette.secondary)
        excludedRows(section)
    }

    private func disclosureKey(_ section: PlugbackController.ScreenSection, _ group: String) -> String {
        "\(section.screenID)|\(group)"
    }

    private func disclosure<Rows: View>(_ key: String, title: String, @ViewBuilder rows: @escaping () -> Rows) -> some View {
        let expanded = Binding(
            get: { !search.isEmpty || expandedScreens.contains(key) },
            set: { if $0 { expandedScreens.insert(key) } else { expandedScreens.remove(key) } })
        return VStack(alignment: .leading, spacing: 0) {
            palette.border.frame(height: 1).padding(.top, 4)
            DisclosureGroup(isExpanded: expanded) {
                rows().padding(.top, 4)
            } label: {
                Button { expanded.wrappedValue.toggle() } label: {
                    Text(title)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded.wrappedValue ? "펼쳐짐" : "접힘")
            }
            .font(.caption).foregroundStyle(palette.secondary).padding(.vertical, 4)
        }
    }

    /// 저장 기록은 있지만 지금 창이 없는 앱 — 복원 대상은 유지된다. 기본 접힘.
    @ViewBuilder private func absentDisclosure(_ section: PlugbackController.ScreenSection) -> some View {
        if !section.absentSavedApps.isEmpty {
            disclosure(disclosureKey(section, "absent"), title: CardPresentation.absentHeader(section.absentSavedApps.count)) {
                appRows(section.absentSavedApps.filter { matches($0.displayName, $0.bundleID) }, in: section)
            }
        }
    }

    /// 제외한 앱 — 다시 체크하면 포함. 기본 접힘이되, 방금 체크를 끈 화면은 펼쳐 둔다.
    @ViewBuilder private func excludedDisclosure(_ section: PlugbackController.ScreenSection) -> some View {
        if !section.excludedApps.isEmpty {
            disclosure(disclosureKey(section, "excluded"), title: CardPresentation.excludedHeader(section.excludedApps.count)) {
                excludedRows(section)
            }
        }
    }

    private var spaceCap: CGFloat {
        let rowCount = sections.map { section in
            max(section.presentApps.count + section.absentSavedApps.count, section.excludedApps.count,
                section.spaceGroups.map { $0.apps.count }.max() ?? 0)
        }.max() ?? 0
        return min(listCap, max(180, CGFloat(rowCount) * 30 + 50))
    }

    private var spaceBrowser: some View {
        let destinations = CardPresentation.spaceSelections(in: sections)
        let current = CardPresentation.resolvedSpaceSelection(selection, in: sections)
        return HStack(alignment: .top, spacing: 0) {
            CardScrollView(maxHeight: spaceCap) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sections) { section in
                        if sections.count > 1 {
                            Text(CardPresentation.screenName(section.label)).font(.caption2).foregroundStyle(palette.secondary)
                                .padding(.top, 5).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(destinations.filter { $0.screenID == section.screenID }, id: \.self) { item in
                            spaceButton(item, section: section, selected: current == item)
                        }
                    }
                }
            }
            .padding(.leading, 7).padding(.vertical, 10)
            .frame(width: 112, height: spaceCap + 20, alignment: .top)
            .background(palette.surface)
            CardScrollView(maxHeight: spaceCap) {
                if let current, let section = sections.first(where: { $0.screenID == current.screenID }) {
                    VStack(alignment: .leading, spacing: 8) {
                        if sections.count > 1 {
                            CardSourceStatus(section: section, autoSave: controller.autoSave, palette: palette)
                        }
                        switch current.category {
                        case .all:
                            Text(CardPresentation.presentHeader).font(.callout.weight(.semibold))
                            targets(section)
                            absentDisclosure(section)
                        case .excluded:
                            Text(CardPresentation.excludedHeader(section.excludedApps.count)).font(.callout.weight(.semibold))
                            excludedRows(section)
                        case .group(let id):
                            if let group = section.spaceGroups.first(where: { $0.id == id }) {
                                HStack {
                                    Text(CardPresentation.spaceGroupTitle(for: group.kind)).font(.callout.weight(.semibold))
                                    Spacer(minLength: 2)
                                    if let status = CardPresentation.spaceGroupStatus(for: group.kind, guide: group.guide) {
                                        Text(status).font(.caption2).foregroundStyle(palette.secondary)
                                    }
                                }
                                if group.apps.isEmpty {
                                    Text("저장된 앱 없음").font(.caption).foregroundStyle(palette.secondary)
                                } else { appRows(group.apps, in: section) }
                                guide(group)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 10).padding(.vertical, 10)
        }
        .overlay(alignment: .top) { palette.border.frame(height: 1) }
    }

    private func spaceButton(_ item: CardSpaceSelection, section: PlugbackController.ScreenSection,
                             selected: Bool) -> some View {
        let group = section.spaceGroups.first { .group($0.id) == item.category }
        let title: String
        let count: Int
        switch item.category {
        case .all: title = "지금 화면"; count = section.presentApps.count
        case .excluded: title = "제외 앱"; count = section.excludedApps.count
        case .group: title = group.map { CardPresentation.spaceGroupTitle(for: $0.kind) } ?? "Space"; count = group?.apps.count ?? 0
        }
        return Button { selection = item } label: {
            HStack(spacing: 3) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 1)
                if group?.guide != nil { Image(systemName: "info.circle").font(.caption2) }
                Text("\(count)").font(.caption2).monospacedDigit()
            }
            .font(.caption).padding(.horizontal, 7).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? palette.onAccent : palette.text)
            .background(selected ? palette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(CardPresentation.screenName(section.label)), \(title), 앱 \(count)개")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
        .help("목록만 전환합니다. 지금 복원은 전체 대상 앱에 적용됩니다.")
    }

    @ViewBuilder private func guide(_ group: PlugbackController.SpaceGroup) -> some View {
        if let guide = group.guide {
            Label(CardPresentation.spaceGuide(guide), systemImage: "info.circle")
                .font(.caption).foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct CardSourceStatus: View {
    let section: PlugbackController.ScreenSection
    let autoSave: Bool
    let palette: CardPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let savedBy = section.savedBy {
                Text(CardPresentation.sourceLabel(savedBy: savedBy, savedAt: section.savedAt))
            }
            if !autoSave, section.spaceConfigurationDiffers {
                Text(CardPresentation.manualSpaceConfigurationDifference)
            }
        }
        .font(.caption).foregroundStyle(palette.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
#Preview("빈 카드 · A + Sage") {
    Card(controller: SpaceProbe.placeholderController, layout: .status,
         palette: CardColors.sage.palette(for: .light))
        .frame(width: CardLayout.status.width)
        .background(CardColors.sage.palette(for: .light).background)
        .environment(\.colorScheme, .light)
}
#endif
