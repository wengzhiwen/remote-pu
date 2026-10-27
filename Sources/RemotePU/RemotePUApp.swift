import AppKit
import RemotePUCore
import SwiftUI

@main
struct RemotePUApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // The menu bar item and the main window are AppKit objects created in
        // AppModel.startMenuBar()/openMainWindow(): SwiftUI's MenuBarExtra(.window)
        // replays its expand animation on every scene update on macOS 26, which made
        // the panel permanently re-animate (see MenuPanelController).
        Settings {
            SettingsView().environmentObject(model)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Reconnect All Nodes") { model.reconnect(nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.startMenuBar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop ssh masters/collectors and flush history before exiting. This must not
        // depend on the main actor: during .terminateLater AppKit spins a private run
        // loop mode that never drains the main queue. The work runs on the cooperative
        // pool while we wait here (bounded), then anything left gets SIGTERM.
        let model = AppModel.shared
        model.prepareForQuit()
        let manager = model.manager
        let history = model.history
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await manager.stopAll()
            try? await history?.flush(includeCurrent: true)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        ProcessRegistry.shared.terminateAll()
        return .terminateNow
    }
}
