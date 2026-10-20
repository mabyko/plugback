import PlugbackKit
import SwiftUI

// 메뉴바 카드 — 작업 환경 헤더, 상태 구획(상태·다음 행동·남은 항목·복원 소스·결과), 경고, 레이아웃별 대상 앱, 푸터 순서다
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

// 상태 구획은 모든 레이아웃의 목록 위에 있다 — 목록은 늘고 스크롤되므로, 상태와 다음 행동이 메뉴바 바로 아래에 먼저 읽힌다.
struct Card: View {
    @ObservedObject var controller: PlugbackController
    let layout: CardLayout
    let palette: CardPalette
    @State private var showingManager = false

    private var isManaging: Bool { layout == .status && showingManager }

    var body: some View {
        let sections = controller.sections
        VStack(alignment: .leading, spacing: 0) {
            if isManaging {
                managerHeader
            } else {
                header(sections)
                separator
                CardStatusView(controller: controller, sections: sections, layout: layout, palette: palette)
            }
            CardNoticeList(controller: controller, layout: layout, palette: palette)
            separator
            if layout == .status && !isManaging {
                appSummary(sections)
            } else {
                CardAppBrowser(controller: controller, layout: layout, palette: palette)
            }
            separator
            footer
        }
        .font(.body)
    }

    private var separator: some View {
        palette.border.frame(height: 1).accessibilityHidden(true)
    }

    /// 작업 환경 = 연결된 외장 화면 조합. 화면이 몇 대든 모든 화면 이름을 보이고, 배지는 연결 여부만 말한다.
    private func header(_ sections: [PlugbackController.ScreenSection]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "display")
                .foregroundStyle(controller.isConnected ? palette.accent : palette.secondary)
                .accessibilityHidden(true)
            Text(CardPresentation.headerTitle(screens: sections.map(\.label)))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let badge = CardPresentation.headerBadge(for: controller.screenPresence) {
                HStack(spacing: 5) {
                    Circle().fill(badge.highlighted ? Color.green : palette.secondary)
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(badge.text)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(palette.surface, in: Capsule())
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, layout.inset).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var managerHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { showingManager = false } label: {
                Label("돌아가기", systemImage: "chevron.left").labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("card.manager.back")
            VStack(alignment: .leading, spacing: 2) {
                Text("대상 앱 관리").font(.headline)
                Text(CardPresentation.selectionScopeNote).font(.caption).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, layout.inset).padding(.vertical, 10)
    }

    /// 상태 카드의 대상 앱 한 줄 — 누르면 세 묶음 관리 화면으로 들어간다.
    private func appSummary(_ sections: [PlugbackController.ScreenSection]) -> some View {
        // 지금 화면에 있는 앱이 먼저, 화면에 없는 저장 앱은 뒤에 — 첫인상이 지금 화면과 맞아야 한다
        let apps = sections.flatMap(\.presentApps) + sections.flatMap(\.absentSavedApps)
        let unique = apps.reduce(into: [PlugbackController.AppRow]()) { result, app in
            if !result.contains(where: { $0.bundleID == app.bundleID }) { result.append(app) }
        }
        let spaces = sections.flatMap(\.spaceGroups).filter {
            if case .regular = $0.kind { return true }; return false
        }.count
        let summary = CardPresentation.targetSummary(
            hasSnapshot: controller.hasRestorableProfile, appCount: controller.enabledAppCount,
            windowCount: controller.savedWindowCount, spaceCount: spaces,
            presentAppCount: Set(sections.flatMap(\.presentApps).map(\.bundleID)).count)
        return Button { showingManager = true } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("대상 앱 관리").font(.callout.weight(.medium)).foregroundStyle(palette.text)
                    Text(summary).font(.caption).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    ForEach(Array(unique.prefix(5))) { app in
                        CardAppIcon(bundleID: app.bundleID, size: 20)
                    }
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("대상 앱 관리, \(summary)")
        .accessibilityIdentifier("card.manager.open")
        .padding(.horizontal, layout.inset).padding(.vertical, 10)
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
