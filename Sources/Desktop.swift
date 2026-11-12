import AppKit
import CoreGraphics

struct DesktopWindow {
    let id: Int
    let frame: CGRect
    let layer: Int
    let dock: Bool
}

struct DesktopScene {
    var windows: [DesktopWindow]

    static func snapshot(primaryTop: CGFloat, includeOwn: Bool = false) -> DesktopScene {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first.map { Int($0.processIdentifier) }
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
            guard layer == 0 || dock else { return nil }
            let frame = CGRect(x: rect.minX, y: primaryTop - rect.maxY,
                               width: rect.width, height: rect.height)
            return DesktopWindow(id: id, frame: frame, layer: layer, dock: dock)
        }
        return DesktopScene(windows: windows)
    }

    func isFullscreen(on screen: NSScreen, fullscreenPresentation: Bool) -> Bool {
        windows.contains { window in
            window.layer == 0 && !window.dock &&
                DisplayCoverage.isFullscreen(window: window.frame, screen: screen.frame,
                                             topInset: screen.safeAreaInsets.top,
                                             fullscreenPresentation: fullscreenPresentation)
        }
    }

    func ledges(in frame: CGRect) -> [Ledge] {
        let normals = windows.filter { $0.layer == 0 && !$0.dock }
        var ledges: [Ledge] = []
        if let dock = windows.first(where: {
            $0.dock && $0.frame.intersects(frame) && abs($0.frame.minY - frame.minY) <= 42
        }), let ledge = makeLedge(id: -2, rect: dock.frame, on: frame, coveredBy: []) {
            ledges.append(ledge)
        }
        var blockers: [CGRect] = []
        for window in normals.prefix(100) where window.frame.intersects(frame) {
            if ledges.count < 55, let ledge = makeLedge(id: window.id, rect: window.frame,
                                                       on: frame, coveredBy: blockers) {
                ledges.append(ledge)
            }
            blockers.append(window.frame)
        }
        let bottom = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1)
        if let ledge = makeLedge(id: -1, rect: bottom, on: frame, coveredBy: blockers) {
            ledges.append(ledge)
        }
        return ledges
    }

    private func makeLedge(id: Int, rect: CGRect, on screen: CGRect, coveredBy: [CGRect]) -> Ledge? {
        let left = max(screen.minX, rect.minX)
        let right = min(screen.maxX, rect.maxX)
        guard right - left >= 2, rect.maxY >= screen.minY, rect.maxY <= screen.maxY - 2 else {
            return nil
        }
        let corner = id > 0 ? min(8, rect.width * 0.06) : 0
        let innerLeft = max(left, rect.minX + corner)
        let innerRight = min(right, rect.maxX - corner)
        guard innerRight - innerLeft >= 2 else { return nil }
        var visible = [innerLeft...innerRight]
        let band = CGRect(x: left - 14, y: rect.maxY - 1, width: right - left + 28, height: 88)
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
        return Ledge(id: id, frame: rect, visible: visible, occluders: occluders)
    }
}

final class SnowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SnowView: NSView {
    var field: Snowfield
    var cursor: CGPoint?
    var onCancel: (() -> Void)?
    var onInputChanged: (() -> Void)?
    var snowColor = NSColor(srgbRed: 0.88, green: 0.94, blue: 1, alpha: 0.96)
    var particleScale: CGFloat = 1
    var particleOpacity: CGFloat = 0.92
    var flakeColor = NSColor.white
    private let snowShadow = NSColor(srgbRed: 0.46, green: 0.62, blue: 0.76, alpha: 0.86)
    private let ink = NSColor(srgbRed: 0.16, green: 0.25, blue: 0.33, alpha: 0.95)

    init(screen: CGRect) {
        field = Snowfield(bounds: screen, seed: UInt64(abs(screen.minX.rounded())) + 23)
        super.init(frame: CGRect(origin: .zero, size: screen.size))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = global(event)
        guard field.beginBall(at: point) else { return }
        cursor = point
        window?.makeFirstResponder(self)
        onInputChanged?()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursor = global(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        _ = field.finishBall(at: global(event))
        cursor = nil
        onInputChanged?()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
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
        for flake in field.flakes {
            let point = local(flake.position)
            let radius = flake.radius * particleScale
            let alpha = flake.detached ? 0.78 : min(0.96, 0.36 + radius * 0.22)
            cg.setFillColor(flakeColor.withAlphaComponent(alpha * particleOpacity).cgColor)
            cg.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                      width: radius * 2, height: radius * 2))
        }

        for drift in field.drifts.values.sorted(by: { $0.ledge.top < $1.ledge.top }) {
            drawDrift(drift, in: cg)
        }

        for (index, ball) in field.balls.enumerated() where ball.radius > 0 {
            guard let ledge = field.drifts[ball.ledge]?.ledge,
                  let center = field.ballCenter(index, on: ledge), ledge.isVisible(center.x) else { continue }
            let isHead = ball.below != nil && !field.balls.contains { $0.radius > 0 && $0.below == index }
            cg.saveGState()
            clipCoveredAreas(of: ledge, in: cg)
            drawBall(at: local(center), radius: ball.radius, head: isHead, in: cg)
            cg.restoreGState()
        }
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

    private func drawBall(at center: CGPoint, radius: CGFloat, head: Bool, in cg: CGContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        cg.setFillColor(snowShadow.cgColor)
        cg.fillEllipse(in: rect)
        cg.setFillColor(snowColor.cgColor)
        cg.fillEllipse(in: rect.insetBy(dx: radius * 0.08, dy: radius * 0.08).offsetBy(dx: -0.45, dy: 0.75))
        guard head else { return }
        cg.setFillColor(ink.cgColor)
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
