# 🔥 TokenBurn

<!-- TODO: build status badge once CI is enabled (workflow staged at ci/build.yml, blocked on gh token `workflow` scope) -->

A free, native macOS menu bar app for watching your Claude Code and Codex usage: live rate-limit gauges, a Liquid Glass popover, and a local, on-device API-equivalent cost audit of your own session logs.

## Install

```
brew tap dethok/tap
brew install tokenburn
```

This builds TokenBurn from source on your machine (no signed binary yet, so this avoids the Gatekeeper wall a downloaded `.app` would hit) and installs it into `~/Applications/TokenBurn.app`.

### Manual build (fallback)

```
git clone https://github.com/dethok/tokenburn.git
cd tokenburn
bash build.sh
```

This builds the app and installs it to `~/Applications/TokenBurn.app`. Launch it from Finder or `open ~/Applications/TokenBurn.app`.

## Requirements

- macOS 14+. macOS 26+ gets the full Liquid Glass panel; macOS 14–25 gets the same dark HUD panel via an `NSVisualEffectView` fallback (visually equivalent, no Liquid Glass API involved). The macOS 14–25 path compiles clean but hasn't been runtime-verified on those OS versions yet — [file an issue](https://github.com/dethok/tokenburn/issues) if something looks off.
- Xcode Command Line Tools (`xcode-select --install`)
- An existing Claude Code login (for Claude usage data)
- Codex CLI login is optional, for Codex usage data

## Privacy

TokenBurn runs entirely on your machine. It talks only to `api.anthropic.com` and `chatgpt.com`, using your existing local Claude Code / Codex CLI logins — it never asks you to sign in separately. Cost calculations are computed locally by reading your own session logs (`~/.claude/projects/`, `~/.codex/sessions/`); nothing is uploaded anywhere. There is no telemetry, no analytics, and no third-party server in the loop.

TokenBurn uses the same undocumented usage endpoints the official Claude Code and Codex CLIs use internally. These aren't a published, stable API — they can change or break without notice.

## Screenshots

| Limits | Insights |
|---|---|
| ![Live Claude and Codex limits with pace tracking](screenshots/limits.png) | ![Spend insights by model](screenshots/insights.png) |
