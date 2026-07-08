import SwiftUI

/// 从 Agent 原生历史文件（如 Claude Code JSONL）渲染的干净对话视图。
///
/// 与 `TranscriptReadOnlyView`（试图从 PTY 字节重建）不同，此视图展示的是
/// Agent 自己保存的**结构化消息日志**——无转义、无乱码、排版正确。
///
/// 数据来源：`AgentHistoryParser` 解析 Agent 的 JSONL 历史文件（如 `~/.claude/history/*.jsonl`），
/// 产出 `[ConversationEntry]` 数组，每条记录包含角色（user/assistant/system）和消息文本。
///
/// 关联文件：
/// - `TerminalPaneView.swift`：决定何时显示本视图（替代 TranscriptReadOnlyView）。
/// - `TranscriptReadOnlyView.swift`：无结构历史的降级方案（PTY 字节重放）。
/// - `AgentHistoryParser`：负责从 JSONL 文件中解析出 `[ConversationEntry]`。
struct ConversationHistoryView: View {
    /// 结构化对话条目列表（按时间顺序排列）。
    let entries: [ConversationEntry]
    /// Agent 的主题色，用于标识助手消息的气泡颜色。
    let agentColor: Color

    var body: some View {
        // ---- 可滚动对话列表 ----
        ScrollView {
            // `LazyVStack` 延迟加载每行，性能优于 VStack（仅渲染可见区域内的行）。
            LazyVStack(alignment: .leading, spacing: 12) {
                // 遍历每条对话记录，渲染为聊天气泡。
                ForEach(entries) { entry in
                    MessageBubble(entry: entry, accent: agentColor)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor)) // 使用系统文本背景色（适配浅/深色模式）
    }
}

// MARK: - 消息气泡组件

/// 单条消息的气泡视图。
///
/// 布局规则：
/// - **用户消息**：右对齐，左角色头像在右侧显示。
/// - **助手/系统消息**：左对齐，右角色头像在左侧显示。
///
/// 角色头像：
/// - 用户："U"（系统强调色背景）。
/// - 助手："A"（Agent 主题色背景）。
/// - 系统："S"（Agent 主题色背景）。
private struct MessageBubble: View {
    /// 对话条目（含角色和消息内容）。
    let entry: ConversationEntry
    /// Agent 主题色，用于非用户消息的气泡和头像强调色。
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // ---- 非用户消息：头像在左 ----
            if !entry.isUser {
                // 助手 / system 消息：头像标识
                roleIndicator
            } else {
                // 用户消息：左侧留空，消息靠右
                Spacer(minLength: 60)
            }

            // ---- 消息文本气泡 ----
            VStack(alignment: entry.isUser ? .trailing : .leading, spacing: 4) {
                Text(entry.content)
                    .font(.system(.callout, design: .monospaced)) // 等宽字体，便于阅读代码
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(entry.isUser ? userBubbleBg : assistantBubbleBg)
                    .cornerRadius(10)                // 圆角气泡
                    .textSelection(.enabled)          // 允许用户选中文本复制
            }

            // ---- 用户消息：头像在右 ----
            if entry.isUser {
                roleIndicator
            } else {
                // 非用户消息：右侧留空
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - 子视图与计算属性

    /// 角色标识圆形图标。
    /// - 用户消息：系统强调色圆形 + "U" 字母。
    /// - 助手消息：Agent 主题色圆形 + "A" 字母。
    /// - 系统消息：Agent 主题色圆形 + "S" 字母。
    @ViewBuilder
    private var roleIndicator: some View {
        Circle()
            .fill(entry.isUser ? Color.accentColor : accent)    // 用户=系统蓝，助手=Agent色
            .frame(width: 28, height: 28)
            .overlay(
                Text(entry.isUser ? "U" : roleLetter)            // 角色首字母
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)                     // 白字
            )
    }

    /// 角色标识字母：助手="A"，系统="S"。
    private var roleLetter: String { entry.role == .assistant ? "A" : "S" }

    /// 用户消息气泡背景色（系统强调色的 12% 透明度）。
    private var userBubbleBg: Color { Color.accentColor.opacity(0.12) }
    /// 助手/系统消息气泡背景色（次要色的 8% 透明度）。
    private var assistantBubbleBg: Color { Color.secondary.opacity(0.08) }
}
