import Foundation

// MARK: - Data (local-only, no network)

struct CodexWindow: Identifiable {
    let id: String
    let label: String
    let usedPercent: Double
    /// nil when resets_at is absent or already in the past — UI shows "—".
    let resetsAt: Date?
}

struct CodexUsage {
    enum Source {
        case live
        case localLog(mtime: Date)
    }
    let windows: [CodexWindow]
    let planType: String?
    let source: Source
}

enum CodexFetcher {
    static let staleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    private static func newestSessionFile() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, mtime: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if newest == nil || mtime > newest!.mtime {
                newest = (url, mtime)
            }
        }
        return newest?.url
    }

    /// Depth-first search for a "rate_limits" key anywhere in a decoded JSON line.
    private static func findRateLimits(_ obj: Any) -> [String: Any]? {
        if let dict = obj as? [String: Any] {
            if let rl = dict["rate_limits"] as? [String: Any] { return rl }
            for value in dict.values {
                if let found = findRateLimits(value) { return found }
            }
        } else if let arr = obj as? [Any] {
            for value in arr {
                if let found = findRateLimits(value) { return found }
            }
        }
        return nil
    }

    // ponytail: live endpoint (chatgpt.com/backend-api/wham/usage) turned out to use
    // limit_window_seconds/reset_at, not window_minutes/resets_at as guessed — accept both
    // so the parser survives either naming without needing a second code path.
    private static func effectiveWindowMinutes(_ dict: [String: Any]) -> Int? {
        if let m = dict["window_minutes"] as? NSNumber { return m.intValue }
        if let s = dict["limit_window_seconds"] as? NSNumber { return s.intValue / 60 }
        return nil
    }

    private static func effectiveResetsAtRaw(_ dict: [String: Any]) -> Any? {
        dict["resets_at"] ?? dict["reset_at"]
    }

    private static func window(from dict: [String: Any]) -> CodexWindow? {
        guard let pct = dict["used_percent"] as? NSNumber else { return nil }
        let minutes = effectiveWindowMinutes(dict) ?? 0
        let label: String
        switch minutes {
        case 300: label = "Session (5h)"
        case 10080: label = "Weekly"
        default: label = "Window \(minutes)m"
        }
        var resets: Date?
        if let epoch = effectiveResetsAtRaw(dict) as? NSNumber {
            let d = Date(timeIntervalSince1970: epoch.doubleValue)
            resets = d > Date() ? d : nil
        } else if let iso = effectiveResetsAtRaw(dict) as? String, let d = UsageFetcher.parseDate(iso) {
            resets = d > Date() ? d : nil
        }
        return CodexWindow(id: label, label: label, usedPercent: pct.doubleValue, resetsAt: resets)
    }

    private static func isWindowDict(_ dict: [String: Any]) -> Bool {
        dict["used_percent"] != nil && (effectiveWindowMinutes(dict) != nil || effectiveResetsAtRaw(dict) != nil)
    }

    /// Live endpoint's schema is undocumented — walk the whole tree; any window-shaped dict
    /// (nested under primary/primary_window/secondary/rate_limit, or anywhere else) is picked up.
    private static func findWindows(_ obj: Any, into windows: inout [CodexWindow], seen: inout Set<String>) {
        if let dict = obj as? [String: Any] {
            if isWindowDict(dict), let w = window(from: dict), seen.insert(w.id).inserted {
                windows.append(w)
            }
            for value in dict.values { findWindows(value, into: &windows, seen: &seen) }
        } else if let arr = obj as? [Any] {
            for value in arr { findWindows(value, into: &windows, seen: &seen) }
        }
    }

    private static func findPlanType(_ obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            if let plan = dict["plan_type"] as? String { return plan }
            for value in dict.values {
                if let found = findPlanType(value) { return found }
            }
        } else if let arr = obj as? [Any] {
            for value in arr {
                if let found = findPlanType(value) { return found }
            }
        }
        return nil
    }

    private static func authToken() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return nil }
        return access
    }

    /// Live fetch of Codex usage. Returns nil on ANY failure (no auth.json, HTTP error, unparseable) —
    /// caller falls back to the local session-log scan.
    static func fetchLive() async -> CodexUsage? {
        guard let token = authToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ClaudeUsage/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var windows: [CodexWindow] = []
        var seen = Set<String>()
        findWindows(parsed, into: &windows, seen: &seen)
        guard !windows.isEmpty else { return nil }

        return CodexUsage(windows: windows, planType: findPlanType(parsed), source: .live)
    }

    /// Live fetch with fallback to the local session-log scan. Used by both the menu-bar app and --print.
    static func loadPreferringLive() async -> CodexUsage? {
        if let live = await fetchLive() { return live }
        return load()
    }

    /// Scans the newest ~/.codex/sessions/**/*.jsonl for the LAST line containing "rate_limits".
    static func load() -> CodexUsage? {
        guard let url = newestSessionFile(),
              let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        guard let line = text.split(separator: "\n").reversed().first(where: { $0.contains("rate_limits") }),
              let lineData = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: lineData),
              let rateLimits = findRateLimits(parsed) else { return nil }

        var windows: [CodexWindow] = []
        if let primary = rateLimits["primary"] as? [String: Any], let w = window(from: primary) { windows.append(w) }
        if let secondary = rateLimits["secondary"] as? [String: Any], let w = window(from: secondary) { windows.append(w) }
        guard !windows.isEmpty else { return nil }

        return CodexUsage(windows: windows, planType: rateLimits["plan_type"] as? String, source: .localLog(mtime: mtime))
    }
}
