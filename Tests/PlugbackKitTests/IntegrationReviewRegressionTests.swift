import AppKit
import CoreGraphics
import XCTest
@testable import PlugbackKit

// 교차 검토에서 재현한 비동기 경계와 결과 표시의 회귀 검사.

private let builtin = ScreenInfo(id: "builtin", name: "내장 화면",
                                 frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
private let extA = ScreenInfo(id: "ext-1", name: "LG UltraFine 27",
                              frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
private let extB = ScreenInfo(id: "ext-2", name: "DELL U2723QE",
                              frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
private let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1)
private let rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)

@MainActor
private final class HookGateway: WindowGateway {
    let base: FakeWindowGateway
    var onLaunch: ((String) async -> Void)?
    var onAdditional: ((String) async -> Void)?
    init(_ base: FakeWindowGateway) { self.base = base }
    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] { await base.standardWindows(of: bundleIDs) }
    func enumerationFailures() async -> Set<String> { await base.enumerationFailures() }
    func existingWindowServerIDs() async -> Set<CGWindowID>? { await base.existingWindowServerIDs() }
    func isRunning(bundleID: String) async -> Bool { await base.isRunning(bundleID: bundleID) }
    func unminimize(windowID: Int) async -> CGRect? { await base.unminimize(windowID: windowID) }
    func openWindow(bundleID: String) async -> Bool { await base.openWindow(bundleID: bundleID) }
    func move(windowID: Int, to frame: CGRect) async -> CGRect? { await base.move(windowID: windowID, to: frame) }
    func raise(windowID: Int) async -> Bool { await base.raise(windowID: windowID) }
    func launch(bundleID: String) async -> Bool {
        let ok = await base.launch(bundleID: bundleID)
        if let onLaunch { await onLaunch(bundleID) }
        return ok
    }
    func openAdditionalWindow(bundleID: String) async -> Bool {
        let ok = await base.openAdditionalWindow(bundleID: bundleID)
        if let onAdditional { await onAdditional(bundleID) }
        return ok
    }
}

