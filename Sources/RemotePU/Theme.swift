import AppKit
import RemotePUCore
import RPUProtocol
import SwiftUI

/// Colours follow the dataviz reference palette: categorical slots in fixed order
/// (light/dark steps), a fixed status palette that always ships with an icon + label,
/// and a single-hue blue ramp for magnitude (per-core heat grid).
enum Palette {
    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } ?? false
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { isDark($0) ? hex(dark) : hex(light) })
    }

    /// Categorical slots 1–8 (blue, orange, aqua, yellow, magenta, green, violet, red).
    static let series: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),
        dynamic(light: 0xEB6834, dark: 0xD95926),
        dynamic(light: 0x1BAF7A, dark: 0x199E70),
        dynamic(light: 0xEDA100, dark: 0xC98500),
        dynamic(light: 0xE87BA4, dark: 0xD55181),
        dynamic(light: 0x008300, dark: 0x008300),
        dynamic(light: 0x6250D6, dark: 0x9085E9),
        dynamic(light: 0xE34948, dark: 0xE66767),
    ]

    /// Colour follows the entity (e.g. GPU index), never its rank.
    static func series(_ index: Int) -> Color { series[((index % series.count) + series.count) % series.count] }

    static let accent = series[0]
    /// Meter track: a lighter step of the accent's own ramp.
    static let track = dynamic(light: 0xCDE2FB, dark: 0x184F95)

    // Status (reserved — never used for series).
    static let good = Color(nsColor: hex(0x0CA30C))
    static let warning = Color(nsColor: hex(0xFAB219))
    static let serious = Color(nsColor: hex(0xEC835A))
    static let critical = Color(nsColor: hex(0xD03B3B))

    static let gridline = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)

    /// Sequential blue ramp 100…700; near-zero recedes toward the surface in both modes.
    private static let ramp: [UInt32] = [0xCDE2FB, 0xB7D3F6, 0x9EC5F4, 0x86B6EF, 0x6DA7EC, 0x5598E7, 0x3987E5,
                                         0x2A78D6, 0x256ABF, 0x1C5CAB, 0x184F95, 0x104281, 0x0D366B]

    static func heat(_ value: Double?) -> Color {
        guard let value else { return Color.secondary.opacity(0.15) }
        let i = min(ramp.count - 1, max(0, Int((value / 100) * Double(ramp.count - 1) + 0.5)))
        return Color(nsColor: NSColor(name: nil) { ap in
            isDark(ap) ? hex(ramp[ramp.count - 1 - i]) : hex(ramp[i])
        })
    }
}

enum Severity: Int, Comparable {
    case normal, warning, serious, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var color: Color? {
        switch self {
        case .normal: return nil
        case .warning: return Palette.warning
        case .serious: return Palette.serious
        case .critical: return Palette.critical
        }
    }

    var symbol: String? {
        switch self {
        case .normal: return nil
        case .warning: return "exclamationmark.triangle.fill"
        case .serious: return "flame.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    static func temperature(_ c: Double?) -> Severity {
        guard let c else { return .normal }
        if c >= 95 { return .critical }
        if c >= 88 { return .serious }
        if c >= 80 { return .warning }
        return .normal
    }

    static func fill(_ fraction: Double?) -> Severity {
        guard let f = fraction else { return .normal }
        if f >= 0.98 { return .critical }
        if f >= 0.93 { return .serious }
        if f >= 0.85 { return .warning }
        return .normal
    }
}

enum Fmt {
    static let dash = "–"

    static func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? dash }

    static func temp(_ v: Double?) -> String { v.map { String(format: "%.0f°C", $0) } ?? dash }

    static func watts(_ v: Double?) -> String {
        guard let v else { return dash }
        return v < 10 ? String(format: "%.1f W", v) : String(format: "%.0f W", v)
    }

    static func gib(_ bytes: Double?) -> String {
        guard let b = bytes else { return dash }
        let g = b / 1_073_741_824
        return g < 10 ? String(format: "%.1f GB", g) : String(format: "%.0f GB", g)
    }

    static func gibPair(_ used: Double?, _ total: Double?) -> String {
        guard let used else { return dash }
        guard let total else { return gib(used) }
        let t = total / 1_073_741_824
        let u = used / 1_073_741_824
        return t < 10 ? String(format: "%.1f / %.1f GB", u, t) : String(format: "%.1f / %.0f GB", u, t)
    }

    static func mhz(_ v: Double?) -> String {
        guard let v else { return dash }
        return v >= 1000 ? String(format: "%.2f GHz", v / 1000) : String(format: "%.0f MHz", v)
    }

    static func rpm(_ v: Double?) -> String { v.map { String(format: "%.0f rpm", $0) } ?? dash }

    /// Axis labels: one decimal for small magnitudes (e.g. 0.3 W), integers otherwise.
    static func axis(_ v: Double) -> String {
        abs(v) < 10 && v != v.rounded() ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }

    static func number(_ v: Double?, digits: Int = 1) -> String {
        v.map { String(format: "%.\(digits)f", $0) } ?? dash
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d \(s % 86_400 / 3600)h"
    }
}

