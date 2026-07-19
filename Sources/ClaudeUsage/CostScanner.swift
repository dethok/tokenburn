import Foundation

// MARK: - Local, incremental "what would this have cost via the API" scan.
// Never logs/prints tokens — only USD totals and file/line counts.

/// Insights time-range filter — shared by CostScanner and CodexCostScanner.
enum InsightsRange: String, CaseIterable {
    case last7, last30, all
    var label: String {
        switch self {
        case .last7: return "7D"
        case .last30: return "30D"
        case .all: return "All"
        }
    }
}

enum CostScanner {
    struct Result {
        var totalUSD: Double = 0
        var fileCount: Int = 0
        var lineCount: Int = 0
    }

    private struct Price { let inPerM: Double; let outPerM: Double }

    // Substring match against message.model, first match wins.
    private static let priceTable: [(String, Price)] = [
        ("fable-5", Price(inPerM: 10, outPerM: 50)),
        ("opus-4-1", Price(inPerM: 15, outPerM: 75)),
        ("opus-4-0", Price(inPerM: 15, outPerM: 75)),
        ("opus-4-2025", Price(inPerM: 15, outPerM: 75)),
        ("opus-4", Price(inPerM: 5, outPerM: 25)),
        ("sonnet", Price(inPerM: 3, outPerM: 15)),
        ("haiku-4-5", Price(inPerM: 1, outPerM: 5)),
        ("3-5-haiku", Price(inPerM: 0.8, outPerM: 4)),
        ("3-haiku", Price(inPerM: 0.25, outPerM: 1.25)),
    ]
    private static let unknownPrice = Price(inPerM: 5, outPerM: 25)

    private static func price(for model: String) -> Price {
        for (substr, p) in priceTable where model.contains(substr) { return p }
        return unknownPrice
    }

