import AppKit
import SwiftUI

/// The panel that opens from the menu-bar icon.
struct PopoverView: View {
  @ObservedObject var model: AppModel

  private var connected: Bool { model.controllerName != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      miniController
      if !model.accessibilityGranted { permissionBanner }
      togglesCard
      profiles
      Divider().padding(.horizontal, -2)
      footer
    }
    .padding(14)
    .frame(width: 320)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.controllerName ?? "No Controller")
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      Circle().fill(statusColor).frame(width: 8, height: 8)
        .shadow(color: statusColor.opacity(0.6), radius: 3)
    }
  }

  private var statusText: String {
    if !connected { return "Plug in your controller with USB" }
    if model.browserActive { return "Playing in the browser" }
    if !model.accessibilityGranted { return "Needs permission" }
    return model.mappingEnabled ? "Active · \(model.activeProfile)" : "Paused"
  }

  private var statusColor: Color {
    if !connected { return .secondary.opacity(0.5) }
    if model.browserActive { return .blue }
    if !model.accessibilityGranted || !model.mappingEnabled { return .orange }
    return .green
  }

  // MARK: Controller

  private var miniController: some View {
    ControllerView(pad: model.pad, connected: connected)
      .frame(width: 380, height: 210)
      .scaleEffect(0.74)
      .frame(width: 292, height: 156)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 2)
      .background(Card())
  }

  // MARK: Permission

  private var permissionBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 1) {
        Text("Allow keyboard & mouse").font(.system(size: 12, weight: .semibold))
        Text("Already on? Remove it with − and allow again").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Allow", action: model.openAccessibility).buttonStyle(PillButtonStyle(prominent: true))
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
  }

  // MARK: Toggles

  private var togglesCard: some View {
    VStack(spacing: 0) {
      Row(symbol: "keyboard", title: "Keyboard & Mouse",
          subtitle: model.browserActive ? "Paused while a game tab is in front"
            : model.mappingEnabled ? "On · Xbox button pauses" : "Paused · Xbox button resumes") {
        PillSwitch(isOn: model.mappingEnabled) { model.setMappingEnabled(!model.mappingEnabled) }
      }
      Divider().padding(.leading, 38)
      Row(symbol: "globe", title: "Browser Gamepad", subtitle: model.browserSummary.text) {
        if !model.browserPages.isEmpty {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
        } else {
          switch model.extensionStatus {
          case .installed: Button("Play", action: model.openCloudGaming).buttonStyle(PillButtonStyle(prominent: true))
          case .disabled: Button("Turn On", action: model.openBrowserExtensions).buttonStyle(PillButtonStyle())
          case .notInstalled: Button("Set Up", action: model.setUpBrowser).buttonStyle(PillButtonStyle())
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .background(Card())
  }

  // MARK: Profiles

  private var profiles: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("PROFILE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
        Spacer()
        if model.profileErrorCount > 0 {
          Label("\(model.profileErrorCount) error\(model.profileErrorCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
        }
      }
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
        ForEach(model.profileNames, id: \.self) { name in
          ProfileChip(name: name, auto: model.profileApps[name],
                      selected: name == model.activeProfile) { model.chooseProfile(name) }
        }
      }
      if let app = model.lastAppName {
        Menu {
          ForEach(model.profileNames, id: \.self) { name in
            Button {
              model.assignLastApp(name)
            } label: {
              if model.lastAppProfile == name { Label(name, systemImage: "checkmark") } else { Text(name) }
            }
          }
          if model.lastAppProfile != nil {
            Divider()
            Button("Don't Switch Automatically") { model.assignLastApp(nil) }
          }
        } label: {
          Label(model.lastAppProfile.map { "\(app) uses \($0)" } ?? "Always use a profile for \(app)…",
                systemImage: "pin")
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 2) {
      IconButton(symbol: "macwindow", help: "Open RematchBridge", action: model.openWindow)
      IconButton(symbol: "square.and.pencil", help: "Edit Profiles", action: model.editProfiles)
      IconButton(symbol: "arrow.clockwise", help: "Reload Profiles", action: model.reloadProfiles)
      IconButton(symbol: "doc.text.magnifyingglass", help: "Open Log", action: model.openLog)
      Spacer()
      IconButton(symbol: "power", help: "Quit RematchBridge", action: model.quit)
    }
  }
}

// MARK: - Components

private struct Card: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(Color.primary.opacity(0.045))
      .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07)))
  }
}

private struct Row<Trailing: View>: View {
  let symbol: String
  let title: String
  let subtitle: String
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.14)))
        .foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 12, weight: .semibold))
        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 6)
      trailing()
    }
    .padding(.vertical, 8)
  }
}

/// A switch drawn in SwiftUI so it matches the panel (and renders anywhere).
private struct PillSwitch: View {
  let isOn: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      ZStack(alignment: isOn ? .trailing : .leading) {
        Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
        Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
      }
      .frame(width: 34, height: 20)
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isOn ? "On" : "Off")
  }
}

private struct ProfileChip: View {
  let name: String
  let auto: String?
  let selected: Bool
  let action: () -> Void
  @State private var hover = false

  private var symbol: String {
    let n = name.lowercased()
    if n.contains("desktop") { return "cursorarrow" }
    if n.contains("emul") { return "arcade.stick" }
    if n.contains("stream") || n.contains("fps") { return "scope" }
    return "slider.horizontal.3"
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "slider.horizontal.3")
          .font(.system(size: 11, weight: .semibold))
        VStack(alignment: .leading, spacing: 0) {
          Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
          if let auto { Text(auto).font(.system(size: 9)).opacity(0.75).lineLimit(1) }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .frame(height: 32)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.10 : 0.06)))
      .foregroundStyle(selected ? Color.white : Color.primary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
  }
}

private struct PillButtonStyle: ButtonStyle {
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold))
      .padding(.horizontal, 10)
      .frame(height: 22)
      .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.09)))
      .foregroundStyle(prominent ? Color.white : Color.primary)
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

private struct IconButton: View {
  let symbol: String
  let help: String
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .frame(width: 28, height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
    .onHover { hover = $0 }
  }
}
