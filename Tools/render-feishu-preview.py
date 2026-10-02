#!/usr/bin/env python3
"""Render the production native document surface with synthetic data, no cloud or user stores."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/feishu-preview'
out.mkdir(parents=True, exist_ok=True)
theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text().split('// MARK: - Soft drop shadow')[0]
source = theme + (root / 'Sources/ClaudeBar/Models/DocumentTable.swift').read_text() + (root / 'Sources/ClaudeBar/Models/DocumentMarkup.swift').read_text()
source += r'''
final class AppPreferences {
    static let shared = AppPreferences()
    var isDark = false
}
struct HairlineDivider: View { var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) } }
struct ActionIcon: View {
    let symbol: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 26
    var action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: symbol).foregroundStyle(tint).frame(width: size, height: size) }.buttonStyle(.plain) }
}
struct StandbyEmptyState: View {
    let label: String
    let symbol: String
    let tint: Color
    var block = false
    var body: some View { Label(label, systemImage: symbol).foregroundStyle(tint).padding() }
}
'''
source += (root / 'Sources/ClaudeBar/Views/Shared/DocumentInlineEditor.swift').read_text()
source += (root / 'Sources/ClaudeBar/Views/Shared/DocumentTableView.swift').read_text()
source += (root / 'Sources/ClaudeBar/Views/Shared/SkillMarkdownPreview.swift').read_text()
source += r'''
@main struct DocumentPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let sample = """
        # 动态数据与工具协作
        本文说明 **动态场景**、`biz_tool_code` 与返回数据之间的关系。正文保持舒适行宽，长表格单独滚动。
        <callout emoji="💡" background-color="light-yellow" border-color="yellow"><p>先确认场景，再选择工具。</p><ul><li>异步任务请保留任务标识</li><li>颜色和提及按飞书块渲染</li></ul></callout>
        <p align="left">联系 <cite type="user" user-id="ou_demo"/>，关注 <span text-color="red" background-color="light-yellow">返回码</span> 与公式 <latex>E=mc^2</latex>。</p>
        <grid><column width-ratio="0.58"><p><strong>左栏</strong></p><p>创建、生成、整理文件，并保留任务标识。</p></column><column width-ratio="0.42"><checkbox done="true">保存知识库</checkbox><checkbox done="false">验证视频生成</checkbox></column></grid>
        ## 场景与能力
        - 创建、生成、整理文件
          - 生成相簿：`generateAlbum`
          - 生成回忆故事：`generateMemoryStory`
        - [x] 保存知识库
        - [ ] 验证视频生成
        ### 数据契约
        <table><tr><th>动态场景</th><th>MClaw 卡片化示例</th><th>biz_tool_code</th><th>支持状态</th></tr><tr><td>整理文件（异步）</td><td><pre lang="json"><code>{"taskId":"demo",<br/> "meta":{"biz_tool_code":"organizeFiles"}}</code></pre></td><td><code>organizeFiles</code></td><td>支持任务回调</td></tr><tr><td>生成相簿</td><td><strong>相片列表</strong><br/>展示结构化结果</td><td><code>generateAlbum</code></td><td>支持</td></tr></table>
        #### 验证步骤
        1. 确认请求参数
        2. 检查返回类型
        > 修改先保留在草稿，保存后同步到飞书。
        ##### 边界条件
        使用空列表、长文本与多语言数据验证。
        ###### 补充说明
        <whiteboard title="流程白板"></whiteboard>
        """
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            for width in [1200, 760] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1280), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: SkillMarkdownPreview(content: sample, documentNavigation: true, onEdit: { _ in })
                    .foregroundStyle(Theme.textPrimary).background(Theme.cardSurface))
                window.contentView = host
                // Native layout and .task run, without activating a window or reading TCC.
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = rep.representation(using: .png, properties: [:])!
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("document-\(width)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
    }
}
'''
probe = out / 'Probe.swift'
probe.write_text(source)
subprocess.run(['swiftc', '-O', '-parse-as-library', str(probe), '-o', str(out / 'preview')], check=True)
subprocess.run([str(out / 'preview'), str(out)], check=True, timeout=20)
print(out)
