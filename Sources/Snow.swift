import Foundation
import CoreGraphics

struct Ledge: Equatable {
    let id: Int
    let frame: CGRect
    var visible: [ClosedRange<CGFloat>]

    var top: CGFloat { frame.maxY }
    func isVisible(_ x: CGFloat) -> Bool { visible.contains { $0.contains(x) } }
}

enum SnowTool: Int { case glove, shovel }

struct Snowfield {
    struct Flake {
        var position: CGPoint
        var speed: CGFloat
        var radius: CGFloat
        var phase: CGFloat
        var detached = false
    }

    struct Drift {
        var ledge: Ledge
        var heights: [CGFloat]
    }

    struct Ball {
        var x: CGFloat
        var radius: CGFloat
        var ledge: Int
        var below: Int?
    }

    static let column: CGFloat = 5
    let bounds: CGRect
    private(set) var drifts: [Int: Drift] = [:]
    private(set) var flakes: [Flake] = []
    private(set) var balls: [Ball] = []
    private(set) var held: CGFloat?
    private var take: (id: Int, column: Int, amount: CGFloat)?
    private var random: UInt64
    private var emission: CGFloat = 0
    private var time: CGFloat = 0

    init(bounds: CGRect, seed: UInt64 = 23) {
        self.bounds = bounds
        random = max(seed, 1)
    }

    private mutating func unit() -> CGFloat {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return CGFloat(random & 0xFFFF) / 65535
    }

    mutating func updateLedges(_ ledges: [Ledge]) {
        let incoming = Set(ledges.map(\.id))
        for id in drifts.keys.sorted() where !incoming.contains(id) {
            guard let drift = drifts.removeValue(forKey: id) else { continue }
            for (i, height) in drift.heights.enumerated() where i.isMultiple(of: 3) && height > 0.4 {
                let x = drift.ledge.frame.minX + CGFloat(i) * Self.column
                shed(x: x, y: drift.ledge.top - 1, amount: height)
            }
            for index in balls.indices where balls[index].ledge == id {
                if let center = ballCenter(index, on: drift.ledge) {
                    shed(x: center.x, y: drift.ledge.top - 1, amount: balls[index].radius)
                }
            }
            // Keep indices stable for stacks attached to other windows.
            for index in balls.indices where balls[index].ledge == id {
                balls[index].radius = 0
            }
            if take?.id == id { cancelBall() }
        }

        for ledge in ledges {
            let size = max(1, Int(ceil(ledge.frame.width / Self.column)))
            var heights = drifts[ledge.id]?.heights ?? []
            if heights.count < size {
                heights += Array(repeating: 0, count: size - heights.count)
            } else if heights.count > size {
                heights.removeLast(heights.count - size)
            }
            drifts[ledge.id] = Drift(ledge: ledge, heights: heights)
        }
    }

    private mutating func shed(x: CGFloat, y: CGFloat, amount: CGFloat) {
        guard flakes.count < 850, x >= bounds.minX, x <= bounds.maxX else { return }
        let speed = 70 + unit() * 55
        let phase = unit() * 7
        flakes.append(Flake(position: CGPoint(x: x, y: y), speed: speed,
                            radius: min(4, 1 + amount * 0.28), phase: phase, detached: true))
    }

