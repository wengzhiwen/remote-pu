import RemotePUCore
import RPUProtocol
import SwiftUI

/// What gets rendered into the status item: per node "icon value", e.g. 💻 21%  🖥 97%.
/// Drawn black-on-clear and used as a template image so macOS tints it for the menu bar.
struct MenuBarTitleContent: View {
    let entries: [MenuBarEntry]
    let problems: Int

    var body: some View {
        HStack(spacing: 9) {
            if entries.isEmpty {
                Image(systemName: problems > 0 ? "exclamationmark.triangle" : "gauge.with.dots.needle.67percent")
                    .font(.system(size: 14, weight: .medium))
            }
            ForEach(entries) { e in
                HStack(spacing: 3) {
                    Image(systemName: e.symbol)
                        .font(.system(size: 13, weight: .medium))
                    if e.attention {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(e.text)
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
                .fixedSize()
                .opacity(e.online ? 1 : 0.45)
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 1)
        .frame(height: 22)
    }
}

/// Status-item label: the pre-rendered title image (re-rendered when values change).
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let image = model.menuBarImage {
                Image(nsImage: image)
            } else {
                Image(systemName: "gauge.with.dots.needle.67percent")
            }
        }
        .accessibilityLabel(accessibilityText)
        .onAppear {
            model.registerOpenWindow { openWindow(id: $0) }
            model.openSettingsAction = { openSettings() }
        }
    }

    private var accessibilityText: String {
        let parts = model.menuBarEntries().map { e in "\(model.live(e.id)?.config.name ?? e.id) \(e.text)" }
        return parts.isEmpty ? "RemotePU" : parts.joined(separator: ", ")
    }
}

/// Window-style MenuBarExtra content: one row per node.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("RemotePU").font(.headline)
                Spacer()
                if model.summary.online > 0 {
                    PulseDot(color: Palette.good, size: 7)
                    Text("Monitoring").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(model.summary.online)/\(model.summary.total) online")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if model.nodes.isEmpty {
                Text("No nodes configured").foregroundStyle(.secondary).padding(14)
            } else if model.nodes.count <= 6 {
                // A ScrollView has no ideal height in a self-sizing panel and would
                // collapse to zero, so small lists are laid out directly.
                nodeRows
            } else {
                ScrollView { nodeRows }
                    .frame(height: 460)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Open Dashboard") { model.openMainWindow() }
                    .keyboardShortcut("d")
                Spacer()
                Button {
                    model.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings…")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit RemotePU")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .onAppear {
            model.openWindowAction = { openWindow(id: $0) }
            model.openSettingsAction = { openSettings() }
        }
    }

    private var nodeRows: some View {
        VStack(spacing: 2) {
            ForEach(model.nodes) { node in
                MenuNodeRow(live: node) {
                    model.openMainWindow(select: .node(node.id))
                }
            }
        }
        .padding(6)
    }
}

struct MenuNodeRow: View {
    @ObservedObject var live: NodeLive
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    NodeIconView(symbol: NodeIcons.symbol(for: live.config, hello: live.hello), size: 13)
                    Text(live.config.name).font(.callout.weight(.medium)).lineLimit(1)
                    StatusBadge(status: live.status, showLabel: false).font(.caption)
                    Spacer()
                    if let s = live.latest, live.status.phase == .online || live.status.phase == .stale {
                        Text("CPU \(Fmt.pct(s.cpu?.util))").font(.caption).monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy, value: s.cpu?.util)
                        TemperatureText(value: s.cpu?.tempC).font(.caption)
                    } else {
                        Text(live.status.phase.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let s = live.latest, live.status.phase == .online || live.status.phase == .stale {
                    ForEach(s.gpus ?? [], id: \.idx) { g in
                        HStack(spacing: 6) {
                            Text(verbatim: "GPU\(g.idx)").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                            Meter(fraction: g.util.map { $0 / 100 }, height: 5)
                            Text(Fmt.pct(g.util)).font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
                                .contentTransition(.numericText())
                                .animation(.snappy, value: g.util)
                            TemperatureText(value: g.tempC).font(.caption2).frame(width: 46, alignment: .trailing)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("MEM").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                        let f = fraction(s.mem?.used, s.mem?.total)
                        Meter(fraction: f, severity: Severity.fill(f), height: 5)
                        Text(Fmt.pct(f.map { $0 * 100 })).font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
                        Sparkline(values: live.series(.node(.cpuUtil), since: Date().addingTimeInterval(-180)).map(\.avg))
                            .frame(width: 46, height: 12)
                    }
                } else if let msg = live.status.message {
                    Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
