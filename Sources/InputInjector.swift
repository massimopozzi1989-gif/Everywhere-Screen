import AppKit
import CoreGraphics

/// Trasforma i messaggi di input del tablet in eventi macOS (CGEvent).
/// Richiede il permesso Accessibilità; tutte le chiamate avvengono sulla sua coda seriale.
final class InputInjector {
    /// Chiamato (sulla coda interna) se manca il permesso.
    var onPermissionMissing: (() -> Void)?

    private let queue = DispatchQueue(label: "everywhere.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<Int>()
    private var lastDown: (time: TimeInterval, point: CGPoint, button: Int)?
    private var clickCount = 1
    private var askedPermission = false

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    static func requestPermission() {
        CGRequestPostEventAccess()
    }

    func handle(_ msg: [String: Any], display: CGDirectDisplayID) {
        queue.async { self.process(msg, display: display) }
    }

    private func process(_ msg: [String: Any], display: CGDirectDisplayID) {
        guard Self.hasPermission else {
            if !askedPermission {
                askedPermission = true
                Self.requestPermission()
            }
            onPermissionMissing?()
            return
        }
        switch msg["t"] as? String {
        case "p":
            guard let kind = msg["k"] as? String, let x = msg["x"] as? Double, let y = msg["y"] as? Double else { return }
            pointer(kind, x: x, y: y, button: msg["b"] as? Int ?? 0,
                    pressure: msg["p"] as? Double, pen: (msg["pen"] as? Int ?? 0) != 0, display: display)
        case "s":
            scroll(dx: msg["dx"] as? Double ?? 0, dy: msg["dy"] as? Double ?? 0)
        case "txt":
            if let s = msg["s"] as? String { type(s) }
        case "k":
            if let code = msg["c"] as? String { key(code, modifiers: msg["m"] as? Int ?? 0) }
        default:
            break
        }
    }

    // MARK: - Mouse / Pencil

    private func pointer(_ kind: String, x: Double, y: Double, button: Int, pressure: Double?, pen: Bool, display: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(display)
        let point = CGPoint(x: bounds.minX + min(max(x, 0), 1) * (bounds.width - 1),
                            y: bounds.minY + min(max(y, 0), 1) * (bounds.height - 1))
        let right = button == 2
        let type: CGEventType

        switch kind {
        case "d":
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastDown, last.button == button, now - last.time < NSEvent.doubleClickInterval,
               hypot(point.x - last.point.x, point.y - last.point.y) < 8 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastDown = (now, point, button)
            buttonsDown.insert(button)
            type = right ? .rightMouseDown : .leftMouseDown
        case "u":
            guard buttonsDown.remove(button) != nil else { return }
            type = right ? .rightMouseUp : .leftMouseUp
        default:
            type = buttonsDown.contains(0) ? .leftMouseDragged : buttonsDown.contains(2) ? .rightMouseDragged : .mouseMoved
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: right ? .right : .left) else { return }
        if kind == "d" || kind == "u" {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        if pen, let pressure {
            // Pressione della Pencil, letta dalle app di disegno come quella di una tavoletta.
            event.setIntegerValueField(.mouseEventSubtype, value: 1)   // tablet point
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        }
        event.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Tastiera

    private func type(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { key("Enter", modifiers: 0) }
            var units = Array(line.utf16)
            while !units.isEmpty {
                let chunk = Array(units.prefix(16))
                units.removeFirst(chunk.count)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
    }

    private func key(_ code: String, modifiers: Int) {
        guard let keyCode = Self.keyCodes[code] else { return }
        var flags = CGEventFlags()
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskControl) }
        if modifiers & 4 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 8 != 0 { flags.insert(.maskCommand) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// `KeyboardEvent.code` (posizione fisica del tasto) → virtual key code macOS.
    private static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7,
        "KeyC": 8, "KeyV": 9, "IntlBackslash": 10, "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14,
        "KeyR": 15, "KeyY": 16, "KeyT": 17, "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21,
        "Digit6": 22, "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27, "Digit8": 28,
        "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32, "BracketLeft": 33, "KeyI": 34,
        "KeyP": 35, "Enter": 36, "KeyL": 37, "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41,
        "Backslash": 42, "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48,
        "Space": 49, "Backquote": 50, "Backspace": 51, "Escape": 53, "NumpadEnter": 76,
        "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101, "F11": 103, "F10": 109,
        "F12": 111, "Home": 115, "PageUp": 116, "Delete": 117, "F4": 118, "End": 119, "F2": 120,
        "PageDown": 121, "F1": 122, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
    ]
}
