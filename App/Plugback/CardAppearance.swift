import SwiftUI

/// 표시 설정은 앱에만 속한다. 프로필·복원 소스와 별개로 각각 보존한다.
struct CardAppearance: DynamicProperty {
    @AppStorage var layout: CardLayout
    @AppStorage var colors: CardColors
    @AppStorage var brightness: CardBrightness

    init(store: UserDefaults? = nil) {
        _layout = AppStorage(wrappedValue: .status, "appearance.layout", store: store)
        _colors = AppStorage(wrappedValue: .sage, "appearance.colors", store: store)
        _brightness = AppStorage(wrappedValue: .system, "appearance.brightness", store: store)
    }

    func palette(systemScheme: ColorScheme) -> CardPalette {
        colors.palette(for: brightness.colorScheme ?? systemScheme)
    }
}

enum CardLayout: String, CaseIterable {
    // 기존 설치의 선택값을 유지한다. 표시 순서는 새 시안 A–D를 따른다.
    case status = "comfortable"
    case list = "compact"
    case spaces = "command"
    case board = "grouped"

    var title: String {
        switch self {
        case .status: "A · 상태 카드"
        case .list: "B · 빠른 목록"
        case .spaces: "C · Space 탐색"
        case .board: "D · 아이콘 보드"
        }
    }

    var detail: String {
        switch self {
        case .status: "작은 카드에서 복원하고, 대상 앱은 관리 화면에서 고릅니다."
        case .list: "검색 가능한 촘촘한 목록에서 대상 앱을 바로 고릅니다."
        case .spaces: "저장된 Space별로 앱을 살펴봅니다. 복원은 전체 대상에 적용됩니다."
        case .board: "앱 아이콘을 한눈에 보고 복원 대상을 고릅니다."
        }
    }

    var width: CGFloat {
        switch self {
        case .status: 360
        case .list: 364
        case .spaces: 440
        case .board: 400
        }
    }

    var inset: CGFloat { self == .status ? 22 : 16 }
    var rowPadding: CGFloat { 2 }
    var frameWidth: CGFloat { 1 }
    var innerCornerRadius: CGFloat { cornerRadius - frameWidth }
    var cornerRadius: CGFloat { 17 }
}

/// 콘텐츠와 바깥 프레임을 각각 자른다. 헤더·푸터의 배경도 안쪽 곡선을 따른다.
struct CardSurface: ViewModifier {
    let layout: CardLayout
    let palette: CardPalette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.text)
            .background(palette.background)
            .clipShape(RoundedRectangle(cornerRadius: layout.innerCornerRadius))
            .padding(layout.frameWidth)
            .background(palette.border)
            .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius))
            .frame(width: layout.width)
            .tint(palette.accent)
    }
}

enum CardColors: String, CaseIterable {
    case graphite, porcelain, coral, sage

    var title: String {
        switch self {
        case .graphite: "Graphite · 바이올렛"
        case .porcelain: "Porcelain · 블루"
        case .coral: "Coral · 코랄"
        case .sage: "Sage · 세이지"
        }
    }

