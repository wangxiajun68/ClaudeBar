import WidgetKit
import SwiftUI

@main
struct ClaudeBarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeBarWidget", provider: WidgetProvider()) { entry in
            WidgetEntryView(entry: entry)
                .widgetURL(URL(string: BuildChannel.urlScheme + "://"))
        }
        .configurationDisplayName(BuildChannel.appName)
        .description("Claude Code、Codex 与 Cursor 状态概览")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
