import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let store = ProfileStore()
  private var mapper: Mapper!
  private let usbQueue = DispatchQueue(label: "rematchbridge.usb")
  private let monitor = PadMonitor()
  private let web = WebBridge()
  private let model = AppModel()
  private let hud = HUD()
  private lazy var window = MainWindowController(model: model)
  private let popover = NSPopover()
  private let fallbackMenu = NSMenu()
  private var rumbleGeneration = 0
  private var extensionTimer: Timer?
  private var extensionCheckRunning = false
  private var controllers: [UInt32: PadDevice] = [:]  // by USB location
  private var statusItem: NSStatusItem!
  private var trusted = AXIsProcessTrusted()
  private var trustTimer: Timer?
  /// The last app in front other than us, for "Always Use for…".
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
      self?.hud.show(on ? "Mapping On" : "Mapping Paused", symbol: on ? "play.circle.fill" : "pause.circle.fill")
      self?.refresh()
    }
    applyProfile(announce: false)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    fallbackMenu.delegate = self
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked(_:))
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

    let host = NSHostingController(rootView: PopoverView(model: model))
    host.sizingOptions = .preferredContentSize
    popover.contentViewController = host
    popover.behavior = .transient
    popover.animates = true

    wireModel()

    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(frontAppChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    if let front = NSWorkspace.shared.frontmostApplication, front != .current { lastApp = front }

    web.onFocusChange = { [weak self] focused in
      guard let self, focused != self.mapper.suppressed else { return }
      Log.write(focused ? "browser gamepad active" : "browser gamepad idle")
      self.mapper.setSuppressed(focused)
      self.refresh()
    }
    web.onPagesChange = { [weak self] pages in
      self?.model.browserPages = pages
      self?.checkExtension()
    }
    web.onRumble = { [weak self] strong, weak, duration in self?.rumble(strong: strong, weak: weak, duration: duration) }
    web.start()

    monitor.onConnect = { [weak self] service, kind in self?.connect(service, kind: kind) }
    monitor.start(queue: usbQueue)

    if UserDefaults.standard.object(forKey: "didOfferLogin") == nil {
      UserDefaults.standard.set(true, forKey: "didOfferLogin")
      setLaunchAtLogin(true)
    }
    requestAccessibility(prompt: false)  // logs the current state and keeps watching it
    refresh()
    checkExtension()
    extensionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkExtension() }
    // First run, or something still needs attention: show the setup window.
    if !UserDefaults.standard.bool(forKey: "didOnboard") || !trusted {
      UserDefaults.standard.set(true, forKey: "didOnboard")
      window.show()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    window.show()  // opening the app again from Finder/Spotlight shows the window
    return false
  }

  func applicationWillTerminate(_ notification: Notification) {
    mapper.stop()
    for c in controllers.values { c.close() }
  }

  private func wireModel() {
    model.setMappingEnabled = { [weak self] on in self?.mapper.setEnabled(on) }
    model.chooseProfile = { [weak self] name in self?.choose(profileNamed: name) }
    model.openAccessibility = { [weak self] in self?.requestAccessibility(prompt: true) }
    model.setUpBrowser = { [weak self] in self?.showExtension() }
    model.setLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on); self?.refresh() }
    model.editProfiles = { [weak self] in self?.closePopover(); self?.editProfiles() }
    model.reloadProfiles = { [weak self] in self?.reloadProfiles() }
    model.assignLastApp = { [weak self] name in self?.assignLastApp(to: name) }
    model.openWindow = { [weak self] in self?.closePopover(); self?.window.show(); self?.checkExtension() }
    model.openCloudGaming = { [weak self] in self?.closePopover(); self?.openInBrowser("https://www.xbox.com/play") }
    model.openBrowserExtensions = { [weak self] in
      self?.closePopover()
      self?.openInBrowser(self?.extensionsPageURL ?? "chrome://extensions")
    }
    model.openLog = { [weak self] in self?.closePopover(); self?.openLog() }
    model.quit = { NSApp.terminate(nil) }
    let setUp = model.setUpBrowser
    model.setUpBrowser = { [weak self] in self?.closePopover(); setUp() }
    let allow = model.openAccessibility
    model.openAccessibility = { [weak self] in self?.closePopover(); allow() }
  }

  // MARK: - Status item

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      // Right-click: the classic menu.
      closePopover()
      statusItem.menu = fallbackMenu
      sender.performClick(nil)
      statusItem.menu = nil
      return
    }
    if popover.isShown {
      closePopover()
    } else {
      refresh()
      checkExtension()
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  /// Re-reads whether the browser extension is installed (off the main thread).
  private func checkExtension() {
    guard !extensionCheckRunning else { return }
    extensionCheckRunning = true
    DispatchQueue.global(qos: .utility).async {
      let status = ExtensionDetector.detect()
      DispatchQueue.main.async {
        self.extensionCheckRunning = false
        if self.model.extensionStatus != status { self.model.extensionStatus = status }
      }
    }
  }

  private var detectedBrowserID: String {
    switch model.extensionStatus {
    case .installed(_, let id), .disabled(_, let id): return id
    case .notInstalled: return "com.google.Chrome"
    }
  }

  private var extensionsPageURL: String {
    switch detectedBrowserID {
    case "com.microsoft.edgemac": return "edge://extensions"
    case "com.brave.Browser": return "brave://extensions"
    default: return "chrome://extensions"
    }
  }

  /// Opens `url` in the browser that has the extension (Chrome if none).
  private func openInBrowser(_ url: String) {
    guard let target = URL(string: url) else { return }
    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: detectedBrowserID) {
      NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    } else {
      NSWorkspace.shared.open(target)
    }
  }

  private func closePopover() {
    if popover.isShown { popover.performClose(nil) }
  }

  private func assignLastApp(to profileName: String?) {
    guard let id = lastApp?.bundleIdentifier else { return }
    do {
      if let name = profileName, let p = store.profiles.first(where: { $0.name == name }) {
        try store.assign(bundleID: id, to: p)
      } else {
        try store.unassign(bundleID: id)
      }
      applyProfile(announce: false)
      refresh()
    } catch {
      alert("Couldn't save profile", error.localizedDescription)
    }
  }

  // MARK: - Controllers

  /// Called on the USB queue.
  private func connect(_ service: io_service_t, kind: PadProtocol) {
    let device = PadDevice(service: service, kind: kind, queue: usbQueue)
    let location = device.locationID
    device.onState = { [weak self] state in
      self?.web.publish(state)
      DispatchQueue.main.async {
        self?.mapper.update(state)
        self?.model.updatePad(state)
      }
    }
    device.onDisconnect = { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.controllers[location] === device else { return }
        self.controllers[location] = nil
        Log.write("disconnected: \(device.name)")
        if self.controllers.isEmpty {
          self.mapper.stop()
          self.web.publish(nil)
          self.model.pad = PadState()
        }
        self.hud.show("Controller Disconnected", symbol: "gamecontroller")
        self.refresh()
      }
    }
    device.start { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          if !(error is PadDevice.ResetInProgress) { Log.write("could not open \(device.name): \(error.localizedDescription)") }
          return
        }
        self.controllers[location]?.close()
        self.controllers[location] = device
        Log.write("connected: \(device.name) \(String(format: "%04x:%04x", device.vendorID, device.productID))")
        self.mapper.start()
        self.web.publish(PadState())
        self.hud.show("Controller Connected", symbol: "gamecontroller.fill")
        self.refresh()
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
    applyProfile(announce: true)
    refresh()
  }

  private var activeProfile: Profile {
    if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      let match = store.profiles.first(where: { $0.apps.contains(id) })
    {
      return match
    }
    return store.profiles.first { $0.name == chosenProfileName } ?? store.profiles[0]
  }

  private func applyProfile(announce: Bool) {
    let p = activeProfile
    guard p.name != mapper.profile.name || p.url != mapper.profile.url else { return }
    mapper.setProfile(p)
    Log.write("profile: \(p.name)")
    if announce, !controllers.isEmpty, !mapper.suppressed {
      hud.show(p.name, symbol: "slider.horizontal.3")
    }
    refresh()
  }

  private func choose(profileNamed name: String) {
    chosenProfileName = name
    if let p = store.profiles.first(where: { $0.name == name }) {
      mapper.setProfile(activeProfile)
      Log.write("profile: \(p.name) (chosen)")
    }
    refresh()
  }

  // MARK: - Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    // Status
    let name = controllers.values.first.map { AppModel.shortName($0.name) }
    let header = disabled(name ?? "No Controller", symbol: name == nil ? "gamecontroller" : "gamecontroller.fill")
    if #available(macOS 14.4, *) {
      header.subtitle = name == nil ? "Plug in your controller with a USB cable" : statusText
    }
    menu.addItem(header)
    if !trusted {
      menu.addItem(item("Allow Keyboard & Mouse Control…", #selector(openAccessibility), symbol: "exclamationmark.triangle.fill"))
    }
    menu.addItem(item("Open RematchBridge…", #selector(openWindow), key: ",", symbol: "macwindow"))

    // Mapping
    menu.addItem(.separator())
    let toggle = item(mapper.enabled ? "Pause Mapping" : "Resume Mapping", #selector(toggleMapping),
                      symbol: mapper.enabled ? "pause.circle" : "play.circle")
    if #available(macOS 14.4, *) { toggle.subtitle = "Or press the Xbox button" }
    menu.addItem(toggle)

    // Profiles
    menu.addItem(.separator())
    menu.addItem(NSMenuItem.sectionHeader(title: "Profile"))
    for p in store.profiles {
      let i = item(p.name, #selector(chooseProfile(_:)))
      i.representedObject = p.name
      i.state = p.name == mapper.profile.name ? .on : .off
      if #available(macOS 14.4, *), !p.apps.isEmpty { i.subtitle = "Auto: " + appNames(p.apps) }
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
      assign.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
      assign.submenu = sub
      menu.addItem(assign)
    }
    if !store.errors.isEmpty {
      menu.addItem(item("\(store.errors.count) Profile Error(s)…", #selector(showProfileErrors), symbol: "exclamationmark.triangle"))
    }
    menu.addItem(item("Edit Profiles…", #selector(editProfilesAction), symbol: "square.and.pencil"))
    menu.addItem(item("Reload Profiles", #selector(reloadProfiles), symbol: "arrow.clockwise"))

    // Browser
    menu.addItem(.separator())
    if model.browserPages.isEmpty {
      menu.addItem(item("Set Up Browser Gamepad…", #selector(showExtensionAction), symbol: "globe"))
    } else {
      let b = disabled("Browser Gamepad: " + model.browserPages.joined(separator: ", "), symbol: "globe")
      menu.addItem(b)
    }

    // App
    menu.addItem(.separator())
    let login = item("Open at Login", #selector(toggleLogin))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    menu.addItem(item("Open Log", #selector(openLog)))
    menu.addItem(item("Quit RematchBridge", #selector(quit), key: "q"))
  }

  private var statusText: String {
    if mapper.suppressed { return "Browser gamepad" }
    if !trusted { return "Needs permission" }
    return mapper.enabled ? "Active · \(mapper.profile.name)" : "Paused"
  }

  private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.target = self
    if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    return i
  }

  private func disabled(_ title: String, symbol: String? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    return i
  }

  private func appNames(_ ids: [String]) -> String {
    ids.map { id in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }.joined(separator: ", ")
  }

  /// Updates the menu-bar icon and the window's model.
  private func refresh() {
    let connected = !controllers.isEmpty
    if let button = statusItem?.button {
      let image = NSImage(systemSymbolName: connected ? "gamecontroller.fill" : "gamecontroller",
                          accessibilityDescription: "RematchBridge")
      image?.isTemplate = true
      button.image = image
      button.appearsDisabled = !connected || (!mapper.suppressed && (!mapper.enabled || !trusted))
      button.toolTip = connected ? "RematchBridge — \(statusText)" : "RematchBridge — no controller"
    }
    model.controllerName = controllers.values.first.map { AppModel.shortName($0.name) }
    model.accessibilityGranted = trusted
    model.mappingEnabled = mapper.enabled
    model.browserActive = mapper.suppressed
    model.profileNames = store.profiles.map(\.name)
    model.activeProfile = mapper.profile.name
    model.chosenProfile = store.profiles.contains { $0.name == chosenProfileName } ? chosenProfileName : store.profiles[0].name
    model.launchAtLogin = SMAppService.mainApp.status == .enabled
    var apps: [String: String] = [:]
    for p in store.profiles where !p.apps.isEmpty { apps[p.name] = appNames(p.apps) }
    model.profileApps = apps
    model.lastAppName = lastApp?.localizedName
    model.lastAppProfile = lastApp?.bundleIdentifier.flatMap { id in store.profiles.first { $0.apps.contains(id) }?.name }
    model.profileErrorCount = store.errors.count
  }

  // MARK: - Actions

  @objc private func openWindow() { window.show() }

  @objc private func toggleMapping() { mapper.setEnabled(!mapper.enabled) }

  @objc private func chooseProfile(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    choose(profileNamed: name)
  }

  @objc private func assignProfile(_ sender: NSMenuItem) {
    guard let pair = sender.representedObject as? [String], pair.count == 2,
      let p = store.profiles.first(where: { $0.name == pair[0] })
    else { return }
    do {
      try store.assign(bundleID: pair[1], to: p)
      applyProfile(announce: false)
      refresh()
    } catch {
      alert("Couldn't save profile", error.localizedDescription)
    }
  }

  @objc private func editProfilesAction() { editProfiles() }

  private func editProfiles() {
    let readme = store.folder.appendingPathComponent("README.txt")
    try? Self.readme.write(to: readme, atomically: true, encoding: .utf8)
    NSWorkspace.shared.open(store.folder)
  }

  @objc private func reloadProfiles() {
    store.reload()
    mapper.setProfile(activeProfile)
    refresh()
    if store.errors.isEmpty {
      hud.show("Profiles Reloaded", symbol: "arrow.clockwise")
    } else {
      showProfileErrors()
    }
  }

  @objc private func showProfileErrors() {
    alert("Some profiles couldn't be loaded", store.errors.joined(separator: "\n\n"))
  }

  @objc private func toggleLogin() {
    setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    refresh()
  }

  private func setLaunchAtLogin(_ on: Bool) {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      Log.write("launch at login: \(error.localizedDescription)")
    }
  }

  @objc private func showExtensionAction() { showExtension() }

  private func showExtension() {
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
    alert("Set up the browser gamepad",
      """
      1. In Chrome's Extensions page (just opened), turn on Developer mode (top right).
      2. Click "Load unpacked". In the folder picker press Cmd+Shift+G, paste (Cmd+V), press Return, then click Select. The folder's location is already on your clipboard.
      3. Open (or reload) xbox.com/play. Your controller appears as an Xbox controller, with rumble.

      Keyboard & mouse mapping pauses automatically while that tab is in front.
      """)
  }

  @objc private func openLog() {
    if let url = Log.url { NSWorkspace.shared.open(url) }
  }

  @objc private func openAccessibility() { requestAccessibility(prompt: true) }

  @objc private func quit() { NSApp.terminate(nil) }

  /// What macOS currently allows: Accessibility, and posting keyboard/mouse events.
  private static func permissions() -> (accessibility: Bool, postEvents: Bool) {
    (AXIsProcessTrusted(), CGPreflightPostEventAccess())
  }

  private func requestAccessibility(prompt: Bool) {
    if prompt {
      if !Self.permissions().accessibility {
        // A stale entry (from an older build's signature) shows as "on" in System Settings
        // but never matches, and macOS won't prompt again while it exists. Clear only our
        // own entry so the current build can register cleanly.
        resetOwnAccessibilityEntry()
      }
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      _ = CGRequestPostEventAccess()  // registers the event-posting permission too
      if !Self.permissions().accessibility {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
      }
    }
    checkPermissions()
    guard trustTimer == nil else { return }
    // Keep watching: permissions can be granted or revoked at any time in System Settings.
    trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkPermissions() }
  }

  private func resetOwnAccessibilityEntry() {
    guard let id = Bundle.main.bundleIdentifier else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    task.arguments = ["reset", "Accessibility", id]
    do {
      try task.run()
      task.waitUntilExit()
      Log.write("reset stale Accessibility entry for \(id) (exit \(task.terminationStatus))")
    } catch {
      Log.write("could not reset Accessibility entry: \(error.localizedDescription)")
    }
  }

  private var lastPermissions: (accessibility: Bool, postEvents: Bool)?

  private func checkPermissions() {
    let now = Self.permissions()
    let changed = lastPermissions.map { $0 != now } ?? true
    let wasTrusted = trusted
    lastPermissions = now
    trusted = now.accessibility || now.postEvents
    guard changed else { return }
    Log.write("permissions: accessibility=\(now.accessibility) postEvents=\(now.postEvents)")
    if trusted, !wasTrusted {
      hud.show("Keyboard & Mouse Ready", symbol: "checkmark.circle.fill")
    }
    refresh()
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
