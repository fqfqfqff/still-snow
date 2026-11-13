import Foundation
import CoreGraphics

struct Ledge: Equatable {
    let id: Int
    let frame: CGRect
    var visible: [ClosedRange<CGFloat>]
    var occluders: [CGRect] = []

    var top: CGFloat { frame.maxY }
    func isVisible(_ x: CGFloat) -> Bool { visible.contains { $0.contains(x) } }
}

struct Snowfield {
    struct Flake {
        var position: CGPoint
        var speed: CGFloat
        var radius: CGFloat
        var phase: CGFloat
        var snowAmount: CGFloat = 0
        var lateralSpeed: CGFloat = 0
        var detached: Bool { snowAmount > 0 }
    }

    struct Drift {
        var ledge: Ledge
        var heights: [CGFloat]

        func height(at x: CGFloat) -> CGFloat {
            guard !heights.isEmpty else { return 0 }
            let index = max(0, min(CGFloat(heights.count - 1), (x - ledge.frame.minX) / Snowfield.column - 0.5))
            let left = Int(index)
            let right = min(heights.count - 1, left + 1)
            let fraction = index - CGFloat(left)
            return heights[left] * (1 - fraction) + heights[right] * fraction
        }
    }

    struct Plow {
        static let halfWidth: CGFloat = 13
        let ledgeID: Int
        let direction: CGFloat
        var x: CGFloat
        let destination: CGFloat
    }

    struct Ball {
        var x: CGFloat
        var radius: CGFloat
        var ledge: Int
        var below: Int?
    }

    struct Placement {
        let ledge: Int
        let below: Int?
        let center: CGPoint
        let radius: CGFloat
    }

    static let column: CGFloat = 5
    static let maximumHeight: CGFloat = 24
    let bounds: CGRect
    private(set) var drifts: [Int: Drift] = [:]
    private(set) var flakes: [Flake] = []
    private var nextFlakes: [Flake] = []
    private(set) var plow: Plow?
    private var nextPlowTime: CGFloat = 19
    private(set) var balls: [Ball] = []
    private(set) var held: CGFloat?
    private var take: (id: Int, column: Int, amount: CGFloat)?
    private var random: UInt64
    private var emission: CGFloat = 0
    private(set) var time: CGFloat = 0
    private var settleAt: CGFloat = 0
    private(set) var collisionOrder: [Int] = []
    private var unsettled = Set<Int>()

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

    mutating func updateLedges(_ ledges: [Ledge], retainedWindowIDs: Set<Int> = []) {
        let incoming = Set(ledges.map(\.id))
        var geometryChanged = false
        for id in Array(drifts.keys) where !incoming.contains(id) {
            guard var drift = drifts[id] else { continue }
            if retainedWindowIDs.contains(id) {
                if !drift.ledge.visible.isEmpty {
                    drift.ledge.visible = []
                    drift.ledge.occluders = []
                    drifts[id] = drift
                    geometryChanged = true
                }
                continue
            }
            if take?.id == id {
                cancelBall()
                drift = drifts[id] ?? drift
            }
            drifts[id] = nil
            unsettled.remove(id)
            geometryChanged = true
            if !drift.ledge.visible.isEmpty {
                releaseSnow(from: drift, outside: nil)
            }
            for index in balls.indices where balls[index].ledge == id && balls[index].radius > 0 {
                if !drift.ledge.visible.isEmpty {
                    shed(x: drift.ledge.frame.minX + balls[index].x, y: drift.ledge.top,
                         amount: balls[index].radius * 2)
                }
                balls[index].radius = 0
            }
        }

        for ledge in ledges {
            guard let previous = drifts[ledge.id] else {
                let count = max(1, Int(ceil(ledge.frame.width / Self.column)))
                drifts[ledge.id] = Drift(ledge: ledge, heights: Array(repeating: 0, count: count))
                geometryChanged = true
                continue
            }
            if previous.ledge == ledge { continue }
            geometryChanged = true
            if abs(previous.ledge.frame.width - ledge.frame.width) > 0.01 {
                if take?.id == ledge.id { cancelBall() }
                resize(drift: drifts[ledge.id] ?? previous, to: ledge)
            } else {
                drifts[ledge.id]?.ledge = ledge
                if previous.ledge.visible.isEmpty && !ledge.visible.isEmpty {
                    unsettled.insert(ledge.id)
                }
            }
        }
        if geometryChanged {
            let visible: [Ledge] = drifts.values.compactMap { $0.ledge.visible.isEmpty ? nil : $0.ledge }
            collisionOrder = visible.sorted { first, second in
                if first.top == second.top { return first.id < second.id }
                return first.top > second.top
            }.map(\.id)
        }
    }

