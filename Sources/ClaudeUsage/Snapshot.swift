import Foundation

// MARK: - Widget snapshot (contract with a phone widget/Scriptable script — key names are load-
// bearing, do not rename). Dumps state the model has ALREADY fetched; adds zero new network calls
// and never serializes token/credential material — only percentages, labels, dates, USD totals.

private struct SnapshotWindow: Codable {
    let id: String
    let label: String
    let usedPct: Double
    let resetsAt: Date?
}

private struct SnapshotCost: Codable {
    let claude: Double?
    let codex: Double?
}

private struct WidgetSnapshot: Codable {
    let generatedAt: Date
    let claudePlan: String?
    let codexPlan: String?
    let claude: [SnapshotWindow]
    let codex: [SnapshotWindow]
    let costTodayUSD: SnapshotCost
    let samples: [UsageSample]
}

enum SnapshotStore {
    private static let primaryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("snapshot.json")
    }()

    // iCloud provisions this directory itself once Scriptable is installed — never create it here.
    private static let scriptableDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents", isDirectory: true)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Called from the MainActor model at the end of each refresh cycle. Captures the already-
    /// fetched values synchronously, then does everything else (loading samples.json, encoding,
    /// disk I/O) inside a detached task so it never blocks the main thread.
    static func write(
        claudePlan: String?,
        codexPlan: String?,
        claudeWindows: [UsageWindow],
        codexWindows: [CodexWindow],
        costTodayClaude: Double?,
        costTodayCodex: Double?
    ) {
        let generatedAt = Date()
        let claudeSnap = claudeWindows.map { SnapshotWindow(id: $0.id, label: $0.label, usedPct: $0.utilization, resetsAt: $0.resetsAt) }
        let codexSnap = codexWindows.map { SnapshotWindow(id: $0.id, label: $0.label, usedPct: $0.usedPercent, resetsAt: $0.resetsAt) }

        Task.detached(priority: .utility) {
            let snapshot = WidgetSnapshot(
                generatedAt: generatedAt,
                claudePlan: claudePlan,
                codexPlan: codexPlan,
                claude: claudeSnap,
                codex: codexSnap,
                costTodayUSD: SnapshotCost(claude: costTodayClaude, codex: costTodayCodex),
                samples: SampleStore.load()
            )
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: primaryURL, options: .atomic)

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: scriptableDir.path, isDirectory: &isDir), isDir.boolValue {
                try? data.write(to: scriptableDir.appendingPathComponent("tokenburn-status.json"), options: .atomic)
            }
        }
    }
}
