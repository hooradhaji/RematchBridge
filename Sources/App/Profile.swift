import CoreGraphics
import Foundation

/// Controller inputs that can be mapped, by their profile name.
enum Input: String, CaseIterable {
  case a, b, x, y, lb, rb, lt, rt, ls, rs, view, menu, guide, share, up, down, left, right

  func isPressed(_ s: PadState, triggerThreshold: Double) -> Bool {
    switch self {
    case .a: s.a
    case .b: s.b
    case .x: s.x
    case .y: s.y
    case .lb: s.lb
    case .rb: s.rb
    case .lt: Double(s.lt) / 1023 >= triggerThreshold
    case .rt: Double(s.rt) / 1023 >= triggerThreshold
    case .ls: s.ls
    case .rs: s.rs
    case .view: s.view
    case .menu: s.menu
    case .guide: s.guide
    case .share: s.share
    case .up: s.up
    case .down: s.down
    case .left: s.left
    case .right: s.right
    }
  }
}

enum MouseButton: String {
  case left, right, middle
  var cg: CGMouseButton {
    switch self {
    case .left: .left
    case .right: .right
    case .middle: .center
    }
  }
}

/// What a button does. Written in profiles as a plain string:
/// a key chord ("space", "cmd+tab"), "mouse:left|right|middle", "toggle", or "none".
enum Action: Equatable {
  case key(KeyChord)
  case mouse(MouseButton)
  case toggleMapping
  case none

  static func parse(_ text: String) -> Action? {
    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
    if t.isEmpty || t == "none" { return Action.none }
    if t == "toggle" { return .toggleMapping }
    if t.hasPrefix("mouse:") {
      return MouseButton(rawValue: String(t.dropFirst(6))).map { .mouse($0) }
    }
    return KeyChord.parse(t).map { .key($0) }
  }
}

struct StickConfig: Codable, Equatable {
  enum Mode: String, Codable { case mouse, scroll, keys, none }
  var mode: Mode
  /// Mouse: 1.0 ≈ 1600 px/s at full tilt. Scroll: 1.0 ≈ 1500 px/s.
  var speed: Double? = nil
  /// Fraction of travel ignored around center (0...0.9).
  var deadzone: Double? = nil
  var invertY: Bool? = nil
  // Keys mode only.
  var up: String? = nil
  var down: String? = nil
  var left: String? = nil
  var right: String? = nil

  var effectiveSpeed: Double { max(0.05, min(speed ?? 1, 10)) }
  var effectiveDeadzone: Double { max(0, min(deadzone ?? 0.12, 0.9)) }
}

/// A profile as stored on disk (~/Library/Application Support/RematchBridge/Profiles/*.json).
struct ProfileFile: Codable {
  var name: String
  /// Bundle IDs of apps that switch to this profile automatically when they're in front.
  var apps: [String]? = nil
  var buttons: [String: String]
  var leftStick: StickConfig
  var rightStick: StickConfig
  /// How far a trigger must be pulled to count as pressed (0.05...1).
  var triggerThreshold: Double? = nil
  /// Inputs whose key repeats while held (like a real keyboard).
  var repeatKeys: [String]? = nil
}

/// A validated, ready-to-use profile.
struct Profile {
  let file: ProfileFile
  let url: URL?
  let actions: [Input: Action]
  let stickKeys: (left: [Input: KeyChord], right: [Input: KeyChord])
  let repeating: Set<Input>

  var name: String { file.name }
  var apps: [String] { file.apps ?? [] }
  var triggerThreshold: Double { max(0.05, min(file.triggerThreshold ?? 0.25, 1)) }

  /// Throws a readable description of every problem in the file.
  init(file: ProfileFile, url: URL?) throws {
    var problems: [String] = []
    var actions: [Input: Action] = [:]
    for (name, value) in file.buttons {
      guard let input = Input(rawValue: name.lowercased()) else {
        problems.append("unknown button \"\(name)\" (use: \(Input.allCases.map(\.rawValue).joined(separator: ", ")))")
        continue
      }
      guard let action = Action.parse(value) else {
        problems.append("\(name): can't understand \"\(value)\"")
        continue
      }
      actions[input] = action
    }
    func keys(_ stick: StickConfig, _ label: String) -> [Input: KeyChord] {
      guard stick.mode == .keys else { return [:] }
      var out: [Input: KeyChord] = [:]
      for (dir, value) in [(Input.up, stick.up), (.down, stick.down), (.left, stick.left), (.right, stick.right)] {
        guard let value, !value.isEmpty else { continue }
        if let chord = KeyChord.parse(value) { out[dir] = chord } else {
          problems.append("\(label).\(dir.rawValue): can't understand key \"\(value)\"")
        }
      }
      return out
    }
    let left = keys(file.leftStick, "leftStick"), right = keys(file.rightStick, "rightStick")
    var repeating = Set<Input>()
    for name in file.repeatKeys ?? [] {
      if let input = Input(rawValue: name.lowercased()) { repeating.insert(input) } else {
        problems.append("repeatKeys: unknown button \"\(name)\"")
      }
    }
    if !problems.isEmpty {
      throw NSError(domain: "RematchBridge", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "\(url?.lastPathComponent ?? file.name): " + problems.joined(separator: "; ")
      ])
    }
    self.file = file
    self.url = url
    self.actions = actions
    self.stickKeys = (left, right)
    self.repeating = repeating
  }
}

