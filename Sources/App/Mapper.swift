import AppKit
import CoreGraphics

/// Turns controller state into keyboard and mouse events. Main thread only.
final class Mapper {
  var onEnabledChange: ((Bool) -> Void)?

  private(set) var enabled = true
  private(set) var profile: Profile

  private var state = PadState()
  private var down: Set<Input> = []
  private var stickDown: [Stick: Set<Input>] = [.left: [], .right: []]
  /// What each active source pressed, so release always matches the press.
  private var held: [Source: Action] = [:]
  private var modifierRefs: [CGKeyCode: Int] = [:]
  private var mouseHeld: [MouseButton: Int] = [:]
  private var repeatTimers: [Source: DispatchSourceTimer] = [:]
  private var tick: DispatchSourceTimer?
  private var lastTick = DispatchTime.now()
  private var mouseRemainder = CGPoint.zero
  private var scrollRemainder = CGPoint.zero
  private var lastClick: (button: MouseButton, time: TimeInterval, point: CGPoint, count: Int)?
  private let source = CGEventSource(stateID: .hidSystemState)

  enum Stick { case left, right }
  enum Source: Hashable {
    case button(Input)
    case stick(Stick, Input)
  }

  init(profile: Profile) {
    self.profile = profile
  }

  // MARK: - Control

  func setProfile(_ p: Profile) {
    releaseAll()
    profile = p
  }

  func setEnabled(_ on: Bool) {
    guard on != enabled else { return }
    if !on { releaseAll() }
    enabled = on
    if on { syncHeldToCurrentState() }
    onEnabledChange?(on)
  }

  /// Starts the 125 Hz loop that drives stick mouse/scroll movement.
  func start() {
    guard tick == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
    lastTick = .now()
    t.setEventHandler { [weak self] in self?.step() }
    t.resume()
    tick = t
  }

  func stop() {
    releaseAll()
    state = PadState()
    down = []
    tick?.cancel()
    tick = nil
  }

  // MARK: - Input

  func update(_ new: PadState) {
    let threshold = profile.triggerThreshold
    // The toggle button works even while mapping is off.
    for input in Input.allCases where profile.actions[input] == .toggleMapping {
      if input.isPressed(new, triggerThreshold: threshold), !input.isPressed(state, triggerThreshold: threshold) {
        setEnabled(!enabled)
      }
    }
    state = new
    guard enabled else { return }
    syncHeldToCurrentState()
  }

  private func syncHeldToCurrentState() {
    let threshold = profile.triggerThreshold
    for input in Input.allCases {
      let isDown = input.isPressed(state, triggerThreshold: threshold)
      guard isDown != down.contains(input) else { continue }
      if isDown { down.insert(input) } else { down.remove(input) }
      let action = profile.actions[input] ?? .none
      if action == .toggleMapping { continue }
      if isDown { press(.button(input), action) } else { release(.button(input)) }
    }
    updateStickKeys(.left, x: state.lx, y: state.ly, config: profile.file.leftStick, keys: profile.stickKeys.left)
    updateStickKeys(.right, x: state.rx, y: state.ry, config: profile.file.rightStick, keys: profile.stickKeys.right)
  }

  private func updateStickKeys(_ stick: Stick, x: Int16, y: Int16, config: StickConfig, keys: [Input: KeyChord]) {
    guard config.mode == .keys else { return }
    let pressAt = max(config.effectiveDeadzone, 0.3)
    let releaseAt = pressAt - 0.08
    let fx = Double(x) / 32767
    let fy = Double(y) / 32767 * (config.invertY == true ? -1 : 1)
    var active = stickDown[stick] ?? []
    let values: [(Input, Double)] = [(.up, fy), (.down, -fy), (.right, fx), (.left, -fx)]
    for (dir, v) in values {
      let isOn = active.contains(dir) ? v > releaseAt : v > pressAt
      guard isOn != active.contains(dir) else { continue }
      if isOn {
        active.insert(dir)
        if let chord = keys[dir] { press(.stick(stick, dir), .key(chord)) }
      } else {
        active.remove(dir)
        release(.stick(stick, dir))
      }
    }
    stickDown[stick] = active
  }

