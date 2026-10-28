import AppKit
import Carbon

struct ParsedShortcut: Equatable {
    let modifiers: UInt32
    let keyCode: UInt16

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers & UInt32(cmdKey) != 0 { flags |= UInt32(cmdKey) }
        if modifiers & UInt32(shiftKey) != 0 { flags |= UInt32(shiftKey) }
        if modifiers & UInt32(optionKey) != 0 { flags |= UInt32(optionKey) }
        if modifiers & UInt32(controlKey) != 0 { flags |= UInt32(controlKey) }
        return flags
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if let char = keyCodeToCharacter(keyCode) {
            parts.append(char.uppercased())
        }
        return parts.joined()
    }

    private func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
        // Map common letter keyCodes (US keyboard); extend as needed.
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
        ]
        return map[keyCode]
    }
}

enum ShortcutCodec {
    static func encode(_ shortcut: ParsedShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers & UInt32(controlKey) != 0 { parts.append("control") }
        if shortcut.modifiers & UInt32(optionKey) != 0 { parts.append("option") }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { parts.append("command") }
        if let char = shortcut.displayString.last {
            parts.append(String(char))
        }
        return parts.joined(separator: "+")
    }

    static func decode(_ string: String) -> ParsedShortcut? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.lowercased().split(separator: "+").map(String.init)
        guard let keyToken = tokens.last, keyToken.count == 1,
              let keyCode = letterToKeyCode(keyToken) else { return nil }
        var mods: UInt32 = 0
        for token in tokens.dropLast() {
            switch token {
            case "command", "cmd": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "option", "alt": mods |= UInt32(optionKey)
            case "control", "ctrl": mods |= UInt32(controlKey)
            default: return nil
            }
        }
        return ParsedShortcut(modifiers: mods, keyCode: keyCode)
    }

    static func displayString(forStorage storage: String) -> String {
        guard let parsed = decode(storage) else { return String(localized: "None", comment: "Keyboard shortcut field: shown when no shortcut is set") }
        return parsed.displayString
    }

    static func from(event: NSEvent) -> ParsedShortcut? {
        guard event.type == .keyDown, let chars = event.charactersIgnoringModifiers?.uppercased(), let first = chars.first else { return nil }
        let keyCode = letterToKeyCode(String(first).lowercased()) ?? UInt16(event.keyCode)
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        return ParsedShortcut(modifiers: mods, keyCode: keyCode)
    }

    private static func letterToKeyCode(_ letter: String) -> UInt16? {
        let map: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
        ]
        return map[letter.lowercased()]
    }
}
