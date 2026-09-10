**English** · **[中文](README.md)**

<h1>
  <img src="Sources/AppIcon-1024.png" alt="ClaudeBar" width="64" height="64" align="middle">
  ClaudeBar
</h1>

<p align="center">
  <strong>One menu bar for your entire AI workbench.</strong><br>
  VPN · Local LLM proxy · Multi-agent model switching · Session & usage monitoring — always one click away in the macOS menu bar.
</p>

![CI](https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg)![Release](https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release)![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white)![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)![MIT](https://img.shields.io/badge/license-MIT-green)

**[Download latest release](https://github.com/wangxiajun68/ClaudeBar/releases/latest)**

## Why ClaudeBar

AI-assisted development increasingly depends on a pile of separate tools: a VPN client, a packet inspector, a model switcher, a session browser — each with its own window, tray icon, and startup cost, all serving the same workflow.

**ClaudeBar collapses them into a single menu-bar app.** It lives in the menu bar, takes no dock or window space, and is always one click away: switch Claude Code / Codex providers and models, bring up or inspect a VPN tunnel, review every frame of traffic through the local proxy, and browse sessions and token usage across three tools — without launching anything else or leaving your terminal.

In one sentence: **keep the infrastructure in the menu bar, keep your attention on the work.**

## What it does

- **VPN** — bundled mihomo: subscriptions, node select, delay tests, system proxy; live rates in the menu bar.
- **Local LLM proxy** — forwards on `127.0.0.1`, bridges Chat / Responses. Claude Code and Codex each use their selected vendor; third-party clients can pick a different upstream. With traffic recording, inspect conversations, tool calls, images, and raw payloads.
- **Region screenshot** — ⌘⇧A to copy / save / pin a snip.
- **Model switching** — Claude Code and Codex keep separate provider lists; activation writes `settings.json` / `config.toml` independently. Copy configs only via explicit import in Manage.
- **Sessions · usage · resources** — tri-agent session aggregation, token stats, CPU / GPU / memory attribution.
- **Menu-bar popup** — switch models, scan sessions, check resources and usage without opening the main window.
- **Desktop widget** — today's token total and active sessions at a glance.

## Screenshots

![Traffic inspector](docs/screenshots/traffic.png)

*Traffic inspector · compact view: consecutive tool calls and system prompts are collapsed by default, with keyword search.*

| Main window                                      | Menu-bar popup                                        | Desktop widget                         |
| ------------------------------------------------ | ----------------------------------------------------- | -------------------------------------- |
| ![Main window](docs/screenshots/main-window.png) | ![Menu-bar popup](docs/screenshots/menubar-popup.png) | ![Widget](docs/screenshots/widget.png) |

## Quick start

| Goal                   | Path                                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------------------------- |
| **VPN**                | **VPN** page → add subscription → enable system proxy; switch nodes from the menu bar |
| **Capture traffic**    | Settings → local proxy → enable recording on a model card → **Traffic**                               |
| **Switch model**       | **Models** page (Claude Code / Codex tabs) or menu-bar popup → activate → open a new terminal session |
| **Resume session**     | **Sessions** page or popup → click a card                                                             |
| **Global search**      | `⌘K` on any page — search pages / sessions / models                                                   |
| **Third-party client** | Base URL → `http://127.0.0.1:<port>/v1`; Settings → Local proxy to pick a third-party upstream |
| **Region screenshot**  | ⌘⇧A (can be disabled in Settings) |

## Install

Requires **macOS 15+** and Apple Silicon (`arm64`). Download the DMG from [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) and drag it to Applications.

If Gatekeeper blocks the app:

```bash
xattr -cr /Applications/ClaudeBar.app && open /Applications/ClaudeBar.app
```

## Data & privacy

ClaudeBar follows a read-first principle: apart from the explicit write-back when switching models, it never modifies your tools' data.

| Source         | Path                                            | Access                                       |
| -------------- | ----------------------------------------------- | -------------------------------------------- |
| Claude Code    | `~/.claude/`                                    | Read-only (writes `settings.json` on switch) |
| Codex          | `~/.codex/`                                     | Read-only (writes `config.toml` on switch)   |
| Cursor         | `~/Library/.../state.vscdb`                     | Read-only                                    |
| Proxy captures | `~/Library/Application Support/ClaudeBar/logs/` | Written when recording is on                 |
| VPN            | `~/Library/Application Support/ClaudeBar/vpn/`  | Subscriptions and core config (local only)   |

## Build from source

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git && cd ClaudeBar && make build
```

See [CONTRIBUTING.md](CONTRIBUTING.md) · [docs/VERSIONING.md](docs/VERSIONING.md) · [docs/RELEASING.md](docs/RELEASING.md) · [docs/CHANGELOG.md](docs/CHANGELOG.md) · [FAQ](docs/FAQ.md)

## License

[MIT](LICENSE)
