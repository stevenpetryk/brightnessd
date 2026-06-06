import Cocoa
import IOKit.hid

// Routes the native macOS brightness keys to DDC monitors via m1ddc,
// with a native-style HUD, a menubar slider, and an adjustable
// perceptual curve (value = max * position^gamma).
//
// Works with any DDC-capable external display: each display's max
// luminance is read from the monitor itself (e.g. 400 nits on an ASUS
// PA32QCV, 100 on most Dells). If the mouse cursor is on an external
// display, brightness keys are swallowed and turned into DDC writes.
// On the built-in display they pass through to macOS untouched.

// The patched m1ddc (DDC reply validation + 16-bit value fixes) is vendored
// as a submodule and built next to this binary by `make`.
let M1DDC: String = {
    if let override = ProcessInfo.processInfo.environment["BRIGHTNESSD_M1DDC"] {
        return override
    }
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    return exeDir.appendingPathComponent("m1ddc/m1ddc").path
}()
let STEPS = 16.0 // key presses across the full range, like macOS
let FINE_DIVISOR = 4.0 // shift+option = quarter steps

let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3

func m1ddc(_ uuid: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: M1DDC)
    p.arguments = ["display", uuid] + args
    let out = Pipe()
    p.standardOutput = out
    try! p.run()
    p.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Curve

var gamma = UserDefaults.standard.object(forKey: "gamma") as? Double ?? 0.5

// MARK: - Per-display state

final class DisplayState {
    let uuid: String
    let name: String
    let maxValue: Int
    var targetPosition: Double
    var lastWritten: Int
    var writeInFlight = false

    init(uuid: String, name: String, maxValue: Int, current: Int) {
        self.uuid = uuid
        self.name = name
        self.maxValue = maxValue
        lastWritten = current
        targetPosition = pow(Double(current) / Double(maxValue), 1.0 / gamma)
    }

    func value(forPosition pos: Double) -> Int {
        Int((Double(maxValue) * pow(pos, gamma)).rounded())
    }
}

let stateLock = NSLock()
var displays: [String: DisplayState] = [:] // uuid -> state; only DDC-capable externals
var probed: Set<String> = [] // externals we've attempted, capable or not
let ddcQueue = DispatchQueue(label: "ddc")

func discoverDisplays() {
    for screen in NSScreen.screens where !screen.isBuiltin {
        let uuid = screen.displayUUID
        let name = screen.localizedName
        stateLock.lock()
        let new = probed.insert(uuid).inserted
        stateLock.unlock()
        guard new else { continue }
        ddcQueue.async {
            // The bus can be transiently busy (hotplug settling, another DDC
            // client), so probe a few times before concluding the display
            // doesn't speak DDC (projector, TV over a dumb adapter).
            for attempt in 1 ... 5 {
                if let max = Int(m1ddc(uuid, ["max", "luminance"])),
                   let current = Int(m1ddc(uuid, ["get", "luminance"])) {
                    stateLock.lock()
                    displays[uuid] = DisplayState(uuid: uuid, name: name, maxValue: max, current: current)
                    stateLock.unlock()
                    NSLog("%@ (%@): max %d, current %d", name, uuid, max, current)
                    return
                }
                Thread.sleep(forTimeInterval: Double(attempt))
            }
            NSLog("%@ (%@) does not answer DDC luminance; ignoring until re-plug", name, uuid)
            stateLock.lock()
            probed.remove(uuid) // a screen-parameter change will re-probe
            stateLock.unlock()
        }
    }
}

func setPosition(_ pos: Double, for display: DisplayState) {
    stateLock.lock()
    display.targetPosition = min(max(pos, 0), 1)
    let value = display.value(forPosition: display.targetPosition)
    let kick = !display.writeInFlight
    if kick { display.writeInFlight = true }
    stateLock.unlock()
    NSLog("%@ -> %d (pos %.3f)", display.name, value, display.targetPosition)
    // Coalescing writer: key repeats outpace DDC, so writes always send
    // the latest target rather than queueing one write per keypress.
    if kick { ddcQueue.async { drainWrites(display) } }
    appDelegate.brightnessChanged(display)
}

