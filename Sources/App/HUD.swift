import AppKit

/// A brief, click-through banner near the bottom of the screen (like the volume HUD),
/// shown over full-screen apps and games.
final class HUD {
  private var panel: NSPanel?
  private var hideWork: DispatchWorkItem?

  func show(_ text: String, symbol: String) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    guard let effect = panel.contentView as? NSVisualEffectView,
      let stack = effect.subviews.first as? NSStackView,
      let icon = stack.arrangedSubviews.first as? NSImageView,
      let label = stack.arrangedSubviews.last as? NSTextField
    else { return }
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
    label.stringValue = text

    let size = stack.fittingSize
    let frameSize = NSSize(width: size.width + 40, height: 48)
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    if let visible = screen?.visibleFrame {
      panel.setFrame(NSRect(x: visible.midX - frameSize.width / 2, y: visible.minY + 90,
                            width: frameSize.width, height: frameSize.height), display: true)
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

    hideWork?.cancel()
    let work = DispatchWorkItem { [weak panel] in
      NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel?.animator().alphaValue = 0 }) {
        if panel?.alphaValue == 0 { panel?.orderOut(nil) }
      }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.ignoresMouseEvents = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true

    let effect = NSVisualEffectView()
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 24
    effect.layer?.masksToBounds = true

    let icon = NSImageView()
    icon.contentTintColor = .labelColor
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 15, weight: .medium)
    let stack = NSStackView(views: [icon, label])
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
    ])
    panel.contentView = effect
    return panel
  }
}