@MainActor
final class IntegrationReviewRegressionTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("review-probe")

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "review-probe-\(UUID().uuidString)")! }

    private func win(_ id: Int, _ bundleID: String, _ frame: CGRect, _ wsid: CGWindowID) -> WindowInfo {
        WindowInfo(id: id, appBundleID: bundleID, appName: bundleID, frame: frame, windowServerID: wsid)
    }

    // MARK: 1. 생성 루프 — 삭제·옵션·제외 재확인

    func testDeletedAppIsNotLaunchedAfterAnotherAppLaunches() async {
        let fake = FakeWindowGateway()
        let gateway = HookGateway(fake)
        let snapshot = WorkspaceSnapshot.flat(screen: extA, apps: [("com.a", leftHalf), ("com.b", rightHalf)])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        for (index, placement) in snapshot.placements.enumerated() {
            library.confirmLink(placementID: placement.id, bundleID: placement.bundleID, windowServerID: CGWindowID(500 + index))
        }
        library.noteAppTerminated("com.a", currentKey: WorkspaceKey(screenIDs: ["elsewhere"]))
        library.noteAppTerminated("com.b", currentKey: WorkspaceKey(screenIDs: ["elsewhere"]))
        fake.windowsOnLaunch["com.a"] = [win(1, "com.a", CGRect(x: 2000, y: 200, width: 800, height: 600), 601)]
        fake.windowsOnLaunch["com.b"] = [win(2, "com.b", CGRect(x: 2100, y: 300, width: 800, height: 600), 602)]
        let session = RestoreSession(observation: DesktopObservation(gateway: gateway, spaceReader: nil),
                                     gateway: gateway, library: library)
        gateway.onLaunch = { bundleID in
            guard bundleID == "com.a" else { return }
            // 사용자가 com.a 실행을 기다리는 사이 com.b의 저장 기록을 삭제한다 — controller.remove와 같은 두 단계
            XCTAssertTrue(library.removeApp("com.b", in: snapshot.key))
            session.cancelItems(bundleID: "com.b")
        }
        _ = await session.start(origin: .user, key: snapshot.key, screens: [extA],
                                environment: .init(options: { RestoreOptions(reopenClosedApps: true) },
                                                   spaceObservationEnabled: false))
        XCTAssertEqual(fake.launchCalls, ["com.a"])
    }

    func testAdditionalWindowLoopHonorsTheLatestParentOption() async {
        let fake = FakeWindowGateway()
        let gateway = HookGateway(fake)
        let snapshot = WorkspaceSnapshot.flat(screen: extA, apps: [
            ("com.c", UnitRect(x: 0, y: 0, width: 0.3, height: 1)),
            ("com.c", UnitRect(x: 0.3, y: 0, width: 0.3, height: 1)),
            ("com.c", UnitRect(x: 0.6, y: 0, width: 0.4, height: 1)),
        ])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        for (index, placement) in snapshot.placements.enumerated() {
            library.confirmLink(placementID: placement.id, bundleID: "com.c", windowServerID: CGWindowID(700 + index))
        }
        library.trackLinks(sample: DesktopObservation.Sample(sequence: 1, windows: [], unavailableBundleIDs: [],
                                                             spaceAvailability: nil, existingWindowServerIDs: []),
                           currentKey: WorkspaceKey(screenIDs: ["elsewhere"]))
        fake.runningBundleIDs = ["com.c"]
        fake.windowsList = [win(1, "com.c", CGRect(x: 1600, y: 100, width: 800, height: 600), 801)]
        fake.additionalWindows["com.c"] = [win(2, "com.c", CGRect(x: 2500, y: 500, width: 800, height: 600), 802),
                                           win(3, "com.c", CGRect(x: 2600, y: 500, width: 800, height: 600), 803)]
        var labOn = true
        let session = RestoreSession(observation: DesktopObservation(gateway: gateway, spaceReader: nil),
                                     gateway: gateway, library: library)
        gateway.onAdditional = { _ in labOn = false } // 첫 추가 창이 열린 뒤 사용자가 실험실 부모 옵션을 끈다
        _ = await session.start(origin: .user, key: snapshot.key, screens: [extA],
                                environment: .init(options: { RestoreOptions(reopenClosedApps: labOn, openMissingWindows: true) },
                                                   spaceObservationEnabled: false))
        XCTAssertEqual(fake.additionalWindowCalls, ["com.c"])
    }

    func testRemovedPlacementStaysCancelledAfterCreation() async {
        let fake = FakeWindowGateway()
        let gateway = HookGateway(fake)
        let snapshot = WorkspaceSnapshot.flat(screen: extA, apps: [("com.a", leftHalf), ("com.a", rightHalf)])
        let library = makeLibrary(directory: dir, records: [.with(snapshot)])
        for (index, placement) in snapshot.placements.enumerated() {
            library.confirmLink(placementID: placement.id, bundleID: "com.a", windowServerID: CGWindowID(500 + index))
        }
        library.noteAppTerminated("com.a", currentKey: WorkspaceKey(screenIDs: ["elsewhere"]))
        fake.windowsOnLaunch["com.a"] = [win(1, "com.a", CGRect(x: 2000, y: 200, width: 800, height: 600), 601)]
        let removed = snapshot.placements[1].id
        let session = RestoreSession(observation: DesktopObservation(gateway: gateway, spaceReader: nil),
                                     gateway: gateway, library: library)
        gateway.onLaunch = { _ in
            XCTAssertTrue(library.removePlacement(removed, in: snapshot.key))
            session.cancelItem(placementID: removed)
        }
        _ = await session.start(origin: .user, key: snapshot.key, screens: [extA],
                                environment: .init(options: { RestoreOptions(reopenClosedApps: true) },
                                                   spaceObservationEnabled: false))
        XCTAssertEqual(session.outcome(of: removed), .cancelled(.targetRemoved))
    }

    // MARK: 2. 판정하지 않은 자리(제외 앱)가 열린 일·취소 결과로 보이는가

    func testSavingDoesNotAddCancelledResultsForExcludedApps() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        gateway.runningBundleIDs = ["com.chrome", "com.slack"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101),
                               win(2, "com.slack", CGRect(x: 2792, y: 0, width: 1280, height: 1440), 102)]
        _ = await controller.captureNow()
        await controller.setTracked("com.slack", false, on: extA.id)
        gateway.windowsList[0] = win(1, "com.chrome", CGRect(x: 2500, y: 500, width: 800, height: 600), 101)
        _ = await controller.restoreNow()
        XCTAssertFalse(controller.lastResults.flatMap(\.entries).contains { $0.bundleID == "com.slack" })
        _ = await controller.captureNow()
        XCTAssertFalse(controller.lastResults.flatMap(\.entries).contains { $0.bundleID == "com.slack" })
    }

    // MARK: 3. 지문 불일치 안내가 저장 뒤에도 남는가

    func testManualSaveClearsResolvedFingerprintWarning() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        let fp1 = ScreenFingerprint(vendor: 1, model: 1, serial: 1)
        let fp2 = ScreenFingerprint(vendor: 1, model: 1, serial: 2)
        let a1 = ScreenInfo(id: extA.id, name: extA.name, frame: extA.frame, isBuiltin: false, fingerprint: fp1)
        let a2 = ScreenInfo(id: extA.id, name: extA.name, frame: extA.frame, isBuiltin: false, fingerprint: fp2)
        screens.screensList = [builtin, a1]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        _ = await controller.captureNow()
        screens.screensList = [builtin, a2]
        _ = await controller.restoreNow()
        XCTAssertTrue(controller.identityMismatch)
        _ = await controller.captureNow()
        XCTAssertFalse(controller.identityMismatch)
    }

    // MARK: 4. 실행 중 취소된 요청 — 결과는 보이는데 시각이 없는가

    func testCancelledRunKeepsItsResultTime() async {
        let gateway = FakeWindowGateway()
        let screens = FakeScreenProvider()
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir), defaults: defaults())
        gateway.runningBundleIDs = ["com.chrome"]
        gateway.windowsList = [win(1, "com.chrome", CGRect(x: 1512, y: 0, width: 1280, height: 1440), 101)]
        _ = await controller.captureNow()
        gateway.windowsList[0] = win(1, "com.chrome", CGRect(x: 2500, y: 500, width: 800, height: 600), 101)
        _ = await controller.restoreNow()
        gateway.windowsList[0] = win(1, "com.chrome", CGRect(x: 2500, y: 500, width: 800, height: 600), 101)
        gateway.standardWindowsDelay = 0.2
        let calls = gateway.standardWindowsCalls
        let restore = Task { await controller.restoreNow() }
        while gateway.standardWindowsCalls == calls { await Task.yield() }
        controller.cancelRemaining()
        _ = await restore.value
        XCTAssertFalse(controller.lastResults.isEmpty)
        XCTAssertNotNil(controller.lastRestoredAt)
    }
}

