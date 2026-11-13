import Foundation
import CoreGraphics

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

let display = CGRect(x: -320, y: 0, width: 320, height: 240)
let ground = Ledge(id: -1, frame: CGRect(x: -320, y: 0, width: 320, height: 1), visible: [-320...0])
let window = Ledge(id: 8, frame: CGRect(x: -260, y: 60, width: 185, height: 80), visible: [-260 ... -75])
let covered = Ledge(id: 9, frame: CGRect(x: -260, y: 30, width: 185, height: 40), visible: [])
var field = Snowfield(bounds: display)
field.updateLedges([ground, window, covered])

for _ in 0..<720 { field.step(1.0 / 30, rate: 135, wind: .zero) }
let original = field.drifts[window.id]!.heights
require(original.filter { $0 > 5 }.count > 15, "snow should accumulate on an exposed window")
require(field.drifts[covered.id]!.heights.allSatisfy { $0 == 0 }, "covered edge should not catch snow")
require(field.flakes.count <= 850, "particle count should remain bounded")

let moved = Ledge(id: 8, frame: window.frame.offsetBy(dx: 20, dy: -15), visible: [-240 ... -55])
field.updateLedges([ground, moved, covered])
require(field.drifts[8]!.heights == original, "moving the window should preserve its profile")

let source = CGPoint(x: -215, y: moved.top + 6)
let initial = field.drifts[8]!.heights
require(field.beginBall(at: source), "pickup should start on accumulated snow")
require(field.drifts[8]!.heights != initial, "pickup should use snow from the drift")
field.cancelBall()
require(field.held == nil && field.drifts[8]!.heights == initial, "cancel should restore snow")

let drop = CGPoint(x: -170, y: moved.top + 8)
require(field.beginBall(at: source), "first pickup")
require(field.finishBall(at: drop), "first ball placement")
let otherSource = CGPoint(x: -120, y: moved.top + 6)
require(field.beginBall(at: otherSource), "second pickup")
let radius = field.balls[0].radius
require(field.finishBall(at: CGPoint(x: drop.x, y: moved.top + 2 * radius + 2)), "stack a second ball")
require(field.balls.count == 2 && field.balls[1].below == 0, "snowman should have two stacked balls")
require(field.ballCenter(1, on: moved)!.y > field.ballCenter(0, on: moved)!.y, "head sits above its base")

let beforeSweep = field.drifts[8]!.heights.reduce(0, +)
field.sweep(from: CGPoint(x: -238, y: moved.top + 7),
            to: CGPoint(x: -57, y: moved.top + 7))
require(field.drifts[8]!.heights.reduce(0, +) < beforeSweep, "cursor should move snow off the swept columns")

field.updateLedges([ground])
require(field.drifts[8] == nil && field.balls.allSatisfy { $0.radius == 0 }, "closed window removes attached snow")
require(field.flakes.contains(where: \.detached), "released snow should fall")
field.clear()
require(field.flakes.isEmpty && field.balls.isEmpty && field.held == nil, "clear should reset snow")
print("PASS: accumulation, occlusion, bounded particles, moved windows, sculpting, sweep, window close, clear.")

let monitor = CGRect(x: 0, y: 0, width: 1710, height: 1100)
let notchedFullscreen = CGRect(x: 0, y: 0, width: 1710, height: 1061)
let maximizedWindow = CGRect(x: 0, y: 60, width: 1710, height: 1001)
require(DisplayCoverage.isFullscreen(window: monitor, screen: monitor, topInset: 0, fullscreenPresentation: false),
        "an edge-to-edge fullscreen window should hide the overlay")
require(DisplayCoverage.isFullscreen(window: notchedFullscreen, screen: monitor, topInset: 39,
                                     fullscreenPresentation: false),
        "a fullscreen window with a camera-housing gap should hide the overlay")
require(!DisplayCoverage.isFullscreen(window: maximizedWindow, screen: monitor, topInset: 39,
                                      fullscreenPresentation: false),
        "an ordinary maximized window that leaves the Dock visible should keep snow")
require(!DisplayCoverage.isFullscreen(window: notchedFullscreen, screen: monitor, topInset: 0,
                                      fullscreenPresentation: false),
        "without fullscreen presentation a menu-bar-sized gap on a non-notched display is not enough")
