import SwiftUI
import AppKit
import ServiceManagement
import Observation

// MARK: - Design tokens

extension Color {
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255,
            green: Double((rgb & 0x00FF00) >> 8) / 255,
            blue: Double(rgb & 0x0000FF) / 255
        )
    }

    static let statusGreen = Color(hex: "4FD97F")
    static let statusAmber = Color(hex: "F5B942")
    static let statusRed = Color(hex: "F07167")

    // Scheme-aware neutrals — dark keeps the original whites, light flips to black at spec'd
    // (or, where unspecified, equivalent) opacities. Accent hues (statusGreen/Amber/Red, hue(for:))
    // stay constant across schemes on purpose.
    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.92) : .black.opacity(0.85)
    }
    // Bumped 0.55->0.70 dark / 0.50->0.62 light — too weak against the glass (GPT-5.5 review).
    static func textMuted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.70) : .black.opacity(0.62)
    }
    // Shared neutral for bar tracks, divider hairlines, and badge-pill fills.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.08) : .black.opacity(0.08)
    }
    // Inset-well fill (mini-cards) — kept faint so it reads as a tonal layer on glass, not an
    // opaque card.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.03) : .black.opacity(0.03)
    }
    // Segmented-control fill (tabs, range pills) — stronger than `well` so the selected segment
    // actually reads as selected rather than a barely-there tint.
    static func segmentFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.12) : .black.opacity(0.10)
    }
    // Badge-chip fill (plan/status metadata pills) — reads as a chip, not disabled UI, paired
    // with a `hairline` stroke.
    static func badgeFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.04) : .black.opacity(0.04)
    }
}

private struct HSBComponents { let h: Double; let s: Double; let b: Double }

private func hsbComponents(of color: Color) -> HSBComponents {
    let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
    var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
    ns.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
    return HSBComponents(h: Double(h), s: Double(s), b: Double(br))
}

private let mintHSB = hsbComponents(of: Color(hex: "4FD97F"))
private let amberHSB = hsbComponents(of: Color(hex: "F5B942"))
private let coralHSB = hsbComponents(of: Color(hex: "F07167"))

/// Continuous severity color — smooth HSB interpolation mint->amber across 0-85%, amber->coral
/// across 85-100%. Replaces the old 3-step colorFor(_:) everywhere (bars, % labels, gauge arc).
func hue(for pct: Int) -> Color {
    let clamped = Double(min(max(pct, 0), 100))
    let a: HSBComponents, b: HSBComponents, t: Double
    if clamped <= 85 {
        a = mintHSB; b = amberHSB; t = clamped / 85
    } else {
        a = amberHSB; b = coralHSB; t = (clamped - 85) / 15
    }
    return Color(
        hue: a.h + (b.h - a.h) * t,
        saturation: a.s + (b.s - a.s) * t,
        brightness: a.b + (b.b - a.b) * t
    )
}

/// Bouncy fill-in used by every animated bar/ring (bars, hero ring) — shared so they stay in sync.
let fillSpring = Animation.spring(duration: 0.35, bounce: 0.35)

/// Dark liquid glass tint over the NSVisualEffectView — tune here if the panel reads too milky
/// (raise) or too opaque (lower). Kept in the 0.20-0.30 "smoked glass, not frosted" range.
let glassTint: Double = 0.25

private let hhmmFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()
private let dayHHmmFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE HH:mm"
    return f
}()

/// <24h away → "resets HH:mm · in Xh" (ceil hours, or "in Xm" under 1h); else "resets EEE HH:mm · in Xd".
func resetLine(for date: Date?) -> String {
    guard let date else { return "" }
    let remaining = date.timeIntervalSinceNow
    guard remaining > 0 else { return "resets \(hhmmFormatter.string(from: date))" }
    if remaining < 24 * 3600 {
        if remaining < 3600 {
            let m = max(1, Int((remaining / 60).rounded(.up)))
            return "resets \(hhmmFormatter.string(from: date)) · in \(m)m"
        }
        let h = Int((remaining / 3600).rounded(.up))
        return "resets \(hhmmFormatter.string(from: date)) · in \(h)h"
    }
    let d = Int((remaining / 86400).rounded(.up))
    return "resets \(dayHHmmFormatter.string(from: date)) · in \(d)d"
}

