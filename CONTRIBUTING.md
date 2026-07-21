# Contributing to TokenBurn

## Building

```
git clone https://github.com/dethok/tokenburn.git
cd tokenburn
bash build.sh
```

`build.sh` runs `swift build -c release` and assembles `~/Applications/TokenBurn.app`. You need
Xcode Command Line Tools (`xcode-select --install`). No other dependencies — it's a single Swift
package (`Package.swift`), no third-party libraries.

Run the app's offline self-check any time: `.build/release/TokenBurn --selftest`.

## Two-OS support policy

TokenBurn supports **macOS 14+**. There are two visual paths, picked automatically at runtime:

- **macOS 26+**: full Liquid Glass treatment.
- **macOS 14–25**: `NSVisualEffectView` (`.hudWindow`, dark) fallback — same dark HUD panel look,
  no `.glassEffect`/26-only APIs involved.

If you add a UI change, keep both paths working: guard any macOS-26-only API with
`if #available(macOS 26, *)` and give <26 a real fallback, don't just disable the feature. Build
targets the macOS 14 deployment target (`Package.swift`) using the newest available SDK — the
compiler will flag anything that needs a guard.

## Pull requests

- Keep diffs scoped to one change.
- Run `.build/release/TokenBurn --selftest` before opening a PR — it must pass.
- If you touch anything version-gated, say in the PR description which macOS versions you
  actually ran it on (CI only builds; it can't verify pre-26 runtime behavior).
- No new dependencies without discussion first — this stays a single-package, stdlib+AppKit/
  SwiftUI-only project.