    private mutating func resize(drift: Drift, to ledge: Ledge) {
        let old = drift.ledge.frame
        let new = ledge.frame
        let count = max(1, Int(ceil(new.width / Self.column)))
        var heights = Array(repeating: CGFloat.zero, count: count)
        for (index, height) in drift.heights.enumerated() where height > 0 {
            let start = old.minX + CGFloat(index) * Self.column
            let end = min(old.maxX, start + Self.column)
            let left = max(start, new.minX)
            let right = min(end, new.maxX)
            guard left < right else { continue }
            let first = max(0, Int(floor((left - new.minX) / Self.column)))
            let last = min(count - 1, Int(ceil((right - new.minX) / Self.column)) - 1)
            guard first <= last else { continue }
            for i in first...last {
                let cellStart = new.minX + CGFloat(i) * Self.column
                let cellEnd = min(new.maxX, cellStart + Self.column)
                let width = min(cellEnd, right) - max(cellStart, left)
                heights[i] += height * max(0, width) / (cellEnd - cellStart)
            }
        }
        if !drift.ledge.visible.isEmpty {
            releaseSnow(from: drift, outside: new)
        }
        for index in balls.indices where balls[index].ledge == ledge.id && balls[index].radius > 0 {
            let x = old.minX + balls[index].x
            if x < new.minX || x > new.maxX {
                shed(x: x, y: drift.ledge.top, amount: balls[index].radius * 2)
                balls[index].radius = 0
            } else {
                balls[index].x = x - new.minX
            }
        }
        drifts[ledge.id] = Drift(ledge: ledge, heights: heights)
        unsettled.insert(ledge.id)
    }

    private mutating func releaseSnow(from drift: Drift, outside kept: CGRect?) {
        let old = drift.ledge.frame
        let ranges = kept.map { [old.minX..<max(old.minX, min(old.maxX, $0.minX)),
                                  min(old.maxX, max(old.minX, $0.maxX))..<old.maxX] } ?? [old.minX..<old.maxX]
        for range in ranges where !range.isEmpty {
            var released: [Int: (amount: CGFloat, weightedX: CGFloat)] = [:]
            let groupWidth = max(15, (range.upperBound - range.lowerBound) / 45)
            for (i, height) in drift.heights.enumerated() where height > 0 {
                let start = old.minX + CGFloat(i) * Self.column
                let left = max(start, range.lowerBound)
                let right = min(start + Self.column, range.upperBound)
                guard left < right else { continue }
                let x = (left + right) / 2
                let amount = height * (right - left) / Self.column
                let group = Int((x - range.lowerBound) / groupWidth)
                released[group, default: (0, 0)].amount += amount
                released[group, default: (0, 0)].weightedX += x * amount
            }
            for group in released.keys.sorted() {
                if let snow = released[group], snow.amount > 0 {
                    shed(x: snow.weightedX / snow.amount, y: drift.ledge.top - 1, amount: snow.amount)
                }
            }
        }
    }

