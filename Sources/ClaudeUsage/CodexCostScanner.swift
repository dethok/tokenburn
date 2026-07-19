import Foundation

// MARK: - Local Codex token/cost scan. Real schema verified against ~/.codex/sessions/**/*.jsonl:
// each line is {"timestamp","type","payload"}.
// - "turn_context" events carry payload.model (e.g. "gpt-5.5") — the current model, holds until
//   the next turn_context in the same file.
// - "event_msg" events with payload.type=="token_count" carry payload.info.last_token_usage — the
//   PER-TURN incremental token delta (verified against a real session: summing last_token_usage
//   across a file's token_count events reproduces the final cumulative total_token_usage exactly,
//   e.g. 28711 + 36794 = 65505 = the next event's total).
// - total_tokens = input_tokens + output_tokens; cached_input_tokens/reasoning_output_tokens are
//   sub-components of input/output respectively, not additive on top.
// Never logs/prints raw content — only counts and USD totals.

enum CodexCostScanner {
    struct Result {
        var totalTokens: Int64 = 0
        var totalUSD: Double = 0
        var allPriced = true   // false if any encountered model lacks a verified price
        var fileCount: Int = 0
    }

    /// input/cachedInput/output token counts — kept split (not just a total) so USD can be
    /// computed correctly from the cache at any aggregation granularity without a reparse.
    struct TokenBreakdown: Codable {
        var input: Int64 = 0
        var cachedInput: Int64 = 0
        var output: Int64 = 0
        var total: Int64 { input + output }
        static func + (a: TokenBreakdown, b: TokenBreakdown) -> TokenBreakdown {
            TokenBreakdown(input: a.input + b.input, cachedInput: a.cachedInput + b.cachedInput, output: a.output + b.output)
        }
    }

    private struct Price { let inPerM: Double; let cachedPerM: Double; let outPerM: Double }

    // Verified against https://developers.openai.com/api/docs/pricing (platform.openai.com/docs/pricing
    // redirects there) on 2026-07-20. Only "gpt-5.5" exact-matched a row on the fetched page.
    // gpt-5.5-codex / gpt-5.6 / gpt-5.6-codex — all present in the real logs — did NOT appear under
    // those exact names (the page only lists gpt-5.6-sol/terra/luna variants and gpt-5.5-pro).
    // Add them here once independently verified against a real price row; never guess.
    private static let priceTable: [String: Price] = [
        "gpt-5.5": Price(inPerM: 5.00, cachedPerM: 0.50, outPerM: 30.00),
    ]

