import Foundation

/// Incrementally reads the CLIs' log folders and keeps compact per-15-minute,
/// per-model token totals.
///
/// Only bytes appended since the last scan are read, so a refresh after a Claude
/// reply touches one file and a few kilobytes. Not thread-safe: use it through
/// ``UsageStore``.
public final class UsageEngine {
    public let retentionDays: Int
    static let slotSeconds: Double = 900
    private static let recentWindow = 16

    private var ledgers: [ProviderID: Ledger] = [:]
    private var logLimits: [ProviderID: LimitsSnapshot] = [:]

    public init(retentionDays: Int = 35) {
        self.retentionDays = max(8, retentionDays)
    }

    // MARK: - Scanning

    /// Scans `home` (for example `~/.claude`) and returns `true` when totals changed.
    @discardableResult
    public func scan(_ provider: ProviderID, home: URL, now: Date = Date()) -> Bool {
        let ledger = ledger(for: provider)
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let candidates = discover(provider, home: home, cutoff: cutoff).sorted { $0.modified < $1.modified }

        var changed = false
        let present = Set(candidates.map(\.path))
        for path in ledger.files.keys where !present.contains(path) {
            ledger.release(path)
            changed = true
        }
        for candidate in candidates {
            if let record = ledger.files[candidate.path],
               record.size == candidate.size, record.modified == candidate.modified {
                continue
            }
            process(candidate, provider: provider, ledger: ledger, cutoff: cutoff)
            changed = true
        }
        if changed { ledger.aggregate = nil }
        return changed
    }

    /// Latest limits found inside the logs themselves (Codex writes them there).
    public func limitsFromLogs(_ provider: ProviderID) -> LimitsSnapshot? {
        logLimits[provider]
    }

    public func trackedFileCount(_ provider: ProviderID) -> Int {
        ledgers[provider]?.files.count ?? 0
    }

    public func forget(_ provider: ProviderID) {
        ledgers[provider] = nil
        logLimits[provider] = nil
    }

    // MARK: - Summaries

    public func summary(_ provider: ProviderID, now: Date = Date(), calendar: Calendar = .current) -> ProviderUsageSummary {
        var summary = ProviderUsageSummary(provider: provider)
        let todayStart = calendar.startOfDay(for: now)
        let dayStarts: [Date] = (0..<7).reversed().map {
            calendar.date(byAdding: .day, value: -$0, to: todayStart) ?? todayStart.addingTimeInterval(-Double($0) * 86_400)
        }
        summary.daily = dayStarts.map { DayUsage(day: $0, totals: UsageTotals()) }
        guard let ledger = ledgers[provider] else { return summary }

        let nowSlot = Self.slot(now)
        let todaySlot = Self.slot(todayStart)
        let fiveHourSlot = nowSlot - 19
        let daySlots = dayStarts.map(Self.slot)
        let weekSlot = daySlots[0]
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart
        let monthSlot = Self.slot(monthStart)

        var prices: [Int32: ModelPrice?] = [:]
        var perModel: [Int32: UsageTotals] = [:]

        for (key, bucket) in ledger.aggregated() where bucket.requests > 0 || !bucket.counts.isZero {
            let price: ModelPrice?
            if let cached = prices[key.model] {
                price = cached
            } else {
                price = Pricing.price(for: ledger.models[Int(key.model)])
                prices[key.model] = .some(price)
            }
            let cost = price?.cost(of: bucket.counts)
            let requests = Int(bucket.requests)

            if key.slot >= monthSlot { summary.thisMonth.add(bucket.counts, requests: requests, cost: cost) }
            if key.slot >= todaySlot { summary.today.add(bucket.counts, requests: requests, cost: cost) }
            if key.slot >= fiveHourSlot { summary.last5Hours.add(bucket.counts, requests: requests, cost: cost) }
            if key.slot >= weekSlot {
                summary.last7Days.add(bucket.counts, requests: requests, cost: cost)
                perModel[key.model, default: UsageTotals()].add(bucket.counts, requests: requests, cost: cost)
                if let day = daySlots.lastIndex(where: { $0 <= key.slot }) {
                    summary.daily[day].totals.add(bucket.counts, requests: requests, cost: cost)
                }
            }
        }

        summary.models = perModel
            .map { ModelUsage(model: ledger.models[Int($0.key)], totals: $0.value) }
            .filter { !$0.totals.isEmpty }
            .sorted { $0.totals.tokens.total > $1.totals.tokens.total }
        summary.lastActivity = ledger.files.values.compactMap(\.lastEvent).max()
        summary.filesTracked = ledger.files.count
        return summary
    }

    // MARK: - Internals

    static func slot(_ date: Date) -> Int32 {
        Int32(clamping: Int64((date.timeIntervalSince1970 / slotSeconds).rounded(.down)))
    }