/// "resets HH:mm · in Xh Ym" — exact hours+minutes (no ceiling), no "% left" prefix.
func preciseResetLine(_ resetsAt: Date?) -> String {
    guard let resetsAt else { return "" }
    let remaining = resetsAt.timeIntervalSinceNow
    guard remaining > 0 else { return "resets \(hhmmFormatter.string(from: resetsAt))" }
    let h = Int(remaining / 3600)
    let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
    return "resets \(hhmmFormatter.string(from: resetsAt)) · in \(h)h \(m)m"
}

/// Session-row-specific reset line: "NN% left · resets HH:mm · in Xh Ym".
func sessionResetLine(pct: Int, resetsAt: Date?) -> String {
    let left = max(0, 100 - pct)
    guard resetsAt != nil else { return "\(left)% left" }
    return "\(left)% left · \(preciseResetLine(resetsAt))"
}

/// Short window name — drops the "Claude · " prefix and "· all models" tail that used to collide
/// with hero text; also used for mini-card labels to keep those cards compact.
func shortWindowName(_ w: UsageWindow) -> String {
    if w.id == "session" || w.id == "five_hour" { return "session" }
    if w.label.hasPrefix("Weekly · ") {
        let rest = w.label.replacingOccurrences(of: "Weekly · ", with: "").lowercased()
        return rest == "all models" ? "weekly" : rest
    }
    return w.label.lowercased()
}

/// Theoretical even-burn position within a `windowDays`-day window ending at resetsAt, 0-100,
/// clamped. elapsed = window - (resetsAt - now); exactly mid-window -> 50. nil if resetsAt is nil.
func expectedPct(resetsAt: Date?, windowDays: Double = 7, now: Date = Date()) -> Double? {
    guard let resetsAt else { return nil }
    let totalWindow = windowDays * 86400
    let remaining = resetsAt.timeIntervalSince(now)
    let elapsed = totalWindow - remaining
    return min(max(elapsed / totalWindow * 100, 0), 100)
}

// ponytail: only two window lengths exist anywhere in this app (5h session, 7d weekly) — a
// >=1-day heuristic is exact for both without needing to thread windowDays through every caller.
func paceTooltip(windowDays: Double = 7) -> String {
    let label = windowDays < 1 ? "5-hour" : "7-day"
    return "Grey line = theoretical even pace: where usage would sit if spent uniformly over the \(label) window. Under pace = burning slower than even; ahead = faster."
}

/// Only show the pace-cap projection when it lands before the window's own reset — a projected
/// cap AFTER the reset is impossible (the window resets first).
func shouldShowETA(_ eta: Date?, resetsAt: Date?) -> Bool {
    guard let eta, let resetsAt else { return false }
    return eta < resetsAt
}

let etaTooltip = "Projected time your session limit reaches 100% at the current burn rate (based on the last 45 minutes). Shown only when that would happen before the session resets."


// MARK: - Components

private struct ResetLabel: View {
    let date: Date?
    var size: CGFloat = 12
    var lineLimit: Int = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if date != nil {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(resetLine(for: date))
                    .monospacedDigit()
                    .lineLimit(lineLimit)
            }
            .font(.system(size: size))
            .foregroundStyle(Color.textMuted(colorScheme))
        }
    }
}

/// 45° diagonal hatching, ~1pt lines 3.5pt apart — draws over whatever frame it's given. Static
/// (no animation), so it respects reduced-motion trivially by construction.
private struct HatchOverlay: View {
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let lineColor = colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.25)
            var x = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(lineColor), lineWidth: 1)
                x += 3.5
            }
        }
    }
}

private struct BarView: View {
    let pct: Int
    let color: Color
    var height: CGFloat = 10
    var paceMarkerPct: Double?   // weekly tiles only — theoretical even-burn position, 0-100
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedPct: Int = 0
    @State private var sweepOn = false

