// G29 Control — a small macOS app to configure a Logitech G29 wheel without G HUB.
//
// Wheel commands come from the Linux kernel driver (hid-lg4ff), the reference
// implementation of Logitech's classic wheel protocol.
//
// Build: run ./build.sh (needs Xcode or the Command Line Tools: xcode-select --install)

import SwiftUI
import AppKit
import IOKit
import IOKit.hid

// MARK: - Wheel protocol

enum G29 {
    static let vendorID = 0x046D
    static let pidNative = 0xC24F   // G29, PS3 position (the mode PCs/Macs should use)
    static let pidPS4 = 0xC260      // G29, PS4 position
    static let pidCompat = 0xC294   // "Driving Force EX" fallback mode: pedals combined, ~200°
    static let allPIDs = [pidNative, pidPS4, pidCompat]

    static func modeName(_ pid: Int) -> String {
        switch pid {
        case pidNative: return "Native G29 mode"
        case pidPS4: return "PS4 mode"
        case pidCompat: return "Compatibility mode (pedals combined)"
        default: return String(format: "Unknown mode (0x%04X)", pid)
        }
    }

    static let revertIdentity: [UInt8] = [0xF8, 0x0A]
    static let switchToNative: [UInt8] = [0xF8, 0x09, 0x05, 0x01, 0x01]

    static func range(_ degrees: Int) -> [UInt8] {
        let d = min(900, max(40, degrees))
        return [0xF8, 0x81, UInt8(d & 0xFF), UInt8((d >> 8) & 0xFF)]
    }

    static let centeringOff: [UInt8] = [0xF5]
    static let centeringActivate: [UInt8] = [0x14]

    static func centering(percent: Int) -> [UInt8] {
        let mag = 0xFFFF * min(100, max(1, percent)) / 100
        var a: Int
        var b: Int
        if mag <= 0xAAAA {
            a = 0x0C * mag
            b = 0x80 * mag
        } else {
            a = 0x0C * 0xAAAA + 0x06 * (mag - 0xAAAA)
            b = 0x80 * 0xAAAA + 0xFF * (mag - 0xAAAA)
        }
        a /= 0xAAAA
        b /= 0xAAAA
        return [0xFE, 0x0D, UInt8(a & 0xFF), UInt8(a & 0xFF), UInt8(b & 0xFF)]
    }

    static func leds(_ count: Int) -> [UInt8] {
        let c = min(5, max(0, count))
        return [0xF8, 0x12, UInt8((1 << c) - 1)]
    }

    /// level 0...255, 128 = no force
    static func constantForce(_ level: Int) -> [UInt8] {
        return [0x11, 0x08, UInt8(min(255, max(0, level))), 0x80]
    }

    static let stopForce: [UInt8] = [0x13, 0x00]
}

// IOKit error codes (the C macros for these can't be imported into Swift)
enum IOErr {
    static let exclusiveAccess: UInt32 = 0xE00002C5
    static let notPrivileged: UInt32 = 0xE00002C1
    static let notPermitted: UInt32 = 0xE00002E2
    static let noDevice: UInt32 = 0xE00002C0
    static let notOpen: UInt32 = 0xE00002CD
}

/// Runs a command-line tool and waits for it; returns its exit status (-1 if it couldn't start).
@discardableResult
func runTool(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Model

struct Axis: Identifiable {
    let usage: UInt32
    var id: UInt32 { usage }
    var name: String
    var min: Int
    var max: Int
    var value: Int
    var restAtMax: Bool

    var normalized: Double {
        guard max > min else { return 0 }
        return Swift.min(1, Swift.max(0, Double(value - min) / Double(max - min)))
    }
    /// 0 = released, 1 = fully pressed (works whichever way the pedal reports)
    var pressed: Double { restAtMax ? 1 - normalized : normalized }
}

struct InputSnapshot {
    var axes: [Axis] = []
    var buttons: [Int] = []
    var hat: Int = 8
    var raw: [UInt8] = []
}

struct LogLine: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    let isError: Bool
}

final class WheelController: ObservableObject {
    @Published var connected = false
    @Published var pid = 0
    @Published var name = ""
    @Published var input = InputSnapshot()
    @Published var log: [LogLine] = []
    @Published var gHubRunning = false
    @Published var needsInputMonitoring = false
    @Published var lastWriteFailed = false

