import PlugbackKit
import SwiftUI

/// 시스템 강조색에 덮이지 않는 체크박스·스위치. 보조 기술에는 표준 Toggle을 제공한다.
struct CardToggleStyle: ToggleStyle {
    let palette: CardPalette
    var isSwitch = false
    var controlOnTrailingEdge = false
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                let control = Group {
                    if isSwitch {
                        Capsule().fill(configuration.isOn ? palette.accent : palette.border)
                            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                                Circle().fill(configuration.isOn ? palette.onAccent : palette.text)
                                    .frame(width: size - 4, height: size - 4).padding(3)
                            }
                            .frame(width: size + 12, height: size + 2)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(configuration.isOn ? palette.accent : palette.background)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(configuration.isOn ? palette.accent : palette.secondary))
                            .overlay {
                                if configuration.isOn {
                                    Image(systemName: "checkmark").font(.system(size: size - 4, weight: .bold))
                                        .foregroundStyle(palette.onAccent)
                                }
                            }
                            .frame(width: size, height: size)
                    }
                }
                if !controlOnTrailingEdge { control }
                configuration.label
                if controlOnTrailingEdge { control }
            }
            .frame(minHeight: isSwitch ? 28 : 0)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(CardPressStyle())
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 3)
            .strokeBorder(focused ? palette.accent : Color.clear, lineWidth: 2))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.78 : 1)
    }
}

/// 팔레트와 키보드 포커스를 유지하는 메뉴바 카드의 동작 버튼.
struct CardActionStyle: ButtonStyle {
    let palette: CardPalette
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(prominent ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: 32)
            .foregroundStyle(prominent ? palette.onAccent : palette.text)
            .background(prominent ? palette.accent : palette.surface,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? palette.accent : (prominent ? palette.accent : palette.border),
                              lineWidth: focused ? 2 : 1))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .fill(palette.text.opacity(hovered && isEnabled ? 0.04 : 0))
                .allowsHitTesting(false))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .focused($focused)
            .onHover { hovered = $0 }
    }
}

/// MenuBarExtra가 목록 높이를 0으로 접지 않게 내용을 측정하고, 긴 목록에는 상한을 둔다.
struct CardScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                // 오버레이 스크롤바가 행의 상태·삭제 버튼·구분선을 덮지 않게 한다.
                .padding(.trailing, 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

struct CardAppRow: View {
    let bundleID: String
    let name: String
    let isEnabled: Bool
    let isRunning: Bool?
    let layout: CardLayout
    let palette: CardPalette
    let setTracked: (Bool) -> Void
    let remove: (() -> Void)?
    @State private var hovered = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { isEnabled }, set: setTracked)) {
                HStack(spacing: 8) {
                    identity
                    Spacer(minLength: 4)
                    runningStatus
                }
                .padding(.vertical, layout.rowPadding)
                .frame(maxWidth: .infinity,
                       minHeight: rowHeight,
                       alignment: .leading)
            }
            .toggleStyle(CardToggleStyle(palette: palette))
            .accessibilityLabel(name)
            .help(isEnabled ? "복원 대상에서 제외" : "복원 대상에 포함")
            if !isEnabled, let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle").frame(width: 24, height: 24)
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondary)
                    .help("프로필에서 삭제")
                    .accessibilityLabel("\(name) 프로필에서 삭제")
            }
        }
        .background(hovered ? palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            if let remove { Button("프로필에서 삭제", role: .destructive, action: remove) }
        }
    }

    private var identity: some View {
        HStack(spacing: 8) {
            CardAppIcon(bundleID: bundleID, size: 20)
            Text(name).font(.body)
                .foregroundStyle(isEnabled ? palette.text : palette.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help("\(name)\n\(bundleID)")
        }
    }

    @ViewBuilder private var runningStatus: some View {
        if isRunning == false {
            Text(CardPresentation.notRunningLabel)
                .font(.caption).foregroundStyle(palette.secondary)
                .fixedSize()
        }
    }
}