    var body: some View {
        GeometryReader { geo in
            let fillWidth = geo.size.width * CGFloat(min(max(animatedPct, 0), 100)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hairline(colorScheme))
                Capsule()
                    .fill(color)
                    .overlay(alignment: .leading) {
                        if !reduceMotion {
                            // Slow specular sweep, masked to the fill by the frame+clipShape below.
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.12), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: max(fillWidth * 0.5, 6))
                            .offset(x: sweepOn ? fillWidth : -fillWidth * 0.5)
                            .animation(.linear(duration: 2.5).repeatForever(autoreverses: false), value: sweepOn)
                        }
                    }
                    .frame(width: fillWidth)
                    .clipShape(Capsule())
                if let paceMarkerPct {
                    // Hatch spans the GAP between the actual fill and the pace line — the unused
                    // pace allowance — only when under pace (pace > actual). The filled portion
                    // itself stays solid hue with no hatching; ahead of pace, no hatching at all.
                    // Static (final pct, not animatedPct) — no motion to respect.
                    if paceMarkerPct > Double(pct) {
                        let startFraction = CGFloat(pct) / 100
                        let endFraction = CGFloat(min(paceMarkerPct, 100)) / 100
                        HatchOverlay(colorScheme: colorScheme)
                            .frame(width: geo.size.width, height: height)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: geo.size.width * (endFraction - startFraction), height: height)
                                    .offset(x: geo.size.width * startFraction)
                            }
                            .clipShape(Capsule())
                    }
                    // Static even-burn reference line — not tied to the fill's own animation.
                    Rectangle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.30))
                        .frame(width: 1.5, height: height + 2)
                        .offset(x: geo.size.width * CGFloat(min(max(paceMarkerPct, 0), 100)) / 100 - 0.75)
                }
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(fillSpring) { animatedPct = pct }
            if !reduceMotion { sweepOn = true }
        }
        .onChange(of: pct) { _, newValue in
            withAnimation(fillSpring) { animatedPct = newValue }
        }
    }
}

/// Borderless "inset well" mini-card — the ONE tile style for both Claude weekly windows and
/// Codex windows (2-col grid; a lone window naturally occupies one half-width cell). Same pace
/// marker/hatch/label treatment either way, since both route through this one component now.
private struct MiniCard: View {
    let label: String
    let pct: Int
    let resetsAt: Date?
    var expected: Double?          // nil disables the pace marker/label entirely
    var paceWindowDays: Double = 7 // for the tooltip's wording only
    @Environment(\.colorScheme) private var colorScheme
    private var color: Color { hue(for: pct) }

    // ahead = amber, under = muted green (still burning, just slower than even), on-pace = plain
    // muted. Same semantics for Claude and Codex since there's only one paceLabel now.
    private var paceLabel: (text: String, color: Color)? {
        guard let expected else { return nil }
        let diff = Double(pct) - expected
        if diff > 3 { return ("\(Int(diff.rounded()))% ahead of pace", .statusAmber) }
        if diff < -3 { return ("\(Int(abs(diff).rounded()))% under pace", Color.statusGreen.opacity(0.7)) }
        return ("on pace", Color.textMuted(colorScheme))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary(colorScheme))
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: Double(pct)))
                    .animation(.default, value: pct)
            }
            BarView(pct: pct, color: color, height: 6, paceMarkerPct: expected)
            // lineLimit 2 — verified real-data worst case ("resets Wed 23:59 · in 7d") overflows a
            // single line at this card's width by ~6pt but wraps cleanly into 2 with margin to
            // spare, so this fixes the actual truncation risk without needing minimumScaleFactor.
            ResetLabel(date: resetsAt, size: 11, lineLimit: 2)
            if let paceLabel {
                HStack(spacing: 3) {
                    Text(paceLabel.text)
                        .font(.system(size: 10))
                        .foregroundStyle(paceLabel.color)
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted(colorScheme))
                        .help(paceTooltip(windowDays: paceWindowDays))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        // Fixed height (not content-driven) so two cards with differently-long labels/reset text
        // in the same grid row still render the same size — width already matches via the grid's
        // equal-flexible columns. 80->96 fit the pace label line; 96->106 (real font-metrics
        // check: row+bar+2-line-reset+pace = 98pt) covers the reset label's new 2-line wrap.
        .frame(height: 106, alignment: .top)
        .background(Color.well(colorScheme))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Shared "Claude"/"Codex" section header: bold title, optional plan badge, refresh, live/stale note.
private struct SectionHeader: View {
    let title: String
    let badge: String?
    let statusText: String
    let statusColor: Color
    let isFetching: Bool
    let onRefresh: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.textPrimary(colorScheme))
            if let badge {
                Text(badge)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted(colorScheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.badgeFill(colorScheme))
                            .overlay(Capsule().stroke(Color.hairline(colorScheme), lineWidth: 1))
                    )
            }
            Spacer()
            // Refresh + status merged into one tappable element — a spinner replaces the bullet
            // while fetching, the live/stale/retrying text stays either way. Verified real-data
            // width (worst case "retrying (as of HH:mm)") fits the header row with margin.
            Button(action: onRefresh) {
                HStack(spacing: 4) {
                    if isFetching {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(isFetching ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isFetching)
                    } else {
                        Text("•")
                    }
                    Text(statusText)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TabPill: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.textPrimary(colorScheme) : Color.textMuted(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isActive ? Color.segmentFill(colorScheme) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Menu bar replacement for the "✳ NN%" text — a small radial gauge (worst Claude utilization).
/// MenuBarExtra's label closure can't reliably render a live SwiftUI Canvas/Shape view (renders
/// blank — known limitation), so UsageModel rasterizes this to an NSImage via ImageRenderer
/// instead of instantiating it directly in the label; kept internal (not private) for that.
struct MenuBarGaugeView: View {
    let worst: Int

    private var displayText: String { worst >= 100 ? "99+" : "\(worst)" }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(worst, 0), 100)) / 100)
                .stroke(hue(for: worst), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // "99+" needs to shrink slightly to keep clearing the ring at this size.
            Text(displayText)
                .font(.system(size: displayText.count > 2 ? 7 : 8, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
        }
        .frame(width: 18, height: 18)
    }
}

/// Hero-column ring: 64pt, 7pt stroke, hue-colored fill arc, centered % numeral. Fill sweeps in
/// with the same spring as the bars.
private struct HeroRingGauge: View {
    let pct: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var animatedPct: Int = 0
    private var color: Color { hue(for: pct) }

    // "%" reads as a superscripted unit — smaller, baseline-raised — while the numeral keeps the
    // full serif size. Composed via Text string interpolation (the `+` concatenation operator is
    // deprecated as of macOS 26).
    private var numeral: Text {
        Text("\(pct)").font(.system(size: 23, weight: .semibold, design: .serif))
    }
    private var percentSign: Text {
        Text("%")
            .font(.system(size: 23 * 0.55, weight: .semibold, design: .serif))
            .baselineOffset(8)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.hairline(colorScheme), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(animatedPct, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(numeral)\(percentSign)")
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(pct)))
                .animation(.default, value: pct)
        }
        .frame(width: 64, height: 64)
        .onAppear {
            withAnimation(fillSpring) { animatedPct = pct }
        }
        .onChange(of: pct) { _, newValue in
            withAnimation(fillSpring) { animatedPct = newValue }
        }
    }
}

