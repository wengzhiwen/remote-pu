import RemotePUCore
import RPUProtocol
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var sidebarVisible = true

    static let sidebarWidth: CGFloat = 232
    /// Dashboard content stops growing here, so showing/hiding the sidebar (and
    /// resizing a wide window) slides the page without re-wrapping its charts
    /// and tiles — the large horizontal reflow used to make the toggle feel
    /// like a jump.
    static let detailMaxWidth: CGFloat = 950

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            HStack(spacing: 0) {
                if sidebarVisible {
                    Sidebar()
                        .frame(width: Self.sidebarWidth)
                        .background(.regularMaterial)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                DetailFrame {
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
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    /// In-window control bar. Deliberately plain views, not an NSToolbar: the
    /// toolbar SwiftUI syncs into this hand-made NSWindow let scrolled content
    /// draw over the title bar on macOS 26, and the system sidebar toggle
    /// jumped across the window when clicked. Here the bar sits above the
    /// content in a VStack, so neither can happen.
    private var bar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .keyboardShortcut("s", modifiers: [.option, .command])

            Text(pageTitle).font(.headline).lineLimit(1).truncationMode(.middle)

            Spacer()

            Button {
                model.reconnect(nil)
            } label: {
                Label("Reconnect all", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reconnect all nodes")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var pageTitle: String {
        switch model.selection {
        case .node(let id): return model.live(id)?.displayName ?? ""
        default: return String(localized: "Overview")
        }
    }
}

/// Centers the detail page at `MainWindow.detailMaxWidth`.
private struct DetailFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: MainWindow.detailMaxWidth)
            .frame(maxWidth: .infinity)
    }
}

/// The sidebar column: monitoring status and the time-range drawer pinned on
/// top, navigation below (they used to crowd the toolbar).
struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            MonitoringPanel()
            Divider()
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
            .listStyle(.sidebar)
            // The column paints a material behind everything; the list would
            // add its own slightly different background on top.
            .scrollContentBackground(.hidden)
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
        }
    }
}

/// "● Monitoring · 3/4 online" plus the chart time range as a collapsible drawer.
struct MonitoringPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var rangeOpen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LivePill()
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Button {
                withAnimation(.snappy) { rangeOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text("Range")
                    Spacer()
                    Text(verbatim: model.range.rawValue).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: rangeOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Chart time range")
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            if rangeOpen {
                ForEach(TimeRange.allCases) { r in
                    rangeRow(r)
                }
            }
            Divider()
                .padding(.top, 6)
        }
        .padding(.bottom, 8)
    }

    private func rangeRow(_ r: TimeRange) -> some View {
        Button {
            model.range = r
        } label: {
            HStack {
                Text(verbatim: r.rawValue)
                Spacer()
                if r == model.range {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chart time range")
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
        .help(String(localized: "Samples stream once per interval from every online node"))
    }
}
