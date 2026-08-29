import CoreGraphics
import XCTest
@testable import PlugbackKit

final class SpaceReaderTests: XCTestCase {
    func testStableGateAndRuntimeOnlyWindowMetadata() async {
        let runtimeID = SpaceRuntimeID(42)
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: "screen", spaces: [
                    .init(runtimeID: runtimeID, opaqueName: "opaque", localOrder: 1,
                          kind: .regular, isCurrent: true),
                ]),
            ],
            membershipsByWindowServerID: [7: [runtimeID]]
        )
        XCTAssertEqual(
            SpaceReader.settledSnapshot(first: snapshot, second: snapshot),
            .available(snapshot)
        )
        XCTAssertEqual(
            SpaceReader.settledSnapshot(
                first: snapshot,
                second: SpaceSnapshot(displays: snapshot.displays,
                                      membershipsByWindowServerID: [:])
            ),
            .unavailable
        )
        XCTAssertEqual(
            SpaceReader.settledSnapshot(first: snapshot, second: nil),
            .unavailable
        )

        let unavailable = await UnavailableSpaceReader().stableSnapshot(windowServerIDs: [7])
        XCTAssertEqual(unavailable, .unavailable)

        let unknown = WindowInfo(
            id: 1, appBundleID: "com.example", appName: "Example", frame: .zero,
            fullscreenState: .unknown, windowServerID: 7
        )
        XCTAssertFalse(unknown.isFullscreen)
        XCTAssertEqual(unknown.windowServerID, 7)
    }
}
