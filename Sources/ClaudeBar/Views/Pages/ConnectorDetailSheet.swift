import AppKit
import SwiftUI

struct ConnectorDetailSheet: View {
    let record: ConnectorRecord
    @Environment(\.dismiss) private var dismiss
    @State private var tools: [MCPToolSummary] = []
    @State private var toolsLoading = false
    @State private var toolsError: String?
    @State private var pluginInfo: PluginPreviewInfo?

    private var contentFile: URL {
        if record.kind == .skill { return record.source.appendingPathComponent("SKILL.md") }
        if let directory = record.detailDirectory { return directory }
        return record.source
    }

    private var finderURL: URL {
        let target = record.detailDirectory ?? record.source
        return FileManager.default.fileExists(atPath: target.path)
            ? target : target.deletingLastPathComponent()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s12) {
                GlyphWell(name: record.kind.symbol, tint: Theme.Ink.claude, size: 42)
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text(record.name)
                        .font(Theme.Font.titleSmall)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(record.kind == .skill ? "Skill" : record.kind.title) · \(record.sharedOwner ?? record.scope)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: Theme.Space.s12)
                Button("完成") { dismiss() }
                    .adaptiveGlassButton()
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.s24)
            HairlineDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s16) {
                    switch record.kind {
                    case .skill:
                        SkillMarkdownPreview(file: contentFile)
                    case .mcp:
                        mcpContents
                    case .plugin:
                        pluginContents
                    }
                    HairlineDivider()
                    sourceDetails
                }
                .frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(Theme.Space.s24)
            }
            HairlineDivider()
            HStack(spacing: Theme.Space.s8) {
                Button("复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(contentFile.path, forType: .string)
                }
                .adaptiveGlassButton()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([finderURL])
                }
                .adaptiveGlassButton()
                if record.kind == .plugin && record.platforms == [.cursor] {
                    Button("打开 Cursor") {
                        if let app = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
                            NSWorkspace.shared.open(app)
                        }
                    }
                    .adaptiveGlassButton()
                }
                Spacer()
                if FileManager.default.fileExists(atPath: contentFile.path) {
                    Button(record.kind == .plugin ? "打开安装位置" : "打开原文件") {
                        NSWorkspace.shared.open(contentFile)
                    }
                        .adaptiveGlassButton()
                }
            }
            .padding(.horizontal, Theme.Space.s24)
            .padding(.vertical, Theme.Space.s12)
        }
        .background(Theme.bgPrimary)
        .task(id: record.id) {
            if record.kind == .mcp { await loadTools() }
            if record.kind == .plugin { await loadPluginInfo() }
        }
    }

    @ViewBuilder private var mcpContents: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack {
                Text("可用工具")
                    .font(Theme.Font.section)
                    .foregroundStyle(Theme.textPrimary)
                if !toolsLoading && toolsError == nil {
                    Text("\(tools.count)")
                        .font(Theme.Font.microMedium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                // Also offered when the *first* read failed: a record whose
                // configuration has no recognisable command or URL reports that
                // as `toolsError`, and gating on `mcpConnection != nil` hid the
                // only button that could retry it.
                if !toolsLoading && (record.mcpConnection != nil || toolsError != nil) {
                    Button("重新读取") { Task { await loadTools() } }
                        .adaptiveGlassButton()
                }
            }
            Text("从 MCP 服务读取名称和描述，不会调用任何工具。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            if toolsLoading {
                ProgressView("正在连接 MCP 服务")
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else if let toolsError {
                StandbyEmptyState(label: toolsError, symbol: "exclamationmark.triangle",
                                  tint: Theme.Ink.error, block: true)
            } else if tools.isEmpty {
                StandbyEmptyState(label: "该服务没有公布工具",
                                  symbol: "square.grid.2x2",
                                  tint: Theme.textSecondary, block: true)
            } else {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: Theme.Space.s6) {
                        Text(tool.name)
                            .font(Theme.Font.chromeEmph)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        Text(tool.description)
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !tool.argumentNames.isEmpty {
                            Text("参数：" + tool.argumentNames.joined(separator: " · "))
                                .font(Theme.Font.microMono)
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.s12)
                    .tile(dense: true)
                }
            }
        }
    }

    private var pluginContents: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Text("插件详情")
                .font(Theme.Font.section)
                .foregroundStyle(Theme.textPrimary)
            if let info = pluginInfo {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    if let description = info.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let version = info.version, !version.isEmpty {
                        detailLine("版本", version)
                    }
                    ForEach(Array(info.components.enumerated()), id: \.offset) { _, item in
                        detailLine(item.0, "\(item.1) 项")
                    }
                    if info.components.isEmpty && (info.description?.isEmpty ?? true) {
                        Text("安装目录中没有可读取的插件清单。")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(Theme.Space.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tile()
            } else {
                ProgressView("正在读取插件信息")
                    .frame(maxWidth: .infinity, minHeight: 130)
            }
        }
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s10) {
            Text("来源与管理")
                .font(Theme.Font.section)
                .foregroundStyle(Theme.textPrimary)
            detailLine("范围", record.scope)
            detailLine("配置", record.source.path)
            if let directory = record.detailDirectory {
                detailLine("安装位置", directory.path)
            }
            Text(methodDescription)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var methodDescription: String {
        switch record.method {
        case .skillMove: return record.enabled == false ? "已移入 ClaudeBar 停用区；启用会还原到原位置。" : "停用会将整个 Skill 目录移入 ClaudeBar 停用区。"
        case .codexSetting: return "启停由 Codex 配置文件控制；新会话会读取更新后的设置。"
        case .claudePlugin: return "启停通过 Claude Code 官方命令执行；已有会话可能需要重新加载。"
        case .cursorMCP: return "Cursor 未提供可靠的本机状态读取；启停命令已直接显示在卡片上，执行后请在 Customize 核对。"
        case .native: return "此项目由原客户端管理；可打开原文件或安装位置查看。"
        }
    }

    private func loadTools() async {
        guard let connection = record.mcpConnection else {
            toolsError = "当前配置没有可识别的本地启动命令或 HTTP 地址；请在原客户端查看工具。"
            return
        }
        toolsLoading = true
        toolsError = nil
        do {
            tools = try await MCPToolDiscovery.list(connection: connection, from: record.source)
        } catch {
            toolsError = error.localizedDescription
        }
        toolsLoading = false
    }

    private func loadPluginInfo() async {
        let directory = record.detailDirectory ?? record.source
        pluginInfo = await Task.detached(priority: .utility) {
            PluginPreviewInfo.read(directory: directory)
        }.value
    }
}

