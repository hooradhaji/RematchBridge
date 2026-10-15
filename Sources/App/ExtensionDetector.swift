import Foundation

/// Finds out whether the RematchBridge browser extension is installed, by reading the
/// browsers' own profile settings (read-only). This survives restarts, unlike the live
/// connection, which only exists while a game tab is open.
enum ExtensionStatus: Equatable {
  case notInstalled
  case installed(browser: String, bundleID: String)
  case disabled(browser: String, bundleID: String)
}

enum ExtensionDetector {
  static let extensionName = "RematchBridge Gamepad"

  private static let browsers: [(name: String, folder: String, bundleID: String)] = [
    ("Chrome", "Google/Chrome", "com.google.Chrome"),
    ("Edge", "Microsoft Edge", "com.microsoft.edgemac"),
    ("Brave", "BraveSoftware/Brave-Browser", "com.brave.Browser"),
    ("Arc", "Arc/User Data", "company.thebrowser.Browser"),
    ("Chromium", "Chromium", "org.chromium.Chromium"),
  ]

  /// Blocking file reads; call off the main thread.
  static func detect() -> ExtensionStatus {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var disabled: ExtensionStatus?
    for browser in browsers {
      let root = support.appendingPathComponent(browser.folder, isDirectory: true)
      guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
      for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
        for file in ["Secure Preferences", "Preferences"] {
          let url = root.appendingPathComponent(profile).appendingPathComponent(file)
          guard let entries = extensionEntries(url) else { continue }
          for entry in entries where isOurs(entry) {
            if isEnabled(entry) { return .installed(browser: browser.name, bundleID: browser.bundleID) }
            disabled = disabled ?? .disabled(browser: browser.name, bundleID: browser.bundleID)
          }
        }
      }
    }
    return disabled ?? .notInstalled
  }

  private static func extensionEntries(_ url: URL) -> [[String: Any]]? {
    guard let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any]
    else { return nil }
    return settings.values.compactMap { $0 as? [String: Any] }
  }

  private static func isOurs(_ entry: [String: Any]) -> Bool {
    if let manifest = entry["manifest"] as? [String: Any], manifest["name"] as? String == extensionName { return true }
    // Unpacked extensions keep only their folder path; read the manifest from there.
    guard let path = entry["path"] as? String, path.hasPrefix("/"),
      let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("manifest.json")),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return manifest["name"] as? String == extensionName
  }

  private static func isEnabled(_ entry: [String: Any]) -> Bool {
    if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return false }
    if let reasons = entry["disable_reasons"] as? Int, reasons != 0 { return false }
    if let state = entry["state"] as? Int, state == 0 { return false }
    return true
  }
}