    private static func lineCost(usage: [String: Any], model: String) -> Double {
        let p = price(for: model)
        let input = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
        let output = (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.doubleValue ?? 0

        var cacheWriteUSD = 0.0
        if let cc = usage["cache_creation"] as? [String: Any] {
            let ephemeral5m = (cc["ephemeral_5m_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            let ephemeral1h = (cc["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            cacheWriteUSD = (ephemeral5m * 1.25 * p.inPerM + ephemeral1h * 2.0 * p.inPerM) / 1_000_000
        } else {
            let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            cacheWriteUSD = (cacheWrite * 1.25 * p.inPerM) / 1_000_000
        }

        let baseUSD = (input * p.inPerM + output * p.outPerM + cacheRead * 0.1 * p.inPerM) / 1_000_000
        return baseUSD + cacheWriteUSD
    }

    // "timestamp" is a top-level ISO8601 (w/ fractional seconds) field on every JSONL line,
    // e.g. "2026-07-19T14:00:35.862Z" — verified against a real session file.
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private struct ParseResult {
        var cost = 0.0
        var lines = 0
        var dayModels: [String: [String: Double]] = [:]   // day -> model -> cost
    }

    /// Parses one file fresh: pre-filters lines by substring before JSON-decoding, dedupes
    /// within the file by "message.id:requestId". Buckets cost by day AND model together so
    /// date-scoped model/folder splits are derivable without a reparse.
    private static func costAndLineCount(for url: URL) -> ParseResult {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return ParseResult() }
        var result = ParseResult()
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"usage\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let usage = message["usage"] as? [String: Any] else { continue }
            result.lines += 1
            let key = "\(message["id"] as? String ?? ""):\(obj["requestId"] as? String ?? "")"
            guard seen.insert(key).inserted else { continue }
            let cost = lineCost(usage: usage, model: model)
            result.cost += cost
            guard let ts = obj["timestamp"] as? String, let date = isoWithFraction.date(from: ts) else { continue }
            let day = dayFormatter.string(from: date)
            result.dayModels[day, default: [:]][model, default: 0] += cost
        }
        return result
    }

    // MARK: - Cache (path -> size/mtime/cost/dayModels)

    private struct CacheEntry: Codable {
        let size: Int64
        let mtime: Double
        let cost: Double
        let dayModels: [String: [String: Double]]
    }

    // Bump on any change to CacheEntry's shape or to what's accumulated per-file — a mismatch
    // (or an older un-versioned/differently-shaped cache) discards the cache and triggers a full
    // rescan on the next scan(). v3: replaced flat days+models dicts with dayModels (day->model->
    // cost) so date-range-scoped model/folder splits don't need a reparse.
    private static let cacheVersion = 3

    private struct CachePayload: Codable {
        var version: Int
        var files: [String: CacheEntry]
    }

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("cost-cache.json")
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

    /// Sum of whatever's already cached, with no rescan — used by `--print`.
    static func cachedTotal() -> Double? {
        let cache = loadCache()
        guard !cache.isEmpty else { return nil }
        return cache.values.reduce(0) { $0 + $1.cost }
    }

    private static func projectFiles() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
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

    /// Incremental scan: unchanged files (same size+mtime as cache) reuse their cached cost;
    /// changed/new files are fully reparsed. `forceFull` skips the cache-hit shortcut (but still
    /// writes the cache afterwards) so callers get accurate lineCount for the whole corpus.
    static func scan(forceFull: Bool = false) -> Result {
        let cache = loadCache()
        var newCache: [String: CacheEntry] = [:]
        var result = Result()
        let files = projectFiles()
        result.fileCount = files.count

        for url in files {
            let path = url.path
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = attrs.fileSize, let mtime = attrs.contentModificationDate else { continue }
            let mtimeStamp = mtime.timeIntervalSince1970

            if !forceFull, let cached = cache[path], cached.size == Int64(size), cached.mtime == mtimeStamp {
                result.totalUSD += cached.cost
                newCache[path] = cached
                continue
            }

            // ponytail: full-file reparse on any change, tail-delta parsing if rescans get slow
            let parsed = costAndLineCount(for: url)
            result.totalUSD += parsed.cost
            result.lineCount += parsed.lines
            newCache[path] = CacheEntry(size: Int64(size), mtime: mtimeStamp, cost: parsed.cost, dayModels: parsed.dayModels)
        }

        saveCache(newCache)
        return result
    }

    // MARK: - Insights (aggregated from the cache, no reparse)

    struct DayCost: Identifiable { var id: String { day }; let day: String; let costUSD: Double }
    struct ModelCost: Identifiable { var id: String { model }; let model: String; let costUSD: Double }
    struct ProjectCost: Identifiable { var id: String { name }; let name: String; let costUSD: Double }

    struct Insights {
        let dailyLast30: [DayCost]     // chart buckets — daily for 7D/30D; daily or weekly for All
        let byModel: [ModelCost]
        let topProjects: [ProjectCost] // family-grouped, "By folder"
        let total7d: Double
        let total30d: Double
        let totalAllTime: Double
        let rangeTotal: Double         // total for the SELECTED range (headline number)
    }

    /// Short display name for a raw API model string, e.g. "claude-opus-4-1-20250805" -> "opus-4-1".
    private static func modelShortName(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        let parts = s.split(separator: "-")
        return parts.count > 3 ? parts.prefix(3).joined(separator: "-") : s
    }

    // ponytail: was truncating to the last 2 dash-segments, which mangled deeper project paths
    // (e.g. "secretary-ai-phase1" -> "ai-phase1") and silently broke hyphen-prefix family
    // clustering below. Root-cause fix: keep the FULL remainder after the home-dir prefix, so a
    // path like "secretary-ai-staging" still literally starts with "secretary-ai-" and clusters
    // correctly; deep vault subpaths (e.g. "maximizer-01-Projects-...") likewise still start with
    // "maximizer-" and cluster under the shorter root name.
    private static func projectShortName(from dirName: String) -> String {
        var name = dirName
        if name.hasPrefix("-") { name.removeFirst() }
        let homePrefix = "Users-" + NSUserName() + "-"
        if name.hasPrefix(homePrefix) { name = String(name.dropFirst(homePrefix.count)) }
        return name.isEmpty ? dirName : name
    }

    // Explicit alias table for known project clusters whose decoded short names don't share a
    // literal hyphen-prefix relationship — extend here as new naming schemes turn up.
    private static let projectAliases: [String: String] = [
        "secai": "secretary-ai",
    ]

    private static func aliasedFamily(for shortName: String) -> String {
        for (prefix, family) in projectAliases where shortName == prefix || shortName.hasPrefix(prefix + "-") {
            return family
        }
        return shortName
    }

    /// Groups decoded project short-names into families: alias table first, then two names
    /// cluster when one is a hyphen-prefix of the other (grouped under the shortest of those).
    static func familyGroupedTotals(_ projectTotals: [String: Double]) -> [String: Double] {
        var aliased: [String: Double] = [:]
        for (name, cost) in projectTotals { aliased[aliasedFamily(for: name), default: 0] += cost }

        let names = Array(aliased.keys)
        var familyOf: [String: String] = [:]
        for name in names {
            let shorterRoots = names.filter { $0 != name && name.hasPrefix($0 + "-") }
            familyOf[name] = shorterRoots.min(by: { $0.count < $1.count }) ?? name
        }
        var grouped: [String: Double] = [:]
        for (name, cost) in aliased { grouped[familyOf[name] ?? name, default: 0] += cost }
        return grouped
    }

    private static func lastNDayKeys(_ n: Int, today: Date, calendar: Calendar) -> [String] {
        (0..<n).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayFormatter.string(from: $0) }
        }
    }

    private static func weekKey(for day: String, calendar: Calendar) -> String {
        guard let date = dayFormatter.date(from: day) else { return day }
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
    }

    /// nil until the cache has at least one entry (first scan still running).
    static func insights(range: InsightsRange = .all) -> Insights? {
        let cache = loadCache()
        guard !cache.isEmpty else { return nil }

        var dayTotals: [String: Double] = [:]
        var allDayKeys = Set<String>()
        for entry in cache.values {
            for (day, models) in entry.dayModels {
                allDayKeys.insert(day)
                dayTotals[day, default: 0] += models.values.reduce(0, +)
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

        var modelTotals: [String: Double] = [:]
        var projectTotals: [String: Double] = [:]
        var rangeTotal = 0.0
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path

        for (path, entry) in cache {
            var fileRangeTotal = 0.0
            for (day, models) in entry.dayModels where scopeDayKeys.contains(day) {
                for (model, cost) in models {
                    modelTotals[modelShortName(model), default: 0] += cost
                    fileRangeTotal += cost
                }
            }
            rangeTotal += fileRangeTotal
            guard fileRangeTotal > 0, path.hasPrefix(root) else { continue }
            let rel = path.dropFirst(root.count).drop(while: { $0 == "/" })
            if let slash = rel.firstIndex(of: "/") {
                projectTotals[projectShortName(from: String(rel[rel.startIndex..<slash])), default: 0] += fileRangeTotal
            }
        }

        // Chart buckets: exact daily for 7D/30D; daily for All if the span is <=60 days, else
        // condensed into weekly buckets.
        let chartDays: [DayCost]
        switch range {
        case .last7:
            chartDays = lastNDayKeys(7, today: today, calendar: calendar).map { DayCost(day: $0, costUSD: dayTotals[$0] ?? 0) }
        case .last30:
            chartDays = lastNDayKeys(30, today: today, calendar: calendar).map { DayCost(day: $0, costUSD: dayTotals[$0] ?? 0) }
        case .all:
            let spanDays = (dayFormatter.date(from: sortedDays.first!).map { calendar.dateComponents([.day], from: $0, to: today).day ?? 0 }) ?? 0
            if spanDays > 60 {
                var weekly: [String: Double] = [:]
                for day in sortedDays { weekly[weekKey(for: day, calendar: calendar), default: 0] += dayTotals[day] ?? 0 }
                chartDays = weekly.keys.sorted().map { DayCost(day: $0, costUSD: weekly[$0] ?? 0) }
            } else {
                chartDays = sortedDays.map { DayCost(day: $0, costUSD: dayTotals[$0] ?? 0) }
            }
        }

        let total7d = lastNDayKeys(7, today: today, calendar: calendar).reduce(0.0) { $0 + (dayTotals[$1] ?? 0) }
        let total30d = lastNDayKeys(30, today: today, calendar: calendar).reduce(0.0) { $0 + (dayTotals[$1] ?? 0) }
        let totalAllTime = dayTotals.values.reduce(0, +)

        let byModel = modelTotals.map { ModelCost(model: $0.key, costUSD: $0.value) }
            .sorted { $0.costUSD > $1.costUSD }
        let familyTotals = familyGroupedTotals(projectTotals)
        let topProjects = familyTotals.map { ProjectCost(name: $0.key, costUSD: $0.value) }
            .sorted { $0.costUSD > $1.costUSD }

        return Insights(
            dailyLast30: chartDays,
            byModel: Array(byModel.prefix(4)),
            topProjects: Array(topProjects.prefix(5)),
            total7d: total7d,
            total30d: total30d,
            totalAllTime: totalAllTime,
            rangeTotal: rangeTotal
        )
    }
}
