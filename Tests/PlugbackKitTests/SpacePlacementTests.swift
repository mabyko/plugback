import XCTest
@testable import PlugbackKit

final class SpacePlacementTests: XCTestCase {
    func testDuplicateNameAcrossScreensIsUnknown() {
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: "BUILTIN", spaces: [
                    space(1, "shared", order: 1, current: true),
                ]),
                .init(screenID: "EXTERNAL", spaces: [
                    space(2, "shared", order: 1, current: true),
                ]),
            ],
            membershipsByWindowServerID: [:]
        )

        XCTAssertEqual(
            SpacePlacement.of(
                SpaceHint(opaqueName: "shared", localOrderHint: 99),
                on: "EXTERNAL",
                in: snapshot
            ),
            .unknown(.name)
        )
    }

    func testRuntimeIDReturnsCurrentSpaceWithLiveIdentity() {
        let target = space(7, "remembered", order: 3, current: true)
        let snapshot = SpaceSnapshot(
            displays: [.init(screenID: "EXTERNAL", spaces: [target])],
            membershipsByWindowServerID: [:]
        )

        XCTAssertEqual(
            SpacePlacement.of(
                SpaceRuntimeID(7), on: "EXTERNAL", in: snapshot
            ),
            .current(.init(
                screenID: "EXTERNAL",
                space: target,
                identity: SpaceHint(opaqueName: "remembered", localOrderHint: 3)
            ))
        )
    }

    func testWindowMembershipsJoinOnlyWhenTheyShareOneRuntimeSpace() {
        let target = space(7, "remembered", order: 1, current: true)
        let snapshot = SpaceSnapshot(
            displays: [.init(screenID: "EXTERNAL", spaces: [target])],
            membershipsByWindowServerID: [11: [SpaceRuntimeID(7)], 12: [SpaceRuntimeID(7)]]
        )

        XCTAssertEqual(
            SpacePlacement.of(
                windowServerIDs: [11, 12], on: "EXTERNAL", in: snapshot
            ),
            .current(.init(
                screenID: "EXTERNAL",
                space: target,
                identity: SpaceHint(opaqueName: "remembered", localOrderHint: 1)
            ))
        )
    }

    func testHintPlacementTable() {
        let targetCurrent = space(1, "current", order: 2, current: true)
        let targetInactive = space(2, "inactive", order: 1)
        let stranded = space(3, "stranded", order: 3)
        let fullscreen = space(4, "fullscreen", order: 4, kind: .fullscreen, current: true)
        let unsupported = space(5, "unsupported", order: 5, kind: .unknown(99))
        let snapshot = SpaceSnapshot(
            displays: [
                .init(screenID: "BUILTIN", spaces: [stranded]),
                .init(
                    screenID: "EXTERNAL",
                    spaces: [targetCurrent, targetInactive, fullscreen, unsupported]
                ),
            ],
            membershipsByWindowServerID: [:]
        )
        let rows: [(String, SpacePlacement)] = [
            ("current", .current(.init(
                screenID: "EXTERNAL", space: targetCurrent,
                identity: SpaceHint(opaqueName: "current", localOrderHint: 2)
            ))),
            ("inactive", .inactive(.init(
                screenID: "EXTERNAL", space: targetInactive,
                identity: SpaceHint(opaqueName: "inactive", localOrderHint: 1)
            ))),
            ("stranded", .stranded(.init(
                screenID: "BUILTIN", space: stranded,
                identity: SpaceHint(opaqueName: "stranded", localOrderHint: 3)
            ))),
            ("fullscreen", .fullscreen(.init(
                screenID: "EXTERNAL", space: fullscreen, identity: nil
            ))),
            ("unsupported", .unsupported(.init(
                screenID: "EXTERNAL", space: unsupported, identity: nil
            ))),
            ("missing", .missing),
        ]

        for (name, expected) in rows {
            XCTAssertEqual(
                SpacePlacement.of(
                    SpaceHint(opaqueName: name, localOrderHint: 999),
                    on: "EXTERNAL",
                    in: snapshot
                ),
                expected,
                name
            )
        }
    }

    func testWindowMembershipFailureTable() {
        let first = SpaceRuntimeID(1)
        let second = SpaceRuntimeID(2)
        let snapshot = SpaceSnapshot(
            displays: [.init(screenID: "EXTERNAL", spaces: [
                space(1, "first", order: 1, current: true),
                space(2, "second", order: 2),
            ])],
            membershipsByWindowServerID: [
                11: [], 12: [first, second], 13: [first], 14: [second],
            ]
        )
        let rows: [([CGWindowID?], SpacePlacement)] = [
            ([nil], .unknown(.windowUnjoined)),
            ([11], .unknown(.membership(0))),
            ([12], .unknown(.membership(2))),
            ([13, 14], .unknown(.multipleSpaces)),
        ]

        for (windowIDs, expected) in rows {
            XCTAssertEqual(
                SpacePlacement.of(
                    windowServerIDs: windowIDs,
                    on: "EXTERNAL",
                    in: snapshot
                ),
                expected
            )
        }
    }

    private func space(
        _ id: UInt64,
        _ name: String?,
        order: Int,
        kind: SpaceKind = .regular,
        current: Bool = false
    ) -> SpaceSnapshot.Space {
        .init(
            runtimeID: SpaceRuntimeID(id),
            opaqueName: name,
            localOrder: order,
            kind: kind,
            isCurrent: current
        )
    }
}
