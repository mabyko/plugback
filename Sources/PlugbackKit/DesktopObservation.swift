import CoreGraphics
import Foundation

/// AX 창 열거와 그 열거에 대응하는 Space snapshot의 단일 입구.
/// 둘을 한 값으로 돌려줘 서로 다른 열거의 임시 window ID를 섞을 수 없게 한다.
@MainActor
final class DesktopObservation {
    struct Sample {
        /// 이 observation 안에서 관찰을 시작한 순서. 늦게 끝난 예전 sample을 버릴 때 쓴다.
        let sequence: Int
        let windows: [WindowInfo]
        /// 창 목록을 읽지 못한 앱 — 이 앱의 창 부재를 닫힘으로 판정하지 않는다.
        let unavailableBundleIDs: Set<String>
        /// nil은 Space를 관찰하지 않은 유효한 flat 경로다.
        /// reader가 있는데 관찰하지 못한 경우는 `.unavailable`로 보존한다.
        let spaceAvailability: SpaceSnapshotAvailability?
        /// 지금 존재하는 창 전부의 WindowServer ID — AX 열거는 다른 Space의 창을 돌려주지 않으므로
        /// 창 부재를 닫힘으로 판정하는 근거는 이 집합이다. nil이면 닫힘을 판정하지 않는다 (F-03.6).
        var existingWindowServerIDs: Set<CGWindowID>? = nil

        var snapshot: SpaceSnapshot? {
            if case .some(.available(let value)) = spaceAvailability { return value }
            return nil
        }
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

    /// 지금까지 시작한 관찰의 마지막 순서 번호 — 이 뒤에 시작한 관찰만 새것이다.
    var latestSequence: Int { nextSequence }

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
        let failures = await gateway.enumerationFailures()
        let existing = await gateway.existingWindowServerIDs()
        guard includeSpaces, let spaceReader else {
            return Sample(sequence: sequence, windows: windows, unavailableBundleIDs: failures,
                          spaceAvailability: nil, existingWindowServerIDs: existing)
        }
        let ids = Array(Set(windows.compactMap(\.windowServerID))).sorted()
        return Sample(
            sequence: sequence,
            windows: windows,
            unavailableBundleIDs: failures,
            spaceAvailability: await spaceReader.stableSnapshot(windowServerIDs: ids),
            existingWindowServerIDs: existing
        )
    }

    func drain() async {
        guard readsInFlight > 0 else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
}
