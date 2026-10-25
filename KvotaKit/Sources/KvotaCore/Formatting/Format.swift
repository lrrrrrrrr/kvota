import Foundation

/// Compact, locale-light formatting for small widgets.
public enum Format {
    /// 950 → "950", 12_300 → "12.3K", 4_560_000 → "4.6M".
    public static func tokens(_ value: Int64) -> String {
        let v = Double(value)
        let abs = Swift.abs(v)
        switch abs {
        case ..<1_000: return "\(value)"
        case ..<10_000: return trim(String(format: "%.1fK", v / 1_000))
        case ..<1_000_000: return String(format: "%.0fK", v / 1_000)
        case ..<10_000_000: return trim(String(format: "%.1fM", v / 1_000_000))
        case ..<1_000_000_000: return String(format: "%.0fM", v / 1_000_000)
        default: return trim(String(format: "%.1fB", v / 1_000_000_000))
        }
    }

    /// USD with sensible precision: "$0.42", "$12.30", "$1,240".
    public static func cost(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value < 100 { return String(format: "$%.2f", value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US")
        return "$" + (formatter.string(from: NSNumber(value: value.rounded())) ?? String(format: "%.0f", value))
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Time left until `date`: "45m", "2h 14m", "3d 4h", "now".
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 30 { return "now" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        if hours < 24 { return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m" }
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }

    /// How long ago: "just now", "4m ago", "3h ago", "2d ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// "claude-opus-4-5-20251101" → "Opus 4.5", "gpt-5.1-codex-max" → "GPT-5.1 Codex Max".
    public static func modelName(_ raw: String) -> String {
        var name = raw.lowercased()
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        name = name.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if name.hasPrefix("claude-") {
            let parts = name.dropFirst("claude-".count).split(separator: "-")
            // Both "claude-opus-4-5" and the older "claude-3-5-sonnet" layouts.
            guard let family = parts.first(where: { !$0.allSatisfy(\.isNumber) }) else { return raw }
            let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            let familyName = family.prefix(1).uppercased() + family.dropFirst()
            return version.isEmpty ? familyName : "\(familyName) \(version)"
        }
        if name.hasPrefix("gpt-") {
            let parts = name.split(separator: "-")
            guard parts.count >= 2 else { return raw.uppercased() }
            let head = "GPT-\(parts[1])"
            let tail = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return ([head] + tail).joined(separator: " ")
        }
        if name.hasPrefix("gemini-") {
            // "gemini-2.5-pro" → "Gemini 2.5 Pro"
            let parts = name.dropFirst("gemini-".count).split(separator: "-").map { part -> String in
                part.first?.isLetter == true ? part.prefix(1).uppercased() + part.dropFirst() : String(part)
            }
            return (["Gemini"] + parts).joined(separator: " ")
        }
        return raw
    }

    private static func trim(_ s: String) -> String {
        // "4.0M" → "4M"
        s.replacingOccurrences(of: ".0", with: "")
    }
}
