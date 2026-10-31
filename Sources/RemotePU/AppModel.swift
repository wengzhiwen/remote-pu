import AppKit
import Combine
import RemotePUCore
import RPUIPC
import RPUProtocol
import ServiceManagement
import SwiftUI

enum TimeRange: String, CaseIterable, Identifiable, Codable {
    case m15 = "15m", h1 = "1h", h6 = "6h", h24 = "24h", d7 = "7d", d30 = "30d"

    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .m15: return 900
        case .h1: return 3600
        case .h6: return 6 * 3600
        case .h24: return 86_400
        case .d7: return 7 * 86_400
        case .d30: return 30 * 86_400
        }
    }

    /// Served from the in-memory 1 s ring (30 min) instead of the database.
    var isLive: Bool { self == .m15 }
}

enum SidebarItem: Hashable {
    case overview
    case node(String)
}

/// Which node editor sheet is open in Settings → Nodes.
struct NodeEditorTarget: Identifiable, Hashable {
    var id: String
    var config: NodeConfig
    var isNew: Bool
}

/// Command-line switches (also used by tests driving the app over the control API).
struct LaunchOptions {
    var dataDir: String?
    var demo = false
    var controlEnabled = true
    var openMain = false
    var appearance: String?
    var noKeychain = false

    static func parse(_ args: [String] = CommandLine.arguments) -> LaunchOptions {
        var o = LaunchOptions()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--data-dir": o.dataDir = it.next()
            case "--demo": o.demo = true
            case "--no-control": o.controlEnabled = false
            case "--open-main": o.openMain = true
            case "--appearance": o.appearance = it.next()
            case "--no-keychain": o.noKeychain = true
            default: break // e.g. -NSDocumentRevisionsDebugMode from launch services
            }
        }
        if ProcessInfo.processInfo.environment["RPU_DEMO"] == "1" { o.demo = true }
        return o
    }
}

/// Live state of one node (observed per card so only that card re-renders).
@MainActor
final class NodeLive: ObservableObject, Identifiable {
    let id: String
    @Published var config: NodeConfig
    @Published var status = NodeStatus(phase: .idle)
    @Published var hello: HelloMessage?
    @Published var latest: SampleMessage?
    @Published var lastAgentError: String?
    private(set) var ring = RingBuffer<SampleMessage>(capacity: 1800)

    init(config: NodeConfig) {
        id = config.id
        self.config = config
    }

    var gpuKeys: [Int: String] { hello?.gpuKeys ?? [:] }
    var isDemo: Bool { config.kind == .demo }
    var displayName: String { config.name }

    func append(_ s: SampleMessage) {
        ring.append(s)
        latest = s
    }

    /// Ring-buffer series since `since`, thinned to at most `maxPoints`. Charts
    /// rebuild every mark on every sample, so the cap trades resolution for a
    /// much cheaper per-sample relayout; ~3 px per point is visually identical.
    func series(_ metric: MetricRef, since: Date, maxPoints: Int = 150) -> [SeriesPoint] {
        let keys = gpuKeys
        let cutoff = since.timeIntervalSince1970
        let points = ring.elements.compactMap { s -> SeriesPoint? in
            guard s.ts >= cutoff, let v = metric.value(in: s, gpuKeys: keys) else { return nil }
            return SeriesPoint(t: s.date, avg: v, max: v)
        }
        guard points.count > maxPoints else { return points }
        let stride = Int((Double(points.count) / Double(maxPoints)).rounded(.up))
        return Swift.stride(from: 0, to: points.count, by: stride).map { i in
            let chunk = points[i..<min(points.count, i + stride)]
            let avg = chunk.reduce(0) { $0 + $1.avg } / Double(chunk.count)
            return SeriesPoint(t: chunk.last!.t, avg: avg, max: chunk.map(\.max).max() ?? avg)
        }
    }

    func gpuInfo(_ idx: Int) -> GPUInfo? { hello?.gpus?.first { $0.idx == idx } }
}

