import RemotePUCore
import RPUProtocol
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            NodesSettings()
                .tabItem { Label("Nodes", systemImage: "server.rack") }
                .tag("nodes")
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 620, height: 460)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $model.settings.menuBarMode) {
                    Text("Each node: icon + value").tag("nodes")
                    Text("Busiest GPU (with its node icon)").tag("maxGPU")
                    Text("Busiest CPU (with its node icon)").tag("maxCPU")
                    Text("Icon only").tag("icon")
                }
                if model.settings.menuBarMode == "nodes" {
                    Text("Choose each node's icon, value and visibility in Settings → Nodes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let image = model.menuBarImage {
                    LabeledContent("Preview") {
                        Image(nsImage: image).renderingMode(.template).foregroundStyle(.primary)
                    }
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Open dashboard at launch", isOn: $model.settings.openDashboardAtLaunch)
                Toggle("Monitor this Mac", isOn: $model.settings.showLocalNode)
            }
            Section("History") {
                Stepper(value: $model.settings.retention5sDays, in: 1...30, step: 1) {
                    LabeledContent("Keep 5-second data", value: "\(Int(model.settings.retention5sDays)) d")
                }
                Stepper(value: $model.settings.retention1mDays, in: 7...365, step: 7) {
                    LabeledContent("Keep 1-minute data", value: "\(Int(model.settings.retention1mDays)) d")
                }
                Text("The last 30 minutes are kept in memory at 1-second resolution.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}

struct NodesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(model.userNodes) { c in
                    NodeSettingsRow(config: c, live: model.live(c.id))
                        .tag(c.id)
                        .contextMenu {
                            Button("Edit…") { edit(c) }
                            Button("Reconnect") { model.reconnect(c.id) }
                            Divider()
                            Button("Remove", role: .destructive) { model.removeNode(c.id) }
                        }
                        .onTapGesture(count: 2) { edit(c) }
                }
                .onMove { model.moveNodes(from: $0, to: $1) }
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.editor = NodeEditorTarget(id: "new", config: NodeConfig(id: "", name: "", target: ""), isNew: true)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a node")
                Button {
                    if let id = selected { model.removeNode(id) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selected == nil || selected == NodeConfig.localID)
                .help("Remove the selected node")
                Menu {
                    let hosts = SSHConfigParser.load()
                    if hosts.isEmpty { Text("No hosts in ~/.ssh/config") }
                    ForEach(hosts, id: \.alias) { h in
                        Button("\(h.alias)\(h.hostName.map { " (\($0))" } ?? "")") {
                            var c = NodeConfig(id: "", name: h.alias, target: h.alias)
                            c.interval = model.settings.defaultInterval
                            model.editor = NodeEditorTarget(id: "new", config: c, isNew: true)
                        }
                    }
                } label: {
                    Label("Import from SSH config", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button("Edit…") {
                    if let id = selected, let c = model.userNodes.first(where: { $0.id == id }) { edit(c) }
                }
                .disabled(selected == nil)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(item: $model.editor) { target in
            NodeEditor(target: target).environmentObject(model)
        }
    }

    private func edit(_ c: NodeConfig) {
        model.editor = NodeEditorTarget(id: c.id, config: c, isNew: false)
    }
}

struct NodeSettingsRow: View {
    let config: NodeConfig
    let live: NodeLive?

    var body: some View {
        HStack(spacing: 10) {
            NodeIconView(symbol: NodeIcons.symbol(for: config, hello: live?.hello), size: 14, tile: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                    if !config.enabled { Text("disabled").font(.caption).foregroundStyle(.secondary) }
                    if config.enabled && !config.showInMenuBar {
                        Image(systemName: "menubar.rectangle").foregroundStyle(.tertiary).help("Hidden from the menu bar")
                    }
                }
                Text(config.kind == .local ? String(localized: "This Mac") : config.target + (config.auth == .password ? " · " + String(localized: "password") : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let live { LiveStatus(live: live) }
        }
        .padding(.vertical, 2)
    }
}

private struct LiveStatus: View {
    @ObservedObject var live: NodeLive

    var body: some View {
        StatusBadge(status: live.status).font(.caption)
    }
}

struct NodeEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: NodeEditorTarget

    @State private var config: NodeConfig
    @State private var password = ""
    @State private var savePassword = true
    @State private var portText = ""
    @State private var optionsText = ""
    @State private var error: String?

    init(target: NodeEditorTarget) {
        self.target = target
        _config = State(initialValue: target.config)
        _portText = State(initialValue: target.config.port.map(String.init) ?? "")
        _optionsText = State(initialValue: target.config.sshOptions.joined(separator: ", "))
    }

    private var isLocal: Bool { config.kind == .local }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name, prompt: Text("e.g. gpu-box"))
                    IconPicker(selection: $config.icon,
                               automatic: NodeIcons.symbol(for: NodeConfig(id: config.id, name: config.name, kind: config.kind),
                                                           hello: model.live(config.id)?.hello))
                    if !isLocal {
                        TextField("SSH target", text: $config.target, prompt: Text("alias from ~/.ssh/config or user@host"))
                        TextField("Port", text: $portText, prompt: Text("default"))
                        TextField("Identity file", text: Binding(get: { config.identityFile ?? "" },
                                                                 set: { config.identityFile = $0.isEmpty ? nil : $0 }),
                                  prompt: Text("optional, e.g. ~/.ssh/id_ed25519"))
                    }
                }
                if !isLocal {
                    Section("Authentication") {
                        Picker("Method", selection: $config.auth) {
                            Text("SSH keys / agent").tag(SSHAuthMode.system)
                            Text("Password").tag(SSHAuthMode.password)
                        }
                        .pickerStyle(.radioGroup)
                        if config.auth == .password {
                            SecureField("Password", text: $password,
                                        prompt: Text(model.secrets.hasPassword(for: config.id.isEmpty ? "-" : config.id)
                                                     ? String(localized: "saved — leave empty to keep")
                                                     : String(localized: "required")))
                            Toggle("Save in Keychain", isOn: $savePassword)
                            Text("The password is handed to the system ssh through a private askpass helper; it is never written to disk unless saved in the Keychain.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Uses your ~/.ssh/config, keys and ssh-agent. Connections never prompt; failures are shown on the node.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Advanced") {
                        TextField("Extra ssh options", text: $optionsText, prompt: Text("e.g. ProxyJump=bastion, Compression=yes"))
                    }
                }
                Section("Sampling") {
                    Stepper(value: $config.interval, in: 0.5...10, step: 0.5) {
                        LabeledContent("Interval", value: String(format: "%.1f s", config.interval))
                    }
                    Toggle("Enabled", isOn: $config.enabled)
                }
                Section("Menu bar") {
                    Toggle("Show in menu bar", isOn: $config.showInMenuBar)
                    Picker("Value", selection: $config.menuMetric) {
                        Text("Automatic (GPU for GPU servers, else CPU)").tag("auto")
                        Text("CPU utilisation").tag("cpu")
                        Text("GPU utilisation (busiest)").tag("gpu")
                        Text("Temperature (hottest)").tag("temp")
                    }
                    .disabled(!config.showInMenuBar)
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.critical)
                    .padding(.horizontal, 20)
            }
            HStack {
                if !target.isNew, !isLocal {
                    Button("Remove", role: .destructive) {
                        model.removeNode(config.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") {
                    model.editor = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(target.isNew ? String(localized: "Add") : String(localized: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (!isLocal && config.target.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding(16)
        }
        .frame(width: 540, height: isLocal ? 520 : 760)
    }

    private func save() {
        config.name = config.name.trimmingCharacters(in: .whitespaces)
        config.target = config.target.trimmingCharacters(in: .whitespaces)
        config.port = Int(portText.trimmingCharacters(in: .whitespaces))
        config.sshOptions = optionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if config.auth == .password, password.isEmpty, !model.secrets.hasPassword(for: config.id.isEmpty ? "-" : config.id) {
            error = String(localized: "Enter the ssh password.")
            return
        }
        do {
            if target.isNew {
                if config.id.isEmpty { config.id = model.uniqueID(for: config.name) }
                try model.addNode(config, password: password.isEmpty ? nil : password, persistPassword: savePassword)
            } else {
                try model.updateNode(config, password: password.isEmpty ? nil : password, persistPassword: savePassword)
            }
            model.editor = nil
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}

struct AboutSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Data folder") {
                    Button(model.paths.dataDir.path) { NSWorkspace.shared.open(model.paths.dataDir) }
                        .buttonStyle(.link)
                }
                LabeledContent("Control socket", value: model.paths.controlSocket)
                LabeledContent("Mac agent", value: model.agentPath ?? String(localized: "missing"))
                LabeledContent("Askpass helper", value: model.askpassPath ?? String(localized: "missing"))
            }
            Section {
                Toggle("Demo nodes", isOn: Binding(get: { model.demoEnabled }, set: { model.setDemo($0) }))
                Text("Adds two synthetic nodes for trying the interface without hardware.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}

/// Grid of curated SF Symbols; "Automatic" follows the detected platform.
struct IconPicker: View {
    @Binding var selection: String?
    let automatic: String

    var body: some View {
        LabeledContent("Icon") {
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    selection = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: automatic)
                        Text("Automatic")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selection == nil ? Palette.track : Color.clear))
                }
                .buttonStyle(.plain)
                ColumnsLayout(minWidth: 30, maxWidth: 34, spacing: 4) {
                    ForEach(NodeIcons.all, id: \.self) { symbol in
                        Button {
                            selection = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15))
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(selection == symbol ? Palette.track : Color.secondary.opacity(0.08)))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selection == symbol ? Palette.accent : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                .frame(width: 330)
            }
        }
    }
}
