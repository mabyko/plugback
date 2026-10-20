import PlugbackKit
import SwiftUI

/// 대상 앱 탐색 — 화면마다 세 묶음(지금 화면 / 화면에 없는 저장 앱 / 제외한 앱)과 Space별 목록.
/// 화면·Space 선택과 검색은 보기만 바꾼다. 저장·복원 범위는 컨트롤러가 그대로 결정한다.
/// 체크 끄기는 제외(기록 유지)이고, 저장 기록 삭제는 행 메뉴·휴지통 버튼 뒤에 한 번 더 묻는다.
struct CardAppBrowser: View {
    @ObservedObject var controller: PlugbackController
    let layout: CardLayout
    let palette: CardPalette
    @State private var search = ""
    @State private var expandedScreens: Set<String> = []
    @State private var selection: CardSpaceSelection?
    @State private var showsExcluded = false
    @State private var pendingRemoval: PendingRemoval?
    @ScaledMetric(relativeTo: .callout) private var listCap: CGFloat = 326

    private struct PendingRemoval: Equatable {
        let bundleID: String
        let name: String
        let screenID: String
    }

    private var sections: [PlugbackController.ScreenSection] { controller.sections }
    private var secondaryCount: Int { sections.reduce(0) { $0 + $1.absentSavedApps.count + $1.excludedApps.count } }
    private var targetCount: Int { controller.enabledAppCount }

    var body: some View {
        if layout == .spaces && !sections.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if pendingRemoval != nil {
                    removalConfirmation.padding(.horizontal, layout.inset).padding(.vertical, 8)
                }
                spaceBrowser
            }
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
                if pendingRemoval != nil {
                    removalConfirmation.padding(.trailing, layout.inset)
                }
                CardScrollView(maxHeight: layout == .board ? listCap + 24 : listCap) {
                    VStack(alignment: .leading, spacing: 12) {
                        if sections.isEmpty { emptyMessage }
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                if sections.count > 1 {
                                    Text(CardPresentation.screenName(section.label)).font(.callout.weight(.semibold))
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
            .padding(.leading, layout.inset).padding(.top, 10).padding(.bottom, 12)
        }
    }

    private var emptyMessage: some View {
        Text(controller.isConnected ? "창을 원하는 자리에 배치한 뒤 저장을 눌러 주세요." : "외장 화면을 연결하면 저장된 배치로 복원할 수 있습니다.")
            .font(.callout).foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 삭제 확인 — 목록 위 한 곳에서 묻는다. 메뉴바 패널 위에 시트를 띄우지 않는다.
    @ViewBuilder private var removalConfirmation: some View {
        if let pending = pendingRemoval {
            VStack(alignment: .leading, spacing: 6) {
                Text(CardPresentation.removalTitle(pending.name)).font(.callout.weight(.semibold))
                Text(CardPresentation.removalDetail(windowCount: savedWindowCount(of: pending.bundleID)))
                    .font(.caption).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(CardPresentation.removeRecordsAction, role: .destructive) {
                        pendingRemoval = nil
                        Task { await controller.remove(pending.bundleID, on: pending.screenID) }
                    }
                    .buttonStyle(CardActionStyle(palette: palette, prominent: true))
                    Button("취소") { pendingRemoval = nil }
                        .buttonStyle(CardActionStyle(palette: palette, prominent: false))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        }
    }

    /// 삭제는 작업 환경 전체의 그 앱 기록을 지운다 — 확인 문구의 수도 모든 화면을 합친다.
    private func savedWindowCount(of bundleID: String) -> Int {
        sections.reduce(0) { total, section in
            let rows = section.presentApps + section.absentSavedApps + section.excludedApps
            return total + (rows.first { $0.bundleID == bundleID }?.windowCount ?? 0)
        }
    }

    private func requestRemoval(_ app: PlugbackController.AppRow, in section: PlugbackController.ScreenSection) {
        pendingRemoval = PendingRemoval(bundleID: app.bundleID, name: app.displayName, screenID: section.screenID)
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
                                remove: app.isSaved ? { requestRemoval(app, in: section) } : nil)
                }
            }
        } else {
            appRows(apps, in: section)
        }
    }

    private func appRows(_ apps: [PlugbackController.AppRow], in section: PlugbackController.ScreenSection) -> some View {
        VStack(spacing: 0) {
            ForEach(apps) { app in
                CardAppRow(bundleID: app.bundleID, name: app.displayName,
                    isEnabled: app.isEnabled, isRunning: isRunning(app.bundleID), windowCount: app.windowCount,
                    isSaved: app.isSaved, layout: layout, palette: palette,
                    setTracked: { setTracked(app.bundleID, $0, in: section) },
                    remove: app.isSaved ? { requestRemoval(app, in: section) } : nil)
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
                    remove: app.windowCount > 0 ? { requestRemoval(app, in: section) } : nil)
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

    /// 선택한 Space의 안내 — 남은 항목 전체의 안내는 상태 구획이 따로 보인다.
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