    private mutating func shed(x: CGFloat, y: CGFloat, amount: CGFloat, sideways: CGFloat = 0) {
        guard amount > 0, bounds.width > 0 else { return }
        let x = min(bounds.maxX - 0.01, max(bounds.minX, x))
        if flakes.count >= 850 {
            if let ambient = flakes.lastIndex(where: { !$0.detached }) {
                flakes.swapAt(ambient, flakes.count - 1)
                flakes.removeLast()
            } else if let closest = flakes.indices.min(by: {
                abs(flakes[$0].position.x - x) < abs(flakes[$1].position.x - x)
            }) {
                flakes[closest].snowAmount += amount
                return
            }
        }
        let speed: CGFloat = sideways == 0 ? 26 + unit() * 22 : -(20 + unit() * 24)
        let phase = unit() * 7
        flakes.append(Flake(position: CGPoint(x: x, y: y), speed: speed,
                            radius: min(5, 1.1 + sqrt(amount) * 0.65), phase: phase,
                            snowAmount: amount, lateralSpeed: sideways))
    }

    mutating func step(_ dt: CGFloat, rate: CGFloat, wind: CGVector, plowsEnabled: Bool = false) {
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

        nextFlakes.removeAll(keepingCapacity: true)
        nextFlakes.reserveCapacity(flakes.count)

        for var flake in flakes {
            let previous = flake.position
            if flake.detached {
                flake.speed = min(185, flake.speed + 410 * dt)
                flake.lateralSpeed *= max(0, 1 - 2.4 * dt)
                flake.position.x = min(bounds.maxX - 0.01, max(bounds.minX,
                    previous.x + (flake.lateralSpeed + wind.dx * 0.45) * dt))
                flake.position.y -= flake.speed * dt
            } else {
                flake.position.x += (wind.dx + sin(time * 1.7 + flake.phase) * 13) * dt
                flake.position.y -= max(14, flake.speed - wind.dy) * dt
                if flake.position.x < bounds.minX { flake.position.x += bounds.width }
                if flake.position.x > bounds.maxX { flake.position.x -= bounds.width }
            }

            var landing: (ledge: Ledge, x: CGFloat, height: CGFloat)?
            let fall = previous.y - flake.position.y
            if fall > 0 {
                let wrapped = abs(flake.position.x - previous.x) > bounds.width / 2
                let startX = wrapped ? flake.position.x : previous.x
                let endX = flake.position.x
                let minX = min(startX, endX)
                let maxX = max(startX, endX)
                for id in collisionOrder {
                    guard let drift = drifts[id] else { continue }
                    let ledge = drift.ledge
                    if flake.position.y > ledge.top + Self.maximumHeight { break }
                    guard previous.y >= ledge.top else { continue }
                    guard ledge.visible.contains(where: {
                        $0.upperBound >= minX && $0.lowerBound <= maxX
                    }) else { continue }
                    let baseFraction = min(1, (previous.y - ledge.top) / fall)
                    let x2 = startX + (endX - startX) * baseFraction
                    let surface = min(previous.y, ledge.top + drift.height(at: x2))
                    guard flake.position.y <= surface, surface > (landing?.height ?? -.infinity) else { continue }
                    let x = startX + (endX - startX) * ((previous.y - surface) / fall)
                    if ledge.isVisible(x), !ledge.occluders.contains(where: {
                        $0.contains(CGPoint(x: x, y: surface))
                    }) { landing = (ledge, x, surface) }
                }
            }
            if let landing {
                if flake.detached {
                    flake.snowAmount = depositReleased(flake.snowAmount, on: landing.ledge, at: landing.x)
                    if flake.snowAmount > 0.01 && landing.ledge.id != -1 {
                        flake.position.y = min(flake.position.y, landing.ledge.top - 1)
                        nextFlakes.append(flake)
                    }
                } else {
                    deposit(on: landing.ledge, at: landing.x, radius: flake.radius)
                }
            } else if flake.position.y >= bounds.minY - 6 {
                nextFlakes.append(flake)
            }
        }
        swap(&flakes, &nextFlakes)
        advancePlow(dt, enabled: plowsEnabled)
        if time >= settleAt {
            settleAt = time + 0.10
            settle()
        }
    }