  // MARK: - Actions

  private func press(_ src: Source, _ action: Action) {
    guard held[src] == nil else { return }
    switch action {
    case .key(let chord):
      held[src] = action
      for m in modifierCodes(chord.modifiers) { modifierDown(m) }
      if Keys.flag(forModifierCode: chord.keyCode) != nil {
        modifierDown(chord.keyCode)
      } else {
        postKey(chord.keyCode, down: true)
        if case .button(let input) = src, profile.repeating.contains(input) { startRepeat(src, chord.keyCode) }
      }
    case .mouse(let button):
      held[src] = action
      mouseDown(button)
    case .toggleMapping, .none:
      break
    }
  }

  private func release(_ src: Source) {
    guard let action = held.removeValue(forKey: src) else { return }
    repeatTimers.removeValue(forKey: src)?.cancel()
    switch action {
    case .key(let chord):
      if Keys.flag(forModifierCode: chord.keyCode) != nil {
        modifierUp(chord.keyCode)
      } else {
        postKey(chord.keyCode, down: false)
      }
      for m in modifierCodes(chord.modifiers).reversed() { modifierUp(m) }
    case .mouse(let button):
      mouseUp(button)
    case .toggleMapping, .none:
      break
    }
  }

  func releaseAll() {
    for src in Array(held.keys) { release(src) }
    stickDown = [.left: [], .right: []]
    down = []
    mouseRemainder = .zero
    scrollRemainder = .zero
  }

  // MARK: - Keyboard

  private func modifierCodes(_ flags: CGEventFlags) -> [CGKeyCode] {
    var codes: [CGKeyCode] = []
    if flags.contains(.maskControl) { codes.append(0x3B) }
    if flags.contains(.maskAlternate) { codes.append(0x3A) }
    if flags.contains(.maskShift) { codes.append(0x38) }
    if flags.contains(.maskCommand) { codes.append(0x37) }
    if flags.contains(.maskSecondaryFn) { codes.append(0x3F) }
    return codes
  }

  private var heldFlags: CGEventFlags {
    var f: CGEventFlags = []
    for (code, n) in modifierRefs where n > 0 { if let flag = Keys.flag(forModifierCode: code) { f.insert(flag) } }
    return f
  }

  private func modifierDown(_ code: CGKeyCode) {
    let n = modifierRefs[code, default: 0]
    modifierRefs[code] = n + 1
    if n == 0 { postKey(code, down: true) }
  }

  private func modifierUp(_ code: CGKeyCode) {
    let n = modifierRefs[code, default: 0]
    guard n > 0 else { return }
    modifierRefs[code] = n - 1
    if n == 1 { postKey(code, down: false) }
  }

