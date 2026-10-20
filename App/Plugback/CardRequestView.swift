import SwiftUI

/// 현재 요청의 남은 항목 — 이동·잠금·방문 대기는 화면 이름과 함께 묶어 보이고, 확인 필요는 「복원 확인」 창 진입점이 맡는다 (3.8·3.12절).
/// 대기 줄은 안내일 뿐 버튼이 아니다 — Space는 사용자가 macOS에서 연다. 재개·취소는 상태 구획의 버튼이 한다.
struct CardRequestView: View {
    let lines: [RequestLine]
    let guides: [String]
    /// 0이면 진입점을 그리지 않는다 — 확인 필요가 상태 문장이면 「창 확인하기」 버튼이 같은 일을 한다.
    let confirmationCount: Int
    let palette: CardPalette
    let openConfirmation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !lines.isEmpty {
                // 같은 화면·Space의 저장 창은 이미 한 줄로 묶였다. 그래도 화면·Space가 많으면 상한 안에서 스크롤한다.
                CardScrollView(maxHeight: 96) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: line.symbol).foregroundStyle(palette.secondary)
                                    .frame(width: 14).accessibilityHidden(true)
                                Text(line.text).foregroundStyle(palette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            ForEach(guides, id: \.self) { guide in
                Text(guide).font(.caption).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirmationCount > 0 {
                Button(action: openConfirmation) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle").frame(width: 14).accessibilityHidden(true)
                        Text("창 확인 필요 \(confirmationCount)개")
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(palette.accent)
                .accessibilityIdentifier("card.confirmation.open")
                .help("어떤 앱의 어떤 저장 창을 확인해야 하는지 보여줍니다.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
    }
}
