import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let store = ProfileStore()
  private var mapper: Mapper!
  private let usbQueue = DispatchQueue(label: "rematchbridge.usb")
  private let monitor = GIPMonitor()
  private let web = WebBridge()
  private var rumbleGeneration = 0
  private var controllers: [UInt32: GIPDevice] = [:]  // by USB location
  private var statusItem: NSStatusItem!
  private var trusted = AXIsProcessTrusted()
  private var trustTimer: Timer?
  /// The last app in front other than us, for "Use profile for…".
  private var lastApp: NSRunningApplication?
  /// The profile the user picked; app-specific profiles override it while their app is in front.
  private var chosenProfileName: String {
    get { UserDefaults.standard.string(forKey: "profile") ?? BuiltInProfiles.desktop.name }
    set { UserDefaults.standard.set(newValue, forKey: "profile") }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/RematchBridge.log")
    Log.url = logs
    Log.write("RematchBridge \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") starting")

    store.reload()
    mapper = Mapper(profile: store.profiles[0])
    mapper.onEnabledChange = { [weak self] on in
      Log.write("mapping \(on ? "enabled" : "paused")")
      self?.refreshIcon()
    }
    applyProfile()

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    refreshIcon()

    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(frontAppChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    if let front = NSWorkspace.shared.frontmostApplication, front != .current { lastApp = front }

    web.onFocusChange = { [weak self] focused in
      guard let self else { return }
      if focused != self.mapper.suppressed { Log.write(focused ? "browser gamepad active" : "browser gamepad idle") }
      self.mapper.setSuppressed(focused)
      self.refreshIcon()
    }
    web.onRumble = { [weak self] strong, weak, duration in self?.rumble(strong: strong, weak: weak, duration: duration) }
    web.start()

    monitor.onConnect = { [weak self] service in self?.connect(service) }
    monitor.start(queue: usbQueue)

    if !trusted { requestAccessibility(prompt: true) }
    if UserDefaults.standard.object(forKey: "didOfferLogin") == nil {
      UserDefaults.standard.set(true, forKey: "didOfferLogin")
      setLaunchAtLogin(true)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    mapper.stop()
    for c in controllers.values { c.close() }
  }

  // MARK: - Controllers

  /// Called on the USB queue.
  private func connect(_ service: io_service_t) {
    let device = GIPDevice(service: service, queue: usbQueue)
    let location = device.locationID
    device.onState = { [weak self] state in
      self?.web.publish(state)
      DispatchQueue.main.async { self?.mapper.update(state) }
    }
    device.onDisconnect = { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.controllers[location] === device else { return }
        self.controllers[location] = nil
        Log.write("disconnected: \(device.name)")
        if self.controllers.isEmpty {
          self.mapper.stop()
          self.web.publish(nil)
        }
        self.refreshIcon()
      }
    }
    device.start { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          if !(error is GIPDevice.ResetInProgress) { Log.write("could not open \(device.name): \(error.localizedDescription)") }
          return
        }
        self.controllers[location]?.close()
        self.controllers[location] = device
        Log.write("connected: \(device.name) \(String(format: "%04x:%04x", device.vendorID, device.productID))")
        self.mapper.start()
        self.web.publish(PadState())
        self.refreshIcon()
      }
    }
  }

  /// Browser rumble: magnitudes 0...1, stops after `duration` seconds.
  private func rumble(strong: Double, weak: Double, duration: Double) {
    rumbleGeneration += 1
    let gen = rumbleGeneration
    let s = UInt8((strong * 100).rounded()), w = UInt8((weak * 100).rounded())
    for c in controllers.values { c.rumble(strong: s, weak: w) }
    guard s > 0 || w > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0.05)) { [weak self] in
      guard let self, self.rumbleGeneration == gen else { return }
      for c in self.controllers.values { c.rumble(strong: 0, weak: 0) }
    }
  }

  // MARK: - Profiles

  @objc private func frontAppChanged(_ note: Notification) {
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    if app != .current { lastApp = app }
    applyProfile()
  }

  private var activeProfile: Profile {
    if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      let match = store.profiles.first(where: { $0.apps.contains(id) })
    {
      return match
    }
    return store.profiles.first { $0.name == chosenProfileName } ?? store.profiles[0]
  }

  private func applyProfile() {
    let p = activeProfile
    guard p.name != mapper.profile.name || p.url != mapper.profile.url else { return }
    mapper.setProfile(p)
    Log.write("profile: \(p.name)")
  }

  // MARK: - Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    if controllers.isEmpty {
      menu.addItem(disabled("No controller — plug in your Rematch"))
    } else {
      for c in controllers.values { menu.addItem(disabled("● \(c.name)")) }
    }
    if !trusted {
      menu.addItem(.separator())
      menu.addItem(item("⚠︎ Allow Accessibility so buttons work…", #selector(openAccessibility)))
    }

    if mapper.suppressed {
      menu.addItem(disabled("● Browser gamepad in use (keys paused)"))
    }

    menu.addItem(.separator())
    let toggle = item(mapper.enabled ? "Mapping On" : "Mapping Paused", #selector(toggleMapping), key: "")
    toggle.state = mapper.enabled ? .on : .off
    menu.addItem(toggle)
    menu.addItem(disabled("Press the Xbox button to pause/resume"))

    menu.addItem(.separator())
    let active = mapper.profile
    menu.addItem(disabled("Profile"))
    for p in store.profiles {
      let i = item(p.name + (p.apps.isEmpty ? "" : "  (\(appNames(p.apps)))"), #selector(chooseProfile(_:)))
      i.representedObject = p.name
      i.state = p.name == active.name ? .on : .off
      i.indentationLevel = 1
      menu.addItem(i)
    }
    if let app = lastApp, let id = app.bundleIdentifier {
      let sub = NSMenu()
      for p in store.profiles where p.url != nil {
        let i = item(p.name, #selector(assignProfile(_:)))
        i.representedObject = [p.name, id]
        i.state = p.apps.contains(id) ? .on : .off
        sub.addItem(i)
      }
      let assign = NSMenuItem(title: "Always Use for “\(app.localizedName ?? id)”", action: nil, keyEquivalent: "")
      assign.submenu = sub
      menu.addItem(assign)
    }
    if !store.errors.isEmpty {
      menu.addItem(item("⚠︎ \(store.errors.count) profile error(s) — Show", #selector(showProfileErrors)))
    }
    menu.addItem(item("Edit Profiles…", #selector(editProfiles)))
    menu.addItem(item("Reload Profiles", #selector(reloadProfiles)))

    menu.addItem(item("Set Up Browser Gamepad (Xbox Cloud)…", #selector(showExtension)))

    menu.addItem(.separator())
    let login = item("Launch at Login", #selector(toggleLogin))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    menu.addItem(item("Open Log", #selector(openLog)))
    menu.addItem(item("Quit RematchBridge", #selector(quit), key: "q"))
  }

  private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.target = self
    return i
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
  }

  private func appNames(_ ids: [String]) -> String {
    ids.map { id in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }.joined(separator: ", ")
  }

  private func refreshIcon() {
    guard let button = statusItem?.button else { return }
    let connected = !controllers.isEmpty
    let name = connected ? "gamecontroller.fill" : "gamecontroller"
    let image = NSImage(systemSymbolName: name, accessibilityDescription: "RematchBridge")
    image?.isTemplate = true
    button.image = image
    button.appearsDisabled = !connected || (!mapper.enabled && !mapper.suppressed) || (!trusted && !mapper.suppressed)
    button.toolTip = !connected ? "RematchBridge: no controller"
      : mapper.suppressed ? "RematchBridge: browser gamepad"
      : !trusted ? "RematchBridge: needs Accessibility permission"
      : mapper.enabled ? "RematchBridge: \(mapper.profile.name)" : "RematchBridge: paused"
  }

  // MARK: - Actions

  @objc private func toggleMapping() { mapper.setEnabled(!mapper.enabled) }

  @objc private func chooseProfile(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    chosenProfileName = name
    if let p = store.profiles.first(where: { $0.name == name }) {
      mapper.setProfile(p)
      Log.write("profile: \(p.name) (chosen)")
    }
    refreshIcon()
  }

  @objc private func assignProfile(_ sender: NSMenuItem) {
    guard let pair = sender.representedObject as? [String], pair.count == 2,
      let p = store.profiles.first(where: { $0.name == pair[0] })
    else { return }
    do {
      try store.assign(bundleID: pair[1], to: p)
      applyProfile()
    } catch {
      alert("Couldn't save profile", error.localizedDescription)
    }
  }

  @objc private func editProfiles() {
    let readme = store.folder.appendingPathComponent("README.txt")
    try? Self.readme.write(to: readme, atomically: true, encoding: .utf8)
    NSWorkspace.shared.open(store.folder)
  }

  @objc private func reloadProfiles() {
    store.reload()
    mapper.setProfile(activeProfile)
    if !store.errors.isEmpty { showProfileErrors() }
  }

  @objc private func showProfileErrors() {
    alert("Some profiles couldn't be loaded", store.errors.joined(separator: "\n\n"))
  }

  @objc private func toggleLogin() {
    setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
  }

  private func setLaunchAtLogin(_ on: Bool) {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      Log.write("launch at login: \(error.localizedDescription)")
    }
  }

  @objc private func showExtension() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RematchBridge/Chrome Extension", isDirectory: true)
    // Copy out of the app bundle so the folder Chrome loads survives app updates.
    if let bundled = Bundle.main.url(forResource: "Extension", withExtension: nil) {
      try? FileManager.default.removeItem(at: support)
      try? FileManager.default.copyItem(at: bundled, to: support)
    }
    // The folder is inside the hidden Library folder, so hand over the path for Cmd+Shift+G.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(support.path, forType: .string)
    if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
      let url = URL(string: "chrome://extensions")
    {
      NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }
    alert("Browser gamepad for Xbox Cloud Gaming",
      """
      1. In Chrome's Extensions page (just opened), turn on Developer mode (top right).
      2. Click "Load unpacked". In the folder picker press Cmd+Shift+G, paste (Cmd+V), press Return, then click Select.
         (The folder's location is already on your clipboard.)
      3. Open xbox.com/play. Your controller appears as an Xbox controller, with rumble.

      Keyboard/mouse mapping pauses automatically while that tab is in front.
      Works on: xbox.com, play.geforcenow.com, hardwaretester.com/gamepad (for testing).
      """)
  }

  @objc private func openLog() {
    if let url = Log.url { NSWorkspace.shared.open(url) }
  }

  @objc private func openAccessibility() { requestAccessibility(prompt: true) }

  @objc private func quit() { NSApp.terminate(nil) }

  private func requestAccessibility(prompt: Bool) {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    trusted = AXIsProcessTrustedWithOptions(options)
    if prompt, !trusted {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    guard !trusted, trustTimer == nil else { return }
    trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
      guard let self, AXIsProcessTrusted() else { return }
      self.trusted = true
      t.invalidate()
      self.trustTimer = nil
      Log.write("accessibility granted")
      self.refreshIcon()
    }
    refreshIcon()
  }

  private func alert(_ title: String, _ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.runModal()
  }

  static let readme = """
    RematchBridge profiles
    ======================

    Each .json file here is one profile. Edit with any text editor, then choose
    "Reload Profiles" from the menu-bar icon. Delete all files to get the
    built-in profiles back.

    BUTTON NAMES
      a b x y  lb rb  lt rt (triggers)  ls rs (stick clicks)
      view menu guide share  up down left right (D-pad)
      The back paddles send whatever you set in Turtle Beach Control Hub
      (A and B by default).

    ACTIONS (the value for a button)
      A key:         "space", "w", "return", "escape", "tab", "f5", "up" ...
      A shortcut:    "cmd+tab", "cmd+shift+4", "ctrl+left"
      A modifier:    "shift", "ctrl", "opt", "cmd"
      Mouse:         "mouse:left", "mouse:right", "mouse:middle"
      Pause/resume:  "toggle"
      Nothing:       "none"
      Keys: a-z 0-9 return tab space delete escape forwarddelete home end
            pageup pagedown left right up down f1-f12 keypad0-keypad9
            - = [ ] ; ' , . / \\ ` volumeup volumedown mute

    STICKS ("leftStick" / "rightStick")
      { "mode": "mouse",  "speed": 1.0, "deadzone": 0.1 }
      { "mode": "scroll", "speed": 1.0, "deadzone": 0.15 }
      { "mode": "keys", "up": "w", "down": "s", "left": "a", "right": "d", "deadzone": 0.25 }
      { "mode": "none" }
      Optional: "invertY": true

    OTHER
      "triggerThreshold": 0.25   how far to pull LT/RT to count as pressed
      "repeatKeys": ["up","down"] keys that auto-repeat while held
      "apps": ["com.example.app"] use this profile automatically when that
                                  app is in front (or use "Always Use for…"
                                  in the menu)
    """
}