    private static func costUSD(_ b: TokenBreakdown, model: String) -> Double? {
        guard let p = priceTable[model] else { return nil }
        let nonCachedInput = max(Double(b.input - b.cachedInput), 0)
        return (nonCachedInput * p.inPerM + Double(b.cachedInput) * p.cachedPerM + Double(b.output) * p.outPerM) / 1_000_000
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static func parseTimestamp(_ s: String) -> Date? {
        isoWithFraction.date(from: s) ?? iso.date(from: s)
    }

    private struct ParseResult {
        var tokens: Int64 = 0
        var usd: Double = 0
        var allPriced = true
        var dayModels: [String: [String: TokenBreakdown]] = [:]   // day -> model -> token breakdown
    }

    /// Walks one session file: tracks the current model via turn_context, sums token_count
    /// events' last_token_usage (the per-turn delta), buckets by day AND model together.
    ///
    /// Events before the first turn_context model marker are buffered, not bucketed immediately:
    /// verified against real files that sessions never switch models mid-file (0/30 sampled, plus
    /// 0/376 with >1 distinct model in a broader scan), so pre-marker events are backfilled to
    /// this file's first-seen model once we know it. Only a file with NO marker anywhere becomes
    /// "unattributed" (never a per-event "unknown" bucket).
    private static func parseFile(_ url: URL) -> ParseResult {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return ParseResult() }
        var result = ParseResult()
        var currentModel: String?
        var firstSeenModel: String?
        var pending: [(day: String, breakdown: TokenBreakdown, tokens: Int64)] = []

        func bucket(day: String, breakdown: TokenBreakdown, tokens: Int64, model: String) {
            result.tokens += tokens
            if let usd = costUSD(breakdown, model: model) {
                result.usd += usd
            } else {
                result.allPriced = false
            }
            let existing = result.dayModels[day]?[model] ?? TokenBreakdown()
            result.dayModels[day, default: [:]][model] = existing + breakdown
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("turn_context") || line.contains("token_count") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }

            if obj["type"] as? String == "turn_context" {
                if let m = payload["model"] as? String {
                    currentModel = m
                    if firstSeenModel == nil { firstSeenModel = m }
                }
                continue
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let totalTokens = (last["total_tokens"] as? NSNumber)?.int64Value else { continue }
            guard let ts = obj["timestamp"] as? String, let date = parseTimestamp(ts) else { continue }

            let breakdown = TokenBreakdown(
                input: (last["input_tokens"] as? NSNumber)?.int64Value ?? 0,
                cachedInput: (last["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0,
                output: (last["output_tokens"] as? NSNumber)?.int64Value ?? 0
            )
            let day = CostScanner.dayFormatter.string(from: date)

            if let currentModel {
                bucket(day: day, breakdown: breakdown, tokens: totalTokens, model: currentModel)
            } else {
                pending.append((day, breakdown, totalTokens))
            }
        }

        let backfillModel = firstSeenModel ?? "unattributed"
        for item in pending {
            bucket(day: item.day, breakdown: item.breakdown, tokens: item.tokens, model: backfillModel)
        }
        return result
    }

    // MARK: - Cache (path -> size/mtime/tokens/usd/allPriced/dayModels)

    private struct CacheEntry: Codable {
        let size: Int64
        let mtime: Double
        let tokens: Int64
        let usd: Double
        let allPriced: Bool
        let dayModels: [String: [String: TokenBreakdown]]
    }

    private static let cacheVersion = 2   // day->model->TokenBreakdown (same generation as CostScanner's v3 dayModels)
    private struct CachePayload: Codable {
        var version: Int
        var files: [String: CacheEntry]
    }

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("codex-cost-cache.json")
    }()

    private static func loadCache() -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.version == cacheVersion else { return [:] }
        return payload.files
    }

    private static func saveCache(_ cache: [String: CacheEntry]) {
        guard let data = try? JSONEncoder().encode(CachePayload(version: cacheVersion, files: cache)) else { return }
        try? data.write(to: cacheURL)
    }

    private static func sessionFiles() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    /// Incremental scan, same shape as CostScanner.scan(): unchanged files reuse cached counts.
    static func scan(forceFull: Bool = false) -> Result {
        let cache = loadCache()
        var newCache: [String: CacheEntry] = [:]
        var result = Result()
        let files = sessionFiles()
        result.fileCount = files.count

        for url in files {
            let path = url.path
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = attrs.fileSize, let mtime = attrs.contentModificationDate else { continue }
            let mtimeStamp = mtime.timeIntervalSince1970

            if !forceFull, let cached = cache[path], cached.size == Int64(size), cached.mtime == mtimeStamp {
                result.totalTokens += cached.tokens
                result.totalUSD += cached.usd
                result.allPriced = result.allPriced && cached.allPriced
                newCache[path] = cached
                continue
            }

            let parsed = parseFile(url)
            result.totalTokens += parsed.tokens
            result.totalUSD += parsed.usd
            result.allPriced = result.allPriced && parsed.allPriced
            newCache[path] = CacheEntry(
                size: Int64(size), mtime: mtimeStamp, tokens: parsed.tokens, usd: parsed.usd,
                allPriced: parsed.allPriced, dayModels: parsed.dayModels
            )
        }

        saveCache(newCache)
        return result
    }

    // MARK: - Insights

    struct DayTokens: Identifiable { var id: String { day }; let day: String; let tokens: Int64 }
    struct ModelTokens: Identifiable { var id: String { model }; let model: String; let tokens: Int64; let usd: Double? }

    struct Insights {
        let dailyLast30: [DayTokens]
        let byModel: [ModelTokens]
        let total7dTokens: Int64
        let total30dTokens: Int64
        let totalAllTimeTokens: Int64
        let rangeTotalTokens: Int64
        let rangeTotalUSD: Double
        let allPriced: Bool   // false -> UI shows tokens only, no $ anywhere for Codex
    }