    private func ledger(for provider: ProviderID) -> Ledger {
        if let existing = ledgers[provider] { return existing }
        let created = Ledger()
        ledgers[provider] = created
        return created
    }

    private func process(_ file: Candidate, provider: ProviderID, ledger: Ledger, cutoff: Date) {
        let record = ledger.files[file.path] ?? FileRecord()
        let inode = Self.fileNumber(file.url)
        let rewritten = file.size < record.offset || (record.inode != 0 && inode != 0 && record.inode != inode)
        if record.offset > 0 && (rewritten || file.kind != .jsonl) {
            ledger.clear(record)
        }

        var context = LineContext(ledger: ledger, record: record, cutoff: cutoff)
        do {
            switch file.kind {
            case .jsonl:
                record.offset = try LineScanner.scan(url: file.url, from: record.offset) { line in
                    handle(line, provider: provider, context: &context)
                }
            case .zstd:
                try ZstdLineScanner.scan(url: file.url) { line in
                    handle(line, provider: provider, context: &context)
                }
                record.offset = file.size
            case .jsonDocument:
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                for event in GeminiLogParser.events(fromDocument: data) {
                    add(event, context: &context)
                }
                record.offset = file.size
            }
        } catch {
            // Unreadable right now (permissions, mid-write). Try again on the next scan.
        }

        record.size = file.size
        record.modified = file.modified
        record.inode = inode
        ledger.files[file.path] = record
    }

    private struct LineContext {
        let ledger: Ledger
        let record: FileRecord
        let cutoff: Date
    }

    private func handle(_ line: UnsafeRawBufferPointer, provider: ProviderID, context: inout LineContext) {
        let parsed: ParsedLine?
        switch provider {
        case .claude: parsed = ClaudeLogParser.parse(line: line, state: &context.record.parser)
        case .codex: parsed = CodexLogParser.parse(line: line, state: &context.record.parser)
        case .gemini: parsed = GeminiLogParser.parse(line: line, state: &context.record.parser)
        }
        switch parsed {
        case let .usage(event)?:
            add(event, context: &context)
        case let .limits(limits)?:
            updateLimits(limits)
        case let .usageAndLimits(event, limits)?:
            add(event, context: &context)
            updateLimits(limits)
        case nil:
            break
        }
    }

    private func updateLimits(_ limits: LimitsSnapshot) {
        if let existing = logLimits[limits.provider], existing.capturedAt > limits.capturedAt { return }
        logLimits[limits.provider] = limits
    }

    private func add(_ event: UsageEvent, context: inout LineContext) {
        guard event.timestamp >= context.cutoff else { return }
        let ledger = context.ledger
        let record = context.record
        let slotKey = SlotKey(slot: Self.slot(event.timestamp), model: ledger.intern(event.model))

        if let keyString = event.dedupeKey {
            let key = Self.hash(keyString)
            if let index = record.recent.firstIndex(where: { $0.key == key }) {
                // The same reply written again a few lines later (streaming). Keep the
                // most complete reading instead of counting it twice.
                let previous = record.recent[index]
                let better = event.counts.output > previous.counts.output
                    || (event.counts.output == previous.counts.output && event.counts.total > previous.counts.total)
                if better {
                    record.buckets[previous.slotKey, default: Bucket()].counts -= previous.counts
                    record.buckets[slotKey, default: Bucket()].counts += event.counts
                    if previous.slotKey != slotKey {
                        record.buckets[previous.slotKey, default: Bucket()].requests -= 1
                        record.buckets[slotKey, default: Bucket()].requests += 1
                    }
                    record.recent[index] = RecentEntry(key: key, slotKey: slotKey, counts: event.counts)
                }
                return
            }
            if ledger.claimed.contains(key) { return }
            ledger.claimed.insert(key)
            record.claimedKeys.append(key)
            record.recent.append(RecentEntry(key: key, slotKey: slotKey, counts: event.counts))
            if record.recent.count > Self.recentWindow { record.recent.removeFirst() }
        }

        record.buckets[slotKey, default: Bucket()].counts += event.counts
        record.buckets[slotKey, default: Bucket()].requests += 1
        if record.lastEvent.map({ event.timestamp > $0 }) ?? true {
            record.lastEvent = event.timestamp
        }
    }

    // MARK: - File discovery

    enum FileKind: Equatable { case jsonl, zstd, jsonDocument }

    struct Candidate {
        let url: URL
        let path: String
        let size: UInt64
        let modified: Date
        let kind: FileKind
    }

    func discover(_ provider: ProviderID, home: URL, cutoff: Date) -> [Candidate] {
        var found: [Candidate] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let fm = FileManager.default
        for folder in provider.logFolders {
            let root = home.appendingPathComponent(folder, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
                  let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if provider == .codex, Self.isOldCodexDayFolder(url, root: root, cutoff: cutoff) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff,
                      let kind = Self.kind(of: url, provider: provider)
                else { continue }
                found.append(Candidate(
                    url: url,
                    path: url.path,
                    size: UInt64(max(0, values.fileSize ?? 0)),
                    modified: modified,
                    kind: kind
                ))
            }
        }
        return found
    }