require(DisplayCoverage.isFullscreen(window: notchedFullscreen, screen: monitor, topInset: 0,
                                     fullscreenPresentation: true),
        "fullscreen presentation may leave a menu-bar-sized gap")
print("PASS: fullscreen geometry including display insets and ordinary maximized windows.")

var sculpt = Snowfield(bounds: display, seed: 37)
sculpt.updateLedges([ground, window])
for _ in 0..<960 { sculpt.step(1.0 / 30, rate: 150, wind: .zero) }
let heights = sculpt.drifts[window.id]!.heights
let edgeColumn = heights.indices.filter { heights[$0] >= 1.5 }.min { heights[$0] < heights[$1] }!
let fullColumn = heights.indices.max { heights[$0] < heights[$1] }!
func pilePoint(_ column: Int) -> CGPoint {
    CGPoint(x: window.frame.minX + (CGFloat(column) + 0.5) * Snowfield.column, y: window.top + 5)
}
let basePoint = CGPoint(x: window.frame.midX, y: window.top + 10)
require(sculpt.beginBall(at: pilePoint(edgeColumn)), "pick a small amount for the base")
require(sculpt.finishBall(at: basePoint), "place the base on the actual drift")
let baseCenter = sculpt.ballCenter(0, on: window)!
let baseRadius = sculpt.balls[0].radius
let snowHeight = sculpt.drifts[window.id]!.height(at: baseCenter.x)
require(abs(baseCenter.y - baseRadius - (window.top + snowHeight - 0.75)) < 0.01,
        "the base rests on the accumulated surface")
require(sculpt.beginBall(at: pilePoint(fullColumn)), "pick a larger ball for the second tier")
let held = sculpt.held!
let slightlyOffCenter = CGPoint(x: baseCenter.x + 5, y: baseCenter.y + 1)
let preview = sculpt.placement(at: slightlyOffCenter)!
require(held > baseRadius && preview.below == 0 && preview.radius < baseRadius,
        "an oversized upper ball snaps and fits")
require(sculpt.finishBall(at: slightlyOffCenter), "commit the same placement shown in preview")
require(hypot(sculpt.ballCenter(1, on: window)!.x - preview.center.x,
              sculpt.ballCenter(1, on: window)!.y - preview.center.y) < 0.01,
        "preview matches the installed ball exactly")
let thirdColumn = heights.indices.filter { $0 != fullColumn && $0 != edgeColumn }.max { heights[$0] < heights[$1] }!
require(sculpt.beginBall(at: pilePoint(thirdColumn)), "pick a third ball")
let second = sculpt.ballCenter(1, on: window)!
require(sculpt.finishBall(at: second), "snap a third ball on the same axis")
require(sculpt.balls[2].below == 1 && sculpt.balls[0].x == sculpt.balls[2].x,
        "all three balls share an axis")
let fourthColumn = heights.indices.filter { ![fullColumn, edgeColumn, thirdColumn].contains($0) }
    .max { heights[$0] < heights[$1] }!
require(sculpt.beginBall(at: pilePoint(fourthColumn)), "pick a fourth ball")
let top = sculpt.ballCenter(2, on: window)!
require(!sculpt.finishBall(at: top), "a fourth ball cannot create an unstable stack")
require(sculpt.held == nil && sculpt.balls.count == 3, "rejected placement cancels cleanly")
print("PASS: surface contact, oversized ball fitting, exact preview, centered three-ball stack.")

let back = DesktopWindow(id: 81, frame: CGRect(x: 15, y: 30, width: 220, height: 100), layer: 0, dock: false)
let front = DesktopWindow(id: 82, frame: CGRect(x: 100, y: 90, width: 150, height: 120), layer: 0, dock: false)
let screen = CGRect(x: 0, y: 0, width: 420, height: 300)
let scene = DesktopScene(windows: [front, back])
let backEdge = scene.ledges(in: screen).first { $0.id == back.id }!
require(!backEdge.isVisible(16), "snow does not hang over the rounded corner")
require(backEdge.isVisible(60) && !backEdge.isVisible(140), "overlap hides the covered ledge")
require(backEdge.occluders.contains { $0.contains(CGPoint(x: 140, y: 145)) },
        "foreground rectangles clip both the snow cap and the snowman")
