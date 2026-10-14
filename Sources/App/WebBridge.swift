import CryptoKit
import Foundation
import Network

/// Streams controller state to the RematchBridge browser extension over a loopback
/// WebSocket, so web pages (Xbox Cloud Gaming, GeForce NOW) see a real gamepad.
///
/// The WebSocket handshake and framing are implemented here directly so that a page
/// whose Origin isn't allowed never receives a single frame.
///
/// Protocol (JSON text frames):
///   app → page: {"t":"s","b":[18 button values 0...1],"a":[lx,ly,rx,ry]}  (Y axes down-positive)
///               {"t":"c","connected":false}
///   page → app: {"t":"f","focused":true|false}
///               {"t":"r","strong":0...1,"weak":0...1,"duration":ms}
final class WebBridge {
  static let port: NWEndpoint.Port = 37121
  /// Only these pages may connect (checked against the WebSocket Origin header).
  static let allowedOrigins: Set<String> = [
    "https://www.xbox.com", "https://play.geforcenow.com", "https://hardwaretester.com",
  ]

  /// Main queue: true while any connected page has focus.
  var onFocusChange: ((Bool) -> Void)?
  /// Main queue: hosts of the pages currently connected (e.g. "xbox.com").
  var onPagesChange: (([String]) -> Void)?
  /// Main queue: rumble request, magnitudes 0...1, duration in seconds.
  var onRumble: ((Double, Double, Double) -> Void)?

  private let queue = DispatchQueue(label: "rematchbridge.web")
  private var listener: NWListener?
  private var clients: [ObjectIdentifier: Client] = [:]
  private var lastFrame: Data?
  private var heartbeat: DispatchSourceTimer?

  private final class Client {
    let connection: NWConnection
    var open = false  // handshake accepted
    var origin = ""
    var focused = false
    var buffer = Data()
    init(_ c: NWConnection) { connection = c }
  }

  func start() {
    queue.async {
      self.listen()
      let t = DispatchSource.makeTimerSource(queue: self.queue)
      t.schedule(deadline: .now() + 1, repeating: 1)
      t.setEventHandler { [weak self] in self?.resendLast() }  // keeps idle pages fresh
      t.resume()
      self.heartbeat = t
    }
  }

