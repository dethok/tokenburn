import SwiftUI
import AppKit
import ServiceManagement

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
    // ponytail: light-mode muted wasn't spec'd explicitly — kept the same primary:muted opacity
    // ratio as dark mode (55/92 ≈ 0.6) rounded to a clean 50%.
    static func textMuted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.55) : .black.opacity(0.50)
    }
    // Shared neutral for bar tracks, divider hairlines, and badge-pill fills.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.08) : .black.opacity(0.08)
    }
    // Inset-well fill (mini-cards, active tab pill) — kept faint so it reads as a tonal layer on
    // glass, not an opaque card.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.03) : .black.opacity(0.03)
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

/// Theoretical even-burn position within a 7-day weekly window ending at resetsAt, 0-100,
/// clamped. elapsed = 7d - (resetsAt - now); exactly mid-window -> 50. nil if resetsAt is nil.
func expectedPct(resetsAt: Date?, now: Date = Date()) -> Double? {
    guard let resetsAt else { return nil }
    let totalWindow = 7.0 * 86400
    let remaining = resetsAt.timeIntervalSince(now)
    let elapsed = totalWindow - remaining
    return min(max(elapsed / totalWindow * 100, 0), 100)
}

/// MenuBarExtra(.window)'s hosting NSPanel backs itself opaque by default, which blocks the
/// desktop/glass from showing through no matter what material/glass effect is applied above it.
/// Clearing the window's own opacity/background is what lets real translucency read through.
/// This is now a plain 0-opacity NSView (not NSVisualEffectView) so it renders nothing itself and
/// cannot occlude .glassEffect's own background — its only job is the window walk below. Liquid
/// Glass's own window setup can reset isOpaque/backgroundColor after attach, so re-assert once
/// more async on the next run loop turn as a cheap belt-and-suspenders.
private final class TransparentVisualEffectView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowTransparency(phase: "sync")
        DispatchQueue.main.async { [weak self] in self?.applyWindowTransparency(phase: "async") }
    }

    private func applyWindowTransparency(phase: String) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        // ponytail: diagnostic only, for the next round if glass still doesn't show — logs the
        // class names of whatever sits alongside the SwiftUI hosting view, in case one of them
        // is an opaque backing view occluding the glass from underneath.
        if let siblings = window.contentView?.superview?.subviews {
            let names = siblings.map { String(describing: type(of: $0)) }.joined(separator: ", ")
            EventLog.append(source: "window", ok: true, detail: "\(phase) contentView.superview subviews: [\(names)]")
        }
    }
}

/// 0-opacity 1x1 probe — no visual footprint of its own, exists only to trigger the window-
/// clearing hook above without participating in (or occluding) the glass effect's background.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> TransparentVisualEffectView {
        let view = TransparentVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.alphaValue = 0
        return view
    }
    func updateNSView(_ nsView: TransparentVisualEffectView, context: Context) {}
}

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

/// Full-width row: label + colored %, capsule bar, reset line. Used for every Codex window.
private struct PrimaryRow: View {
    let label: String
    let pct: Int
    let resetsAt: Date?
    @Environment(\.colorScheme) private var colorScheme
    private var color: Color { hue(for: pct) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary(colorScheme))
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: Double(pct)))
                    .animation(.default, value: pct)
            }
            BarView(pct: pct, color: color, height: 10)
            ResetLabel(date: resetsAt, size: 12)
        }
    }
}

/// Session-row-specific sparkline: session% samples since the current 5h window began.
private struct SessionSparkline: View {
    let samples: [UsageSample]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2 else { return }
            let minTs = samples.first!.ts.timeIntervalSinceReferenceDate
            let maxTs = samples.last!.ts.timeIntervalSinceReferenceDate
            let span = max(maxTs - minTs, 1)
            func point(_ s: UsageSample) -> CGPoint {
                let x = CGFloat((s.ts.timeIntervalSinceReferenceDate - minTs) / span) * size.width
                let y = size.height - CGFloat(min(max(s.sessionPct, 0), 100) / 100) * size.height
                return CGPoint(x: x, y: y)
            }
            var path = Path()
            path.move(to: point(samples[0]))
            for s in samples.dropFirst() { path.addLine(to: point(s)) }
            context.stroke(path, with: .color(color), lineWidth: 1.5)

            let last = point(samples[samples.count - 1])
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .color(.white))
        }
    }
}

/// Full-width Claude session row: %, bar, "NN% left · resets..." line, optional pace ETA line,
/// optional sparkline (session% since the current 5h window began).
private struct SessionRow: View {
    let pct: Int
    let resetsAt: Date?
    let eta: Date?
    let sparkline: [UsageSample]
    @Environment(\.colorScheme) private var colorScheme
    private var color: Color { hue(for: pct) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("session")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary(colorScheme))
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: Double(pct)))
                    .animation(.default, value: pct)
            }
            BarView(pct: pct, color: color, height: 10)
            Text(sessionResetLine(pct: pct, resetsAt: resetsAt))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Color.textMuted(colorScheme))
            if let eta {
                Text("at this pace, caps ~\(hhmmFormatter.string(from: eta))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.textMuted(colorScheme))
            }
            if sparkline.count >= 3 {
                SessionSparkline(samples: sparkline, color: color)
                    .frame(height: 16)
            }
        }
    }
}