    mutating func step(_ dt: CGFloat, rate: CGFloat, wind: CGVector) {
        let dt = min(max(dt, 0), 1.0 / 15)
        time += dt
        emission += rate * dt
        while emission >= 1 {
            emission -= 1
            guard flakes.count < 700 else { continue }
            let x = bounds.minX + unit() * bounds.width
            let speed = 30 + unit() * 88
            let radius = 0.75 + unit() * 2
            let phase = unit() * 7
            flakes.append(Flake(position: CGPoint(x: x, y: bounds.maxY + 3),
                                speed: speed, radius: radius, phase: phase))
        }

        let ledges: [Ledge] = drifts.values.map { $0.ledge }
        let orderedLedges = ledges.sorted { first, second in
            if first.top == second.top { return first.id < second.id }
            return first.top > second.top
        }
        var remaining: [Flake] = []
        remaining.reserveCapacity(flakes.count)

        for var flake in flakes {
            let oldY = flake.position.y
            flake.position.x += (wind.dx + sin(time * 1.7 + flake.phase) * 13) * dt
            flake.position.y -= max(14, flake.speed - wind.dy) * dt
            if flake.position.x < bounds.minX { flake.position.x += bounds.width }
            if flake.position.x > bounds.maxX { flake.position.x -= bounds.width }

            if let ledge = orderedLedges.first(where: {
                oldY >= $0.top && flake.position.y <= $0.top && $0.isVisible(flake.position.x)
            }) {
                deposit(on: ledge, at: flake.position.x, radius: flake.radius)
            } else if flake.position.y >= bounds.minY - 6 {
                remaining.append(flake)
            }
        }
        flakes = remaining
    }

    private mutating func deposit(on ledge: Ledge, at x: CGFloat, radius: CGFloat) {
        guard var drift = drifts[ledge.id] else { return }
        let i = Int((x - ledge.frame.minX) / Self.column)
        let ceiling: CGFloat = ledge.id < 0 ? 23 : 15
        for offset in -2...2 where drift.heights.indices.contains(i + offset) {
            let n = i + offset
            let amount = (0.6 + 0.28 * radius) / CGFloat(1 + abs(offset))
            drift.heights[n] = min(ceiling, drift.heights[n] + amount)
        }
        drifts[ledge.id] = drift
    }

    mutating func sweep(from: CGPoint, to: CGPoint, tool: SnowTool) {
        let travel = hypot(to.x - from.x, to.y - from.y)
        guard travel > 0.5, travel < 240 else { return }
        let reach: CGFloat = tool == .glove ? 12 : 20
        for id in drifts.keys.sorted() {
            guard var drift = drifts[id],
                  min(from.y, to.y) <= drift.ledge.top + 26,
                  max(from.y, to.y) >= drift.ledge.top - reach else { continue }
            let low = max(0, Int(floor((min(from.x, to.x) - reach - drift.ledge.frame.minX) / Self.column)))
            let high = min(drift.heights.count - 1, Int(ceil((max(from.x, to.x) + reach - drift.ledge.frame.minX) / Self.column)))
            guard low <= high else { continue }
            for i in low...high where drift.heights[i] > 0.1 {
                let x = drift.ledge.frame.minX + (CGFloat(i) + 0.5) * Self.column
                guard drift.ledge.isVisible(x) else { continue }
                let y = drift.ledge.top + drift.heights[i] * 0.5
                let t = min(1, max(0, ((x - from.x) * (to.x - from.x) +
                    (y - from.y) * (to.y - from.y)) / (travel * travel)))
                let distance = hypot(x - (from.x + t * (to.x - from.x)), y - (from.y + t * (to.y - from.y)))
                guard distance < reach else { continue }
                let removed = tool == .shovel ? drift.heights[i] :
                    min(drift.heights[i], (1 - distance / reach) * min(4, travel * 0.38))
                drift.heights[i] -= removed
                if tool == .glove && removed > 0.5 {
                    shed(x: x + (to.x >= from.x ? 11 : -11), y: drift.ledge.top - 1, amount: removed)
                }
            }
            drifts[id] = drift
        }
    }

    func pickup(at point: CGPoint) -> (Int, Int)? {
        for id in drifts.keys.sorted() {
            guard let drift = drifts[id], drift.ledge.isVisible(point.x),
                  (drift.ledge.top - 4...drift.ledge.top + 25).contains(point.y) else { continue }
            let index = Int((point.x - drift.ledge.frame.minX) / Self.column)
            if drift.heights.indices.contains(index), drift.heights[index] >= 1.5 {
                return (id, index)
            }
        }
        return nil
    }

