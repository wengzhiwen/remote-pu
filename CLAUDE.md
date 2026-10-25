# RemotePU — notes for Claude / contributors

Native macOS menu-bar monitor for local and remote CPU/GPU (Apple Silicon Macs, Linux + NVIDIA) over the system ssh. Design: PLAN.md · test status and plan: TESTING.md · control API: docs/CONTROL_API.md.

If a `CLAUDE.local.md` exists (gitignored), it holds the private test-host details and project history. Never commit private host names, user names, IPs, GPU UUIDs or passwords. Use placeholders such as `user@mac-b` and `user@gpu-wsl`, with the real values in `local/env.sh`.

## Build & test (on a Mac)

- `scripts/mac.sh test` runs the Swift tests (swift-testing; uses `DEVELOPER_DIR=/Applications/Xcode.app/...` when Xcode exists, because the CLT alone can't run them) plus `python3 -m unittest discover -s collector/tests`.
- `scripts/mac.sh bundle` builds `dist/RemotePU.app`, ad-hoc signed. Command Line Tools are enough; there is no Xcode project.
- After editing `collector/rpu_collector.py`, run `scripts/gen-collector.sh`. The embedded copy in `Sources/RemotePUCore/Generated/` is checked by a unit test. `scripts/mac.sh` regenerates it automatically.
- To work on an isolated app instance:
  - `open -n dist/RemotePU.app --args --data-dir /tmp/rpu-x --no-keychain [--demo]`
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
- `LazyVGrid`/`LazyVStack` render nothing in `ImageRenderer`; use `ColumnsLayout`/`Grid`. A `ScrollView` inside a self-sizing `MenuBarExtra(.window)` collapses to zero height.
- The menu bar title is a pre-rendered template `NSImage`; a MenuBarExtra label doesn't reliably show several images and texts.
- Swift charts: one measure per chart (no dual axes); colours follow the entity (GPU index → categorical slot), never its rank. Status colours always come with an icon and a label.
- In zsh, `$CMD args` does not word-split; define a shell function instead.
- UI strings are English keys in code, with translations in `Resources/zh-Hans.lproj/Localizable.strings`. Interpolated `Text("…\(x)")` creates `%@`/`%lld` keys, so add those keys too (or use `Text(verbatim:)`).
