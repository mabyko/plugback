import AppKit
import ApplicationServices
import Darwin

// Throwaway, read-only experiment. No titles, text, keys, screenshots, or AX writes.
// Records evidence; a mouse press plus a changed frame does NOT prove who moved it.
// Global mouse events cover other apps, so only Chrome and Finder are sampled.

struct GeometryEvidence {
    let initial: CGRect?
    var moved = false
    var resized = false
    var failedReads = 0
    var samples = 0

    mutating func observe(_ frame: CGRect?) {
        guard let initial, let frame else { failedReads += 1; return }
        samples += 1
        moved = moved || abs(frame.minX - initial.minX) > 1 || abs(frame.minY - initial.minY) > 1
        resized = resized || abs(frame.width - initial.width) > 1 || abs(frame.height - initial.height) > 1
    }

    var kind: String {
        if moved && resized { return "position_and_size" }
        if moved { return "position" }
        if resized { return "size" }
        return initial == nil || failedReads > 0 || samples == 0 ? "unknown" : "unchanged"
    }
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func windowElement(_ element: AXUIElement) -> AXUIElement? {
    if copyAttribute(element, kAXRoleAttribute) as? String == kAXWindowRole as String { return element }
    guard let value = copyAttribute(element, kAXWindowAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func frameOf(_ window: AXUIElement) -> CGRect? {
    guard let position = copyAttribute(window, kAXPositionAttribute),
          let size = copyAttribute(window, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

final class Interaction {
    let id: Int
    let token: Int
    let window: AXUIElement
    let started = ProcessInfo.processInfo.systemUptime
    var geometry: GeometryEvidence
    var dragEvents = 0
    var changedWhilePressed = false
    var screenChanged = false
    var maxReadMS = 0.0

    init(id: Int, token: Int, window: AXUIElement, initial: CGRect?) {
        self.id = id
        self.token = token
        self.window = window
        geometry = GeometryEvidence(initial: initial)
    }
}

final class InteractionProbe {
    let started = ProcessInfo.processInfo.systemUptime
    let runID = UUID().uuidString
    let targets = Set(["com.google.Chrome", "com.apple.finder"])
    let system = AXUIElementCreateSystemWide()
    var windows: [AXUIElement] = []
    var observers: [AXObserver] = []
    var monitor: Any?
    var screenObserver: NSObjectProtocol?
    var sampleTimer: Timer?
    var interaction: Interaction?
    var sequence = 0
    var completed = 0
    var observedMoves = 0
    var observedResizes = 0
    var observedUnchanged = 0
    var lookupFailures = 0
    var rawDowns = 0
    var rawDrags = 0
    var rawUps = 0
    var filteredDowns = 0
    var previous: (token: Int, id: Int, ended: TimeInterval)?

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var record = fields
        record["event"] = event
        record["run_id"] = runID
        record["t_ms"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    func token(_ element: AXUIElement) -> Int {
        if let index = windows.firstIndex(where: { CFEqual($0, element) }) { return index + 1 }
        windows.append(element)
        return windows.count
    }

    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            log("blocked", ["reason": "accessibility_permission_missing"])
            return false
        }
        AXUIElementSetMessagingTimeout(system, 0.1)
        for app in NSWorkspace.shared.runningApplications where targets.contains(app.bundleIdentifier ?? "") {
            var observer: AXObserver?
            let result = AXObserverCreate(app.processIdentifier, probeAXCallback, &observer)
            guard result == .success, let observer else {
                log("observer_failed", ["app": app.bundleIdentifier ?? "", "ax_error": result.rawValue])
                continue
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            for name in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                let status = AXObserverAddNotification(observer, element, name as CFString,
                    Unmanaged.passUnretained(self).toOpaque())
                log("subscription", ["app": app.bundleIdentifier ?? "", "notification": name, "ax_error": status.rawValue])
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers.append(observer)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] in
            self?.mouse($0)
        }
        guard monitor != nil else { log("blocked", ["reason": "mouse_monitor_unavailable"]); return false }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.interaction?.screenChanged = true
            self?.log("screen_change", ["screen_count": NSScreen.screens.count])
        }
        log("ready", ["screen_count": NSScreen.screens.count, "targets": targets.sorted(),
                      "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                      "probe_revision": 3, "event_loop": "NSApplication.run",
                      "read_only": true, "verdict": "awaiting_human_actions"])
        return true
    }

    func mouse(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            rawUps += 1
            if interaction != nil { sample(); finish("mouse_up") }
            return
        }
        if event.type == .leftMouseDragged {
            rawDrags += 1
            interaction?.dragEvents += 1
            return
        }
        rawDowns += 1
        log("mouse_down_received", ["count": rawDowns])
        if interaction != nil { finish("new_down_without_up") }
        // CGEvent locations already use the top-left global coordinate system used by AX.
        guard let point = event.cgEvent?.location else { log("lookup_failed", ["reason": "no_event_coordinates"]); return }
        let lookupStart = ProcessInfo.processInfo.systemUptime
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard result == .success, let hit else {
            lookupFailures += 1
            log("lookup_failed", ["ax_error": result.rawValue])
            return
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              targets.contains(bundle) else {
            filteredDowns += 1
            log("mouse_down_filtered", ["reason": "outside_target_apps"])
            return
        }
        AXUIElementSetMessagingTimeout(hit, 0.1)
        guard let window = windowElement(hit) else {
            lookupFailures += 1
            log("lookup_failed", ["app": bundle, "reason": "no_standard_window"])
            return
        }
        AXUIElementSetMessagingTimeout(window, 0.1)
        guard copyAttribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String else {
            filteredDowns += 1
            log("mouse_down_filtered", ["reason": "not_a_standard_window", "app": bundle])
            return
        }
        sequence += 1
        let current = Interaction(id: sequence, token: token(window), window: window, initial: frameOf(window))
        interaction = current
        log("mouse_down", ["gesture": current.id, "window": current.token, "app": bundle,
                           "hit_role": copyAttribute(hit, kAXRoleAttribute) as? String ?? "unknown",
                           "lookup_ms": Int((ProcessInfo.processInfo.systemUptime - lookupStart) * 1000),
                           "event_uptime_s": event.timestamp,
                           "received_uptime_s": lookupStart,
                           "initial_frame_available": current.geometry.initial != nil])
        // ponytail: 10 Hz sampling only during a press, for at most 15 seconds, in this diagnostic.
        // This intentionally measures candidate signals; it is not a production gesture detector.
        sampleTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let current = self.interaction else { return }
            self.sample()
            if NSEvent.pressedMouseButtons & 1 == 0 { self.finish("release_seen_without_up_event") }
            else if ProcessInfo.processInfo.systemUptime - current.started > 15 { self.finish("press_timeout") }
        }
        RunLoop.main.add(sampleTimer!, forMode: .common)
    }

    func sample() {
        guard let current = interaction else { return }
        let pressedBefore = NSEvent.pressedMouseButtons & 1 != 0
        let start = ProcessInfo.processInfo.systemUptime
        let frame = frameOf(current.window)
        current.maxReadMS = max(current.maxReadMS, (ProcessInfo.processInfo.systemUptime - start) * 1000)
        let before = current.geometry.kind
        current.geometry.observe(frame)
        if frame != nil, pressedBefore, NSEvent.pressedMouseButtons & 1 != 0,
           current.geometry.moved || current.geometry.resized {
            current.changedWhilePressed = true
        }
        if current.geometry.kind != before {
            log("geometry_evidence", ["gesture": current.id, "window": current.token,
                                      "geometry": current.geometry.kind,
                                      "changed_while_pressed": current.changedWhilePressed])
        }
    }

    func finish(_ reason: String) {
        sampleTimer?.invalidate()
        sampleTimer = nil
        guard let current = interaction else { return }
        interaction = nil
        if reason == "mouse_up" { completed += 1 }
        if current.geometry.moved { observedMoves += 1 }
        if current.geometry.resized { observedResizes += 1 }
        if current.geometry.kind == "unchanged" { observedUnchanged += 1 }
        log("gesture_end", ["gesture": current.id, "window": current.token, "reason": reason,
                            "geometry": current.geometry.kind, "drag_events": current.dragEvents,
                            "changed_while_pressed": current.changedWhilePressed,
                            "screen_changed": current.screenChanged,
                            "successful_samples": current.geometry.samples,
                            "failed_reads": current.geometry.failedReads,
                            "max_read_ms": Int(current.maxReadMS)])
        previous = (current.token, current.id, ProcessInfo.processInfo.systemUptime)
    }

    func ax(_ element: AXUIElement, notification: CFString) {
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let window = windowElement(element) else {
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            log("ax_notification", ["notification": notification as String, "window_resolved": false,
                                    "source_role": role as? String ?? "unknown", "role_error": roleError.rawValue])
            return
        }
        let id = token(window)
        var fields: [String: Any] = ["notification": notification as String, "window": id,
                                     "button_pressed": NSEvent.pressedMouseButtons & 1 != 0]
        if let current = interaction, current.token == id { fields["gesture"] = current.id; fields["phase"] = "during" }
        else if let previous, previous.token == id, ProcessInfo.processInfo.systemUptime - previous.ended < 2 {
            fields["gesture"] = previous.id; fields["phase"] = "after"
        } else { fields["phase"] = "uncorrelated" }
        log("ax_notification", fields)
    }

    func stop(_ reason: String) {
        finish("probe_stopped")
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        for observer in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        log("finished", ["reason": reason, "gestures": sequence, "complete_mouse_sequences": completed,
                         "with_position_change": observedMoves, "with_size_change": observedResizes,
                         "without_geometry_change": observedUnchanged, "lookup_failures": lookupFailures,
                         "raw_mouse_down": rawDowns, "raw_mouse_dragged": rawDrags,
                         "raw_mouse_up": rawUps, "filtered_mouse_down": filteredDowns,
                         "verdict": "human_labels_required_not_a_product_pass"])
    }
}

func probeAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                     _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<InteractionProbe>.fromOpaque(context).takeUnretainedValue().ax(element, notification: notification)
}

func selfCheck() {
    let initial = CGRect(x: 50, y: 50, width: 400, height: 300)
    var evidence = GeometryEvidence(initial: initial)
    evidence.observe(initial)
    assert(evidence.kind == "unchanged")
    evidence.observe(initial.offsetBy(dx: 30, dy: 0))
    evidence.observe(initial)
    assert(evidence.kind == "position", "Moving back must not erase observed movement")
    var resized = GeometryEvidence(initial: initial)
    resized.observe(CGRect(x: 50, y: 50, width: 500, height: 300))
    assert(resized.kind == "size")
    var failed = GeometryEvidence(initial: nil)
    failed.observe(initial)
    assert(failed.kind == "unknown", "A failed initial read must not look like a motionless click")
    print("SELF_CHECK_PASS: unchanged, move-and-return, resize, missing baseline; not a real-input test")
}

// A human starts and finishes this trial locally, independent of chat response time.
// The existing AX/input probe is unchanged; this panel only controls its lifetime.
@MainActor
final class ProbePanel: NSObject, NSWindowDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 285),
                         styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    let status = NSTextField(wrappingLabelWithString: "준비됐을 때 시작을 누르세요. 지금은 기록하지 않습니다.")
    let startButton = NSButton(title: "시작", target: nil, action: nil)
    let finishButton = NSButton(title: "두 동작 완료", target: nil, action: nil)
    var probe: InteractionProbe?
    var timer: Timer?
    var deadline = Date()

    override init() {
        super.init()
        window.title = "Plugback 입력 관찰"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.delegate = self
        let heading = NSTextField(labelWithString: "글자 선택과 창 크기 변경 확인")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.frame = NSRect(x: 20, y: 232, width: 390, height: 26)
        let instructions = NSTextField(wrappingLabelWithString:
            "시작을 누른 다음 Chrome에서 진행해 주세요.\n\n1. 페이지 글자를 3초간 드래그해서 선택\n2. 2초 쉬고, 오른쪽 아래 모서리로\n   창 크기를 3초간 변경\n3. 이 창의 ‘두 동작 완료’ 누르기")
        instructions.font = .systemFont(ofSize: 13)
        instructions.frame = NSRect(x: 20, y: 96, width: 390, height: 128)
        status.font = .systemFont(ofSize: 12)
        status.frame = NSRect(x: 20, y: 52, width: 390, height: 38)
        startButton.frame = NSRect(x: 126, y: 12, width: 112, height: 32)
        finishButton.frame = NSRect(x: 250, y: 12, width: 160, height: 32)
        startButton.bezelStyle = .rounded
        finishButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(begin)
        finishButton.target = self
        finishButton.action = #selector(complete)
        finishButton.isEnabled = false
        for view in [heading, instructions, status, startButton, finishButton] {
            window.contentView?.addSubview(view)
        }
    }

    func show() {
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.maxX - 450, y: frame.maxY - 325))
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let record: [String: Any] = ["event": "panel_ready", "accessibility_trusted": AXIsProcessTrusted(),
                                    "recording": false, "actions": ["text_selection", "resize"]]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    @objc func begin() {
        guard probe == nil else { return }
        let candidate = InteractionProbe()
        guard candidate.start() else {
            candidate.stop("setup_failed")
            status.stringValue = "관찰을 시작하지 못했습니다. 이 메시지를 대화에 알려주세요."
            return
        }
        probe = candidate
        deadline = Date().addingTimeInterval(180)
        startButton.isEnabled = false
        finishButton.isEnabled = true
        status.stringValue = "관찰 중 · 두 동작을 마치고 완료를 눌러주세요. (3분 제한)"
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.probe != nil else { return }
                let remaining = Int(ceil(self.deadline.timeIntervalSinceNow))
                if remaining <= 0 { self.end("time_limit", confirmed: false) }
                else { self.status.stringValue = "관찰 중 · 남은 시간 \(remaining)초\n두 동작을 마치면 ‘두 동작 완료’를 눌러주세요." }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func complete() { end("user_finished", confirmed: true) }

    func end(_ reason: String, confirmed: Bool) {
        timer?.invalidate()
        timer = nil
        guard let probe else { return }
        if confirmed {
            probe.log("human_action_confirmation", ["source": "complete_button", "actions": ["text_selection", "resize"]])
        }
        probe.stop(reason)
        self.probe = nil
        startButton.isEnabled = true
        startButton.title = "다시 시작"
        finishButton.isEnabled = false
        status.stringValue = confirmed
            ? "관찰을 마쳤습니다. 이 대화로 돌아와 ‘완료’라고 알려주세요."
            : "관찰 시간이 끝났습니다. 준비되면 ‘다시 시작’을 눌러주세요."
    }

    func windowWillClose(_ notification: Notification) {
        end("panel_closed", confirmed: false)
        exit(0)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--self-check"] { selfCheck(); exit(0) }
if arguments == ["--check"] {
    print("accessibility_trusted=\(AXIsProcessTrusted())")
    print("targets_running=\(NSWorkspace.shared.runningApplications.filter { ["com.google.Chrome", "com.apple.finder"].contains($0.bundleIdentifier ?? "") }.count)")
    exit(AXIsProcessTrusted() ? 0 : 2)
}
if arguments == ["--interactive"] {
    NSApplication.shared.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let panel = ProbePanel()
        panel.show()
        withExtendedLifetime(panel) { NSApplication.shared.run() }
    }
    exit(0)
}
let duration: TimeInterval
if arguments.isEmpty { duration = 180 }
else if arguments.count == 2, arguments[0] == "--seconds", let value = Double(arguments[1]), value >= 1, value <= 300 { duration = value }
else {
    FileHandle.standardError.write(Data("Usage: window-interaction-probe [--check | --self-check | --interactive | --seconds 1...300]\n".utf8))
    exit(2)
}
NSApplication.shared.setActivationPolicy(.prohibited)
let probe = InteractionProbe()
guard probe.start() else { probe.stop("setup_failed"); exit(2) }
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { probe.stop("interrupted"); exit(0) }
interrupt.resume()
let deadline = Timer(timeInterval: duration, repeats: false) { _ in
    probe.stop("time_limit")
    exit(0)
}
RunLoop.main.add(deadline, forMode: .common)
// AppKit's event dispatch is needed in addition to AX's CFRunLoop source.
// A plain RunLoop.run kept AX callbacks alive but did not record the first trial's mouse input.
NSApplication.shared.run()
