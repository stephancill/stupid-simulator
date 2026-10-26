import Foundation

/// macOS virtual key codes mapped to USB HID keyboard usage codes, which is what the simulator's
/// keyboard path expects. Pure lookup, so the table is tested without a device.
public enum KeyboardMap {
    /// Keyed by the `kVK_` constants from Carbon's Events.h.
    public static let usageByVirtualKeyCode: [UInt16: UInt32] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09,
        0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F,
        0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15,
        0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
        0x10: 0x1C, 0x06: 0x1D,
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22,
        0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C,
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31,
        0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
        0x7B: 0x50, 0x7C: 0x4F, 0x7D: 0x51, 0x7E: 0x52,
        0x75: 0x4C, 0x73: 0x4A, 0x77: 0x4D, 0x74: 0x4B, 0x79: 0x4E,
    ]

    public static func usage(forVirtualKeyCode keyCode: UInt16) -> UInt32? {
        usageByVirtualKeyCode[keyCode]
    }

    /// The modifier keys, which macOS reports through `flagsChanged` rather than as key presses.
    /// Each carries the device dependent flag that says whether that one key, not its twin on the
    /// other side, is down. Command is left out: the Mac's menus own it.
    public static let modifierByVirtualKeyCode: [UInt16: (usage: UInt32, deviceFlag: UInt)] = [
        0x38: (0xE1, 0x02), // left Shift
        0x3C: (0xE5, 0x04), // right Shift
        0x3B: (0xE0, 0x01), // left Control
        0x3E: (0xE4, 0x2000), // right Control
        0x3A: (0xE2, 0x20), // left Option
        0x3D: (0xE6, 0x40), // right Option
    ]

    /// The usage and whether it is now down, for a `flagsChanged` event's key code and raw flags.
    public static func modifier(forVirtualKeyCode keyCode: UInt16, flags: UInt) -> (usage: UInt32, isDown: Bool)? {
        guard let modifier = modifierByVirtualKeyCode[keyCode] else { return nil }
        return (modifier.usage, flags & modifier.deviceFlag != 0)
    }

    public static let leftShiftUsage: UInt32 = 0xE1

    /// One key to press for a character, with Shift held for the key's upper character.
    public struct TypedKey: Sendable, Hashable {
        public let usage: UInt32
        public let shifted: Bool

        public init(usage: UInt32, shifted: Bool) {
            self.usage = usage
            self.shifted = shifted
        }
    }

    /// The keys for a literal string on a US layout, so text can be typed without a virtual key
    /// code. A character with no key, such as an accented letter, returns nil rather than typing
    /// something different.
    public static func keys(forTyping text: String) -> [TypedKey]? {
        var keys: [TypedKey] = []
        for character in text {
            if let usage = usageByCharacter[character] {
                keys.append(TypedKey(usage: usage, shifted: false))
            } else if let usage = shiftedUsageByCharacter[character] {
                keys.append(TypedKey(usage: usage, shifted: true))
            } else {
                return nil
            }
        }
        return keys
    }

    static let usageByCharacter: [Character: UInt32] = {
        var map: [Character: UInt32] = [:]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[letter] = UInt32(0x04 + index)
        }
        for (index, digit) in "123456789".enumerated() {
            map[digit] = UInt32(0x1E + index)
        }
        map["0"] = 0x27
        map["\n"] = 0x28
        map["\t"] = 0x2B
        map[" "] = 0x2C
        map["-"] = 0x2D
        map["="] = 0x2E
        map["["] = 0x2F
        map["]"] = 0x30
        map["\\"] = 0x31
        map[";"] = 0x33
        map["'"] = 0x34
        map["`"] = 0x35
        map[","] = 0x36
        map["."] = 0x37
        map["/"] = 0x38
        return map
    }()

    /// A key pressed by name, with the modifiers held around it, oldest first.
    public struct KeyChord: Sendable, Hashable {
        public let modifiers: [UInt32]
        public let usage: UInt32

        public init(modifiers: [UInt32], usage: UInt32) {
            self.modifiers = modifiers
            self.usage = usage
        }
    }

    /// Keys with no character to type, by the names `stupidsim key` takes.
    public static let usageByKeyName: [String: UInt32] = [
        "delete": 0x2A, "backspace": 0x2A,
        "forward-delete": 0x4C,
        "return": 0x28, "enter": 0x28,
        "escape": 0x29, "esc": 0x29,
        "tab": 0x2B,
        "space": 0x2C,
        "left": 0x50, "right": 0x4F, "up": 0x52, "down": 0x51,
        "home": 0x4A, "end": 0x4D, "page-up": 0x4B, "page-down": 0x4E,
    ]

    /// Left hand modifiers by name. Command is the GUI usage, which the guest reads as ⌘.
    public static let modifierUsageByName: [String: UInt32] = [
        "cmd": 0xE3, "command": 0xE3,
        "shift": 0xE1,
        "ctrl": 0xE0, "control": 0xE0,
        "opt": 0xE2, "option": 0xE2, "alt": 0xE2,
    ]

    /// A chord such as `delete`, `cmd+a` or `shift+tab`: modifiers joined to one key with `+`.
    /// The key is a name from `usageByKeyName` or a single character on a US layout, and an upper
    /// character holds Shift. Names ignore case; a lone character keeps its own. Nil for anything
    /// unknown, rather than pressing something else.
    public static func chord(named text: String) -> KeyChord? {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" alone, or a trailing "cmd++", means the plus key.
        if text.hasSuffix("++") || text == "+" {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }

        var modifiers: [UInt32] = []
        for name in parts {
            guard let usage = modifierUsageByName[name.lowercased()] else { return nil }
            if !modifiers.contains(usage) { modifiers.append(usage) }
        }

        let usage: UInt32
        if let named = usageByKeyName[key.lowercased()] {
            usage = named
        } else if key.count == 1, let character = key.first {
            if let plain = usageByCharacter[character] {
                usage = plain
            } else if let upper = shiftedUsageByCharacter[character] {
                usage = upper
                if !modifiers.contains(leftShiftUsage) { modifiers.append(leftShiftUsage) }
            } else {
                return nil
            }
        } else {
            return nil
        }
        return KeyChord(modifiers: modifiers, usage: usage)
    }

    /// The upper character of each key on a US layout.
    static let shiftedUsageByCharacter: [Character: UInt32] = {
        var map: [Character: UInt32] = [:]
        for (index, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            map[letter] = UInt32(0x04 + index)
        }
        for (index, symbol) in "!@#$%^&*(".enumerated() {
            map[symbol] = UInt32(0x1E + index)
        }
        map[")"] = 0x27
        map["_"] = 0x2D
        map["+"] = 0x2E
        map["{"] = 0x2F
        map["}"] = 0x30
        map["|"] = 0x31
        map[":"] = 0x33
        map["\""] = 0x34
        map["~"] = 0x35
        map["<"] = 0x36
        map[">"] = 0x37
        map["?"] = 0x38
        return map
    }()
}