    @Published var rangeDegrees: Double = (UserDefaults.standard.object(forKey: "range") as? Double) ?? 900 {
        didSet { UserDefaults.standard.set(rangeDegrees, forKey: "range") }
    }
    @Published var centering: Double = (UserDefaults.standard.object(forKey: "centering") as? Double) ?? 0 {
        didSet { UserDefaults.standard.set(centering, forKey: "centering") }
    }
    @Published var autoApply: Bool = (UserDefaults.standard.object(forKey: "autoApply") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoApply, forKey: "autoApply") }
    }
    @Published var autoNative: Bool = (UserDefaults.standard.object(forKey: "autoNative") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoNative, forKey: "autoNative") }
    }
    @Published var ledCount: Double = 0

    private var manager: IOHIDManager!
    /// macOS can report one wheel as several HID entries (one per USB interface),
    /// and only some of them accept commands, so keep them all.
    private var devices: [IOHIDDevice] = []
    /// The entry that last accepted a command; tried first.
    private var preferred: IOHIDDevice?
    private var settleWork: DispatchWorkItem?
    /// Counts plug-ins, so delayed work can tell the wheel was replugged in the meantime.
    private var plugCount = 0
    private var plugTime = Date()
    private var lastSteerChange = Date()
    private var calibrationTimer: Timer?
    private var outputSize = 7
    private var axes: [UInt32: Axis] = [:]
    private var buttons = Set<Int>()
    private var hat = 8
    private var raw: [UInt8] = []
    private var dirty = false
    private var timer: Timer?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = G29.allPIDs.map {
            [kIOHIDVendorIDKey: G29.vendorID, kIOHIDProductIDKey: $0] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<WheelController>.fromOpaque(ctx).takeUnretainedValue().attached(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<WheelController>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, ctx)

        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            Unmanaged<WheelController>.fromOpaque(ctx).takeUnretainedValue().handle(value)
        }, ctx)

        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx else { return }
            let me = Unmanaged<WheelController>.fromOpaque(ctx).takeUnretainedValue()
            me.raw = Array(UnsafeBufferPointer(start: report, count: length))
            me.dirty = true
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            addLog("Could not open the USB device list: \(describe(r))", error: true)
            let code = UInt32(bitPattern: r)
            if code == IOErr.notPermitted || code == IOErr.notPrivileged {
                needsInputMonitoring = true
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.flush()
        }
        checkGHub()
        addLog("Waiting for a G29… (plug in the wheel and its power adapter)")
    }

    // MARK: Device events

    private func intProp(_ dev: IOHIDDevice, _ key: String) -> Int? {
        return (IOHIDDeviceGetProperty(dev, key as CFString) as? NSNumber)?.intValue
    }

    private func outputSize(of dev: IOHIDDevice) -> Int {
        return max(7, intProp(dev, kIOHIDMaxOutputReportSizeKey) ?? 7)
    }

    func attached(_ dev: IOHIDDevice) {
        guard !devices.contains(where: { CFEqual($0, dev) }) else { return }
        devices.append(dev)
        addLog(String(format: "USB interface found: 0x%04X, usage %02X:%02X, output %d bytes, input %d bytes",
                      intProp(dev, kIOHIDProductIDKey) ?? 0,
                      intProp(dev, kIOHIDPrimaryUsagePageKey) ?? 0,
                      intProp(dev, kIOHIDPrimaryUsageKey) ?? 0,
                      intProp(dev, kIOHIDMaxOutputReportSizeKey) ?? 0,
                      intProp(dev, kIOHIDMaxInputReportSizeKey) ?? 0))

        if !connected {
            axes = [:]
            buttons = []
            hat = 8
            dirty = true
            connected = true
            lastWriteFailed = false
            plugCount += 1
            plugTime = Date()
            lastSteerChange = Date()
        }
        updateIdentity()

        // macOS may report more entries in quick succession: act once, after it has finished
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func updateIdentity() {
        guard let dev = preferred ?? devices.first else { return }
        pid = intProp(dev, kIOHIDProductIDKey) ?? 0
        name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "Logitech wheel"
        outputSize = outputSize(of: dev)
    }

    /// Runs once per plug-in, 2 s after the last entry appeared
    /// (this also lets the wheel finish its power-on calibration).
    private func settled() {
        settleWork = nil
        guard connected else { return }
        updateIdentity()
        addLog("Connected: \(name) — \(G29.modeName(pid)) (output report \(outputSize) bytes)")
        checkGHub()

        if pid == G29.pidCompat {
            addLog("Gas and brake are combined in this mode — that's why releasing gas brakes the car.")
            if autoNative { switchToNative() }
        } else if pid == G29.pidPS4 {
            addLog("The wheel's switch is on PS4. Move it to PS3 and replug for full Mac/PC support.", error: true)
        } else if autoApply {
            applyAfterCalibration()
        }
    }

    /// After it's plugged in, the wheel calibrates (turns lock to lock) and then resets its
    /// spring and rotation, so settings sent before it finishes are lost. Wait until the
    /// wheel has been still for a moment (at most 15 s after plug-in), then apply.
    private func applyAfterCalibration() {
        calibrationTimer?.invalidate()
        addLog("Waiting for the wheel to finish calibrating…")
        let plug = plugCount
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self, self.connected, self.plugCount == plug else { timer.invalidate(); return }
            let now = Date()
            let sincePlug = now.timeIntervalSince(self.plugTime)
            let still = now.timeIntervalSince(self.lastSteerChange) >= 1.5
            guard (still && sincePlug >= 4) || sincePlug >= 15 else { return }
            timer.invalidate()
            self.calibrationTimer = nil
            self.applyAutomatically(plug: plug)
        }
    }

    private func applyAutomatically(plug: Int) {
        if applySettings(quietFailure: true) {
            // send once more shortly after, in case the wheel was still busy and dropped it
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.connected, self.plugCount == plug else { return }
                self.applySettings(quietFailure: true, quiet: true)
            }
        } else {
            addLog("Wheel not ready yet — retrying…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.connected, self.plugCount == plug else { return }
                self.applySettings()
            }
        }
    }

    func removed(_ dev: IOHIDDevice) {
        guard let i = devices.firstIndex(where: { CFEqual($0, dev) }) else { return }
        devices.remove(at: i)
        if let p = preferred, CFEqual(p, dev) { preferred = nil }
        if devices.isEmpty {
            settleWork?.cancel()
            settleWork = nil
            calibrationTimer?.invalidate()
            calibrationTimer = nil
            connected = false
            axes = [:]
            buttons = []
            raw = []
            dirty = true
            addLog("Wheel disconnected")
        } else {
            updateIdentity()
        }
    }

    func handle(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(el)
        let usage = IOHIDElementGetUsage(el)
        let v = IOHIDValueGetIntegerValue(value)

        if page == UInt32(kHIDPage_Button) {
            if v != 0 { buttons.insert(Int(usage)) } else { buttons.remove(Int(usage)) }
        } else if page == UInt32(kHIDPage_GenericDesktop) {
            if usage == UInt32(kHIDUsage_GD_Hatswitch) {
                hat = v
            } else if let n = axisName(usage) {
                if usage == 0x30 && axes[usage]?.value != v { lastSteerChange = Date() }
                if var a = axes[usage] {
                    a.value = v
                    axes[usage] = a
                } else {
                    let mn = IOHIDElementGetLogicalMin(el)
                    let mx = IOHIDElementGetLogicalMax(el)
                    axes[usage] = Axis(usage: usage, name: n, min: mn, max: mx, value: v,
                                       restAtMax: (mx - v) < (v - mn))
                }
            }
        }
        dirty = true
    }

    private func axisName(_ usage: UInt32) -> String? {
        switch usage {
        case 0x30: return "X"
        case 0x31: return "Y"
        case 0x32: return "Z"
        case 0x33: return "Rx"
        case 0x34: return "Ry"
        case 0x35: return "Rz"
        case 0x36: return "Slider"
        case 0x37: return "Dial"
        default: return nil
        }
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        input = InputSnapshot(axes: axes.values.sorted { $0.usage < $1.usage },
                              buttons: buttons.sorted(), hat: hat, raw: raw)
    }

    var steeringDegrees: Double {
        guard let x = input.axes.first(where: { $0.usage == 0x30 }) else { return 0 }
        return (x.normalized - 0.5) * rangeDegrees
    }

    /// Pedals in the same order as on the floor: clutch, brake, gas.
    /// G29 native mode reports clutch = Y (0x31), gas = Z (0x32), brake = Rz (0x35).
    var pedals: [Axis] {
        let order: [UInt32: Int] = [0x31: 0, 0x35: 1, 0x32: 2]
        return input.axes
            .filter { $0.usage != 0x30 }
            .sorted { (order[$0.usage] ?? 9, $0.usage) < (order[$1.usage] ?? 9, $1.usage) }
    }

    static func pedalName(_ axis: Axis) -> String {
        switch axis.usage {
        case 0x31: return "Clutch"
        case 0x35: return "Brake"
        case 0x32: return "Gas"
        default: return "Axis \(axis.name)"
        }
    }

    // MARK: Commands

    @discardableResult
    func send(_ bytes: [UInt8], _ label: String, quiet: Bool = false, quietFailure: Bool = false) -> Bool {
        guard !devices.isEmpty else {
            addLog("No wheel connected", error: true)
            return false
        }
        // try the entry that worked last time first, then every other one
        var candidates = devices
        if let p = preferred, let i = candidates.firstIndex(where: { CFEqual($0, p) }) {
            candidates.insert(candidates.remove(at: i), at: 0)
        }
        var firstError: IOReturn = kIOReturnSuccess
        for dev in candidates {
            var buf = [UInt8](repeating: 0, count: outputSize(of: dev))
            for (i, b) in bytes.enumerated() where i < buf.count { buf[i] = b }
            let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, buf, buf.count)
            if r == kIOReturnSuccess {
                if preferred == nil || !CFEqual(preferred!, dev) {
                    preferred = dev
                    updateIdentity()
                }
                lastWriteFailed = false
                if !quiet { addLog("\(label) ✓") }
                return true
            }
            if firstError == kIOReturnSuccess { firstError = r }
        }
        lastWriteFailed = true
        if !quietFailure {
            addLog("\(label) failed: \(describe(firstError))", error: true)
            explain(firstError)
        }
        return false
    }

    private func explain(_ r: IOReturn) {
        checkGHub()
        let code = UInt32(bitPattern: r)
        if code == IOErr.exclusiveAccess || gHubRunning {
            addLog("→ Another app is holding the wheel (usually Logitech G HUB). Click “Quit G HUB”, then Apply.", error: true)
        } else if code == IOErr.notPermitted || code == IOErr.notPrivileged {
            needsInputMonitoring = true
            addLog("→ macOS blocked access. Allow G29 Control in System Settings → Privacy & Security → Input Monitoring, then reopen the app.", error: true)
        } else if code == IOErr.noDevice || code == IOErr.notOpen {
            addLog("→ The wheel went away. Unplug and replug it (wheel + power adapter).", error: true)
        } else {
            addLog("→ Try: quit G HUB, unplug the wheel, wait 5 s, plug it back in.", error: true)
        }
    }

    @discardableResult
    func applySettings(quietFailure: Bool = false, quiet: Bool = false) -> Bool {
        guard connected else { addLog("No wheel connected", error: true); return false }
        if pid == G29.pidCompat {
            addLog("Switch to native mode first (button at the top).", error: true)
            return false
        }
        let deg = Int(rangeDegrees)
        guard send(G29.range(deg), "Rotation set to \(deg)°", quiet: quiet, quietFailure: quietFailure) else { return false }
        let c = Int(centering)
        if c == 0 {
            send(G29.centeringOff, "Centering spring off (free wheel)", quiet: quiet, quietFailure: quietFailure)
        } else if send(G29.centering(percent: c), "Centering spring \(c)%", quiet: quiet, quietFailure: quietFailure) {
            send(G29.centeringActivate, "activate", quiet: true, quietFailure: quietFailure)
        }
        if !quiet { flashLEDs() }
        return true
    }

    func switchToNative() {
        addLog("Switching to native G29 mode — the wheel will reconnect…")
        guard send(G29.revertIdentity, "Reset identity", quiet: true) else { return }
        send(G29.switchToNative, "Mode switch sent")
    }

    func setLEDs(_ count: Int) { send(G29.leds(count), "LEDs", quiet: true) }

    func flashLEDs() {
        guard send(G29.leds(5), "LEDs", quiet: true) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.send(G29.leds(Int(self.ledCount)), "LEDs", quiet: true)
        }
    }

    /// Short force-feedback pulse to prove the motor and the command channel work.
    func pulse(left: Bool) {
        guard send(G29.constantForce(left ? 40 : 216), left ? "Force test: pull left" : "Force test: pull right") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.send(G29.stopForce, "stop", quiet: true)
        }
    }

    // MARK: G HUB

    func checkGHub() {
        gHubRunning = runTool("/usr/bin/pgrep", ["-i", "lghub"]) == 0
    }

    func quitGHub() {
        runTool("/usr/bin/pkill", ["-i", "lghub"])
        addLog("Asked Logitech G HUB to quit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.checkGHub()
            if self.gHubRunning {
                self.addLog("G HUB restarted itself. In G HUB settings turn off “Start on login”, or uninstall it, then reboot.", error: true)
            } else {
                self.addLog("G HUB is closed. Unplug and replug the wheel, then Apply.")
            }
        }
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Log

    func addLog(_ text: String, error: Bool = false) {
        log.append(LogLine(text: text, isError: error))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func describe(_ r: IOReturn) -> String {
        let hex = String(format: "0x%08X", UInt32(bitPattern: r))
        return "\(hex) — \(String(cString: mach_error_string(r)))"
    }

    func copyLog() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        var text = log.map { "\(f.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
        text += "\n\nMode: \(G29.modeName(pid))\nLast raw report: "
        text += input.raw.map { String(format: "%02x", $0) }.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        addLog("Log copied to clipboard")
    }
}

// MARK: - Updates (from GitHub Releases)

struct AppRelease {
    let version: String
    let notes: String
    let page: URL
    let zip: URL?
}

final class Updater: ObservableObject {
    static let repo = "thisisyusub/G29Control"
    static let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

    @Published var available: AppRelease?
    @Published var checking = false
    @Published var installing = false

    @Published var autoCheck: Bool = (UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }

    private let log: (String, Bool) -> Void
    private var timer: Timer?

    init(log: @escaping (String, Bool) -> Void) {
        self.log = log
        // check shortly after launch, then once a day while the app keeps running
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.autoCheck else { return }
            self.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self = self, self.autoCheck else { return }
            self.check(userInitiated: false)
        }
    }

    /// "1.10.0" > "1.9.2"; missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
    }

    func check(userInitiated: Bool) {
        guard !checking, !installing else { return }
        checking = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap { try? JSONDecoder().decode(GitHubRelease.self, from: $0) }
            DispatchQueue.main.async {
                self.checking = false
                guard status == 200, let r = release else {
                    let reason = error?.localizedDescription ?? "GitHub answered with status \(status)"
                    self.log("Update check failed: \(reason)", true)
                    if userInitiated { self.alert("Couldn't check for updates", reason) }
                    return
                }
                let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
                guard Self.isNewer(version, than: Self.currentVersion) else {
                    self.available = nil
                    if userInitiated {
                        self.alert("You're up to date", "G29 Control \(Self.currentVersion) is the latest version.")
                    }
                    return
                }
                let zip = r.assets.first { $0.name == "G29Control.zip" }?.browser_download_url
                let release = AppRelease(version: version, notes: r.body ?? "", page: r.html_url, zip: zip)
                let isNew = self.available?.version != version
                self.available = release
                if isNew { self.log("Update available: G29 Control \(version) (you have \(Self.currentVersion))", false) }
                if userInitiated { self.offer(release) }
            }
        }.resume()
    }

    private func offer(_ r: AppRelease) {
        let a = NSAlert()
        a.messageText = "G29 Control \(r.version) is available"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "You have \(Self.currentVersion)."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(1200)))
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { install() }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// The app can replace itself only from a writable folder (not the disk image, and not
    /// the read-only copy macOS runs when the app was opened straight from Downloads).
    private var canReplaceInPlace: Bool {
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        return !app.path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: app.path)
    }

    func install() {
        guard let r = available, !installing else { return }
        guard let zip = r.zip, canReplaceInPlace else {
            alert("Install the update manually",
                  "G29 Control can't replace itself from where it's running. Download \(r.version) from the release page and drag it into Applications.")
            NSWorkspace.shared.open(r.page)
            return
        }
        installing = true
        log("Downloading G29 Control \(r.version)…", false)
        URLSession.shared.downloadTask(with: zip) { file, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<URL, Error>
            if let file = file, status == 200 {
                result = Result { try Self.unpack(file, expecting: r.version) }
            } else {
                result = .failure(UpdateError(error?.localizedDescription ?? "Download failed (status \(status))"))
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let newApp):
                    self.log("Installing G29 Control \(r.version) and relaunching…", false)
                    self.relaunch(into: newApp)
                case .failure(let e):
                    self.installing = false
                    self.log("Update failed: \(e.localizedDescription)", true)
                    self.alert("Update failed", "\(e.localizedDescription)\n\nYou can download it from the release page instead.")
                    NSWorkspace.shared.open(r.page)
                }
            }
        }.resume()
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Unzips the download and checks it's an intact G29 Control of the expected version.
    private static func unpack(_ download: URL, expecting version: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("G29Control-update-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("G29Control.zip")
        try fm.moveItem(at: download, to: zip)
        guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else {
            throw UpdateError("Couldn't unzip the update.")
        }
        guard let app = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("The download isn't the expected G29 Control \(version).")
        }
        guard runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError("The downloaded app's signature is broken.")
        }
        runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Quits, then a small shell script swaps the app bundle (restoring the old one if
    /// that fails) and opens it again.
    private func relaunch(into newApp: URL) {
        let dest = Bundle.main.bundleURL.path
        let old = newApp.deletingLastPathComponent().appendingPathComponent("previous.app").path
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        mv "$3" "$4" || { open "$3"; exit 1; }
        if mv "$2" "$3"; then rm -rf "$4"; else mv "$4" "$3"; fi
        open "$3"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                       newApp.path, dest, old]
        do {
            try p.run()
        } catch {
            installing = false
            log("Update failed: couldn't start the installer (\(error.localizedDescription))", true)
            return
        }
        NSApp.terminate(nil)
    }
}

