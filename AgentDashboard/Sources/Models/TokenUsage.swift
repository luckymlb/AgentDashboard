import Foundation

/// 单个 Claude 会话的累计 token 用量(来自 transcript 中所有 assistant 消息的 message.usage 累加)。
/// 值类型 + 全 let 成员,天然 Sendable,可跨 actor 传递。
struct TokenUsage: Sendable, Equatable {
    let inputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    /// 最近遇到的模型名(用于判断是否 Claude 原生 → 是否显示 cache_creation 行)。
    let model: String?

    var total: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
    }

    /// 是否 Claude 原生模型 —— 仅其 cache_creation 字段才有意义,第三方模型(glm/deepseek 等)恒 0。
    var isClaudeNative: Bool {
        model?.lowercased().hasPrefix("claude") ?? false
    }

    static let zero = TokenUsage(inputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, outputTokens: 0, model: nil)

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            model: lhs.model ?? rhs.model
        )
    }
}

extension TokenUsage {
    /// 紧凑格式:<1k 原样;≥1k "22.7k";≥1M "1.2M";≥1B "1.2B"
    var formattedTotal: String {
        TokenUsage.format(total)
    }

    /// 千分位格式(分项卡片用):134,814
    var totalWithSeparator: String {
        TokenUsage.decimal(total)
    }

    static func format(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        } else {
            return "\(value)"
        }
    }

    static func decimal(_ value: Int) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}
