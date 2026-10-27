import Charts
import RemotePUCore
import RPUProtocol
import SwiftUI

/// Horizontal meter: the fill carries severity (accent → warning → critical); the
/// track is a lighter step of the accent ramp so the state reads across the bar.
struct Meter: View {
    let fraction: Double?
    var severity: Severity = .normal
    var height: CGFloat = 6
    var tint: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint?.opacity(0.16) ?? Palette.track.opacity(0.6))
                if let f = fraction {
                    Capsule()
                        .fill(severity.color ?? tint ?? Palette.accent)
                        .frame(width: max(height, geo.size.width * min(1, max(0, f))))
                }
            }
        }
        .frame(height: height)
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "unavailable")
    }
}

/// Label · value row with an optional meter underneath.
struct MeterRow: View {
    let label: String
    let value: String
    var fraction: Double?
    var severity: Severity = .normal
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let symbol = severity.symbol {
                    Image(systemName: symbol).foregroundStyle(severity.color ?? .secondary).imageScale(.small)
                }
                Text(value).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                if let detail { Text(detail).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.callout)
            if fraction != nil { Meter(fraction: fraction, severity: severity) }
        }
    }
}

/// Stat tile: label · value (+ optional caption, severity icon).
struct StatTile: View {
    let label: String
    let value: String
    var caption: String?
    var severity: Severity = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value).font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                if let symbol = severity.symbol {
                    Image(systemName: symbol).foregroundStyle(severity.color ?? .secondary)
                }
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

/// Tiny line for menu rows / cards (single series, no axes).
struct Sparkline: View {
    let values: [Double]
    var domain: ClosedRange<Double> = 0...100
    var color: Color = Palette.accent

    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count > 1 else { return }
                let span = max(domain.upperBound - domain.lowerBound, 0.0001)
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat((min(max(v, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }
}

/// One series in a chart: label + metric + categorical slot.
struct SeriesSpec: Identifiable, Hashable {
    var id: String { metric.description }
    let label: String
    let metric: MetricRef
    let slot: Int
}

private struct LoadedSeries: Identifiable {
    var id: String { spec.id }
    let spec: SeriesSpec
    let points: [SeriesPoint]
}

/// Time-series chart for one measure (one y-axis). Multiple series share the unit
/// (e.g. per-GPU utilisation). Hover shows a crosshair and a tooltip with all values.
struct MetricChart: View {
    @ObservedObject var live: NodeLive
    let title: String
    let series: [SeriesSpec]
    let range: TimeRange
    var yDomain: ClosedRange<Double>?
    var format: (Double) -> String = { Fmt.number($0) }
    /// Divide raw values by this before plotting (e.g. bytes → GB).
    var scale: Double = 1
    var height: CGFloat = 150

    @EnvironmentObject private var model: AppModel
    @State private var stored: [String: [SeriesPoint]] = [:]
    @State private var hover: Date?

    private var data: [LoadedSeries] {
        let raw: [LoadedSeries]
        if range.isLive || live.isDemo {
            let since = Date().addingTimeInterval(-range.seconds)
            raw = series.map { LoadedSeries(spec: $0, points: live.series($0.metric, since: since)) }
        } else {
            raw = series.map { LoadedSeries(spec: $0, points: stored[$0.id] ?? []) }
        }
        guard scale != 1 else { return raw }
        return raw.map { s in
            LoadedSeries(spec: s.spec, points: s.points.map { SeriesPoint(t: $0.t, avg: $0.avg / scale, max: $0.max / scale) })
        }
    }

    var body: some View {
        let loaded = data
        let hasData = loaded.contains { !$0.points.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if hasData {
                chart(loaded)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3))
                    Text("No data yet").font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: height)
            }
        }
        .task(id: TaskKey(range: range, node: live.id, series: series.map(\.id))) {
            guard !range.isLive, !live.isDemo else { return }
            while !Task.isCancelled {
                var next: [String: [SeriesPoint]] = [:]
                for s in series { next[s.id] = await model.series(for: live, metric: s.metric, range: range) }
                stored = next
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private struct TaskKey: Hashable {
        let range: TimeRange
        let node: String
        let series: [String]
    }

    @ViewBuilder
    private func chart(_ loaded: [LoadedSeries]) -> some View {
        let multi = loaded.count > 1
        let now = Date()
        Chart {
            ForEach(loaded) { s in
                ForEach(s.points, id: \.t) { p in
                    LineMark(x: .value("Time", p.t), y: .value(s.spec.label, p.avg), series: .value("Series", s.spec.label))
                        .foregroundStyle(by: .value("Series", s.spec.label))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if !multi {
                    ForEach(s.points, id: \.t) { p in
                        AreaMark(x: .value("Time", p.t), y: .value(s.spec.label, p.avg))
                            .foregroundStyle(LinearGradient(colors: [Palette.series(s.spec.slot).opacity(0.22), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            if range.isLive {
                // Live head: the newest sample of each series, so motion is visible.
                ForEach(loaded) { s in
                    if let last = s.points.last {
                        PointMark(x: .value("Time", last.t), y: .value(s.spec.label, last.avg))
                            .foregroundStyle(Palette.series(s.spec.slot))
                            .symbolSize(28)
                    }
                }
            }
            if let hover {
                RuleMark(x: .value("Time", hover))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(at: hover, loaded)
                    }
            }
        }
        .chartForegroundStyleScale(domain: loaded.map(\.spec.label), range: loaded.map { Palette.series($0.spec.slot) })
        .chartLegend(multi ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .leading, spacing: 4)
        .chartXScale(domain: now.addingTimeInterval(-range.seconds)...now)
        .modifier(OptionalYDomain(domain: yDomain))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.gridline)
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).monospacedDigit() } }
            }
        }
        .chartXAxis {
            AxisMarks(values: timeTicks(end: now)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.gridline)
                AxisValueLabel(format: range.seconds > 86_400 ? .dateTime.month().day() : .dateTime.hour().minute())
            }
        }
        .chartXSelection(value: $hover)
        .frame(height: height)
    }

    /// Round-time ticks kept away from both edges so labels are never clipped.
    private func timeTicks(end: Date) -> [Date] {
        let span = range.seconds
        let steps: [Double] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400, 172_800, 604_800]
        let step = steps.first { span / $0 <= 4.5 } ?? 604_800
        let start = end.timeIntervalSince1970 - span
        let tz = Double(TimeZone.current.secondsFromGMT(for: end))
        var t = ((start + tz) / step).rounded(.up) * step - tz
        var ticks: [Date] = []
        while t <= end.timeIntervalSince1970 - span * 0.1 {
            if t >= start + span * 0.04 { ticks.append(Date(timeIntervalSince1970: t)) }
            t += step
        }
        return ticks
    }

    private func tooltip(at t: Date, _ loaded: [LoadedSeries]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t, format: range.seconds > 86_400 ? .dateTime.month().day().hour().minute() : .dateTime.hour().minute().second())
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(loaded) { s in
                if let p = nearest(s.points, to: t) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.series(s.spec.slot)).frame(width: 8, height: 8)
                        Text(s.spec.label).font(.caption)
                        Spacer(minLength: 8)
                        Text(format(p.avg)).font(.caption.weight(.semibold)).monospacedDigit()
                        if p.max > p.avg + 0.05 {
                            Text(String(localized: "max") + " " + format(p.max)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(minWidth: 140)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func nearest(_ points: [SeriesPoint], to t: Date) -> SeriesPoint? {
        points.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
    }
}

private struct OptionalYDomain: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content }
    }
}

