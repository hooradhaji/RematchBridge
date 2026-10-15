import AppKit
import SwiftUI

/// The RematchBridge window: setup checklist, live controller view, profile and mapping controls.
struct MainView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      ControllerView(pad: model.pad, connected: model.controllerName != nil)
        .frame(height: 210)
        .frame(maxWidth: .infinity)
      setup
      controls
    }
    .padding(22)
    .frame(width: 480)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
      VStack(alignment: .leading, spacing: 2) {
        Text("RematchBridge").font(.title2.weight(.semibold))
        Text(model.controllerName ?? "No controller connected")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      statusBadge
    }
  }

  private var statusBadge: some View {
    let (text, color): (String, Color) =
      model.controllerName == nil ? ("Waiting", .secondary)
      : model.browserActive ? ("Browser", .blue)
      : !model.mappingEnabled ? ("Paused", .orange)
      : ("Active", .green)
    return Text(text)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(Capsule().fill(color.opacity(0.15)))
      .foregroundStyle(color)
  }

  private var setup: some View {
    VStack(spacing: 0) {
        SetupRow(
          symbol: "cable.connector", title: "Controller",
          detail: model.controllerName.map { "Connected over USB — \($0)" } ?? "Plug in your controller with a USB cable",
          ok: model.controllerName != nil)
        Divider().padding(.leading, 36)
        SetupRow(
          symbol: "keyboard", title: "Keyboard & mouse",
          detail: model.accessibilityGranted
            ? "Allowed in Accessibility"
            : "Turn on RematchBridge in Accessibility. Already on? Select it, click −, then allow again.",
          ok: model.accessibilityGranted,
          action: model.accessibilityGranted ? nil : ("Allow…", model.openAccessibility))
        Divider().padding(.leading, 36)
        SetupRow(
          symbol: "globe", title: "Browser gamepad",
          detail: model.browserSummary.text,
          ok: model.browserSummary.ok, optional: true,
          action: {
            switch model.extensionStatus {
            case .installed: return model.browserPages.isEmpty ? ("Play", model.openCloudGaming) : nil
            case .disabled: return ("Turn On…", model.openBrowserExtensions)
            case .notInstalled: return ("Set Up…", model.setUpBrowser)
            }
          }())
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Profile").frame(width: 92, alignment: .leading)
        Picker("", selection: Binding(get: { model.chosenProfile }, set: { model.chooseProfile($0) })) {
          ForEach(model.profileNames, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        Button("Edit…", action: model.editProfiles)
        Spacer()
      }
      if model.activeProfile != model.chosenProfile, !model.activeProfile.isEmpty {
        Text("“\(model.activeProfile)” is in use for the app in front.")
          .font(.caption).foregroundStyle(.secondary).padding(.leading, 92)
      }
      HStack {
        Text("Mapping").frame(width: 92, alignment: .leading)
        Toggle("", isOn: Binding(get: { model.mappingEnabled }, set: { model.setMappingEnabled($0) }))
          .toggleStyle(.switch).labelsHidden()
        Text(model.browserActive ? "Paused while a game tab is in front" : "Press the Xbox button to pause or resume")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      HStack {
        Text("Startup").frame(width: 92, alignment: .leading)
        Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Spacer()
      }
    }
  }
}

private struct SetupRow: View {
  let symbol: String
  let title: String
  let detail: String
  let ok: Bool
  var optional = false
  var action: (String, () -> Void)? = nil

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 8)
      if let action { Button(action.0, action: action.1).controlSize(.small) }
      Image(systemName: ok ? "checkmark.circle.fill" : optional ? "circle.dashed" : "exclamationmark.circle.fill")
        .foregroundStyle(ok ? .green : optional ? .secondary : .orange)
        .font(.title3)
    }
    .padding(.vertical, 8)
  }
}

