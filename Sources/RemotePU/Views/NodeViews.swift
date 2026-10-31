import Charts
import RemotePUCore
import RPUProtocol
import SwiftUI

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            if model.nodes.isEmpty {
                ContentUnavailableView {
                    Label("No nodes", systemImage: "server.rack")
                } description: {
                    Text("Add a Mac or Linux server in Settings → Nodes.")
                } actions: {
                    Button("Add Node…") { model.openSettings(tab: "nodes") }
                }
                .padding(.top, 80)
            } else {
                OverviewGrid()
            }
        }
    }
}

/// Card grid without a ScrollView (also used by the control API's offscreen render).
struct OverviewGrid: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Non-lazy grid: lazy stacks render nothing in ImageRenderer.
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            ForEach(Array(rows().enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .top) {
                    ForEach(row) { node in
                        NodeCard(live: node)
                            .onTapGesture { model.selection = .node(node.id) }
                    }
                }
            }
        }
        .padding(16)
    }

    private func rows() -> [[NodeLive]] {
        stride(from: 0, to: model.nodes.count, by: 2).map { Array(model.nodes[$0..<min($0 + 2, model.nodes.count)]) }
    }
}

/// Compact live summary of one node.
struct NodeCard: View {
    @ObservedObject var live: NodeLive

