import Foundation

enum GatewayTaskKind: String, Sendable {
    case general, coding, debugging, reasoning, extraction, writing, vision
    var title: String {
        switch self {
        case .general: return "通用"
        case .coding: return "编码"
        case .debugging: return "排错"
        case .reasoning: return "规划／推理"
        case .extraction: return "提取／转换"
        case .writing: return "写作"
        case .vision: return "视觉"
        }
    }
}

/// A bounded local rule baseline, not a trained semantic classifier.
/// Decisions never retain the prompt or tool output.
struct GatewayTaskRouting: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case automatic, explicit, fallback
        var title: String {
            switch self { case .automatic: return "自动（规则）"; case .explicit: return "客户端指定"; case .fallback: return "保守兜底" }
        }
    }
    var kind: GatewayTaskKind
    var difficulty: GatewayTaskDifficulty
    var source: Source
    var reason: String
}

enum GatewayTaskRouter {
    static func analyze(messages: [[String: Any]], tools: Bool, images: Bool,
                        override: GatewayTaskDifficulty?) -> GatewayTaskRouting {
        // Short continuation messages and tool results must not erase the
        // user goal. System prompts, payload bytes and tool outputs are not
        // task instructions. Only bounded user text enters the rule matcher.
        var goal = ""
        var continued = messages.last?["role"] as? String == "tool"
        for message in messages.reversed() where message["role"] as? String == "user" {
            let text = userText(message)
            if text.isEmpty { continue }
            if isContinuation(text) { continued = true; continue }
            goal = text; break
        }
        let prefix = String(goal.prefix(600))
        let instruction = prefix.components(separatedBy: CharacterSet(charactersIn: ":：\n")).first ?? prefix
        let transform = isSimpleTransform(instruction) && !isComplex(instruction)
        let kind = taskKind(transform ? instruction : prefix, images: images)
        if let override {
            return .init(kind: kind, difficulty: override, source: .explicit, reason: "遵守 task_difficulty")
        }
        func result(_ difficulty: GatewayTaskDifficulty, _ reason: String,
                    source: GatewayTaskRouting.Source = .automatic) -> GatewayTaskRouting {
            .init(kind: kind, difficulty: difficulty, source: source,
                  reason: (continued ? "沿用会话任务 · " : "") + reason)
        }
        guard !goal.isEmpty else {
            return result(.medium, tools ? "工具续轮缺少用户目标" : "任务信息不足", source: .fallback)
        }
        // A constrained transform can have lengthy, difficult source data.
        // Inspect its instruction before common payload delimiters.
        if !tools && transform {
            return result(.low, "明确的提取、翻译或格式转换")
        }
        if isComplex(prefix) { return result(.high, "复杂排错、系统设计或多步推理") }
        if tools { return result(.medium, "需要工具执行，保留执行能力") }
        if images { return result(.medium, "需要视觉理解") }
        if matches(prefix, #"^(?:hello|hi|hey|ping|thanks|thank you|你好|您好|谢谢)[!！。.\s]*$"#) {
            return result(.low, "简单问候或连接检查")
        }
        if kind != .general { return result(.medium, "常规\(kind.title)任务") }
        return result(.medium, "无法明确判断任务难度", source: .fallback)
    }

    private static func userText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return String(text.prefix(1600)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let parts = message["content"] as? [[String: Any]] ?? []
        var text = ""
        for part in parts where part["type"] as? String == "text" {
            if let value = part["text"] as? String { text += String(value.prefix(max(0, 1600 - text.count))) }
            if text.count >= 1600 { break }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isContinuation(_ text: String) -> Bool {
        matches(text, #"^(?:继续(?:执行|完成|吧)?|接着(?:做|执行)?|下一步|continue(?: please)?|proceed|go on|carry on)[!！。.?？\s]*$"#)
    }

    private static func taskKind(_ text: String, images: Bool) -> GatewayTaskKind {
        if images { return .vision }
        if matches(text, #"排查|排错|修复|调试|故障|死锁|竞态|\b(?:debug|bug|fix|deadlock|race condition|diagnose)\b"#) { return .debugging }
        if matches(text, #"证明|推导|规划|架构|设计方案|分析方案|\b(?:prove|proof|derive|reasoning|architecture|design|plan)\b"#) { return .reasoning }
        if isTransform(text) { return .extraction }
        if matches(text, #"代码|编程|函数|实现|重构|测试|\b(?:code|coding|implement|refactor|function|test)\b"#) { return .coding }
        if matches(text, #"写作|撰写|文案|润色|邮件|文章|\b(?:write|writing|rewrite|email|essay)\b"#) { return .writing }
        return .general
    }

    private static func isTransform(_ text: String) -> Bool {
        matches(text, #"提取|翻译|转成|转换为|格式化|分类|摘要|总结(?:以下|这段|下面)|\b(?:extract|translate|format|classify|summarize|convert)\b"#)
    }

    private static func isSimpleTransform(_ text: String) -> Bool {
        matches(text, #"^(?:请|帮我|请帮我)?(?:提取|翻译|格式化|分类|摘要|总结(?:以下|这段|下面))|^(?:请|帮我)?(?:把|将).{0,60}(?:转换为|转成|格式化)|^(?:please\s+)?(?:extract|translate|format|classify|summarize|convert)\b"#)
    }

    private static func isComplex(_ text: String) -> Bool {
        matches(text, #"死锁|竞态|并发(?:故障|错误|问题)|分布式|根因|跨(?:文件|模块|服务)|系统(?:架构|设计)|架构设计|迁移方案|证明|推导|多步(?:推理|规划)|\b(?:deadlock|race condition|distributed|root cause|system design|prove|proof|multi[- ]step|cross[- ](?:module|service|file))\b"#)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