    private mutating func advancePlow(_ dt: CGFloat, enabled: Bool) {
        guard enabled else {
            if plow != nil { nextPlowTime = time + 19 }
            plow = nil
            return
        }
        guard var vehicle = plow else {
            if time >= nextPlowTime {
                startPlow()
                nextPlowTime = time + (plow == nil ? 6 : 28 + unit() * 26)
            }
            return
        }
        guard let drift = drifts[vehicle.ledgeID],
              let lane = drift.ledge.visible.first(where: {
                  let center = drift.ledge.frame.minX + vehicle.x
                  return $0.lowerBound <= center - Plow.halfWidth && $0.upperBound >= center + Plow.halfWidth
              }) else {
            plow = nil
            return
        }
        let origin = drift.ledge.frame.minX
        let end = min(lane.upperBound - origin - Plow.halfWidth,
                      max(lane.lowerBound - origin + Plow.halfWidth, vehicle.destination))
        let next = vehicle.x + vehicle.direction * 48 * dt
        vehicle.x = vehicle.direction > 0 ? min(next, end) : max(next, end)
        let center = origin + vehicle.x
        let nose = center + vehicle.direction * Plow.halfWidth
        let body = CGRect(x: center - Plow.halfWidth, y: drift.ledge.top,
                          width: Plow.halfWidth * 2, height: 15)
        guard !drift.ledge.occluders.contains(where: { $0.intersects(body) }) else {
            plow = nil
            return
        }
        let column = Int((nose - origin) / Self.column)
        if drift.heights.indices.contains(column), drift.ledge.isVisible(nose) {
            let removed = min(max(0, drift.heights[column] - 0.45), 135 * dt)
            if removed > 0.08 {
                drifts[vehicle.ledgeID]?.heights[column] -= removed
                unsettled.insert(vehicle.ledgeID)
                shed(x: nose, y: drift.ledge.top + drift.heights[column] + 3,
                     amount: removed, sideways: vehicle.direction * 155)
            }
        }
        plow = vehicle.x == end ? nil : vehicle
    }

    private mutating func startPlow() {
        var routes: [(id: Int, lane: ClosedRange<CGFloat>)] = []
        for id in collisionOrder where id == -1 || id > 0 {
            guard let drift = drifts[id],
                  drift.ledge.top + 21 <= bounds.maxY else { continue }
            let origin = drift.ledge.frame.minX
            for lane in drift.ledge.visible where lane.upperBound - lane.lowerBound >= 150 {
                let route = CGRect(x: lane.lowerBound, y: drift.ledge.top, width: lane.upperBound - lane.lowerBound, height: 15)
                guard !drift.ledge.occluders.contains(where: { $0.intersects(route) }) else { continue }
                let snow = [0.2, 0.4, 0.6, 0.8].reduce(CGFloat.zero) { total, fraction in
                    total + drift.height(at: lane.lowerBound + route.width * fraction)
                }
                if snow >= 8 {
                    routes.append((id, (lane.lowerBound - origin)...(lane.upperBound - origin)))
                }
            }
        }
        guard !routes.isEmpty else { return }
        let route = routes[min(routes.count - 1, Int(unit() * CGFloat(routes.count)))]
        let left = route.lane.lowerBound + Plow.halfWidth
        let right = route.lane.upperBound - Plow.halfWidth
        let direction: CGFloat = unit() < 0.5 ? 1 : -1
        plow = Plow(ledgeID: route.id, direction: direction,
                    x: direction > 0 ? left : right, destination: direction > 0 ? right : left)
    }

    private mutating func settle() {
        for id in Array(unsettled) {
            guard let drift = drifts[id], drift.heights.count > 1, !drift.ledge.visible.isEmpty else {
                unsettled.remove(id)
                continue
            }
            let ledge = drift.ledge
            var heights = drift.heights
            var changed = false
            for i in 0..<(heights.count - 1) {
                let x = ledge.frame.minX + (CGFloat(i) + 0.5) * Self.column
                guard ledge.isVisible(x), ledge.isVisible(x + Self.column) else { continue }
                let difference = heights[i] - heights[i + 1]
                let transfer = min(0.55, max(0, abs(difference) - 1.8) * 0.24)
                guard transfer > 0.02 else { continue }
                let signed = difference > 0 ? transfer : -transfer
                heights[i] -= signed
                heights[i + 1] += signed
                changed = true
            }
            if changed {
                drifts[id]?.heights = heights
            } else {
                unsettled.remove(id)
            }
        }
    }

