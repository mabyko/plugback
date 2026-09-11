import AppKit
@testable import PlugbackKit
import SwiftUI
import XCTest
@testable import Plugback

final class CardAppearanceTests: XCTestCase {
    @MainActor
    func testLongListKeepsExcludedAppsAndScrollerReachable() async throws {
        let suite = "plugback-long-list-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = CardDesktopFixture()
        // 지금 화면에 창이 있는 앱이 첫 묶음이다 — 목록이 길어지려면 화면에도 앱이 많아야 한다
        fixture.applications = (0..<20).map { ("preview.visible.\($0)", "화면 앱 \($0)") }
        fixture.appsPerSpace = 20
        let store = ProfileStore(directory: directory)
        let key = WorkspaceKey(screenIDs: ["preview"])
        let placements = (0...20).map { index in
            WindowPlacement(bundleID: "preview.app.\(index)",
                            displayName: index == 0 ? "저장했던 앱" : "대상 앱 \(index)",
                            screenID: "preview", space: nil, unitRect: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        }
        let record = WorkspaceRecord(
            key: key,
            apps: placements.map { AppSelection(bundleID: $0.bundleID, displayName: $0.displayName, isEnabled: $0.bundleID != "preview.app.0") },
            saved: WorkspaceSnapshot(key: key, screens: [ScreenRecord(id: "preview", name: "LG HDR 4K")],
                                     placements: placements, savedAt: Date())
        )
        try store.save([key: record])
        let controller = PlugbackController(gateway: fixture, screenProvider: fixture,
                                           store: store, defaults: defaults, spaceReader: fixture)
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.presentApps.count, 20, "화면의 앱은 저장 전이어도 첫 묶음에 보인다")
        XCTAssertEqual(controller.sections.first?.absentSavedApps.count, 20, "저장만 된 앱은 접힌 묶음으로 내려간다")
        XCTAssertEqual(controller.sections.first?.excludedApps.count, 1)

        func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }
        for style in [NSScroller.Style.overlay, .legacy] {
            let palette = CardColors.sage.palette(for: .dark)
            let host = NSHostingView(rootView: Card(controller: controller, layout: .list, palette: palette)
                .modifier(CardSurface(layout: .list, palette: palette))
                .environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThan(host.frame.height, 600, "앱이 많아도 카드 높이는 제한한다")
            let scroll = try XCTUnwrap(subviews(host).compactMap { $0 as? NSScrollView }.first)
            scroll.scrollerStyle = style
            scroll.autohidesScrollers = false
            scroll.hasVerticalScroller = true
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height)
            let disclosurePoint = NSPoint(x: 40, y: document.isFlipped ? document.bounds.maxY - 12 : 12)
            func clickDisclosure() throws {
                let location = document.convert(disclosurePoint, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let collapsedHeight = document.bounds.height
            try clickDisclosure()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertGreaterThan(document.bounds.height, collapsedHeight, "접힌 묶음을 펼치면 목록이 늘어난다")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            scroll.flashScrollers()
            let scroller = try XCTUnwrap(scroll.verticalScroller)
            XCTAssertFalse(scroller.isHidden)
            XCTAssertTrue(host.bounds.contains(host.convert(scroller.bounds, from: scroller)),
                          "스크롤바는 카드 안에서 조작할 수 있다")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("plugback-long-list-\(style.rawValue).png"))
            try clickDisclosure()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(document.bounds.height, collapsedHeight, accuracy: 1, "다시 누르면 목록이 접힌다")
            XCTAssertEqual(controller.allWorkspaces.first?.windowCount, 21, "접기는 저장 기록을 바꾸지 않는다")
        }
    }

    @MainActor
    func testClickingRowWhitespaceTogglesTargetSelection() throws {
        for layout in [CardLayout.list, .spaces] {
            var tracked = false
            let host = NSHostingView(rootView: CardAppRow(
                bundleID: "com.apple.Safari", name: "Safari", isEnabled: false, isRunning: true,
                layout: layout, palette: CardColors.sage.palette(for: .light),
                setTracked: { tracked = $0 }, remove: nil
            ).frame(width: 360, height: 44))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let location = NSPoint(x: 220, y: 22) // 이름과 체크박스 사이의 빈 영역
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            window.sendEvent(down)
            window.sendEvent(up)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(tracked, "행의 빈 곳을 클릭해도 대상 설정을 갱신한다: \(layout)")
        }
    }