// MARK: - App

@main
struct G29ControlApp: App {
    @StateObject private var wheel: WheelController
    @StateObject private var updater: Updater
    @AppStorage("showMenuBar") private var showMenuBar = true

    init() {
        let wheel = WheelController()
        _wheel = StateObject(wrappedValue: wheel)
        _updater = StateObject(wrappedValue: Updater { [weak wheel] text, error in
            wheel?.addLog(text, error: error)
        })
    }

    var body: some Scene {
        Window("G29 Control", id: "main") {
            MainView()
                .environmentObject(wheel)
                .environmentObject(updater)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check(userInitiated: true) }
                    .disabled(updater.checking || updater.installing)
            }
        }

        Window("Activity", id: "activity") {
            ActivityView()
                .environmentObject(wheel)
                .frame(minWidth: 560, minHeight: 340)
        }

        Settings {
            PreferencesView()
                .environmentObject(wheel)
                .environmentObject(updater)
        }

        MenuBarExtra("G29 Control", systemImage: "steeringwheel", isInserted: $showMenuBar) {
            MenuBarContent()
                .environmentObject(wheel)
                .environmentObject(updater)
        }
    }
}

// MARK: - Style helpers (Liquid Glass on macOS 26, frosted material before)

enum Palette {
    static let clutch = Color.blue
    static let brake = Color.red
    static let gas = Color.green
}

extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let tint = tint {
                self.glassEffect(.regular.tint(tint.opacity(0.35)),
                                 in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self.glassEffect(.regular,
                                 in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self.legacyCard(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        self.legacyCard(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    func legacyCard(cornerRadius: CGFloat, tint: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill((tint ?? Color.clear).opacity(0.18))
                }
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }
}

struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .tracking(1)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }
}

struct LabeledValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundColor(.secondary)
        }
    }
}

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject var wheel: WheelController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(spacing: 16) {
                    AlertsView()
                    HStack(alignment: .top, spacing: 16) {
                        if wheel.connected {
                            VStack(spacing: 16) {
                                SteeringCard()
                                HStack(alignment: .top, spacing: 16) {
                                    PedalsCard()
                                    ButtonsCard()
                                }
                            }
                        } else {
                            EmptyStateCard()
                        }
                        ControlsPanel().frame(width: 340)
                    }
                }
                .padding(20)
            }
        }
        .safeAreaInset(edge: .bottom) { FooterBar() }
        .navigationTitle("G29 Control")
        .navigationSubtitle(wheel.connected ? G29.modeName(wheel.pid) : "Not connected")
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Circle()
                .fill(wheel.connected ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
                .help(wheel.connected ? "Wheel connected" : "No wheel connected")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Switch to Native G29 Mode") { wheel.switchToNative() }
                    .disabled(!wheel.connected)
                Button("Quit Logitech G HUB") { wheel.quitGHub() }
                Divider()
                Button("Show Activity") { openWindow(id: "activity") }
                Button("Copy Diagnostics") { wheel.copyLog() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")

            Button {
                wheel.applySettings()
            } label: {
                Label("Apply to Wheel", systemImage: "arrow.down.circle")
            }
            .disabled(!wheel.connected)
            .help("Send rotation and centering settings to the wheel (⌘↩)")
        }
    }
}

struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(scheme == .dark ? 0.25 : 0.16),
                    Color.clear,
                    Palette.brake.opacity(scheme == .dark ? 0.12 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: Alerts

struct AlertsView: View {
    @EnvironmentObject var wheel: WheelController
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(spacing: 10) {
            if let update = updater.available {
                AlertRow(icon: "arrow.down.app.fill",
                         title: "G29 Control \(update.version) is available",
                         message: updater.installing
                            ? "Downloading… the app relaunches when it's done."
                            : "You have \(Updater.currentVersion). The app relaunches to finish installing.",
                         action: updater.installing ? nil : "Install Update",
                         tint: .accentColor) { updater.install() }
            }
            if wheel.gHubRunning {
                AlertRow(icon: "lock.fill",
                         title: "Logitech G HUB is running",
                         message: "It can lock the wheel so settings can't be sent.",
                         action: "Quit G HUB") { wheel.quitGHub() }
            }
            if wheel.connected && wheel.pid == G29.pidCompat {
                AlertRow(icon: "exclamationmark.triangle.fill",
                         title: "Compatibility mode",
                         message: "Gas and brake are combined and rotation is limited.",
                         action: "Switch to Native") { wheel.switchToNative() }
            }
            if wheel.connected && wheel.pid == G29.pidPS4 {
                AlertRow(icon: "switch.2",
                         title: "Wheel is in PS4 mode",
                         message: "Move the switch on the wheel to PS3, then unplug and replug it.")
            }
            if wheel.needsInputMonitoring {
                AlertRow(icon: "hand.raised.fill",
                         title: "macOS is blocking access to the wheel",
                         message: "Allow G29 Control under Privacy & Security → Input Monitoring.",
                         action: "Open Settings") { wheel.requestInputMonitoring() }
            }
        }
    }
}