    private mutating func deposit(on ledge: Ledge, at x: CGFloat, radius: CGFloat) {
        guard let count = drifts[ledge.id]?.heights.count else { return }
        let i = Int((x - ledge.frame.minX) / Self.column)
        let ground = ledge.id == -1
        let maximum: CGFloat = ground ? 20 : 11
        for offset in -2...2 where (0..<count).contains(i + offset) {
            let n = i + offset
            let local = (CGFloat(n) + 0.5) * Self.column
            guard ledge.isVisible(ledge.frame.minX + local) else { continue }
            let ripple = sin(local * 0.043) * 1.2 + sin(local * 0.018) * 1.5
            let taper = ground ? 1 : min(1, max(0.12, min(local, ledge.frame.width - local) / 22))
            let ceiling = (maximum + ripple) * taper
            let amount = (0.56 + 0.22 * radius) / CGFloat(1 + abs(offset))
            let previous = drifts[ledge.id]?.heights[n] ?? 0
            let added = min(amount, max(0, ceiling - previous))
            if added > 0 {
                drifts[ledge.id]?.heights[n] += added
                unsettled.insert(ledge.id)
            }
        }
    }

    private mutating func depositReleased(_ amount: CGFloat, on ledge: Ledge, at x: CGFloat) -> CGFloat {
        let index = Int((x - ledge.frame.minX) / Self.column)
        unsettled.insert(ledge.id)
        let count = drifts[ledge.id]?.heights.count ?? 0
        let maxHeight: CGFloat = ledge.id == -1 ? Self.maximumHeight : 16
        var remaining = amount
        // On the ground, spread overflow out from the impact point until a column can hold it.
        let reach = ledge.id == -1 ? max(index, count - 1 - index) : 5
        for distance in 0...reach {
            for offset in distance == 0 ? [0] : [-distance, distance] {
                let i = index + offset
                guard i >= 0, i < count, ledge.isVisible(ledge.frame.minX + (CGFloat(i) + 0.5) * Self.column),
                      let height = drifts[ledge.id]?.heights[i] else { continue }
                let deposited = min(remaining, max(0, maxHeight - height))
                drifts[ledge.id]?.heights[i] += deposited
                remaining -= deposited
                if remaining <= 0.01 { return 0 }
            }
        }
        return remaining
    }

