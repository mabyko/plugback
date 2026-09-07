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

// 액션은 모든 레이아웃의 목록 위(2026-09 밀도 시안) — 목록은 늘고 스크롤되므로 아래 두면 버튼 위치가
// 내용 따라 움직인다. 위에 두면 메뉴바 바로 아래 고정이라 손이 먼저 닿고, 저장 확인 문구도 그 버튼 밑에 붙는다.
struct Card: View {
    @ObservedObject var controller: PlugbackController
    let layout: CardLayout
    let palette: CardPalette
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 17
    @ScaledMetric(relativeTo: .headline) private var compactTitleSize: CGFloat = 15
    @State private var showingManager = false

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
            if !isManaging { actions }
            if layout == .status && !isManaging {
                summary
            } else {
                CardAppBrowser(controller: controller, layout: layout, palette: palette)
            }
            // 연결된 모든 화면의 결과를 합산한다 — 두 번째 화면의 실패 사유도 여기서 보인다.
            // 지문 불일치로 통째 건너뛴 화면은 lastResults가 이미 뺐다 — 그건 위 경고 배너의 몫이다.
            // 버튼(다음 행동) 아래, 목록 다음에 둔다 — 결과는 참고 정보라 맨 아래가 맞다.
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

    private var targetCount: Int {
        controller.sections.reduce(0) { $0 + ($1.profile?.apps.filter(\.isEnabled).count ?? 0) }
    }

