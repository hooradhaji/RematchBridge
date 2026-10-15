import Foundation
import IOKit
import IOUSBHost

private let kServiceTerminated: UInt32 = 0xE000_0010  // kIOMessageServiceIsTerminated

func registryNumber(_ service: io_service_t, _ key: String) -> Int? {
  (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? NSNumber)?.intValue
}

func registryString(_ service: io_service_t, _ key: String) -> String? {
  IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? String
}

/// Which USB protocol a controller speaks.
enum PadProtocol {
  /// Xbox One / Series and licensed third-party pads (interface FF/47/D0).
  case gip
  /// Xbox 360-style wired pads (interface FF/5D/01).
  case xusb
}

/// Decides which controllers RematchBridge should drive: wired Xbox-protocol pads that
/// no macOS driver handles. Nothing else on USB is ever opened.
enum PadMatcher {
  /// Returns the protocol for `service` if it's a controller we should drive.
  static func match(_ service: io_service_t) -> PadProtocol? {
    let vid = registryNumber(service, "idVendor") ?? 0
    let pid = registryNumber(service, "idProduct") ?? 0
    if appleHandled.contains(pair(vid, pid)) { return nil }
    // The signature lists the device's and each interface's class/subclass/protocol,
    // so this works before the device is configured, without opening it.
    let sig = signature(service)
    if registryNumber(service, "bDeviceClass") == 0xFF, registryNumber(service, "bDeviceSubClass") == 0x47,
      registryNumber(service, "bDeviceProtocol") == 0xD0
    {
      return .gip
    }
    if contains(sig, [0xFF, 0x47, 0xD0]) { return .gip }
    if contains(sig, [0xFF, 0x5D, 0x01]) { return .xusb }  // not 0x81: that's the wireless receiver
    return nil
  }

  private static func pair(_ v: Int, _ p: Int) -> Int { v << 16 | p }

  private static func signature(_ service: io_service_t) -> [UInt8] {
    guard let data = IORegistryEntryCreateCFProperty(service, "UsbDeviceSignature" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? Data
    else { return [] }
    return [UInt8](data)
  }

  static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard haystack.count >= needle.count else { return false }
    return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
  }

  /// Controllers Apple's own driver (XboxGamepad.dext) claims. Read from the system so new
  /// macOS versions are respected automatically; the fallback is macOS 26's list.
  static let appleHandled: Set<Int> = {
    var set: Set<Int> = [pair(0x045E, 0x028E), pair(0x045E, 0x0B00), pair(0x045E, 0x02EA), pair(0x045E, 0x0B12)]
    let url = URL(fileURLWithPath: "/System/Library/DriverExtensions/XboxGamepad.dext/Info.plist")
    if let plist = NSDictionary(contentsOf: url), let personalities = plist["IOKitPersonalities"] as? [String: Any] {
      for case let p as [String: Any] in personalities.values {
        guard let v = (p["idVendor"] as? NSNumber)?.intValue else { continue }
        if let pid = (p["idProduct"] as? NSNumber)?.intValue { set.insert(pair(v, pid)) }
        for case let pid as NSNumber in (p["idProductArray"] as? [Any]) ?? [] { set.insert(pair(v, pid.intValue)) }
      }
    }
    return set
  }()
}

/// One wired Xbox-protocol controller, read directly over USB (no driver involved).
final class PadDevice {
  let kind: PadProtocol
  let name: String
  let serial: String
  let vendorID: Int
  let productID: Int
  let locationID: UInt32

  /// Called on `queue` whenever the decoded state changes.
  var onState: ((PadState) -> Void)?
  /// Called on `queue` with every raw packet (for diagnostics).
  var onPacket: (([UInt8]) -> Void)?
  /// Called once on `queue` when the controller goes away.
  var onDisconnect: (() -> Void)?

  private let queue: DispatchQueue
  private let deviceService: io_service_t
  private var device: IOUSBHostDevice?
  private var interface: IOUSBHostInterface?
  private var inPipe: IOUSBHostPipe?
  private var outPipe: IOUSBHostPipe?
  private var seq: UInt8 = 1
  private var state = PadState()
  private var closed = false
  private var consecutiveErrors = 0
  private var sawInput = false
  private lazy var shareFromEnd = GIP.shareFromEnd(vendorID: vendorID, productID: productID)

  struct ResetInProgress: Error {}
  private var deviceDescription: String { String(format: "%04x:%04x", vendorID, productID) }

  private static let resetLock = NSLock()
  private static var lastReset: [UInt32: Date] = [:]

