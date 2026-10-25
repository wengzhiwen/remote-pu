# RemotePU

Native macOS menu-bar app that monitors CPU / GPU load, temperature, power, clocks, fans and memory on this Mac, on remote Apple Silicon Macs and on Linux NVIDIA GPU servers (multi-GPU, WSL2, unified-memory GB10) — over the system `ssh`, with nothing to install on the remote side.

- **Linux**: a stdlib-only Python collector is piped over ssh (`python3 -`) and streams NDJSON; it uses `nvidia-smi` for GPUs.
- **Mac**: `rpu-agent-mac` (Swift, no sudo: SMC + IOReport + IOKit). It runs locally, and the app uploads it to remote Macs automatically, gzip-compressed and SHA-256 verified.
- **Auth**: keys / ssh-agent / `~/.ssh/config`, or a password kept in the Keychain and handed to ssh through a private askpass helper.
- **History**: SQLite with 5 s buckets kept 7 days and 1 min rollups kept 90 days.
- **Automation**: the app exposes a local control API (`rpuctl`) for scripted testing — see [docs/CONTROL_API.md](docs/CONTROL_API.md).

See [PLAN.md](PLAN.md) for design decisions and [TESTING.md](TESTING.md) for what has been verified and the integration test plan.

## Build (on a Mac; Command Line Tools are enough)

```sh
scripts/mac.sh test      # Swift tests (uses Xcode toolchain if present) + Python collector tests
scripts/mac.sh bundle    # → dist/RemotePU.app (ad-hoc signed)
scripts/mac.sh install   # → ~/Applications/RemotePU.app
scripts/mac.sh run -- --data-dir /tmp/rpu-test --demo   # isolated instance with demo nodes
```

From a non-Mac dev box: `scripts/remote-mac.sh scripts/mac.sh bundle` syncs the tree to `$RPU_MAC_HOST` (e.g. `user@my-mac`; can be set in the gitignored `local/env.sh`) and runs the command there.

## Command-line tools (inside the app bundle, `Contents/Helpers/`)

| Tool | Purpose |
|---|---|
| `rpuctl` | Control a running app (nodes, data, UI, screenshots) |
| `rpu-probe` | Headless end-to-end check: `rpu-probe --count 5 local user@gpu-box` |
| `rpu-agent-mac` | Mac collector; `--once`, `--dump-topology`, `--dump-smc`, `--dump-ioreport`, `--dump-hid`, `--dump-gpu` |
| `rpu-askpass` | SSH_ASKPASS helper used for password logins |

The Linux collector can also be run by hand: `ssh host 'python3 -u - --interval 1 --count 3' < collector/rpu_collector.py`.

## Layout

```
collector/          Linux collector (Python) + tests
Sources/            RPUProtocol, RPUIPC, RemotePUCore, rpu-agent-mac, rpu-askpass, rpuctl, rpu-probe, RemotePU (app)
Tests/              Swift tests
Resources/          Info.plist, localisations (en, zh-Hans)
scripts/            mac.sh, remote-mac.sh, gen-collector.sh
docs/               CONTROL_API.md
```