/// Borderless "inset well" mini-card for the secondary Claude windows grid.
private struct MiniCard: View {
    let label: String
    let pct: Int
    let resetsAt: Date?
    var expected: Double? // weekly tiles only — nil disables the pace marker/label entirely
    @Environment(\.colorScheme) private var colorScheme
    private var color: Color { hue(for: pct) }

    private var paceLabel: (text: String, color: Color)? {
        guard let expected else { return nil }
        let diff = Double(pct) - expected
        if diff > 3 { return ("\(Int(diff.rounded()))% ahead of pace", .statusAmber) }
        if diff < -3 { return ("\(Int(abs(diff).rounded()))% under pace", Color.textMuted(colorScheme)) }
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
            ResetLabel(date: resetsAt, size: 11)
            if let paceLabel {
                Text(paceLabel.text)
                    .font(.system(size: 10))
                    .foregroundStyle(paceLabel.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        // Fixed height (not content-driven) so two cards with differently-long labels/reset text
        // in the same grid row still render the same size — width already matches via the grid's
        // equal-flexible columns. Bumped 80->96 to fit the pace label line on weekly tiles.
        .frame(height: 96, alignment: .top)
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
                    .background(Capsule().fill(Color.hairline(colorScheme)))
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Color.textMuted(colorScheme))
                    .rotationEffect(.degrees(isFetching ? 360 : 0))
                    .animation(isFetching ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isFetching)
            }
            .buttonStyle(.plain)
            Text("• \(statusText)")
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
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
                .background(isActive ? Color.well(colorScheme) : Color.clear)
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

    var body: some View {
        ZStack {
            Circle().stroke(Color.hairline(colorScheme), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(animatedPct, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(pct)%")
                .font(.system(size: 23, weight: .semibold, design: .serif))
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
                .background(isActive ? Color.well(colorScheme) : Color.clear)
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
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { d in
                    Capsule()
                        .fill(d.day == todayKey ? Color.white : Color.statusGreen)
                        .frame(height: max(2, 40 * CGFloat(d.costUSD / maxCost)))
                }
            }
            .frame(height: 40, alignment: .bottom)
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
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { d in
                    Capsule()
                        .fill(d.day == todayKey ? Color.white : Color.statusGreen)
                        .frame(height: max(2, 40 * CGFloat(d.tokens) / CGFloat(maxTokens)))
                }
            }
            .frame(height: 40, alignment: .bottom)
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
        .glassEffect(.clear, in: .rect(cornerRadius: 16))
        .containerBackground(.clear, for: .window)
        .overlay(alignment: .topLeading) {
            // 0-opacity 1x1 probe — window-clearing side effect only, cannot occlude the glass above.
            VisualEffectBackground().frame(width: 1, height: 1)
        }
        .onAppear { Task { await model.refreshOnPopoverOpen() } }
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
            heroLeft
            heroRight
        }
    }

    private var heroLeft: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API-equivalent · all time")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted(colorScheme))
            costDisplay
            if let today = model.todayCostUSD, today > 0 {
                Text("today \(money(today))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.textMuted(colorScheme))
            }
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal")
                Text("computed locally")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var costDisplay: some View {
        if let cost = model.costUSD {
            HStack(alignment: .top, spacing: 2) {
                Text("$")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .baselineOffset(14)
                Text(Self.costFormatter.string(from: NSNumber(value: cost)) ?? "0")
                    .font(.system(size: 40, weight: .semibold, design: .serif))
                    .contentTransition(.numericText(value: cost))
                    .animation(.default, value: cost)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
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
                .foregroundStyle(Color.textMuted(colorScheme))
            if let w = heroRingWindow {
                HeroRingGauge(pct: Int(w.utilization.rounded()))
                Text(preciseResetLine(w.resetsAt))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(2)
                    .foregroundStyle(Color.textMuted(colorScheme))
            } else {
                HeroRingGauge(pct: 0).opacity(0.3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
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
                if let session = sessionWindow {
                    SessionRow(
                        pct: Int(session.utilization.rounded()),
                        resetsAt: session.resetsAt,
                        eta: model.sessionETA,
                        sparkline: model.sessionSparkline
                    )
                }
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
                VStack(spacing: 12) {
                    ForEach(model.codexWindows) { w in
                        PrimaryRow(label: w.label.lowercased(), pct: Int(w.usedPercent.rounded()), resetsAt: w.resetsAt)
                    }
                }
            }
        }
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
                Button("quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                Button("dethok") {
                    NSWorkspace.shared.open(URL(string: "https://dethok.github.io")!)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundStyle(Color.textMuted(colorScheme).opacity(0.25))
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

struct ClaudeUsageApp: App {
    @State private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(model: model)
        } label: {
            if let image = model.gaugeImage {
                Image(nsImage: image)
            } else {
                Text(model.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