  private func postKey(_ code: CGKeyCode, down: Bool, autorepeat: Bool = false) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
    e.flags = heldFlags
    if autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    e.post(tap: .cghidEventTap)
  }

  private func startRepeat(_ src: Source, _ code: CGKeyCode) {
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(50))
    t.setEventHandler { [weak self] in self?.postKey(code, down: true, autorepeat: true) }
    t.resume()
    repeatTimers[src] = t
  }

  // MARK: - Mouse

  private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

  private func mouseDown(_ b: MouseButton) {
    let n = mouseHeld[b, default: 0]
    mouseHeld[b] = n + 1
    guard n == 0 else { return }
    let p = cursor
    let now = ProcessInfo.processInfo.systemUptime
    var count = 1
    if let last = lastClick, last.button == b, now - last.time <= NSEvent.doubleClickInterval,
      hypot(last.point.x - p.x, last.point.y - p.y) < 6
    {
      count = last.count + 1
    }
    lastClick = (b, now, p, count)
    postMouse(b, down: true, at: p, clickCount: count)
  }

  private func mouseUp(_ b: MouseButton) {
    let n = mouseHeld[b, default: 0]
    guard n > 0 else { return }
    mouseHeld[b] = n - 1
    guard n == 1 else { return }
    postMouse(b, down: false, at: cursor, clickCount: lastClick?.count ?? 1)
  }

  private func postMouse(_ b: MouseButton, down: Bool, at p: CGPoint, clickCount: Int) {
    let type: CGEventType
    switch b {
    case .left: type = down ? .leftMouseDown : .leftMouseUp
    case .right: type = down ? .rightMouseDown : .rightMouseUp
    case .middle: type = down ? .otherMouseDown : .otherMouseUp
    }
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: b.cg) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    if b == .middle { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
    e.flags = heldFlags
    e.post(tap: .cghidEventTap)
  }

  // MARK: - Analog loop

  private func step() {
    let now = DispatchTime.now()
    let dt = min(Double(now.uptimeNanoseconds - lastTick.uptimeNanoseconds) / 1e9, 0.05)
    lastTick = now
    guard enabled else { return }
    for (cfg, x, y) in [(profile.file.leftStick, state.lx, state.ly), (profile.file.rightStick, state.rx, state.ry)] {
      guard let v = shaped(x: x, y: y, config: cfg) else { continue }
      switch cfg.mode {
      case .mouse:
        let speed = 1600 * cfg.effectiveSpeed
        mouseRemainder.x += v.x * speed * dt
        mouseRemainder.y -= v.y * speed * dt  // screen Y grows downward
      case .scroll:
        let speed = 1500 * cfg.effectiveSpeed
        scrollRemainder.x -= v.x * speed * dt
        scrollRemainder.y += v.y * speed * dt
      case .keys, .none:
        break
      }
    }
    flushMouse()
    flushScroll()
  }

  /// Applies deadzone and a response curve; nil inside the deadzone.
  private func shaped(x: Int16, y: Int16, config: StickConfig) -> CGPoint? {
    guard config.mode == .mouse || config.mode == .scroll else { return nil }
    let fx = Double(x) / 32767
    let fy = Double(y) / 32767 * (config.invertY == true ? -1 : 1)
    let mag = min(hypot(fx, fy), 1)
    let dz = config.effectiveDeadzone
    guard mag > dz else { return nil }
    let n = (mag - dz) / (1 - dz)
    let curved = pow(n, 1.8)  // fine control near center, fast at the edge
    return CGPoint(x: fx / mag * curved, y: fy / mag * curved)
  }

  private func flushMouse() {
    let dx = mouseRemainder.x.rounded(.towardZero), dy = mouseRemainder.y.rounded(.towardZero)
    guard dx != 0 || dy != 0 else { return }
    mouseRemainder.x -= dx
    mouseRemainder.y -= dy
    var p = cursor
    p.x += dx
    p.y += dy
    p = clampToScreens(p)
    let type: CGEventType =
      mouseHeld[.left, default: 0] > 0 ? .leftMouseDragged
      : mouseHeld[.right, default: 0] > 0 ? .rightMouseDragged
      : mouseHeld[.middle, default: 0] > 0 ? .otherMouseDragged : .mouseMoved
    let button: CGMouseButton = type == .rightMouseDragged ? .right : type == .otherMouseDragged ? .center : .left
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    // Games with a captured cursor read these deltas rather than the position.
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
    e.flags = heldFlags
    e.post(tap: .cghidEventTap)
  }

  private func flushScroll() {
    let dx = scrollRemainder.x.rounded(.towardZero), dy = scrollRemainder.y.rounded(.towardZero)
    guard dx != 0 || dy != 0 else { return }
    scrollRemainder.x -= dx
    scrollRemainder.y -= dy
    guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                          wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
    e.flags = heldFlags
    e.post(tap: .cghidEventTap)
  }

  private func clampToScreens(_ p: CGPoint) -> CGPoint {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let rects = ids.map { CGDisplayBounds($0) }
    if rects.contains(where: { $0.contains(p) }) { return p }
    // Snap to the nearest point on the nearest display.
    var best = p, bestDist = Double.infinity
    for r in rects {
      let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
      let d = hypot(q.x - p.x, q.y - p.y)
      if d < bestDist { best = q; bestDist = d }
    }
    return best
  }
}
