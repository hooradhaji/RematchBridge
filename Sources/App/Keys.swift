import CoreGraphics

/// A key press: one virtual key plus held modifiers, parsed from names like "cmd+shift+t".
/// The last part is the key (which may itself be a modifier, e.g. "shift").
struct KeyChord: Equatable {
  var keyCode: CGKeyCode
  var modifiers: CGEventFlags

  static func parse(_ text: String) -> KeyChord? {
    let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let last = parts.last, !parts.contains("") else { return nil }
    var flags: CGEventFlags = []
    for name in parts.dropLast() {
      guard let m = Keys.modifiers[name] else { return nil }
      flags.insert(m.flag)
    }
    if let code = Keys.codes[last] { return KeyChord(keyCode: code, modifiers: flags) }
    if let m = Keys.modifiers[last] { return KeyChord(keyCode: m.code, modifiers: flags) }
    return nil
  }
}

enum Keys {
  static let modifiers: [String: (flag: CGEventFlags, code: CGKeyCode)] = [
    "cmd": (.maskCommand, 0x37), "command": (.maskCommand, 0x37),
    "shift": (.maskShift, 0x38),
    "ctrl": (.maskControl, 0x3B), "control": (.maskControl, 0x3B),
    "opt": (.maskAlternate, 0x3A), "option": (.maskAlternate, 0x3A), "alt": (.maskAlternate, 0x3A),
    "fn": (.maskSecondaryFn, 0x3F),
    "rshift": (.maskShift, 0x3C), "rctrl": (.maskControl, 0x3E), "ropt": (.maskAlternate, 0x3D),
    "rcmd": (.maskCommand, 0x36),
  ]

  static func flag(forModifierCode code: CGKeyCode) -> CGEventFlags? {
    modifiers.values.first { $0.code == code }?.flag
  }

  /// US ANSI virtual key codes (Carbon kVK_*).
  static let codes: [String: CGKeyCode] = {
    var c: [String: CGKeyCode] = [
      "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
      "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
      "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
      "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
      "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
      "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
      "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
      "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75, "home": 0x73, "end": 0x77,
      "pageup": 0x74, "pagedown": 0x79, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
      "capslock": 0x39, "keypadenter": 0x4C,
      "volumeup": 0x48, "volumedown": 0x49, "mute": 0x4A,
      "minus": 0x1B, "equal": 0x18, "comma": 0x2B, "period": 0x2F, "slash": 0x2C,
      "semicolon": 0x29, "quote": 0x27, "grave": 0x32, "backslash": 0x2A,
      "leftbracket": 0x21, "rightbracket": 0x1E,
    ]
    let f: [CGKeyCode] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
    for (i, code) in f.enumerated() { c["f\(i + 1)"] = code }
    let keypad: [CGKeyCode] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
    for (i, code) in keypad.enumerated() { c["keypad\(i)"] = code }
    return c
  }()
}
