import Foundation

/// The small shell script Kvota installs as Claude Code's status line command.
///
/// Claude Code sends JSON to the status line command after every reply, including the
/// account's `rate_limits`. The script saves that part next to itself as
/// `rate_limits.json`, then passes the data on to the user's previous status line
/// command, so nothing visible changes. Without a previous command it prints a short
/// line such as `Opus 4.5 · 5h 23% · 7d 41%`.
///
/// It needs only `/bin/sh`, `grep`, `sed` and `tr`, takes a few milliseconds, and never
/// touches the network.
public enum StatusLineBridgeScript {
    public static let fileName = "statusline-bridge.sh"
    public static let snapshotFileName = "rate_limits.json"
    /// Written on every run: when it ran, whether Claude Code included limits, its version.
    public static let lastRunFileName = "last_run.json"
    public static let previousCommandFileName = "statusline-command"
    /// Marker used to recognise the bridge in `settings.json`.
    public static let marker = "kvota/statusline-bridge.sh"

    public static let source = #"""
    #!/bin/sh
    # Kvota status line bridge for Claude Code — https://github.com/lrrrrrrrr/kvota
    # Saves the rate-limit part of Claude Code's status line data for the Kvota widget,
    # then hands the data to your previous status line command (if you had one).
    # Remove it from Kvota's settings to restore your original status line.
    dir=$(cd "$(dirname "$0")" && pwd)
    input=$(cat)
    flat=$(printf '%s' "$input" | tr -d '\n\r')
    limits=$(printf '%s' "$flat" | grep -oE '"rate_limits"[[:space:]]*:[[:space:]]*\{([^{}]|\{[^{}]*\})*\}' | head -n 1)
    if [ -n "$limits" ]; then
      tmp="$dir/.rate_limits.$$"
      if printf '{%s}\n' "$limits" > "$tmp"; then mv -f "$tmp" "$dir/rate_limits.json"; else rm -f "$tmp"; fi
    fi
    version=$(printf '%s' "$flat" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    has=false
    if [ -n "$limits" ]; then has=true; fi
    run="$dir/.last_run.$$"
    if printf '{"at":%s,"rate_limits":%s,"version":"%s"}\n' "$(date +%s)" "$has" "$version" > "$run"; then mv -f "$run" "$dir/last_run.json"; else rm -f "$run"; fi
    if [ -s "$dir/statusline-command" ]; then
      printf '%s' "$input" | /bin/sh -c "$(cat "$dir/statusline-command")"
      exit $?
    fi
    pct() {
      printf '%s' "$limits" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{[^}]*\"used_percentage\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"
    }
    model=$(printf '%s' "$flat" | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*{[^}]*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    line="$model"
    five=$(pct five_hour)
    week=$(pct seven_day)
    if [ -n "$five" ]; then line="${line:+$line · }5h $five%"; fi
    if [ -n "$week" ]; then line="${line:+$line · }7d $week%"; fi
    printf '%s\n' "$line"
    """#
}

/// What the bridge saw the last time Claude Code ran the status line.
public struct StatusLineRun: Equatable, Sendable {
    public var at: Date
    /// False when Claude Code ran the status line without any plan limits, which happens
    /// when it isn't signed in with a Pro or Max plan.
    public var hadRateLimits: Bool
    public var claudeCodeVersion: String?

    public init(at: Date, hadRateLimits: Bool, claudeCodeVersion: String?) {
        self.at = at
        self.hadRateLimits = hadRateLimits
        self.claudeCodeVersion = claudeCodeVersion
    }

    public static func parse(_ data: Data) -> StatusLineRun? {
        guard let root = JSON.object(data), let at = JSON.date(root["at"]) else { return nil }
        return StatusLineRun(
            at: at,
            hadRateLimits: JSON.bool(root["rate_limits"]) ?? false,
            claudeCodeVersion: JSON.string(root["version"])
        )
    }
}
