import AppKit
@testable import PlugbackKit
import SwiftUI
import XCTest
@testable import Plugback

final class CardAppearanceTests: XCTestCase {
    @MainActor
    func testClickingRowWhitespaceTogglesBothCheckboxPositions() throws {
        for layout in [CardLayout.comfortable, .command] {
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
            observed = layout == .grouped && colors == .coral && brightness == .dark
        }.frame(width: 400, height: 100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let settings = CardAppearance(store: defaults)
        settings.colors = .coral
        settings.layout = .grouped
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
        XCTAssertEqual(appearance.layout, .comfortable)
        XCTAssertEqual(appearance.colors, .porcelain)
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
        XCTAssertEqual(CardAppearance(store: defaults).layout, .comfortable)
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
        // HTML과 같은 4개 앱·2개 Space를 페이크로 캡처한다. 실제 화면 API는 호출하지 않는다.
        let fixture = CardDesktopFixture()
        let firstWindows = await fixture.standardWindows(of: nil)
        fixture.currentSpace = 2
        let secondWindows = await fixture.standardWindows(of: nil)
        fixture.currentSpace = 1
        let apps = (firstWindows + secondWindows).map {
            TargetApp(bundleID: $0.appBundleID, displayName: $0.appName,
                      unitRect: UnitRect($0.frame, in: fixture.screens()[0].frame))
        }
        try store.save(["preview": Profile(screenID: "preview", screenName: "Studio Display", apps: apps)])
        let controller = PlugbackController(gateway: fixture, screenProvider: fixture,
                                           store: store, defaults: defaults, spaceReader: fixture)
        await controller.captureNow()
        fixture.currentSpace = 2
        await controller.captureNow()
        fixture.currentSpace = 1
        await controller.cardOpened()
        XCTAssertEqual(controller.sections.first?.spaceGroups.count, 2)
        XCTAssertEqual(controller.sections.first?.profile?.apps.count, 4)
        await controller.restoreNow()
        try renderCombinations(controller)
        try renderSettings(controller, store: defaults)
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
                    if layout == .grouped {
                        // 안쪽 모서리가 네모면 이 픽셀은 배경색이 된다. 둥글면 바깥 프레임색이 보인다.
                        let insetPixel = Int(7 * CGFloat(bitmap.pixelsWide) / host.bounds.width)
                        let actual = try XCTUnwrap(bitmap.colorAt(x: insetPixel, y: insetPixel)?.usingColorSpace(.sRGB))
                        // 같은 이미지의 직선 프레임을 기준으로 삼아 디스플레이 색 프로필 차이를 제거한다.
                        let expected = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                            y: Int(3 * CGFloat(bitmap.pixelsWide) / host.bounds.width))?.usingColorSpace(.sRGB))
                        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.035)
                        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.035)
                        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.035)
                    }
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "\(layout)-\(colors)-\(scheme)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    if colors == .porcelain && scheme == .light {
                        try png.write(to: FileManager.default.temporaryDirectory
                            .appendingPathComponent("plugback-\(layout).png"))
                    }
                    if layout == .command && colors == .sage {
                        try png.write(to: FileManager.default.temporaryDirectory
                            .appendingPathComponent("plugback-command-sage-\(scheme).png"))
                    }
                    window.orderOut(nil)
                }
            }
        }
    }

    @MainActor
    private func renderSettings(_ controller: PlugbackController, store: UserDefaults) throws {
        let appearance = CardAppearance(store: store)
        appearance.layout = .grouped
        appearance.colors = .sage
        for scheme in [ColorScheme.light, .dark] {
            appearance.brightness = scheme == .dark ? .dark : .light
            for pane in SettingsPane.allCases {
                let host = NSHostingView(rootView: SettingsView(controller: controller, initialPane: pane, store: store))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 520, accuracy: 1)
                XCTAssertEqual(host.fittingSize.height, 560, accuracy: 1)
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
    func screens() -> [ScreenInfo] {
        [ScreenInfo(id: "preview", name: "Studio Display",
                    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isBuiltin: false)]
    }
    func standardWindows(of bundleIDs: [String]?) async -> [WindowInfo] {
        let apps = [("com.apple.Safari", "Safari"), ("com.tinyspeck.slackmacgap", "Slack"),
                    ("com.apple.dt.Xcode", "Xcode"), ("com.linear", "Linear")]
        return apps.enumerated().compactMap { index, app in
            guard (index < 2 ? 1 : 2) == currentSpace else { return nil }
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
        .available(SpaceSnapshot(displays: [.init(screenID: "preview", spaces: [
            .init(runtimeID: SpaceRuntimeID(1), opaqueName: "one", localOrder: 1, kind: .regular, isCurrent: currentSpace == 1),
            .init(runtimeID: SpaceRuntimeID(2), opaqueName: "two", localOrder: 2, kind: .regular, isCurrent: currentSpace == 2)
        ])], membershipsByWindowServerID: [1: [SpaceRuntimeID(1)], 2: [SpaceRuntimeID(1)],
                                          3: [SpaceRuntimeID(2)], 4: [SpaceRuntimeID(2)]]))
    }
}
