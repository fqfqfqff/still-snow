import AppKit
import CoreGraphics
import ApplicationServices

struct DesktopWindow {
    let id: Int
    let frame: CGRect
    let layer: Int
    let dock: Bool
    var supportsSnow = true
    var decorative = false

    // WindowServer reports a padded host around the visible desktop widget.
    var surfaceFrame: CGRect {
        guard decorative, id > 0 else { return frame }
        return frame.insetBy(dx: 8, dy: 8)
    }
}

struct DesktopTransition {
    private var previousFrames: [Int: CGRect] = [:]
    private var movingUntil: [Int: TimeInterval] = [:]

    mutating func unsettledWindows(in windows: [DesktopWindow], now: TimeInterval,
                                   dragging: Bool) -> Set<Int> {
        var frames: [Int: CGRect] = [:]
        for window in windows where window.supportsSnow && !window.dock && !window.decorative {
            frames[window.id] = window.frame
            guard !dragging, let before = previousFrames[window.id] else { continue }
            let distance = hypot(window.frame.minX - before.minX, window.frame.minY - before.minY)
            if distance >= 80 || (distance >= 2 && movingUntil[window.id, default: 0] > now) {
                movingUntil[window.id] = now + 0.28
            }
        }
        previousFrames = frames
        movingUntil = movingUntil.filter { !dragging && $0.value > now && frames[$0.key] != nil }
        return Set(movingUntil.keys)
    }
}

struct DesktopScene {
    var windows: [DesktopWindow]

