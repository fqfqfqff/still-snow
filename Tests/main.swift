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
            to: CGPoint(x: -57, y: moved.top + 7), tool: .shovel)
require(field.drifts[8]!.heights.reduce(0, +) < beforeSweep, "shovel should clear snow")

field.updateLedges([ground])
require(field.drifts[8] == nil && field.balls.allSatisfy { $0.radius == 0 }, "closed window removes attached snow")
require(field.flakes.contains(where: \.detached), "released snow should fall")
field.clear()
require(field.flakes.isEmpty && field.balls.isEmpty && field.held == nil, "clear should reset snow")
print("PASS: accumulation, occlusion, bounded particles, moved windows, sculpting, shovel, window close, clear.")

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
