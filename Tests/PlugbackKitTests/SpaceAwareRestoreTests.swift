import CoreGraphics
import XCTest
@testable import PlugbackKit

@MainActor
final class SpaceAwareRestoreTests: XCTestCase {
    private let external = ScreenInfo(id: "EXTERNAL", name: "External",
                                      frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), isBuiltin: false)
    private let builtin = ScreenInfo(id: "BUILTIN", name: "Built-in",
                                     frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isBuiltin: true)
    private var key: WorkspaceKey { WorkspaceKey(screenIDs: [external.id]) }

    func testCaptureBindsEachWindowToItsCurrentSpaceOnly() {
        // 현재 Space의 창은 각각 그 Space에 기록되고, 비활성 Space의 창은 이번에 확인한 것이 아니다 (S01·W08)
        let firstID = SpaceRuntimeID(1)
        let secondID = SpaceRuntimeID(2)
        let left = window(1, bundleID: "com.app", frame: CGRect(x: 1000, y: 0, width: 500, height: 1000), windowServerID: 11)
        let right = window(2, bundleID: "com.app", frame: CGRect(x: 1500, y: 0, width: 500, height: 1000), windowServerID: 12)
        let elsewhere = window(3, bundleID: "com.app", frame: CGRect(x: 1200, y: 0, width: 400, height: 500), windowServerID: 13)
        let snapshot = makeSnapshot(
            externalSpaces: [space(firstID, "first", order: 1, current: true), space(secondID, "second", order: 2)],
            memberships: [11: [firstID], 12: [firstID], 13: [secondID]]
        )
        let observation = CaptureEngine.observe(windows: [left, right, elsewhere], screens: [builtin, external],
                                                snapshot: snapshot, base: nil, links: [:], excludedBundleIDs: [], closedPlacementIDs: [])
        XCTAssertEqual(observation.placements.count, 2)
        XCTAssertEqual(Set(observation.placements.map { $0.space?.opaqueName }), ["first"])
        XCTAssertEqual(observation.observedSpaceNames[external.id], ["first"])
        XCTAssertEqual(observation.screens.first?.regularSpaces.map(\.opaqueName), ["first", "second"])
    }

    func testCaptureRemembersEmptyRegularSpacesButNotFullscreenSpaces() {
        let snapshot = makeSnapshot(
            externalSpaces: [
                space(SpaceRuntimeID(1), "first", order: 1, current: true),
                space(SpaceRuntimeID(2), "fullscreen", order: 2, kind: .fullscreen),
                space(SpaceRuntimeID(3), "empty", order: 3),
            ],
            memberships: [:]
        )
        let observation = CaptureEngine.observe(windows: [], screens: [external], snapshot: snapshot, base: nil,
                                                links: [:], excludedBundleIDs: [], closedPlacementIDs: [])
        XCTAssertEqual(observation.screens.first?.regularSpaces, [
            SpaceHint(opaqueName: "first", localOrderHint: 1),
            SpaceHint(opaqueName: "empty", localOrderHint: 3),
        ])
    }

    func testDesktopObservationPreservesEverySpaceAvailability() async {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [
            window(1, bundleID: "com.app", windowServerID: 11),
            window(2, bundleID: "com.app", windowServerID: 7),
            window(3, bundleID: "com.app", windowServerID: 11),
            window(4, bundleID: "com.app", windowServerID: nil),
        ]
        let flat = await DesktopObservation(gateway: gateway, spaceReader: nil).sample()
        XCTAssertNil(flat.spaceAvailability)

        let reader = FakeSpaceReader()
        let observation = DesktopObservation(gateway: gateway, spaceReader: reader)
        let omitted = await observation.sample(includeSpaces: false)
        XCTAssertNil(omitted.spaceAvailability)
        XCTAssertTrue(reader.requests.isEmpty)

        reader.availability = .unavailable
        let unavailable = await observation.sample()
        XCTAssertEqual(unavailable.spaceAvailability, .unavailable)
        XCTAssertEqual(reader.requests.last, [7, 11])

        let snapshot = makeSnapshot(externalSpaces: [space(SpaceRuntimeID(1), "saved", order: 1, current: true)],
                                    memberships: [7: [SpaceRuntimeID(1)], 11: [SpaceRuntimeID(1)]])
        reader.availability = .available(snapshot)
        let available = await observation.sample()
        XCTAssertEqual(available.spaceAvailability, .available(snapshot))
    }

    func testUnavailableCapturePreservesTheSnapshot() async throws {
        let directory = temporaryDirectory("space")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(gateway: gateway, screens: screens, reader: reader, directory: directory)
        let savedID = SpaceRuntimeID(1)
        let savedFrame = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        let changedFrame = CGRect(x: 1500, y: 100, width: 400, height: 800)
        let snapshot = makeSnapshot(externalSpaces: [space(savedID, "saved", order: 1, current: true)],
                                    memberships: [11: [savedID], 12: [savedID]])

        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", frame: savedFrame, windowServerID: 11)]
        reader.availability = .available(snapshot)
        let awaited1 = await controller.captureNow()
        XCTAssertEqual(awaited1, .captured(appCount: 1, windowCount: 1))
        XCTAssertEqual(controller.captureNotice, .captured(appCount: 1, windowCount: 1))
        let saved = try XCTUnwrap(controller.allWorkspaces.first)

        gateway.runningBundleIDs.insert("com.new")
        gateway.windowsList = [
            window(1, bundleID: "com.app", frame: changedFrame, windowServerID: 11),
            window(2, bundleID: "com.new", frame: changedFrame, windowServerID: 12),
        ]
        reader.availability = .unavailable
        let awaited2 = await controller.captureNow()
        XCTAssertEqual(awaited2, .spaceObservationUnavailable)
        XCTAssertEqual(controller.captureNotice, .spaceObservationUnavailable)
        XCTAssertNil(controller.lastCaptureCount)
        XCTAssertEqual(controller.allWorkspaces.first, saved)
        XCTAssertEqual(controller.sections.first?.spaceGroups.first?.kind, .regular(number: 1, state: .unknown))
        XCTAssertEqual(controller.sections.first?.presentApps.map { "\($0.bundleID):\($0.isSaved)" }, ["com.app:true", "com.new:false"])
    }

    func testUnavailableCollectionKeepsThePendingHistory() async throws {
        let directory = temporaryDirectory("space")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(gateway: gateway, screens: screens, reader: reader, directory: directory)
        let savedID = SpaceRuntimeID(1)
        let snapshot = makeSnapshot(externalSpaces: [space(savedID, "saved", order: 1, current: true)],
                                    memberships: [11: [savedID]])
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", frame: CGRect(x: 1000, y: 0, width: 500, height: 1000), windowServerID: 11)]
        reader.availability = .available(snapshot)
        _ = await controller.captureNow()

        gateway.windowsList = [window(1, bundleID: "com.app", frame: CGRect(x: 1200, y: 0, width: 500, height: 1000), windowServerID: 11)]
        await controller.collectCandidate()
        let collectedAt = try XCTUnwrap(controller.lastCollectedAt)
        XCTAssertTrue(controller.hasPendingCollect)

        gateway.windowsList = [window(1, bundleID: "com.app", frame: CGRect(x: 1500, y: 0, width: 400, height: 1000), windowServerID: 11)]
        reader.availability = .unavailable
        await controller.collectCandidate()
        XCTAssertEqual(controller.lastCollectedAt, collectedAt)
        XCTAssertTrue(controller.hasPendingCollect)
        XCTAssertEqual(controller.sections.first?.spaceGroups.first?.kind, .regular(number: 1, state: .unknown))
    }

    func testOlderProjectionCannotOverwriteANewerObservation() async {
        let directory = temporaryDirectory("space")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(gateway: gateway, screens: screens, reader: reader, directory: directory)
        controller.restoreMode = .manual
        let savedID = SpaceRuntimeID(1)
        let snapshot = makeSnapshot(externalSpaces: [space(savedID, "saved", order: 1, current: true)],
                                    memberships: [11: [savedID]])
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", windowServerID: 11)]
        reader.availability = .available(snapshot)
        _ = await controller.captureNow()
        XCTAssertEqual(controller.sections.first?.spaceGroups.first?.kind, .regular(number: 1, state: .current))

        reader.queuedResponses = [(availability: .available(snapshot), delay: 0.03), (availability: .unavailable, delay: 0)]
        let requestCount = reader.requests.count
        let olderRefresh = Task { await controller.cardOpened() }
        while reader.requests.count == requestCount { await Task.yield() }
        let awaited3 = await controller.captureNow()
        XCTAssertEqual(awaited3, .spaceObservationUnavailable)
        await olderRefresh.value
        XCTAssertEqual(controller.sections.first?.spaceGroups.first?.kind, .regular(number: 1, state: .unknown))
        XCTAssertEqual(controller.captureNotice, .spaceObservationUnavailable)
    }

    func testSpaceGroupsNumberByLiveOrderAndCarryRequestGuides() {
        // 표시 번호는 현재 화면의 일반 Space 순서(전체화면 제외)이고, 안내는 요청의 항목 상태에서 온다 (P20)
        let hint = SpaceHint(opaqueName: "saved", localOrderHint: 2)
        let placement = WindowPlacement(bundleID: "com.app", displayName: "App", screenID: external.id,
                                        space: hint, unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let record = WorkspaceRecord.with(WorkspaceSnapshot(
            key: key, screens: [ScreenRecord(id: external.id, name: external.name, regularSpaces: [hint])],
            placements: [placement], savedAt: Date()))
        let labels = [builtin.id: ScreenLabel(name: builtin.name), external.id: ScreenLabel(name: external.name)]

        let stranded = SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(SpaceRuntimeID(1), hint.opaqueName, order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(SpaceRuntimeID(2), "external", order: 1, current: true)]),
            ], membershipsByWindowServerID: [:])
        let passive = PlugbackController.spaceGroups(record: record, screenID: external.id, snapshot: stranded,
                                                     targetConnected: true, outcomes: [:], labels: labels)
        XCTAssertEqual(passive.first?.kind, .regular(number: 1, state: .otherDisplay))
        XCTAssertNil(passive.first?.guide, "요청이 없으면 안내도 없다")

        let move = PlugbackController.spaceGroups(record: record, screenID: external.id, snapshot: stranded, targetConnected: true,
                                                  outcomes: [placement.id: .awaitingSpaceMove(sourceScreenID: builtin.id)], labels: labels)
        XCTAssertEqual(move.first?.guide, .move(source: ScreenLabel(name: builtin.name), destination: ScreenLabel(name: external.name)))

        let inactive = makeSnapshot(externalSpaces: [
            space(SpaceRuntimeID(2), "external", order: 1, current: true),
            space(SpaceRuntimeID(9), "fullscreen", order: 2, kind: .fullscreen),
            space(SpaceRuntimeID(1), hint.opaqueName, order: 3),
        ], memberships: [:])
        let visit = PlugbackController.spaceGroups(record: record, screenID: external.id, snapshot: inactive, targetConnected: true,
                                                   outcomes: [placement.id: .awaitingVisit], labels: labels)
        XCTAssertEqual(visit.first?.kind, .regular(number: 2, state: .inactive), "전체화면 항목은 번호에서 빠진다")
        XCTAssertEqual(visit.first?.guide, .visit(destination: ScreenLabel(name: external.name)))
        XCTAssertEqual(visit.first?.apps.first?.windowCount, 1)
    }

    func testControllerContinuesOneGuidedRestoreAcrossDesktopEvents() async {
        let directory = temporaryDirectory("space")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(gateway: gateway, screens: screens, reader: reader, directory: directory)
        let savedID = SpaceRuntimeID(1)
        let builtinID = SpaceRuntimeID(100)
        let externalID = SpaceRuntimeID(200)
        let savedFrame = CGRect(x: 1000, y: 0, width: 500, height: 1000)

        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", frame: savedFrame, windowServerID: 11)]
        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(savedID, "saved", order: 1, current: true)]),
            ], membershipsByWindowServerID: [11: [savedID]]))
        let awaited4 = await controller.captureNow()
        XCTAssertEqual(awaited4, .captured(appCount: 1, windowCount: 1))

        gateway.windowsList = [window(1, bundleID: "com.app", frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11)]
        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(savedID, "saved", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(externalID, "external", order: 1, current: true)]),
            ], membershipsByWindowServerID: [11: [savedID]]))
        _ = await controller.restoreNow()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(controller.sections.first?.spaceGroups.first?.guide,
                       .move(source: ScreenLabel(name: builtin.name), destination: ScreenLabel(name: external.name)))
        XCTAssertEqual(controller.waitingItems.first?.outcome, .awaitingSpaceMove(sourceScreenID: builtin.id))

        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(externalID, "external", order: 1, current: true), space(savedID, "saved", order: 2)]),
            ], membershipsByWindowServerID: [11: [savedID]]))
        await controller.missionControlClosed()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(controller.sections.first?.spaceGroups.first?.guide, .visit(destination: ScreenLabel(name: external.name)))
        XCTAssertEqual(controller.waitingItems.first?.spaceNumber, 2)

        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(externalID, "external", order: 1), space(savedID, "saved", order: 2, current: true)]),
            ], membershipsByWindowServerID: [11: [savedID]]))
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.moveCalls.map(\.target), [savedFrame])
        XCTAssertNil(controller.sections.first?.spaceGroups.first?.guide)
        XCTAssertTrue(controller.waitingItems.isEmpty)
    }

    func testInitiallyInactiveSavedSpaceIsRestoredOnTheFirstVisit() async {
        // R1: 처음부터 비활성인 저장 Space도 요청이 있는 동안 방문 대기로 남고, 한 번 열면 복원한다
        let directory = temporaryDirectory("space")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(gateway: gateway, screens: screens, reader: reader, directory: directory)
        let savedID = SpaceRuntimeID(1), otherID = SpaceRuntimeID(2), builtinID = SpaceRuntimeID(100)
        let savedFrame = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", frame: savedFrame, windowServerID: 11)]
        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(otherID, "other", order: 1), space(savedID, "saved", order: 2, current: true)]),
            ], membershipsByWindowServerID: [11: [savedID]]))
        _ = await controller.captureNow()

        gateway.windowsList = [window(1, bundleID: "com.app", frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11)]
        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(otherID, "other", order: 1, current: true), space(savedID, "saved", order: 2)]),
            ], membershipsByWindowServerID: [11: [builtinID]]))
        _ = await controller.restoreNow()
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        XCTAssertEqual(controller.waitingItems.first?.outcome, .awaitingVisit)

        reader.availability = .available(SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(builtinID, "builtin", order: 1, current: true)]),
                .init(screenID: external.id, spaces: [space(otherID, "other", order: 1), space(savedID, "saved", order: 2, current: true)]),
            ], membershipsByWindowServerID: [11: [builtinID]]))
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.moveCalls.map(\.target), [savedFrame])

        // 그 뒤의 평소 방문은 창을 움직이지 않는다 (P03)
        gateway.windowsList = [window(1, bundleID: "com.app", frame: CGRect(x: 100, y: 100, width: 300, height: 300), windowServerID: 11)]
        await controller.activeSpaceChanged()
        XCTAssertEqual(gateway.moveCalls.count, 1)
    }

    func testSharedSpacesConfigurationHoldsSavesAndRestores() async {
        // 개별 Spaces가 꺼진 구성은 새 Space 기록·복원을 보류하고 기존 기록을 보존한다 (D6·P12)
        let directory = temporaryDirectory("space")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, external]
        let reader = FakeSpaceReader()
        let controller = makeController(gateway: gateway, screens: screens, reader: reader, directory: directory)
        let savedID = SpaceRuntimeID(1)
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", windowServerID: 11)]
        reader.availability = .available(makeSnapshot(externalSpaces: [space(savedID, "saved", order: 1, current: true)], memberships: [11: [savedID]]))
        _ = await controller.captureNow()

        controller.spacesPreferenceCheck = { .sharedSpaces }
        gateway.windowsList = [window(1, bundleID: "com.app", frame: CGRect(x: 1500, y: 0, width: 400, height: 900), windowServerID: 11)]
        let awaited5 = await controller.captureNow()
        XCTAssertEqual(awaited5, .spacesUnsupported(.sharedSpaces))
        XCTAssertEqual(controller.allWorkspaces.first?.windowCount, 1)
        let awaited6 = await controller.restoreNow()
        XCTAssertEqual(awaited6, .spacesUnsupported(.sharedSpaces))
        XCTAssertTrue(gateway.moveCalls.isEmpty)
        await controller.collectCandidate()
        XCTAssertFalse(controller.hasPendingCollect)

        // 관찰 교차 확인 — 화면 둘에 managed display가 하나뿐이면 공유 구성이다
        controller.spacesPreferenceCheck = { .separateSpaces }
        reader.availability = .available(SpaceSnapshot(
            displays: [.init(screenID: builtin.id, spaces: [space(savedID, "saved", order: 1, current: true)])],
            membershipsByWindowServerID: [11: [savedID]]))
        let awaited7 = await controller.captureNow()
        XCTAssertEqual(awaited7, .spacesUnsupported(.sharedSpaces))
    }

    func testAuthoritativeRestoreCanDrainAnEarlierObservation() async {
        let gateway = FakeWindowGateway()
        gateway.runningBundleIDs = ["com.app"]
        gateway.windowsList = [window(1, bundleID: "com.app", windowServerID: 11)]
        gateway.standardWindowsDelay = 0.02
        let observation = DesktopObservation(gateway: gateway, spaceReader: nil)
        let earlier = Task { await observation.sample() }
        while gateway.standardWindowsCalls == 0 { await Task.yield() }
        await observation.drain()
        _ = await observation.sample()
        _ = await earlier.value
        XCTAssertEqual(gateway.standardWindowsHighWater, 1)
    }

    // MARK: - helpers

    private func makeSnapshot(externalSpaces: [SpaceSnapshot.Space], memberships: [CGWindowID: [SpaceRuntimeID]]) -> SpaceSnapshot {
        SpaceSnapshot(
            displays: [
                .init(screenID: builtin.id, spaces: [space(SpaceRuntimeID(100), "builtin", order: 1, current: true)]),
                .init(screenID: external.id, spaces: externalSpaces),
            ],
            membershipsByWindowServerID: memberships
        )
    }

    private func space(_ id: SpaceRuntimeID, _ name: String?, order: Int, kind: SpaceKind = .regular,
                       current: Bool = false) -> SpaceSnapshot.Space {
        .init(runtimeID: id, opaqueName: name, localOrder: order, kind: kind, isCurrent: current)
    }

    private func window(_ id: Int, bundleID: String, frame: CGRect = CGRect(x: 1000, y: 0, width: 500, height: 1000),
                        windowServerID: CGWindowID?) -> WindowInfo {
        WindowInfo(id: id, appBundleID: bundleID, appName: bundleID, frame: frame, windowServerID: windowServerID)
    }

    private func makeController(gateway: FakeWindowGateway, screens: FakeScreenProvider, reader: FakeSpaceReader,
                                directory: URL) -> PlugbackController {
        let defaults = UserDefaults(suiteName: "guided-space-restore-\(UUID().uuidString)")!
        return PlugbackController(gateway: gateway, screenProvider: screens, store: ProfileStore(directory: directory),
                                  defaults: defaults, spaceReader: reader, activeSpaceDebounceInterval: 0)
    }
}

@MainActor
private final class FakeSpaceReader: SpaceReading {
    var availability: SpaceSnapshotAvailability = .unavailable
    var queuedResponses: [(availability: SpaceSnapshotAvailability, delay: TimeInterval)] = []
    private(set) var requests: [[CGWindowID]] = []

    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability {
        requests.append(windowServerIDs)
        let response = queuedResponses.isEmpty ? (availability: availability, delay: 0) : queuedResponses.removeFirst()
        if response.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000)) }
        return response.availability
    }
}