struct AlertRow: View {
    let icon: String
    let title: String
    let message: String
    var action: String? = nil
    var tint: Color = .orange
    var perform: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            if let action = action {
                Button(action, action: perform).glassButtonStyle()
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16, tint: tint)
    }
}

// MARK: Steering

struct SteeringCard: View {
    @EnvironmentObject var wheel: WheelController

    var body: some View {
        let deg = wheel.steeringDegrees
        let half = max(1, wheel.rangeDegrees / 2)

        HStack(spacing: 32) {
            WheelGauge(degrees: deg)
                .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 6) {
                CardTitle("Steering")
                Text(String(format: "%+.0f°", deg))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Range ±\(Int(half))°")
                    .foregroundColor(.secondary)
                SteeringBar(value: deg / half)
                    .frame(height: 8)
                    .padding(.top, 10)
                HStack {
                    Text("Left")
                    Spacer()
                    Text("Right")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct WheelGauge: View {
    let degrees: Double

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [Color.primary.opacity(0.8), Color.primary.opacity(0.45)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: s * 0.09)
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: s * 0.86, height: s * 0.07)
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: s * 0.07, height: s * 0.42)
                    .offset(y: s * 0.21)
                Circle()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: s * 0.27, height: s * 0.27)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: s * 0.08, height: s * 0.08)
                Capsule()
                    .fill(Color.red)
                    .frame(width: s * 0.045, height: s * 0.09)
                    .offset(y: -s * 0.455)
            }
            .frame(width: s, height: s)
            .rotationEffect(.degrees(degrees))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.9), value: degrees)
    }
}

