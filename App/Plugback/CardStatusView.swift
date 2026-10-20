import PlugbackKit
import SwiftUI

extension CardFacts {
    /// 컨트롤러의 공개 읽기 Interface를 그대로 옮긴다 — 뷰가 상태를 다시 판정하지 않는다.
    init(_ controller: PlugbackController) {
        self.init(presence: controller.screenPresence, hasSnapshot: controller.hasRestorableProfile,
                  isRestoring: controller.isRestoring, isSettling: controller.isSettlingScreens,
                  isSaveBlocked: controller.isSaveBlocked, autoSave: controller.autoSave,
                  restoreMode: controller.restoreMode, openItems: controller.waitingItems,
                  results: controller.lastResults)
    }
}

/// 상태 구획 — 지금 상태 한 문장과 그 상태의 다음 행동, 남은 항목, 복원 소스, 마지막 결과 순서다.
/// 모든 레이아웃이 같은 구획을 쓴다. 문구·우선순위·버튼은 CardPresentation이 정하고 여기서는 배치만 한다.
struct CardStatusView: View {
    @ObservedObject var controller: PlugbackController
    let sections: [PlugbackController.ScreenSection]
    let layout: CardLayout
    let palette: CardPalette
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let facts = CardFacts(controller)
        let status = CardPresentation.status(facts)
        VStack(alignment: .leading, spacing: 10) {
            headline(CardPresentation.statusText(status, facts: facts),
                     settlingAside: facts.isSettling && status != .settling)
            if !facts.openItems.isEmpty {
                let showsLink: Bool = { if case .needsConfirmation = status { return false } else { return true } }()
                CardRequestView(lines: CardPresentation.requestLines(facts.openItems),
                                guides: CardPresentation.requestGuides(in: sections),
                                confirmationCount: showsLink ? controller.confirmationCount : 0,
                                palette: palette, openConfirmation: openConfirmation)
            }
            buttons(CardPresentation.buttons(for: status, facts: facts),
                    additional: CardPresentation.additionalButtons(facts))
            if layout == .spaces {
                // Space 목록은 보기만 바꾼다 — 복원 범위가 전체 대상임을 버튼 곁에서 말한다
                Text("대상 앱 \(controller.enabledAppCount)개 · 창 \(controller.savedWindowCount)개 복원")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            if let feedback = CardPresentation.captureFeedback(controller.captureNotice,
                                                               spacesSupport: controller.spacesSupport) {
                note(feedback.isWarning ? "exclamationmark.triangle.fill" : "checkmark", feedback.text,
                     font: .callout, color: feedback.isWarning ? palette.text : palette.accent,
                     symbolColor: feedback.isWarning ? .orange : palette.accent)
            }
            source(facts)
            let results = facts.visibleResults
            if !results.isEmpty {
                CardResultStrip(results: results, restoredAt: controller.lastRestoredAt,
                                screenNames: Dictionary(sections.map { ($0.screenID, CardPresentation.screenName($0.label)) },
                                                        uniquingKeysWith: { first, _ in first }),
                                palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, layout.inset).padding(.vertical, 12)
    }

    private var titleFont: Font { layout == .status ? .title2 : .title3 }

    private func headline(_ text: CardStatusText, settlingAside: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let symbol = text.symbol {
                    Image(systemName: symbol).foregroundStyle(tint(text.tone))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .font(titleFont)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(text.title).font(titleFont.weight(.semibold))
                if let detail = text.detail {
                    Text(detail).font(.callout).foregroundStyle(palette.secondary)
                }
                if settlingAside {
                    Text(CardPresentation.settlingStatus).font(.caption).foregroundStyle(palette.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// 색은 보조다 — 상태는 기호와 문장이 함께 말한다.
    private func tint(_ tone: CardStatusText.Tone) -> Color {
        switch tone {
        case .neutral: palette.secondary
        case .attention: .orange
        case .done: palette.accent
        case .failure: .red
        }
    }

    private func buttons(_ specs: [CardButton], additional: [CardButton]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                Button { perform(spec.action) } label: {
                    Group {
                        if let symbol = spec.symbol { Label(spec.title, systemImage: symbol) } else { Text(spec.title) }
                    }
                    .frame(maxWidth: index == 0 ? .infinity : nil)
                }
                .buttonStyle(CardActionStyle(palette: palette, prominent: index == 0))
                .disabled(!spec.isEnabled)
                .accessibilityLabel(spec.accessibilityLabel)
                .help(spec.accessibilityLabel)
            }
            if !additional.isEmpty {
                Menu {
                    ForEach(additional) { spec in
                        Button(spec.title) { perform(spec.action) }
                            .disabled(!spec.isEnabled)
                    }
                } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("다른 동작")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("지금 배치를 저장하거나 새 복원을 시작합니다")
            }
        }
    }

    private func perform(_ action: CardAction) {
        switch action {
        case .save: Task { await controller.captureNow() }
        case .restore: Task { await controller.restoreNow() }
        case .resumeRemaining: Task { await controller.resumeRemaining() }
        case .cancelRemaining: controller.cancelRemaining()
        case .openConfirmation: openConfirmation()
        }
    }

    private func openConfirmation() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: RestoreConfirmationView.windowID)
    }

    /// 복원 소스(저장 완료본)와 저장 대기 이력은 다른 기호·크기·색이다 — 이력은 복원 기준이 아니다.
    @ViewBuilder private func source(_ facts: CardFacts) -> some View {
        let source = CardPresentation.sourceLabel(for: sections)
        let pending = CardPresentation.pendingStatus(
            autoSave: controller.autoSave, isSaveBlocked: controller.isSaveBlocked, isConnected: facts.isConnected,
            collectedAt: controller.lastCollectedAt, hasPending: controller.hasPendingCollect,
            spaceConfigurationDiffers: controller.spaceConfigurationDiffers)
        if source != nil || pending != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let source {
                    note("tray.and.arrow.down", source, font: .callout, color: palette.text, symbolColor: palette.secondary)
                }
                if let pending {
                    note(pending.isWarning ? "exclamationmark.triangle.fill" : "hourglass", pending.text, font: .caption,
                         color: pending.isWarning ? palette.text : palette.secondary,
                         symbolColor: pending.isWarning ? .orange : palette.secondary)
                }
            }
        }
    }

