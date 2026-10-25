import CryptoKit
import Foundation
import KvotaCore
import Security

/// Fetches current Codex and Gemini limits using the login each CLI already has.
///
/// Claude is deliberately not supported here: Anthropic doesn't allow third-party apps to
/// use Claude.ai sign-in tokens, so Kvota gets Claude limits only from Claude Code's
/// documented status line data (see StatusLineBridge).
///
/// Only in the direct-download build, and only for providers the user turns on.
/// Credentials are read on demand, kept in memory, and never written anywhere.
public final class LiveLimitsClient: LiveLimitsProvider, @unchecked Sendable {
    public let supportedProviders: [ProviderID] = [.codex, .gemini]

    private let session: URLSession
    private let lock = NSLock()
    private var gemini = GeminiSession()

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Kvota (+https://github.com/lrrrrrrrr/kvota)"]
        session = URLSession(configuration: configuration)
    }

    public func fetchLimits(for provider: ProviderID, home: URL) async throws -> LimitsSnapshot {
        switch provider {
        case .claude:
            throw KvotaError("Claude limits come from Claude Code's status line, not from a live request.", short: "Uses the status line")
        case .codex: return try await fetchCodex(home: home)
        case .gemini: return try await fetchGemini(home: home)
        }
    }

    private static func runOffMainThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Codex

