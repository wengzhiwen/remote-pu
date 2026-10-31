# RemotePU — notes for Claude / contributors

Native macOS menu-bar monitor for local and remote CPU/GPU (Apple Silicon Macs, Linux + NVIDIA) over the system ssh. Design: PLAN.md · test status and plan: TESTING.md · control API: docs/CONTROL_API.md.

If a `CLAUDE.local.md` exists (gitignored), it holds the private test-host details and project history. Never commit private host names, user names, IPs, GPU UUIDs or passwords. Use placeholders such as `user@mac-b` and `user@gpu-wsl`, with the real values in `local/env.sh`.

## Build & test (on a Mac)

- `scripts/mac.sh test` runs the Swift tests (swift-testing; uses `DEVELOPER_DIR=/Applications/Xcode.app/...` when Xcode exists, because the CLT alone can't run them) plus `python3 -m unittest discover -s collector/tests`.
- `scripts/mac.sh bundle` builds `dist/RemotePU.app`, ad-hoc signed. Command Line Tools are enough; there is no Xcode project.
- `scripts/mac.sh recovery` builds `dist/RemotePU-Recovery.app` with a separate bundle identifier for a corrupt ControlCenter association. It shares production data and SSH keychain entries: stop the normal instance before launching it. This is a workaround, not a repair of the original system record.
- After editing `collector/rpu_collector.py`, run `scripts/gen-collector.sh`. The embedded copy in `Sources/RemotePUCore/Generated/` is checked by a unit test. `scripts/mac.sh` regenerates it automatically.
- The app icon is drawn by `scripts/gen-icon.swift`; run `scripts/gen-icon.sh [pulse|nodes|gauge]` to regenerate `Resources/AppIcon.icns`.
- To work on an isolated app instance:
  - `open -n dist/RemotePU.app --args --data-dir /tmp/rpu-x --no-keychain [--demo]`
  - Launch UI instances through `open` (LaunchServices), not by executing `Contents/MacOS/RemotePU` directly; macOS 26 tracks menu-bar items by application identity as well as their autosave name.
  - then drive it with `dist/RemotePU.app/Contents/Helpers/rpuctl --socket /tmp/rpu-x/control.sock <cmd>`.
  - Quit it with `rpuctl app.quit` when done.
- To check UI content, use `rpuctl ui.render page=overview|<node> [appearance=dark] path=…` (offscreen, no permissions). `ui.screenshot` only gets full pixels with Screen Recording permission.

## Code map

- `Sources/RPUProtocol`: the NDJSON v1 wire format (the only thing the app parses; every field optional).
- `Sources/RemotePUCore`:
  - `NodeRunner`: per-node state machine — ssh master → probe → deploy → stream → backoff.
  - `SSH.swift`: argument builders and remote scripts.
  - `AskpassBroker`: password logins.
  - `HistoryStore`: SQLite.
  - `ManagedProcess`: line-streamed child processes.
- `Sources/rpu-agent-mac`: Apple Silicon collector (SMC, IOReport, IOKit). Its `--dump-*` flags help calibrate new chips.
- `Sources/RemotePU`: the SwiftUI app. Key files:
  - `AppModel`: state.
  - `AppControl`: control API.
  - `Theme`: palette, icons, live cues.
  - `Views/`: the screens.

## Gotchas learned the hard way

- Never return `.terminateLater` and finish on the main actor: AppKit's nested loop doesn't drain the main queue. Quit runs the cleanup on the cooperative pool with a bounded wait (see `AppDelegate`).
- ssh masters run `cat` remotely, on a stdin pipe the app holds open (`holdStdinOpen`), so they die with the app; plain `-N` masters were left running after the app quit.
- Agent uploads must be verified by SHA-256 on the remote before install: a dropped connection makes `cat > file` succeed with a truncated file.
- `LazyVGrid`/`LazyVStack` render nothing in `ImageRenderer`; use `ColumnsLayout`/`Grid`. A `ScrollView` inside the self-sizing popover panel collapses to zero height.
- The menu bar is plain AppKit (`MenuPanelController`: `NSStatusItem` with a pre-rendered template `NSImage` title + `NSPopover`); SwiftUI's `MenuBarExtra(.window)` replays its expand animation on every scene update (macOS 26), which made the panel constantly re-animate and unclickable. The main and settings windows are AppKit windows hosting SwiftUI (`NSHostingController` syncs toolbars and window titles).
- Swift charts: one measure per chart (no dual axes); colours follow the entity (GPU index → categorical slot), never its rank. Status colours always come with an icon and a label.
- In zsh, `$CMD args` does not word-split; define a shell function instead.
- UI strings are English keys in code, with translations in `Resources/zh-Hans.lproj/Localizable.strings`. Interpolated `Text("…\(x)")` creates `%@`/`%lld` keys, so add those keys too (or use `Text(verbatim:)`).
- SwiftUI animation in a per-sample UI is render-loop poison: a `repeatForever` or a value transition restarted by every sample (~1 Hz) keeps the hosting view re-laying-out at ~120 Hz — the dashboard stuttered when scrolling. Continuous motion is a CABasicAnimation on a CALayer (see `PulseDot`), value texts don't animate, and `MetricChart` observes nothing (a task pulls its data). Hidden view graphs also keep rendering: window content and the popover's contentViewController are dropped on close and rebuilt on open.
