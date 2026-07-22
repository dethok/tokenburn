// TokenBurn — iPhone widget (Scriptable), aligned with the desktop app's design:
// green accent, session ring hero + pace verdict, per-window rows (weekly /
// fable / codex) with used-%, bar, reset countdown and under/over-pace deltas.
// Reads tokenburn-status.json written by the Mac app into Scriptable's iCloud
// folder. Pure file read — the phone never talks to any usage endpoint.

const FILE = "tokenburn-status.json";
const GREEN = new Color("#68e15b");
const GREEN_DIM = new Color("#68e15b", 0.9);
const AMBER = new Color("#ff9f0a");
const GRAY = new Color("#98989d");
const TRACK = new Color("#3a3a3c", 0.9);
const CARD = new Color("#2c2c2e", 0.55);
const BG_TOP = new Color("#1e1e20");
const BG_BOTTOM = new Color("#0c0c0d");

const HOUR = 3600 * 1000;
const SESSION_MS = 5 * HOUR;
const WEEK_MS = 7 * 24 * HOUR;

function bg(w) {
  const g = new LinearGradient();
  g.colors = [BG_TOP, BG_BOTTOM];
  g.locations = [0, 1];
  w.backgroundGradient = g;
}

async function loadStatus() {
  const fm = FileManager.iCloud();
  const path = fm.joinPath(fm.documentsDirectory(), FILE);
  // Download BEFORE the existence check: an undownloaded iCloud file can fail
  // fileExists until it's materialized locally. Throws if truly absent.
  try {
    await fm.downloadFileFromiCloud(path);
  } catch (e) {}
  if (!fm.fileExists(path)) return null;
  try {
    return JSON.parse(fm.readString(path));
  } catch (e) {
    return null;
  }
}

function pick(windows, re) {
  if (!windows) return null;
  return windows.find((w) => re.test(w.id) || re.test(w.label)) || null;
}

// Fraction of the window already elapsed (0..1), from its reset time; null off-window.
function elapsedFrac(win, windowMs) {
  if (!win || !win.resetsAt) return null;
  const start = Date.parse(win.resetsAt) - windowMs;
  const f = (Date.now() - start) / windowMs;
  return f > 0 && f <= 1 ? f : null;
}

// elapsed% of the window minus used% — positive = under pace, negative = over.
function paceDelta(win, windowMs) {
  const f = elapsedFrac(win, windowMs);
  if (f == null) return null;
  return Math.round(f * 100 - win.usedPct);
}

function fmtCountdown(resetsAt) {
  if (!resetsAt) return null;
  const ms = Date.parse(resetsAt) - Date.now();
  if (ms <= 0) return "now";
  const h = Math.floor(ms / HOUR);
  if (h >= 48) return `in ${Math.round(h / 24)}d`;
  const m = Math.floor((ms % HOUR) / 60000);
  return h > 0 ? `in ${h}h ${m}m` : `in ${m}m`;
}

function fmtResetClock(resetsAt) {
  const d = new Date(Date.parse(resetsAt));
  const df = new DateFormatter();
  df.dateFormat = "HH:mm";
  return df.string(d);
}

