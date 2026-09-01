import Foundation

/// AX 창 열거와 그 열거에 대응하는 Space snapshot의 단일 입구.
/// 둘을 한 값으로 돌려줘 서로 다른 열거의 임시 window ID를 섞을 수 없게 한다.
@MainActor
final class DesktopObservation {
    struct Sample {
        /// 이 observation 안에서 관찰을 시작한 순서. 늦게 끝난 예전 sample을 버릴 때 쓴다.
        let sequence: Int
        let windows: [WindowInfo]
        /// nil은 Space를 관찰하지 않은 유효한 flat 경로다.
        /// reader가 있는데 관찰하지 못한 경우는 `.unavailable`로 보존한다.
        let spaceAvailability: SpaceSnapshotAvailability?
    }

    private let gateway: WindowGateway
    private let spaceReader: SpaceReading?
    private var nextSequence = 0
    private var readsInFlight = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(gateway: WindowGateway, spaceReader: SpaceReading?) {
        self.gateway = gateway
        self.spaceReader = spaceReader
    }

    func sample(of bundleIDs: [String]? = nil, includeSpaces: Bool = true) async -> Sample {
        nextSequence += 1
        let sequence = nextSequence
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
            return Sample(sequence: sequence, windows: windows, spaceAvailability: nil)
        }
        let ids = Array(Set(windows.compactMap(\.windowServerID))).sorted()
        return Sample(
            sequence: sequence,
            windows: windows,
            spaceAvailability: await spaceReader.stableSnapshot(windowServerIDs: ids)
        )
    }

    func drain() async {
        guard readsInFlight > 0 else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
}
