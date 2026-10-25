import Foundation

/// The AI coding tools Kvota knows how to read.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case claude
    case codex
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    /// The command-line tool whose local data Kvota reads.
    public var toolName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .gemini: "Gemini CLI"
        }
    }

    /// Folder in the user's home directory where the tool keeps its data.
    public var homeFolderName: String {
        switch self {
        case .claude: ".claude"
        case .codex: ".codex"
        case .gemini: ".gemini"
        }
    }

    /// Folders (relative to the tool's home folder) that contain usage logs.
    public var logFolders: [String] {
        switch self {
        case .claude: ["projects"]
        case .codex: ["sessions", "archived_sessions"]
        case .gemini: ["tmp"]
        }
    }
}
