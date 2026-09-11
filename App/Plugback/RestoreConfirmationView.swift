import PlugbackKit
import SwiftUI

/// 「복원 확인」 상세 창 (3.8절). 확인이 필요한 저장 창마다 앱·화면·Space·위치·사유를 보여주고,
/// 직접 지정이 켜져 있을 때만 같은 앱의 후보를 저장 자리에 연결할 수 있다. 「남은 창 복원」으로만 재개한다.
/// 창을 열고 닫는 동작은 복원을 시작하지 않는다.
struct RestoreConfirmationView: View {
    static let windowID = "restore-confirmation"

    @ObservedObject var controller: PlugbackController
    @State private var raising: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if controller.confirmationItems.isEmpty {
                Text(controller.hasOpenRestoreItems ? "확인이 필요한 창은 없습니다. 방문·이동 대기 항목은 카드에서 볼 수 있습니다."
                                                     : "확인이 필요한 창이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.confirmationItems) { item in
                            row(item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { Task { await controller.cardOpened() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("창 확인 필요 \(controller.confirmationItems.count)개").font(.headline)
            Text(controller.directWindowAssignment
                 ? "확인한 뒤 「남은 창 복원」을 누르면 현재 조건을 다시 확인하고 남은 항목만 복원합니다."
                 : "확인한 뒤 「남은 창 복원」을 누르면 현재 조건을 다시 확인하고 남은 항목만 복원합니다. 창을 직접 고르려면 실험실에서 「복원할 창 직접 지정」을 켜세요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ item: PlugbackController.ConfirmationItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                CardAppIcon(bundleID: item.bundleID, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.body.weight(.semibold))
                    Text("\(CardPresentation.screenName(item.screen))"
                         + (item.spaceNumber.map { " · Space \($0)" } ?? " · Space 미지정")
                         + " · \(CardPresentation.placementDescription(item.unitRect))")
                        .font(.caption).foregroundStyle(.secondary)
                    if case .needsConfirmation(let reason) = item.outcome {
                        Text(CardPresentation.describe(reason)).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button("이 자리 삭제", role: .destructive) { controller.removePlacement(item.placementID) }
                    .font(.caption)
                    .help("이 저장 자리를 작업 환경 기록에서 지웁니다. 되돌릴 수 없습니다.")
            }
            if controller.directWindowAssignment, case .needsConfirmation(.ambiguousCandidates) = item.outcome {
                candidatePicker(item)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func candidatePicker(_ item: PlugbackController.ConfirmationItem) -> some View {
        HStack(spacing: 8) {
            Picker("현재 창", selection: Binding(
                get: { item.chosenWindowServerID },
                set: { controller.chooseWindow(placementID: item.placementID, windowServerID: $0) })) {
                Text("자동 배정에 맡김").tag(CGWindowID?.none)
                ForEach(item.candidates) { candidate in
                    // 제목은 표시용이다 — 저장하거나 진단 기록에 넣지 않는다 (3.7절)
                    Text(candidate.title?.isEmpty == false ? candidate.title! : "제목 없는 창 \(candidate.windowServerID)")
                        .tag(CGWindowID?.some(candidate.windowServerID))
                }
            }
            .frame(maxWidth: 360)
            if let chosen = item.chosenWindowServerID {
                Button(raising == item.placementID ? "확인 중…" : "창 확인") {
                    raising = item.placementID
                    Task {
                        _ = await controller.raiseWindow(bundleID: item.bundleID, windowServerID: chosen)
                        raising = nil
                    }
                }
                .disabled(raising != nil)
                .help("고른 창을 앞으로 가져와 어떤 창인지 확인합니다.")
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            if controller.isRestoring {
                ProgressView().controlSize(.small)
                Text("복원 중…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("남은 창 복원") { Task { await controller.resumeRemaining() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.hasOpenRestoreItems || controller.isRestoring || !controller.isConnected)
        }
    }
}