    private func note(_ symbol: String, _ text: String, font: Font, color: Color, symbolColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(symbolColor)
                .frame(width: 14).accessibilityHidden(true)
            Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
    }
}

/// 저장소·화면 경고 — 해당할 때만, 각각 따로 보인다. 상태 문장이 이 경고를 덮지 않고 이 경고도 결과를 덮지 않는다.
struct CardNoticeList: View {
    @ObservedObject var controller: PlugbackController
    let layout: CardLayout
    let palette: CardPalette

    var body: some View {
        let trouble = controller.storeNotice
        let spaces = controller.spacesSupport
        let failed = controller.allWorkspaces.filter { controller.saveFailedWorkspaces.contains($0.key) }
        if trouble != nil || !failed.isEmpty || controller.identityMismatch || spaces != .separateSpaces {
            VStack(alignment: .leading, spacing: 0) {
                palette.border.frame(height: 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    if let trouble { storeNotice(trouble) }
                    ForEach(failed) { workspace in
                        VStack(alignment: .leading, spacing: 6) {
                            warning(CardPresentation.saveFailureNotice(workspace))
                            Button("다시 시도") { controller.retrySave(workspace.key) }
                                .controlSize(.small)
                                .disabled(controller.isRestoring)
                                .padding(.leading, 21)
                        }
                    }
                    if controller.identityMismatch { warning(CardPresentation.identityMismatchNotice) }
                    if spaces != .separateSpaces { warning(CardPresentation.spacesSupportNotice(spaces)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, layout.inset).padding(.vertical, 10)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func storeNotice(_ trouble: ProfileStore.Trouble) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            warning(CardPresentation.storeNotice(trouble))
            HStack(spacing: 8) {
                if case .corruptionBackedUp(let backupURL) = trouble {
                    Button("백업 파일 보기") { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }
                }
                Button("확인") { controller.dismissStoreNotice() }
            }
            .controlSize(.small)
            .padding(.leading, 21)
        }
    }
}
