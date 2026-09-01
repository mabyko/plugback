#if DEBUG
import XCTest
@testable import Plugback

final class SpaceRelocationProbeTests: XCTestCase {
    func testBlockingWindowIDsIgnoreDesktopInfrastructureLayers() throws {
        let allWindowIDs = Set<UInt32>([1, 2, 3, 4, 5])
        let layersByWindowID: [UInt32: Int] = [
            1: -2_147_483_624, // Dock desktop picture
            2: -2_147_483_603, // Finder desktop
            3: -2_147_483_602, // WindowServer desktop infrastructure
            4: 24,             // WindowServer overlay
            5: 0,              // normal application window
        ]

        XCTAssertEqual(
            try RelocationProbeValidator.blockingWindowIDs(
                from: layersByWindowID, allWindowIDs: allWindowIDs
            ),
            Set<UInt32>([5])
        )
        XCTAssertThrowsError(try RelocationProbeValidator.blockingWindowIDs(
            from: layersByWindowID, allWindowIDs: allWindowIDs.union([6])
        ))
    }

    func testProbeRequiresConfirmationAndOnlyPlansAnEmptyInactiveTailSpace() throws {
        let spaceToken = "222222222222"
        let destinationToken = "333333333333"
        XCTAssertThrowsError(try RelocationProbeRequest.parse([
            "Plugback", "--space-relocation-probe", spaceToken, destinationToken,
        ]))

        let request = try RelocationProbeRequest.parse([
            "Plugback", "--space-relocation-probe", spaceToken, destinationToken,
            "--confirm-empty-sacrificial-space",
        ])
        let topology = RelocationTopology(
            displays: [
                .init(identifier: "source", token: "111111111111", spaces: [
                    .init(id: 1, token: "aaaaaaaaaaaa", name: "current", type: 0,
                          isCurrent: true),
                    .init(id: 2, token: spaceToken, name: "sacrifice", type: 0,
                          isCurrent: false),
                ]),
                .init(identifier: "destination", token: destinationToken, spaces: [
                    .init(id: 3, token: "bbbbbbbbbbbb", name: "destination", type: 0,
                          isCurrent: true),
                ]),
            ],
            membershipsByWindowID: [11: [1]]
        )

        let plan = try RelocationProbeValidator.plan(request: request, topology: topology)
        XCTAssertEqual(plan.spaceID, 2)
        XCTAssertEqual(plan.sourceIndex, 1)
        XCTAssertEqual(plan.destinationIndex, 1)
        XCTAssertEqual(plan.expectedMoved.displays[0].spaces.map(\.id), [1])
        XCTAssertEqual(plan.expectedMoved.displays[1].spaces.map(\.id), [3, 2])

        let nonEmpty = RelocationTopology(
            displays: topology.displays,
            membershipsByWindowID: [11: [1, 2]]
        )
        XCTAssertThrowsError(
            try RelocationProbeValidator.plan(request: request, topology: nonEmpty)
        )
    }
}
#endif