func drainWrites(_ display: DisplayState) {
    while true {
        stateLock.lock()
        let target = display.value(forPosition: display.targetPosition)
        let last = display.lastWritten
        if last == target {
            display.writeInFlight = false
            stateLock.unlock()
            return
        }
        // The built-in display fades brightness changes in hardware; DDC
        // jumps abruptly. Emulate the fade by easing toward the target a
        // third of the remaining distance per write (each write takes tens
        // of ms, so this lands within a few hundred ms).
        let remaining = target - last
        let step = remaining > 0 ? max(1, remaining / 3) : min(-1, remaining / 3)
        let next = last + step
        stateLock.unlock()
        _ = m1ddc(display.uuid, ["set", "luminance", String(next)])
        stateLock.lock()
        display.lastWritten = next
        stateLock.unlock()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }

    var isBuiltin: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    var displayUUID: String {
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }
}

func cursorScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
}

func cursorDisplay() -> DisplayState? {
    guard let screen = cursorScreen(), !screen.isBuiltin else { return nil }
    stateLock.lock()
    defer { stateLock.unlock() }
    return displays[screen.displayUUID]
}

// MARK: - HUD tuning

struct TuneParam {
    let key: String
    let label: String
    let min: Double
    let max: Double
    let def: Double
    var step: Double = 1 // snap; colors use finer steps

    func snap(_ v: Double) -> Double { (v / step).rounded() * step }
    func format(_ v: Double) -> String { String(format: step < 1 ? "%.2f" : "%.0f", v) }
}

let TUNE_PARAMS: [TuneParam] = [
    TuneParam(key: "cornerRadius", label: "Corner radius", min: 8, max: 40, def: 22),
    TuneParam(key: "sunCenterY", label: "Sun center Y", min: 60, max: 170, def: 114),
    TuneParam(key: "ringRadius", label: "Ring radius", min: 6, max: 30, def: 21),
    TuneParam(key: "strokeWidth", label: "Stroke width", min: 2, max: 14, def: 6),
    TuneParam(key: "armInner", label: "Arm inner R", min: 10, max: 45, def: 32),
    TuneParam(key: "armOuter", label: "Arm outer R", min: 25, max: 80, def: 55),
    TuneParam(key: "lightL", label: "Light: lightness", min: 0, max: 1, def: 0, step: 0.05),
    TuneParam(key: "lightA", label: "Light: alpha", min: 0, max: 1, def: 0.65, step: 0.05),
    TuneParam(key: "darkL", label: "Dark: lightness", min: 0, max: 1, def: 0.65, step: 0.05),
    TuneParam(key: "darkA", label: "Dark: alpha", min: 0, max: 1, def: 0.9, step: 0.05),
    TuneParam(key: "barWidth", label: "Bar width", min: 100, max: 196, def: 161),
    TuneParam(key: "barHeight", label: "Bar height", min: 3, max: 16, def: 8),
    TuneParam(key: "barY", label: "Bar Y", min: 8, max: 60, def: 20),
    TuneParam(key: "segGap", label: "Segment gap", min: 0, max: 4, def: 1),
]

var tune: [String: Double] = Dictionary(uniqueKeysWithValues: TUNE_PARAMS.map { p in
    (p.key, UserDefaults.standard.object(forKey: "tune.\(p.key)") as? Double ?? p.def)
})

func T(_ key: String) -> CGFloat { CGFloat(tune[key]!) }

func logTune() {
    let state = TUNE_PARAMS.map { String(format: "%@=%.2f", $0.key, tune[$0.key]!) }.joined(separator: " ")
    NSLog("tune: %@", state)
}

// MARK: - Curve visualizer

