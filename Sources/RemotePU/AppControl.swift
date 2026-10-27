import AppKit
import RemotePUCore
import RPUIPC
import RPUProtocol
import SwiftUI

/// Local control API (Unix socket, see docs/CONTROL_API.md) so tests and tools —
/// including Claude driving integration tests over ssh — can inspect and steer the
/// running app: manage nodes, read live data/history, drive the UI, take screenshots.
extension AppModel {
    struct CommandInfo {
        let name: String
        let args: String
        let summary: String
    }

    static let commands: [CommandInfo] = [
        .init(name: "help", args: "", summary: "List commands"),
        .init(name: "ping", args: "", summary: "App version, pid, paths"),
        .init(name: "state", args: "", summary: "All nodes: config, status, latest summary; UI state"),
        .init(name: "nodes.list", args: "", summary: "Node configs (including demo nodes)"),
        .init(name: "nodes.add", args: "name target [kind=ssh|local] [auth=system|password] [password] [persist=true] [port] [identityFile] [interval] [enabled] [sshOptions:=[..]] [icon=<SF Symbol>|auto] [showInMenuBar] [menuMetric=auto|cpu|gpu|temp] [id]",
              summary: "Add a node"),
        .init(name: "nodes.update", args: "id [same fields as nodes.add]", summary: "Change a node"),
        .init(name: "nodes.remove", args: "id", summary: "Delete a node (and its keychain password)"),
        .init(name: "nodes.setPassword", args: "id password [persist=true]", summary: "Set ssh password (persist=false: memory only)"),
        .init(name: "nodes.reconnect", args: "[id]", summary: "Reconnect one node (or all) now"),
        .init(name: "nodes.sample", args: "id", summary: "Latest hello + sample as sent by the collector"),
        .init(name: "nodes.wait", args: "id [phase=online] [timeout=60]", summary: "Block until a node reaches a phase"),
        .init(name: "history.query", args: "id metric [range=1h | seconds] [points=200]",
              summary: "Series from storage; metric e.g. cpu_util, gpu:<key>:util"),
        .init(name: "history.flush", args: "", summary: "Flush + roll up + prune now; returns row counts"),
        .init(name: "demo.set", args: "enabled=true|false", summary: "Add/remove synthetic demo nodes"),
        .init(name: "settings.get", args: "", summary: "Current settings"),
        .init(name: "settings.set", args: "<field>=<value> …", summary: "Change settings (menuBarMode, retention5sDays, …)"),
        .init(name: "ui.state", args: "", summary: "Selection, range, open windows, appearance"),
        .init(name: "ui.open", args: "window=main|settings [tab=general|nodes|about]", summary: "Open a window"),
        .init(name: "ui.close", args: "window=main|settings", summary: "Close a window"),
        .init(name: "ui.select", args: "node=<id>|overview", summary: "Select sidebar item (opens main window)"),
        .init(name: "ui.range", args: "value=15m|1h|6h|24h|7d|30d", summary: "Set chart time range"),
        .init(name: "ui.menu", args: "[open=true|false]", summary: "Toggle the menu bar panel"),
        .init(name: "ui.editor", args: "id=<node>|new|none", summary: "Open/close the node editor sheet in Settings"),
        .init(name: "ui.appearance", args: "value=light|dark|system", summary: "Force light/dark for screenshots"),
        .init(name: "ui.menubar", args: "[path] [appearance=light|dark]", summary: "PNG of the menu bar title + its entries (icon/value per node)"),
        .init(name: "ui.windows", args: "", summary: "All app windows with class/identifier/frame"),
        .init(name: "ui.screenshot", args: "window=main|settings|menu|<number> [path=/tmp/x.png] [method=auto|screencapture|layer|cache]",
              summary: "PNG of an app window (full pixels need Screen Recording permission; see ui.requestScreenCapture)"),
        .init(name: "ui.requestScreenCapture", args: "", summary: "Ask macOS for Screen Recording permission (one-time prompt)"),
        .init(name: "ui.render", args: "page=overview|<node id> [width=1100] [appearance=light|dark] [path]",
              summary: "Offscreen PNG of a full page (not clipped by window size)"),
        .init(name: "log.tail", args: "[n=100] [filter]", summary: "Recent log lines"),
        .init(name: "app.quit", args: "", summary: "Quit the app"),
    ]

