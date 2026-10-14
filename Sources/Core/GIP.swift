import Foundation

/// Normalized controller state decoded from GIP (Xbox One / Series) input packets.
struct PadState: Equatable {
  var a = false, b = false, x = false, y = false
  var lb = false, rb = false, ls = false, rs = false
  var view = false, menu = false, guide = false, share = false
  var up = false, down = false, left = false, right = false
  /// 0...1023
  var lt: UInt16 = 0, rt: UInt16 = 0
  /// Signed, up/right positive (GIP convention).
  var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
}

/// Minimal GIP (Gaming Input Protocol) codec for wired Xbox One / Series pads.
/// Packet layout: [command, flags, sequence, length, payload...].
enum GIP {
  static let cmdAck: UInt8 = 0x01
  static let cmdAnnounce: UInt8 = 0x02
  static let cmdStatus: UInt8 = 0x03
  static let cmdPower: UInt8 = 0x05
  static let cmdGuide: UInt8 = 0x07
  static let cmdRumble: UInt8 = 0x09
  static let cmdLED: UInt8 = 0x0A
  static let cmdInput: UInt8 = 0x20

  static let flagNeedsAck: UInt8 = 0x10
  static let flagSystem: UInt8 = 0x20

  /// PDP-designed pads (incl. Turtle Beach Rematch) only stream input after this.
  static func pdpEnableInput(seq: UInt8) -> [UInt8] { [0x06, flagSystem, seq, 0x02, 0x01, 0x00] }

  static func powerOn(seq: UInt8) -> [UInt8] { [cmdPower, flagSystem, seq, 0x01, 0x00] }

  /// Guide-button LED: mode 0x01 = on, brightness 0x00...0x2F.
  static func led(seq: UInt8, brightness: UInt8 = 0x14) -> [UInt8] {
    [cmdLED, flagSystem, seq, 0x03, 0x00, 0x01, brightness]
  }

  /// Rumble on all four motors. Magnitudes are 0...100.
  static func rumble(seq: UInt8, leftTrigger: UInt8, rightTrigger: UInt8, strong: UInt8, weak: UInt8) -> [UInt8] {
    [cmdRumble, 0x00, seq, 0x09, 0x00, 0x0F, leftTrigger, rightTrigger, strong, weak, 0xFF, 0x00, 0xEB]
  }

  static func ack(for packet: [UInt8], seq: UInt8) -> [UInt8] {
    // Acknowledge `packet` (echoes its sequence number in the header).
    [cmdAck, flagSystem, packet[2], 0x09, 0x00, packet[0], flagSystem, packet[3], 0x00, 0x00, 0x00, 0x00, 0x00]
  }

  static func le16(_ p: [UInt8], _ i: Int) -> UInt16 { UInt16(p[i]) | UInt16(p[i + 1]) << 8 }

  /// Decodes a 0x20 input packet into `state`, keeping the guide button (sent separately as 0x07).
  static func decodeInput(_ p: [UInt8], shareFromEnd: Int?, into state: inout PadState) {
    guard p.count >= 18 else { return }
    let b0 = p[4], b1 = p[5]
    state.menu = b0 & 0x04 != 0
    state.view = b0 & 0x08 != 0
    state.a = b0 & 0x10 != 0
    state.b = b0 & 0x20 != 0
    state.x = b0 & 0x40 != 0
    state.y = b0 & 0x80 != 0
    state.up = b1 & 0x01 != 0
    state.down = b1 & 0x02 != 0
    state.left = b1 & 0x04 != 0
    state.right = b1 & 0x08 != 0
    state.lb = b1 & 0x10 != 0
    state.rb = b1 & 0x20 != 0
    state.ls = b1 & 0x40 != 0
    state.rs = b1 & 0x80 != 0
    state.lt = min(le16(p, 6), 1023)
    state.rt = min(le16(p, 8), 1023)
    state.lx = Int16(bitPattern: le16(p, 10))
    state.ly = Int16(bitPattern: le16(p, 12))
    state.rx = Int16(bitPattern: le16(p, 14))
    state.ry = Int16(bitPattern: le16(p, 16))
    if let back = shareFromEnd, p.count - back >= 18 { state.share = p[p.count - back] & 0x01 != 0 }
  }

  /// Distance of the Share button byte from the end of the input packet, per controller.
  /// Verified on hardware; unknown pads report no Share button rather than a guess.
  static func shareFromEnd(vendorID: Int, productID: Int) -> Int? {
    switch (vendorID, productID) {
    case (0x10F5, 0x711F): return 18  // Turtle Beach Rematch Advanced Wired
    default: return nil
    }
  }
}
