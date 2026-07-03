import SwiftUI

/// 被 hover 的 token 区域:usage + 位置锚点,供 MenuBarPopover 顶层浮层定位。
struct HoveredTokenInfo: Equatable {
    let usage: TokenUsage
    let anchor: Anchor<CGRect>
}

struct HoveredTokenPreferenceKey: PreferenceKey {
    static var defaultValue: HoveredTokenInfo? = nil
    static func reduce(value: inout HoveredTokenInfo?, nextValue: () -> HoveredTokenInfo?) {
        // 任一子视图报非 nil 即采用;全部回 nil 时清空(鼠标移开)。
        if let next = nextValue() { value = next }
    }
}

/// hover 行右侧 tok/时间区时浮出的 token 分项卡片。
/// 渲染在 MenuBarPopover 的顶层 overlayPreferenceValue 中(不在任何行内,不会被遮挡),
/// allowsHitTesting(false) → 不拦截点击,整行点击跳转不受影响。
struct TokenInfoCard: View {
    let usage: TokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Input", usage.inputTokens)
            if usage.isClaudeNative {
                row("Cache creation", usage.cacheCreationTokens)
            }
            row("Cache read", usage.cacheReadTokens)
            row("Output", usage.outputTokens)
            Divider()
            HStack {
                Text("Total")
                Spacer()
                Text(usage.totalWithSeparator).fontWeight(.semibold)
            }
        }
        .font(.caption)
        .padding(8)
        .frame(width: 170)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(TokenUsage.decimal(value)).monospacedDigit()
        }
    }
}