    @MainActor
    func testOpenViewObservesChangesFromAnotherSettingsInstance() {
        let suite = "plugback-live-appearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var observed = false
        let host = NSHostingView(rootView: AppearanceObserver(store: defaults) { layout, colors, brightness in
            observed = layout == .board && colors == .coral && brightness == .dark
        }.frame(width: 400, height: 100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let settings = CardAppearance(store: defaults)
        settings.colors = .coral
        settings.layout = .board
        settings.brightness = .dark
        let deadline = Date().addingTimeInterval(3)
        while !observed && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(observed, "열린 카드에 새 조합이 반영된다")
        window.orderOut(nil)
    }

    func testSelectionsPersistIndependentlyAndUnknownValuesFallBack() {
        let suite = "plugback-appearance-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = CardAppearance(store: defaults)
        XCTAssertEqual(appearance.layout, .status)
        XCTAssertEqual(CardLayout.allCases, [.status, .list, .spaces, .board])
        XCTAssertEqual(["comfortable", "compact", "command", "grouped"].compactMap(CardLayout.init(rawValue:)),
                       CardLayout.allCases, "기존 설치의 저장된 레이아웃 선택을 유지한다")
        XCTAssertEqual(appearance.colors, .sage)
        XCTAssertEqual(appearance.brightness, .system)
        for layout in CardLayout.allCases {
            appearance.layout = layout
            for colors in CardColors.allCases {
                appearance.colors = colors
                for brightness in CardBrightness.allCases {
                    appearance.brightness = brightness
                    let reopened = CardAppearance(store: defaults)
                    XCTAssertEqual(reopened.layout, layout)
                    XCTAssertEqual(reopened.colors, colors)
                    XCTAssertEqual(reopened.brightness, brightness)
                }
            }
        }
        defaults.set("future-layout", forKey: "appearance.layout")
        XCTAssertEqual(CardAppearance(store: defaults).layout, .status)
        XCTAssertEqual(CardAppearance(store: defaults).colors, .sage)
        XCTAssertEqual(CardAppearance(store: defaults).brightness, .dark)
    }

    @MainActor
    func testEveryPaletteKeepsReadableText() throws {
        func luminance(_ color: Color) throws -> Double {
            let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for colors in CardColors.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let p = colors.palette(for: scheme)
                for (foreground, background) in [(p.text, p.background), (p.text, p.surface),
                    (p.secondary, p.background), (p.secondary, p.surface), (p.onAccent, p.accent),
                    (p.text, p.soft), (p.secondary, p.soft), (p.text, p.accentSoft),
                    (p.secondary, p.accentSoft)] {
                    let a = try luminance(foreground), b = try luminance(background)
                    XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5,
                                                "\(colors) / \(scheme)")
                }
            }
        }
    }

