**English** · **[中文](README.md)**

<h1>
  <img src="Sources/AppIcon-1024.png" alt="ClaudeBar" width="64" height="64" align="middle">
  ClaudeBar
</h1>

<p align="center">
  <strong>One click in the menu bar. The whole AI pipeline, in your hand.</strong><br>
  Switch models · watch sessions · count tokens · run VPN · inspect traffic — all from the macOS menu bar.
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml"><img src="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><img src="https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><strong>Download latest →</strong></a>
</p>

## Interface

The main window is a dashboard: CPU die, GPU bars, memory tank, disk, Wi-Fi / Bluetooth, left and right fans — then the active vendor, live sessions, and tokens. The menu-bar popup is the same facts, compressed: three chips to switch CC / Codex / VPN, then living sessions and a monthly heatmap.

**Main window** · Ice / graphite tiles. Color lives in the charts.

![Dashboard](docs/screenshots/main-window.png)

**Menu bar** · Click the icon. Switch, inspect, leave. No window required.

![Menu-bar popup](docs/screenshots/menubar-popup.png)

## Why it exists

Running Claude Code, Codex, and Cursor at once usually means a pile of other apps: a VPN client, a proxy inspector, a model switcher, a session list. Each one owns a tray icon. Each context switch pulls you out of the terminal.

ClaudeBar folds that pile into **one** menu-bar app. It stays in the top bar; the main window opens when you want the dashboard. Click, do the thing, go back to the code.

## Six jobs

**Switch.** Claude Code and Codex keep separate vendor lists. Activation writes `~/.claude/settings.json` and `~/.codex/config.toml` independently. The popup has three chips: CC, Codex, VPN node.

**Forward.** A local proxy on `127.0.0.1` (default 15721) bridges Chat and Responses. Claude Code and Codex follow the model you just activated; third-party clients can pick a different upstream without rewriting those two files. Turn on capture and the **Traffic** page shows conversations, tool calls, images, and raw frames.

**Tunnel.** Bundled mihomo: subscriptions, node pick, delay tests, system proxy / TUN. Live ↓↑ rates sit in the menu bar. The outbound path is a breadcrumb (`Japan › telecom`), not a decorative metro line.

**Scene.** Sessions collect Claude Code, Cursor, Codex, and other CLIs onto one card: context bar, current tool, heartbeat, CPU / memory. Double-click to resume in the terminal or Cursor.

**Usage.** Model tokens only. Day / month / year heatmap, CC / Codex / third-party columns, input · cache-hit · write · output mix. VPN quota stays on the VPN page.

**Machine.** A 2×3 grid: load, temps in the CPU / GPU captions, disk fill, Wi-Fi / Bluetooth / ethernet, two clickable fans (auto / max). Light is ice `#EEF3F8`. Dark is graphite `#16181C`. Neither follows system appearance.

Also: ⌘⇧A region screenshot (copy / save / pin), ⌘K to jump to a page / session / model, and a desktop widget for today's tokens.

## How to

| You want to… | Go here |
| --- | --- |
| Change model | Menu-bar CC / Codex chip, or **Models**. Open a new terminal session for it to stick. |
| Change node | Menu-bar VPN chip, or the **VPN** mosaic. |
| See if a chat hit the proxy | Settings → local proxy → enable capture on the model card → **Traffic** |
| Point a third-party client at the same upstream | Base URL `http://127.0.0.1:<port>/v1`; pick a third-party vendor in Settings |
| Resume the session you just left | **Sessions** page or popup card |
| Grab a rectangle of the screen | ⌘⇧A (can be disabled in Settings) |

## Install

**macOS 15+**, Apple Silicon. Download the DMG from [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) and drop it on Applications.

If Gatekeeper blocks it:

```bash
xattr -cr /Applications/ClaudeBar.app && open /Applications/ClaudeBar.app
```

## What it touches

Read-first. The only writes into other tools are the ones you trigger by switching a model.

| Who | Path | Access |
| --- | --- | --- |
| Claude Code | `~/.claude/` | Read; writes `settings.json` on switch |
| Codex | `~/.codex/` | Read; writes `config.toml` on switch |
| Cursor | `~/Library/.../state.vscdb` | Read-only |
| Proxy captures | `~/Library/Application Support/ClaudeBar/logs/` | Written when recording is on |
| VPN | `~/Library/Application Support/ClaudeBar/vpn/` | Subscriptions and core config, local only |

## Build from source

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
make build
```

[Contributing](CONTRIBUTING.md) · [Versioning](docs/VERSIONING.md) · [Releasing](docs/RELEASING.md) · [Changelog](docs/CHANGELOG.md) · [FAQ](docs/FAQ.md)

## License

[MIT](LICENSE)

UI icons come from [Lucide](https://lucide.dev) (ISC), shipped inside the app as `Resources/Lucide.txt`. The VPN core, [mihomo](https://github.com/MetaCubeX/mihomo), is a sidecar downloaded at build time and is not committed.