struct CardResultStrip: View {
    let results: [RestoreResult]
    let restoredAt: Date?
    let palette: CardPalette
    @State private var expanded = false
    @ScaledMetric(relativeTo: .callout) private var detailCap: CGFloat = 144

    var body: some View {
        let moved = results.reduce(0) { $0 + $1.movedCount }
        let skipped = results.reduce(0) { $0 + $1.skippedCount }
        let failed = results.reduce(0) { $0 + $1.failedCount }
        VStack(alignment: .leading, spacing: 6) {
            if failed > 0 {
                Label {
                    Text("\(failureNames) 복원 실패").foregroundStyle(palette.text)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !results.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    CardScrollView(maxHeight: detailCap) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(results, id: \.screenID) { result in
                                ForEach(result.entries, id: \.bundleID) { entry in
                                    Label("\(entry.displayName) — \(CardPresentation.describe(entry.outcome))",
                                          systemImage: CardPresentation.symbolName(for: entry.outcome))
                                        .foregroundStyle(entry.outcome == .failed ? palette.text : palette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("마지막 복원 · 이동 \(moved) · 건너뜀 \(skipped) · 실패 \(failed)")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let restoredAt {
                            Text(CardPresentation.relative(restoredAt)).fixedSize()
                        }
                    }
                    .accessibilityLabel("마지막 복원 · 이동 \(moved) · 건너뜀 \(skipped) · 실패 \(failed)"
                                        + (restoredAt.map { " · \(CardPresentation.relative($0))" } ?? ""))
                }
                .help("마지막 복원 결과 펼치기")
                .foregroundStyle(palette.secondary)
            }
        }
        .font(.caption)
    }

    private var failureNames: String {
        let names = results.flatMap(\.entries).filter { $0.outcome == .failed }.map(\.displayName)
        let first = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(first) 외 \(names.count - 2)개 앱" : first
    }
}

/// 목록·요약·보드에서 같은 설치 아이콘을 쓴다. 파일 조회는 identity가 바뀔 때만 한다.
struct CardAppIcon: View {
    let bundleID: String
    var size: CGFloat = 24
    @State private var image: NSImage?
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() }
            else { Image(systemName: "app").resizable() }
        }
        .scaledToFit()
        .frame(width: size * scale, height: size * scale)
        .accessibilityHidden(true)
        .task(id: bundleID) {
            image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }
}

struct CardAppTile: View {
    let app: TargetApp
    let isRunning: Bool
    let palette: CardPalette
    let setTracked: (Bool) -> Void
    let remove: () -> Void
    @ScaledMetric(relativeTo: .caption2) private var tileHeight: CGFloat = 62
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { setTracked(!app.isEnabled) } label: {
            VStack(spacing: 5) {
                CardAppIcon(bundleID: app.bundleID, size: 28)
                Text(app.displayName).font(.caption2).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: tileHeight)
            .padding(.horizontal, 3)
            .overlay(alignment: .topLeading) {
                Image(systemName: app.isEnabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11)).foregroundStyle(palette.accent)
                    .padding(3)
            }
            .overlay(alignment: .topTrailing) {
                if !isRunning {
                    Circle().fill(palette.secondary).frame(width: 4, height: 4).padding(5)
                }
            }
            .background(hovered ? palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .foregroundStyle(palette.text)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? palette.accent : Color.clear, lineWidth: 2))
        .onHover { hovered = $0 }
        .help("\(app.displayName)\(isRunning ? "" : " · 꺼짐")\n복원 대상에서 제외")
        .accessibilityRepresentation {
            Toggle(app.displayName, isOn: Binding(get: { app.isEnabled }, set: setTracked))
                .accessibilityHint(isRunning ? "" : "실행하지 않은 앱")
        }
        .contextMenu { Button("프로필에서 삭제", role: .destructive, action: remove) }
    }
}
