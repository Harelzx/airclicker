import AppKit
import AVFoundation
import CoreMotion

// MARK: - Settings

enum SlideAction: String {
    case next, previous

    var title: String {
        switch self {
        case .next: return "Next slide"
        case .previous: return "Previous slide"
        }
    }
}

/// How sharp a flick has to be. Each step trades accidental slides for effort.
enum Sensitivity: String, CaseIterable {
    case low, medium, high

    var title: String {
        switch self {
        case .low: return "Low (very sharp flick only)"
        case .medium: return "Medium"
        case .high: return "High (lighter flick)"
        }
    }

    /// Multiplies the flick thresholds.
    var scale: Double {
        switch self {
        case .low: return 1.35
        case .medium: return 1.0
        case .high: return 0.75
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var sensitivity: Sensitivity {
        get { defaults.string(forKey: "sensitivity").flatMap(Sensitivity.init) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "sensitivity") }
    }

    static var reversed: Bool {
        get { defaults.bool(forKey: "reversed") }
        set { defaults.set(newValue, forKey: "reversed") }
    }
}

/// Past 1 MB the log moves to AirClicker.old.log, replacing the previous one, so it never takes more than ~2 MB.
private let maxLogSize = 1_000_000

func writeLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let path = NSHomeDirectory() + "/Library/Logs/AirClicker.log"
    let fileManager = FileManager.default
    if let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int, size > maxLogSize {
        let oldPath = NSHomeDirectory() + "/Library/Logs/AirClicker.old.log"
        try? fileManager.removeItem(atPath: oldPath)
        try? fileManager.moveItem(atPath: path, toPath: oldPath)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        fileManager.createFile(atPath: path, contents: Data(line.utf8))
    }
}

// MARK: - Output: arrow keys to the frontmost app

enum KeySender {
    static let rightArrow: CGKeyCode = 0x7C
    static let leftArrow: CGKeyCode = 0x7B

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func send(_ action: SlideAction) {
        let key = action == .next ? rightArrow : leftArrow
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

// MARK: - Keep the AirPods link awake

/// Out of the ear and with nothing playing, the AirPods drop the Mac and the motion stream stops.
/// A silent loop keeps the Bluetooth link (and the sensors) alive.
final class SilentKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    init() {
        engine.attach(player)
        // Connecting or disconnecting AirPods changes the output device, which stops the engine.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            writeLog("audio output changed, restarting the silent loop")
            self.player.stop()
            self.play()
        }
    }

    func start() {
        running = true
        play()
    }

    private func play() {
        // Reconnect every time: the output format may have changed since the last start.
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
        buffer.frameLength = buffer.frameCapacity // zero-filled, so silent
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        } catch {
            writeLog("audio engine failed: \(error)")
        }
    }

    func stop() {
        running = false
        player.stop()
        engine.stop()
    }
}

// MARK: - Input: hand flick via AirPods motion sensors

/// Hold an AirPod and flick your hand: right = next, left = previous.
///
/// "Right" is read as rotation about the vertical axis (gyroscope projected onto gravity),
/// so it doesn't matter how the AirPod sits between your fingers.
/// Tuned on real flicks at 50 Hz. A flick counts only when the turn is
///   - fast: above 6.5 rad/s for two samples in a row (real flicks peak at 8-13); right flicks are
///     slower (median peak 10.5 vs 12.6), so they need only 5.5,
///   - long: past 75° (real flicks turn 80-130°; the short pull back before a left flick turns 45-75°),
///   - mostly horizontal, so twisting or raising the hand is ignored.
/// Right flicks also turn less (median 99° vs 125°), so a turn of 55-75° still counts, but only after
/// a short wait shows it was not the pull back before a flick the other way.
/// Right after a flick, a turn the other way is the swing back to center and never counts.
final class FlickListener: NSObject, CMHeadphoneMotionManagerDelegate {
    var onFlick: ((SlideAction) -> Void)?
    private(set) var isReceiving = false
    private var running = false

    private let manager = CMHeadphoneMotionManager()
    private var lastSample = Date.distantPast
    private var watchdog: Timer?

