import AppKit
import CoreGraphics
import SwiftUI

final class SnowApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let defaults = UserDefaults.standard
    private var russian: Bool { preferences.language.usesRussian }
    private let verifyPath: String?
    private var verifyWindow: NSWindow?
    private var verifyIsolatedWindow = true
    private var item: NSStatusItem?
    private var overlays: [(screen: NSScreen, panel: SnowPanel, view: SnowView)] = []
    private var timer: Timer?
    private let updates = AppUpdates()
    private let preferences: SnowPreferences
    private let verificationDefaults: String?
    private var settingsWindow: NSWindow?
    private var lastAppliedIcon: SnowStyle?
    private var lastAppliedDark: Bool?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastSnapshot: TimeInterval = -.infinity
    private var lastMouse: CGPoint?
    private var fullscreen: Set<NSNumber> = []
    private var spaceTransitionEnds: TimeInterval = 0
    private var paused = false
    private var sculpting = false
    private var sculptingDeadline: TimeInterval = 0
    private var sleeping = false
    private var activeSession = true
    private var weather = 1
    private var tool: SnowTool = .glove
    private var horizontal = 0
    private var vertical = 0

    init(verifyPath: String?) {
        self.verifyPath = verifyPath
        verificationDefaults = verifyPath.map { _ in "org.stillsnow.verify." + UUID().uuidString }
        let configuration = verificationDefaults.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        preferences = SnowPreferences(defaults: configuration)
        super.init()
    }

    private func tr(_ english: String, _ russian: String) -> String {
        self.russian ? russian : english
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        weather = min(2, max(0, defaults.object(forKey: "weather") as? Int ?? 1))
        horizontal = min(1, max(-1, defaults.integer(forKey: "windX")))
        vertical = min(1, max(-1, defaults.integer(forKey: "windY")))
        tool = SnowTool(rawValue: defaults.integer(forKey: "tool")) ?? .glove

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = status
        status.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Still Snow")
        status.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        menuNeedsUpdate(menu)
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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockScreen),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlockScreen),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)

        if verifyPath == nil { updates.start() }
        rebuildOverlays()
        if verifyPath != nil { beginVerification() }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        rebuildOverlays()
    }

    func applicationDidHide(_ notification: Notification) {
        guard verifyPath == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isHidden else { return }
            NSApp.unhideWithoutActivation()
            self.settingsWindow?.orderOut(nil)
            self.lastSnapshot = -.infinity
        }
    }

    private func rebuildOverlays() {
        endSculpting()
        for overlay in overlays { overlay.panel.close() }
        overlays = NSScreen.screens.map { screen in
            let panel = SnowPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            let view = SnowView(screen: screen.frame)
            view.onCancel = { [weak self] in self?.endSculpting() }
            view.onInputChanged = { [weak self] in
                self?.sculptingDeadline = ProcessInfo.processInfo.systemUptime + 20
                self?.refreshInput()
            }
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
        let fps: Double = ProcessInfo.processInfo.isLowPowerModeEnabled ? 18 : 30
        let timer = Timer(timeInterval: 1 / fps, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.003
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        guard now >= spaceTransitionEnds, let main = NSScreen.screens.first else { return }
        if now - lastSnapshot >= (NSEvent.pressedMouseButtons == 0 ? 0.18 : 1.0 / 30) {
            lastSnapshot = now
            var scene = DesktopScene.snapshot(primaryTop: main.frame.maxY, includeOwn: verifyPath != nil)
            if verifyIsolatedWindow, let sample = verifyWindow {
                scene.windows = scene.windows.filter { $0.id == sample.windowNumber }
            }
            let fullscreenPresentation = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            fullscreen = Set(overlays.filter {
                scene.isFullscreen(on: $0.screen, fullscreenPresentation: fullscreenPresentation)
            }.map { screenID($0.screen) })
            for overlay in overlays {
                if fullscreen.contains(screenID(overlay.screen)) {
                    if overlay.view.field.held != nil { endSculpting() }
                    overlay.panel.orderOut(nil)
                } else {
                    let ledges = scene.ledges(in: overlay.screen.frame).filter { preferences.accumulate || $0.id == -1 }
                    overlay.view.field.updateLedges(ledges)
                    if !overlay.panel.isVisible { overlay.panel.orderFrontRegardless() }
                }
            }
        }
        if sculpting && now > sculptingDeadline && !overlays.contains(where: { $0.view.field.held != nil }) {
            endSculpting()
        }
        let point = NSEvent.mouseLocation
        let wind = CGVector(dx: CGFloat(horizontal) * 54, dy: CGFloat(vertical) * 19)
        let rates: [CGFloat] = [25, 64, 150]
        let energy: CGFloat = ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.67 : 1
        for overlay in overlays where overlay.panel.isVisible {
            let area = min(1.5, max(0.35, overlay.screen.frame.width / 1440))
            overlay.view.field.step(dt, rate: rates[weather] * area * energy / CGFloat(max(1, overlays.count)), wind: wind)
            if !sculpting, let previous = lastMouse,
               overlay.screen.frame.contains(previous), overlay.screen.frame.contains(point) {
                overlay.view.field.sweep(from: previous, to: point, tool: tool)
            }
            overlay.view.needsDisplay = true
        }
        refreshInput()
        lastMouse = point
    }

    private func screenID(_ screen: NSScreen) -> NSNumber {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? 0
    }

    private func refreshInput() {
        guard sculpting else { return }
        let point = NSEvent.mouseLocation
        let dragging = overlays.contains { $0.view.field.held != nil }
        for overlay in overlays {
            let held = overlay.view.field.held != nil
            let canPick = overlay.screen.frame.contains(point) && overlay.view.field.pickup(at: point) != nil
            overlay.panel.ignoresMouseEvents = !overlay.panel.isVisible || !(held || (!dragging && canPick))
        }
    }

    private func refreshAppearance() {
        let symbol = sculpting ? "hand.draw" : (paused ? "pause.circle" : "snowflake")
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "Still Snow")
        icon?.isTemplate = true
        item?.button?.image = icon
        item?.button?.toolTip = sculpting
            ? tr("Snowman mode · Esc to exit", "Лепка снеговика · Esc для выхода")
            : "Still Snow"
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
        settingsWindow?.appearance = preferences.appearance.appKitAppearance
        settingsWindow?.title = tr("Still Snow Settings", "Настройки Still Snow")
        applyIcon()
        for overlay in overlays {
            overlay.view.snowColor = preferences.color.withAlphaComponent(preferences.opacity)
            overlay.view.particleScale = preferences.size
            overlay.view.particleOpacity = preferences.opacity
            overlay.view.flakeColor = preferences.color
            overlay.view.needsDisplay = true
        }
        lastSnapshot = -.infinity
    }

    @objc private func showSettings() {
        endSculpting()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = tr("Still Snow Settings", "Настройки Still Snow")
            window.contentViewController = NSHostingController(rootView:
                SnowSettingsView(preferences: preferences))
            window.appearance = preferences.appearance.appKitAppearance
            window.isReleasedWhenClosed = false
            window.contentMinSize = CGSize(width: 540, height: 460)
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if sculpting, let panel = notification.object as? SnowPanel,
           overlays.contains(where: { $0.panel === panel && $0.view.field.held != nil }) {
            endSculpting()
        }
    }

    private func endSculpting() {
        sculpting = false
        for overlay in overlays {
            overlay.view.field.cancelBall()
            overlay.view.cursor = nil
            overlay.panel.ignoresMouseEvents = true
            overlay.view.needsDisplay = true
        }
        refreshAppearance()
    }

    @objc private func toggleSculpting() {
        if sculpting {
            endSculpting()
        } else if !paused {
            sculpting = true
            sculptingDeadline = ProcessInfo.processInfo.systemUptime + 20
            refreshAppearance()
        }
    }

    @objc private func togglePause() {
        endSculpting()
        paused.toggle()
        refreshAppearance()
        schedule()
    }

    @objc private func clearSnow() {
        endSculpting()
        for overlay in overlays { overlay.view.field.clear() }
    }

    @objc private func setWeather(_ sender: NSMenuItem) {
        weather = sender.tag
        defaults.set(weather, forKey: "weather")
    }

    @objc private func setTool(_ sender: NSMenuItem) {
        endSculpting()
        tool = SnowTool(rawValue: sender.tag) ?? .glove
        defaults.set(tool.rawValue, forKey: "tool")
    }

    @objc private func setWind(_ sender: NSMenuItem) {
        horizontal = sender.tag % 3 - 1
        vertical = sender.tag / 3 - 1
        defaults.set(horizontal, forKey: "windX")
        defaults.set(vertical, forKey: "windY")
    }

    @objc private func sleep() { sleeping = true; endSculpting(); schedule() }
    @objc private func wake() { sleeping = false; schedule() }
    @objc private func sessionInactive() { activeSession = false; endSculpting(); schedule() }
    @objc private func sessionActive() { activeSession = true; schedule() }
    @objc private func lockScreen() { sessionInactive() }
    @objc private func unlockScreen() { sessionActive() }
    @objc private func powerChanged() { schedule() }
    @objc private func spaceChanged() {
        endSculpting()
        spaceTransitionEnds = ProcessInfo.processInfo.systemUptime + 0.45
        rebuildOverlays()
    }

    @objc private func checkForUpdates() {
        guard updates.available else {
            let alert = NSAlert()
            alert.messageText = tr("Update source not configured", "Источник обновлений не настроен")
            alert.informativeText = tr(
                "This build is ready for signed updates once a release source is published.",
                "Эта сборка поддерживает подписанные обновления. Проверка заработает в сборке с адресом опубликованной ленты.")
            NSApp.activate()
            alert.runModal()
            return
        }
        updates.check()
    }

    @objc private func toggleUpdateChecks() {
        updates.automaticChecks.toggle()
    }

    @objc private func toggleUpdateInstallation() {
        updates.automaticInstallation.toggle()
    }

    @objc func validateMenuItem(_ entry: NSMenuItem) -> Bool {
        if entry.action == #selector(checkForUpdates) {
            return !updates.available || updates.canCheck
        }
        if entry.action == #selector(toggleUpdateInstallation) {
            return updates.available && updates.automaticChecks
        }
        if entry.action == #selector(toggleUpdateChecks) {
            return updates.available
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = menu.addItem(withTitle: "Still Snow", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        add(to: menu, paused ? tr("Resume snowfall", "Продолжить снег") : tr("Pause snowfall", "Пауза"),
            #selector(togglePause))
        menu.addItem(.separator())
        let weatherNames = [tr("Light", "Лёгкий"), tr("Steady", "Ровный"), tr("Flurry", "Метель")]
        let weatherMenu = NSMenu()
        for (index, title) in weatherNames.enumerated() {
            add(to: weatherMenu, title, #selector(setWeather), tag: index, selected: weather == index)
        }
        submenu(menu, tr("Snowfall", "Снегопад"), weatherMenu)
        let windMenu = NSMenu()
        let calm = tr("Calm", "Штиль")
        let directions = ["↙", "↓", "↘", "←", calm, "→", "↖", "↑", "↗"]
        for tag in [4, 3, 5, 7, 1, 6, 8, 0, 2] {
            add(to: windMenu, directions[tag], #selector(setWind), tag: tag,
                selected: tag == (vertical + 1) * 3 + horizontal + 1)
        }
        submenu(menu, tr("Wind", "Ветер"), windMenu)
        let toolMenu = NSMenu()
        add(to: toolMenu, tr("Glove", "Варежка"), #selector(setTool), tag: 0, selected: tool == .glove)
        add(to: toolMenu, tr("Shovel", "Лопата"), #selector(setTool), tag: 1, selected: tool == .shovel)
        submenu(menu, tr("Cursor tool", "Инструмент"), toolMenu)

        menu.addItem(.separator())
        add(to: menu, sculpting ? tr("Exit snowman mode", "Закончить лепку") :
            tr("Build a snowman", "Лепить снеговика"), #selector(toggleSculpting), selected: sculpting)
        if sculpting {
            let hint = menu.addItem(withTitle: tr("Drag snow onto a ledge or ball", "Перетащите снег на край или шар"),
                                    action: nil, keyEquivalent: "")
            hint.isEnabled = false
        }
        add(to: menu, tr("Clear snow", "Очистить снег"), #selector(clearSnow))
        menu.addItem(.separator())
        add(to: menu, tr("Settings…", "Настройки…"), #selector(showSettings), key: ",")
        let updateMenu = NSMenu()
        add(to: updateMenu, tr("Check for Updates…", "Проверить обновления…"), #selector(checkForUpdates))
        add(to: updateMenu, tr("Check Automatically", "Проверять автоматически"), #selector(toggleUpdateChecks),
            selected: updates.automaticChecks)
        add(to: updateMenu, tr("Install Automatically", "Устанавливать автоматически"), #selector(toggleUpdateInstallation),
            selected: updates.automaticInstallation)
        submenu(menu, tr("Updates", "Обновления"), updateMenu)
        add(to: menu, tr("Quit Still Snow", "Выйти из Still Snow"), #selector(quit), key: "q")
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, tag: Int = 0,
                     selected: Bool = false, key: String = "") {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.tag = tag
        entry.state = selected ? .on : .off
    }

    private func submenu(_ menu: NSMenu, _ title: String, _ submenu: NSMenu) {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func beginVerification() {
        guard let screen = NSScreen.screens.first else { finishVerification(["No graphical screen"]); return }
        weather = 2
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
        showSettings()
        if settingsWindow?.title != "Настройки Still Snow" || !darkAppearance {
            issues.append("Russian or dark settings failed to apply")
        }
        preferences.language = .english
        preferences.appearance = .light
        if settingsWindow?.title != "Still Snow Settings" || darkAppearance {
            issues.append("English or light settings failed to apply")
        }
        if settingsWindow?.contentViewController == nil || settingsWindow?.isVisible != true {
            issues.append("Settings view failed to load")
        }
        settingsWindow?.orderOut(nil)
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
        if let verificationDefaults {
            UserDefaults(suiteName: verificationDefaults)?.removePersistentDomain(forName: verificationDefaults)
        }
        if let verifyPath { try? summary.write(toFile: verifyPath, atomically: true, encoding: .utf8) }
        quit()
    }
}

let args = CommandLine.arguments
let verifyPath = args.count == 3 && args[1] == "--verify" ? args[2] : nil
let app = NSApplication.shared
app.setActivationPolicy(verifyPath == nil ? .accessory : .regular)
let controller = SnowApp(verifyPath: verifyPath)
app.delegate = controller
app.run()