struct MenuSummary: Equatable {
    var online = 0
    var total = 0
    var maxGPUUtil: Double?
    var maxCPUUtil: Double?
    var maxTemp: Double?
    var problems = 0
    /// Node with the highest GPU (resp. CPU) utilisation, for "which machine?".
    var busiestGPUNode: String?
    var busiestCPUNode: String?
}

/// One segment of the menu bar title: a node's icon and its headline value.
struct MenuBarEntry: Equatable, Identifiable {
    var id: String
    var symbol: String
    var text: String
    var online: Bool
    var attention: Bool
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    static let shared = AppModel()

    let options: LaunchOptions
    let paths: RPUPaths
    let configStore: ConfigStore
    let secrets: LayeredSecretStore
    let history: HistoryStore?
    let manager: NodeManager
    let agentPath: String?
    let askpassPath: String?
    private var broker: AskpassBroker?
    private var control: ControlServer?
    private var maintenanceTimer: Timer?

    @Published private(set) var nodes: [NodeLive] = []
    @Published var settings: AppSettings
    @Published var selection: SidebarItem? = .overview
    @Published var range: TimeRange = .m15
    @Published private(set) var demoEnabled = false
    @Published private(set) var summary = MenuSummary()
    /// Rendered menu bar title (template image: icon + value per node).
    @Published private(set) var menuBarImage: NSImage?
    private var lastMenuEntries: [MenuBarEntry] = []
    @Published var settingsTab = "general"
    @Published var editor: NodeEditorTarget?
    @Published var mainWindowVisible = false

    /// The AppKit menu bar (status item + popover panel) and the AppKit main window.
    /// SwiftUI's MenuBarExtra(.window) replays its expand animation on every scene
    /// update — once per sample — on macOS 26, so both live outside the scene graph.
    private(set) var menuPanel: MenuPanelController?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pendingOpenMain = false

    private var configs: [NodeConfig]
    private var demoConfigs: [NodeConfig] = []
    private var liveByID: [String: NodeLive] = [:]
    let startedAt = Date()