    @MainActor
    func testAllLayoutColorCombinationsRenderStoredProfile() async throws {
        let suite = "plugback-render-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ProfileStore(directory: directory)
        // README용 앱 20개·Space 3개를 페이크로 저장한다. 실제 창 이동은 하지 않는다.
        let fixture = CardDesktopFixture()
        fixture.applications = [
            ("com.apple.Safari", "Safari"), ("com.tinyspeck.slackmacgap", "Slack"),
            ("com.apple.finder", "Finder"), ("com.apple.mail", "Mail"),
            ("com.apple.iCal", "Calendar"), ("com.apple.Notes", "Notes"),
            ("com.apple.Terminal", "Terminal"), ("com.apple.dt.Xcode", "Xcode"),
            ("com.linear", "Linear"), ("com.microsoft.VSCode", "Visual Studio Code"),
            ("com.apple.Preview", "Preview"), ("com.apple.Music", "Music"),
            ("md.obsidian", "Obsidian"), ("com.apple.Passwords", "암호"),
            ("com.apple.reminders", "미리 알림"), ("com.apple.calculator", "계산기"),
            ("com.apple.TextEdit", "TextEdit"), ("com.apple.Maps", "지도"),
            ("com.apple.Photos", "사진"), ("com.apple.systempreferences", "시스템 설정")
        ]
        fixture.appsPerSpace = 7
        let controller = PlugbackController(gateway: fixture, screenProvider: fixture,
                                           store: store, defaults: defaults, spaceReader: fixture)
        // Space를 차례로 방문해 저장하면 작업 환경 기록이 누적된다 (S02) — 관찰하지 못한 Space의 기록은 유지된다.
        await controller.captureNow()
        fixture.currentSpace = 2
        await controller.captureNow()
        fixture.currentSpace = 3
        await controller.captureNow()
        fixture.currentSpace = 1
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.spaceGroups.count, 3)
        XCTAssertEqual(controller.allWorkspaces.first?.windowCount, 20)
        XCTAssertEqual(controller.sections.first?.apps.count, 20)
        let destinations = CardPresentation.spaceSelections(in: controller.sections)
        XCTAssertEqual(destinations.count, 3)
        XCTAssertEqual(CardPresentation.resolvedSpaceSelection(destinations.last, in: controller.sections), destinations.last)
        let stale = CardSpaceSelection(screenID: "unplugged-display", category: .group("gone"))
        XCTAssertEqual(CardPresentation.resolvedSpaceSelection(stale, in: controller.sections), destinations.first)
        XCTAssertNil(CardPresentation.resolvedSpaceSelection(destinations.first, in: []))
        await controller.restoreNow()
        try renderCombinations(controller)
        try renderSettings(controller, store: defaults)
    }

    @MainActor
    func testStatusManagementAndSpaceNavigationUseLiveController() async throws {
        let suite = "plugback-navigation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = CardDesktopFixture()
        let store = ProfileStore(directory: directory)
        let controller = PlugbackController(gateway: fixture, screenProvider: fixture,
                                           store: store, defaults: defaults, spaceReader: fixture)
        await controller.captureNow()
        fixture.currentSpace = 2
        await controller.captureNow()
        fixture.currentSpace = 1
        await controller.cardOpened()
        let palette = CardColors.sage.palette(for: .dark)
        let host = NSHostingView(rootView: Card(controller: controller, layout: .status, palette: palette)
            .modifier(CardSurface(layout: .status, palette: palette)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.setFrameSize(host.fittingSize)
        }
        func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }
        func click(_ point: NSPoint, in view: NSView) throws {
            let location = view.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        settle()
        let summaryHeight = host.frame.height
        XCTAssertTrue(subviews(host).compactMap { $0 as? NSScrollView }.isEmpty)
        // 관리 행은 고정 푸터 바로 위에 있다. 실제 클릭으로 내부 화면 전환을 검증한다.
        try click(NSPoint(x: 120, y: host.isFlipped ? host.bounds.height - 65 : 65), in: host)
        settle()
        XCTAssertFalse(subviews(host).compactMap { $0 as? NSScrollView }.isEmpty, "관리에 들어가면 앱 목록을 표시한다")
        XCTAssertFalse(subviews(host).compactMap { $0 as? NSTextField }.isEmpty, "관리 화면에는 검색 입력이 있다")
        let managerBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: managerBitmap)
        try XCTUnwrap(managerBitmap.representation(using: .png, properties: [:])).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("plugback-manager.png"))
        try click(NSPoint(x: 36, y: host.isFlipped ? 24 : host.bounds.height - 24), in: host)
        settle()
        XCTAssertEqual(host.frame.height, summaryHeight, accuracy: 1)
        XCTAssertTrue(subviews(host).compactMap { $0 as? NSScrollView }.isEmpty)
        XCTAssertEqual(controller.sections.first?.apps.count, 4)

        host.rootView = Card(controller: controller, layout: .board, palette: palette)
            .modifier(CardSurface(layout: .board, palette: palette))
        settle()
        let scroll = try XCTUnwrap(subviews(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        try click(NSPoint(x: 40, y: document.isFlipped ? 28 : document.bounds.height - 28), in: document)
        try await Task.sleep(nanoseconds: 100_000_000)
        settle()
        XCTAssertEqual(controller.sections.first?.apps.count, 3,
                       "아이콘을 누르면 실제 작업 환경에서 해당 앱을 제외한다")
        XCTAssertEqual(controller.sections.first?.excludedApps.count, 1)

        let original = try XCTUnwrap(controller.sections.first)
        let other = PlugbackController.ScreenSection(screenID: "second", label: original.label,
            hasSnapshot: original.hasSnapshot, savedAt: original.savedAt, savedBy: original.savedBy,
            apps: original.apps, presentApps: original.presentApps, absentSavedApps: original.absentSavedApps,
            excludedApps: original.excludedApps, spaceGroups: original.spaceGroups, spaceConfigurationDiffers: false,
            lastResult: nil)
        let destinations = CardPresentation.spaceSelections(in: [original, other])
        XCTAssertEqual(Set(destinations).count, destinations.count, "서로 다른 화면의 같은 Space ID를 구분한다")
        XCTAssertEqual(destinations.filter { $0.screenID == "second" }.count, 3)
        let selected = try XCTUnwrap(destinations.last)
        XCTAssertEqual(CardPresentation.resolvedSpaceSelection(selected, in: [original, other]), selected)
        XCTAssertEqual(CardPresentation.resolvedSpaceSelection(selected, in: [original]), destinations.first)
    }

    @MainActor
    private func renderCombinations(_ controller: PlugbackController) throws {
        for layout in CardLayout.allCases {
            for colors in CardColors.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let p = colors.palette(for: scheme)
                    let view = Card(controller: controller, layout: layout, palette: p)
                        .modifier(CardSurface(layout: layout, palette: p))
                        .environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: layout.width, height: 800),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    host.setFrameSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.frame.width, layout.width, accuracy: 1)
                    XCTAssertGreaterThan(host.frame.height, 250, "목록이 접히면 안 된다")
                    XCTAssertLessThan(host.frame.height, 800)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "\(layout)-\(colors)-\(scheme)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    if colors == .sage {
                        try png.write(to: FileManager.default.temporaryDirectory
                            .appendingPathComponent("plugback-\(layout)-\(scheme).png"))
                    }
                    window.orderOut(nil)
                }
            }
        }
    }

    @MainActor
    private func renderSettings(_ controller: PlugbackController, store: UserDefaults) throws {
        let appearance = CardAppearance(store: store)
        appearance.layout = .board
        appearance.colors = .sage
        for scheme in [ColorScheme.light, .dark] {
            appearance.brightness = scheme == .dark ? .dark : .light
            for pane in SettingsPane.allCases {
                let host = NSHostingView(rootView: SettingsView(controller: controller, initialPane: pane, store: store))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 520, accuracy: 1)
                XCTAssertEqual(host.fittingSize.height, 600, accuracy: 1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "settings-\(pane)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try png.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("plugback-settings-\(pane)-\(scheme).png"))
                window.orderOut(nil)
            }
        }
    }
}

