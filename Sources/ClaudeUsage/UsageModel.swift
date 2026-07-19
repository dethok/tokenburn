import Foundation
import Observation
import SwiftUI
import AppKit

// MARK: - Data

struct UsageWindow: Identifiable {
    let id: String
    let label: String
    let utilization: Double // 0-100
    let resetsAt: Date?
}

enum UsageError: Error {
    case noToken
    case network(String)
    case badResponse(String)
    case rateLimited(retryAfterSeconds: Double?)

    var message: String {
        switch self {
        case .noToken: return "No valid Claude login — open any Claude Code session"
        case .network(let m): return "Usage fetch failed: \(m)"
        case .badResponse(let m): return "Usage fetch failed: \(m)"
        case .rateLimited: return "Rate limited — retrying shortly"
        }
    }
}

// MARK: - Fetching (ported 1:1 from the verified swiftbar plugin)

enum UsageFetcher {
    static let labels: [String: String] = [
        "five_hour": "Session (5h)",
        "seven_day": "Weekly · all models",
        "seven_day_sonnet": "Weekly · Sonnet",
        "seven_day_opus": "Weekly · Opus",
        "seven_day_oauth_apps": "Weekly · OAuth apps",
        "extra_usage": "Extra usage",
    ]

    // display order for known windows; unknown keys sort after
    static let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps", "extra_usage"]
    static func sortIndex(_ key: String) -> Int { order.firstIndex(of: key) ?? Int.max }

    /// "default_claude_max_20x" -> "max 20x"; falls back to subscriptionType capitalized; nil if neither present.
    private static func planLabel(from oauth: [String: Any]) -> String? {
        if let tier = oauth["rateLimitTier"] as? String {
            let stripped = tier.hasPrefix("default_claude_") ? String(tier.dropFirst("default_claude_".count)) : tier
            let pretty = stripped.replacingOccurrences(of: "_", with: " ")
            if !pretty.isEmpty { return pretty }
        }
        if let sub = oauth["subscriptionType"] as? String, !sub.isEmpty { return sub.capitalized }
        return nil
    }

    private static func tokenFromCreds(_ data: Data) -> (token: String, plan: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let token = oauth["accessToken"] as? String,
              let expiresAt = oauth["expiresAt"] as? NSNumber else { return nil }
        guard expiresAt.doubleValue / 1000 > Date().timeIntervalSince1970 else { return nil }
        return (token, planLabel(from: oauth))
    }

    private static func tokenFromKeychain() -> (token: String, plan: String?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return tokenFromCreds(data)
        } catch {
            return nil
        }
    }

    private static func tokenFromFile() -> (token: String, plan: String?)? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return tokenFromCreds(data)
    }

    /// Returns (token, source-label, plan-label). Never logs the token itself. Plan is read from
    /// the same credentials JSON as the token — no second Keychain read.
    static func getToken() throws -> (token: String, source: String, plan: String?) {
        if let t = tokenFromKeychain() { return (t.token, "keychain", t.plan) }
        if let t = tokenFromFile() { return (t.token, "file", t.plan) }
        throw UsageError.noToken
    }

    static func fetchUsage(token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            if http?.statusCode == 429 {
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                throw UsageError.rateLimited(retryAfterSeconds: retryAfter)
            }
            throw UsageError.network("HTTP \(http?.statusCode ?? -1)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("unexpected response schema")
        }
        return obj
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoWithFraction.date(from: s) ?? iso.date(from: s)
    }

    /// Primary parse: top-level "limits" array of {kind, group, percent, resets_at, scope, ...}.
    static func parseLimitsArray(_ limits: [[String: Any]]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        for entry in limits {
            guard let kind = entry["kind"] as? String, let percent = entry["percent"] as? NSNumber else { continue }
            let scope = entry["scope"] as? [String: Any]
            let modelName = (scope?["model"] as? [String: Any])?["display_name"] as? String

            let id: String
            let label: String
            switch kind {
            case "session":
                id = "session"
                label = "Session (5h)"
            case "weekly_all":
                id = "weekly_all"
                label = "Weekly · all models"
            case "weekly_scoped":
                let name = modelName ?? "unknown"
                id = "weekly_scoped:\(name)"
                label = "Weekly · \(name)"
            default:
                id = kind
                label = kind
            }

            result.append(UsageWindow(
                id: id,
                label: label,
                utilization: percent.doubleValue,
                resetsAt: parseDate(entry["resets_at"] as? String)
            ))
        }
        return result
    }

    /// Fallback (legacy schema, used only when "limits" is absent): any top-level value that is
    /// itself an object with "utilization" is a window.
    static func parseGenericDict(_ obj: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        for (key, value) in obj {
            guard let dict = value as? [String: Any], let util = dict["utilization"] as? NSNumber else { continue }
            result.append(UsageWindow(
                id: key,
                label: labels[key] ?? key,
                utilization: util.doubleValue,
                resetsAt: parseDate(dict["resets_at"] as? String)
            ))
        }
        return result.sorted { sortIndex($0.id) < sortIndex($1.id) }
    }

    static func parseWindows(_ obj: [String: Any]) -> [UsageWindow] {
        if let limits = obj["limits"] as? [[String: Any]] {
            let parsed = parseLimitsArray(limits)
            if !parsed.isEmpty { return parsed }
        }
        return parseGenericDict(obj)
    }
}

