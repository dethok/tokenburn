import Foundation
import SwiftUI
import AppKit

// --selftest: offline assert-based check of hue(for:) and SampleStore.sessionETA against
// synthetic data. No network, no filesystem writes (sessionETA takes samples in-memory, doesn't
// go through SampleStore.append/load). Exits 0 on all-pass, 1 on any failure.
if CommandLine.arguments.contains("--selftest") {
    var failures = 0
    func check(_ name: String, _ pass: Bool) {
        print("\(pass ? "PASS" : "FAIL"): \(name)")
        if !pass { failures += 1 }
    }
    func rgb(_ color: Color) -> (r: Double, g: Double, b: Double) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
    func approxEqual(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double), tol: Double = 0.02) -> Bool {
        abs(a.r - b.r) < tol && abs(a.g - b.g) < tol && abs(a.b - b.b) < tol
    }

    let mint = rgb(Color(hex: "4FD97F"))
    let amber = rgb(Color(hex: "F5B942"))
    let coral = rgb(Color(hex: "F07167"))
    check("hue(0) ≈ mint", approxEqual(rgb(hue(for: 0)), mint))
    check("hue(85) ≈ amber", approxEqual(rgb(hue(for: 85)), amber))
    check("hue(100) ≈ coral", approxEqual(rgb(hue(for: 100)), coral))
    let mid = rgb(hue(for: 50))
    check("hue(50) is between mint and amber", !approxEqual(mid, mint) && !approxEqual(mid, amber))

    let now = Date()
    let rising = (0..<5).map { i in UsageSample(ts: now.addingTimeInterval(Double(-40 + i * 10) * 60), sessionPct: Double(i) * 5, weeklyPct: 0) }
    check("rising slope (0.5%/min) over 5 points/40min produces an ETA", SampleStore.sessionETA(samples: rising, now: now) != nil)

    let flat = (0..<5).map { i in UsageSample(ts: now.addingTimeInterval(Double(-40 + i * 10) * 60), sessionPct: 10, weeklyPct: 0) }
    check("flat samples (slope 0) produce no ETA", SampleStore.sessionETA(samples: flat, now: now) == nil)

    let tooFew = [UsageSample(ts: now, sessionPct: 10, weeklyPct: 0), UsageSample(ts: now.addingTimeInterval(-600), sessionPct: 5, weeklyPct: 0)]
    check("fewer than 3 samples produce no ETA", SampleStore.sessionETA(samples: tooFew, now: now) == nil)

    let old = [UsageSample(ts: now.addingTimeInterval(-3600), sessionPct: 1, weeklyPct: 0),
               UsageSample(ts: now.addingTimeInterval(-3550), sessionPct: 2, weeklyPct: 0),
               UsageSample(ts: now.addingTimeInterval(-3500), sessionPct: 3, weeklyPct: 0)]
    check("samples older than 45min are excluded, leaving <3 points -> no ETA", SampleStore.sessionETA(samples: old, now: now) == nil)

    let midWindowReset = now.addingTimeInterval(3.5 * 86400)
    check("expectedPct at exactly mid-window (3.5d left of 7d) == 50", expectedPct(resetsAt: midWindowReset, now: now).map { abs($0 - 50) < 0.01 } ?? false)
    check("expectedPct is nil for a nil resetsAt", expectedPct(resetsAt: nil, now: now) == nil)

    exit(failures == 0 ? 0 : 1)
}

// --print-cost: force a full synchronous cost scan (bypasses the cache-hit shortcut), print
// the total + file/line counts, exit. Never prints tokens.
if CommandLine.arguments.contains("--print-cost") {
    let start = Date()
    let result = CostScanner.scan(forceFull: true)
    let codexResult = CodexCostScanner.scan(forceFull: true)
    let elapsed = Date().timeIntervalSince(start)
    print("total: $\(String(format: "%.2f", result.totalUSD))")
    print("files: \(result.fileCount)")
    print("lines: \(result.lineCount)")
    if codexResult.allPriced {
        print("codex: \(codexResult.totalTokens) tokens, $\(String(format: "%.2f", codexResult.totalUSD))")
    } else {
        print("codex: \(codexResult.totalTokens) tokens (pricing unverified for some models — no $ total)")
    }
    print("codex files: \(codexResult.fileCount)")
    print(String(format: "elapsed: %.1fs", elapsed))
    exit(0)
}

// --print: debug/verification hook. Fetch once, print plain lines, exit.
if CommandLine.arguments.contains("--print") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        let iso = ISO8601DateFormatter()
        do {
            let (token, source, _) = try UsageFetcher.getToken()
            let obj = try await UsageFetcher.fetchUsage(token: token)
            let windows = UsageFetcher.parseWindows(obj)
            if windows.isEmpty {
                FileHandle.standardError.write("Unexpected response schema — no usage windows found\n".data(using: .utf8)!)
                exitCode = 1
            } else {
                for w in windows {
                    let pct = Int(w.utilization.rounded())
                    let resets = w.resetsAt.map { iso.string(from: $0) } ?? "n/a"
                    print("\(w.label): \(pct)% resets \(resets)")
                }
                print("token source: \(source)")
            }
        } catch let e as UsageError {
            FileHandle.standardError.write("\(e.message)\n".data(using: .utf8)!)
            exitCode = 1
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            exitCode = 1
        }

        if let codex = await CodexFetcher.loadPreferringLive() {
            for w in codex.windows {
                let pct = Int(w.usedPercent.rounded())
                let resets = w.resetsAt.map { iso.string(from: $0) } ?? "—"
                print("codex \(w.label): \(pct)% resets \(resets)")
            }
            switch codex.source {
            case .live:
                print("codex source: live")
            case .localLog(let mtime):
                print("codex source: local log (as of \(CodexFetcher.staleFormatter.string(from: mtime)))")
            }
        } else {
            print("codex: no session data found")
        }

        if let cached = CostScanner.cachedTotal() {
            print("cost: $\(String(format: "%.2f", cached))")
        } else {
            print("cost: no cache")
        }

        semaphore.signal()
    }
    semaphore.wait()
    exit(exitCode)
}

ClaudeUsageApp.main()