// Session ring drawn into an image: gray track circle + green arc from 12
// o'clock, used-% in the center — mirrors the desktop hero ring.
function ringImage(sizePt, usedPct, accent, paceFrac) {
  const s = sizePt;
  const ctx = new DrawContext();
  ctx.size = new Size(s, s);
  ctx.opaque = false;
  ctx.respectScreenScale = true;
  const lw = 6;
  const r = s / 2 - lw / 2 - 1;
  const c = s / 2;

  ctx.setLineWidth(lw);
  ctx.setStrokeColor(TRACK);
  ctx.strokeEllipse(new Rect(c - r, c - r, 2 * r, 2 * r));

  const toRad = (f) => (-90 + 360 * f) * (Math.PI / 180);
  const arcPoint = (f, radius) =>
    new Point(c + radius * Math.cos(toRad(f)), c + radius * Math.sin(toRad(f)));

  const strokeArc = (from, to, color) => {
    if (to - from < 0.003) return;
    const steps = Math.max(2, Math.round(96 * (to - from)));
    const pts = [];
    for (let i = 0; i <= steps; i++) pts.push(arcPoint(from + (to - from) * (i / steps), r));
    const path = new Path();
    path.addLines(pts);
    ctx.setStrokeColor(color);
    ctx.addPath(path);
    ctx.strokePath();
  };

  const frac = Math.max(0, Math.min(1, usedPct / 100));
  const pace = paceFrac != null ? Math.max(0, Math.min(1, paceFrac)) : null;

  // Pace zone: dashed grey arc from used → elapsed-time point (the circular
  // version of the hatched bar zone).
  if (pace != null && pace > frac + 0.01) {
    // Short dashes along the arc, slightly slimmer than the main ring radially.
    const dashOn = 0.006, dashOff = 0.009;
    const grey = new Color("#8e8e93", 0.5);
    ctx.setLineWidth(lw * 0.75);
    for (let f = frac; f < pace; f += dashOn + dashOff) {
      strokeArc(f, Math.min(f + dashOn, pace), grey);
    }
    ctx.setLineWidth(lw);
  }

  strokeArc(0, frac, accent);

  // Radial tick at the pace point, crossing the ring like the bar's tick.
  if (pace != null && pace > 0.01 && pace < 0.99) {
    ctx.setStrokeColor(new Color("#ffffff", 0.85));
    ctx.setLineWidth(1.5);
    const p = new Path();
    p.addLines([arcPoint(pace, r - lw / 2 - 1), arcPoint(pace, r + lw / 2 + 1)]);
    ctx.addPath(p);
    ctx.strokePath();
    ctx.setLineWidth(lw);
  }

  // Digits big, "%" smaller beside them (desktop-style). DrawContext can't mix
  // fonts in one string, so the number is centered (nudged left to make room)
  // and the % drawn separately, smaller, just after it.
  const fs = s * 0.26;
  const num = `${Math.round(usedPct)}`;
  ctx.setFont(Font.boldSystemFont(fs));
  ctx.setTextColor(Color.white());
  ctx.setTextAlignedCenter();
  ctx.drawTextInRect(num, new Rect(0, s * 0.32, s, fs * 1.2));
  const numW = num.length * fs * 0.58;
  ctx.setFont(Font.boldSystemFont(fs * 0.55));
  ctx.setTextAlignedLeft();
  ctx.drawTextInRect("%", new Rect(s / 2 + numW / 2 + 1, s * 0.32 + fs * 0.48, fs, fs));
  return ctx.getImage();
}

// Desktop-style paced bar drawn as an image: green fill (used), then a hatched
// grey zone up to the elapsed-time point (the pace headroom), a pace tick, and
// plain dark track for the rest.
function pacedBarImage(width, usedFrac, paceFrac) {
  const h = 6;
  const ctx = new DrawContext();
  ctx.size = new Size(width, h);
  ctx.opaque = false;
  ctx.respectScreenScale = true;

  const rounded = (x, w, color) => {
    const p = new Path();
    p.addRoundedRect(new Rect(x, 0, w, h), h / 2, h / 2);
    ctx.addPath(p);
    ctx.setFillColor(color);
    ctx.fillPath();
  };

  rounded(0, width, TRACK);

  const used = Math.max(0, Math.min(1, usedFrac)) * width;
  const pace = paceFrac != null ? Math.max(0, Math.min(1, paceFrac)) * width : null;

  // Hatched pace zone: diagonal light-grey stripes between used and pace point.
  if (pace != null && pace > used + 2) {
    ctx.setStrokeColor(new Color("#8e8e93", 0.45));
    ctx.setLineWidth(1);
    for (let x = used - h; x < pace; x += 3.5) {
      // 45° segment from (x, h) to (x+h, 0), clamped to the zone horizontally.
      let x0 = x, y0 = h, x1 = x + h, y1 = 0;
      if (x0 < used) { y0 = h - (used - x0); x0 = used; }
      if (x1 > pace) { y1 = x1 - pace; x1 = pace; }
      if (x1 <= x0) continue;
      const p = new Path();
      p.addLines([new Point(x0, y0), new Point(x1, y1)]);
      ctx.addPath(p);
      ctx.strokePath();
    }
  }

  if (used > 1) rounded(0, Math.max(h, used), GREEN);

  // Pace tick at the elapsed-time point.
  if (pace != null && pace > 1 && pace < width - 1) {
    ctx.setFillColor(new Color("#ffffff", 0.85));
    ctx.fillRect(new Rect(pace - 0.75, 0, 1.5, h));
  }
  return ctx.getImage();
}