    mutating func beginBall(at point: CGPoint) -> Bool {
        guard held == nil, let (id, index) = pickup(at: point),
              var drift = drifts[id] else { return false }
        let amount = min(drift.heights[index], 7)
        drift.heights[index] -= amount
        drifts[id] = drift
        take = (id, index, amount)
        held = 6 + amount
        return true
    }

    mutating func finishBall(at point: CGPoint) -> Bool {
        guard let radius = held else { return false }
        if balls.count >= 96 { compactBalls() }
        guard balls.count < 96 else { cancelBall(); return false }
        for index in balls.indices.reversed() {
            let ball = balls[index]
            guard ball.radius > 0, let ledge = drifts[ball.ledge]?.ledge,
                  let center = ballCenter(index, on: ledge), ledge.isVisible(center.x),
                  radius <= ball.radius + 2,
                  !balls.contains(where: { $0.radius > 0 && $0.below == index }),
                  abs(point.x - center.x) <= ball.radius + 9,
                  abs(point.y - center.y - ball.radius) <= radius + 18 else { continue }
            balls.append(Ball(x: ball.x, radius: radius, ledge: ball.ledge, below: index))
            held = nil
            take = nil
            return true
        }

        let targets = drifts.values.filter {
            $0.ledge.isVisible(point.x) && abs(point.y - $0.ledge.top) < 34
        }.sorted {
            let first = abs(point.y - $0.ledge.top)
            let second = abs(point.y - $1.ledge.top)
            return first == second ? $0.ledge.id < $1.ledge.id : first < second
        }
        if let target = targets.first {
            balls.append(Ball(x: point.x - target.ledge.frame.minX, radius: radius,
                              ledge: target.ledge.id, below: nil))
            held = nil
            take = nil
            return true
        }
        cancelBall()
        return false
    }

    private mutating func compactBalls() {
        var indices: [Int: Int] = [:]
        var active: [Ball] = []
        for (old, ball) in balls.enumerated() where ball.radius > 0 {
            indices[old] = active.count
            var updated = ball
            updated.below = ball.below.flatMap { indices[$0] }
            active.append(updated)
        }
        balls = active
    }

    mutating func cancelBall() {
        if let take, var drift = drifts[take.id], drift.heights.indices.contains(take.column) {
            drift.heights[take.column] += take.amount
            drifts[take.id] = drift
        }
        take = nil
        held = nil
    }

    func ballCenter(_ index: Int, on ledge: Ledge) -> CGPoint? {
        let ball = balls[index]
        guard ball.radius > 0 else { return nil }
        let x = ledge.frame.minX + ball.x
        guard x <= ledge.frame.maxX else { return nil }
        var y = ledge.top + ball.radius
        var below = ball.below
        while let i = below {
            guard balls[i].radius > 0 else { return nil }
            y += balls[i].radius * 2 - 1
            below = balls[i].below
        }
        return CGPoint(x: x, y: y)
    }

    mutating func clear() {
        held = nil
        take = nil
        balls.removeAll()
        flakes.removeAll()
        for id in Array(drifts.keys) {
            if let count = drifts[id]?.heights.count {
                drifts[id]?.heights = Array(repeating: 0, count: count)
            }
        }
    }
}

enum DisplayCoverage {
    static func isFullscreen(window: CGRect, screen: CGRect,
                             topInset: CGFloat, fullscreenPresentation: Bool) -> Bool {
        let edgeTolerance: CGFloat = 5
        guard screen.width > 0, screen.height > 0,
              abs(window.minX - screen.minX) <= edgeTolerance,
              abs(window.maxX - screen.maxX) <= edgeTolerance,
              abs(window.minY - screen.minY) <= edgeTolerance else { return false }
        // Native fullscreen windows can stop below the camera housing or the menu bar.
        let topTolerance = fullscreenPresentation
            ? max(44, topInset + edgeTolerance)
            : max(edgeTolerance, topInset + edgeTolerance)
        return abs(window.maxY - screen.maxY) <= topTolerance
            && window.height >= screen.height * 0.9
    }
}
