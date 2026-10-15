import Foundation

// Live view of the controller: prints decoded buttons/sticks and any raw byte changes.
setbuf(stdout, nil)
let queue = DispatchQueue(label: "gipdump")
let monitor = PadMonitor()
var devices: [PadDevice] = []
var lastRaw: [UInt8] = []

func describe(_ s: PadState) -> String {
  var on: [String] = []
  let named: [(Bool, String)] = [
    (s.a, "A"), (s.b, "B"), (s.x, "X"), (s.y, "Y"), (s.lb, "LB"), (s.rb, "RB"), (s.ls, "LS"), (s.rs, "RS"),
    (s.view, "View"), (s.menu, "Menu"), (s.guide, "Guide"), (s.share, "Share"),
    (s.up, "Up"), (s.down, "Down"), (s.left, "Left"), (s.right, "Right"),
  ]
  for (v, n) in named where v { on.append(n) }
  return String(format: "LT %4d RT %4d  L(%6d,%6d) R(%6d,%6d)  ", s.lt, s.rt, s.lx, s.ly, s.rx, s.ry)
    + (on.isEmpty ? "-" : on.joined(separator: " "))
}

monitor.onConnect = { service, kind in
  let d = PadDevice(service: service, kind: kind, queue: queue)
  print("connected: \(d.name) \(String(format: "%04x:%04x", d.vendorID, d.productID)) [\(kind)]")
  d.onState = { print(describe($0)) }
  let raw = ProcessInfo.processInfo.environment["RAW"] != nil
  d.onPacket = { p in
    if raw { print("raw", p.map { String(format: "%02x", $0) }.joined(separator: " ")) }
    guard d.kind == .gip else { return }
    guard p[0] == GIP.cmdInput else {
      if p[0] != GIP.cmdStatus { print("packet", p.map { String(format: "%02x", $0) }.joined(separator: " ")) }
      return
    }
    // Report bytes beyond the standard layout when they change (paddles, share, etc.).
    if p.count > 18, lastRaw.count == p.count, Array(p[18...]) != Array(lastRaw[18...]) {
      let extra = p[18...].enumerated().map { String(format: "%02x", $0.element) }.joined(separator: " ")
      print("  extra[18...] (len \(p.count)): \(extra)")
    }
    lastRaw = p
  }
  d.onDisconnect = { print("disconnected") }
  print("(if the Xbox button light comes on, the handshake worked)")
  d.start { error in
    if let error, !(error is PadDevice.ResetInProgress) { print("open failed: \(error.localizedDescription)") }
  }
  devices.append(d)
}
monitor.start(queue: queue)
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "0") ?? 0
if seconds > 0 { queue.asyncAfter(deadline: .now() + seconds) { exit(0) } }
dispatchMain()