function addBar(stack, usedFrac, width, paceFrac) {
  const img = stack.addImage(pacedBarImage(width, usedFrac, paceFrac));
  img.imageSize = new Size(width, 6);
}

function addFreshnessDot(stack, status) {
  const ageMin = (Date.now() - Date.parse(status.generatedAt)) / 60000;
  const dot = stack.addStack();
  dot.size = new Size(6, 6);
  dot.cornerRadius = 3;
  dot.backgroundColor = ageMin > 30 ? GRAY : GREEN;
  if (ageMin > 30) {
    stack.addSpacer(3);
    const t = stack.addText(`stale ${Math.round(ageMin)}m`);
    t.font = Font.systemFont(8);
    t.textColor = GRAY;
  }
}

// One per-window row: "label  N%" + bar + "resets · in Xd · M% under pace".
function addWindowRow(col, label, win, windowMs, barWidth) {
  const head = col.addStack();
  head.centerAlignContent();
  const l = head.addText(label);
  l.font = Font.mediumSystemFont(11);
  l.textColor = Color.white();
  head.addSpacer();
  const p = head.addText(`${Math.round(win.usedPct)}%`);
  p.font = Font.boldSystemFont(12);
  p.textColor = GREEN;

  col.addSpacer(2);
  addBar(col, win.usedPct / 100, barWidth, elapsedFrac(win, windowMs));
  col.addSpacer(2);

  const sub = col.addStack();
  sub.centerAlignContent();
  const bits = [];
  const cd = fmtCountdown(win.resetsAt);
  if (cd) bits.push(`resets ${cd}`);
  const s = sub.addText(bits.join(" · ") || " ");
  s.font = Font.systemFont(8.5);
  s.textColor = GRAY;
  const pace = paceDelta(win, windowMs);
  if (pace != null) {
    sub.addSpacer(4);
    const pt = sub.addText(pace >= 0 ? `${pace}% under pace` : `${-pace}% over pace`);
    pt.font = Font.mediumSystemFont(8.5);
    pt.textColor = pace >= 0 ? GREEN_DIM : AMBER;
  }
}

function sessionPaceLine(session) {
  const pace = paceDelta(session, SESSION_MS);
  if (pace == null) return null;
  if (pace >= 10) return { text: "✓ well within pace", color: GREEN_DIM };
  if (pace >= 0) return { text: "✓ on pace", color: GREEN_DIM };
  return { text: `▲ ${-pace}% over pace`, color: AMBER };
}

function setupWidget() {
  const w = new ListWidget();
  bg(w);
  const t = w.addText("🔥 TokenBurn");
  t.font = Font.boldSystemFont(14);
  t.textColor = GREEN;
  w.addSpacer(6);
  const m = w.addText("Waiting for Mac snapshot…\nIs ClaudeUsage running and\nScriptable iCloud enabled?");
  m.font = Font.systemFont(11);
  m.textColor = GRAY;
  // Diagnostic: what this device actually sees in the synced folder.
  let seen = [];
  try {
    const fm = FileManager.iCloud();
    seen = fm.listContents(fm.documentsDirectory());
  } catch (e) {}
  w.addSpacer(4);
  const d = w.addText("sees: " + (seen.length ? seen.join(" · ").slice(0, 90) : "nothing"));
  d.font = Font.systemFont(8);
  d.textColor = GRAY;
  return w;
}

