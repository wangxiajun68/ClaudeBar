import WidgetKit
import SwiftUI

@main
struct ClaudeBarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeBarWidget", provider: WidgetProvider()) { entry in
            WidgetEntryView(entry: entry)
                .widgetURL(URL(string: "claudebar://"))
        }
        .configurationDisplayName("Axon")
        .description("Claude Code 状态概览")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
