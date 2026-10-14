import Foundation
import CoreGraphics
var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) { if !cond { failures += 1; print("FAIL line \(line): \(msg)") } }

// Key parsing
check(KeyChord.parse("space") == KeyChord(keyCode: 0x31, modifiers: []), "space")
check(KeyChord.parse("cmd+tab") == KeyChord(keyCode: 0x30, modifiers: .maskCommand), "cmd+tab")
check(KeyChord.parse("CMD + Shift + 4") == KeyChord(keyCode: 0x15, modifiers: [.maskCommand, .maskShift]), "cmd+shift+4")
check(KeyChord.parse("shift") == KeyChord(keyCode: 0x38, modifiers: []), "lone shift")
check(KeyChord.parse("cmd+[") == KeyChord(keyCode: 0x21, modifiers: .maskCommand), "cmd+[")
check(KeyChord.parse("f12")?.keyCode == 0x6F, "f12")
check(KeyChord.parse("cmd+") == nil, "trailing plus rejected")
check(KeyChord.parse("bogus") == nil, "bogus rejected")
check(KeyChord.parse("a+b") == nil, "non-modifier prefix rejected")
check(Action.parse("mouse:left") == .mouse(.left), "mouse:left")
check(Action.parse("mouse:side") == nil, "bad mouse rejected")
check(Action.parse("toggle") == .toggleMapping, "toggle")
check(Action.parse("none") == Action.none && Action.parse("") == Action.none, "none")

// Built-in profiles all validate and survive a JSON round trip
for f in BuiltInProfiles.all {
  do {
    let data = try JSONEncoder().encode(f)
    let back = try JSONDecoder().decode(ProfileFile.self, from: data)
    let p = try Profile(file: back, url: nil)
    check(p.actions.count == Input.allCases.count, "\(f.name) maps every input (\(p.actions.count))")
  } catch { check(false, "\(f.name): \(error)") }
}
// Bad profile reports every problem
var bad = BuiltInProfiles.desktop
bad.buttons["zz"] = "space"; bad.buttons["a"] = "nonsense"
do { _ = try Profile(file: bad, url: nil); check(false, "bad profile accepted") }
catch { let m = error.localizedDescription; check(m.contains("zz") && m.contains("nonsense"), "errors listed: \(m)") }

// GIP decoding with packets captured from the Rematch Advanced
func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
var st = PadState()
let share = GIP.shareFromEnd(vendorID: 0x10F5, productID: 0x711F)
GIP.decodeInput(hex("20 00 03 20 10 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"), shareFromEnd: share, into: &st)
check(st.a && !st.b, "A decoded")
var shareP = [UInt8](repeating: 0, count: 36); shareP[0] = 0x20; shareP[3] = 0x20; shareP[18] = 0x01
st = PadState(); GIP.decodeInput(shareP, shareFromEnd: share, into: &st)
check(st.share && !st.a, "share decoded")
var stick = [UInt8](repeating: 0, count: 36); stick[0] = 0x20
stick[6] = 0xFF; stick[7] = 0x03  // LT 1023
let lx = Int16(-32768), ly = Int16(32767)
stick[10] = UInt8(UInt16(bitPattern: lx) & 0xFF); stick[11] = UInt8(UInt16(bitPattern: lx) >> 8)
stick[12] = UInt8(UInt16(bitPattern: ly) & 0xFF); stick[13] = UInt8(UInt16(bitPattern: ly) >> 8)
st = PadState(); GIP.decodeInput(stick, shareFromEnd: share, into: &st)
check(st.lt == 1023 && st.lx == -32768 && st.ly == 32767, "axes decoded \(st)")
check(Input.lt.isPressed(st, triggerThreshold: 0.25) && !Input.rt.isPressed(st, triggerThreshold: 0.25), "trigger threshold")
// Other pads don't get a guessed Share button
check(GIP.shareFromEnd(vendorID: 0x0E6F, productID: 0x02A0) == nil, "no share guess")
check(GIP.ack(for: hex("07 30 05 02 01 5b"), seq: 0) == hex("01 20 05 09 00 07 20 02 00 00 00 00 00"), "ack format")

check(AppModel.shortName("Xbox Rematch Advanced Wired Controller- Dark Cosmos Reveal") == "Rematch Advanced Wired", "short name")
check(AppModel.shortName("Xbox Controller") == "Xbox Controller", "short name keeps short names")
check(AppModel.shortName("PowerA Wired Controller") == "PowerA Wired", "short name drops Controller")
check(AppModel.shortName("Gamepad") == "Gamepad", "single word kept")
print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