    static func existingWindowIDs() -> Set<Int>? {
        guard let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return Set(all.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    static func snapshot(primaryTop: CGFloat, includeOwn: Bool = false,
                         excludedOwners: Set<Int> = [], dockPID: Int? = nil, widgetOwners: Set<Int> = []) -> DesktopScene {
        let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly,
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let windows = raw.compactMap { item -> DesktopWindow? in
            guard let id = item[kCGWindowNumber as String] as? Int,
                  let owner = item[kCGWindowOwnerPID as String] as? Int,
                  includeOwn || owner != ownPID,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 44, rect.height >= 18,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0.1 else { return nil }
            let dock = owner == dockPID && rect.width >= 85 && rect.height <= 160 &&
                rect.width / rect.height >= 1.35
            let widget = !dock && widgetOwners.contains(owner) && layer < 0 &&
                (60...470).contains(rect.width) && (60...470).contains(rect.height)
            guard layer == 0 || dock || widget else { return nil }
            let frame = CGRect(x: rect.minX, y: primaryTop - rect.maxY,
                               width: rect.width, height: rect.height)
            let supports = dock || (!excludedOwners.contains(owner) && rect.width >= 100 && rect.height >= 64)
            return DesktopWindow(id: id, frame: frame, layer: layer, dock: dock, supportsSnow: supports || widget, decorative: widget)
        }
        return DesktopScene(windows: windows)
    }

    func isFullscreen(on screen: NSScreen, fullscreenPresentation: Bool) -> Bool {
        windows.contains { window in
            window.layer == 0 && window.supportsSnow && !window.dock &&
                DisplayCoverage.isFullscreen(window: window.frame, screen: screen.frame,
                                             topInset: screen.safeAreaInsets.top,
                                             fullscreenPresentation: fullscreenPresentation)
        }
    }

    func ledges(in frame: CGRect, desktopIcons: [DesktopWindow] = []) -> [Ledge] {
        let normals = windows.filter { $0.layer == 0 && !$0.dock }
        var ledges: [Ledge] = []
        if let dock = windows.first(where: {
            $0.dock && $0.frame.intersects(frame) && abs($0.frame.minY - frame.minY) <= 42
        }), let ledge = makeLedge(id: -2, rect: dock.frame, on: frame, coveredBy: []) {
            ledges.append(ledge)
        }
        var blockers: [CGRect] = []
        for window in normals.prefix(100) where window.frame.intersects(frame) {
            if window.supportsSnow, ledges.count < 55, let ledge = makeLedge(id: window.id, rect: window.frame,
                                                       on: frame, coveredBy: blockers) {
                ledges.append(ledge)
            }
            blockers.append(window.frame)
        }
        for element in (windows.filter(\.decorative) + desktopIcons).prefix(120) {
            if let ledge = makeLedge(id: element.id, rect: element.surfaceFrame, on: frame,
                                     coveredBy: blockers, decorative: true) {
                ledges.append(ledge)
            }
        }
        let bottom = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1)
        if let ledge = makeLedge(id: -1, rect: bottom, on: frame, coveredBy: blockers) {
            ledges.append(ledge)
        }
        return ledges
    }

    private func makeLedge(id: Int, rect: CGRect, on screen: CGRect, coveredBy: [CGRect], decorative: Bool = false) -> Ledge? {
        // Show Desktop leaves a sliver of each parked window at the screen edge.
        let intersection = rect.intersection(screen)
        if id > 0 && (intersection.height < min(42, rect.height * 0.33) ||
                      intersection.width < min(42, rect.width * 0.33)) {
            return nil
        }
        let left = max(screen.minX, rect.minX)
        let right = min(screen.maxX, rect.maxX)
        guard right - left >= 2, rect.maxY >= screen.minY, rect.maxY <= screen.maxY - 2 else {
            return nil
        }
        let widget = decorative && id > 0
        var corner: CGFloat = id > 0 ? min(8, rect.width * 0.06) : 0
        if widget { corner = min(20, rect.width * 0.19) }
        let innerLeft = max(left, rect.minX + corner)
        let innerRight = min(right, rect.maxX - corner)
        guard innerRight - innerLeft >= 2 else { return nil }
        var visible = [innerLeft...innerRight]
        let band = CGRect(x: left - 14, y: rect.maxY - 36, width: right - left + 28, height: 123)
        let occluders = coveredBy.map { $0.intersection(band) }.filter { !$0.isNull && !$0.isEmpty }
        for blocker in occluders where blocker.minY <= rect.maxY + 0.5 && blocker.maxY > rect.maxY + 0.5 {
            visible = visible.flatMap { range in
                if blocker.maxX <= range.lowerBound || blocker.minX >= range.upperBound { return [range] }
                var slices: [ClosedRange<CGFloat>] = []
                if blocker.minX - range.lowerBound >= 2 { slices.append(range.lowerBound...blocker.minX) }
                if range.upperBound - blocker.maxX >= 2 { slices.append(blocker.maxX...range.upperBound) }
                return slices
            }
            if visible.isEmpty { break }
        }
        // Keep an occluded surface in the simulation so its drift can reappear.
        return Ledge(id: id, frame: rect, visible: visible, occluders: occluders, decorative: decorative)
    }
}

// Finder exposes desktop icons as accessibility items inside its desktop scroll area.
enum DesktopIcons {
    static func snapshot(primaryTop: CGFloat, finderPID: pid_t) -> [DesktopWindow] {
        let finder = AXUIElementCreateApplication(finderPID)
        AXUIElementSetMessagingTimeout(finder, 0.25)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        let containers = children(of: finder, limit: 35).filter {
            attribute($0, kAXRoleAttribute) as? String == kAXScrollAreaRole
        }
        var result: [DesktopWindow] = []
        var seen = Set<CGRectKey>()
        for container in containers {
            let direct = children(of: container, limit: 120)
            let groups = direct.filter {
                let role = attribute($0, kAXRoleAttribute) as? String
                return role == kAXListRole || role == kAXGroupRole || role == kAXLayoutAreaRole
            }
            let elements = direct + groups.flatMap { children(of: $0, limit: 120) }
            for element in elements.prefix(160) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return result }
                let role = attribute(element, kAXRoleAttribute) as? String
                guard role == kAXImageRole || role == kAXLayoutItemRole,
                      let positionValue = attribute(element, kAXPositionAttribute),
                      let sizeValue = attribute(element, kAXSizeAttribute),
                      CFGetTypeID(positionValue) == AXValueGetTypeID(),
                      CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }
                var position = CGPoint.zero
                var size = CGSize.zero
                guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                      position.x.isFinite, position.y.isFinite,
                      (14...270).contains(size.width), (14...240).contains(size.height) else { continue }
                let width = min(size.width, size.height, 128)
                let frame = CGRect(x: position.x + (size.width - width) / 2, y: primaryTop - position.y - width,
                                   width: width, height: width)
                let key = CGRectKey(x: Int(frame.minX.rounded()), y: Int(frame.maxY.rounded()))
                guard seen.insert(key).inserted else { continue }
                let id = -10 - Int(UInt(bitPattern: key.hashValue) % UInt(Int.max - 10))
                result.append(DesktopWindow(id: id, frame: frame, layer: -1, dock: false, decorative: true))
            }
        }
        return result
    }

    private struct CGRectKey: Hashable {
        let x: Int
        let y: Int
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private static func children(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var count = 0
        let name = kAXChildrenAttribute as CFString
        guard AXUIElementGetAttributeValueCount(element, name, &count) == .success, count > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, name, 0, min(count, limit), &values) == .success
        else { return [] }
        return values as? [AXUIElement] ?? []
    }
}