final class CurveView: NSView {
    var position: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        for f in [0.25, 0.5, 0.75] {
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: r.minX + r.width * f, y: r.minY))
            grid.line(to: NSPoint(x: r.minX + r.width * f, y: r.maxY))
            grid.move(to: NSPoint(x: r.minX, y: r.minY + r.height * f))
            grid.line(to: NSPoint(x: r.maxX, y: r.minY + r.height * f))
            grid.stroke()
        }

        // x: key/slider position, y: fraction of the display's max luminance
        let curve = NSBezierPath()
        curve.lineWidth = 2
        for i in 0 ... 100 {
            let p = Double(i) / 100
            let pt = NSPoint(x: r.minX + r.width * p, y: r.minY + r.height * pow(p, gamma))
            i == 0 ? curve.move(to: pt) : curve.line(to: pt)
        }
        NSColor.controlAccentColor.setStroke()
        curve.stroke()

        let dot = NSPoint(x: r.minX + r.width * position, y: r.minY + r.height * pow(position, gamma))
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)).fill()
    }
}

// MARK: - HUD (mimics the native brightness bezel)

final class SegmentBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        // A dark plate forms the 1px border around and between segments.
        // Lit segments: in light mode they're punched out of the plate (the
        // bezel material shows through, exactly the background color); in
        // dark mode macOS inconsistently fills them with the sun color
        // instead — mirror that.
        let segments = 16
        let gap = T("segGap")
        let inner = bounds.insetBy(dx: 1, dy: 1)
        let segWidth = (inner.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let filled = Int((fraction * Double(segments)).rounded())
        let darkMode = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        NSColor.black.withAlphaComponent(0.8).setFill()
        bounds.fill()

        for i in 0 ..< filled {
            let rect = NSRect(x: inner.minX + CGFloat(i) * (segWidth + gap), y: inner.minY,
                              width: segWidth, height: inner.height)
            if darkMode {
                NSColor(white: T("darkL"), alpha: T("darkA")).setFill()
                rect.fill()
            } else {
                rect.fill(using: .clear)
            }
        }
    }
}

// Hand-drawn to match the native bezel's sun: a stroked ring (not a disc)
// with eight rounded arms, corona radius 50, arms 25 long.
final class SunView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Darker than secondaryLabelColor in light mode, to match the bezel.
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: T("darkL"), alpha: T("darkA"))
                : NSColor(white: T("lightL"), alpha: T("lightA"))
        }.setStroke()
        let c = NSPoint(x: bounds.midX, y: T("sunCenterY"))

        let lineWidth = T("strokeWidth")
        let ringRadius = T("ringRadius") // centerline
        let armInner = T("armInner")
        let armOuter = T("armOuter")

        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - ringRadius, y: c.y - ringRadius,
                                               width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = lineWidth
        ring.stroke()

        // Round caps extend lineWidth/2 past the endpoints, so inset them to
        // keep the drawn arms spanning exactly armInner...armOuter.
        let capInset = lineWidth / 2
        for i in 0 ..< 8 {
            let a = CGFloat(i) * .pi / 4
            let arm = NSBezierPath()
            arm.lineWidth = lineWidth
            arm.lineCapStyle = .round
            arm.move(to: NSPoint(x: c.x + cos(a) * (armInner + capInset), y: c.y + sin(a) * (armInner + capInset)))
            arm.line(to: NSPoint(x: c.x + cos(a) * (armOuter - capInset), y: c.y + sin(a) * (armOuter - capInset)))
            arm.stroke()
        }
    }
}

final class HUD {
    private let panel: NSPanel
    private let bar = SegmentBar()
    private var effect: NSVisualEffectView!
    private var sun: SunView!
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the native bezel has no shadow or border
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer!.masksToBounds = true
        panel.contentView!.addSubview(effect)

        sun = SunView(frame: panel.contentView!.bounds)
        effect.addSubview(sun)
        bar.wantsLayer = true // .clear punches out of the bar's own layer only
        effect.addSubview(bar)
        applyTune()
    }

    func applyTune() {
        effect.layer!.cornerRadius = T("cornerRadius")
        bar.frame = NSRect(x: (200 - T("barWidth")) / 2, y: T("barY"), width: T("barWidth"), height: T("barHeight"))
        sun.needsDisplay = true
        bar.needsDisplay = true
    }

    var pinned = false // while tuning: stay on screen until unpinned
    private var fadeID = 0 // invalidates in-flight fade completions

    func show(fraction: Double, onScreenWithUUID uuid: String) {
        applyTune()
        bar.fraction = fraction
        let screen = NSScreen.screens.first { $0.displayUUID == uuid } ?? NSScreen.main!
        let f = screen.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - 100, y: f.minY + 140))
        // Interrupt any in-flight fade-out: bump the generation so its
        // completion no-ops, and snap alpha back via a zero-length animation
        // (a bare alphaValue assignment doesn't cancel the running animator).
        fadeID += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        guard !pinned else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [self] _ in self.fade() }
    }

    func fade() {
        hideTimer?.invalidate()
        fadeID += 1
        let id = fadeID
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if self.fadeID == id { self.panel.orderOut(nil) }
        })
    }
}