    func handleControl(_ req: ControlRequest) async throws -> JSONValue {
        switch req.cmd {
        case "help":
            return .array(Self.commands.map { ["cmd": .string($0.name), "args": .string($0.args), "summary": .string($0.summary)] })
        case "ping":
            return [
                "app": "RemotePU",
                "version": .from(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "uptime": .number(Date().timeIntervalSince(startedAt).rounded()),
                "dataDir": .string(paths.dataDir.path),
                "controlSocket": .string(paths.controlSocket),
                "agent": .from(agentPath),
                "askpass": .from(askpassPath),
                "bundle": .string(Bundle.main.bundlePath),
            ]
        case "state":
            return ["nodes": .array(nodes.map(nodeState)), "ui": uiState(), "summary": summaryJSON(), "demo": .bool(demoEnabled)]
        case "nodes.list":
            return try JSONValue(encoding: allConfigs)
        case "nodes.add":
            let c = try nodeConfig(from: req, base: nil)
            let added = try addNode(c, password: req.string("password"), persistPassword: req.bool("persist") ?? true)
            return try JSONValue(encoding: added)
        case "nodes.update":
            guard let id = req.string("id"), let existing = userNodes.first(where: { $0.id == id }) else {
                throw ControlError("unknown node id")
            }
            let c = try nodeConfig(from: req, base: existing)
            try updateNode(c, password: req.string("password"), persistPassword: req.bool("persist") ?? true)
            return try JSONValue(encoding: c)
        case "nodes.remove":
            guard let id = req.string("id"), userNodes.contains(where: { $0.id == id }) else { throw ControlError("unknown node id") }
            removeNode(id)
            return .bool(true)
        case "nodes.setPassword":
            guard let id = req.string("id"), let pw = req.string("password") else { throw ControlError("id and password required") }
            try setPassword(pw, for: id, persist: req.bool("persist") ?? true)
            return .bool(true)
        case "nodes.reconnect":
            reconnect(req.string("id"))
            return .bool(true)
        case "nodes.sample":
            let live = try node(req)
            return ["hello": try live.hello.map { try JSONValue(encoding: $0, encoder: RPUJSON.makeEncoder()) } ?? .null,
                    "sample": try live.latest.map { try JSONValue(encoding: $0, encoder: RPUJSON.makeEncoder()) } ?? .null,
                    "status": try JSONValue(encoding: live.status, encoder: Self.unixDateEncoder)]
        case "nodes.wait":
            let live = try node(req)
            let wanted = NodePhase(rawValue: req.string("phase") ?? "online") ?? .online
            let deadline = Date().addingTimeInterval(req.double("timeout") ?? 60)
            while live.status.phase != wanted {
                if Date() > deadline {
                    throw ControlError("timeout; phase=\(live.status.phase.rawValue) message=\(live.status.message ?? "-")")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            return try JSONValue(encoding: live.status, encoder: Self.unixDateEncoder)
        case "history.query":
            let live = try node(req)
            guard let m = req.string("metric"), let metric = MetricRef(string: m) else { throw ControlError("bad metric") }
            let seconds = req.string("range").flatMap { TimeRange(rawValue: $0)?.seconds } ?? req.double("range") ?? 3600
            guard let history else { throw ControlError("history unavailable") }
            let pts = try await history.query(nodeID: live.id, metric: metric, from: Date().addingTimeInterval(-seconds),
                                              to: Date(), maxPoints: req.int("points") ?? 200)
            return .array(pts.map { [.number($0.t.timeIntervalSince1970), .number($0.avg), .number($0.max)] })
        case "history.flush":
            guard let history else { throw ControlError("history unavailable") }
            try await history.flush()
            try await history.rollup()
            return try JSONValue(encoding: try await history.stats())
        case "demo.set":
            setDemo(req.bool("enabled") ?? true)
            return .bool(demoEnabled)
        case "settings.get":
            return try JSONValue(encoding: settings)
        case "settings.set":
            var obj = try JSONValue(encoding: settings).objectValue ?? [:]
            for (k, v) in req.args ?? [:] { obj[k] = v }
            settings = try JSONValue.object(obj).decode(as: AppSettings.self)
            saveSettings()
            return try JSONValue(encoding: settings)
        case "ui.state":
            return uiState()
        case "ui.open":
            if req.string("window") == "settings" {
                openSettings(tab: req.string("tab"))
            } else {
                openMainWindow()
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            return uiState()
        case "ui.close":
            let w = try window(req.string("window") ?? "main")
            w.performClose(nil)
            return .bool(true)
        case "ui.select":
            let target = req.string("node") ?? req.string("value") ?? "overview"
            if target == "overview" {
                openMainWindow(select: .overview)
            } else {
                guard live(target) != nil else { throw ControlError("unknown node \(target)") }
                openMainWindow(select: .node(target))
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            return uiState()
        case "ui.range":
            guard let r = TimeRange(rawValue: req.string("value") ?? "") else { throw ControlError("value must be 15m|1h|6h|24h|7d|30d") }
            range = r
            return .string(r.rawValue)
        case "ui.menu":
            try toggleMenuBarPanel(open: req.bool("open"))
            try await Task.sleep(nanoseconds: 400_000_000)
            return uiState()
        case "ui.editor":
            let target = req.string("id") ?? "none"
            if target == "none" {
                editor = nil
            } else if target == "new" {
                openSettings(tab: "nodes")
                editor = NodeEditorTarget(id: "new", config: NodeConfig(id: "", name: "", target: ""), isNew: true)
            } else {
                guard let c = userNodes.first(where: { $0.id == target }) else { throw ControlError("unknown node") }
                openSettings(tab: "nodes")
                editor = NodeEditorTarget(id: c.id, config: c, isNew: false)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            return uiState()
        case "ui.menubar":
            // The status-item title as rendered (template image drawn black → re-tinted here for viewing).
            let entries = menuBarEntries()
            let path = req.string("path") ?? NSTemporaryDirectory() + "rpu-menubar.png"
            let dark = (req.string("appearance") ?? "light") == "dark"
            // The real title is a black template image; invert it on a dark bar for viewing.
            let base = MenuBarTitleContent(entries: entries, problems: summary.problems)
            let view: AnyView = dark
                ? AnyView(base.colorInvert().padding(.horizontal, 8).background(Color(white: 0.12)))
                : AnyView(base.padding(.horizontal, 8).background(Color(white: 0.94)))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                throw ControlError("render failed")
            }
            try png.write(to: URL(fileURLWithPath: path))
            let item = menuPanel?.statusItem
            let frame = item?.button?.window?.frame
            // This is the last known anchor, not proof of host visibility:
            // ControlCenter can block an item while AppKit still reports true.
            let anchorOnMenuBar = frame.map { frame in
                NSScreen.screens.contains { screen in
                    let bar = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY,
                                     width: screen.frame.width, height: screen.frame.maxY - screen.visibleFrame.maxY)
                    return frame.intersects(bar)
                }
            } ?? false
            return ["path": .string(path), "entries": .array(entries.map { ["node": .string($0.id), "symbol": .string($0.symbol),
                                                                              "text": .string($0.text), "online": .bool($0.online)] }),
                    "statusItem": ["autosaveName": .from(item?.autosaveName), "requestedVisible": .bool(item?.isVisible ?? false),
                                   "anchorOnMenuBar": .bool(anchorOnMenuBar)]]
        case "ui.appearance":
            setAppearance(req.string("value") ?? "system")
            return .string(req.string("value") ?? "system")
        case "ui.windows":
            return .array(NSApp.windows.map(windowInfo))
        case "ui.screenshot":
            let name = req.string("window") ?? "main"
            let w = try window(name)
            let path = req.string("path") ?? NSTemporaryDirectory() + "rpu-\(name)-\(Int(Date().timeIntervalSince1970)).png"
            // auto: real pixels via screencapture when Screen Recording is granted,
            // else the permission-free layer render (window chrome only for SwiftUI content).
            var method = req.string("method") ?? "auto"
            if method == "auto" { method = CGPreflightScreenCaptureAccess() ? "screencapture" : "layer" }
            let size: CGSize
            if method == "screencapture" {
                let r = try await ProcessRunner.run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(w.windowNumber)", path], timeout: 15)
                guard r.status == 0, let img = NSImage(contentsOfFile: path),
                      let rep = img.representations.first else {
                    throw ControlError("screencapture failed: \(r.errorText)")
                }
                size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            } else {
                size = try screenshot(w, to: path, method: method)
            }
            return ["path": .string(path), "width": .number(Double(size.width)), "height": .number(Double(size.height)),
                    "method": .string(method), "screenRecordingGranted": .bool(CGPreflightScreenCaptureAccess())]
        case "ui.requestScreenCapture":
            // Shows the system prompt once; grant RemotePU in System Settings → Privacy → Screen Recording.
            return .bool(CGRequestScreenCaptureAccess())
        case "ui.render":
            let page = req.string("page") ?? req.string("node") ?? "overview"
            let path = req.string("path") ?? NSTemporaryDirectory() + "rpu-render-\(page)-\(Int(Date().timeIntervalSince1970)).png"
            let dark = (req.string("appearance") ?? "light") == "dark"
            let size = try renderPage(page, width: CGFloat(req.double("width") ?? 1100), dark: dark, to: path)
            return ["path": .string(path), "width": .number(Double(size.width)), "height": .number(Double(size.height))]
        case "log.tail":
            return .array(RPULog.shared.tail(req.int("n") ?? 100, matching: req.string("filter")).map { .string($0) })
        case "app.quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return .bool(true)
        default:
            throw ControlError("unknown command \(req.cmd) (try help)")
        }
    }

    // MARK: - helpers

    static var unixDateEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private func node(_ req: ControlRequest) throws -> NodeLive {
        guard let id = req.string("id") ?? req.string("node"), let n = live(id) else { throw ControlError("unknown node id") }
        return n
    }

    private func nodeConfig(from req: ControlRequest, base: NodeConfig?) throws -> NodeConfig {
        var c = base ?? NodeConfig(id: req.string("id") ?? "", name: req.string("name") ?? req.string("target") ?? "node")
        if let v = req.string("name") { c.name = v }
        if let v = req.string("kind") {
            guard let k = NodeKind(rawValue: v) else { throw ControlError("kind must be ssh|local|demo") }
            c.kind = k
        }
        if let v = req.string("target") { c.target = v }
        if let v = req.int("port") { c.port = v }
        if let v = req.string("identityFile") { c.identityFile = v.isEmpty ? nil : v }
        if let v = req.string("auth") {
            guard let a = SSHAuthMode(rawValue: v) else { throw ControlError("auth must be system|password") }
            c.auth = a
        }
        if let v = req.double("interval") { c.interval = max(0.2, v) }
        if let v = req.bool("enabled") { c.enabled = v }
        if let v = req.arg("sshOptions")?.arrayValue { c.sshOptions = v.compactMap(\.stringValue) }
        if let v = req.string("demoProfile") { c.demoProfile = v }
        if let v = req.string("icon") { c.icon = v.isEmpty || v == "auto" ? nil : v }
        if let v = req.bool("showInMenuBar") { c.showInMenuBar = v }
        if let v = req.string("menuMetric") {
            guard ["auto", "cpu", "gpu", "temp"].contains(v) else { throw ControlError("menuMetric must be auto|cpu|gpu|temp") }
            c.menuMetric = v
        }
        if base == nil, c.kind == .ssh, c.target.isEmpty { throw ControlError("target required") }
        if base == nil, req.string("password") != nil, req.string("auth") == nil { c.auth = .password }
        return c
    }

    private func nodeState(_ n: NodeLive) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(n.id),
            "name": .string(n.config.name),
            "kind": .string(n.config.kind.rawValue),
            "target": .string(n.config.target),
            "auth": .string(n.config.auth.rawValue),
            "enabled": .bool(n.config.enabled),
            "phase": .string(n.status.phase.rawValue),
            "message": .from(n.status.message),
            "since": .number(n.status.since.timeIntervalSince1970.rounded()),
            "hasPassword": .bool(secrets.hasPassword(for: n.id)),
            "samples": .number(Double(n.ring.count)),
        ]
        if let h = n.hello {
            o["os"] = .from(h.os)
            o["osVersion"] = .from(h.osVersion)
            o["cpu"] = .from(h.cpu?.model)
            o["gpus"] = .array((h.gpus ?? []).map { .string($0.name ?? "GPU") })
            o["gpuKeys"] = .array((h.gpus ?? []).map { .string($0.key) })
        }
        if let s = n.latest {
            o["age"] = .number((Date().timeIntervalSince1970 - s.ts).rounded())
            o["cpuUtil"] = .from(s.cpu?.util)
            o["cpuTemp"] = .from(s.cpu?.tempC)
            o["memUsed"] = .from(s.mem?.used)
            o["gpuUtil"] = .array((s.gpus ?? []).map { .from($0.util) })
            o["gpuTemp"] = .array((s.gpus ?? []).map { .from($0.tempC) })
        }
        if let e = n.lastAgentError { o["agentError"] = .string(e) }
        return .object(o)
    }

    private func summaryJSON() -> JSONValue {
        ["online": .number(Double(summary.online)), "total": .number(Double(summary.total)),
         "maxGPUUtil": .from(summary.maxGPUUtil), "maxCPUUtil": .from(summary.maxCPUUtil),
         "maxTemp": .from(summary.maxTemp), "problems": .number(Double(summary.problems))]
    }

    private func uiState() -> JSONValue {
        let sel: String
        switch selection {
        case .overview, .none: sel = "overview"
        case .node(let id): sel = id
        }
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        return [
            "selection": .string(sel),
            "range": .string(range.rawValue),
            "settingsTab": .string(settingsTab),
            "editor": .from(editor?.id),
            "mainWindowVisible": .bool(mainWindowVisible),
            "appearance": .string(appearance),
            "windows": .array(NSApp.windows.filter(\.isVisible).map(windowInfo)),
        ]
    }

    private func windowInfo(_ w: NSWindow) -> JSONValue {
        [
            "number": .number(Double(w.windowNumber)),
            "title": .string(w.title),
            "identifier": .from(w.identifier?.rawValue),
            "class": .string(String(describing: type(of: w))),
            "visible": .bool(w.isVisible),
            "key": .bool(w.isKeyWindow),
            "frame": .array([.number(w.frame.origin.x), .number(w.frame.origin.y),
                              .number(w.frame.size.width), .number(w.frame.size.height)]),
        ]
    }

    func window(_ name: String) throws -> NSWindow {
        let windows = NSApp.windows
        let found: NSWindow?
        switch name {
        case "main":
            found = windows.first { ($0.identifier?.rawValue.hasPrefix("main") ?? false) && $0.isVisible }
                ?? windows.first { $0.title == "RemotePU" && $0.isVisible }
        case "settings":
            found = windows.first { ($0.identifier?.rawValue.contains("Settings") ?? false) && $0.isVisible }
                ?? windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Settings") }
        case "menu":
            found = menuPanel?.panelWindow
        default:
            found = Int(name).flatMap { n in windows.first { $0.windowNumber == n } }
        }
        guard let w = found else { throw ControlError("window \(name) not found/visible (see ui.windows)") }
        return w
    }

    /// Captures one of our own windows into a PNG without Screen Recording permission.
    /// "layer" (default) renders the Core Animation layer tree, which includes SwiftUI
    /// content; "cache" uses NSView.cacheDisplay (chrome only for layer-hosted content).
    func screenshot(_ window: NSWindow, to path: String, method: String = "layer") throws -> CGSize {
        guard let view = window.contentView?.superview ?? window.contentView else { throw ControlError("no content view") }
        let rep: NSBitmapImageRep
        if method == "cache" {
            guard let r = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ControlError("cannot create bitmap") }
            view.cacheDisplay(in: view.bounds, to: r)
            rep = r
        } else {
            guard let layer = view.layer else { throw ControlError("view is not layer-backed; use method=cache") }
            let scale = window.backingScaleFactor
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ControlError("cannot create context")
            }
            ctx.setFillColor(window.backgroundColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            if layer.isGeometryFlipped {
                ctx.translateBy(x: 0, y: view.bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            guard let image = ctx.makeImage() else { throw ControlError("render failed") }
            rep = NSBitmapImageRep(cgImage: image)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ControlError("PNG encoding failed") }
        try png.write(to: URL(fileURLWithPath: path))
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Offscreen render of a page with SwiftUI's ImageRenderer (independent of windows).
    func renderPage(_ page: String, width: CGFloat, dark: Bool, to path: String) throws -> CGSize {
        let content: AnyView
        if page == "overview" {
            content = AnyView(OverviewGrid())
        } else {
            guard let live = live(page) else { throw ControlError("unknown node \(page)") }
            content = AnyView(NodeDetailContent(live: live))
        }
        let view = content
            .environmentObject(self)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { throw ControlError("render failed") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ControlError("PNG encoding failed") }
        try png.write(to: URL(fileURLWithPath: path))
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Opens/closes the popover panel (see MenuPanelController).
    func toggleMenuBarPanel(open: Bool?) throws {
        guard let panel = menuPanel else { throw ControlError("menu bar not set up") }
        panel.setOpen(open ?? !panel.isShown)
    }
}