struct SteeringBar: View {
    let value: Double   // -1 ... 1

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let v = min(1, max(-1, value))
            let fill = max(4, abs(v) * w / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fill)
                    .offset(x: v >= 0 ? w / 2 : w / 2 - fill)
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1)
                    .offset(x: w / 2)
            }
        }
    }
}

// MARK: Pedals

struct PedalSlot: Identifiable {
    let usage: UInt32
    let name: String
    let axisName: String
    let color: Color
    var id: UInt32 { usage }

    static let all: [PedalSlot] = [
        PedalSlot(usage: 0x31, name: "Clutch", axisName: "Y", color: Palette.clutch),
        PedalSlot(usage: 0x35, name: "Brake", axisName: "Rz", color: Palette.brake),
        PedalSlot(usage: 0x32, name: "Gas", axisName: "Z", color: Palette.gas)
    ]
}

struct PedalsCard: View {
    @EnvironmentObject var wheel: WheelController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle("Pedals")
            HStack(alignment: .bottom, spacing: 26) {
                ForEach(PedalSlot.all) { slot in
                    PedalBar(slot: slot, axis: wheel.input.axes.first(where: { $0.usage == slot.usage }))
                }
            }
            .frame(maxWidth: .infinity)
            Text("In games: Gas → axis Z · Brake → axis Rz · Clutch → axis Y")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct PedalBar: View {
    let slot: PedalSlot
    let axis: Axis?

    private var value: Double { axis?.pressed ?? 0 }

    var body: some View {
        VStack(spacing: 8) {
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundColor(axis == nil ? .secondary : .primary)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(LinearGradient(colors: [slot.color.opacity(0.6), slot.color],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(height: 160 * value)
            }
            .frame(width: 36, height: 160)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.08), value: value)
            Text(slot.name).font(.subheadline.weight(.medium))
            Text("axis \(slot.axisName)").font(.caption2).foregroundColor(.secondary)
        }
    }
}

// MARK: Buttons

struct ButtonsCard: View {
    @EnvironmentObject var wheel: WheelController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle("Buttons")
            DPadView(hat: wheel.input.hat)
                .frame(width: 88, height: 88)
                .frame(maxWidth: .infinity)
            if wheel.input.buttons.isEmpty {
                Text("Press any button")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                    ForEach(wheel.input.buttons, id: \.self) { b in
                        Text("#\(b)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 230, alignment: .top)
        .glassCard()
    }
}

struct DPadView: View {
    let hat: Int

    private func isOn(_ d: Int) -> Bool {
        guard hat >= 0 && hat < 8 else { return false }
        return hat == d || hat == (d + 1) % 8 || hat == (d + 7) % 8
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            ForEach([0, 2, 4, 6], id: \.self) { d in
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 15))
                    .foregroundColor(isOn(d) ? Color.accentColor : Color.primary.opacity(0.25))
                    .offset(y: -29)
                    .rotationEffect(.degrees(Double(d) * 45))
            }
        }
    }
}

struct EmptyStateCard: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("Connect your G29")
                .font(.title2.weight(.semibold))
            Text("Plug in the wheel's USB cable and its power adapter,\nand set the mode switch to PS3.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 460)
        .glassCard()
    }
}

// MARK: Controls

struct ControlsPanel: View {
    @EnvironmentObject var wheel: WheelController

    private var presetBinding: Binding<Int> {
        Binding(
            get: { Int(wheel.rangeDegrees) },
            set: { newValue in
                wheel.rangeDegrees = Double(newValue)
                if wheel.connected { wheel.applySettings() }
            }
        )
    }