    // 헤더·목록 밀도는 layout, 색은 palette만 따른다. 어느 쪽도 다른 설정을 바꾸지 않는다.
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            separator
            HStack(spacing: 3) {
                // 한 앱이 여러 화면에 저장되어 있어도 아이콘은 한 번만 보여준다.
                let apps = controller.sections.flatMap { $0.profile?.apps.filter(\.isEnabled) ?? [] }
                let unique = apps.reduce(into: [TargetApp]()) { result, app in
                    if !result.contains(where: { $0.bundleID == app.bundleID }) { result.append(app) }
                }
                ForEach(Array(unique.prefix(6)), id: \.bundleID) { app in
                    CardAppIcon(bundleID: app.bundleID, size: 24)
                }
                Spacer(minLength: 4)
                let spaces = controller.sections.flatMap(\.spaceGroups).filter {
                    if case .regular = $0.kind { return true }; return false
                }.count
                Text("대상 \(targetCount)개" + (spaces > 0 ? " · Space \(spaces)개" : ""))
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
                        Text(section.name).font(.caption.weight(.medium))
                        sourceStatus(for: section)
                    }
                }
            }
            // 요약 화면에서도 복원을 마치기 위한 Space 안내를 숨기지 않는다.
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

    private func sourceStatus(for section: PlugbackController.ScreenSection) -> some View {
        CardSourceStatus(section: section, labAutoSlot: controller.labAutoSlot, palette: palette)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 강조는 지금 할 수 있는 일을 따라간다 — 프로필이 없으면 저장을 강조한다.
            let canSave = controller.isConnected && !controller.isRestoring && !controller.isSaveBlocked
            // 어느 화면에든 프로필이 있으면 복원할 수 있다 — 첫 화면만 보던 판정은 뒷 화면을 잠갔다
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
                Text("현재 배치를 저장하고 시작하세요").font(.caption).foregroundStyle(palette.secondary)
            }
            if layout == .spaces {
                Text("전체 대상 앱 \(targetCount)개 복원").font(.caption).foregroundStyle(palette.secondary)
            }
            if controller.sections.count == 1, let section = controller.sections.first {
                sourceStatus(for: section)
            }
            if let notice = controller.captureNotice {
                // 성공과 Space 관찰 실패 중 실제 마지막 결과 하나만 보여준다.
                Text(CardPresentation.captureNotice(notice))
                    .font(.subheadline).foregroundStyle(palette.accent)
            }
            // 저장 금지는 알림을 닫아도 남는다 — 수동 저장도 막히므로 실험실과 무관하게 표시한다.
            // 복원 소스와 별도로 수집(뽑을 때 저장될 값)의 전역 상태를 보여준다.
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
        .padding(.horizontal, layout.inset)
        .padding(.top, 2)
        .padding(.bottom, 10)
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
    private var excludedCount: Int { sections.reduce(0) { $0 + $1.untrackedApps.count } }
    private var targetCount: Int {
        sections.reduce(0) { $0 + ($1.profile?.apps.filter(\.isEnabled).count ?? 0) }
    }

    var body: some View {
        if layout == .spaces && !sections.isEmpty {
            spaceBrowser
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    TextField("앱 검색", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("card.appSearch")
                    if layout == .board {
                        Button("제외 \(excludedCount)") { showsExcluded.toggle() }
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
                        let titles = CardPresentation.sectionTitles(names: sections.map(\.name))
                        ForEach(Array(zip(sections, titles)), id: \.0.id) { section, title in
                            VStack(alignment: .leading, spacing: 7) {
                                if sections.count > 1 {
                                    Text(title).font(.callout.weight(.semibold))
                                    CardSourceStatus(section: section, labAutoSlot: controller.labAutoSlot, palette: palette)
                                }
                                if layout == .board && showsExcluded {
                                    excludedRows(section)
                                } else {
                                    targets(section)
                                    if layout != .board { excludedDisclosure(section) }
                                }
                            }
                        }
                    }
                }
                if layout == .board {
                    HStack {
                        Text(showsExcluded ? CardPresentation.untrackedHeader : "\(targetCount)개 앱 선택됨")
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
        let apps = (section.profile?.apps ?? []).filter { $0.isEnabled && matches($0.displayName, $0.bundleID) }
        if apps.isEmpty {
            Text(search.isEmpty ? "대상 앱이 없습니다. 저장하거나 제외 앱을 포함해 주세요." : "검색 결과가 없어요")
                .font(.callout).foregroundStyle(palette.secondary)
        } else if layout == .board {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(apps, id: \.bundleID) { app in
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

    private func appRows(_ apps: [TargetApp], in section: PlugbackController.ScreenSection) -> some View {
        VStack(spacing: 0) {
            ForEach(apps, id: \.bundleID) { app in
                CardAppRow(bundleID: app.bundleID, name: app.displayName,
                    isEnabled: app.isEnabled, isRunning: isRunning(app.bundleID), layout: layout, palette: palette,
                    setTracked: { setTracked(app.bundleID, $0, in: section) },
                    remove: { Task { await controller.remove(app.bundleID, on: section.screenID) } })
            }
        }
    }

    private func setTracked(_ bundleID: String, _ tracked: Bool, in section: PlugbackController.ScreenSection) {
        if !tracked { expandedScreens.insert(section.screenID) }
        Task { await controller.setTracked(bundleID, tracked, on: section.screenID) }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @ViewBuilder private func excludedRows(_ section: PlugbackController.ScreenSection) -> some View {
        let apps = section.untrackedApps.filter { matches($0.displayName, $0.bundleID) }
        if apps.isEmpty {
            Text(search.isEmpty ? "저장하지 않는 앱이 없습니다" : "검색 결과가 없어요")
                .font(.callout).foregroundStyle(palette.secondary)
        }
        VStack(spacing: 0) {
            ForEach(apps, id: \.bundleID) { app in
                CardAppRow(bundleID: app.bundleID, name: app.displayName, isEnabled: false,
                    isRunning: nil, layout: layout, palette: palette,
                    setTracked: { setTracked(app.bundleID, $0, in: section) },
                    remove: section.profile?.apps.contains(where: { $0.bundleID == app.bundleID }) == true
                        ? { Task { await controller.remove(app.bundleID, on: section.screenID) } } : nil)
            }
        }
    }

    @ViewBuilder private func excludedDisclosure(_ section: PlugbackController.ScreenSection) -> some View {
        if !section.untrackedApps.isEmpty {
            palette.border.frame(height: 1).padding(.top, 4)
            let expanded = Binding(
                get: { !search.isEmpty || expandedScreens.contains(section.screenID) },
                set: { if $0 { expandedScreens.insert(section.screenID) }
                       else { expandedScreens.remove(section.screenID) } })
            DisclosureGroup(isExpanded: expanded) {
                excludedRows(section).padding(.top, 4)
            } label: {
                Button { expanded.wrappedValue.toggle() } label: {
                    Text("\(CardPresentation.untrackedHeader) \(section.untrackedApps.count)개")
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded.wrappedValue ? "펼쳐짐" : "접힘")
            }
            .font(.caption).foregroundStyle(palette.secondary).padding(.vertical, 4)
        }
    }

    private var spaceCap: CGFloat {
        let rowCount = sections.map { section in
            max(section.untrackedApps.count, section.spaceGroups.map { $0.apps.count }.max()
                ?? section.profile?.apps.filter(\.isEnabled).count ?? 0)
        }.max() ?? 0
        return min(listCap, max(180, CGFloat(rowCount) * 30 + 50))
    }

    private var spaceBrowser: some View {
        let destinations = CardPresentation.spaceSelections(in: sections)
        let current = CardPresentation.resolvedSpaceSelection(selection, in: sections)
        return HStack(alignment: .top, spacing: 0) {
            CardScrollView(maxHeight: spaceCap) {
                VStack(alignment: .leading, spacing: 4) {
                    let titles = CardPresentation.sectionTitles(names: sections.map(\.name))
                    ForEach(Array(zip(sections, titles)), id: \.0.id) { section, title in
                        if sections.count > 1 {
                            Text(title).font(.caption2).foregroundStyle(palette.secondary)
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
                            CardSourceStatus(section: section, labAutoSlot: controller.labAutoSlot, palette: palette)
                        }
                        switch current.category {
                        case .all:
                            Text("대상 앱").font(.callout.weight(.semibold))
                            targets(section)
                        case .excluded:
                            Text(CardPresentation.untrackedHeader).font(.callout.weight(.semibold))
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
        case .all: title = "대상 앱"; count = section.profile?.apps.filter(\.isEnabled).count ?? 0
        case .excluded: title = "제외 앱"; count = section.untrackedApps.count
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
        .accessibilityLabel("\(section.name), \(title), 앱 \(count)개")
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
    let labAutoSlot: Bool
    let palette: CardPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let slot = section.restoreSource {
                Text(CardPresentation.sourceLabel(slot: slot, savedAt: section.profile?.savedAt,
                                                  pending: section.usesPendingSource))
            }
            if !labAutoSlot, section.spaceConfigurationDiffers {
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