// MARK: - Menubar

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hud = HUD()
    private let curveView = CurveView()
    private let gammaSlider = NSSlider(value: log(gamma), minValue: log(0.25), maxValue: log(3.0), target: nil, action: nil)
    private let gammaLabel = NSTextField(labelWithString: "")
    private var tuneMenu: NSMenu?
    private var tuneSliders: [NSSlider] = []
    private var tuneValueLabels: [NSTextField] = []
    private var hudWanted = false
    private var menuDisplay: DisplayState? // display the slider controls

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button!.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")

        let menu = NSMenu()
        let sliderItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        slider.frame = NSRect(x: 12, y: 4, width: 196, height: 20)
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        container.addSubview(slider)
        sliderItem.view = container
        menu.addItem(sliderItem)

        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())

        let curveItem = NSMenuItem()
        let curveContainer = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 152))
        curveView.frame = NSRect(x: 12, y: 36, width: 196, height: 112)
        curveContainer.addSubview(curveView)
        gammaSlider.frame = NSRect(x: 12, y: 8, width: 146, height: 20)
        gammaSlider.minValue = log(0.25)
        gammaSlider.maxValue = log(3.0)
        gammaSlider.target = self
        gammaSlider.action = #selector(gammaSliderMoved)
        gammaSlider.isContinuous = true
        curveContainer.addSubview(gammaSlider)
        gammaLabel.frame = NSRect(x: 162, y: 10, width: 50, height: 16)
        gammaLabel.isEditable = false
        gammaLabel.isBordered = false
        gammaLabel.drawsBackground = false
        gammaLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        gammaLabel.textColor = .secondaryLabelColor
        curveContainer.addSubview(gammaLabel)
        curveItem.view = curveContainer
        menu.addItem(curveItem)

        let tuneMenu = NSMenu()
        let rowH: CGFloat = 26
        let tuneContainer = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: rowH * CGFloat(TUNE_PARAMS.count) + 8))
        for (i, p) in TUNE_PARAMS.enumerated() {
            let y = tuneContainer.frame.height - 4 - rowH * CGFloat(i + 1)
            let label = NSTextField(labelWithString: p.label)
            label.frame = NSRect(x: 12, y: y + 4, width: 105, height: 16)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            tuneContainer.addSubview(label)
            let s = NSSlider(value: tune[p.key]!, minValue: p.min, maxValue: p.max,
                             target: self, action: #selector(tuneSliderMoved(_:)))
            s.frame = NSRect(x: 120, y: y + 2, width: 145, height: 20)
            s.isContinuous = true
            s.tag = i
            tuneContainer.addSubview(s)
            let value = NSTextField(labelWithString: "")
            value.frame = NSRect(x: 270, y: y + 4, width: 52, height: 16)
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.stringValue = p.format(tune[p.key]!)
            tuneContainer.addSubview(value)
            tuneSliders.append(s)
            tuneValueLabels.append(value)
        }
        let tuneViewItem = NSMenuItem()
        tuneViewItem.view = tuneContainer
        tuneMenu.addItem(tuneViewItem)
        tuneMenu.addItem(NSMenuItem(title: "Reset to defaults", action: #selector(resetTune), keyEquivalent: ""))
        tuneMenu.items.last!.target = self
        let tuneRootItem = NSMenuItem(title: "Tune HUD", action: nil, keyEquivalent: "")
        tuneRootItem.submenu = tuneMenu
        tuneMenu.delegate = self
        self.tuneMenu = tuneMenu
        menu.addItem(tuneRootItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit brightnessd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in discoverDisplays() }
        discoverDisplays()
        startEventTap()
        startHIDListener()
    }

    func brightnessChanged(_ display: DisplayState) {
        DispatchQueue.main.async {
            if self.menuDisplay === display { self.refreshUI() }
            if self.hudWanted {
                self.hudWanted = false
                self.hud.show(fraction: display.targetPosition, onScreenWithUUID: display.uuid)
            }
        }
    }

    private func refreshUI() {
        // Slider controls the display under the cursor, else the first known one.
        stateLock.lock()
        let fallback = displays.values.first
        stateLock.unlock()
        menuDisplay = cursorDisplay() ?? fallback
        gammaSlider.doubleValue = log(gamma)
        gammaLabel.stringValue = String(format: "γ %.2f", gamma)
        guard let d = menuDisplay else {
            slider.isEnabled = false
            infoItem.title = "No DDC display connected"
            curveView.position = 0
            return
        }
        slider.isEnabled = true
        slider.doubleValue = d.targetPosition
        curveView.position = d.targetPosition
        infoItem.title = String(format: "%@: %d / %d · γ %.2f", d.name, d.value(forPosition: d.targetPosition), d.maxValue, gamma)
    }

    @objc private func sliderMoved() {
        guard let d = menuDisplay else { return }
        setPosition(slider.doubleValue, for: d)
    }

    @objc private func gammaSliderMoved() {
        // Keep each display's current output; re-derive positions under the new curve.
        stateLock.lock()
        let snapshot = displays.values.map { ($0, $0.value(forPosition: $0.targetPosition)) }
        gamma = exp(gammaSlider.doubleValue)
        for (d, current) in snapshot {
            d.targetPosition = pow(Double(max(current, 1)) / Double(d.maxValue), 1.0 / gamma)
        }
        stateLock.unlock()
        UserDefaults.standard.set(gamma, forKey: "gamma")
        refreshUI()
    }

    @objc private func tuneSliderMoved(_ sender: NSSlider) {
        let p = TUNE_PARAMS[sender.tag]
        let v = p.snap(sender.doubleValue)
        sender.doubleValue = v
        tune[p.key] = v
        UserDefaults.standard.set(v, forKey: "tune.\(p.key)")
        tuneValueLabels[sender.tag].stringValue = p.format(v)
        logTune()
        previewHUD()
    }

    @objc private func resetTune() {
        for (i, p) in TUNE_PARAMS.enumerated() {
            tune[p.key] = p.def
            UserDefaults.standard.removeObject(forKey: "tune.\(p.key)")
            tuneSliders[i].doubleValue = p.def
            tuneValueLabels[i].stringValue = p.format(p.def)
        }
        logTune()
        previewHUD()
    }

    private func previewHUD() {
        stateLock.lock()
        let d = displays.values.first
        stateLock.unlock()
        hud.show(fraction: d?.targetPosition ?? 0.75, onScreenWithUUID: d?.uuid ?? "")
    }

    func keyPressed(up: Bool, fine: Bool, display: DisplayState) {
        hudWanted = true
        let step = (1.0 / STEPS) / (fine ? FINE_DIVISOR : 1.0)
        setPosition(display.targetPosition + (up ? step : -step), for: display)
    }

    private func startEventTap() {
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED),
            callback: tapCallback,
            userInfo: nil
        )!
        let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        NSLog("brightnessd running, gamma %.1f", gamma)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
        if menu === tuneMenu {
            hud.pinned = true
            previewHUD()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === tuneMenu {
            hud.pinned = false
            hud.fade()
        }
    }
}

