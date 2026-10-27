import RemotePUCore
import RPUProtocol
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
                Section("Nodes") {
                    ForEach(model.nodes) { node in
                        SidebarRow(live: node).tag(SidebarItem.node(node.id))
                            .contextMenu {
                                Button("Reconnect") { model.reconnect(node.id) }
                                if node.config.kind != .demo {
                                    Button("Edit…") {
                                        model.editor = NodeEditorTarget(id: node.id, config: node.config, isNew: false)
                                        model.openSettings(tab: "nodes")
                                    }
                                }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        model.editor = NodeEditorTarget(id: "new", config: NodeConfig(id: "", name: "", target: ""), isNew: true)
                        model.openSettings(tab: "nodes")
                    } label: {
                        Label("Add Node", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(10)
            }
        } detail: {
            switch model.selection {
            case .node(let id):
                if let live = model.live(id) {
                    NodeDetailView(live: live).id(id)
                } else {
                    OverviewView()
                }
            default:
                OverviewView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $model.range) {
                    ForEach(TimeRange.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .help("Chart time range")
            }
            ToolbarItem {
                LivePill()
            }
            ToolbarItem {
                Button {
                    model.reconnect(nil)
                } label: {
                    Label("Reconnect all", systemImage: "arrow.clockwise")
                }
                .help("Reconnect all nodes")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct SidebarRow: View {
    @ObservedObject var live: NodeLive

    var body: some View {
        HStack(spacing: 8) {
            NodeIconView(symbol: NodeIcons.symbol(for: live.config, hello: live.hello), size: 14, tile: true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(live.config.name).lineLimit(1)
                    StatusBadge(status: live.status, showLabel: false).font(.caption2)
                }
                if let s = live.latest, live.status.phase == .online || live.status.phase == .stale {
                    let gpu = s.gpus?.compactMap(\.util).max()
                    Text("CPU \(Fmt.pct(s.cpu?.util))" + (gpu.map { " · GPU \(Fmt.pct($0))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(live.status.phase.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .help(live.status.message ?? live.status.phase.label)
    }
}

/// "● Monitoring · 3/4 online" — tells at a glance that data is streaming.
struct LivePill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.summary.online > 0 {
                PulseDot(color: Palette.good, size: 7)
                Text("Monitoring")
            } else {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("Not connected").foregroundStyle(.secondary)
            }
            Text("\(model.summary.online)/\(model.summary.total) online").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .help(String(localized: "Samples stream once per interval from every online node"))
    }
}