let highFront = DesktopWindow(id: 83, frame: CGRect(x: 100, y: 134, width: 150, height: 100), layer: 0, dock: false)
let partiallyMasked = DesktopScene(windows: [highFront, back]).ledges(in: screen).first { $0.id == back.id }!
require(partiallyMasked.isVisible(140), "a window just above the ledge leaves its base exposed")
require(partiallyMasked.occluders.contains { $0.contains(CGPoint(x: 140, y: 135)) },
        "a floating foreground window still clips the upper part of the cap")
print("PASS: rounded corners and full/partial foreground occlusion.")

let physicsDisplay = CGRect(x: 0, y: 0, width: 440, height: 250)
let physicsGround = Ledge(id: -1, frame: CGRect(x: 0, y: 0, width: 440, height: 1), visible: [0...440])
let wide = Ledge(id: 30, frame: CGRect(x: 40, y: 90, width: 320, height: 75), visible: [40...360])
let lower = Ledge(id: 31, frame: CGRect(x: 190, y: 42, width: 174, height: 38), visible: [190...364])
var resizeField = Snowfield(bounds: physicsDisplay, seed: 71)
resizeField.updateLedges([physicsGround, wide])
for _ in 0..<680 { resizeField.step(1.0 / 30, rate: 110, wind: .zero) }
resizeField.updateLedges([physicsGround, wide, lower])
let wideSnow = resizeField.drifts[wide.id]!.heights
let originalAmount = wideSnow.reduce(0, +)
let narrower = Ledge(id: wide.id, frame: CGRect(x: 40, y: 90, width: 165, height: 75), visible: [40...205])
resizeField.updateLedges([physicsGround, narrower, lower])
let keptAmount = resizeField.drifts[wide.id]!.heights.reduce(0, +)
let fallen = resizeField.flakes.filter(\.detached)
require(keptAmount > 0 && fallen.contains { $0.position.x > narrower.frame.maxX },
        "right-edge shrink keeps snow on the window and drops the removed portion")
require(abs(keptAmount + fallen.map(\.snowAmount).reduce(0, +) - originalAmount) < 0.01,
        "shrinking transfers the missing snow into airborne chunks")
for _ in 0..<75 { resizeField.step(1.0 / 30, rate: 0, wind: .zero) }
require(resizeField.drifts[lower.id]!.height(at: 270) > 5,
        "shed snow piles up on the first exposed lower window")

var leftResize = Snowfield(bounds: physicsDisplay, seed: 88)
leftResize.updateLedges([physicsGround, wide])
for _ in 0..<650 { leftResize.step(1.0 / 30, rate: 112, wind: .zero) }
let beforeLeft = leftResize.drifts[wide.id]!
let fromLeft = Ledge(id: wide.id, frame: CGRect(x: 117, y: 90, width: 243, height: 75), visible: [117...360])
leftResize.updateLedges([physicsGround, fromLeft])
require(abs(leftResize.drifts[wide.id]!.height(at: 262) - beforeLeft.height(at: 262)) < 2,
        "left-edge shrink keeps the profile aligned to the fixed right edge")
require(leftResize.flakes.contains { $0.detached && $0.position.x < fromLeft.frame.minX },
        "left-edge shrink drops snow on the left")
let parked = leftResize.drifts[wide.id]!.heights
leftResize.updateLedges([physicsGround], retainedWindowIDs: [wide.id])
require(leftResize.drifts[wide.id]!.ledge.visible.isEmpty, "a hidden existing window stops catching snow")
leftResize.updateLedges([physicsGround, fromLeft], retainedWindowIDs: [wide.id])
require(leftResize.drifts[wide.id]!.heights == parked, "snow returns when the window is visible again")

var sweepField = Snowfield(bounds: physicsDisplay, seed: 93)
sweepField.updateLedges([physicsGround, wide])
for _ in 0..<550 { sweepField.step(1.0 / 30, rate: 100, wind: .zero) }
sweepField.sweep(from: CGPoint(x: 130, y: wide.top + 5), to: CGPoint(x: 164, y: wide.top + 5))
require(sweepField.flakes.contains { $0.detached && $0.lateralSpeed > 0 && $0.speed < 0 },
        "rightward sweep throws material up and to the right")