final class SnowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SnowView: NSView {
    var field: Snowfield
    private var cursor: CGPoint?
    private var pressOrigin: CGPoint?
    private var draggingBall = false
    var hasSnowGesture: Bool { pressOrigin != nil }
    var onInputChanged: (() -> Void)?
    var snowColor = NSColor(srgbRed: 0.88, green: 0.94, blue: 1, alpha: 0.96)
    var particleScale: CGFloat = 1
    var particleOpacity: CGFloat = 0.92
    var flakeColor = NSColor.white
    var garlandLedges: [Ledge] = []
    var animateGarlands = true
    private let bulbColors: [CGColor] = [
        CGColor(red: 1, green: 0.34, blue: 0.31, alpha: 1),
        CGColor(red: 1, green: 0.79, blue: 0.34, alpha: 1),
        CGColor(red: 0.38, green: 0.89, blue: 0.64, alpha: 1),
        CGColor(red: 0.36, green: 0.70, blue: 1, alpha: 1)
    ]
    private let snowShadow = NSColor(srgbRed: 0.46, green: 0.62, blue: 0.76, alpha: 0.86)
    private let ink = NSColor(srgbRed: 0.16, green: 0.25, blue: 0.33, alpha: 0.95)

    init(screen: CGRect) {
        field = Snowfield(bounds: screen, seed: UInt64(abs(screen.minX.rounded())) + 23)
        super.init(frame: CGRect(origin: .zero, size: screen.size))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = global(event)
        guard field.beginBall(at: point) else { return }
        pressOrigin = point
        window?.makeFirstResponder(self)
        onInputChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let point = global(event)
        if hypot(point.x - origin.x, point.y - origin.y) >= 5 { draggingBall = true }
        if draggingBall, field.held != nil { cursor = point }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let point = global(event)
        if draggingBall || hypot(point.x - origin.x, point.y - origin.y) >= 5 {
            _ = field.finishBall(at: point)
        } else {
            field.cancelBall()
            if let (ledgeID, _) = field.pickup(at: origin), ledgeID != -1 {
                field.sweep(from: origin, to: CGPoint(x: origin.x - 9, y: origin.y))
                field.sweep(from: origin, to: CGPoint(x: origin.x + 9, y: origin.y))
            }
        }
        draggingBall = false
        pressOrigin = nil
        cursor = nil
        onInputChanged?()
        needsDisplay = true
    }