private struct RangePill: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? Color.textPrimary(colorScheme) : Color.textMuted(colorScheme))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.segmentFill(colorScheme) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Local-only spend breakdown — Claude from CostScanner's cache, Codex (tokens; $ only once every
/// model in the logs is verified-priced) from CodexCostScanner's. The 7D/30D/All pills scope the
/// chart, headline total, by-model split, and by-folder list for both.
private struct InsightsView: View {
    let model: UsageModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var range: InsightsRange = .all

    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.groupingSeparator = ","
        return f
    }()
    private func money(_ v: Double) -> String { "$" + (Self.moneyFormatter.string(from: NSNumber(value: v)) ?? "0") }
    private func tokenLabel(_ t: Int64) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK", Double(t) / 1_000) }
        return "\(t)"
    }

    private var claude: CostScanner.Insights? { model.insightsByRange[range] }
    private var codex: CodexCostScanner.Insights? { model.codexInsightsByRange[range] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            rangeRow
            if let claude {
                headline(claude)
                claudeSpendChart(claude.dailyLast30)
                byModel(claude.byModel)
                byFolder(claude.topProjects)
                if let codex, !codex.byModel.isEmpty {
                    Rectangle().fill(Color.hairline(colorScheme)).frame(height: 1)
                    codexSection(codex)
                }
            } else {
                Text(model.isCostComputing ? "computing…" : "no cost data yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .task(id: range) { await model.loadInsights(for: range) }
    }

    private var rangeRow: some View {
        HStack(spacing: 6) {
            ForEach(InsightsRange.allCases, id: \.self) { r in
                RangePill(title: r.label, isActive: range == r) { range = r }
            }
            Spacer()
        }
    }

    private func headline(_ claude: CostScanner.Insights) -> some View {
        let bothPriced = codex?.allPriced == true
        let combined = bothPriced ? claude.rangeTotal + (codex?.rangeTotalUSD ?? 0) : claude.rangeTotal
        let label = bothPriced ? "\(range.label) total (claude + codex)" : "\(range.label) total"
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted(colorScheme))
            Text(money(combined))
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(Color.textPrimary(colorScheme))
        }
    }

    private func claudeSpendChart(_ days: [CostScanner.DayCost]) -> some View {
        let maxCost = max(days.map(\.costUSD).max() ?? 0, 0.01)
        let todayKey = CostScanner.dayFormatter.string(from: Date())
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude · spend")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted(colorScheme))
                Spacer()
                Text("\(money(maxCost))/bucket")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.textMuted(colorScheme))
            }
            GeometryReader { geo in
                // Cap bar width so a handful of buckets (7D) don't stretch into wide blobs;
                // center the row instead of letting the HStack force them to fill the width.
                let barWidth = min(22, geo.size.width / CGFloat(max(days.count, 1)) - 3)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days) { d in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(d.day == todayKey ? Color.white : Color.statusGreen)
                            .frame(width: max(barWidth, 1), height: d.costUSD > 0 ? max(3, 40 * CGFloat(d.costUSD / maxCost)) : 1.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: 40)
        }
    }

    private func byModel(_ models: [CostScanner.ModelCost]) -> some View {
        let maxCost = max(models.map(\.costUSD).max() ?? 0, 0.01)
        return VStack(alignment: .leading, spacing: 8) {
            Text("By model")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted(colorScheme))
            VStack(spacing: 6) {
                ForEach(models) { m in
                    HStack(spacing: 8) {
                        Text(m.model)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textPrimary(colorScheme))
                            .frame(width: 90, alignment: .leading)
                        BarView(pct: Int((m.costUSD / maxCost * 100).rounded()), color: .statusGreen, height: 6)
                        Text(money(m.costUSD))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Color.textPrimary(colorScheme))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    // "By folder" — attribution is by working directory, not a real project registry; family-
    // grouped in CostScanner (alias table + hyphen-prefix clustering) before this ever sees it.
    private func byFolder(_ projects: [CostScanner.ProjectCost]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By folder")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted(colorScheme))
            VStack(spacing: 6) {
                ForEach(projects) { p in
                    HStack {
                        Text(p.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textPrimary(colorScheme))
                        Spacer()
                        Text(money(p.costUSD))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Color.textPrimary(colorScheme))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func codexSection(_ codex: CodexCostScanner.Insights) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            codexSpendChart(codex.dailyLast30)
            codexByModel(codex.byModel, allPriced: codex.allPriced)
            if !codex.allPriced {
                Text("pricing unverified for some models in your Codex logs — token counts only")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted(colorScheme))
            }
        }
    }

    private func codexSpendChart(_ days: [CodexCostScanner.DayTokens]) -> some View {
        let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)
        let todayKey = CostScanner.dayFormatter.string(from: Date())
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Codex · tokens")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted(colorScheme))
                Spacer()
                Text("\(tokenLabel(maxTokens))/bucket")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.textMuted(colorScheme))
            }
            GeometryReader { geo in
                let barWidth = min(22, geo.size.width / CGFloat(max(days.count, 1)) - 3)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days) { d in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(d.day == todayKey ? Color.white : Color.statusGreen)
                            .frame(width: max(barWidth, 1), height: d.tokens > 0 ? max(3, 40 * CGFloat(d.tokens) / CGFloat(maxTokens)) : 1.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: 40)
        }
    }

    private func codexByModel(_ models: [CodexCostScanner.ModelTokens], allPriced: Bool) -> some View {
        let maxTokens = max(models.map(\.tokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Codex · by model")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted(colorScheme))
            VStack(spacing: 6) {
                ForEach(models) { m in
                    HStack(spacing: 8) {
                        Text(m.model)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textPrimary(colorScheme))
                            .frame(width: 90, alignment: .leading)
                        BarView(pct: Int((Double(m.tokens) / Double(maxTokens) * 100).rounded()), color: .statusGreen, height: 6)
                        Text(allPriced ? money(m.usd ?? 0) : tokenLabel(m.tokens))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Color.textPrimary(colorScheme))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Popover

struct PopoverContentView: View {
    let model: UsageModel
    @Environment(\.colorScheme) private var colorScheme

    private enum Tab { case limits, insights }
    @State private var selectedTab: Tab = .limits
    // Independent of InsightsView's own range picker — hero just reads the already-cached
    // per-range aggregate for its headline $ figure.
    @State private var heroRange: InsightsRange = .all

    private var sessionWindow: UsageWindow? {
        model.windows.first { $0.id == "session" || $0.id == "five_hour" }
    }

    private var closestLimitWindow: UsageWindow? {
        model.windows.max { $0.utilization < $1.utilization }
    }

    private var remainingWindows: [UsageWindow] {
        model.windows
            .filter { $0.id != "session" && $0.id != "five_hour" }
            .filter { !($0.id == "extra_usage" && $0.utilization == 0 && $0.resetsAt == nil) }
    }

    private static let costFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.groupingSeparator = ","
        return f
    }()

    private func money(_ v: Double) -> String {
        "$" + (Self.costFormatter.string(from: NSNumber(value: v)) ?? "0")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            heroRow
            tabRow
            switch selectedTab {
            case .limits:
                claudeSection
                codexBlock
            case .insights:
                InsightsView(model: model)
            }
            footerRow
        }
        .padding(16)
        .frame(width: 360)
        // Dark liquid glass: the NSVisualEffectView (.hudWindow, forced darkAqua) beneath the
        // NSHostingView does the actual behind-window blur; this is the ONE tint layer above it
        // (no .glassEffect, no other .background — those compounded into a heavier, less
        // transparent look than the VEV alone). AppKit's cornerRadius+masksToBounds on the
        // effectView already clips this to the panel's rounded corners.
        .background(Color.black.opacity(glassTint))
        .onAppear { Task { await model.refreshOnPopoverOpen() } }
        .task(id: heroRange) { await model.loadInsights(for: heroRange) }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("🔥 TokenBurn")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(Color.textPrimary(colorScheme))
    }

    // MARK: Tabs

    private var tabRow: some View {
        HStack(spacing: 6) {
            TabPill(title: "Limits", isActive: selectedTab == .limits) { selectedTab = .limits }
            TabPill(title: "Insights", isActive: selectedTab == .insights) { selectedTab = .insights }
            Spacer()
        }
    }

    // MARK: Hero

    private var heroRow: some View {
        HStack(alignment: .top, spacing: 24) {
            // Both columns stretch to the row's full (tallest-content) height, so they render as
            // equal-height siblings; heroLeft's naturally top-down text stays top-aligned, while
            // heroRight's caption/ring/reset/eta block centers as one optical unit within that
            // same height instead of floating at the top.
            heroLeft
                .frame(maxHeight: .infinity, alignment: .top)
            heroRight
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var heroLeft: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heroCaption)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(Color.textMuted(colorScheme))
            costDisplay
            HStack(spacing: 6) {
                ForEach(InsightsRange.allCases, id: \.self) { r in
                    RangePill(title: r.label, isActive: heroRange == r) { heroRange = r }
                }
            }
            if let today = model.todayCostUSD, today > 0 {
                Text("today \(money(today))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(Color.textMuted(colorScheme))
            }
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal")
                Text("computed locally")
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(Color.textMuted(colorScheme))
        }
        // Takes the remainder after heroRight's fixed width — was starved by heroRight's old
        // .layoutPriority(1), crushing this column to "A…"/"$1"/"t…".
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // All → the model's running total (unscoped scan); 7D/30D → the matching cached Insights
    // aggregate, already computed for the Insights tab — hero just reads it, lazily loaded via
    // .task(id: heroRange) so switching pills doesn't re-scan anything.
    private var heroCost: Double? {
        heroRange == .all ? model.costUSD : model.insightsByRange[heroRange]?.rangeTotal
    }

    private var heroCaption: String {
        switch heroRange {
        case .all: return "API-equivalent · all time"
        case .last30: return "· last 30 days"
        case .last7: return "· last 7 days"
        }
    }

    @ViewBuilder
    private var costDisplay: some View {
        if let cost = heroCost {
            // "$" and the numeral composed as one Text via string interpolation so they share a
            // real baseline (was a hand-tuned .baselineOffset guess that left a floating gap).
            // Verified worst case "$99,999" (110pt numeral + 10pt sign) fits the 184pt column at
            // full scale — minimumScaleFactor is a floor, not something this actually hits.
            let dollarSign = Text("$")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            let numeral = Text(Self.costFormatter.string(from: NSNumber(value: cost)) ?? "0")
                .font(.system(size: 40, weight: .semibold, design: .serif))
            Text("\(dollarSign)\(numeral)")
                .contentTransition(.numericText(value: cost))
                .animation(.default, value: cost)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(Color.textPrimary(colorScheme))
        } else {
            Text("computing…")
                .font(.system(size: 14))
                .foregroundStyle(Color.textMuted(colorScheme))
        }
    }

    // Current session, falling back to the worst window if the session window is momentarily absent.
    private var heroRingWindow: UsageWindow? { sessionWindow ?? closestLimitWindow }

    private var heroRight: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(Color.textMuted(colorScheme))
            if let w = heroRingWindow {
                let pct = Int(w.utilization.rounded())
                HeroRingGauge(pct: pct)
                // "NN% left" merged into the reset line; ETA line below — relocated here from the
                // now-removed full-width session row (redundant with this ring). Verified real
                // word-wrap: worst case "100% left · resets 23:59 · in 23h 59m" needs exactly 2
                // lines at this column's width, both under it with margin.
                Text(sessionResetLine(pct: pct, resetsAt: w.resetsAt))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(2)
                    .foregroundStyle(Color.textMuted(colorScheme))
                if sessionWindow != nil, let eta = model.sessionETA, shouldShowETA(eta, resetsAt: w.resetsAt) {
                    // Short form ("caps ~HH:mm") — "at this pace," doesn't fit the 120pt column
                    // and truncated with an ellipsis; the ⓘ-adjacent pace context is obvious
                    // without it. Verified: all HH:mm boundary values render at the same 67pt
                    // (monospaced digits), comfortably under the column. Suppressed entirely when
                    // the projection would land after the window's own reset — impossible.
                    HStack(spacing: 3) {
                        Text("caps ~\(hhmmFormatter.string(from: eta))")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(Color.textMuted(colorScheme))
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textMuted(colorScheme))
                            .help(etaTooltip)
                    }
                }
            } else {
                HeroRingGauge(pct: 0).opacity(0.3)
            }
        }
        // Fixed width, no layoutPriority — this is what was starving heroLeft.
        .frame(width: 120, alignment: .leading)
    }

    // MARK: Claude section

    // Status reads purely off recency of the last SUCCESS, not the latest attempt's outcome —
    // a failed poll 3 minutes after a good one should still read calm, not flip to a warning.
    private var claudeStatus: (text: String, color: Color) {
        if model.hasNeverSucceeded {
            return ("stale", .statusAmber)
        }
        if model.isRecentlySucceeded {
            return ("live", .statusGreen)
        }
        if !model.isStale, let last = model.lastFetchDate {
            return ("retrying (as of \(hhmmFormatter.string(from: last)))", .statusAmber)
        }
        return ("stale", .statusAmber)
    }

    @ViewBuilder
    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Claude",
                badge: model.claudePlan,
                statusText: claudeStatus.text,
                statusColor: claudeStatus.color,
                isFetching: model.isFetching,
                onRefresh: { Task { await model.manualRefresh() } }
            )
            // Only the never-succeeded-this-run case shows the full error text; any later
            // failure keeps showing the last-good windows/mini-cards retained on the model.
            if model.hasNeverSucceeded, let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.statusAmber)
            } else {
                // No more full-width session row here — redundant with the hero ring; its two
                // info lines relocated into heroRight, sparkline into its own strip under hero.
                if !remainingWindows.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(remainingWindows) { w in
                            MiniCard(
                                label: shortWindowName(w),
                                pct: Int(w.utilization.rounded()),
                                resetsAt: w.resetsAt,
                                expected: w.label.hasPrefix("Weekly") ? expectedPct(resetsAt: w.resetsAt) : nil
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: Codex section

    private var codexStatus: (text: String, color: Color) {
        switch model.codexSource {
        case .live:
            return ("live", .statusGreen)
        case .localLog(let mtime):
            return ("as of \(CodexFetcher.staleFormatter.string(from: mtime))", .statusAmber)
        case nil:
            return ("—", Color.textMuted(colorScheme))
        }
    }

    @ViewBuilder
    private var codexBlock: some View {
        if !model.codexWindows.isEmpty {
            Rectangle().fill(Color.hairline(colorScheme)).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: "Codex",
                    badge: model.codexPlanType,
                    statusText: codexStatus.text,
                    statusColor: codexStatus.color,
                    isFetching: model.isFetching,
                    onRefresh: { Task { await model.manualRefresh() } }
                )
                // Same mini-card style as Claude's weekly tiles. The usual case is a single
                // (weekly) window — spans the full panel width instead of sitting half-width
                // and alone in a 2-col grid. 2+ windows keep the 2-col grid.
                if model.codexWindows.count == 1, let w = model.codexWindows.first {
                    MiniCard(
                        label: w.label.lowercased(),
                        pct: Int(w.usedPercent.rounded()),
                        resetsAt: w.resetsAt,
                        expected: codexExpectedPct(for: w),
                        paceWindowDays: w.label == "Session (5h)" ? 5.0 / 24.0 : 7
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.codexWindows) { w in
                            // Weekly = 7d window, session (5h) = 5h window; same expectedPct math,
                            // just a different period. Unknown window lengths get no pace marker.
                            MiniCard(
                                label: w.label.lowercased(),
                                pct: Int(w.usedPercent.rounded()),
                                resetsAt: w.resetsAt,
                                expected: codexExpectedPct(for: w),
                                paceWindowDays: w.label == "Session (5h)" ? 5.0 / 24.0 : 7
                            )
                        }
                    }
                }
            }
        }
    }

    private func codexExpectedPct(for w: CodexWindow) -> Double? {
        if w.label == "Weekly" { return expectedPct(resetsAt: w.resetsAt, windowDays: 7) }
        if w.label == "Session (5h)" { return expectedPct(resetsAt: w.resetsAt, windowDays: 5.0 / 24.0) }
        return nil
    }

    // MARK: Footer

    private var footerRow: some View {
        VStack(spacing: 10) {
            Rectangle().fill(Color.hairline(colorScheme)).frame(height: 1)
            HStack {
                Button {
                    launchAtLoginBinding.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: launchAtLoginBinding.wrappedValue ? "checkmark.square.fill" : "square")
                        Text("Launch at Login")
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button("dethok") {
                    NSWorkspace.shared.open(URL(string: "https://dethok.github.io")!)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundStyle(Color.textMuted(colorScheme).opacity(0.25))
                Button("quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.textMuted(colorScheme))
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    // ponytail: best-effort toggle; UI re-reads actual status next render
                }
            }
        )
    }
}

