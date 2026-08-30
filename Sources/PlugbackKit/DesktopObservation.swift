import Foundation

/// AX 창 열거와 그 열거에 대응하는 Space snapshot의 단일 입구.
/// 마지막 열거의 window ID만 유효하므로 복원은 먼저 진행 중인 열거를 비운다.
@MainActor
final class DesktopObservation {
    private let gateway: WindowGateway
    private let spaceReader: SpaceReading?
    private var readsInFlight = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(gateway: WindowGateway, spaceReader: SpaceReading?) {
        self.gateway = gateway
        self.spaceReader = spaceReader
    }

    func windows(of bundleIDs: [String]?) async -> [WindowInfo] {
        readsInFlight += 1
        defer {
            readsInFlight -= 1
            if readsInFlight == 0 {
                let waiters = readWaiters
                readWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return await gateway.standardWindows(of: bundleIDs)
    }

    func drain() async {
        guard readsInFlight > 0 else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func stableSnapshot(for windows: [WindowInfo]) async -> SpaceSnapshot? {
        guard let spaceReader else { return nil }
        let ids = Array(Set(windows.compactMap(\.windowServerID))).sorted()
        let availability = await spaceReader.stableSnapshot(windowServerIDs: ids)
        guard case .available(let snapshot) = availability else { return nil }
        return snapshot
    }
}