    private func fetchCodex(home: URL) async throws -> LimitsSnapshot {
        var stored = try? Data(contentsOf: home.appendingPathComponent("auth.json"))
        if stored == nil {
            // With `cli_auth_credentials_store = "keyring"` (or "auto") Codex keeps the same
            // JSON in the Keychain, under an account derived from its home folder.
            let account = Self.codexKeyringAccount(home: home)
            stored = await Self.runOffMainThread {
                Keychain.passwordViaSecurityTool(service: "Codex Auth", account: account)
            }
        }
        guard let data = stored else {
            throw KvotaError(
                "No Codex CLI login found (checked ~/.codex/auth.json and the Keychain). Run codex and sign in with ChatGPT; the Codex desktop app and IDE extensions keep their own login.",
                short: "Sign in to Codex CLI"
            )
        }
        guard let credentials = CodexCredentials.parse(data) else {
            throw KvotaError("Codex is signed in with an API key, which has no plan limits to show.", short: "API key: no plan limits")
        }
        if credentials.isExpired(at: Date()) {
            // Codex renews its login only while it runs; Kvota never touches it.
            throw KvotaError("Codex's login has expired because Codex hasn't run for a while. Run codex once to refresh it.", short: "Run codex to refresh login")
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account = credentials.accountID {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let body = try await send(request, provider: "Codex") { status in
            status == 401 || status == 403
                ? KvotaError("Codex's login has expired. Run codex once to refresh it.", short: "Run codex to refresh login")
                : nil
        }
        guard let snapshot = CodexLimits.parseUsage(body, capturedAt: Date()) else {
            throw KvotaError("ChatGPT returned Codex usage in an unexpected format.")
        }
        return snapshot
    }

    // MARK: - Gemini

    private struct GeminiSession {
        var accessToken: String?
        var expiresAt: Date?
        var project: String?
        var plan: String?
        var projectCheckedAt: Date?
        var client: GeminiOAuthClient?
        var clientSearched = false
    }

    private static let codeAssist = "https://cloudcode-pa.googleapis.com/v1internal"

    /// Codex's Keychain account: "cli|" + the first 16 hex digits of SHA-256(codex home path).
    static func codexKeyringAccount(home: URL) -> String {
        let path = home.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cli|" + digest.prefix(16)
    }

    private func fetchGemini(home: URL) async throws -> LimitsSnapshot {
        let token = try await geminiAccessToken(home: home)

        let needsProject = withLock { () -> Bool in
            guard let checked = gemini.projectCheckedAt else { return true }
            return Date().timeIntervalSince(checked) > 3600
        }
        if needsProject {
            let body: [String: Any] = [
                "metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
            ]
            let data = try await postJSON("\(Self.codeAssist):loadCodeAssist", token: token, body: body)
            let parsed = GeminiLimits.parsePlan(data)
            withLock {
                gemini.plan = parsed.plan
                gemini.project = parsed.project
                gemini.projectCheckedAt = Date()
            }
        }

        let (project, plan) = withLock { (gemini.project, gemini.plan) }
        var body: [String: Any] = [:]
        if let project { body["project"] = project }
        let data = try await postJSON("\(Self.codeAssist):retrieveUserQuota", token: token, body: body)
        guard let snapshot = GeminiLimits.parseQuota(data, capturedAt: Date(), plan: plan) else {
            throw KvotaError("Google returned no quota information for this Gemini login.")
        }
        return snapshot
    }

    private func geminiAccessToken(home: URL) async throws -> String {
        let now = Date()
        if let token = withLock({ () -> String? in
            guard let token = gemini.accessToken, let expires = gemini.expiresAt, expires.timeIntervalSince(now) > 60 else { return nil }
            return token
        }) {
            return token
        }

        var stored = try? Data(contentsOf: home.appendingPathComponent("oauth_creds.json"))
        if stored == nil {
            stored = await Self.runOffMainThread {
                Keychain.passwordViaSecurityTool(service: "gemini-cli-oauth", account: "main-account")
            }
        }
        guard let data = stored, let credentials = GeminiCredentials.parse(data) else {
            throw KvotaError(
                "No Gemini CLI Google login found (checked ~/.gemini/oauth_creds.json and the Keychain). Run gemini and choose \"Login with Google\"; API-key sign-ins have no quota to show.",
                short: "Sign in to Gemini CLI"
            )
        }
        if credentials.hasValidAccessToken(at: now), let token = credentials.accessToken {
            return token
        }

        // Gemini CLI's token lasts an hour and is renewed only while the CLI runs. Renew it in
        // memory with the CLI's own public OAuth client, read from the installed CLI.
        guard let refreshToken = credentials.refreshToken else {
            throw KvotaError("Gemini CLI's login has expired. Run gemini once to refresh it.", short: "Run gemini to refresh login")
        }
        let client: GeminiOAuthClient? = withLock {
            if !gemini.clientSearched {
                gemini.clientSearched = true
                gemini.client = GeminiOAuthClient.locate(home: home.deletingLastPathComponent())
            }
            return gemini.client
        }
        guard let client else {
            throw KvotaError("Gemini CLI's login has expired. Run gemini once to refresh it.", short: "Run gemini to refresh login")
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "client_id": client.id,
            "client_secret": client.secret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        let response = try await send(request, provider: "Google") { status in
            status == 400 || status == 401
                ? KvotaError("Gemini CLI's login has expired. Run gemini once to refresh it.", short: "Run gemini to refresh login")
                : nil
        }
        guard let json = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw KvotaError("Google didn't renew the Gemini login.")
        }
        let lifetime = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3000)
        withLock {
            gemini.accessToken = token
            gemini.expiresAt = Date().addingTimeInterval(lifetime)
        }
        return token
    }

    private func postJSON(_ url: String, token: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, provider: "Gemini") { status in
            if status == 401 {
                self.withLock { self.gemini.accessToken = nil }
                return KvotaError("Gemini CLI's login was rejected. Run gemini once to refresh it.", short: "Run gemini to refresh login")
            }
            if status == 403 {
                return KvotaError("This Google account has no Gemini Code Assist quota to show.", short: "No quota for this account")
            }
            return nil
        }
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest, provider: String, explain: (Int) -> KvotaError?) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw KvotaError("Couldn't reach \(provider): \(error.localizedDescription)", short: "Can't reach \(provider)")
        }
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let error = explain(status) { throw error }
            if status == 429 {
                throw KvotaError("\(provider) is rate limiting usage checks. Kvota will try again later.", short: "Busy, retrying soon")
            }
            throw KvotaError("\(provider) answered with HTTP \(status).", short: "\(provider) error \(status)")
        }
        return data
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

/// Reads generic password items without changing them.
enum Keychain {
    /// Through `/usr/bin/security`. macOS asks the user to allow access the first time,
    /// unless the item already trusts that tool.
    static func passwordViaSecurityTool(service: String, account: String? = nil, timeout: TimeInterval = 60) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        process.arguments = arguments + ["-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // `security -w` prints non-text secrets as hex.
        if text.first != "{", let decoded = Data(hex: text) {
            return decoded
        }
        return Data(text.utf8)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