// MARK: - App

/// MenuBarExtra(.window)'s hosting NSPanel is opaque no matter what material/glass is applied
/// above it — verified via a window-walk diagnostic (its only subview is MenuBarExtraHostingView,
/// isOpaque/backgroundColor clearing doesn't stick). Owning the NSStatusItem + NSPanel directly
/// sidesteps that entirely: we set isOpaque/backgroundColor on OUR panel at creation, and an
/// NSVisualEffectView we add ourselves genuinely blurs the desktop behind it (how real HUD-style
/// menu bar apps do this).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var effectView: NSVisualEffectView!
    private var hostingView: NSHostingView<PopoverContentView>!
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        updateStatusButton()
        observeGaugeChanges()

        panel = makePanel()

        if ProcessInfo.processInfo.environment["TOKENBURN_DEBUG_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showPanel() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient]
        panel.isReleasedWhenClosed = false

        effectView = NSVisualEffectView()
        // Dark liquid glass: .hudWindow is Apple's actual dark translucent HUD material — shows
        // more of the desktop through it than .popover while staying dark. Forcing darkAqua keeps
        // it dark regardless of the system's light/dark setting (the SwiftUI content's own
        // colorScheme-driven text colors are unaffected — that's read from the environment
        // separately, not from this NSAppearance).
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.masksToBounds = true

        hostingView = NSHostingView(rootView: PopoverContentView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        panel.contentView = effectView
        return panel
    }

    /// @Observable has no Combine/delegate hook outside SwiftUI views — withObservationTracking
    /// is the supported way to watch it from plain AppKit code; re-register after each fire since
    /// tracking is one-shot per call.
    private func observeGaugeChanges() {
        withObservationTracking {
            _ = model.gaugeImage
            _ = model.menuBarTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusButton()
                self?.observeGaugeChanges()
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        if let image = model.gaugeImage {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = model.menuBarTitle
        }
    }

    @objc private func statusItemClicked() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)

        let fitting = hostingView.fittingSize
        let width = max(fitting.width, 360)
        let height = fitting.height
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(x: buttonFrame.midX - width / 2, y: buttonFrame.minY - height - 4))

        panel.makeKeyAndOrderFront(nil)
        Task { await model.refreshOnPopoverOpen() }
        startOutsideMonitors()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        stopOutsideMonitors()
    }

    private func startOutsideMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.hidePanel()
            return nil
        }
    }

    private func stopOutsideMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }
}

struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