private struct AppearanceObserver: View {
    var appearance: CardAppearance
    let report: (CardLayout, CardColors, CardBrightness) -> Void

    init(store: UserDefaults, report: @escaping (CardLayout, CardColors, CardBrightness) -> Void) {
        appearance = CardAppearance(store: store)
        self.report = report
    }

    var body: some View {
        let _ = report(appearance.layout, appearance.colors, appearance.brightness)
        Text(appearance.layout.title)
    }
}

@MainActor
private final class CardDesktopFixture: WindowGateway, ScreenProvider, SpaceReading {
    var currentSpace = 1
    var applications = [("com.apple.Safari", "Safari"), ("com.tinyspeck.slackmacgap", "Slack"),
                        ("com.apple.dt.Xcode", "Xcode"), ("com.linear", "Linear")]
    var appsPerSpace = 2
    var spaceCount: Int { (applications.count + appsPerSpace - 1) / appsPerSpace }
    func screens() -> [ScreenInfo] {
        [ScreenInfo(id: "preview", name: "Studio Display",
                    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isBuiltin: false)]
    }
    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] {
        return applications.enumerated().compactMap { index, app in
            guard index / appsPerSpace + 1 == currentSpace else { return nil }
            guard bundleIDs == nil || bundleIDs!.contains(app.0) else { return nil }
            return WindowInfo(id: index + 1, appBundleID: app.0, appName: app.1,
                              frame: CGRect(x: index * 100, y: 100, width: 800, height: 900),
                              windowServerID: UInt32(index + 1))
        }
    }
    func move(windowID: Int, to frame: CGRect) async -> CGRect? { frame }
    func isRunning(bundleID: String) async -> Bool { true }
    func unminimize(windowID: Int) async -> CGRect? { nil }
    func openWindow(bundleID: String) async -> Bool { false }
    func stableSnapshot(windowServerIDs: [CGWindowID]) async -> SpaceSnapshotAvailability {
        let spaces = (1...spaceCount).map { number in
            SpaceSnapshot.Space(runtimeID: SpaceRuntimeID(UInt64(number)), opaqueName: "space-\(number)",
                            localOrder: number, kind: .regular, isCurrent: currentSpace == number)
        }
        let memberships = Dictionary(uniqueKeysWithValues: applications.indices.map { index in
            (UInt32(index + 1), [SpaceRuntimeID(UInt64(index / appsPerSpace + 1))])
        })
        return .available(SpaceSnapshot(displays: [.init(screenID: "preview", spaces: spaces)],
                                        membershipsByWindowServerID: memberships))
    }
}