/// A schematic controller that mirrors live input.
struct ControllerView: View {
  let pad: PadState
  let connected: Bool

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      let cx = w / 2
      ZStack {
        // Triggers
        TriggerBar(label: "LT", value: Double(pad.lt) / 1023).position(x: cx - 130, y: 12)
        TriggerBar(label: "RT", value: Double(pad.rt) / 1023).position(x: cx + 130, y: 12)
        // Bumpers
        Pill(label: "LB", on: pad.lb).position(x: cx - 130, y: 40)
        Pill(label: "RB", on: pad.rb).position(x: cx + 130, y: 40)
        // Body
        RoundedRectangle(cornerRadius: 60, style: .continuous)
          .fill(Color.primary.opacity(0.06))
          .overlay(RoundedRectangle(cornerRadius: 60, style: .continuous).stroke(Color.primary.opacity(0.12)))
          .frame(width: 360, height: 150)
          .position(x: cx, y: h - 80)
        // Sticks
        Stick(x: pad.lx, y: pad.ly, pressed: pad.ls).position(x: cx - 110, y: h - 108)
        Stick(x: pad.rx, y: pad.ry, pressed: pad.rs).position(x: cx + 55, y: h - 52)
        // D-pad
        DPad(pad: pad).position(x: cx - 55, y: h - 52)
        // Face buttons
        Face(label: "Y", color: .yellow, on: pad.y).position(x: cx + 110, y: h - 132)
        Face(label: "X", color: .blue, on: pad.x).position(x: cx + 84, y: h - 108)
        Face(label: "B", color: .red, on: pad.b).position(x: cx + 136, y: h - 108)
        Face(label: "A", color: .green, on: pad.a).position(x: cx + 110, y: h - 84)
        // Center
        Glyph(symbol: "rectangle.on.rectangle", on: pad.view).position(x: cx - 30, y: h - 108)
        Glyph(symbol: "line.3.horizontal", on: pad.menu).position(x: cx + 30, y: h - 108)
        Glyph(symbol: "xbox.logo", fallback: "circle.circle", on: pad.guide, size: 30).position(x: cx, y: h - 132)
        Glyph(symbol: "square.and.arrow.up", on: pad.share, size: 20).position(x: cx, y: h - 96)
      }
      .opacity(connected ? 1 : 0.35)
      .animation(.easeOut(duration: 0.08), value: pad)
    }
  }
}

private struct TriggerBar: View {
  let label: String
  let value: Double
  var body: some View {
    HStack(spacing: 6) {
      Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.08))
        Capsule().fill(Color.accentColor).frame(width: max(0, 70 * value))
      }
      .frame(width: 70, height: 8)
    }
  }
}

private struct Pill: View {
  let label: String
  let on: Bool
  var body: some View {
    Text(label).font(.caption.weight(.semibold))
      .frame(width: 64, height: 20)
      .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
      .foregroundStyle(on ? .white : .secondary)
  }
}

private struct Stick: View {
  let x: Int16, y: Int16
  let pressed: Bool
  var body: some View {
    ZStack {
      Circle().fill(Color.primary.opacity(0.07)).frame(width: 46, height: 46)
      Circle()
        .fill(pressed ? Color.accentColor : Color.primary.opacity(0.35))
        .frame(width: 22, height: 22)
        .offset(x: CGFloat(x) / 32767 * 12, y: -CGFloat(y) / 32767 * 12)
    }
  }
}

private struct DPad: View {
  let pad: PadState
  var body: some View {
    ZStack {
      arm(pad.up).offset(y: -13)
      arm(pad.down).offset(y: 13)
      arm(pad.left).rotationEffect(.degrees(90)).offset(x: -13)
      arm(pad.right).rotationEffect(.degrees(90)).offset(x: 13)
    }
  }
  private func arm(_ on: Bool) -> some View {
    RoundedRectangle(cornerRadius: 3).fill(on ? Color.accentColor : Color.primary.opacity(0.25)).frame(width: 12, height: 14)
  }
}

private struct Face: View {
  let label: String
  let color: Color
  let on: Bool
  var body: some View {
    Text(label).font(.system(size: 11, weight: .bold))
      .frame(width: 22, height: 22)
      .background(Circle().fill(on ? color : color.opacity(0.18)))
      .foregroundStyle(on ? .white : color)
  }
}

private struct Glyph: View {
  let symbol: String
  var fallback: String? = nil
  let on: Bool
  var size: CGFloat = 20
  var body: some View {
    let name = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : (fallback ?? "circle")
    Image(systemName: name)
      .font(.system(size: size * 0.5, weight: .semibold))
      .frame(width: size, height: size)
      .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
      .foregroundStyle(on ? .white : .secondary)
  }
}

/// Hosts MainView in a regular window that an accessory (menu-bar) app can bring forward.
final class MainWindowController: NSWindowController, NSWindowDelegate {
  convenience init(model: AppModel) {
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.contentViewController = NSHostingController(rootView: MainView(model: model))
    window.setFrameAutosaveName("RematchBridgeMain")
    self.init(window: window)
    window.delegate = self
  }

  func show() {
    if window?.isVisible != true { window?.center() }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}