    static func kind(of url: URL, provider: ProviderID) -> FileKind? {
        let name = url.lastPathComponent
        switch provider {
        case .claude:
            return name.hasSuffix(".jsonl") ? .jsonl : nil
        case .codex:
            guard name.hasPrefix("rollout-") else { return nil }
            if name.hasSuffix(".jsonl") { return .jsonl }
            if name.hasSuffix(".jsonl.zst") { return .zstd }
            return nil
        case .gemini:
            guard url.pathComponents.contains("chats") else { return nil }
            if name.hasSuffix(".jsonl") { return .jsonl }
            if name.hasSuffix(".json") { return .jsonDocument }
            return nil
        }
    }

    /// Codex stores rollouts in `sessions/YYYY/MM/DD`; whole days older than the cutoff are skipped.
    static func isOldCodexDayFolder(_ url: URL, root: URL, cutoff: Date) -> Bool {
        let parts = url.pathComponents
        guard parts.count >= 4, parts[parts.count - 4] == root.lastPathComponent else { return false }
        let tail = parts.suffix(3).map(String.init)
        guard tail[0].count == 4, let year = Int(tail[0]), let month = Int(tail[1]), let day = Int(tail[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return false }
        let days = Timestamp.daysFromCivil(year: year, month: month, day: day)
        // The folder date is local time; allow a day of slack for time zones.
        let endOfDay = Date(timeIntervalSince1970: Double(days + 2) * 86_400)
        return endOfDay < cutoff
    }

    static func fileNumber(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        switch attributes[.systemFileNumber] {
        case let n as NSNumber: return n.uint64Value
        case let n as UInt64: return n
        case let n as Int: return UInt64(max(0, n))
        default: return 0
        }
    }

    /// FNV-1a, enough to tell request ids apart without keeping the strings.
    static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Storage

struct SlotKey: Hashable {
    var slot: Int32
    var model: Int32
}

struct Bucket {
    var counts = TokenCounts()
    var requests: Int32 = 0
}

struct RecentEntry {
    var key: UInt64
    var slotKey: SlotKey
    var counts: TokenCounts
}

final class FileRecord {
    var size: UInt64 = 0
    var modified: Date = .distantPast
    var inode: UInt64 = 0
    var offset: UInt64 = 0
    var buckets: [SlotKey: Bucket] = [:]
    var claimedKeys: [UInt64] = []
    var recent: [RecentEntry] = []
    var parser = ParserState()
    var lastEvent: Date?
}

final class Ledger {
    var files: [String: FileRecord] = [:]
    var claimed: Set<UInt64> = []
    var models: [String] = []
    var modelIndex: [String: Int32] = [:]
    var aggregate: [SlotKey: Bucket]?

    func intern(_ model: String) -> Int32 {
        if let index = modelIndex[model] { return index }
        let index = Int32(models.count)
        models.append(model)
        modelIndex[model] = index
        return index
    }

    /// Drops everything a file contributed, so it can be read again from the start.
    func clear(_ record: FileRecord) {
        claimed.subtract(record.claimedKeys)
        record.claimedKeys.removeAll()
        record.buckets.removeAll()
        record.recent.removeAll()
        record.parser = ParserState()
        record.lastEvent = nil
        record.offset = 0
        aggregate = nil
    }

    func release(_ path: String) {
        guard let record = files.removeValue(forKey: path) else { return }
        claimed.subtract(record.claimedKeys)
        aggregate = nil
    }

    func aggregated() -> [SlotKey: Bucket] {
        if let aggregate { return aggregate }
        var merged: [SlotKey: Bucket] = [:]
        for record in files.values {
            for (key, bucket) in record.buckets {
                merged[key, default: Bucket()].counts += bucket.counts
                merged[key, default: Bucket()].requests += bucket.requests
            }
        }
        aggregate = merged
        return merged
    }
}

/// Thread-safe front for ``UsageEngine``: scanning runs off the main thread.
public actor UsageStore {
    private let engine: UsageEngine

    public init(retentionDays: Int = 35) {
        engine = UsageEngine(retentionDays: retentionDays)
    }

    @discardableResult
    public func scan(_ provider: ProviderID, home: URL, now: Date = Date()) -> Bool {
        engine.scan(provider, home: home, now: now)
    }

    public func summary(_ provider: ProviderID, now: Date = Date(), calendar: Calendar = .current) -> ProviderUsageSummary {
        engine.summary(provider, now: now, calendar: calendar)
    }

    public func limitsFromLogs(_ provider: ProviderID) -> LimitsSnapshot? {
        engine.limitsFromLogs(provider)
    }

    public func forget(_ provider: ProviderID) {
        engine.forget(provider)
    }
}