    private override init() {
        ignoreSIGPIPE()
        let options = LaunchOptions.parse()
        let paths = RPUPaths.standard(dataDirOverride: options.dataDir)
        try? paths.ensureDirectories()
        RPULog.shared.configure(fileURL: paths.logFile)
        let store = ConfigStore(paths: paths)
        let settings = store.loadSettings()
        var loaded = store.loadNodes()
        if settings.showLocalNode, !loaded.contains(where: { $0.kind == .local }) {
            loaded.insert(.local(), at: 0)
        }
        let secrets = LayeredSecretStore(keychain: options.noKeychain ? nil : KeychainStore())
        let broker = try? AskpassBroker(socketPath: paths.askpassSocket)
        let agent = HelperLocator.find("rpu-agent-mac")
        let askpass = HelperLocator.find("rpu-askpass")
        self.options = options
        self.paths = paths
        self.settings = settings
        configStore = store
        configs = loaded
        self.secrets = secrets
        history = try? HistoryStore(path: paths.historyDB)
        self.broker = broker
        agentPath = agent
        askpassPath = askpass
        manager = NodeManager(env: RunnerEnvironment(paths: paths, agentBinary: agent, askpassHelper: askpass,
                                                     broker: broker, secrets: secrets))
        RPULog.shared.log("app", "start; data=\(paths.dataDir.path) agent=\(agent ?? "-") askpass=\(askpass ?? "-")")

        super.init()
        rebuildLive()
        startEventLoop()
        if options.controlEnabled { startControlServer() }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runMaintenance() }
        }
        if options.demo { demoConfigs = Self.demoNodes; demoEnabled = true; rebuildLive() }
        if let a = options.appearance { setAppearance(a) }
        pendingOpenMain = options.openMain || settings.openDashboardAtLaunch
        applyConfigs()
    }

    static let demoNodes: [NodeConfig] = [
        NodeConfig(id: "demo-gpu", name: "demo-gpu (2×GPU)", kind: .demo, demoProfile: "linux-2gpu"),
        NodeConfig(id: "demo-mac", name: "demo-mac", kind: .demo, demoProfile: "mac"),
    ]

    var allConfigs: [NodeConfig] { configs + demoConfigs }
    var userNodes: [NodeConfig] { configs }

    func live(_ id: String) -> NodeLive? { liveByID[id] }

    // MARK: - events

    private func startEventLoop() {
        let events = manager.events
        Task { @MainActor [weak self] in
            for await e in events {
                self?.handle(e)
            }
        }
    }

    private func handle(_ e: NodeManagerEvent) {
        guard let live = liveByID[e.nodeID] else { return }
        switch e.event {
        case .status(let s):
            live.status = s
            updateSummary()
        case .hello(let h):
            live.hello = h
        case .sample(let s):
            live.append(s)
            if let history, !live.isDemo {
                let keys = live.gpuKeys
                let id = live.id
                Task { await history.ingest(nodeID: id, sample: s, gpuKeys: keys) }
            }
            updateSummary()
        case .agentError(let msg):
            live.lastAgentError = msg
        }
    }

    private func updateSummary() {
        var s = MenuSummary()
        for n in nodes where n.config.enabled {
            s.total += 1
            if n.status.phase == .online { s.online += 1 }
            if [.offline, .authFailed, .stale].contains(n.status.phase) { s.problems += 1 }
            guard n.status.phase == .online || n.status.phase == .stale, let l = n.latest else { continue }
            if let g = l.gpus?.compactMap(\.util).max(), g >= (s.maxGPUUtil ?? -1) {
                s.maxGPUUtil = g
                s.busiestGPUNode = n.id
            }
            if let c = l.cpu?.util, c >= (s.maxCPUUtil ?? -1) {
                s.maxCPUUtil = c
                s.busiestCPUNode = n.id
            }
            let temps = (l.gpus?.compactMap(\.tempC) ?? []) + [l.cpu?.tempC].compactMap { $0 }
            if let t = temps.max() { s.maxTemp = max(s.maxTemp ?? 0, t) }
        }
        if s != summary { summary = s }
        updateMenuBarImage()
    }

    func symbol(for live: NodeLive) -> String { NodeIcons.symbol(for: live.config, hello: live.hello) }

    /// Headline value of a node for the menu bar (GPUs in index order; "auto": GPU for Linux GPU boxes, else CPU).
    func menuValue(for live: NodeLive) -> String {
        guard live.status.phase == .online || live.status.phase == .stale, let l = live.latest else { return Fmt.dash }
        let gpus = (l.gpus ?? []).sorted { $0.idx < $1.idx }
        let gpuText = gpus.isEmpty ? Fmt.dash : gpus.map { Fmt.pct($0.util) }.joined(separator: " ")
        let temp = ((l.gpus?.compactMap(\.tempC) ?? []) + [l.cpu?.tempC].compactMap { $0 }).max()
        switch live.config.menuMetric {
        case "cpu": return Fmt.pct(l.cpu?.util)
        case "gpu": return gpuText
        case "temp": return temp.map { String(format: "%.0f°", $0) } ?? Fmt.dash
        default:
            let gpuBox = live.hello?.os == "linux" && !gpus.isEmpty
            return gpuBox ? gpuText : Fmt.pct(l.cpu?.util)
        }
    }

    func menuBarEntries() -> [MenuBarEntry] {
        func entry(_ n: NodeLive, text: String) -> MenuBarEntry {
            MenuBarEntry(id: n.id, symbol: symbol(for: n), text: text,
                         online: n.status.phase == .online || n.status.phase == .stale,
                         attention: [.offline, .authFailed, .stale].contains(n.status.phase))
        }
        switch settings.menuBarMode {
        case "icon":
            return []
        case "maxGPU", "maxCPU":
            let gpuMode = settings.menuBarMode == "maxGPU" && summary.maxGPUUtil != nil
            let id = gpuMode ? summary.busiestGPUNode : summary.busiestCPUNode
            guard let id, let n = live(id) else { return [] }
            let value = gpuMode ? summary.maxGPUUtil : summary.maxCPUUtil
            let temp = summary.maxTemp.map { " " + String(format: "%.0f°", $0) } ?? ""
            return [entry(n, text: Fmt.pct(value) + temp)]
        default:
            return nodes.filter { $0.config.enabled && $0.config.showInMenuBar }.map { entry($0, text: menuValue(for: $0)) }
        }
    }

    private func updateMenuBarImage() {
        let entries = menuBarEntries()
        guard entries != lastMenuEntries || menuBarImage == nil else { return }
        lastMenuEntries = entries
        let content = MenuBarTitleContent(entries: entries, problems: summary.problems)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let cg = renderer.cgImage else { return }
        let size = NSSize(width: CGFloat(cg.width) / renderer.scale, height: CGFloat(cg.height) / renderer.scale)
        let image = NSImage(cgImage: cg, size: size)
        image.isTemplate = true // adapts to light/dark menu bars
        menuBarImage = image
        if let button = menuPanel?.statusButton {
            button.image = image
            button.setAccessibilityLabel(accessibilityText(for: entries))
        }
    }

    private func accessibilityText(for entries: [MenuBarEntry]) -> String {
        let parts = entries.map { e in "\(live(e.id)?.config.name ?? e.id) \(e.text)" }
        return parts.isEmpty ? "RemotePU" : parts.joined(separator: ", ")
    }

    private func runMaintenance() {
        guard let history else { return }
        let retention = HistoryStore.Retention(raw5sDays: settings.retention5sDays, rollup1mDays: settings.retention1mDays)
        Task.detached { await history.maintenance(retention: retention) }
    }

    /// Synchronous part of quitting (see AppDelegate.applicationShouldTerminate).
    func prepareForQuit() {
        maintenanceTimer?.invalidate()
        control?.stop()
        menuPanel?.setOpen(false)
    }

    // MARK: - nodes

    private func rebuildLive() {
        var next: [NodeLive] = []
        var map: [String: NodeLive] = [:]
        for c in allConfigs {
            let live = liveByID[c.id] ?? NodeLive(config: c)
            live.config = c
            next.append(live)
            map[c.id] = live
        }
        liveByID = map
        nodes = next
        if case .node(let id) = selection, map[id] == nil { selection = .overview }
        updateSummary()
    }

    private func applyConfigs() {
        let all = allConfigs
        Task { await manager.apply(all) }
    }

    private func persist() {
        do {
            try configStore.saveNodes(configs)
        } catch {
            RPULog.shared.log("app", "saving nodes failed: \(error)")
        }
        rebuildLive()
        applyConfigs()
    }

    func uniqueID(for base: String) -> String {
        var id = NodeConfig.makeID(from: base)
        var n = 2
        let taken = Set(allConfigs.map(\.id))
        while taken.contains(id) {
            id = NodeConfig.makeID(from: base) + "-\(n)"
            n += 1
        }
        return id
    }

    @discardableResult
    func addNode(_ config: NodeConfig, password: String? = nil, persistPassword: Bool = true) throws -> NodeConfig {
        var c = config
        if c.id.isEmpty || allConfigs.contains(where: { $0.id == c.id }) { c.id = uniqueID(for: c.name) }
        if let password, !password.isEmpty { try secrets.setPassword(password, for: c.id, persist: persistPassword) }
        configs.append(c)
        persist()
        return c
    }

    func updateNode(_ config: NodeConfig, password: String? = nil, persistPassword: Bool = true) throws {
        guard let i = configs.firstIndex(where: { $0.id == config.id }) else {
            throw ControlError("unknown node \(config.id)")
        }
        if let password, !password.isEmpty { try secrets.setPassword(password, for: config.id, persist: persistPassword) }
        configs[i] = config
        persist()
    }

    func removeNode(_ id: String) {
        configs.removeAll { $0.id == id }
        try? secrets.setPassword(nil, for: id, persist: true)
        persist()
    }

    func moveNodes(from: IndexSet, to: Int) {
        configs.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func setPassword(_ password: String?, for id: String, persist: Bool) throws {
        try secrets.setPassword(password, for: id, persist: persist)
        Task { await manager.retry(id) }
    }

    func reconnect(_ id: String?) {
        Task {
            if let id { await manager.retry(id) } else { await manager.retryAll() }
        }
    }

    func setDemo(_ on: Bool) {
        demoEnabled = on
        demoConfigs = on ? Self.demoNodes : []
        rebuildLive()
        applyConfigs()
    }

    func saveSettings() {
        try? configStore.saveSettings(settings)
        if settings.showLocalNode, !configs.contains(where: { $0.kind == .local }) {
            configs.insert(.local(), at: 0)
            persist()
        } else if !settings.showLocalNode, configs.contains(where: { $0.kind == .local }) {
            configs.removeAll { $0.kind == .local }
            persist()
        }
        updateSummary()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                RPULog.shared.log("app", "launch at login: \(error)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - series

    func series(for live: NodeLive, metric: MetricRef, range: TimeRange) async -> [SeriesPoint] {
        let since = Date().addingTimeInterval(-range.seconds)
        if range.isLive || live.isDemo { return live.series(metric, since: since) }
        guard let history else { return [] }
        let retention = HistoryStore.Retention(raw5sDays: settings.retention5sDays, rollup1mDays: settings.retention1mDays)
        return (try? await history.query(nodeID: live.id, metric: metric, from: since, to: Date(),
                                         maxPoints: 400, retention: retention)) ?? []
    }

    // MARK: - windows

    /// Creates the status item and the popover panel (called from AppDelegate once
    /// the app has finished launching).
    func startMenuBar() {
        guard menuPanel == nil else { return }
        let panel = MenuPanelController(model: self)
        menuPanel = panel
        if let button = panel.statusButton {
            button.image = menuBarImage
            button.setAccessibilityLabel(accessibilityText(for: lastMenuEntries))
        }
        if pendingOpenMain {
            pendingOpenMain = false
            openMainWindow()
        }
    }

    func openMainWindow(select: SidebarItem? = nil) {
        if let select { selection = select }
        let w = mainWindow ?? makeMainWindow()
        if w.contentViewController == nil {
            w.contentViewController = NSHostingController(rootView: MainWindow().environmentObject(self))
        }
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "RemotePU"
        w.identifier = NSUserInterfaceItemIdentifier("main")
        w.contentViewController = NSHostingController(rootView: MainWindow().environmentObject(self))
        w.setContentSize(NSSize(width: 1180, height: 820))
        w.contentMinSize = NSSize(width: 820, height: 560)
        w.isReleasedWhenClosed = false // we keep the window and re-show it
        w.delegate = self
        w.center()
        mainWindow = w
        return w
    }

    func openSettings(tab: String? = nil) {
        if let tab { settingsTab = tab }
        NSApp.activate(ignoringOtherApps: true)
        let w = settingsWindow ?? makeSettingsWindow()
        w.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.identifier = NSUserInterfaceItemIdentifier("Settings")
        w.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(self))
        w.setContentSize(NSSize(width: 620, height: 460))
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        return w
    }

    func mainWindowDidChange(visible: Bool) {
        mainWindowVisible = visible
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    func setAppearance(_ name: String) {
        switch name {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - control server

    private func startControlServer() {
        let server = ControlServer(path: paths.controlSocket) { req in
            try await AppModel.shared.handleControl(req)
        }
        do {
            try server.start()
            control = server
            RPULog.shared.log("control", "listening on \(paths.controlSocket)")
        } catch {
            RPULog.shared.log("control", "cannot start control server: \(error)")
        }
    }
}

extension AppModel: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === mainWindow else { return }
        mainWindowDidChange(visible: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === mainWindow else { return }
        mainWindowDidChange(visible: false)
        // The kept-alive window (isReleasedWhenClosed = false) would keep its
        // SwiftUI graph re-rendering on every sample while hidden; drop the
        // content once the close animation is done and rebuild it on next open.
        DispatchQueue.main.async {
            if !w.isVisible { w.contentViewController = nil }
        }
    }
}