    func palette(for scheme: ColorScheme) -> CardPalette {
        switch (self, scheme == .dark) {
        case (.graphite, false):
            CardPalette(background: 0xFAFAFA, surface: 0xEEEDF2, text: 0x24242B,
                        secondary: 0x666572, border: 0xDEDDE5, accent: 0x5E56BA,
                        onAccent: 0xFFFFFF, groupAccent: 0x625D98, frame: 0xDEDDE5, soft: 0xF5F4F7, accentSoft: 0xEFEDF9)
        case (.graphite, true):
            CardPalette(background: 0x1B1C20, surface: 0x24252B, text: 0xEEEEEF,
                        secondary: 0xA3A4AF, border: 0x34353E, accent: 0xB5B3FF,
                        onAccent: 0x202039, groupAccent: 0xA8A6E5, frame: 0x34353E, soft: 0x202126, accentSoft: 0x333247)
        case (.porcelain, false):
            CardPalette(background: 0xFFFEFA, surface: 0xF1F0E9, text: 0x2D302A,
                        secondary: 0x65695E, border: 0xE5E5DC, accent: 0x3264C7,
                        onAccent: 0xFFFFFF, groupAccent: 0x3264C7, frame: 0xD8DDD3, soft: 0xF7F6EF, accentSoft: 0xEDF2FC)
        case (.porcelain, true):
            CardPalette(background: 0x232421, surface: 0x30312C, text: 0xF3F2EC,
                        secondary: 0xB1B2A8, border: 0x404239, accent: 0xA8C5FF,
                        onAccent: 0x1C2C4A, groupAccent: 0xA8C5FF, frame: 0x404239, soft: 0x292A25, accentSoft: 0x303C51)
        case (.coral, false):
            CardPalette(background: 0xFBFAF8, surface: 0xEBE8E4, text: 0x302A25,
                        secondary: 0x6B6059, border: 0xDED7D1, accent: 0xA5442D,
                        onAccent: 0xFFFFFF, groupAccent: 0xA5442D, frame: 0xDFCEC4, soft: 0xF4F2EE, accentSoft: 0xF3E4DD)
        case (.coral, true):
            CardPalette(background: 0x202020, surface: 0x30302F, text: 0xF4F2EF,
                        secondary: 0xB2AFA9, border: 0x3E3C38, accent: 0xF3B49F,
                        onAccent: 0x35241C, groupAccent: 0xF3B49F, frame: 0x59443C, soft: 0x272726, accentSoft: 0x3E302A)
        case (.sage, false):
            CardPalette(background: 0xF8F8F7, surface: 0xEEEEEC, text: 0x30302F,
                        secondary: 0x656560, border: 0xDEDEDA, accent: 0x465E41,
                        onAccent: 0xFFFFFF, groupAccent: 0x715786, frame: 0xDADAD6, soft: 0xF3F3F1, accentSoft: 0xE1E9D6)
        case (.sage, true):
            CardPalette(background: 0x242424, surface: 0x303030, text: 0xF2F2F0,
                        secondary: 0xB8B8B2, border: 0x424240, accent: 0xD4DFB7,
                        onAccent: 0x283824, groupAccent: 0xDBC9F2, frame: 0x484846, soft: 0x292929, accentSoft: 0x344432)
        }
    }
}

enum CardBrightness: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "시스템 설정"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct CardPalette {
    let background, surface, text, secondary, border, accent, onAccent, groupAccent, frame, soft, accentSoft: Color

    init(background: UInt32, surface: UInt32, text: UInt32, secondary: UInt32,
         border: UInt32, accent: UInt32, onAccent: UInt32, groupAccent: UInt32, frame: UInt32, soft: UInt32, accentSoft: UInt32) {
        func color(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255,
                  opacity: 1)
        }
        self.background = color(background)
        self.surface = color(surface)
        self.text = color(text)
        self.secondary = color(secondary)
        self.border = color(border)
        self.accent = color(accent)
        self.onAccent = color(onAccent)
        self.groupAccent = color(groupAccent)
        self.frame = color(frame)
        self.soft = color(soft)
        self.accentSoft = color(accentSoft)
    }
}

/// 선택 상태는 색뿐 아니라 체크 표시로도 드러낸다. 설정 창은 네이티브 Form을 유지한다.
struct AppearanceSection: View {
    @Binding var layout: CardLayout
    @Binding var colors: CardColors
    @Binding var brightness: CardBrightness
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        Section("모양") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("레이아웃", selection: $layout) {
                    ForEach(CardLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(layout.detail).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("색상", selection: $colors) {
                    ForEach(CardColors.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack(spacing: 6) {
                    let palette = colors.palette(for: brightness.colorScheme ?? systemScheme)
                    ForEach(Array([palette.background, palette.surface, palette.accent,
                                   palette.groupAccent].enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.3)))
                            .frame(width: 26, height: 18)
                    }
                    Text("변경 사항은 바로 적용됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("선택한 색상: \(colors.title). 레이아웃과 별도로 적용됩니다.")
            }
            Picker("밝기", selection: $brightness) {
                ForEach(CardBrightness.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

#Preview("모양 설정") {
    Form {
        AppearanceSection(layout: .constant(.status), colors: .constant(.porcelain),
                          brightness: .constant(.system))
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