    private var burst: Burst?
    private var pending: Pending?
    private var lastBurstEnd: TimeInterval = 0
    private var lastFireTime: TimeInterval = 0
    private var lastFireRight = false
    private var sampleCount = 0
    private var rateWindowStart: TimeInterval = 0

    /// One turn in one direction, from leaving rest until it stops or reverses.
    private struct Burst {
        let right: Bool
        let start: TimeInterval
        var peakTime: TimeInterval = 0
        var lastTime: TimeInterval = 0
        var angle = 0.0
        var peakYaw = 0.0
        var peakTotal = 0.0
        var fastSamples = 0
        var sharp = false
        var fired = false
        var reason = "not sharp enough"
    }

    /// A short turn waiting to see whether a sharp turn the other way follows.
    private struct Pending {
        let right: Bool
        let start: TimeInterval
        let end: TimeInterval
        let angle: Double
    }

    private let peakRate = 6.5          // rad/s (~370°/s) at medium sensitivity
    private let rightPeakRate = 5.5     // rad/s (~315°/s), right flicks are slower
    private let minAngle = 75.0 * .pi / 180
    private let shortAngle = 55.0 * .pi / 180 // a shorter turn is never a flick
    private let windupWait = 0.35       // s a short turn waits for a sharp turn the other way
    private let burstStart = 2.0        // rad/s, a turn this fast begins a burst
    private let burstEnd = 1.5          // rad/s, slower than this the burst is over
    private let horizontalShare = 0.5   // yaw must be at least this share of all rotation
    private let repeatGap = 0.35        // s between two flicks in the same direction
    private let returnGap = 0.6         // s after a flick in which a turn the other way that starts is the swing back

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard !manager.isDeviceMotionActive else { return }
        guard manager.isDeviceMotionAvailable else {
            writeLog("head motion not available")
            return
        }
        burst = nil
        pending = nil
        sampleCount = 0
        rateWindowStart = 0
        running = true
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            if let error { writeLog("head motion error: \(error)") }
            // Updates already queued when stop() ran must not fire a slide.
            guard let self, self.running, let motion else { return }
            self.lastSample = Date()
            self.setReceiving(true)
            self.handle(motion)
        }
        // The stream can stall (AirPod in the case, out of range); show that in the menu.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastSample) > 1.5 { self.setReceiving(false) }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps running while the menu is open
        watchdog = timer
    }

    func stop() {
        running = false
        manager.stopDeviceMotionUpdates()
        watchdog?.invalidate()
        watchdog = nil
        setReceiving(false)
    }

    private func handle(_ motion: CMDeviceMotion) {
        let now = motion.timestamp
        let r = motion.rotationRate
        let g = motion.gravity
        // Gravity points down, so a positive projection is clockwise seen from above: a turn to the right.
        let yaw = r.x * g.x + r.y * g.y + r.z * g.z
        let total = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        logSampleRate(now)
        resolvePending(now)

        if let current = burst, abs(yaw) < burstEnd || (yaw > 0) != current.right {
            endBurst()
        }
        if burst == nil {
            guard abs(yaw) > burstStart else { return }
            burst = Burst(right: yaw > 0, start: now, lastTime: now)
        }
        guard var current = burst else { return }
        defer { burst = current }

        current.angle += yaw * (now - current.lastTime)
        current.lastTime = now
        current.peakTotal = max(current.peakTotal, total)
        if abs(yaw) > abs(current.peakYaw) {
            current.peakYaw = yaw
            current.peakTime = now
        }
        guard !current.fired else { return }

        let scale = Settings.sensitivity.scale
        if abs(yaw) > (current.right ? rightPeakRate : peakRate) * scale {
            if abs(yaw) >= horizontalShare * total {
                current.fastSamples += 1
                if current.fastSamples >= 2 { current.sharp = true }
            } else {
                current.fastSamples = 0
                if !current.sharp { current.reason = "not horizontal" }
            }
        } else {
            current.fastSamples = 0
        }
        guard current.sharp else { return }
        guard abs(current.angle) > minAngle else { // not scaled by sensitivity: this angle is what tells a wind-up from a flick
            current.reason = "too short (wind-up)"
            return
        }

        if let reason = blocked(right: current.right, start: current.start, now: now) {
            current.reason = reason
            return
        }
        current.fired = true
        fire(right: current.right, angle: current.angle, now: now)
    }

    /// Why a turn may not fire now, or nil if it may.
    private func blocked(right: Bool, start: TimeInterval, now: TimeInterval) -> String? {
        // Judged from when the turn began: a slow swing back may only peak well after the flick.
        if right != lastFireRight, start - lastFireTime < returnGap { return "return swing" }
        if right == lastFireRight, now - lastFireTime < repeatGap { return "too soon" }
        return nil
    }

    private func fire(right: Bool, angle: Double, now: TimeInterval, late: Bool = false) {
        lastFireTime = now
        lastFireRight = right
        writeLog(String(format: "flick %@ at %.0f°%@", right ? "right" : "left", abs(angle) * 180 / .pi, late ? " (short, after wait)" : ""))
        onFlick?(right != Settings.reversed ? .next : .previous)
    }

    /// Fires a waiting short turn, unless a sharp turn the other way showed it was a pull back.
    private func resolvePending(_ now: TimeInterval) {
        guard let waiting = pending else { return }
        if let current = burst, current.right != waiting.right, current.sharp {
            pending = nil
            writeLog(String(format: "short %@ turn of %.0f° dropped: pull back before a flick", waiting.right ? "right" : "left", abs(waiting.angle) * 180 / .pi))
            return
        }
        guard now - waiting.end >= windupWait else { return }
        pending = nil
        // After a stall (AirPod back in its case, out of range) the turn is too old to act on.
        guard now - waiting.end < windupWait + 0.2 else { return }
        if blocked(right: waiting.right, start: waiting.start, now: now) == nil {
            fire(right: waiting.right, angle: waiting.angle, now: now, late: true)
        }
    }

    /// Logs every fast turn with its timing, so thresholds can be tuned from real data.
    private func endBurst() {
        defer { burst = nil }
        guard let current = burst else { return }
        let gap = current.start - lastBurstEnd
        lastBurstEnd = current.lastTime
        guard current.sharp else { return } // only turns fast enough to have counted
        if !current.fired, abs(current.angle) >= shortAngle, abs(current.angle) <= minAngle,
           blocked(right: current.right, start: current.start, now: current.lastTime) == nil {
            pending = Pending(right: current.right, start: current.start, end: current.lastTime, angle: current.angle)
        }
        writeLog(String(format: "burst %@ %@: peak %.1f (total %.1f) rad/s, rise %.0fms, length %.0fms, angle %.0f°, gap %.0fms, t=%.3f",
                   current.right ? "R" : "L",
                   current.fired ? "FIRED" : "rejected (\(current.reason))",
                   current.peakYaw, current.peakTotal,
                   (current.peakTime - current.start) * 1000, (current.lastTime - current.start) * 1000,
                   current.angle * 180 / .pi, min(gap, 9.999) * 1000, current.start))
    }

    /// Logs the sensor rate once a minute; a slow stream explains missed flicks.
    private func logSampleRate(_ now: TimeInterval) {
        sampleCount += 1
        if rateWindowStart == 0 { rateWindowStart = now }
        guard now - rateWindowStart >= 60 else { return }
        writeLog(String(format: "motion rate %.0f Hz", Double(sampleCount) / (now - rateWindowStart)))
        sampleCount = 0
        rateWindowStart = now
    }

    private func setReceiving(_ on: Bool) {
        guard on != isReceiving else { return }
        isReceiving = on
        writeLog("head motion data \(on ? "flowing" : "stopped")")
    }

    // The delegate callbacks only log, to explain gaps in the motion stream when reading the log.
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        writeLog("head motion: headphones connected")
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        writeLog("head motion: headphones disconnected")
    }
}

