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

/// The popover panel (see MenuPanelController): one row per node.
struct MenuBarPanel: View {
    static let width: CGFloat = 400
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("RemotePU").font(.headline)
                Spacer()
                if model.summary.online > 0 {
                    PulseDot(color: Palette.good, size: 7)
                }
                Text("\(model.summary.online)/\(model.summary.total) online")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if model.nodes.isEmpty {
                Text("No nodes configured").foregroundStyle(.secondary).padding(14)
            } else if model.nodes.count <= 4 {
                // A ScrollView has no ideal height in a self-sizing panel and would
                // collapse to zero, so small lists are laid out directly.
                nodeRows
            } else {
                ScrollView { nodeRows }
                    .frame(height: 500)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Open Dashboard") {
                    model.openMainWindow()
                    model.menuPanel?.setOpen(false)
                }
                    .keyboardShortcut("d")
                Spacer()
                Button {
                    model.openSettings()
                    model.menuPanel?.setOpen(false)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings…")
                .accessibilityLabel("Settings…")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit RemotePU")
                .accessibilityLabel("Quit RemotePU")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width)
    }

    private var nodeRows: some View {
        VStack(spacing: 0) {
            ForEach(model.nodes) { node in
                MenuNodeRow(live: node) {
                    model.openMainWindow(select: .node(node.id))
                    model.menuPanel?.setOpen(false)
                }
                if node.id != model.nodes.last?.id {
                    Divider().padding(.horizontal, 10)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    NodeIconView(symbol: NodeIcons.symbol(for: live.config, hello: live.hello), size: 13)
                    Text(live.config.name).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    StatusBadge(status: live.status).font(.caption2).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                if let s = live.latest, live.status.phase == .online || live.status.phase == .stale {
                    VStack(spacing: 6) {
                        MenuResourceRow(label: String(localized: "CPU"), fraction: s.cpu?.util.map { $0 / 100 },
                                        temperature: s.cpu?.tempC)
                        let memFraction = fraction(s.mem?.used, s.mem?.total)
                        MenuResourceRow(label: String(localized: "Memory"), fraction: memFraction,
                                        severity: Severity.fill(memFraction),
                                        capacity: Fmt.gibPair(s.mem?.used, s.mem?.total))
                        ForEach(s.gpus ?? [], id: \.idx) { g in
                            VStack(spacing: 4) {
                                MenuResourceRow(label: "GPU\(g.idx)", fraction: g.util.map { $0 / 100 },
                                                tint: Palette.series(g.idx), temperature: g.tempC)
                                if live.gpuInfo(g.idx)?.unified != true, let total = g.memTotal, total > 0 {
                                    let memFraction = fraction(g.memUsed, total)
                                    MenuResourceRow(label: String(localized: "VRAM"), fraction: memFraction,
                                                    severity: Severity.fill(memFraction),
                                                    tint: Palette.series(g.idx),
                                                    capacity: Fmt.gibPair(g.memUsed, total), indented: true)
                                }
                            }
                        }
                    }
                } else if let msg = live.status.message {
                    Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open Dashboard")
    }
}

/// Current readings only: bars and percentages share one column; units explain
/// the trailing temperature or capacity. Trends belong in the dashboard.
private struct MenuResourceRow: View {
    let label: String
    let fraction: Double?
    var severity: Severity = .normal
    var tint: Color?
    var temperature: Double?
    var capacity: String?
    var indented = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if let tint, !indented {
                    RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 6, height: 6)
                }
                Text(label).foregroundStyle(.secondary)
            }
            .padding(.leading, indented ? 10 : 0)
            .frame(width: 46, alignment: .leading)
            Meter(fraction: fraction, severity: severity, height: 4, tint: tint)
                .accessibilityHidden(true)
            HStack(spacing: 3) {
                if let symbol = severity.symbol {
                    Image(systemName: symbol).foregroundStyle(severity.color ?? .secondary)
                        .font(.system(size: 9))
                }
                Text(Fmt.pct(fraction.map { $0 * 100 })).monospacedDigit()
            }
            .frame(width: 46, alignment: .trailing)
            HStack(spacing: 3) {
                if let capacity {
                    Text(capacity).monospacedDigit()
                } else if let temperature {
                    Image(systemName: "thermometer.medium").foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    TemperatureText(value: temperature)
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 92, alignment: .trailing)
        }
        .font(.caption2)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
