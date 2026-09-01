import Foundation

/// AX 창 열거와 그 열거에 대응하는 Space snapshot의 단일 입구.
/// 둘을 한 값으로 돌려줘 서로 다른 열거의 임시 window ID를 섞을 수 없게 한다.
@MainActor
final class DesktopObservation {
    struct Sample {
        let windows: [WindowInfo]
        let snapshot: SpaceSnapshot?
    }

    private let gateway: WindowGateway
    private let spaceReader: SpaceReading?
    private var readsInFlight = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(gateway: WindowGateway, spaceReader: SpaceReading?) {
        self.gateway = gateway
        self.spaceReader = spaceReader
    }

    func sample(of bundleIDs: [String]? = nil, includeSpaces: Bool = true) async -> Sample {
        readsInFlight += 1
        defer {
            readsInFlight -= 1
            if readsInFlight == 0 {
                let waiters = readWaiters
                readWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        let windows = await gateway.standardWindows(of: bundleIDs)
        guard includeSpaces, let spaceReader else {
            return Sample(windows: windows, snapshot: nil)
        }
        let ids = Array(Set(windows.compactMap(\.windowServerID))).sorted()
        let availability = await spaceReader.stableSnapshot(windowServerIDs: ids)
        guard case .available(let snapshot) = availability else {
            return Sample(windows: windows, snapshot: nil)
        }
        return Sample(windows: windows, snapshot: snapshot)
    }

    func drain() async {
        guard readsInFlight > 0 else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
}