var eventTap: CFMachPort!

let tapCallback: CGEventTapCallBack = { _, type, cgEvent, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return Unmanaged.passUnretained(cgEvent)
    }
    guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(cgEvent)
    }
    let keyCode = Int32((event.data1 & 0xFFFF_0000) >> 16)
    guard keyCode == NX_KEYTYPE_BRIGHTNESS_UP || keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN else {
        return Unmanaged.passUnretained(cgEvent)
    }
    guard let display = cursorDisplay() else {
        return Unmanaged.passUnretained(cgEvent) // built-in or non-DDC display: let macOS handle it
    }
    let keyFlags = event.data1 & 0x0000_FFFF
    let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
    if isDown {
        let fine = event.modifierFlags.contains([.shift, .option])
        appDelegate.keyPressed(up: keyCode == NX_KEYTYPE_BRIGHTNESS_UP, fine: fine, display: display)
    }
    return nil // swallow: don't let macOS also act on it
}

// MARK: - Bluetooth keyboard brightness keys
//
// Non-Apple keyboards' brightness keys arrive as consumer-page HID usages
// that macOS consumes below the CGEvent layer — they never become
// NX_SYSDEFINED events, so the tap can't see (or block) them. Observe them
// with IOHIDManager instead. Since macOS still applies its own handling to
// the built-in display, compensate by restoring its brightness afterwards
// via the DisplayServices private API.