  /// True if this location hasn't been reset in the last few seconds (and records the reset).
  private static func claimReset(locationID: UInt32) -> Bool {
    resetLock.lock(); defer { resetLock.unlock() }
    if let last = lastReset[locationID], Date().timeIntervalSince(last) < 8 { return false }
    lastReset[locationID] = Date()
    return true
  }

  init(service: io_service_t, kind: PadProtocol, queue: DispatchQueue) {
    self.kind = kind
    IOObjectRetain(service)
    deviceService = service
    self.queue = queue
    vendorID = registryNumber(service, "idVendor") ?? 0
    productID = registryNumber(service, "idProduct") ?? 0
    locationID = UInt32(truncatingIfNeeded: registryNumber(service, "locationID") ?? 0)
    name = registryString(service, "USB Product Name") ?? registryString(service, "kUSBProductString")
      ?? String(format: kind == .gip ? "Xbox-style controller %04x:%04x" : "Xbox 360-style controller %04x:%04x",
                vendorID, productID)
    serial = registryString(service, "USB Serial Number") ?? registryString(service, "kUSBSerialNumberString")
      ?? String(format: "%08x", locationID)
  }

  deinit { IOObjectRelease(deviceService) }

  /// Opens the controller and starts streaming. Runs on `queue`.
  func start(completion: @escaping (Error?) -> Void) {
    // Setup blocks while IOUSBHost delivers events on `queue`, so it must run elsewhere.
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try self.open()
        self.queue.async { self.startStreaming() }
        completion(nil)
      } catch {
        self.queue.async { self.teardown() }
        completion(error)
      }
    }
  }

  func close() {
    queue.async { self.finish() }
  }

  /// Rumble: magnitudes 0...100.
  func rumble(strong: UInt8, weak: UInt8) {
    queue.async {
      guard !self.closed else { return }
      switch self.kind {
      case .gip:
        self.send(GIP.rumble(seq: self.nextSeq(), leftTrigger: 0, rightTrigger: 0, strong: strong, weak: weak))
      case .xusb:
        func scale(_ v: UInt8) -> UInt8 { UInt8(min(255, Int(v) * 255 / 100)) }
        self.send(XUSB.rumble(strong: scale(strong), weak: scale(weak)))
      }
    }
  }

  // MARK: - Private

  private func open() throws {
    let dev = try IOUSBHostDevice(__ioService: deviceService, options: [], queue: queue) {
      [weak self] _, type, _ in
      if type == kServiceTerminated { self?.finish() }
    }
    device = dev
    // A pad that was already powered (e.g. plugged in before we started) stays half-asleep:
    // it never re-announces and ignores input requests. A USB reset makes it start over.
    // The reset re-enumerates the device, so the monitor reports it again and that
    // second instance (within the window) proceeds normally.
    if kind == .gip, Self.claimReset(locationID: locationID) {
      Log.write("resetting \(name) to restart its handshake")
      try dev.reset()
      throw PadDevice.ResetInProgress()
    }
    try dev.__configure(withValue: 1, matchInterfaces: true)

    guard let interfaceService = waitForInterface() else {
      throw NSError(domain: "RematchBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Controller interface did not appear"])
    }
    defer { IOObjectRelease(interfaceService) }
    let intf = try IOUSBHostInterface(__ioService: interfaceService, options: [], queue: queue, interestHandler: nil)
    interface = intf
    inPipe = (0x81...0x8F).lazy.compactMap { try? intf.copyPipe(withAddress: $0) }.first
    outPipe = (0x01...0x0F).lazy.compactMap { try? intf.copyPipe(withAddress: $0) }.first
    guard inPipe != nil, outPipe != nil else {
      throw NSError(domain: "RematchBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Controller endpoints not found"])
    }

  }

  private func startStreaming() {
    guard !closed else { return }
    for _ in 0..<4 { armRead() }
    wake()
    // Some pads ignore the first power-on while they boot; retry until input flows.
    for delay in [0.5, 1.5, 3.0] {
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, !self.closed, !self.sawInput else { return }
        self.wake()
      }
    }
  }

  private func wake() {
    switch kind {
    case .gip:
      send(GIP.powerOn(seq: nextSeq()))
      send(GIP.led(seq: nextSeq()))
      send(GIP.pdpEnableInput(seq: nextSeq()))
    case .xusb:
      sawInput = true  // 360 pads stream as soon as they're configured
      send(XUSB.ledPlayer1)
    }
  }

  private func waitForInterface() -> io_service_t? {
    for _ in 0..<60 {
      var iterator: io_iterator_t = 0
      if IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &iterator) == KERN_SUCCESS {
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
          if IOObjectConformsTo(child, "IOUSBHostInterface") != 0, isControllerInterface(child) { return child }
          IOObjectRelease(child)
        }
      }
      usleep(50_000)
    }
    return nil
  }

  private func isControllerInterface(_ service: io_service_t) -> Bool {
    let cls = registryNumber(service, "bInterfaceClass"), sub = registryNumber(service, "bInterfaceSubClass")
    let proto = registryNumber(service, "bInterfaceProtocol")
    switch kind {
    case .gip: return registryNumber(service, "bInterfaceNumber") == 0 && cls == 0xFF && (sub == 0x47 || sub == nil)
    case .xusb: return cls == 0xFF && sub == 0x5D && proto == 0x01
    }
  }

  private func nextSeq() -> UInt8 {
    defer { seq = seq == 0xFF ? 1 : seq + 1 }
    return seq
  }

  private func send(_ bytes: [UInt8]) {
    guard let outPipe, !closed else { return }
    let data = NSMutableData(bytes: bytes, length: bytes.count)
    do {
      try outPipe.enqueueIORequest(with: data, completionTimeout: 0) { _, _ in _ = data }
    } catch {
      Log.write("send failed: \(error.localizedDescription)")
    }
  }

  private func armRead() {
    guard let inPipe, !closed else { return }
    let buffer = NSMutableData(length: 64)!
    do {
      try inPipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, count in
        self?.readCompleted(status: status, buffer: buffer, count: count)
      }
    } catch {
      Log.write("read enqueue failed: \(error.localizedDescription)")
      finish()
    }
  }

  private func readCompleted(status: IOReturn, buffer: NSMutableData, count: Int) {
    guard !closed else { return }
    if status == kIOReturnSuccess {
      consecutiveErrors = 0
      if count > 0 { handle(Array(Data(bytes: buffer.bytes, count: count))) }
      armRead()
      return
    }
    // Device unplugged or pipe torn down.
    if status == kIOReturnAborted || status == kIOReturnNoDevice || status == kIOReturnNotResponding
      || status == kIOReturnNotAttached || status == kIOReturnOffline
    {
      finish()
      return
    }
    consecutiveErrors += 1
    if consecutiveErrors > 50 {
      Log.write(String(format: "too many read errors (0x%08x), closing", status))
      finish()
      return
    }
    try? inPipe?.clearStall()
    armRead()
  }

  private func handle(_ p: [UInt8]) {
    onPacket?(p)
    if kind == .xusb {
      let before = state
      XUSB.decodeInput(p, into: &state)
      if state != before { onState?(state) }
      return
    }
    guard p.count >= 4 else { return }
    if p[1] & GIP.flagNeedsAck != 0 { send(GIP.ack(for: p, seq: 0)) }
    let before = state
    switch p[0] {
    case GIP.cmdAnnounce:
      wake()
    case GIP.cmdGuide:
      if p.count >= 5 { state.guide = p[4] & 0x01 != 0 }
    case GIP.cmdInput:
      sawInput = true
      GIP.decodeInput(p, shareFromEnd: shareFromEnd, into: &state)
    default:
      break
    }
    if state != before { onState?(state) }
  }

  private func finish() {
    guard !closed else { return }
    if state != PadState() { onState?(PadState()) }  // release everything
    teardown()
    onDisconnect?()
  }

  private func teardown() {
    closed = true
    interface?.destroy()
    device?.destroy()
    inPipe = nil; outPipe = nil; interface = nil; device = nil
  }
}

/// Watches for supported controllers being plugged in.
final class PadMonitor {
  var onConnect: ((io_service_t, PadProtocol) -> Void)?
  private var port: IONotificationPortRef?
  private var iterator: io_iterator_t = 0

  func start(queue: DispatchQueue) {
    port = IONotificationPortCreate(kIOMainPortDefault)
    IONotificationPortSetDispatchQueue(port, queue)
    let context = Unmanaged.passUnretained(self).toOpaque()
    IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { context, iterator in
      Unmanaged<PadMonitor>.fromOpaque(context!).takeUnretainedValue().drain(iterator)
    }, context, &iterator)
    drain(iterator)
  }

  private func drain(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
      if let kind = PadMatcher.match(service) { onConnect?(service, kind) }
      IOObjectRelease(service)
    }
  }
}

enum Log {
  static var url: URL? = nil
  private static let lock = NSLock()
  static func write(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    lock.lock(); defer { lock.unlock() }
    FileHandle.standardError.write(line.data(using: .utf8)!)
    guard let url else { return }
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
      try? line.data(using: .utf8)!.write(to: url)
    }
  }
}
