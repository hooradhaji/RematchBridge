import Combine
import Foundation

/// Observable state for the RematchBridge window. Main thread only.
final class AppModel: ObservableObject {
  @Published var controllerName: String?
  @Published var pad = PadState()
  @Published var accessibilityGranted = false
  @Published var browserPages: [String] = []  // origins of connected pages, e.g. "xbox.com"
  @Published var mappingEnabled = true
  @Published var browserActive = false
  @Published var profileNames: [String] = []
  @Published var activeProfile = ""
  @Published var chosenProfile = ""
  @Published var launchAtLogin = false
  /// Profile → app names that switch to it automatically.
  @Published var profileApps: [String: String] = [:]
  /// The last app in front (other than us), for "Always use for…".
  @Published var lastAppName: String?
  @Published var lastAppProfile: String?
  @Published var profileErrorCount = 0
  @Published var extensionStatus: ExtensionStatus = .notInstalled

  /// One line about the browser gamepad, for the panel and the window.
  var browserSummary: (text: String, ok: Bool) {
    if !browserPages.isEmpty { return ("Connected · " + browserPages.joined(separator: ", "), true) }
    switch extensionStatus {
    case .installed(let browser, _): return ("Installed in \(browser) · open Xbox Cloud to play", true)
    case .disabled(let browser, _): return ("Turned off in \(browser)'s extensions", false)
    case .notInstalled: return ("For Xbox Cloud Gaming & GeForce NOW", false)
    }
  }

  // Actions the window can trigger; wired up by the app delegate.
  var setMappingEnabled: (Bool) -> Void = { _ in }
  var chooseProfile: (String) -> Void = { _ in }
  var openAccessibility: () -> Void = {}
  var setUpBrowser: () -> Void = {}
  var setLaunchAtLogin: (Bool) -> Void = { _ in }
  var editProfiles: () -> Void = {}
  var reloadProfiles: () -> Void = {}
  var assignLastApp: (String?) -> Void = { _ in }  // nil = stop using a fixed profile for it
  var openWindow: () -> Void = {}
  var openCloudGaming: () -> Void = {}
  var openBrowserExtensions: () -> Void = {}
  var openLog: () -> Void = {}
  var quit: () -> Void = {}

  /// "Xbox Rematch Advanced Wired Controller- Dark Cosmos Reveal" → "Rematch Advanced Wired"
  static func shortName(_ usbName: String) -> String {
    var name = usbName.components(separatedBy: "-").first?.trimmingCharacters(in: .whitespaces) ?? usbName
    // Drop the generic words only when at least two descriptive words remain.
    func words(_ s: String) -> Int { s.split(separator: " ").count }
    if name.hasPrefix("Xbox "), words(name) >= 3 { name.removeFirst(5) }
    if name.hasSuffix(" Controller"), words(name) >= 3 { name.removeLast(11) }
    return name.isEmpty ? usbName : name
  }

  // Pad updates arrive up to ~250 Hz; the UI only needs ~60.
  private var pendingPad: PadState?
  func updatePad(_ s: PadState) {
    let scheduled = pendingPad != nil
    pendingPad = s
    guard !scheduled else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
      guard let self, let p = self.pendingPad else { return }
      self.pendingPad = nil
      if p != self.pad { self.pad = p }
    }
  }
}