extension NodePhase {
    var label: String {
        switch self {
        case .idle: return String(localized: "Idle")
        case .connecting: return String(localized: "Connecting")
        case .probing: return String(localized: "Probing")
        case .deploying: return String(localized: "Deploying agent")
        case .starting: return String(localized: "Starting")
        case .online: return String(localized: "Online")
        case .stale: return String(localized: "No recent data")
        case .offline: return String(localized: "Offline")
        case .authFailed: return String(localized: "Needs attention")
        case .disabled: return String(localized: "Disabled")
        }
    }

    var symbol: String {
        switch self {
        case .online: return "checkmark.circle.fill"
        case .stale: return "exclamationmark.triangle.fill"
        case .connecting, .probing, .deploying, .starting: return "arrow.triangle.2.circlepath"
        case .offline: return "xmark.circle.fill"
        case .authFailed: return "lock.trianglebadge.exclamationmark.fill"
        case .idle, .disabled: return "pause.circle"
        }
    }

    var color: Color {
        switch self {
        case .online: return Palette.good
        case .stale: return Palette.warning
        case .offline: return Palette.serious
        case .authFailed: return Palette.critical
        default: return .secondary
        }
    }
}

/// Status icon + label (never colour alone).
struct StatusBadge: View {
    let status: NodeStatus
    var showLabel = true

    var body: some View {
        HStack(spacing: 5) {
            if status.phase == .online {
                PulseDot(color: Palette.good)
            } else {
                Image(systemName: status.phase.symbol)
                    .foregroundStyle(status.phase.color)
                    .symbolEffect(.pulse, isActive: status.phase.isConnecting)
            }
            if showLabel {
                Text(status.phase.label).foregroundStyle(.secondary)
            }
        }
        .help(status.message ?? status.phase.label)
    }
}

extension HelloMessage {
    var isMac: Bool { os == "macos" }

    var subtitle: String {
        var parts: [String] = []
        if let m = cpu?.model { parts.append(m) }
        if let os = osVersion { parts.append(isMac ? "macOS \(os)" : os) }
        if wsl == true { parts.append("WSL2") }
        return parts.joined(separator: " · ")
    }
}

extension GPUInfo {
    var shortName: String {
        (name ?? "GPU").replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
    }
}

// MARK: - Node icons

/// Curated SF Symbols for labelling machines (all available on macOS 14+).
enum NodeIcons {
    static let all: [String] = [
        "laptopcomputer", "desktopcomputer", "macmini", "macstudio", "macpro.gen3", "display",
        "pc", "server.rack", "cpu", "memorychip", "externaldrive", "cube",
        "bolt", "flame", "brain", "sparkles", "atom", "hare",
        "tortoise", "star", "heart", "house", "building.2", "cloud",
        "gamecontroller", "terminal", "leaf", "moon", "sun.max", "globe.asia.australia",
    ]

    /// Explicit choice, else a guess from the platform reported by the collector.
    static func symbol(for config: NodeConfig, hello: HelloMessage?) -> String {
        if let icon = config.icon, !icon.isEmpty { return icon }
        if config.kind == .local || hello?.os == "macos" {
            // rpu-agent-mac reports the marketing name, e.g. "MacBook Pro (14-inch, M5 Pro)".
            let model = (hello?.model ?? "").lowercased()
            if model.contains("macbook") { return "laptopcomputer" }
            if model.contains("mac mini") || model.hasPrefix("macmini") { return "macmini" }
            if model.contains("mac studio") { return "macstudio" }
            if model.contains("mac pro") { return "macpro.gen3" }
            if model.contains("imac") { return "desktopcomputer" }
            return config.kind == .local ? "laptopcomputer" : "desktopcomputer"
        }
        if hello?.wsl == true { return "pc" }
        if config.kind == .demo { return "sparkles" }
        return "server.rack"
    }
}

// MARK: - Live feedback

/// Radar-style pulse for "online and streaming"; static when Reduce Motion is on.
struct PulseDot: View {
    var color: Color = Palette.good
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(color.opacity(0.45))
                    .scaleEffect(animate ? 2.6 : 1)
                    .opacity(animate ? 0 : 0.9)
            }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { animate = true }
        }
        .accessibilityHidden(true)
    }
}

/// "Updated 2 s ago", ticking every second.
struct UpdatedAgo: View {
    let date: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let date {
                let s = max(0, Int(ctx.date.timeIntervalSince(date)))
                Text(s < 2 ? String(localized: "Updated just now")
                     : String(format: String(localized: "Updated %llds ago"), s))
                    .monospacedDigit()
            }
        }
    }
}

/// Node symbol in a soft rounded tile (dashboard) or bare (menus).
struct NodeIconView: View {
    let symbol: String
    var size: CGFloat = 16
    var tile = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .frame(width: size * 1.5, height: size * 1.5)
            .foregroundStyle(tile ? Palette.accent : .primary)
            .background {
                if tile { RoundedRectangle(cornerRadius: size * 0.35).fill(Palette.track.opacity(0.55)) }
            }
            .accessibilityHidden(true)
    }
}
