import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

final class SnowApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var russian: Bool { preferences.language.usesRussian }
    private let verifyPath: String?
    private let verifyPanelOnly: Bool
    private var verifyWindow: NSWindow?
    private var verifyIsolatedWindow = true
    private var item: NSStatusItem?
    private var overlays: [(screen: NSScreen, panel: SnowPanel, view: SnowView)] = []
    private var timer: Timer?
    private let updates = AppUpdates()
    private let preferences: SnowPreferences
    private let verificationDefaults: String?
    private var controlPopover: NSPopover?
    private var lastAppliedIcon: SnowStyle?
    private var lastAppliedDark: Bool?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastSnapshot: TimeInterval = -.infinity
    private var lastMouse: CGPoint?
    private var fullscreen: Set<NSNumber> = []
    private var desktopTransition = DesktopTransition()
    private var spaceTransitionEnds: TimeInterval = 0
    private var paused: Bool { preferences.paused }
    private var lastKnownWindowCheck: TimeInterval = -.infinity
    private var checkedMissingWindows = Set<Int>()
    private var knownWindows = Set<Int>()
    private var lastSystemOwnerCheck: TimeInterval = -.infinity
    private var excludedOwners = Set<Int>()
    private var dockPID: Int?
    private var finderPID: pid_t?
    private var widgetOwners = Set<Int>()
    private var iconWindows: [DesktopWindow] = []
    private var iconReadPending = false
    private var nextIconRead: TimeInterval = 0
    private let iconQueue = DispatchQueue(label: "org.stillsnow.desktop-icons", qos: .utility)
    private var lowPower = false
    private var reduceMotion = false
    private var sleeping = false
    private var activeSession = true

    init(verifyPath: String?, verifyPanelOnly: Bool) {
        self.verifyPath = verifyPath
        self.verifyPanelOnly = verifyPanelOnly
        verificationDefaults = verifyPath.map { _ in "org.stillsnow.verify." + UUID().uuidString }
        let configuration = verificationDefaults.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        preferences = SnowPreferences(defaults: configuration)
        super.init()
    }

    private func tr(_ english: String, _ russian: String) -> String {
        self.russian ? russian : english
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = status
        status.button?.target = self
        status.button?.action = #selector(toggleControls)
        refreshAppearance()
        preferences.changed = { [weak self] in self?.applyPreferences() }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyIcon() }
        }
        applyPreferences()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(sleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(wake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockScreen),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlockScreen),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        workspace.addObserver(self, selector: #selector(motionChanged),
                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)

        if verifyPath == nil { updates.start() }
        rebuildOverlays()
        if verifyPanelOnly {
            verifyPanel()
        } else if verifyPath != nil {
            beginVerification()
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        rebuildOverlays()
    }

    func applicationDidHide(_ notification: Notification) {
        guard verifyPath == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isHidden else { return }
            NSApp.unhideWithoutActivation()
            self.controlPopover?.performClose(nil)
            self.lastSnapshot = -.infinity
        }
    }

    private func rebuildOverlays() {
        cancelSnowGestures()
        let savedFields = Dictionary(overlays.map { (screenID($0.screen), $0.view.field) },
                                     uniquingKeysWith: { first, _ in first })
        for overlay in overlays { overlay.panel.close() }
        overlays = NSScreen.screens.map { screen in
            let panel = SnowPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            let view = SnowView(screen: screen.frame)
            if let field = savedFields[screenID(screen)], field.bounds == screen.frame {
                view.field = field
            }
            view.onInputChanged = { [weak self] in self?.refreshInput() }
            panel.setFrame(screen.frame, display: false)
            panel.contentView = view
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.isRestorable = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenNone, .fullScreenDisallowsTiling]
            panel.level = .floating
            panel.becomesKeyOnlyIfNeeded = true
            panel.ignoresMouseEvents = true
            panel.delegate = self
            return (screen, panel, view)
        }
        fullscreen.removeAll()
        applyPreferences()
        lastSnapshot = -.infinity
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        lastMouse = nil
        lastSnapshot = -.infinity
        if paused || sleeping || !activeSession {
            for overlay in overlays { overlay.panel.orderOut(nil) }
            return
        }
        lastTick = ProcessInfo.processInfo.systemUptime
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frameInterval: TimeInterval = lowPower || reduceMotion || overlays.count > 1 ? 1.0 / 30 : 1.0 / 60
        let timer = Timer(timeInterval: frameInterval,
                          target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.001
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= spaceTransitionEnds, let main = NSScreen.screens.first else { return }
        let point = NSEvent.mouseLocation
        let pressed = NSEvent.pressedMouseButtons != 0
        let ownGesture = overlays.contains { $0.view.hasSnowGesture }
        let trackingWindow = pressed && !ownGesture && (lastMouse != point || now - lastSnapshot > 0.065)
        let dt = now - lastTick
        lastTick = now
        if trackingWindow || now - lastSnapshot >= 0.15 {
            lastSnapshot = now
            refreshWindowOwners(at: now)
            var scene = DesktopScene.snapshot(primaryTop: main.frame.maxY, includeOwn: verifyPath != nil,
                                              excludedOwners: excludedOwners, dockPID: dockPID, widgetOwners: widgetOwners)
            if verifyPath == nil { refreshDesktopIcons(at: now, primaryTop: main.frame.maxY) }
            if verifyIsolatedWindow, let sample = verifyWindow {
                scene.windows = scene.windows.filter { $0.id == sample.windowNumber }
            }
            let fullscreenPresentation = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            fullscreen = Set(overlays.filter {
                scene.isFullscreen(on: $0.screen, fullscreenPresentation: fullscreenPresentation)
            }.map { screenID($0.screen) })
            let transitioning = desktopTransition.unsettledWindows(
                in: scene.windows, now: now, dragging: pressed && lastMouse != point && !ownGesture)
            let onScreen = Set(scene.windows.map(\.id))
            let missing = Set(overlays.flatMap { $0.view.field.drifts.keys.filter { $0 > 0 } }).subtracting(onScreen)
            if !missing.isEmpty && (!missing.isSubset(of: checkedMissingWindows) || now - lastKnownWindowCheck >= 0.45) {
                knownWindows = DesktopScene.existingWindowIDs() ?? missing
                checkedMissingWindows = missing
                lastKnownWindowCheck = now
            }
            let retained = onScreen.union(knownWindows.intersection(missing))
            for overlay in overlays {
                if fullscreen.contains(screenID(overlay.screen)) {
                    if overlay.view.hasSnowGesture { overlay.view.cancelGesture() }
                    if overlay.panel.isVisible { overlay.panel.orderOut(nil) }
                } else {
                    let surfaces = scene.ledges(in: overlay.screen.frame, desktopIcons: iconWindows).filter { !transitioning.contains($0.id) }
                    let ledges = preferences.accumulate ? surfaces : surfaces.filter { $0.id == -1 }
                    if preferences.garlands {
                        overlay.view.garlandLedges = Array(surfaces.lazy.filter {
                            $0.id > 0 && $0.frame.width >= 140 && !$0.visible.isEmpty
                        }.prefix(8))
                    }
                    overlay.view.field.updateLedges(ledges, retainedWindowIDs: preferences.accumulate ? retained : [])
                    if !overlay.panel.isVisible { overlay.panel.orderFrontRegardless() }
                }
            }
        }
        let wind = CGVector(dx: CGFloat(preferences.wind % 3 - 1) * 54,
                            dy: CGFloat(preferences.wind / 3 - 1) * 19)
        let rates: [CGFloat] = [25, 64, 150]
        let energy: CGFloat = lowPower ? 0.67 : 1
        for overlay in overlays where overlay.panel.isVisible {
            let area = min(1.5, max(0.35, overlay.screen.frame.width / 1440))
            overlay.view.field.step(dt, rate: rates[preferences.weather] * area * energy / CGFloat(max(1, overlays.count)),
                                         wind: wind, plowsEnabled: preferences.snowplows && !reduceMotion)
            if !pressed, !ownGesture, controlPopover?.isShown != true, let previous = lastMouse,
               overlay.screen.frame.contains(previous), overlay.screen.frame.contains(point) {
                overlay.view.field.sweep(from: previous, to: point, preservePickup: true)
            }
            overlay.view.needsDisplay = true
        }
        refreshInput()
        lastMouse = point
    }

    private func refreshWindowOwners(at now: TimeInterval) {
        guard now - lastSystemOwnerCheck >= 3 else { return }
        let utilityApps: Set<String> = ["com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver",
                                        "com.apple.notificationcenterui", "com.apple.WindowManager"]
        let apps = NSWorkspace.shared.runningApplications
        excludedOwners = Set(apps.filter { $0.bundleIdentifier.map(utilityApps.contains) ?? false }
            .map { Int($0.processIdentifier) })
        dockPID = apps.first { $0.bundleIdentifier == "com.apple.dock" }.map { Int($0.processIdentifier) }
        finderPID = apps.first { $0.bundleIdentifier == "com.apple.finder" }?.processIdentifier
        widgetOwners = Set(apps.filter { app in
            guard let bundle = app.bundleIdentifier else { return false }
            return bundle == "com.apple.notificationcenterui" || bundle == "com.apple.widgetkit" ||
                bundle == "com.apple.dock" || bundle.hasPrefix("com.apple.WidgetKit.")
        }.map { Int($0.processIdentifier) })
        lastSystemOwnerCheck = now
    }

    private func refreshDesktopIcons(at now: TimeInterval, primaryTop: CGFloat) {
        guard preferences.desktopIcons && preferences.accumulate else {
            iconWindows = []
            return
        }
        guard now >= nextIconRead, !iconReadPending, let finderPID else { return }
        nextIconRead = now + 2
        guard AXIsProcessTrusted() else { iconWindows = []; return }
        iconReadPending = true
        iconQueue.async { [weak self] in
            let icons = DesktopIcons.snapshot(primaryTop: primaryTop, finderPID: finderPID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.iconReadPending = false
                if self.preferences.desktopIcons && self.preferences.accumulate { self.iconWindows = icons }
            }
        }
    }

    private func screenID(_ screen: NSScreen) -> NSNumber {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? 0
    }

    private func refreshInput() {
        let point = NSEvent.mouseLocation
        let mayBegin = NSEvent.pressedMouseButtons == 0 && controlPopover?.isShown != true
        for overlay in overlays {
            let accepts = overlay.panel.isVisible && (overlay.view.hasSnowGesture ||
                (mayBegin && overlay.screen.frame.contains(point) && overlay.view.field.pickup(at: point) != nil))
            if overlay.panel.ignoresMouseEvents == accepts { overlay.panel.ignoresMouseEvents = !accepts }
        }
    }

    private func refreshAppearance() {
        let icon = NSImage(systemSymbolName: paused ? "pause.circle" : "snowflake",
                           accessibilityDescription: "Still Snow")
        icon?.isTemplate = true
        item?.button?.image = icon
        item?.button?.toolTip = "Still Snow"
    }

    private var darkAppearance: Bool {
        let appearance = preferences.appearance.appKitAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func applyIcon() {
        let dark = darkAppearance
        guard lastAppliedIcon != preferences.icon || lastAppliedDark != dark else { return }
        NSApp.applicationIconImage = preferences.icon.appIcon(dark: dark)
        lastAppliedIcon = preferences.icon
        lastAppliedDark = dark
        refreshAppearance()
    }

    private func applyPreferences() {
        controlPopover?.appearance = preferences.appearance.appKitAppearance
        applyIcon()
        for overlay in overlays {
            overlay.view.snowColor = preferences.color.withAlphaComponent(preferences.opacity)
            overlay.view.particleScale = preferences.size
            overlay.view.particleOpacity = preferences.opacity
            overlay.view.flakeColor = preferences.color
            if !preferences.garlands { overlay.view.garlandLedges = [] }
            overlay.view.animateGarlands = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            overlay.view.needsDisplay = true
        }
        lastSnapshot = -.infinity
    }

    @objc private func toggleControls() {
        guard let anchor = item?.button else { return }
        if let panel = controlPopover, panel.isShown {
            panel.performClose(nil)
            return
        }
        cancelSnowGestures()
        let panel: NSPopover
        if let existing = controlPopover {
            panel = existing
        } else {
            panel = NSPopover()
            panel.behavior = .transient
            panel.animates = true
            panel.contentViewController = NSHostingController(rootView: SnowControlPanel(
                preferences: preferences, updates: updates,
                togglePause: { [weak self] in self?.togglePause() },
                clearSnow: { [weak self] in self?.clearSnow() },
                dispatchVehicle: { [weak self] helicopter in self?.dispatchVehicle(helicopter: helicopter) ?? false },
                checkUpdates: { [weak self] in self?.checkForUpdates() },
                quit: { [weak self] in self?.quit() }))
            panel.contentSize = CGSize(width: 395, height: 495)
            controlPopover = panel
        }
        panel.appearance = preferences.appearance.appKitAppearance
        panel.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func dispatchVehicle(helicopter: Bool) -> Bool {
        if paused { togglePause() }
        lastSnapshot = -.infinity
        tick()
        let pointer = NSEvent.mouseLocation
        let visible = overlays.filter { $0.panel.isVisible }
        let targets = visible.filter { $0.screen.frame.contains(pointer) } +
            visible.filter { !$0.screen.frame.contains(pointer) }
        for target in targets {
            if helicopter {
                target.view.field.callHelicopter()
            } else if !target.view.field.callPlow() {
                continue
            }
            controlPopover?.performClose(nil)
            return true
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? SnowPanel else { return }
        overlays.first { $0.panel === panel }?.view.cancelGesture()
    }

    private func cancelSnowGestures() {
        for overlay in overlays { overlay.view.cancelGesture() }
    }

    private func togglePause() {
        cancelSnowGestures()
        preferences.paused.toggle()
        refreshAppearance()
        schedule()
    }

    private func clearSnow() {
        cancelSnowGestures()
        for overlay in overlays { overlay.view.field.clear() }
    }

    @objc private func sleep() { sleeping = true; cancelSnowGestures(); schedule() }
    @objc private func wake() { sleeping = false; schedule() }
    @objc private func sessionInactive() { activeSession = false; cancelSnowGestures(); schedule() }
    @objc private func sessionActive() { activeSession = true; schedule() }
    @objc private func lockScreen() { sessionInactive() }
    @objc private func unlockScreen() { sessionActive() }
    @objc private func powerChanged() { schedule() }
    @objc private func motionChanged() {
        for overlay in overlays {
            overlay.view.animateGarlands = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        schedule()
    }
    @objc private func frontmostChanged() { lastSnapshot = -.infinity }

    @objc private func spaceChanged() {
        cancelSnowGestures()
        desktopTransition = DesktopTransition()
        spaceTransitionEnds = ProcessInfo.processInfo.systemUptime + 0.55
        rebuildOverlays()
    }

    private func checkForUpdates() {
        guard updates.canCheck else { return }
        controlPopover?.performClose(nil)
        DispatchQueue.main.async { [weak self] in self?.updates.check() }
    }

    private func quit() {
        if let verificationDefaults {
            UserDefaults(suiteName: verificationDefaults)?.removePersistentDomain(forName: verificationDefaults)
        }
        NSApp.terminate(nil)
    }

    private func verifyPanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.item?.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                var issues: [String] = []
                if self.controlPopover?.isShown != true { issues.append("Menu-bar panel failed to open") }
                if self.item?.button?.image?.isTemplate != true { issues.append("Status icon is not a template") }
                self.preferences.language = .russian
                self.preferences.appearance = .dark
                if !self.russian || !self.darkAppearance { issues.append("Language or appearance failed to change") }
                self.toggleControls()
                let result = issues.isEmpty ? "PASS: menu-bar popover, monochrome icon, language and appearance." :
                    "FAIL: " + issues.joined(separator: ", ")
                if let path = self.verifyPath { try? result.write(toFile: path, atomically: true, encoding: .utf8) }
                self.quit()
            }
        }
    }

    private func beginVerification() {
        guard let screen = NSScreen.screens.first else { finishVerification(["No graphical screen"]); return }
        preferences.weather = 2
        let frame = CGRect(x: screen.frame.midX - 210, y: screen.visibleFrame.maxY - 290, width: 420, height: 240)
        let sample = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sample.title = "Still Snow verification"
        sample.collectionBehavior = .fullScreenPrimary
        sample.isReleasedWhenClosed = false
        NSApp.activate()
        sample.makeKeyAndOrderFront(nil)
        sample.orderFrontRegardless()
        verifyWindow = sample
        lastSnapshot = -.infinity
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.verifyScene() }
    }

    private func verifyScene() {
        guard let id = verifyWindow?.windowNumber, let overlay = overlays.first else {
            finishVerification(["Sample window or overlay unavailable"])
            return
        }
        let counts = overlay.view.field.drifts[id]?.heights.filter { $0 > 0 }.count ?? 0
        var issues: [String] = []
        if counts == 0 {
            let exposed = overlay.view.field.drifts[id]?.ledge.visible.count ?? 0
            let particles = overlay.view.field.flakes.count
            let ground = overlay.view.field.drifts[-1]?.heights.filter { $0 > 0 }.count ?? 0
            let lowest = overlay.view.field.flakes.map { Int($0.position.y) }.min() ?? 0
            let edge = Int(overlay.view.field.drifts[id]?.ledge.top ?? 0)
            issues.append("No deposited snow on the WindowServer window (exposed=\(exposed), particles=\(particles), floor=\(ground), lowest=\(lowest), edge=\(edge))")
        }
        if !overlay.panel.isVisible { issues.append("Overlay is hidden") }
        if !overlay.panel.ignoresMouseEvents { issues.append("Normal overlay accepts mouse events") }
        if item?.button?.image?.isTemplate != true { issues.append("Status item icon is not monochrome") }
        if SnowStyle.allCases.contains(where: { $0.appIcon(dark: false) == nil || $0.appIcon(dark: true) == nil }) {
            issues.append("Missing one or more icon variants")
        }
        preferences.language = .russian
        preferences.appearance = .dark
        toggleControls()
        if !russian || !darkAppearance || controlPopover?.contentViewController == nil {
            issues.append("Russian dark menu-bar panel failed to load")
        }
        preferences.language = .english
        preferences.appearance = .light
        if russian || darkAppearance {
            issues.append("English light menu-bar panel failed to load")
        }
        controlPopover?.performClose(nil)
        let before = overlay.view.field.drifts[id]?.ledge.top
        if let frame = verifyWindow?.frame {
            verifyWindow?.setFrameOrigin(CGPoint(x: frame.minX + 24, y: frame.minY - 30))
        }
        lastSnapshot = -.infinity
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let after = overlay.view.field.drifts[id]?.ledge.top
            let movement = before.flatMap { old in after.map { old - $0 } } ?? 0
            if movement < 20 { issues.append("Snow ledge did not follow the moved window") }
            self.verifyFullscreen(issues, columns: counts, screen: overlay.screen)
        }
    }

    private func verifyFullscreen(_ initialIssues: [String], columns: Int, screen: NSScreen) {
        guard let sample = verifyWindow else {
            finishVerification(initialIssues + ["No sample window for fullscreen test"], columns: columns)
            return
        }
        let id = screenID(screen)
        verifyIsolatedWindow = false
        NSApp.activate()
        sample.makeKeyAndOrderFront(nil)
        sample.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            var issues = initialIssues
            if !sample.styleMask.contains(.fullScreen) {
                self.finishVerification(issues + ["Sample did not enter native fullscreen"], columns: columns)
                return
            }
            if self.overlays.contains(where: {
                self.screenID($0.screen) == id && $0.panel.isVisible && $0.panel.isOnActiveSpace
            }) {
                issues.append("Snow overlay remains on the active fullscreen space (sample=\(sample.frame), display=\(screen.frame))")
            }
            sample.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if !self.overlays.contains(where: {
                    self.screenID($0.screen) == id && $0.panel.isVisible && $0.panel.isOnActiveSpace
                }) {
                    issues.append("Overlay did not return after leaving fullscreen")
                }
                self.togglePause()
                if self.overlays.contains(where: { $0.panel.isVisible }) {
                    issues.append("Pause did not hide the overlay")
                }
                self.finishVerification(issues, columns: columns)
            }
        }
    }

    private func finishVerification(_ issues: [String], columns: Int = 0) {
        let summary = issues.isEmpty
            ? "PASS: real window, \(columns) accumulated columns, window move, click-through property, fullscreen entry and exit, pause, settings and icons."
            : "FAIL: " + issues.joined(separator: ", ")
        if let verifyPath { try? summary.write(toFile: verifyPath, atomically: true, encoding: .utf8) }
        quit()
    }
}

let args = CommandLine.arguments
let verifyPanelOnly = args.count == 3 && args[1] == "--verify-panel"
let verifyPath = args.count == 3 && (args[1] == "--verify" || verifyPanelOnly) ? args[2] : nil
let app = NSApplication.shared
app.setActivationPolicy(verifyPath == nil || verifyPanelOnly ? .accessory : .regular)
let controller = SnowApp(verifyPath: verifyPath, verifyPanelOnly: verifyPanelOnly)
app.delegate = controller
app.run()
