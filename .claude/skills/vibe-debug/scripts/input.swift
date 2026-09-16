// Global CGEvents: only for explicit OS-input tests on a dedicated test Mac
// or disposable macOS VM. Never use as a stress/replay recovery fallback.
// App-local debug events already exercise key monitors and view handlers.
//
// Usage: swift input.swift --isolated-desktop key|move|click|dblclick|drag ...
// Coordinates are global screen points, origin top-left. The flag asserts
// isolation; it does not create it. Activation and bounds are not containment.
import CoreGraphics
import Foundation

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(64)
}

// ANSI virtual key codes.
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "return": 36, "tab": 48, "space": 49, "esc": 53,
]

let rawArgs = CommandLine.arguments
guard rawArgs.count >= 3, rawArgs[1] == "--isolated-desktop" else {
    die("global input requires --isolated-desktop on a dedicated test Mac or disposable VM; never use during unattended stress")
}
let args = [rawArgs[0]] + Array(rawArgs.dropFirst(2))

func point(_ xi: Int, _ yi: Int) -> CGPoint {
    guard args.count > yi, let x = Double(args[xi]), let y = Double(args[yi]), x.isFinite, y.isFinite else { die("bad coordinates") }
    return CGPoint(x: x, y: y)
}

func post(_ e: CGEvent?) {
    e?.post(tap: .cghidEventTap)
    usleep(30_000)
}

func mouse(_ type: CGEventType, _ p: CGPoint, clickState: Int64 = 1) -> CGEvent? {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: clickState)
    return e
}

switch args[1] {
case "key":
    guard args.count >= 3, let code = keyCodes[args[2].lowercased()] else {
        die("unknown key '\(args.count >= 3 ? args[2] : "")' — known: a-z 0-9 space tab return esc")
    }
    post(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
    post(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false))

// A plain cursor move — the only way to drive NSTrackingArea hover states
// (mouseEntered/Exited): the window server computes those from real cursor
// motion, so neither --debug-cmd's posted NSEvents nor a bare
// CGWarpMouseCursorPosition reach them. Enter/exit fire on BOUNDARY crossings,
// so move outside the target view first if the cursor may already be inside.
case "move":
    post(mouse(.mouseMoved, point(2, 3)))

case "click", "dblclick":
    let p = point(2, 3)
    let clicks: Int64 = args[1] == "dblclick" ? 2 : 1
    for c in 1...clicks {
        post(mouse(.leftMouseDown, p, clickState: c))
        post(mouse(.leftMouseUp, p, clickState: c))
    }

case "drag":
    let a = point(2, 3), b = point(4, 5)
    let steps = args.count > 6 ? (Int(args[6]) ?? 0) : 20
    guard (2...200).contains(steps) else { die("steps must be 2...200") }
    post(mouse(.leftMouseDown, a))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
    }
    post(mouse(.leftMouseUp, b))

default:
    die("unknown command '\(args[1])' — key, move, click, dblclick, drag")
}