let kCsmrBrightnessUp: UInt32 = 0x6F // kHIDUsage_Csmr_DisplayBrightnessIncrement
let kCsmrBrightnessDown: UInt32 = 0x70

final class BuiltinCompensator {
    private let getBrightness: @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private let setBrightness: @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var saved: Float = -1
    private var lastActivity = Date.distantPast

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)!
        getBrightness = unsafeBitCast(dlsym(handle, "DisplayServicesGetBrightness")!,
                                      to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
        setBrightness = unsafeBitCast(dlsym(handle, "DisplayServicesSetBrightness")!,
                                      to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
        sample()
        // Track the user's intended built-in brightness, but never while we
        // might be observing our own restore or macOS's unwanted step.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            if Date().timeIntervalSince(self.lastActivity) > 2 { self.sample() }
        }
    }

    private var builtinID: CGDirectDisplayID? {
        NSScreen.screens.first { $0.isBuiltin }?.displayID // nil in clamshell
    }

    private func sample() {
        guard let id = builtinID else { return }
        var value: Float = 0
        if getBrightness(id, &value) == 0 { saved = value }
    }

    func restoreSoon() {
        lastActivity = Date()
        guard let id = builtinID, saved >= 0 else { return }
        let value = saved
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.lastActivity = Date()
                _ = self.setBrightness(id, value)
            }
        }
    }
}

let builtinCompensator = BuiltinCompensator()

var hidManager: IOHIDManager!

func startHIDListener() {
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSLog("Input Monitoring not granted — Bluetooth keyboard brightness keys disabled. Grant in Privacy & Security > Input Monitoring, then restart.")
        return
    }
    hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let manager = hidManager!
    // Bluetooth only ("Bluetooth" = classic, "Bluetooth Low Energy" = BLE):
    // the built-in keyboard already arrives via the event tap, and matching
    // it here would double-handle every press.
    IOHIDManagerSetDeviceMatchingMultiple(manager, [
        [kIOHIDTransportKey: "Bluetooth"],
        [kIOHIDTransportKey: "Bluetooth Low Energy"],
    ] as CFArray)
    IOHIDManagerRegisterInputValueCallback(manager, { _, _, _, value in
        let element = IOHIDValueGetElement(value)
        guard IOHIDValueGetIntegerValue(value) == 1 else { return }
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let up: Bool
        if page == UInt32(kHIDPage_Consumer), usage == kCsmrBrightnessUp || usage == kCsmrBrightnessDown {
            up = usage == kCsmrBrightnessUp
        } else if page == UInt32(kHIDPage_KeyboardOrKeypad), usage == 0x3A || usage == 0x3B {
            // Keyboards that claim Apple's vendor ID (e.g. Lofree) send plain
            // F1/F2 and macOS itself maps them to brightness.
            up = usage == 0x3B
        } else {
            return
        }
        DispatchQueue.main.async {
            guard let display = cursorDisplay() else { return } // built-in: macOS handles it
            appDelegate.keyPressed(up: up, fine: false, display: display)
            builtinCompensator.restoreSoon()
        }
    }, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if result != kIOReturnSuccess {
        NSLog("IOHIDManagerOpen failed (0x%x) — Bluetooth keyboard brightness keys disabled", result)
    }
}

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    NSLog("Waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility), then restart.")
    exit(1)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