/// Per-core utilisation cells (sequential blue ramp), grouped by cluster.
struct CoreGrid: View {
    let cores: [Double?]
    let clusters: [ClusterInfo]

    var body: some View {
        let groups = grouped()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                VStack(alignment: .leading, spacing: 4) {
                    if groups.count > 1 {
                        Text(verbatim: "\(g.name) · \(g.indices.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    ColumnsLayout(minWidth: 22, maxWidth: 30, spacing: 3) {
                        ForEach(g.indices, id: \.self) { i in
                            let v = i < cores.count ? cores[i] : nil
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Palette.heat(v))
                                .frame(height: 18)
                                .help(Text(verbatim: "CPU \(i): \(Fmt.pct(v))"))
                        }
                    }
                }
            }
        }
    }

    /// Explicit `cpus` lists when the collector sends them, else contiguous blocks
    /// in logical order.
    private func grouped() -> [(name: String, indices: [Int])] {
        var result: [(String, [Int])] = []
        var start = 0
        for c in clusters where c.cores > 0 {
            if let cpus = c.cpus {
                result.append((c.name, cpus))
            } else {
                result.append((c.name, Array(start..<(start + c.cores))))
            }
            start += c.cores
        }
        let covered = Set(result.flatMap(\.1))
        let rest = (0..<cores.count).filter { !covered.contains($0) }
        if !rest.isEmpty { result.append(("CPU", rest)) }
        return result.filter { !$0.1.isEmpty }
    }
}

/// Non-lazy equal-width columns (LazyVGrid renders nothing in ImageRenderer).
struct ColumnsLayout: Layout {
    var minWidth: CGFloat
    var maxWidth: CGFloat = .infinity
    var spacing: CGFloat = 10

    private func columns(for width: CGFloat) -> (count: Int, itemWidth: CGFloat) {
        let count = max(1, Int((width + spacing) / (minWidth + spacing)))
        let w = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (count, min(w, maxWidth))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], height: CGFloat)] {
        let (count, itemWidth) = columns(for: width)
        var result: [(items: [Int], height: CGFloat)] = []
        for start in stride(from: 0, to: subviews.count, by: count) {
            let idx = Array(start..<min(start + count, subviews.count))
            let h = idx.map { subviews[$0].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            result.append((idx, h))
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minWidth * 3 + spacing * 2)
        let r = rows(subviews, width: width)
        let height = r.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, r.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, itemWidth) = columns(for: bounds.width)
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: itemWidth, height: row.height))
                x += itemWidth + spacing
            }
            y += row.height + spacing
        }
    }
}