/// 표준 창 열거마다 지연을 순서대로 꺼낸다 — 동시에 시작한 관찰 중 어느 쪽이 먼저 끝나는지 정한다.
@MainActor
private final class DelayQueueGateway: WindowGateway {
    let base: FakeWindowGateway
    var delays: [TimeInterval] = []
    private(set) var calls = 0
    init(_ base: FakeWindowGateway) { self.base = base }
    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] {
        calls += 1
        let delay = delays.isEmpty ? 0 : delays.removeFirst()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return await base.standardWindows(of: bundleIDs)
    }
    func enumerationFailures() async -> Set<String> { await base.enumerationFailures() }
    func existingWindowServerIDs() async -> Set<CGWindowID>? { await base.existingWindowServerIDs() }
    func isRunning(bundleID: String) async -> Bool { await base.isRunning(bundleID: bundleID) }
    func unminimize(windowID: Int) async -> CGRect? { await base.unminimize(windowID: windowID) }
    func openWindow(bundleID: String) async -> Bool { await base.openWindow(bundleID: bundleID) }
    func move(windowID: Int, to frame: CGRect) async -> CGRect? { await base.move(windowID: windowID, to: frame) }
}

@MainActor
final class ArrivalCollectionRegressionTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("review-race")

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func stored(_ key: WorkspaceKey) -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("workspaces.json")),
              let file = try? JSONDecoder.plugback.decode(StoreFile.self, from: data) else { return nil }
        return file.workspaces[key.raw]?.saved
    }

    func testArrivalCollectionWaitsForAutomaticRestore() async {
        let fake = FakeWindowGateway()
        let gateway = DelayQueueGateway(fake)
        let screens = FakeScreenProvider()
        let builtin = ScreenInfo(id: "builtin", name: "내장", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
        let extA = ScreenInfo(id: "ext-1", name: "LG", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens,
                                            store: ProfileStore(directory: dir),
                                            defaults: UserDefaults(suiteName: "race-\(UUID().uuidString)")!)
        let saved = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        fake.runningBundleIDs = ["com.chrome"]
        fake.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome", frame: saved, windowServerID: 101)]
        _ = await controller.captureNow()
        await controller.workspaceChanged() // A 선택

        screens.screensList = [builtin] // 분리 — macOS가 창을 내장으로 모은다
        fake.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                         frame: CGRect(x: 100, y: 100, width: 800, height: 600), windowServerID: 101)
        await controller.workspaceChanged()

        // 다시 연결 — 창은 외장의 엉뚱한 자리에 있다
        screens.screensList = [builtin, extA]
        let messy = CGRect(x: 2500, y: 500, width: 800, height: 600)
        fake.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome", frame: messy, windowServerID: 101)
        gateway.delays = [0.3] // 환경 반영 뒤 표시용 관찰이 느리다 — 그 사이 수집 신호가 온다
        let before = gateway.calls
        let change = Task { await controller.workspaceChanged() }
        while gateway.calls == before { await Task.yield() }
        await controller.collectCandidate()
        await change.value
        await controller.collectCandidate() // 복원 뒤 평소 수집
        screens.screensList = [builtin]
        await controller.workspaceChanged() // 떠남 — 자동 저장
        let x = stored(WorkspaceKey(screenIDs: [extA.id]))?.placements.first?.unitRect.x
        XCTAssertEqual(x, 0)
    }
}

