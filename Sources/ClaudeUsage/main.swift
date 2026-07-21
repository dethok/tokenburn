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

    let earlierReset = now.addingTimeInterval(3600)
    let etaPastReset = now.addingTimeInterval(7200)
    check("state selection picks 'well within pace' when the projected cap lands after the window's reset", shouldShowETA(etaPastReset, resetsAt: earlierReset) == false)
    let laterReset = now.addingTimeInterval(7200)
    let etaBeforeReset = now.addingTimeInterval(3600)
    check("state selection picks 'caps ~HH:mm' when the projected cap lands before the window's reset", shouldShowETA(etaBeforeReset, resetsAt: laterReset) == true)
    check("state selection picks 'well within pace' when slope is too flat to project (no eta)", shouldShowETA(nil, resetsAt: laterReset) == false)

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

// --gauge-measure: renders the real MenuBarGaugeView (same code path + scale as
// UsageModel.updateGaugeImage()) for the 1-digit/2-digit/"99+" cases and prints, per case, the
// ring stroke's bounding-box center vs the white digit pixels' centroid, in both px (at the
// render scale) and pt. Isolates ring vs digit by color/alpha: the track is white at 0.25 alpha
// and the fill arc is hue-colored (never near-white), so only opaque near-white pixels are the
// digit — everything else with any ink is the ring. Debug-only, dev tree.
if CommandLine.arguments.contains("--gauge-measure") {
    @MainActor
    func measure(pct: Int) -> (ring: (x: Double, y: Double), digit: (x: Double, y: Double))? {
        let size = MenuBarGaugeView.canvasSize
        let renderer = ImageRenderer(content: MenuBarGaugeView(worst: pct).frame(width: size, height: size))
        renderer.scale = 4
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        var ringMinX = Int.max, ringMaxX = Int.min, ringMinY = Int.max, ringMaxY = Int.min
        var digitSumX = 0.0, digitSumY = 0.0, digitWeight = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let a = Double(c.alphaComponent)
                guard a > 0.04 else { continue } // ~10/255 — skip background
                // Digit pixels are solid white at varying (antialiased) alpha; the track is
                // white capped at 0.25 alpha flat. >0.30 alpha safely separates the two, and
                // weighting the centroid by alpha (not just counting full-opaque pixels) keeps
                // sub-pixel sensitivity from the antialiased glyph edges.
                let isDigit = a > 0.30 && c.redComponent > 0.94 && c.greenComponent > 0.94 && c.blueComponent > 0.94
                if isDigit {
                    digitSumX += Double(x) * a; digitSumY += Double(y) * a; digitWeight += a
                } else {
                    ringMinX = min(ringMinX, x); ringMaxX = max(ringMaxX, x)
                    ringMinY = min(ringMinY, y); ringMaxY = max(ringMaxY, y)
                }
            }
        }
        guard digitWeight > 0, ringMinX <= ringMaxX else { return nil }
        return (ring: (Double(ringMinX + ringMaxX) / 2, Double(ringMinY + ringMaxY) / 2),
                digit: (digitSumX / digitWeight, digitSumY / digitWeight))
    }
    var done = false
    Task { @MainActor in
        defer { done = true }
        for (label, pct) in [("1-digit", 5), ("2-digit", 42), ("99+", 100)] {
            guard let m = measure(pct: pct) else {
                print("\(label): measurement failed")
                continue
            }
            let dxPt = (m.digit.x - m.ring.x) / 4.0
            let dyPt = (m.digit.y - m.ring.y) / 4.0
            print(String(format: "%@: ring=(%.2f, %.2f)px digit=(%.2f, %.2f)px offset=(%.3f, %.3f)pt",
                          label, m.ring.x, m.ring.y, m.digit.x, m.digit.y, dxPt, dyPt))
        }
    }
    while !done {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// --glass-preview <backdrop.png> <out.png>: offscreen render of the real PopoverContentView
// (including its live .glassEffect material on macOS 26+) composited over a backdrop image, with
// no window ever opened. Built to preview Liquid Glass while the screen is locked (screencapture
// doesn't work there). Debug-only, dev tree — mirrors --print/--selftest's early-exit pattern.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--glass-preview") {
    let args = CommandLine.arguments
    guard args.count > flagIndex + 2 else {
        FileHandle.standardError.write("usage: --glass-preview <backdrop.png> <out.png>\n".data(using: .utf8)!)
        exit(1)
    }
    let backdropPath = args[flagIndex + 1]
    let outPath = args[flagIndex + 2]
    guard let backdropImage = NSImage(contentsOfFile: backdropPath) else {
        FileHandle.standardError.write("could not load backdrop: \(backdropPath)\n".data(using: .utf8)!)
        exit(1)
    }

    // NOTE: a raw DispatchSemaphore.wait() here (the --print/--print-cost pattern) would deadlock —
    // this Task must be @MainActor (UsageModel/ImageRenderer/PopoverContentView all are), and
    // MainActor's executor is the main thread's run loop, which a synchronous semaphore-block never
    // pumps. Pumping RunLoop.main instead lets the MainActor-queued work actually run.
    var exitCode: Int32 = 0
    var done = false
    Task { @MainActor in
        defer { done = true }
        let model = UsageModel()
        // Give the model's own background fetch (kicked off in its init) a brief window to land —
        // real data is preferred, but the view renders fine with the default empty state too.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let backdropSize = backdropImage.size
        let content = ZStack {
            Image(nsImage: backdropImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: backdropSize.width, height: backdropSize.height)
                .clipped()
            // ponytail: GlassEffectContainer fallback attempt — see report; PopoverContentView's own
            // .glassEffect (unwrapped) rendered as a total no-op offscreen, testing whether a
            // container changes that.
            if #available(macOS 26, *) {
                GlassEffectContainer {
                    PopoverContentView(model: model)
                }
            } else {
                PopoverContentView(model: model)
            }
        }
        .frame(width: backdropSize.width, height: backdropSize.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            FileHandle.standardError.write("render failed — no cgImage\n".data(using: .utf8)!)
            exitCode = 1
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
            exitCode = 1
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("wrote \(outPath) (\(cgImage.width)x\(cgImage.height))")
        } catch {
            FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        }
    }
    while !done {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(exitCode)
}

ClaudeUsageApp.main()