    var body: some View {
        let s = live.latest
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                NodeIconView(symbol: NodeIcons.symbol(for: live.config, hello: live.hello), size: 16, tile: true)
                Text(live.config.name).font(.headline).lineLimit(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    StatusBadge(status: live.status)
                        .font(.caption)
                    if live.status.phase == .online || live.status.phase == .stale {
                        UpdatedAgo(date: live.latest?.date).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if let h = live.hello {
                Text(h.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if live.status.phase != .online, live.status.phase != .stale, let msg = live.status.message {
                Label(msg, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let s {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        MeterRow(label: String(localized: "CPU"), value: Fmt.pct(s.cpu?.util),
                                 fraction: s.cpu?.util.map { $0 / 100 },
                                 detail: s.cpu?.tempC.map { Fmt.temp($0) })
                        MeterRow(label: String(localized: "Memory"), value: Fmt.gibPair(s.mem?.used, s.mem?.total),
                                 fraction: fraction(s.mem?.used, s.mem?.total),
                                 severity: Severity.fill(fraction(s.mem?.used, s.mem?.total)))
                    }
                    Sparkline(values: live.series(.node(.cpuUtil), since: Date().addingTimeInterval(-300), maxPoints: 90).map(\.avg))
                        .frame(width: 70, height: 34)
                        .accessibilityLabel("CPU utilisation, last 5 minutes")
                }
                ForEach(s.gpus ?? [], id: \.idx) { g in
                    HStack(alignment: .top, spacing: 16) {
                        GPURowCompact(info: live.gpuInfo(g.idx), sample: g, unified: live.gpuInfo(g.idx)?.unified == true)
                        Sparkline(values: live.series(.gpu(key: live.gpuKeys[g.idx] ?? "idx\(g.idx)", .util),
                                                      since: Date().addingTimeInterval(-300), maxPoints: 90).map(\.avg),
                                  color: Palette.series(g.idx))
                            .frame(width: 70, height: 34)
                            .accessibilityLabel("GPU \(g.idx) utilisation, last 5 minutes")
                    }
                }
            } else if live.status.phase.isConnecting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        .contentShape(Rectangle())
    }
}

func fraction(_ used: Double?, _ total: Double?) -> Double? {
    guard let used, let total, total > 0 else { return nil }
    return used / total
}

struct GPURowCompact: View {
    let info: GPUInfo?
    let sample: GPUSample
    let unified: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.series(sample.idx)).frame(width: 8, height: 8)
                Text(verbatim: "GPU \(sample.idx)").font(.callout.weight(.medium))
                Text(info?.shortName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(Fmt.pct(sample.util)).monospacedDigit().font(.callout)
                TemperatureText(value: sample.tempC).font(.callout)
                if let p = sample.powerW { Text(Fmt.watts(p)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Meter(fraction: sample.util.map { $0 / 100 })
            if unified, let used = sample.memUsed {
                HStack {
                    Text("GPU memory (shared)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.gib(used)).font(.caption).monospacedDigit()
                }
            }
            if !unified, sample.memTotal != nil {
                HStack {
                    Text("VRAM").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    let sev = Severity.fill(fraction(sample.memUsed, sample.memTotal))
                    if let symbol = sev.symbol {
                        Image(systemName: symbol).foregroundStyle(sev.color ?? .secondary).imageScale(.small)
                    }
                    Text(Fmt.gibPair(sample.memUsed, sample.memTotal)).font(.caption).monospacedDigit()
                }
                Meter(fraction: fraction(sample.memUsed, sample.memTotal),
                      severity: Severity.fill(fraction(sample.memUsed, sample.memTotal)), height: 4)
            }
        }
    }
}

struct TemperatureText: View {
    let value: Double?

    var body: some View {
        let sev = Severity.temperature(value)
        HStack(spacing: 2) {
            if let symbol = sev.symbol { Image(systemName: symbol).foregroundStyle(sev.color ?? .secondary).imageScale(.small) }
            Text(Fmt.temp(value)).monospacedDigit()
        }
        .foregroundStyle(value == nil ? .secondary : .primary)
    }
}

// MARK: - Detail

struct NodeDetailView: View {
    @ObservedObject var live: NodeLive

    var body: some View {
        ScrollView {
            NodeDetailContent(live: live)
        }
    }
}

/// The detail page body without a ScrollView (also rendered offscreen by `ui.render`).
struct NodeDetailContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: NodeLive

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if live.config.kind == .ssh, live.config.aetherSwitch != nil {
                AetherSection(live: live)
            }
            if let s = live.latest {
                kpis(s)
                cpuSection(s)
                memorySection(s)
                gpuSection(s)
                if live.hello?.isMac == true || s.power?.systemW != nil || !(s.fans ?? []).isEmpty {
                    powerSection(s)
                }
            } else {
                ContentUnavailableView(live.status.phase.label, systemImage: live.status.phase.symbol,
                                       description: Text(live.status.message ?? ""))
                    .padding(.top, 40)
            }
        }
        .padding(16)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            NodeIconView(symbol: NodeIcons.symbol(for: live.config, hello: live.hello), size: 22, tile: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusBadge(status: live.status)
                    if live.status.phase == .online || live.status.phase == .stale {
                        UpdatedAgo(date: live.latest?.date).foregroundStyle(.secondary)
                    }
                    if let m = live.status.message, live.status.phase != .online {
                        Text(m).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let r = live.status.retryAt, r > Date() {
                        Text(String(localized: "Retry at") + " " + r.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if let h = live.hello { InfoChips(hello: h, config: live.config) }
                if let e = live.lastAgentError {
                    Label(e, systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if live.config.kind != .demo {
                Button {
                    model.reconnect(live.id)
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func kpis(_ s: SampleMessage) -> some View {
        let gpus = s.gpus ?? []
        let gpuUtils = gpus.compactMap(\.util)
        let gpuTemp = gpus.compactMap(\.tempC).max()
        let gpuPower = gpus.compactMap(\.powerW)
        let memFrac = fraction(s.mem?.used, s.mem?.total)
        return ColumnsLayout(minWidth: 140, spacing: 10) {
            StatTile(label: String(localized: "CPU"), value: Fmt.pct(s.cpu?.util),
                     caption: s.cpu?.freqMhz.map(Fmt.mhz) ?? s.cpu?.load.map { "load " + $0.map { Fmt.number($0, digits: 2) }.joined(separator: " ") })
            StatTile(label: String(localized: "CPU temperature"), value: Fmt.temp(s.cpu?.tempC),
                     caption: s.cpu?.tempC == nil ? String(localized: "Not available") : nil,
                     severity: Severity.temperature(s.cpu?.tempC))
            StatTile(label: String(localized: "Memory"), value: Fmt.gib(s.mem?.used),
                     caption: memFrac.map { Fmt.pct($0 * 100) + " · " + Fmt.gib(s.mem?.total) },
                     severity: Severity.fill(memFrac))
            if !gpus.isEmpty {
                StatTile(label: gpus.count > 1 ? String(localized: "GPU (max)") : String(localized: "GPU"),
                         value: Fmt.pct(gpuUtils.max()),
                         caption: gpus.count > 1 ? String(localized: "avg") + " " + Fmt.pct(gpuUtils.isEmpty ? nil : gpuUtils.reduce(0, +) / Double(gpuUtils.count)) : nil)
                StatTile(label: String(localized: "GPU temperature"), value: Fmt.temp(gpuTemp), severity: Severity.temperature(gpuTemp))
            }
            if let sys = s.power?.systemW {
                StatTile(label: String(localized: "System power"), value: Fmt.watts(sys))
            } else if !gpuPower.isEmpty {
                StatTile(label: String(localized: "GPU power"), value: Fmt.watts(gpuPower.reduce(0, +)))
            }
        }
    }

    private func cpuSection(_ s: SampleMessage) -> some View {
        SectionCard(title: String(localized: "CPU"), systemImage: "cpu") {
            if let clusters = s.cpu?.clusters, clusters.count > 1 {
                ForEach(clusters, id: \.name) { c in
                    MeterRow(label: c.name, value: Fmt.pct(c.util), fraction: c.util.map { $0 / 100 },
                             detail: c.freqMhz.map(Fmt.mhz))
                }
            }
            if let cores = s.cpu?.cores, !cores.isEmpty {
                CoreGrid(cores: cores, clusters: live.hello?.cpu?.clusters ?? [])
            }
            HStack(alignment: .top, spacing: 14) {
                MetricChart(live: live, model: model, title: String(localized: "Utilisation (%)"),
                            series: [SeriesSpec(label: "CPU", metric: .node(.cpuUtil), slot: 0)],
                            range: model.range, yDomain: 0...100, format: { Fmt.number($0, digits: 0) })
                if live.hello?.caps?.cpuTemp != false {
                    MetricChart(live: live, model: model, title: String(localized: "Temperature (°C)"),
                                series: [SeriesSpec(label: String(localized: "CPU"), metric: .node(.cpuTemp), slot: 0)],
                                range: model.range, format: { Fmt.number($0, digits: 0) })
                }
            }
        }
    }

    private func memorySection(_ s: SampleMessage) -> some View {
        SectionCard(title: String(localized: "Memory"), systemImage: "memorychip") {
            let frac = fraction(s.mem?.used, s.mem?.total)
            MeterRow(label: String(localized: "Used"), value: Fmt.gibPair(s.mem?.used, s.mem?.total),
                     fraction: frac, severity: Severity.fill(frac),
                     detail: s.mem?.pressure.map { String(localized: "pressure") + " " + String(localized: String.LocalizationValue($0)) })
            if let st = s.mem?.swapTotal, st > 0 {
                MeterRow(label: String(localized: "Swap"), value: Fmt.gibPair(s.mem?.swapUsed, st),
                         fraction: fraction(s.mem?.swapUsed, st))
            }
            MetricChart(live: live, model: model, title: String(localized: "Memory used (GB)"),
                        series: [SeriesSpec(label: String(localized: "Used"), metric: .node(.memUsed), slot: 0)],
                        range: model.range,
                        yDomain: s.mem?.total.map { 0...($0 / 1_073_741_824) },
                        format: { Fmt.number($0, digits: 0) }, scale: 1_073_741_824)
        }
    }

    private func gpuSection(_ s: SampleMessage) -> some View {
        let gpus = s.gpus ?? []
        let keys = live.gpuKeys
        func specs(_ m: GPUMetric) -> [SeriesSpec] {
            gpus.map { SeriesSpec(label: "GPU \($0.idx)", metric: .gpu(key: keys[$0.idx] ?? "idx\($0.idx)", m), slot: $0.idx) }
        }
        let unified = live.hello?.gpus?.allSatisfy { $0.unified == true } ?? false
        return Group {
            if !gpus.isEmpty {
                SectionCard(title: gpus.count > 1 ? String(localized: "GPUs") : String(localized: "GPU"), systemImage: "square.stack.3d.up") {
                    ColumnsLayout(minWidth: 300, spacing: 12) {
                        ForEach(gpus, id: \.idx) { g in
                            GPUCard(info: live.gpuInfo(g.idx), sample: g)
                        }
                    }
                    ColumnsLayout(minWidth: 320, spacing: 14) {
                        MetricChart(live: live, model: model, title: String(localized: "GPU utilisation (%)"), series: specs(.util),
                                    range: model.range, yDomain: 0...100, format: { Fmt.number($0, digits: 0) })
                        MetricChart(live: live, model: model, title: String(localized: "GPU temperature (°C)"), series: specs(.temp),
                                    range: model.range, format: { Fmt.number($0, digits: 0) })
                        if gpus.contains(where: { $0.powerW != nil }) {
                            MetricChart(live: live, model: model, title: String(localized: "GPU power (W)"), series: specs(.power),
                                        range: model.range, format: Fmt.axis)
                        }
                        if !unified {
                            MetricChart(live: live, model: model, title: String(localized: "VRAM used (GB)"),
                                        series: specs(.memUsed), range: model.range,
                                        yDomain: gpus.compactMap(\.memTotal).max().map { 0...($0 / 1_073_741_824) },
                                        format: { Fmt.number($0, digits: 0) }, scale: 1_073_741_824)
                        }
                        if gpus.contains(where: { $0.smMhz != nil }) {
                            MetricChart(live: live, model: model, title: String(localized: "GPU clock (MHz)"), series: specs(.smMhz),
                                        range: model.range, format: { Fmt.number($0, digits: 0) })
                        }
                    }
                }
            }
        }
    }

    private func powerSection(_ s: SampleMessage) -> some View {
        SectionCard(title: String(localized: "Power & cooling"), systemImage: "bolt") {
            let p = s.power
            ColumnsLayout(minWidth: 120, spacing: 10) {
                if let v = p?.systemW { StatTile(label: String(localized: "System"), value: Fmt.watts(v)) }
                if let v = p?.cpuW ?? s.cpu?.powerW { StatTile(label: String(localized: "CPU"), value: Fmt.watts(v)) }
                if let v = p?.gpuW { StatTile(label: String(localized: "GPU"), value: Fmt.watts(v)) }
                if let v = p?.aneW { StatTile(label: String(localized: "Neural Engine"), value: Fmt.watts(v)) }
                if let v = p?.dramW { StatTile(label: String(localized: "DRAM"), value: Fmt.watts(v)) }
                ForEach(s.fans ?? [], id: \.idx) { f in
                    StatTile(label: String(localized: "Fan") + " \(f.idx + 1)", value: Fmt.rpm(f.rpm),
                             caption: f.maxRpm.map { String(localized: "max") + " " + Fmt.rpm($0) })
                }
            }
            HStack(alignment: .top, spacing: 14) {
                let specs = powerSpecs(s)
                if !specs.isEmpty {
                    MetricChart(live: live, model: model, title: String(localized: "Power (W)"), series: specs, range: model.range,
                                format: Fmt.axis)
                }
                if !(s.fans ?? []).isEmpty {
                    MetricChart(live: live, model: model, title: String(localized: "Fan speed (rpm, mean)"),
                                series: [SeriesSpec(label: String(localized: "Fans"), metric: .node(.fanRPM), slot: 0)],
                                range: model.range, format: { Fmt.number($0, digits: 0) })
                }
            }
        }
    }
}

private func powerSpecs(_ s: SampleMessage) -> [SeriesSpec] {
    var specs: [SeriesSpec] = []
    if s.power?.systemW != nil {
        specs.append(SeriesSpec(label: String(localized: "System"), metric: .node(.sysPower), slot: 0))
    }
    if s.power?.cpuW != nil || s.cpu?.powerW != nil {
        specs.append(SeriesSpec(label: String(localized: "CPU"), metric: .node(.cpuPower), slot: 1))
    }
    if s.power?.gpuW != nil {
        specs.append(SeriesSpec(label: String(localized: "GPU"), metric: .node(.socGPUPower), slot: 2))
    }
    return specs
}

// MARK: - AetherSwitch

/// GPU mode control for nodes with AetherSwitch configured: current mode,
/// per-mode switch buttons and stop. Polls `mgr status` while visible (nothing
/// here animates per sample — the section re-renders on every poll, not on
/// every metric sample).
struct AetherSection: View {
    @ObservedObject var live: NodeLive
    @EnvironmentObject var model: AppModel
    @Environment(\.renderPreviewMode) private var renderPreviewMode

    private var a: AetherUIState { live.aether }
    private var opRunning: Bool { a.status?.operation?.inProgress == true }
    private var busy: Bool { a.acting || opRunning }
    private var nodeOnline: Bool { live.status.phase == .online || live.status.phase == .stale }
    private var anyActive: Bool {
        guard nodeOnline else { return false }
        if a.status?.currentMode != nil { return true }
        let active: Set<String> = ["ready", "busy", "loading", "unready", "running", "stopping"]
        return a.status?.modes.contains { $0.state.map(active.contains) ?? false } ?? false
    }

    var body: some View {
        SectionCard(title: String(localized: "AetherSwitch"), systemImage: "switch.2",
                    trailing: AnyView(UpdatedAgo(date: a.updatedAt).font(.caption).foregroundStyle(.tertiary))) {
            VStack(alignment: .leading, spacing: 10) {
                if let op = a.status?.operation, op.inProgress == true {
                    operationRow(op)
                }
                ForEach(a.conflictEntries, id: \.self) { c in
                    Label { Text(verbatim: c) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                    }.font(.callout)
                }
                if let err = a.error {
                    Label { Text(verbatim: err) } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.critical)
                    }.font(.callout)
                }
                if a.status == nil, a.error == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(nodeOnline ? String(localized: "Loading") : live.status.phase.label)
                            .foregroundStyle(.secondary)
                    }
                }
                modeList
                HStack {
                    Button {
                        Task { await model.aetherAct(live, .stop) }
                    } label: {
                        Label("Stop all", systemImage: "stop.fill")
                    }
                    .disabled(!anyActive || busy)
                    .help("Stop every managed mode on this node")
                    Spacer()
                }
            }
        }
        .task(id: live.id) {
            // ImageRenderer never runs .task; offscreen renders use the last
            // known state instead (see renderPreviewMode).
            guard !renderPreviewMode else { return }
            while !Task.isCancelled {
                await model.aetherRefresh(live)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var modeList: some View {
        let modes = a.modes
        if modes.isEmpty, a.status != nil {
            Text("No modes registered").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(modes) { m in
                    modeRow(m)
                }
            }
        }
    }

    private func modeRow(_ m: AetherMode) -> some View {
        let rep = a.status?.report(for: m.mode)
        let current = a.status?.currentMode == m.mode
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: aetherStateSymbol(rep?.state))
                .foregroundStyle(aetherStateColor(rep?.state))
                .help(aetherStateLabel(rep?.state))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: m.name ?? m.mode)
                    .font(.callout.weight(current ? .semibold : .regular))
                    .lineLimit(1)
                Text(verbatim: m.mode).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if current, let url = rep?.probe?.publicUrl {
                    Text(verbatim: url).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let e = rep?.error, !e.isEmpty {
                    Text(verbatim: e).font(.caption2).foregroundStyle(Palette.critical).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(aetherStateLabel(rep?.state))
                .font(.caption).foregroundStyle(aetherStateColor(rep?.state))
            if current {
                Text("Current")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Palette.track.opacity(0.7)))
            } else {
                Button(String(localized: "Switch")) {
                    Task { await model.aetherAct(live, .switchTo(m.mode)) }
                }
                .disabled(busy || !nodeOnline)
            }
        }
        .padding(.vertical, 1)
    }

    private func operationRow(_ op: AetherStatus.Operation) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(opText(op)).font(.callout).foregroundStyle(.secondary)
            if let err = op.error, !err.isEmpty {
                Text(verbatim: err).font(.caption).foregroundStyle(Palette.critical).lineLimit(1)
            }
        }
    }

    private func opText(_ op: AetherStatus.Operation) -> String {
        let head: String
        switch op.action {
        case "switch": head = String(format: String(localized: "Switching to %@"), op.target ?? op.mode ?? "")
        case "restart": head = String(format: String(localized: "Restarting %@"), op.target ?? op.mode ?? "")
        case "stop": head = String(localized: "Stopping")
        default: head = (op.action ?? "") + " " + (op.target ?? "")
        }
        return head + " · " + aetherStageLabel(op.stage)
    }
}

extension AetherUIState {
    var conflictEntries: [String] { status?.conflicts ?? [] }
}

/// mgr's per-mode states, mapped to icon + colour (a label always accompanies
/// colour — never colour alone).
func aetherStateSymbol(_ state: String?) -> String {
    switch state {
    case "ready", "running": return "checkmark.circle.fill"
    case "busy": return "bolt.fill"
    case "loading": return "arrow.triangle.2.circlepath"
    case "unready": return "exclamationmark.triangle.fill"
    case "stopping": return "arrow.triangle.2.circlepath"
    case "failed": return "xmark.circle.fill"
    case "conflict": return "exclamationmark.triangle.fill"
    default: return "pause.circle" // stopped / unknown
    }
}

func aetherStateColor(_ state: String?) -> Color {
    switch state {
    case "ready", "running": return Palette.good
    case "busy", "loading": return Palette.accent
    case "unready": return Palette.warning
    case "failed", "conflict": return Palette.critical
    default: return .secondary
    }
}

func aetherStateLabel(_ state: String?) -> String {
    switch state {
    case "ready": return String(localized: "Ready")
    case "busy": return String(localized: "Busy")
    case "loading": return String(localized: "Loading")
    case "unready": return String(localized: "Not ready")
    case "stopping": return String(localized: "Stopping")
    case "running": return String(localized: "Running")
    case "failed": return String(localized: "Failed")
    case "conflict": return String(localized: "Conflict")
    default: return String(localized: "Stopped")
    }
}

func aetherStageLabel(_ stage: String?) -> String {
    switch stage {
    case "begin": return String(localized: "Preparing")
    case "checking": return String(localized: "Checking")
    case "releasing": return String(localized: "Releasing GPU")
    case "starting": return String(localized: "Starting")
    case "loading": return String(localized: "Loading model")
    case "ready", "complete": return String(localized: "Complete")
    case "stopping": return String(localized: "Stopping")
    case "force-stopping": return String(localized: "Force stopping")
    case "failed", "startup-failed": return String(localized: "Failed")
    default: return stage ?? ""
    }
}

struct InfoChips: View {
    let hello: HelloMessage
    let config: NodeConfig

    var body: some View {
        let items = chips()
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
            }
        }
    }

    private func chips() -> [String] {
        var c: [String] = []
        if let host = hello.host { c.append(host) }
        if let model = hello.model { c.append(model) }
        if let k = hello.kernel { c.append((hello.isMac ? "Darwin " : "Linux ") + k) }
        if let arch = hello.arch { c.append(arch) }
        if let cl = hello.cpu?.clusters, !cl.isEmpty {
            c.append(cl.map { "\($0.cores)× \($0.name)" }.joined(separator: " + "))
        } else if let n = hello.cpu?.cores {
            c.append("\(n) CPUs")
        }
        if let m = hello.memTotal { c.append(Fmt.gib(m) + " RAM") }
        for g in hello.gpus ?? [] {
            var s = g.name ?? "GPU"
            if let cores = g.cores { s += " · \(cores)-core" }
            if let mem = g.memTotal, g.unified != true { s += " · " + Fmt.gib(mem) }
            c.append(s)
        }
        if let d = hello.gpus?.first?.driver { c.append("driver " + d) }
        if config.kind == .ssh { c.append(config.target) }
        return c
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Full per-GPU card: meters + clocks/fan/P-state/throttle badges.
struct GPUCard: View {
    let info: GPUInfo?
    let sample: GPUSample

    var body: some View {
        let unified = info?.unified == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.series(sample.idx)).frame(width: 10, height: 10)
                Text(verbatim: "GPU \(sample.idx)").font(.headline)
                Text(info?.shortName ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let ps = sample.pstate {
                    Text(ps).font(.caption.monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                        .help(String(localized: "Performance state (P0 = maximum)"))
                }
            }
            MeterRow(label: String(localized: "Utilisation"), value: Fmt.pct(sample.util),
                     fraction: sample.util.map { $0 / 100 },
                     detail: sample.memUtil.map { String(localized: "bandwidth") + " " + Fmt.pct($0) })
            if !unified {
                let f = fraction(sample.memUsed, sample.memTotal ?? info?.memTotal)
                MeterRow(label: String(localized: "VRAM"), value: Fmt.gibPair(sample.memUsed, sample.memTotal ?? info?.memTotal),
                         fraction: f, severity: Severity.fill(f))
            } else if let used = sample.memUsed {
                MeterRow(label: String(localized: "GPU memory (shared)"), value: Fmt.gib(used))
            }
            if let p = sample.powerW {
                let limit = sample.powerLimitW ?? info?.powerLimitW
                MeterRow(label: String(localized: "Power"), value: Fmt.watts(p), fraction: limit.map { p / $0 },
                         detail: limit.map { "/ " + Fmt.watts($0) })
            }
            HStack(spacing: 14) {
                labeled(String(localized: "Temp"), TemperatureText(value: sample.tempC).font(.callout))
                if let mt = sample.memTempC { labeled(String(localized: "Mem temp"), TemperatureText(value: mt).font(.callout)) }
                if let sm = sample.smMhz {
                    labeled(String(localized: "Clock"), Text(Fmt.mhz(sm)).monospacedDigit().font(.callout))
                }
                if let mm = sample.memMhz {
                    labeled(String(localized: "Mem clock"), Text(Fmt.mhz(mm)).monospacedDigit().font(.callout))
                }
                if let fan = sample.fanPct {
                    labeled(String(localized: "Fan"), Text(Fmt.pct(fan)).monospacedDigit().font(.callout))
                }
                if let gen = sample.pcieGen, !unified {
                    labeled("PCIe", Text(verbatim: "Gen\(gen) ×\(sample.pcieWidth ?? 0)").font(.callout))
                }
            }
            let reasons = (sample.throttle ?? []).filter { $0 != "gpu_idle" }
            if !reasons.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(reasons, id: \.self) { r in
                        Label(throttleLabel(r), systemImage: r.contains("thermal") ? "thermometer.high" : "bolt.badge.clock")
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().strokeBorder(Palette.warning))
                            .help(String(localized: "Clocks reduced: ") + r)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private func labeled<V: View>(_ label: String, _ value: V) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            value
        }
    }

    private func throttleLabel(_ r: String) -> String {
        switch r {
        case "sw_power_cap": return String(localized: "Power cap")
        case "hw_slowdown": return String(localized: "HW slowdown")
        case "sw_thermal": return String(localized: "Thermal (SW)")
        case "hw_thermal": return String(localized: "Thermal (HW)")
        case "hw_power_brake": return String(localized: "Power brake")
        case "app_clocks": return String(localized: "App clocks")
        case "sync_boost": return String(localized: "Sync boost")
        case "display_clocks": return String(localized: "Display clocks")
        default: return r
        }
    }
}