    mutating func sweep(from: CGPoint, to: CGPoint, preservePickup: Bool = false) {
        let travel = hypot(to.x - from.x, to.y - from.y)
        guard travel > 0.25 else { return }
        let protected = preservePickup ? pickup(at: to) : nil
        let reach: CGFloat = 14
        let horizontal = to.x - from.x
        let shove = min(155, 72 + travel * 3)
        for id in collisionOrder {
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
                let reserve = protected?.0 == id && protected?.1 == i
                    ? max(1.5, to.y - drift.ledge.top) : 0
                let removed = min(max(0, drift.heights[i] - reserve),
                                  (1 - distance / reach) * min(2.4, travel * 0.35))
                guard removed >= 0.045 else { continue }
                drift.heights[i] -= removed
                unsettled.insert(id)
                let direction: CGFloat = (abs(horizontal) >= 1 ? horizontal : x - to.x) < 0 ? -1 : 1
                let crest = drift.ledge.top + drift.heights[i] + removed
                let launchX = x + direction * 6
                let launchY = max(crest, drift.ledge.top + drift.height(at: launchX)) + 2
                shed(x: launchX, y: launchY, amount: removed, sideways: direction * shove)
            }
            drifts[id] = drift
        }
    }

    func pickup(at point: CGPoint) -> (Int, Int)? {
        for id in collisionOrder {
            guard let drift = drifts[id], drift.ledge.isVisible(point.x),
                  point.y >= drift.ledge.top - 0.8,
                  point.y <= drift.ledge.top + drift.height(at: point.x) + 4,
                  !drift.ledge.occluders.contains(where: { $0.contains(point) }) else { continue }
            let index = min(drift.heights.count - 1, Int((point.x - drift.ledge.frame.minX) / Self.column))
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
        unsettled.insert(id)
        take = (id, index, amount)
        held = 6 + amount
        return true
    }

    func placement(at point: CGPoint) -> Placement? {
        guard let radius = held else { return nil }
        var best: (placement: Placement, score: CGFloat)?
        for index in balls.indices.reversed() {
            let ball = balls[index]
            guard ball.radius > 0, let drift = drifts[ball.ledge],
                  let support = ballCenter(index, on: drift.ledge),
                  drift.ledge.isVisible(support.x),
                  !balls.contains(where: { $0.radius > 0 && $0.below == index }),
                  stackDepth(index) < 3 else { continue }
            let fittedRadius = min(radius, ball.radius * 0.76)
            let center = CGPoint(x: support.x, y: support.y + ball.radius + fittedRadius - 0.75)
            let dx = abs(point.x - center.x)
            guard dx <= ball.radius + 15, point.y >= support.y - 3,
                  point.y <= center.y + fittedRadius + 16,
                  !drift.ledge.occluders.contains(where: { $0.contains(center) }) else { continue }
            let score = dx + abs(point.y - center.y) * 0.6
            if score < (best?.score ?? .infinity) {
                best = (Placement(ledge: ball.ledge, below: index, center: center, radius: fittedRadius), score)
            }
        }
        if let best { return best.placement }

        let candidates = drifts.values.filter { $0.ledge.isVisible(point.x) }.sorted {
            abs(point.y - $0.ledge.top - $0.height(at: point.x) - radius) <
                abs(point.y - $1.ledge.top - $1.height(at: point.x) - radius)
        }
        for drift in candidates {
            let surface = drift.ledge.top + drift.height(at: point.x)
            let center = CGPoint(x: point.x, y: surface + radius - 0.75)
            guard point.y >= surface - 8, point.y <= center.y + radius + 12,
                  !drift.ledge.occluders.contains(where: { $0.contains(center) }) else { continue }
            let overlapping = balls.contains { ball in
                ball.radius > 0 && ball.ledge == drift.ledge.id && ball.below == nil &&
                abs(point.x - drift.ledge.frame.minX - ball.x) < ball.radius + radius - 1
            }
            if !overlapping {
                return Placement(ledge: drift.ledge.id, below: nil, center: center, radius: radius)
            }
        }
        return nil
    }

    private func stackDepth(_ index: Int) -> Int {
        var depth = 1
        var below = balls[index].below
        while let index = below {
            depth += 1
            below = balls[index].below
        }
        return depth
    }

    mutating func finishBall(at point: CGPoint) -> Bool {
        if balls.count >= 96 { compactBalls() }
        guard balls.count < 96, let position = placement(at: point),
              let ledge = drifts[position.ledge]?.ledge else { cancelBall(); return false }
        balls.append(Ball(x: position.center.x - ledge.frame.minX, radius: position.radius,
                          ledge: position.ledge, below: position.below))
        held = nil
        take = nil
        return true
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
            unsettled.insert(take.id)
        }
        take = nil
        held = nil
    }

    func ballCenter(_ index: Int, on ledge: Ledge) -> CGPoint? {
        let ball = balls[index]
        guard ball.radius > 0 else { return nil }
        let x = ledge.frame.minX + ball.x
        guard x <= ledge.frame.maxX else { return nil }
        var y = ledge.top + (drifts[ledge.id]?.height(at: x) ?? 0) + ball.radius - 0.75
        var below = ball.below
        while let i = below {
            guard balls[i].radius > 0 else { return nil }
            y += balls[i].radius * 2 - 0.75
            below = balls[i].below
        }
        return CGPoint(x: x, y: y)
    }

    mutating func clear() {
        held = nil
        take = nil
        balls.removeAll()
        flakes.removeAll()
        nextFlakes.removeAll(keepingCapacity: true)
        plow = nil
        nextPlowTime = time + 19
        unsettled.removeAll()
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