  private func listen() {
    let params = NWParameters.tcp
    params.requiredInterfaceType = .loopback
    params.allowLocalEndpointReuse = true
    do {
      let l = try NWListener(using: params, on: Self.port)
      l.newConnectionHandler = { [weak self] c in self?.accept(c) }
      l.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready: Log.write("web bridge listening on 127.0.0.1:\(Self.port)")
        case .failed(let e):
          Log.write("web bridge failed: \(e); retrying")
          self?.listener?.cancel()
          self?.queue.asyncAfter(deadline: .now() + 3) { self?.listen() }
        default: break
        }
      }
      l.start(queue: queue)
      listener = l
    } catch {
      Log.write("web bridge could not start: \(error)")
    }
  }

  private func accept(_ c: NWConnection) {
    let client = Client(c)
    let id = ObjectIdentifier(client)
    clients[id] = client
    c.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.drop(id) }
      if case .cancelled = state { self?.drop(id) }
    }
    c.start(queue: queue)
    read(client, id)
    // Pages that never finish the handshake are dropped.
    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      if self?.clients[id]?.open == false { self?.drop(id) }
    }
  }

  private func read(_ client: Client, _ id: ObjectIdentifier) {
    client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self, self.clients[id] != nil else { return }
      if let data { client.buffer.append(data) }
      if client.buffer.count > 1 << 20 { self.drop(id); return }  // nothing legitimate is this big
      if client.open { self.parseFrames(client, id) } else { self.parseHandshake(client, id) }
      if isComplete || error != nil { self.drop(id); return }
      if self.clients[id] != nil { self.read(client, id) }
    }
  }

  // MARK: - Handshake

  private func parseHandshake(_ client: Client, _ id: ObjectIdentifier) {
    guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
    let head = String(decoding: client.buffer[..<end.lowerBound], as: UTF8.self)
    client.buffer.removeSubrange(..<end.upperBound)
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst()
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let origin = headers["origin"] ?? ""
    guard requestLine.hasPrefix("GET "),
      headers["upgrade"]?.lowercased() == "websocket",
      let key = headers["sec-websocket-key"], !key.isEmpty
    else {
      reject(client, id, status: "400 Bad Request", reason: "not a WebSocket request")
      return
    }
    guard Self.allowedOrigins.contains(origin) else {
      reject(client, id, status: "403 Forbidden", reason: "origin \"\(origin)\" not allowed")
      return
    }
    let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
    let response =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n"
    client.connection.send(content: Data(response.utf8), completion: .idempotent)
    client.open = true
    client.origin = origin
    Log.write("web bridge: \(origin) connected")
    publishPages()
    if let frame = lastFrame { send(frame, to: client) }
    if !client.buffer.isEmpty { parseFrames(client, id) }
  }

  private func reject(_ client: Client, _ id: ObjectIdentifier, status: String, reason: String) {
    Log.write("web bridge: rejected (\(reason))")
    let body = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    client.connection.send(content: Data(body.utf8), isComplete: true, completion: .contentProcessed { [weak self] _ in
      self?.drop(id)
    })
  }

  // MARK: - Frames (RFC 6455)

  private func parseFrames(_ client: Client, _ id: ObjectIdentifier) {
    while true {
      let b = [UInt8](client.buffer.prefix(14))
      guard b.count >= 2 else { return }
      let opcode = b[0] & 0x0F
      let masked = b[1] & 0x80 != 0
      var length = Int(b[1] & 0x7F)
      var offset = 2
      if length == 126 {
        guard b.count >= 4 else { return }
        length = Int(b[2]) << 8 | Int(b[3]); offset = 4
      } else if length == 127 {
        guard b.count >= 10 else { return }
        length = b[2..<10].reduce(0) { $0 << 8 | Int($1) }; offset = 10
      }
      guard masked, length <= 1 << 16 else { drop(id); return }  // clients must mask
      guard client.buffer.count >= offset + 4 + length else { return }
      let start = client.buffer.startIndex
      let mask = [UInt8](client.buffer[(start + offset)..<(start + offset + 4)])
      var payload = [UInt8](client.buffer[(start + offset + 4)..<(start + offset + 4 + length)])
      for i in payload.indices { payload[i] ^= mask[i % 4] }
      client.buffer.removeSubrange(start..<(start + offset + 4 + length))

      switch opcode {
      case 0x1:  // text
        if let msg = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] { handle(msg, from: client) }
      case 0x8:  // close
        client.connection.send(content: Data([0x88, 0x00]), isComplete: true, completion: .contentProcessed { [weak self] _ in
          self?.drop(id)
        })
        return
      case 0x9:  // ping → pong
        client.connection.send(content: frame(opcode: 0xA, Data(payload)), completion: .idempotent)
      default:
        break
      }
    }
  }

  private func frame(opcode: UInt8, _ payload: Data) -> Data {
    var out = Data([0x80 | opcode])
    if payload.count < 126 {
      out.append(UInt8(payload.count))
    } else {
      out.append(126)
      out.append(UInt8(payload.count >> 8 & 0xFF))
      out.append(UInt8(payload.count & 0xFF))
    }
    out.append(payload)
    return out
  }

  // MARK: - Messages

  private func handle(_ msg: [String: Any], from client: Client) {
    switch msg["t"] as? String {
    case "f":
      client.focused = msg["focused"] as? Bool ?? false
      publishFocus()
    case "r":
      let strong = unit(msg["strong"]), weak = unit(msg["weak"])
      let duration = min(max((msg["duration"] as? Double ?? 0) / 1000, 0), 5)
      DispatchQueue.main.async { self.onRumble?(strong, weak, duration) }
    default:
      break
    }
  }

  private func unit(_ v: Any?) -> Double { min(max(v as? Double ?? 0, 0), 1) }

  private func drop(_ id: ObjectIdentifier) {
    guard let c = clients.removeValue(forKey: id) else { return }
    c.connection.cancel()
    if c.open {
      Log.write("web bridge: page disconnected")
      publishFocus()
      publishPages()
    }
  }

  private func publishPages() {
    let hosts = Set(clients.values.filter(\.open).map {
      $0.origin.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "")
    }).sorted()
    DispatchQueue.main.async { self.onPagesChange?(hosts) }
  }

  private func publishFocus() {
    let any = clients.values.contains { $0.open && $0.focused }
    DispatchQueue.main.async { self.onFocusChange?(any) }
  }

  // MARK: - Sending

  /// Call from any queue. nil means "controller disconnected".
  func publish(_ s: PadState?) {
    let message: [String: Any]
    if let s {
      let digital: (Bool) -> Double = { $0 ? 1 : 0 }
      let b: [Double] = [s.a, s.b, s.x, s.y, s.lb, s.rb].map(digital)
        + [Double(s.lt) / 1023, Double(s.rt) / 1023]
        + [s.view, s.menu, s.ls, s.rs, s.up, s.down, s.left, s.right, s.guide, s.share].map(digital)
      func axis(_ v: Int16) -> Double { (min(max(Double(v) / 32767, -1), 1) * 10000).rounded() / 10000 + 0 }
      message = ["t": "s", "b": b, "a": [axis(s.lx), -axis(s.ly) + 0, axis(s.rx), -axis(s.ry) + 0]]
    } else {
      message = ["t": "c", "connected": false]
    }
    guard let json = try? JSONSerialization.data(withJSONObject: message) else { return }
    let data = frame(opcode: 0x1, json)
    queue.async {
      self.lastFrame = data
      for c in self.clients.values where c.open { self.send(data, to: c) }
    }
  }

  private func resendLast() {
    guard let f = lastFrame else { return }
    for c in clients.values where c.open { send(f, to: c) }
  }

  private func send(_ data: Data, to client: Client) {
    client.connection.send(content: data, completion: .idempotent)
  }
}