enum BuiltInProfiles {
  static let desktop = ProfileFile(
    name: "Desktop",
    buttons: [
      "a": "mouse:left", "b": "mouse:right", "x": "escape", "y": "return",
      "lb": "cmd+[", "rb": "cmd+]", "lt": "cmd+shift+tab", "rt": "cmd+tab",
      "ls": "none", "rs": "mouse:middle",
      "view": "cmd+space", "menu": "space", "share": "cmd+shift+4", "guide": "toggle",
      "up": "up", "down": "down", "left": "left", "right": "right",
    ],
    leftStick: StickConfig(mode: .mouse, speed: 1.0, deadzone: 0.1),
    rightStick: StickConfig(mode: .scroll, speed: 1.0, deadzone: 0.15),
    triggerThreshold: 0.35,
    repeatKeys: ["up", "down", "left", "right"]
  )

  /// RetroArch's default keyboard layout; most emulators can bind these keys too.
  static let emulator = ProfileFile(
    name: "Emulator",
    buttons: [
      "a": "x", "b": "z", "x": "s", "y": "a",
      "lb": "q", "rb": "w", "lt": "e", "rt": "r",
      "ls": "f", "rs": "g",
      "view": "rshift", "menu": "return", "share": "f1", "guide": "toggle",
      "up": "up", "down": "down", "left": "left", "right": "right",
    ],
    leftStick: StickConfig(mode: .keys, deadzone: 0.3, up: "up", down: "down", left: "left", right: "right"),
    rightStick: StickConfig(mode: .keys, deadzone: 0.3, up: "i", down: "k", left: "j", right: "l"),
    triggerThreshold: 0.25
  )

  /// Keyboard + mouse layout for PC games over Moonlight, Parsec, GeForce NOW, etc.
  static let streaming = ProfileFile(
    name: "Streaming (FPS)",
    buttons: [
      "a": "space", "b": "c", "x": "r", "y": "1",
      "lb": "q", "rb": "e", "lt": "mouse:right", "rt": "mouse:left",
      "ls": "shift", "rs": "v",
      "view": "tab", "menu": "escape", "share": "m", "guide": "toggle",
      "up": "2", "down": "3", "left": "4", "right": "5",
    ],
    leftStick: StickConfig(mode: .keys, deadzone: 0.25, up: "w", down: "s", left: "a", right: "d"),
    rightStick: StickConfig(mode: .mouse, speed: 1.6, deadzone: 0.1),
    triggerThreshold: 0.2
  )

  static let all = [desktop, emulator, streaming]
}

/// Loads and saves profiles in the user's Application Support folder.
final class ProfileStore {
  let folder: URL
  private(set) var profiles: [Profile] = []
  private(set) var errors: [String] = []

  init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    folder = base.appendingPathComponent("RematchBridge/Profiles", isDirectory: true)
  }

  func reload() {
    errors = []
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let existing = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
      .filter { $0.pathExtension.lowercased() == "json" } ?? []
    if existing.isEmpty { writeBuiltIns() }

    var loaded: [Profile] = []
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    for url in files {
      do {
        let file = try JSONDecoder().decode(ProfileFile.self, from: Data(contentsOf: url))
        loaded.append(try Profile(file: file, url: url))
      } catch let error as DecodingError {
        errors.append("\(url.lastPathComponent): \(Self.describe(error))")
      } catch {
        errors.append(error.localizedDescription)
      }
    }
    if loaded.isEmpty {
      // Never leave the user without a working profile.
      loaded = BuiltInProfiles.all.compactMap { try? Profile(file: $0, url: nil) }
    }
    profiles = loaded
    for e in errors { Log.write("profile error: \(e)") }
  }

  func writeBuiltIns() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for (i, p) in BuiltInProfiles.all.enumerated() {
      let url = folder.appendingPathComponent("\(i + 1) \(p.name).json")
      if let data = try? encoder.encode(p) { try? data.write(to: url) }
    }
  }

  /// Adds (or moves) `bundleID` to `profile`'s app list, removing it from the others.
  func assign(bundleID: String, to profile: Profile) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for p in profiles {
      guard let url = p.url else { continue }
      var file = p.file
      var apps = file.apps ?? []
      apps.removeAll { $0 == bundleID }
      if p.url == profile.url { apps.append(bundleID) }
      guard apps != (file.apps ?? []) else { continue }
      file.apps = apps.isEmpty ? nil : apps
      try encoder.encode(file).write(to: url)
    }
    reload()
  }

  /// Stops switching profiles automatically for `bundleID`.
  func unassign(bundleID: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for p in profiles {
      guard let url = p.url, p.apps.contains(bundleID) else { continue }
      var file = p.file
      let apps = (file.apps ?? []).filter { $0 != bundleID }
      file.apps = apps.isEmpty ? nil : apps
      try encoder.encode(file).write(to: url)
    }
    reload()
  }

  private static func describe(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, _): "missing \"\(key.stringValue)\""
    case .typeMismatch(_, let c), .valueNotFound(_, let c):
      "wrong value at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
    case .dataCorrupted(let c):
      c.codingPath.isEmpty ? "not valid JSON" : "bad value at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
    @unknown default: "unreadable"
    }
  }
}