private struct PluginPreviewInfo: Sendable {
    let description: String?
    let version: String?
    let components: [(String, Int)]

    static func read(directory: URL) -> PluginPreviewInfo {
        let fm = FileManager.default
        let candidates = [directory.appendingPathComponent("plugin.json"),
                          directory.appendingPathComponent(".claude-plugin/plugin.json"),
                          directory.appendingPathComponent(".codex-plugin/plugin.json"),
                          directory.appendingPathComponent(".cursor-plugin/plugin.json")]
        let manifest = candidates.first(where: { fm.fileExists(atPath: $0.path) })
        let data = manifest.flatMap { try? Data(contentsOf: $0) }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var components: [(String, Int)] = []
        for (folder, label) in [("skills", "Skills"), ("commands", "命令"),
                                ("agents", "Agents"), ("mcp", "MCP 配置")] {
            let path = directory.appendingPathComponent(folder)
            if let entries = try? fm.contentsOfDirectory(atPath: path.path), !entries.isEmpty {
                components.append((label, entries.count))
            }
        }
        if !components.contains(where: { $0.0 == "MCP 配置" }) {
            let configured = (json["mcpServers"] as? [String: Any])?.count ?? 0
            if configured > 0 {
                components.append(("MCP 配置", configured))
            } else if fm.fileExists(atPath: directory.appendingPathComponent(".mcp.json").path) {
                components.append(("MCP 配置", 1))
            }
        }
        return PluginPreviewInfo(description: json["description"] as? String,
                                 version: json["version"] as? String,
                                 components: components)
    }
}
