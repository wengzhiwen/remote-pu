import AppKit
import CryptoKit
import SwiftUI

/// The menu bar: an NSStatusItem whose button shows the pre-rendered template title
/// image, and an NSPopover hosting MenuBarPanel.
///
/// This replaces SwiftUI's MenuBarExtra(.window), which on macOS 26 replays its
/// (slow, stiff) expand animation whenever its scene re-evaluates — once per sample
/// per node — so the panel constantly re-animates and its content cannot be clicked.
/// A plain popover presents exactly once: live content updates inside it never
/// re-trigger the presentation animation.
@MainActor
final class MenuPanelController: NSObject, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    private weak var model: AppModel?
    private var lastClosedAt = Date.distantPast

    var statusButton: NSStatusBarButton? { statusItem.button }

    init(model: AppModel) {
        self.model = model
        super.init()
        // Visibility and placement are saved by app + autosave name. Keep
        // isolated data directories from sharing the live app's saved state.
        let identity = SHA256.hash(data: Data(model.paths.dataDir.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        statusItem.autosaveName = "RemotePU-\(identity)"
        statusItem.isVisible = true
        popover.behavior = .transient // dismiss on outside click / Escape
        installPanelContent()
        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
        }
    }

    private func installPanelContent() {
        guard let model else { return }
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel().environmentObject(model))
    }

    var isShown: Bool { popover.isShown }

    /// The popover's window while it is shown (for the control API).
    var panelWindow: NSWindow? { popover.isShown ? popover.contentViewController?.view.window : nil }

    @objc private func toggle() {
        // Clicking the status item while the popover is open dismisses it (transient
        // behavior, on mouse-down) before this action runs on mouse-up; the debounce
        // keeps that same click from immediately reopening it.
        if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(lastClosedAt) > 0.3 {
            show()
        }
    }

    func setOpen(_ open: Bool) {
        if open == popover.isShown { return }
        if open { show() } else { popover.performClose(nil) }
    }

    private func show() {
        guard let button = statusItem.button else { return }
        // Content is dropped on close so the hidden panel stops re-rendering on
        // every sample; rebuild it each time the panel opens.
        if popover.contentViewController == nil { installPanelContent() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosedAt = Date()
        popover.contentViewController = nil
    }
}
