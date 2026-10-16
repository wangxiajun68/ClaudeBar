**English** · **[中文](README.md)**

<p align="center">
  <img src="Sources/AppIcon-1024.png" alt="ClaudeBar" width="96">
</p>

<h1 align="center">ClaudeBar</h1>

<p align="center">
  A macOS workbench for Claude Code, Codex, and Cursor.<br>
  Switch models, follow sessions, and inspect usage and requests.
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml"><img src="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><img src="https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><strong>Download for macOS</strong></a>
</p>

https://github.com/user-attachments/assets/1aef4455-aa53-42d1-a1a7-63cdc3926551

<p align="center">
  <a href="docs/promo/claudebar.mp4">Download the high-quality film (1080p · 52 seconds)</a><br>
  Chinese interface and captions, matching the app
</p>

---

ClaudeBar brings Claude Code, Codex, and Cursor into one view. Check models and allowance in the menu bar, follow agents at the top of the screen, and open the desktop window for sessions, usage, and request details. Built with SwiftUI and AppKit for macOS 15+ on Apple Silicon.

## Install

Download the DMG from [Releases](https://github.com/wangxiajun68/ClaudeBar/releases/latest), drag ClaudeBar into Applications, then launch it. Add a provider in Models and enable other features as needed. See the [FAQ](docs/FAQ.md) for installation and permission issues.

Claude Code and Codex keep separate model configurations. Open a new terminal session after switching models. Cursor integration reads sessions, usage, and allowance.

## Interface

### Menu-bar popup

Check models, official allowance, and running sessions; switch models or open a desktop page.

<p><a href="docs/promo/popup.png"><img src="docs/promo/popup.png" width="460" alt="ClaudeBar menu-bar Popup"></a></p>

### Island

Agent status, completion alerts, and session details at the top of the screen. Multiple displays are supported: notched displays follow the hardware outline; other displays use a separate Focus deck.

[![Expanded island and external-display Focus deck](docs/promo/island.png)](docs/promo/island.png)

### Desktop window

Overview shows weather, system load, power flow, and active sessions. Sessions includes tools, context, lifetime tokens, and estimated cost. The migration workspace creates new sessions in supported target clients from existing histories.

[![Desktop overview](docs/promo/overview.png)](docs/promo/overview.png)

[![Session workspace](docs/promo/sessions.png)](docs/promo/sessions.png)

> The film and examples use production views with fixed demonstration data. Spatial layers and camera moves are presentation effects. Models, allowance, and costs are not real account data.

## Features

| Feature | What it does |
| --- | --- |
| Models and providers | Manage Claude Code / Codex independently; import providers, switch models, and inspect available models and capabilities. |
| Automatic gateway | Add models to an Auto pool; route by task tier and capabilities, manage provider concurrency, queues, RPM / estimated TPM, and fallback attempts. Inspect routing and request lanes. |
| Sessions and migration | Follow Claude Code, Codex, and Cursor activity and return to the client; choose a source, target, and history preview for migration. See the [migration contract](docs/technical/session-migration.md). |
| Usage and costs | Explore tokens by time, source, and model, with an activity heatmap. Estimates and actual Cursor charges stay separate; missing values are not zero. |
| Request inspection | A local API proxy accepts Chat / Responses / Anthropic clients. Enable payload recording to inspect conversations, tools, images, and raw data. |
| VPN | Bundled mihomo with subscriptions, nodes, system proxy, and TUN; inspect proxy / direct traffic history and configure domain rules. |
| Connectors and documents | Inspect Skills, MCP, plugins, and shared CLIs, with supported enable / disable operations. Read and edit Feishu documents in the workbench. |
| Mac and desktop | Weather, greetings, CPU / GPU, memory, disk, fans, and battery; charge limits on supported hardware, screenshots, and a floating wooden fish. |
| Matrix CLI | Use `mtx` for resources, sessions, usage, and supported model / VPN / connector controls. Performance mode releases the frontend while keeping background work and CLI access. |

[![Automatic model gateway](docs/promo/gateway.png)](docs/promo/gateway.png)

### Local API

Enable the proxy and use `http://127.0.0.1:15721/v1` (configurable), sending the local token with each request. Use model `auto` for automatic routing. Requests are not retried after output starts.

Payload recording is opt-in: enable it on the provider for Claude Code / Codex, or use the third-party traffic recording setting for other clients. See the [gateway guide](docs/LLM_GATEWAY.md). ⌘K opens page, model, and session search.

### Terminal

![Matrix CLI with example data](docs/assets/cli-matrix-preview.png)

```bash
mtx sessions count
mtx system --json
mtx -w 1
mtx mode performance
mtx mode desktop
```

The CLI is built with the app; command installation is explicit. Development uses `mtx-dev` with system integrations restricted. See the [CLI guide](docs/CLI.md) for installation and commands.

## Data and permissions

ClaudeBar reads local client history and usage. Model switching and some connector operations update client configuration. System features request permission when enabled.

| Source | Path or behavior |
| --- | --- |
| Claude Code | Reads `~/.claude/`; switching updates `~/.claude/settings.json`. |
| Codex | Reads `~/.codex/`; switching updates `~/.codex/config.toml`. |
| Cursor | Reads project records and `state.vscdb`; allowance and billing come from Cursor endpoints. |
| ClaudeBar | Production data lives in `~/Library/Application Support/ClaudeBar/`; request logs and VPN files use `logs/` and `vpn/`. |

Inference runs on the configured upstream. Weather, allowance, documents, and subscriptions contact their respective services. Connector inventory scans do not start MCP servers; opening MCP details connects and lists tools without calling them. Recorded payloads may contain conversation text.

Token costs use published prices and are estimates, not bills. Actual Cursor charges are shown separately. CNY and USD remain separate unless conversion is selected with an explicit rate; missing rates restore separate totals.

## Development

Requires macOS, Xcode Command Line Tools, and Python 3. Work on `dev` with the isolated ClaudeBar Dev identity; production configuration and running instances stay separate.

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
git switch dev
make setup
make build
```

| Command | Result |
| --- | --- |
| `make build` | Builds `.build/dev/ClaudeBar Dev.app`; no install or launch. |
| `make run` | Builds and launches development. |
| `make test-fast` / `make test TEST=core` | Fast regressions / one suite. |
| `make test` | All regressions, without launching the app or real integrations. |
| `make release` | Builds production without installing. |
| `make package` | Produces DMG, zip, and SHA-256 files. |

[Development guide](docs/DEVELOPMENT.md) · [Build and signing](docs/technical/07-build-and-signing.md) · [Release process](docs/RELEASING.md)

See the [film specification](docs/promo/prompt.md) to rebuild the video. Run `python3 Tools/serve-promo.py`, then open `http://127.0.0.1:8808/docs/promo/film.html` for chapter playback.

## Documentation and contribution

[Documentation](docs/README.md) · [FAQ](docs/FAQ.md) · [Changelog](docs/CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

Include system and app versions and reproduction steps in reports. Remove keys, account details, and private conversations from logs. Future architecture and naming research lives in [Reviews](docs/reviews/README.md); this release does not claim a completed Rust migration or rename.

## License

Code: [MIT](LICENSE). Lucide icons: [ISC](Sources/Licenses/Lucide.txt). Fonts and other assets: [asset notices](Sources/ClaudeBar/Resources/ASSET-LICENSES.md). VPN core: [mihomo notes](vendor/mihomo/README.md).
