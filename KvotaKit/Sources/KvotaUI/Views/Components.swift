import AppKit
import KvotaCore
import SwiftUI

// MARK: - Theme

extension ProviderID {
    /// Accent per provider. Colors only hint; names are always shown too.
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.13, green: 0.66, blue: 0.53)
        case .gemini: Color(red: 0.38, green: 0.53, blue: 0.98)
        }
    }

    /// Two letters for the tightest spots (menu bar text).
    var shortName: String {
        switch self {
        case .claude: "Cl"
        case .codex: "Cx"
        case .gemini: "Gm"
        }
    }
}

enum Theme {
    /// Bars turn amber, then red, as a window fills up.
    static func fill(for used: Double, tint: Color) -> Color {
        if used >= 90 { return Color(red: 0.94, green: 0.27, blue: 0.24) }
        if used >= 75 { return Color(red: 0.96, green: 0.62, blue: 0.10) }
        return tint
    }

    static func gaugeSymbol(_ used: Double?) -> String {
        guard let used else { return "gauge.with.dots.needle.0percent" }
        switch used {
        case ..<17: return "gauge.with.dots.needle.0percent"
        case ..<42: return "gauge.with.dots.needle.33percent"
        case ..<58: return "gauge.with.dots.needle.50percent"
        case ..<83: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}

/// Snapshot tests render without AppKit-backed effects.
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var kvotaSnapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

// MARK: - Small pieces

struct ProviderDot: View {
    let provider: ProviderID
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(provider.tint)
            .frame(width: size, height: size)
    }
}

struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// A thin horizontal meter.
struct MeterBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color)
                    .frame(width: fraction <= 0 ? 0 : max(height, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A small ring that fills clockwise from the top.
struct RingGauge: View {
    let fraction: Double?
    let color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: min(1, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// Seven tiny bars, today on the right.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            let count = max(values.count, 1)
            let gap: CGFloat = 2
            let width = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color.opacity(index == values.count - 1 ? 1 : 0.4))
                        .frame(width: width, height: max(2, geo.size.height * value / peak))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// One limit window: label, percentage, meter and reset countdown.
struct LimitRow: View {
    let window: LimitWindow
    let tint: Color
    let now: Date
    var dense = false

    var body: some View {
        let used = window.usedPercent(at: now)
        VStack(alignment: .leading, spacing: dense ? 2 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.system(size: dense ? 10 : 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let resets = window.resetsAt, !window.isExpired(at: now) {
                    Text(dense ? Format.countdown(to: resets, from: now) : "resets in \(Format.countdown(to: resets, from: now))")
                        .font(.system(size: dense ? 9 : 10))
                        .foregroundStyle(.tertiary)
                }
                Text(Format.percent(used))
                    .font(.system(size: dense ? 10 : 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(used >= 75 ? Theme.fill(for: used, tint: tint) : Color.primary)
            }
            MeterBar(fraction: used / 100, color: Theme.fill(for: used, tint: tint), height: dense ? 4 : 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) limit \(Format.percent(used)) used")
    }
}

// MARK: - Backgrounds

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Rounded translucent card used by the floating widget.
struct WidgetBackground: View {
    @Environment(\.kvotaSnapshotMode) private var snapshotMode
    var cornerRadius: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if snapshotMode {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                VisualEffectBackground().clipShape(shape)
            }
            shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}