    private static func lastNDayKeys(_ n: Int, today: Date, calendar: Calendar) -> [String] {
        (0..<n).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { CostScanner.dayFormatter.string(from: $0) }
        }
    }

    /// nil until the cache has at least one entry (first scan still running).
    static func insights(range: InsightsRange = .all) -> Insights? {
        let cache = loadCache()
        guard !cache.isEmpty else { return nil }

        var dayTotals: [String: Int64] = [:]
        var allDayKeys = Set<String>()
        var allPriced = true
        for entry in cache.values {
            allPriced = allPriced && entry.allPriced
            for (day, models) in entry.dayModels {
                allDayKeys.insert(day)
                dayTotals[day, default: 0] += models.values.reduce(0) { $0 + $1.total }
            }
        }
        guard !allDayKeys.isEmpty else { return nil }

        let calendar = Calendar.current
        let today = Date()
        let sortedDays = allDayKeys.sorted()

        let scopeDayKeys: Set<String>
        switch range {
        case .last7: scopeDayKeys = Set(lastNDayKeys(7, today: today, calendar: calendar))
        case .last30: scopeDayKeys = Set(lastNDayKeys(30, today: today, calendar: calendar))
        case .all: scopeDayKeys = allDayKeys
        }

        var modelTotals: [String: TokenBreakdown] = [:]
        var rangeTotalTokens: Int64 = 0
        for entry in cache.values {
            for (day, models) in entry.dayModels where scopeDayKeys.contains(day) {
                for (model, breakdown) in models {
                    modelTotals[model] = (modelTotals[model] ?? TokenBreakdown()) + breakdown
                    rangeTotalTokens += breakdown.total
                }
            }
        }

        let chartDays: [DayTokens]
        switch range {
        case .last7:
            chartDays = lastNDayKeys(7, today: today, calendar: calendar).map { DayTokens(day: $0, tokens: dayTotals[$0] ?? 0) }
        case .last30:
            chartDays = lastNDayKeys(30, today: today, calendar: calendar).map { DayTokens(day: $0, tokens: dayTotals[$0] ?? 0) }
        case .all:
            chartDays = sortedDays.map { DayTokens(day: $0, tokens: dayTotals[$0] ?? 0) }
        }

        let total7d = lastNDayKeys(7, today: today, calendar: calendar).reduce(Int64(0)) { $0 + (dayTotals[$1] ?? 0) }
        let total30d = lastNDayKeys(30, today: today, calendar: calendar).reduce(Int64(0)) { $0 + (dayTotals[$1] ?? 0) }
        let totalAllTime = dayTotals.values.reduce(0, +)

        // "unattributed" (a whole file with no model marker at all) is real but rare — hide it
        // once it's under 1% of the range's tokens so it doesn't clutter the top-4 model list.
        let byModel = modelTotals
            .filter { entry in
                entry.key != "unattributed" || rangeTotalTokens == 0 || Double(entry.value.total) / Double(rangeTotalTokens) >= 0.01
            }
            .map { ModelTokens(model: $0.key, tokens: $0.value.total, usd: costUSD($0.value, model: $0.key)) }
            .sorted { $0.tokens > $1.tokens }
        let rangeTotalUSD = allPriced ? modelTotals.reduce(0.0) { $0 + (costUSD($1.value, model: $1.key) ?? 0) } : 0

        return Insights(
            dailyLast30: chartDays,
            byModel: Array(byModel.prefix(4)),
            total7dTokens: total7d,
            total30dTokens: total30d,
            totalAllTimeTokens: totalAllTime,
            rangeTotalTokens: rangeTotalTokens,
            rangeTotalUSD: rangeTotalUSD,
            allPriced: allPriced
        )
    }

    /// Sum of whatever's already cached, no rescan — used by --print-cost.
    static func cachedTotals() -> (tokens: Int64, usd: Double, allPriced: Bool)? {
        let cache = loadCache()
        guard !cache.isEmpty else { return nil }
        var tokens: Int64 = 0, usd = 0.0, allPriced = true
        for entry in cache.values {
            tokens += entry.tokens
            usd += entry.usd
            allPriced = allPriced && entry.allPriced
        }
        return (tokens, usd, allPriced)
    }
}