require(sweepField.pickup(at: CGPoint(x: 160, y: wide.top - 3)) == nil,
        "the window title bar remains available to the window")

let transient = DesktopWindow(id: 90, frame: CGRect(x: 20, y: 100, width: 160, height: 27),
                              layer: 0, dock: false, supportsSnow: false)
require(!DesktopScene(windows: [transient, back]).ledges(in: screen).contains { $0.id == transient.id },
        "utility popups do not become surfaces")
print("PASS: resize from both edges, falling mass, deposition, window persistence, lateral sweep, and surface filtering.")

var plowField = Snowfield(bounds: physicsDisplay, seed: 131)
plowField.updateLedges([physicsGround, wide])
for _ in 0..<1800 where plowField.plow == nil {
    plowField.step(1.0 / 60, rate: 150, wind: .zero, plowsEnabled: true)
}
require(plowField.plow != nil, "a plow occasionally starts on a wide snowy surface")
let vehicle = plowField.plow!
var pushedSnow = false
for _ in 0..<150 {
    plowField.step(1.0 / 60, rate: 0, wind: .zero, plowsEnabled: true)
    pushedSnow = pushedSnow || plowField.flakes.contains {
        $0.detached && $0.lateralSpeed * vehicle.direction > 40
    }
}
require(pushedSnow, "the plow pushes settled snow back into the simulation")
plowField.step(1.0 / 60, rate: 0, wind: .zero, plowsEnabled: false)
require(plowField.plow == nil, "turning off plows removes the active vehicle")
print("PASS: plow scheduling, displaced snow, and disabling the vehicle.")

var gestureField = Snowfield(bounds: physicsDisplay, seed: 93)
gestureField.updateLedges([physicsGround, wide])
for _ in 0..<550 { gestureField.step(1.0 / 30, rate: 100, wind: .zero) }
let target = CGPoint(x: 164, y: wide.top + 4)
let beforeHover = gestureField.drifts[wide.id]!.heights.reduce(0, +)
for x in 130...164 {
    gestureField.sweep(from: CGPoint(x: CGFloat(x) - 0.65, y: target.y),
                       to: CGPoint(x: CGFloat(x), y: target.y), preservePickup: true)
}
require(gestureField.drifts[wide.id]!.heights.reduce(0, +) < beforeHover,
        "slow hover movement displaces snow")
require(gestureField.beginBall(at: target), "a click can still reserve snow after hovering")
for _ in 0..<40 { gestureField.step(1.0 / 60, rate: 0, wind: .zero) }
require(gestureField.finishBall(at: CGPoint(x: 250, y: wide.top + 14)),
        "snow reserved on mouse down remains available through the drag")
print("PASS: slow hover, pickup after hover, and ball placement.")

let parkedWindow = DesktopWindow(id: back.id, frame: CGRect(x: 40, y: -95, width: 180, height: 115),
                                 layer: 0, dock: false)
let parkedScene = DesktopScene(windows: [parkedWindow])
require(!parkedScene.ledges(in: screen).contains { $0.id == back.id },
        "the visible sliver of a parked window does not carry snow onscreen")
print("PASS: parked window slivers are excluded from the rendered snow scene.")

var desktopTransition = DesktopTransition()
require(desktopTransition.unsettledWindows(in: [back], now: 0, dragging: false).isEmpty,
        "ordinary windows are visible")
require(desktopTransition.unsettledWindows(in: [parkedWindow], now: 0.15, dragging: false) == [back.id],
        "a window jumping to the edge is temporarily hidden")
require(desktopTransition.unsettledWindows(in: [back], now: 0.30, dragging: false) == [back.id],
        "the returning window remains hidden through the animation")
require(desktopTransition.unsettledWindows(in: [back], now: 0.61, dragging: false).isEmpty,
        "the settled window can show its original snow")
require(desktopTransition.unsettledWindows(in: [parkedWindow], now: 0.63, dragging: true).isEmpty,
        "dragging a window updates the snow immediately")
print("PASS: desktop transition, settled return, and live window dragging.")