@MainActor
final class DeferredCollectionRegressionTests: XCTestCase {
    private nonisolated let dir = temporaryDirectory("review-race2")
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private func stored(_ key: WorkspaceKey) -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("workspaces.json")),
              let file = try? JSONDecoder.plugback.decode(StoreFile.self, from: data) else { return nil }
        return file.workspaces[key.raw]?.saved
    }

    func testCollectionWaitsForTheDeferredWorkspaceRestore() async {
        let fake = FakeWindowGateway()
        let gateway = DelayQueueGateway(fake)
        let screens = FakeScreenProvider()
        let builtin = ScreenInfo(id: "builtin", name: "내장", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
        let extA = ScreenInfo(id: "ext-1", name: "LG", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)
        let extB = ScreenInfo(id: "ext-2", name: "DELL", frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), isBuiltin: false)
        screens.screensList = [builtin, extA]
        let controller = PlugbackController(gateway: gateway, screenProvider: screens, store: ProfileStore(directory: dir),
                                            defaults: UserDefaults(suiteName: "race2-\(UUID().uuidString)")!)
        let chromeSaved = CGRect(x: 1512, y: 0, width: 1280, height: 1440)
        let slackSaved = CGRect(x: 4072, y: 0, width: 960, height: 1080)
        fake.runningBundleIDs = ["com.chrome", "com.slack"]
        fake.windowsList = [WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome", frame: chromeSaved, windowServerID: 101)]
        _ = await controller.captureNow() // A
        screens.screensList = [builtin, extA, extB]
        fake.windowsList.append(WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack", frame: slackSaved, windowServerID: 102))
        _ = await controller.captureNow() // A+B
        screens.screensList = [builtin, extA]
        await controller.workspaceChanged() // A 선택 (복원은 이미 제자리)
        fake.windowsList[0] = WindowInfo(id: 1, appBundleID: "com.chrome", appName: "Chrome",
                                         frame: CGRect(x: 2500, y: 500, width: 800, height: 600), windowServerID: 101)

        // A의 지금 복원이 도는 동안 B가 연결된다
        gateway.delays = [0.2, 0.3, 0] // 실행 안 관찰 → 실행 뒤 표시용 관찰(느림) → 수집(빠름)
        let before = gateway.calls
        let restore = Task { await controller.restoreNow() }
        while gateway.calls < before + 1 { await Task.yield() }
        screens.screensList = [builtin, extA, extB]
        let messy = CGRect(x: 4500, y: 300, width: 800, height: 600)
        fake.windowsList[1] = WindowInfo(id: 2, appBundleID: "com.slack", appName: "Slack", frame: messy, windowServerID: 102)
        await controller.workspaceChanged() // 실행 중 — 새 환경 자동 복원은 실행 뒤로 미룬다
        while gateway.calls < before + 2 { await Task.yield() } // 실행이 끝나고 execute가 표시용 관찰을 기다린다
        await controller.collectCandidate()
        _ = await restore.value
        await controller.collectCandidate()
        screens.screensList = [builtin, extA]
        await controller.workspaceChanged()
        let key = WorkspaceKey(screenIDs: [extA.id, extB.id])
        XCTAssertEqual(stored(key)?.placements.first { $0.bundleID == "com.slack" }?.unitRect.x, 0)
    }
}