// MARK: - Event log (evidence trail, no tokens/response bodies — one line per fetch attempt)

enum EventLog {
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("app.log")
    }()
    private static let iso = ISO8601DateFormatter()

    /// "ISO8601 | claude|codex | ok N windows" or "... | err <short reason>". `detail` never
    /// contains tokens or response bodies — only counts and the existing short error messages.
    static func append(source: String, ok: Bool, detail: String) {
        let line = "\(iso.string(from: Date())) | \(source) | \(ok ? "ok" : "err") \(detail)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Called once at launch: caps runaway growth by keeping only the last 200 lines if >1MB.
    static func truncateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > 1_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lastLines = text.split(separator: "\n").suffix(200)
        try? (lastLines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Pace samples (session/weekly % over time, for the session ETA + sparkline)

struct UsageSample: Codable {
    let ts: Date
    let sessionPct: Double
    let weeklyPct: Double
}

enum SampleStore {
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("samples.json")
    }()
    private static let cap = 500

    static func load() -> [UsageSample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([UsageSample].self, from: data) else { return [] }
        return samples
    }

    /// Appends one sample from a successful parse and prunes to the last `cap` entries (ring
    /// buffer via truncate-on-write). Returns the updated list so the caller can derive the ETA/
    /// sparkline from it directly instead of re-reading the file.
    @discardableResult
    static func append(from windows: [UsageWindow]) -> [UsageSample]? {
        guard let session = windows.first(where: { $0.id == "session" || $0.id == "five_hour" }) else { return nil }
        let weekly = windows.first(where: { $0.id == "weekly_all" || $0.id == "seven_day" })?.utilization ?? 0
        var samples = load()
        samples.append(UsageSample(ts: Date(), sessionPct: session.utilization, weeklyPct: weekly))
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
        guard let data = try? JSONEncoder().encode(samples) else { return samples }
        try? data.write(to: url)
        return samples
    }

    /// Linear-regression slope (pct/min) over samples from the last 45 min. Needs ≥3 points and a
    /// slope > 0.1%/min (meaningfully increasing) to project a cap time; nil otherwise.
    static func sessionETA(samples: [UsageSample], now: Date = Date()) -> Date? {
        let recent = samples.filter { now.timeIntervalSince($0.ts) <= 45 * 60 }
        guard recent.count >= 3, let earliest = recent.map(\.ts).min() else { return nil }

        let points = recent.map { (x: $0.ts.timeIntervalSince(earliest) / 60, y: $0.sessionPct) }
        let n = Double(points.count)
        let xBar = points.reduce(0.0) { $0 + $1.x } / n
        let yBar = points.reduce(0.0) { $0 + $1.y } / n
        let num = points.reduce(0.0) { $0 + ($1.x - xBar) * ($1.y - yBar) }
        let den = points.reduce(0.0) { $0 + ($1.x - xBar) * ($1.x - xBar) }
        guard den > 0 else { return nil }
        let slope = num / den
        guard slope > 0.1, let latest = recent.max(by: { $0.ts < $1.ts }) else { return nil }

        let minutesToCap = (100 - latest.sessionPct) / slope
        guard minutesToCap > 0 else { return nil }
        return latest.ts.addingTimeInterval(minutesToCap * 60)
    }
}

// MARK: - Model

@MainActor
@Observable
final class UsageModel {
    var windows: [UsageWindow] = []
    var isFetching = false
    var lastFetchOK = false
    var lastFetchDate: Date?       // last SUCCESSFUL fetch — windows/hero data is retained as of this time
    var lastAttemptDate: Date?     // last attempt of any kind (success or failure), for the popover-open debounce
    var errorMessage: String?
    var tokenSource: String = "keychain"
    var claudePlan: String?        // e.g. "max 20x" — from the same creds JSON as the token, retained on failure
    var backoffUntil: Date?        // 429 cooldown — automatic fetches are suppressed until this deadline
    var backoffStep = 0            // consecutive 429 count since the last success; drives the exponential step

    var codexWindows: [CodexWindow] = []
    var codexPlanType: String?
    var codexSource: CodexUsage.Source?

    var costUSD: Double?
    var isCostComputing = false
    var todayCostUSD: Double?      // always day-granular (from the 7d range) — the "All" range may bucket by week

    // Lazily populated per InsightsRange (only .all is eager, on refreshCost) — each is a cheap
    // in-memory re-aggregation of the already-scanned cache, but still off the main thread since
    // the cache can hold tens of thousands of file entries.
    var insightsByRange: [InsightsRange: CostScanner.Insights] = [:]
    var codexInsightsByRange: [InsightsRange: CodexCostScanner.Insights] = [:]

    var sessionETA: Date?                        // pace projection — nil unless the slope math validates
    var sessionSparkline: [UsageSample] = []      // samples since the current 5h session window began

    var gaugeImage: NSImage?                      // rasterized menu-bar gauge — see updateGaugeImage()
    private var lastRenderedGaugePct: Int?

    private var timer: Timer?

    init() {
        EventLog.truncateIfNeeded()
        Task { await refresh() }
        Task { await refreshCost() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshOnTimer() }
        }
    }

    /// Full refresh incl. the (expensive) local cost scan — only from the manual refresh button.
    /// Always forces, ignoring the 429 backoff and the popover-open debounce.
    func manualRefresh() async {
        await refresh()
        await refreshCost()
    }

    /// Popover-open trigger: skips if within the 429 backoff window, or if the last attempt
    /// (success or failure) was under 60s ago.
    func refreshOnPopoverOpen() async {
        guard !isInBackoff else { return }
        if let last = lastAttemptDate, Date().timeIntervalSince(last) < 60 { return }
        await refresh()
    }

    /// 5-min timer trigger: skips if within the 429 backoff window (300s cadence already covers
    /// the popover's 60s debounce).
    private func refreshOnTimer() async {
        guard !isInBackoff else { return }
        await refresh()
    }

    private var isInBackoff: Bool {
        guard let backoffUntil else { return false }
        return Date() < backoffUntil
    }

    func refreshCost() async {
        isCostComputing = true
        let result = await Task.detached(priority: .utility) { CostScanner.scan() }.value
        costUSD = result.totalUSD
        _ = await Task.detached(priority: .utility) { CodexCostScanner.scan() }.value
        // The cache may have just changed — drop any range aggregations computed from the old one.
        insightsByRange = [:]
        codexInsightsByRange = [:]
        await loadInsights(for: .all)
        todayCostUSD = await Task.detached(priority: .utility) { CostScanner.insights(range: .last7)?.dailyLast30.last?.costUSD }.value
        isCostComputing = false
    }

    /// Loads (and caches) the Insights tab's data for one time-range pill. Cheap in-memory
    /// re-aggregation of the already-scanned cache, but still dispatched off the main thread.
    func loadInsights(for range: InsightsRange) async {
        if insightsByRange[range] == nil {
            insightsByRange[range] = await Task.detached(priority: .utility) { CostScanner.insights(range: range) }.value
        }
        if codexInsightsByRange[range] == nil {
            codexInsightsByRange[range] = await Task.detached(priority: .utility) { CodexCostScanner.insights(range: range) }.value
        }
    }

    var worstUtilization: Int? {
        windows.map { Int($0.utilization.rounded()) }.max()
    }

    private var minutesSinceSuccess: Double? {
        guard let d = lastFetchDate else { return nil }
        return Date().timeIntervalSince(d) / 60
    }

    /// Last success under 10 min ago — calm "live"/no-warning window, even if a later attempt failed.
    var isRecentlySucceeded: Bool { (minutesSinceSuccess ?? .infinity) < 10 }
    /// Last success 60+ min ago (or never) — beyond the "retrying" window, back to plain "stale".
    var isStale: Bool { (minutesSinceSuccess ?? .infinity) >= 60 }
    /// No successful fetch yet this app run — only case where the full error state should show.
    var hasNeverSucceeded: Bool { lastFetchDate == nil }

    /// Retained worstUtilization survives fetch failures, so this only reads "!" pre-first-fetch;
    /// the ⚠ warning only appears once the last success itself is >10 min old.
    var menuBarTitle: String {
        guard let worst = worstUtilization else { return "✳ !" }
        return "✳ \(worst)%" + (isRecentlySucceeded ? "" : " ⚠")
    }

    /// MenuBarExtra's label closure can't reliably render a live SwiftUI Canvas/Shape view (it
    /// renders blank — known limitation), so the gauge is rasterized here instead and the label
    /// just displays the resulting NSImage. Cached on worstUtilization to avoid re-rendering when
    /// it hasn't actually changed.
    private func updateGaugeImage() {
        guard let worst = worstUtilization else {
            gaugeImage = nil
            lastRenderedGaugePct = nil
            return
        }
        guard worst != lastRenderedGaugePct else { return }
        lastRenderedGaugePct = worst

        let renderer = ImageRenderer(content: MenuBarGaugeView(worst: worst).frame(width: 18, height: 18))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 18, height: 18))
        image.isTemplate = false
        gaugeImage = image
    }

    /// First 429 → 10 min, doubling each consecutive 429, capped at 60 min; honors a longer
    /// server-provided Retry-After. `step` is 1-indexed (already incremented for this failure).
    private static func backoffSeconds(step: Int, retryAfter: Double?) -> TimeInterval {
        let minutes = min(10.0 * pow(2, Double(step - 1)), 60.0)
        return max(retryAfter ?? 0, minutes * 60)
    }

    func refresh() async {
        isFetching = true
        defer { isFetching = false }
        lastAttemptDate = Date()
        async let codex = Task.detached(priority: .utility) { await CodexFetcher.loadPreferringLive() }.value
        do {
            let (token, source, plan) = try UsageFetcher.getToken()
            tokenSource = source
            claudePlan = plan
            let obj = try await UsageFetcher.fetchUsage(token: token)
            let parsed = UsageFetcher.parseWindows(obj)
            if parsed.isEmpty {
                // A 200 that parses to zero windows is treated as a failure — keep last-good
                // `windows` on screen rather than blanking the hero/section to nothing.
                lastFetchOK = false
                errorMessage = "Unexpected response schema"
                EventLog.append(source: "claude", ok: false, detail: errorMessage ?? "")
            } else {
                windows = parsed
                lastFetchOK = true
                errorMessage = nil
                lastFetchDate = Date()
                backoffUntil = nil
                backoffStep = 0
                if let samples = SampleStore.append(from: parsed) {
                    sessionETA = SampleStore.sessionETA(samples: samples)
                    if let session = parsed.first(where: { $0.id == "session" || $0.id == "five_hour" }),
                       let resetsAt = session.resetsAt {
                        let windowStart = resetsAt.addingTimeInterval(-5 * 3600)
                        sessionSparkline = samples.filter { $0.ts >= windowStart }
                    } else {
                        sessionSparkline = []
                    }
                } else {
                    sessionETA = nil
                    sessionSparkline = []
                }
                EventLog.append(source: "claude", ok: true, detail: "\(parsed.count) windows")
            }
        } catch let e as UsageError {
            lastFetchOK = false
            errorMessage = e.message
            if case .rateLimited(let retryAfter) = e {
                // ponytail: no reset here on purpose — a manually-triggered 429 still advances
                // the same consecutive-failure step, it doesn't get a shorter "fresh" backoff.
                backoffStep += 1
                backoffUntil = Date().addingTimeInterval(Self.backoffSeconds(step: backoffStep, retryAfter: retryAfter))
            }
            EventLog.append(source: "claude", ok: false, detail: e.message)
        } catch {
            lastFetchOK = false
            errorMessage = error.localizedDescription
            EventLog.append(source: "claude", ok: false, detail: error.localizedDescription)
        }
        if let usage = await codex {
            codexWindows = usage.windows
            codexPlanType = usage.planType
            codexSource = usage.source
            EventLog.append(source: "codex", ok: true, detail: "\(usage.windows.count) windows")
        } else {
            codexWindows = []
            codexPlanType = nil
            codexSource = nil
            EventLog.append(source: "codex", ok: false, detail: "no data")
        }
        updateGaugeImage()
    }
}