    private func commit(_ editing: Bool) {
        if !editing && wheel.connected { wheel.applySettings() }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle("Steering")
                LabeledValue(title: "Rotation", value: "\(Int(wheel.rangeDegrees))°")
                Slider(value: $wheel.rangeDegrees, in: 40...900, step: 10,
                       onEditingChanged: { editing in commit(editing) })
                Picker("Preset", selection: presetBinding) {
                    ForEach([180, 270, 540, 900], id: \.self) { d in
                        Text("\(d)°").tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Divider().padding(.vertical, 2)

                LabeledValue(title: "Centering spring",
                             value: wheel.centering == 0 ? "Off" : "\(Int(wheel.centering))%")
                Slider(value: $wheel.centering, in: 0...100, step: 1,
                       onEditingChanged: { editing in commit(editing) })
                HStack {
                    Text("Soft")
                    Spacer()
                    Text("Firm")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(18)
            .glassCard()

            VStack(alignment: .leading, spacing: 14) {
                CardTitle("Rev Lights")
                HStack {
                    RevLights(count: Int(wheel.ledCount)) { n in
                        wheel.ledCount = Double(n)
                        wheel.setLEDs(n)
                    }
                    Spacer()
                    Button("Flash") { wheel.flashLEDs() }
                        .glassButtonStyle()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .disabled(!wheel.connected)

            VStack(alignment: .leading, spacing: 14) {
                CardTitle("Force Feedback Test")
                HStack {
                    Button { wheel.pulse(left: true) } label: {
                        Label("Pull Left", systemImage: "arrow.left")
                    }
                    .glassButtonStyle()
                    Spacer()
                    Button { wheel.pulse(left: false) } label: {
                        Label("Pull Right", systemImage: "arrow.right")
                    }
                    .glassButtonStyle()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .disabled(!wheel.connected)

            Button { wheel.applySettings() } label: {
                Text("Apply to Wheel").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .glassButtonStyle(prominent: true)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!wheel.connected)
        }
    }
}

struct RevLights: View {
    let count: Int
    let onSet: (Int) -> Void
    private let colors: [Color] = [.green, .green, .yellow, .orange, .red]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { i in
                Button {
                    onSet(i + 1 == count ? i : i + 1)
                } label: {
                    Circle()
                        .fill(i < count ? colors[i] : Color.primary.opacity(0.12))
                        .frame(width: 22, height: 22)
                        .shadow(color: i < count ? colors[i].opacity(0.8) : Color.clear, radius: 6)
                }
                .buttonStyle(.plain)
                .help("Light \(i + 1)")
            }
        }
    }
}

// MARK: Footer

struct FooterBar: View {
    @EnvironmentObject var wheel: WheelController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            if let last = wheel.log.last {
                Image(systemName: last.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundColor(last.isError ? .orange : .secondary)
                Text(last.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(last.isError ? .primary : .secondary)
            }
            Spacer()
            Button("Activity…") { openWindow(id: "activity") }
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Activity window

struct ActivityView: View {
    @EnvironmentObject var wheel: WheelController

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            List(wheel.log) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.fmt.string(from: line.time))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(line.text)
                        .font(.system(size: 12))
                        .foregroundColor(line.isError ? .red : .primary)
                        .textSelection(.enabled)
                }
                .id(line.id)
            }
            .onChange(of: wheel.log.count) { _ in
                if let last = wheel.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { wheel.copyLog() } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
                .help("Copy the log and wheel state to the clipboard")
            }
        }
    }
}

// MARK: - Settings window (⌘,)

struct PreferencesView: View {
    @EnvironmentObject var wheel: WheelController
    @EnvironmentObject var updater: Updater
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some View {
        Form {
            Section("When the wheel connects") {
                Toggle("Apply my settings automatically", isOn: $wheel.autoApply)
                Toggle("Switch to native G29 mode automatically", isOn: $wheel.autoNative)
            }
            Section("App") {
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Text("Keep G29 Control in the menu bar so your settings are re-applied every time you plug the wheel in.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.autoCheck)
                HStack {
                    Text("Version \(Updater.currentVersion)")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Check Now") { updater.check(userInitiated: true) }
                        .disabled(updater.checking || updater.installing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 400)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var wheel: WheelController
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(wheel.connected ? "G29 · \(G29.modeName(wheel.pid))" : "No wheel connected")
        Divider()
        Button("Apply Settings") { wheel.applySettings() }
            .disabled(!wheel.connected)
        Menu("Rotation") {
            ForEach([180, 270, 540, 900], id: \.self) { d in
                Button("\(d)°") {
                    wheel.rangeDegrees = Double(d)
                    if wheel.connected { wheel.applySettings() }
                }
            }
        }
        Menu("Centering Spring") {
            ForEach([0, 10, 20, 40, 70], id: \.self) { c in
                Button(c == 0 ? "Off" : "\(c)%") {
                    wheel.centering = Double(c)
                    if wheel.connected { wheel.applySettings() }
                }
            }
        }
        Divider()
        if let update = updater.available {
            Button("Install Update \(update.version)…") { updater.install() }
                .disabled(updater.installing)
        } else {
            Button("Check for Updates…") { updater.check(userInitiated: true) }
                .disabled(updater.checking)
        }
        Button("Open G29 Control") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Quit G29 Control") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