// MARK: - Menu bar app

/// The menu bar icon: one tilted AirPod with two motion arcs, so it doesn't look like the
/// system's own AirPods control next to it. Drawn as a template so it follows light and dark menu bars.
enum StatusIcon {
    static let flick: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            if let pod = NSImage(systemSymbolName: "airpod.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) {
                NSGraphicsContext.current?.saveGraphicsState()
                let tilt = NSAffineTransform()
                tilt.translateX(by: 7.5, yBy: 9)
                tilt.rotate(byDegrees: -20)
                tilt.concat()
                pod.draw(in: NSRect(x: -pod.size.width / 2, y: -pod.size.height / 2, width: pod.size.width, height: pod.size.height))
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            NSColor.black.setStroke()
            for radius in [6.0, 9.0] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: 8, y: 9), radius: radius, startAngle: -35, endAngle: 35)
                arc.lineWidth = 1.4
                arc.lineCapStyle = .round
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AirClicker"
        return image
    }()

    static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AirClicker")
        image?.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keepAlive = SilentKeepAlive()
    private let flick = FlickListener()
    private var active = false
    private var lastEvent = "nothing yet"
    private var flashTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self // filled in menuNeedsUpdate, so it is always current when opened
        statusItem.menu = menu

        flick.onFlick = { [weak self] action in
            self?.perform(action, source: "Flick")
        }

        // Also adds AirClicker to the Accessibility list, so the user only has to switch it on.
        if !KeySender.isTrusted { KeySender.requestTrust() }
        setActive(true)
    }

    private func perform(_ action: SlideAction, source: String) {
        guard KeySender.isTrusted else {
            writeLog("\(source) -> \(action.rawValue) not sent: no Accessibility permission")
            lastEvent = "\(source) → not sent (needs Accessibility)"
            return
        }
        writeLog("\(source) -> \(action.rawValue)")
        lastEvent = "\(source) → \(action.title)"
        KeySender.send(action)
        flash(action == .next ? "forward.fill" : "backward.fill")
    }

    private func setActive(_ on: Bool) {
        active = on
        if on {
            keepAlive.start()
            flick.start()
        } else {
            flick.stop()
            keepAlive.stop()
        }
        setIcon(StatusIcon.flick)
    }

    /// Dimmed while presentation mode is off.
    private func setIcon(_ image: NSImage?) {
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !active
    }

    private func flash(_ symbol: String) {
        setIcon(StatusIcon.symbol(symbol))
        flashTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.setIcon(StatusIcon.flick)
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(title: "Presentation mode", action: #selector(toggleActive), keyEquivalent: "")
        toggle.target = self
        toggle.state = active ? .on : .off
        menu.addItem(toggle)
        menu.addItem(disabled("Flick an AirPod: right = next, left = back"))
        if active {
            menu.addItem(disabled(flick.isReceiving ? "Motion sensors: receiving ●" : "Motion sensors: no data ○"))
        }
        menu.addItem(.separator())

        let sensitivity = NSMenuItem(title: "Sensitivity: \(Settings.sensitivity.title)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for level in Sensitivity.allCases {
            let choice = NSMenuItem(title: level.title, action: #selector(chooseSensitivity(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = level.rawValue
            choice.state = Settings.sensitivity == level ? .on : .off
            sub.addItem(choice)
        }
        sensitivity.submenu = sub
        menu.addItem(sensitivity)

        let reverse = NSMenuItem(title: "Reverse direction", action: #selector(toggleReversed), keyEquivalent: "")
        reverse.target = self
        reverse.state = Settings.reversed ? .on : .off
        menu.addItem(reverse)
        menu.addItem(.separator())

        menu.addItem(disabled("Last: \(lastEvent)"))
        if !KeySender.isTrusted {
            let grant = NSMenuItem(title: "⚠︎ Grant Accessibility permission…", action: #selector(openAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        let test = NSMenuItem(title: "Test: send Next in 3 seconds", action: #selector(testNext), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AirClicker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleActive() { setActive(!active) }

    @objc private func chooseSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = Sensitivity(rawValue: raw) else { return }
        Settings.sensitivity = level
    }

    @objc private func toggleReversed() {
        Settings.reversed.toggle()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func testNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.perform(.next, source: "Test")
        }
    }
}

// LSUIElement in Info.plist keeps AirClicker out of the Dock: it lives only in the menu bar.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