    func cancelGesture() {
        field.cancelBall()
        draggingBall = false
        pressOrigin = nil
        cursor = nil
        window?.ignoresMouseEvents = true
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelGesture()
        } else {
            super.keyDown(with: event)
        }
    }

    private func global(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x + field.bounds.minX, y: point.y + field.bounds.minY)
    }

    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - field.bounds.minX, y: point.y - field.bounds.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.clear(dirtyRect)
        // Batch flakes with similar opacity into one fill per group.
        let alphaLevels: [CGFloat] = [0.52, 0.65, 0.78, 0.90, 0.96]
        let paths = alphaLevels.map { _ in CGMutablePath() }
        for flake in field.flakes {
            let point = local(flake.position)
            let radius = flake.radius * particleScale
            let alpha = flake.detached ? 0.78 : min(0.96, 0.36 + radius * 0.22)
            let group = min(paths.count - 1, max(0, Int(((alpha - 0.52) / 0.12).rounded())))
            paths[group].addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2))
        }
        for (index, path) in paths.enumerated() where !path.isEmpty {
            cg.setFillColor(flakeColor.withAlphaComponent(alphaLevels[index] * particleOpacity).cgColor)
            cg.addPath(path)
            cg.fillPath()
        }

        for id in field.collisionOrder.reversed() {
            if let drift = field.drifts[id] { drawDrift(drift, in: cg) }
        }
        for ledge in garlandLedges.reversed() {
            drawGarland(on: ledge, in: cg)
        }

        for (index, ball) in field.balls.enumerated() where ball.radius > 0 {
            guard let ledge = field.drifts[ball.ledge]?.ledge,
                  let center = field.ballCenter(index, on: ledge), ledge.isVisible(center.x) else { continue }
            let hasUpperBall = field.balls.contains { $0.radius > 0 && $0.below == index }
            let isHead = ball.below != nil && !hasUpperBall
            cg.saveGState()
            clipCoveredAreas(of: ledge, in: cg)
            drawBall(at: local(center), radius: ball.radius, head: isHead, body: hasUpperBall, in: cg)
            cg.restoreGState()
        }
        if let plow = field.plow, let ledge = field.drifts[plow.ledgeID]?.ledge {
            drawPlow(plow, on: ledge, in: cg)
        }
        if let helicopter = field.helicopter { drawHelicopter(helicopter, in: cg) }
        if let radius = field.held, let cursor {
            if let target = field.placement(at: cursor) {
                let center = local(target.center)
                cg.saveGState()
                cg.setAlpha(0.64)
                drawBall(at: center, radius: target.radius, head: target.below != nil, in: cg)
                cg.setAlpha(0.95)
                cg.setStrokeColor(NSColor.white.cgColor)
                cg.setLineWidth(1)
                cg.setLineDash(phase: 0, lengths: [3, 3])
                let r = target.radius + 2.5
                cg.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                cg.restoreGState()
            } else {
                drawBall(at: local(cursor), radius: radius, head: false, in: cg)
            }
        }
    }

    private func drawDrift(_ drift: Snowfield.Drift, in cg: CGContext) {
        let ledge = drift.ledge
        let origin = local(CGPoint(x: ledge.frame.minX, y: ledge.top))
        let base = origin.y - (ledge.id > 0 ? 0.8 : 0)
        let path = CGMutablePath()
        for slice in ledge.visible {
            let start = max(0, Int(floor((slice.lowerBound - ledge.frame.minX) / Snowfield.column)))
            let end = min(drift.heights.count, Int(ceil((slice.upperBound - ledge.frame.minX) / Snowfield.column)))
            guard start < end else { continue }
            var i = start
            while i < end {
                while i < end && drift.heights[i] <= 0.12 { i += 1 }
                guard i < end else { break }
                let first = i
                while i < end && drift.heights[i] > 0.12 { i += 1 }
                let firstX = max(slice.lowerBound - field.bounds.minX, origin.x + CGFloat(first) * Snowfield.column)
                let endX = min(slice.upperBound - field.bounds.minX, origin.x + CGFloat(i) * Snowfield.column)
                path.move(to: CGPoint(x: firstX, y: base))
                var last = CGPoint(x: firstX, y: base)
                for j in first..<i {
                    let x = min(endX, max(firstX, origin.x + (CGFloat(j) + 0.5) * Snowfield.column))
                    let next = CGPoint(x: x, y: origin.y + drift.heights[j])
                    let midpoint = CGPoint(x: (last.x + next.x) * 0.5, y: (last.y + next.y) * 0.5)
                    path.addQuadCurve(to: midpoint, control: last)
                    last = next
                }
                path.addQuadCurve(to: CGPoint(x: endX, y: base), control: last)
                path.closeSubpath()
            }
        }
        guard !path.isEmpty else { return }
        cg.saveGState()
        clipCoveredAreas(of: ledge, in: cg)
        cg.addPath(path)
        cg.setFillColor(snowColor.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    private let vehicleInk = CGColor(red: 0.08, green: 0.14, blue: 0.21, alpha: 1)
    private let vehicleAmber = CGColor(red: 1, green: 0.57, blue: 0.17, alpha: 1)
    private let vehicleLight = CGColor(red: 1, green: 0.84, blue: 0.49, alpha: 1)
    private let vehicleGlass = CGColor(red: 0.54, green: 0.82, blue: 0.91, alpha: 1)

    private func vehicleShape(_ points: [CGPoint], color: CGColor, in cg: CGContext) {
        guard let first = points.first else { return }
        cg.beginPath()
        cg.move(to: first)
        cg.addLines(between: points)
        cg.closePath()
        cg.setFillColor(color)
        cg.fillPath()
    }

    private func drawPlow(_ plow: Snowfield.Plow, on ledge: Ledge, in cg: CGContext) {
        let position = local(CGPoint(x: ledge.frame.minX + plow.x, y: ledge.top))
        cg.saveGState()
        clipCoveredAreas(of: ledge, in: cg)
        cg.translateBy(x: position.x, y: position.y + 0.5)
        cg.scaleBy(x: plow.direction, y: 1)
        cg.setFillColor(vehicleInk)
        cg.fillEllipse(in: CGRect(x: -16, y: -1, width: 31, height: 3))
        vehicleShape([.init(x: -14, y: 4), .init(x: 11, y: 4), .init(x: 13, y: 11),
                      .init(x: 5, y: 13), .init(x: 2, y: 22), .init(x: -9, y: 22),
                      .init(x: -11, y: 13), .init(x: -14, y: 12)], color: vehicleInk, in: cg)
        vehicleShape([.init(x: -13, y: 7), .init(x: 10, y: 7), .init(x: 11, y: 11),
                      .init(x: 4, y: 12), .init(x: 1, y: 21), .init(x: -8, y: 21),
                      .init(x: -10, y: 12), .init(x: -13, y: 11)], color: vehicleAmber, in: cg)
        vehicleShape([.init(x: -8, y: 14), .init(x: 2, y: 14), .init(x: 0, y: 20),
                      .init(x: -7, y: 20)], color: vehicleGlass, in: cg)
        cg.setFillColor(vehicleInk)
        cg.fill(CGRect(x: -4, y: 14, width: 0.9, height: 6))
        cg.fill(CGRect(x: -11, y: 8, width: 7, height: 1))
        cg.setFillColor(vehicleLight)
        cg.fill(CGRect(x: -13, y: 10, width: 25, height: 1.1))
        cg.fill(CGRect(x: -4, y: 22, width: 3, height: 2))
        cg.fill(CGRect(x: 10, y: 11, width: 2, height: 2))
        for wheel: CGFloat in [-9, 7] {
            cg.setFillColor(vehicleInk)
            cg.fillEllipse(in: CGRect(x: wheel - 4.3, y: 0, width: 8.6, height: 8.6))
            cg.setFillColor(CGColor(gray: 0.58, alpha: 1))
            cg.fillEllipse(in: CGRect(x: wheel - 2.15, y: 2.15, width: 4.3, height: 4.3))
            let angle = plow.x / 4
            cg.setFillColor(vehicleInk)
            cg.fillEllipse(in: CGRect(x: wheel + cos(angle) * 1.2 - 0.55,
                                      y: 4.3 + sin(angle) * 1.2 - 0.55, width: 1.1, height: 1.1))
        }
        vehicleShape([.init(x: 10, y: 3), .init(x: 13, y: 11), .init(x: 17, y: 9),
                      .init(x: 16, y: 4), .init(x: 20, y: 1), .init(x: 13, y: 0)],
                     color: vehicleInk, in: cg)
        vehicleShape([.init(x: 12, y: 3), .init(x: 14, y: 10), .init(x: 16, y: 9),
                      .init(x: 15, y: 4), .init(x: 18, y: 2), .init(x: 13, y: 1)],
                     color: vehicleGlass, in: cg)
        cg.restoreGState()
    }

    private func drawHelicopter(_ aircraft: Snowfield.Helicopter, in cg: CGContext) {
        let center = local(CGPoint(x: aircraft.x, y: aircraft.y))
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y + sin(field.time * 4) * 1.3)
        cg.scaleBy(x: aircraft.direction, y: 1)

        vehicleShape([.init(x: -13, y: 0), .init(x: -30, y: 5), .init(x: -33, y: 15),
                      .init(x: -27, y: 14), .init(x: -25, y: 9), .init(x: -11, y: 7)],
                     color: vehicleInk, in: cg)
        vehicleShape([.init(x: -13, y: 2), .init(x: -29, y: 6), .init(x: -31, y: 13),
                      .init(x: -28, y: 13), .init(x: -26, y: 8), .init(x: -11, y: 6)],
                     color: vehicleAmber, in: cg)

        let cabin = CGRect(x: -17, y: -7, width: 36, height: 22)
        cg.setFillColor(vehicleInk)
        cg.fillEllipse(in: cabin)
        cg.setFillColor(vehicleAmber)
        cg.fillEllipse(in: cabin.insetBy(dx: 1.2, dy: 1.2))
        vehicleShape([.init(x: 4, y: 13), .init(x: 11, y: 11), .init(x: 16, y: 6),
                      .init(x: 17, y: 2), .init(x: 6, y: 2)], color: vehicleGlass, in: cg)
        vehicleShape([.init(x: -8, y: 11), .init(x: 1, y: 12), .init(x: 3, y: 2),
                      .init(x: -8, y: 2)], color: vehicleGlass, in: cg)
        cg.setFillColor(vehicleLight)
        cg.fill(CGRect(x: -13, y: -2, width: 27, height: 1.6))

        cg.setStrokeColor(vehicleInk)
        cg.setLineWidth(1.9)
        cg.setLineCap(.round)
        cg.move(to: .init(x: -8, y: -5))
        cg.addLine(to: .init(x: -10, y: -12))
        cg.move(to: .init(x: 10, y: -5))
        cg.addLine(to: .init(x: 8, y: -12))
        cg.move(to: .init(x: -15, y: -12))
        cg.addLine(to: .init(x: 16, y: -12))
        cg.addLine(to: .init(x: 19, y: -9))
        cg.move(to: .init(x: -1, y: 13))
        cg.addLine(to: .init(x: -1, y: 21))
        cg.strokePath()

        let rotor = 18 + 15 * abs(cos(field.time * 37))
        cg.setFillColor(CGColor(red: 0.64, green: 0.80, blue: 0.86, alpha: 0.27))
        cg.fillEllipse(in: CGRect(x: -34, y: 19, width: 66, height: 5))
        cg.setStrokeColor(vehicleInk)
        cg.move(to: .init(x: -rotor - 1, y: 21))
        cg.addLine(to: .init(x: rotor - 1, y: 21))
        let tailAngle = field.time * 28
        let tail = CGPoint(x: cos(tailAngle) * 4, y: sin(tailAngle) * 4)
        cg.move(to: .init(x: -29 - tail.x, y: 9 - tail.y))
        cg.addLine(to: .init(x: -29 + tail.x, y: 9 + tail.y))
        cg.strokePath()
        cg.restoreGState()
    }

    private lazy var bulbGlows = bulbColors.map { color in
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: [color.copy(alpha: 0.42) ?? color,
                            color.copy(alpha: 0) ?? color] as CFArray, locations: [0, 1])
    }

    private func drawGarland(on ledge: Ledge, in cg: CGContext) {
        let widget = ledge.decorative
        let inset: CGFloat = widget ? 24 : 18
        let width = ledge.frame.width - inset * 2
        guard width >= 54 else { return }
        let origin = local(CGPoint(x: ledge.frame.minX + inset, y: ledge.top - (widget ? 5 : 3)))
        let loops = max(1, Int((width / (widget ? 105 : 135)).rounded()))
        let span = width / CGFloat(loops)
        let sag = min(widget ? 7 : 12, span * 0.11)
        let wire = CGMutablePath()
        cg.saveGState()
        clipCoveredAreas(of: ledge, in: cg)

        for loop in 0..<loops {
            let x = origin.x + CGFloat(loop) * span
            wire.move(to: CGPoint(x: x, y: origin.y))
            wire.addQuadCurve(to: CGPoint(x: x + span, y: origin.y),
                              control: CGPoint(x: x + span / 2, y: origin.y - sag * 2))
        }
        cg.setLineCap(.round)
        cg.setStrokeColor(CGColor(red: 0.05, green: 0.12, blue: 0.12, alpha: 0.94))
        cg.setLineWidth(2.1)
        cg.addPath(wire)
        cg.strokePath()
        cg.setStrokeColor(CGColor(red: 0.41, green: 0.57, blue: 0.49, alpha: 0.7))
        cg.setLineWidth(0.65)
        cg.addPath(wire)
        cg.strokePath()

        cg.setFillColor(CGColor(red: 0.57, green: 0.66, blue: 0.61, alpha: 1))
        for anchor in 0...loops {
            let x = origin.x + CGFloat(anchor) * span
            cg.fillEllipse(in: CGRect(x: x - 1.75, y: origin.y - 1.3, width: 3.5, height: 2.6))
        }

        let bulbsPerLoop = max(2, min(6, Int(span / 22)))
        for loop in 0..<loops {
            for bulb in 0..<bulbsPerLoop {
                let index = loop * bulbsPerLoop + bulb
                let progress = (CGFloat(bulb) + 0.5) / CGFloat(bulbsPerLoop)
                let x = origin.x + span * (CGFloat(loop) + progress)
                guard x >= -12 && x <= bounds.width + 12 else { continue }
                let y = origin.y - 4 * sag * progress * (1 - progress)
                let slope = 4 * sag * (2 * progress - 1) / span
                cg.saveGState()
                cg.translateBy(x: x, y: y)
                cg.rotate(by: atan(slope) * 0.45)
                let center = CGPoint(x: 0, y: -5.3)
                let colorIndex = index % bulbColors.count
                let color = bulbColors[colorIndex]
                let power = animateGarlands ? 0.86 + 0.14 * sin(field.time * 0.95 + CGFloat(index) * 0.63) : 0.93

                if let glow = bulbGlows[colorIndex] {
                    cg.saveGState()
                    cg.setAlpha(power)
                    cg.clip(to: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
                    cg.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                                          endCenter: center, endRadius: 10, options: [])
                    cg.restoreGState()
                }
                cg.setFillColor(CGColor(red: 0.11, green: 0.21, blue: 0.18, alpha: 1))
                cg.fill(CGRect(x: -1.6, y: -3.4, width: 3.2, height: 3.6))
                cg.setFillColor(color.copy(alpha: power) ?? color)
                cg.fillEllipse(in: CGRect(x: -2.15, y: -8.8, width: 4.3, height: 6.1))
                cg.setFillColor(CGColor(gray: 1, alpha: 0.8 * power))
                cg.fillEllipse(in: CGRect(x: -1.05, y: -6.4, width: 1.45, height: 2.5))
                cg.restoreGState()
            }
        }
        cg.restoreGState()
    }

    private func clipCoveredAreas(of ledge: Ledge, in cg: CGContext) {
        for blocker in ledge.occluders {
            let covered = blocker.offsetBy(dx: -field.bounds.minX, dy: -field.bounds.minY).intersection(bounds)
            guard !covered.isNull && !covered.isEmpty else { continue }
            cg.beginPath()
            cg.addRect(bounds)
            cg.addRect(covered)
            cg.clip(using: .evenOdd)
        }
    }

    private func drawBall(at center: CGPoint, radius: CGFloat, head: Bool, body: Bool = false, in cg: CGContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        cg.setFillColor(snowShadow.cgColor)
        cg.fillEllipse(in: rect)
        cg.setFillColor(snowColor.cgColor)
        cg.fillEllipse(in: rect.insetBy(dx: radius * 0.08, dy: radius * 0.08).offsetBy(dx: -0.45, dy: 0.75))
        if body {
            let size = max(0.8, radius * 0.13)
            cg.setFillColor(ink.cgColor)
            for offset: CGFloat in [-0.28, 0.12, 0.46] {
                cg.fillEllipse(in: CGRect(x: center.x - size, y: center.y + radius * offset - size,
                                          width: size * 2, height: size * 2))
            }
        }
        guard head else { return }
        cg.setFillColor(CGColor(red: 0.78, green: 0.18, blue: 0.27, alpha: 1))
        cg.fill(CGRect(x: center.x - radius * 0.73, y: center.y - radius * 0.85,
                       width: radius * 1.46, height: radius * 0.28))
        cg.fill(CGRect(x: center.x + radius * 0.36, y: center.y - radius * 1.16,
                       width: radius * 0.27, height: radius * 0.49))
        cg.setFillColor(ink.cgColor)
        cg.fill(CGRect(x: center.x - radius * 0.79, y: center.y + radius * 0.68,
                       width: radius * 1.58, height: radius * 0.24))
        cg.fill(CGRect(x: center.x - radius * 0.47, y: center.y + radius * 0.9,
                       width: radius * 0.94, height: radius * 0.49))
        for direction: CGFloat in [-1, 1] {
            cg.fillEllipse(in: CGRect(x: center.x + direction * radius * 0.26 - 1,
                                      y: center.y + radius * 0.14, width: 2, height: 2))
        }
        cg.setFillColor(NSColor.systemOrange.cgColor)
        let carrot = CGMutablePath()
        carrot.move(to: CGPoint(x: center.x - 1, y: center.y))
        carrot.addLine(to: CGPoint(x: center.x + radius * 0.55, y: center.y - radius * 0.13))
        carrot.addLine(to: CGPoint(x: center.x - 1, y: center.y - 2))
        carrot.closeSubpath()
        cg.addPath(carrot)
        cg.fillPath()
    }
}