function sessionColumn(col, status, ringSize) {
  const session = pick(status.claude, /session|five_hour/i);
  const used = session ? session.usedPct : 0;

  const ring = col.addImage(ringImage(ringSize, used, GREEN, elapsedFrac(session, SESSION_MS)));
  ring.imageSize = new Size(ringSize, ringSize);

  col.addSpacer(4);
  if (session) {
    const left = Math.max(0, Math.min(100, Math.round(100 - session.usedPct)));
    const l1 = col.addText(
      session.resetsAt
        ? `${left}% left · resets ${fmtResetClock(session.resetsAt)}`
        : `${left}% left`
    );
    l1.font = Font.systemFont(9.5);
    l1.textColor = GRAY;
    const cd = fmtCountdown(session.resetsAt);
    if (cd) {
      const l2 = col.addText(cd);
      l2.font = Font.mediumSystemFont(9.5);
      l2.textColor = Color.white();
    }
    const pace = sessionPaceLine(session);
    if (pace) {
      col.addSpacer(2);
      const pl = col.addText(pace.text);
      pl.font = Font.mediumSystemFont(9);
      pl.textColor = pace.color;
    }
  }
}

function buildSmall(status) {
  const w = new ListWidget();
  bg(w);
  const head = w.addStack();
  head.centerAlignContent();
  const t = head.addText("🔥 Session");
  t.font = Font.boldSystemFont(11);
  t.textColor = Color.white();
  head.addSpacer();
  addFreshnessDot(head, status);
  w.addSpacer(4);
  const col = w.addStack();
  col.layoutVertically();
  sessionColumn(col, status, 62);
  return w;
}

function buildMedium(status) {
  const w = new ListWidget();
  bg(w);
  w.setPadding(10, 12, 10, 12);

  // Header: brand + plan chip + freshness + cost today
  const head = w.addStack();
  head.centerAlignContent();
  const brand = head.addText("🔥 TokenBurn");
  brand.font = Font.boldSystemFont(12);
  brand.textColor = Color.white();
  if (status.claudePlan) {
    head.addSpacer(5);
    const plan = head.addText(status.claudePlan);
    plan.font = Font.systemFont(9);
    plan.textColor = GRAY;
  }
  head.addSpacer(6);
  addFreshnessDot(head, status);
  head.addSpacer();
  const c = status.costTodayUSD || {};
  if (c.claude != null || c.codex != null) {
    const cost = head.addText(`today $${((c.claude ?? 0) + (c.codex ?? 0)).toFixed(0)}`);
    cost.font = Font.mediumSystemFont(10);
    cost.textColor = GRAY;
  }

  w.addSpacer(6);

  // Body: session hero (ring) left, window rows right
  const body = w.addStack();
  body.layoutHorizontally();
  body.centerAlignContent();

  const colL = body.addStack();
  colL.layoutVertically();
  sessionColumn(colL, status, 58);

  body.addSpacer();

  const colR = body.addStack();
  colR.layoutVertically();
  const BAR_W = 148;

  const weekly = pick(status.claude, /weekly_all|seven_day/i);
  if (weekly) addWindowRow(colR, "weekly", weekly, WEEK_MS, BAR_W);

  // Any model-scoped weekly windows (e.g. "Weekly · Fable") get their own row.
  const scoped = (status.claude || []).filter((x) => /weekly_scoped/i.test(x.id));
  for (const winScoped of scoped.slice(0, 1)) {
    colR.addSpacer(5);
    const name = winScoped.label.replace(/^Weekly\s*·\s*/i, "").toLowerCase();
    addWindowRow(colR, name, winScoped, WEEK_MS, BAR_W);
  }

  const codexWeekly = pick(status.codex, /week/i) || (status.codex || [])[0];
  if (codexWeekly) {
    colR.addSpacer(5);
    addWindowRow(colR, "codex", codexWeekly, WEEK_MS, BAR_W);
  }

  return w;
}

const status = await loadStatus();
let widget;
if (!status) {
  widget = setupWidget();
} else if (config.widgetFamily === "small") {
  widget = buildSmall(status);
} else {
  widget = buildMedium(status);
}
widget.refreshAfterDate = new Date(Date.now() + 10 * 60 * 1000);
Script.setWidget(widget);
if (config.runsInApp) await widget.presentMedium();
Script.complete();
