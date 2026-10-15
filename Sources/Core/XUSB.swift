import Foundation

/// Codec for wired Xbox 360-style pads (the "XUSB" / XInput protocol), as documented by
/// the Linux xpad driver. Input reports are 20 bytes: [0x00, 0x14, buttons..., axes...].
enum XUSB {
  /// LED pattern 0x06 = "player 1 on".
  static let ledPlayer1: [UInt8] = [0x01, 0x03, 0x06]

  /// Rumble, magnitudes 0...255 (large/low-frequency motor first).
  static func rumble(strong: UInt8, weak: UInt8) -> [UInt8] {
    [0x00, 0x08, 0x00, strong, weak, 0x00, 0x00, 0x00]
  }

  static func le16(_ p: [UInt8], _ i: Int) -> Int16 {
    Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8)
  }

  /// Decodes an input report into `state`. Returns false for other message types
  /// (LED status, rumble status, headset), which carry no input.
  @discardableResult
  static func decodeInput(_ p: [UInt8], into state: inout PadState) -> Bool {
    guard p.count >= 14, p[0] == 0x00, p[1] >= 0x14 else { return false }
    let b2 = p[2], b3 = p[3]
    state.up = b2 & 0x01 != 0
    state.down = b2 & 0x02 != 0
    state.left = b2 & 0x04 != 0
    state.right = b2 & 0x08 != 0
    state.menu = b2 & 0x10 != 0
    state.view = b2 & 0x20 != 0
    state.ls = b2 & 0x40 != 0
    state.rs = b2 & 0x80 != 0
    state.lb = b3 & 0x01 != 0
    state.rb = b3 & 0x02 != 0
    state.guide = b3 & 0x04 != 0
    state.a = b3 & 0x10 != 0
    state.b = b3 & 0x20 != 0
    state.x = b3 & 0x40 != 0
    state.y = b3 & 0x80 != 0
    // Triggers are 0...255 here; PadState uses GIP's 0...1023.
    state.lt = UInt16((Int(p[4]) * 1023 + 127) / 255)
    state.rt = UInt16((Int(p[5]) * 1023 + 127) / 255)
    state.lx = le16(p, 6)
    state.ly = le16(p, 8)
    state.rx = le16(p, 10)
    state.ry = le16(p, 12)
    state.share = false
    return true
  }
}
