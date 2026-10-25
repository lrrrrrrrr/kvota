import Foundation

/// Gemini CLI's OAuth client id and secret. Google publishes these in the open-source CLI
/// (they identify the installed app and are not secret). Kvota does not ship them: it reads
/// them from the Gemini CLI installed on this Mac, only to renew an expired login in memory.
struct GeminiOAuthClient: Equatable {
    let id: String
    let secret: String

    static func locate(home: URL) -> GeminiOAuthClient? {
        for root in packageRoots(home: home) {
            if let client = scan(packageRoot: root) { return client }
        }
        return nil
    }

    /// Where npm, Homebrew, Bun, Volta and nvm put the `@google/gemini-cli` package.
    static func packageRoots(home: URL) -> [URL] {
        let fm = FileManager.default
        let package = "@google/gemini-cli"
        var roots: [URL] = []

        // Follow the `gemini` command to its package.
        let binaries = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"] + [
            ".npm-global/bin/gemini", ".bun/bin/gemini", ".volta/bin/gemini", ".local/bin/gemini",
        ].map { home.appendingPathComponent($0).path }
        for binary in binaries where fm.fileExists(atPath: binary) {
            var url = URL(fileURLWithPath: binary).resolvingSymlinksInPath()
            for _ in 0..<6 {
                url.deleteLastPathComponent()
                if isGeminiPackage(url) {
                    roots.append(url)
                    break
                }
            }
        }

        var candidates = [
            "/opt/homebrew/lib/node_modules/\(package)",
            "/usr/local/lib/node_modules/\(package)",
            home.appendingPathComponent(".npm-global/lib/node_modules/\(package)").path,
            home.appendingPathComponent(".bun/install/global/node_modules/\(package)").path,
            home.appendingPathComponent(".volta/tools/image/packages/\(package)/lib/node_modules/\(package)").path,
        ]
        for cellar in ["/opt/homebrew/Cellar/gemini-cli", "/usr/local/Cellar/gemini-cli"] {
            for version in (try? fm.contentsOfDirectory(atPath: cellar)) ?? [] {
                candidates.append("\(cellar)/\(version)/libexec/lib/node_modules/\(package)")
            }
        }
        let nvm = home.appendingPathComponent(".nvm/versions/node").path
        for version in (try? fm.contentsOfDirectory(atPath: nvm)) ?? [] {
            candidates.append("\(nvm)/\(version)/lib/node_modules/\(package)")
        }
        for path in candidates where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if !roots.contains(url) { roots.append(url) }
        }
        return roots
    }

    private static func isGeminiPackage(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("package.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return json["name"] as? String == "@google/gemini-cli"
    }

    /// Looks through the package's JavaScript for the client constants.
    static func scan(packageRoot: URL) -> GeminiOAuthClient? {
        let fm = FileManager.default
        var files: [URL] = []
        let direct = packageRoot.appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
        if fm.fileExists(atPath: direct.path) { files.append(direct) }
        for folder in ["bundle", "dist"] {
            let dir = packageRoot.appendingPathComponent(folder)
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "js" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0, size < 60_000_000 { files.append(url) }
                if files.count > 400 { break }
            }
        }
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard text.contains("GOCSPX-") else { continue }
            if let client = extract(from: text) { return client }
        }
        return nil
    }

    static func extract(from text: String) -> GeminiOAuthClient? {
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) else { return nil }
            return String(text[range])
        }
        let id = first(#"OAUTH_CLIENT_ID\s*=\s*['"]([0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com)['"]"#)
            ?? first(#"[0-9]{6,}-[a-z0-9]{16,}\.apps\.googleusercontent\.com"#)
        let secret = first(#"OAUTH_CLIENT_SECRET\s*=\s*['"](GOCSPX-[A-Za-z0-9_\-]+)['"]"#)
            ?? first(#"GOCSPX-[A-Za-z0-9_\-]{20,}"#)
        guard let id, let secret else { return nil }
        return GeminiOAuthClient(id: id, secret: secret)
    }
}
