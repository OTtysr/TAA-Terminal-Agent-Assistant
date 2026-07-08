import SwiftUI

/// 终端选项卡栏 — 位于 TerminalPaneView 顶部、终端视图之上的水平标签栏。
///
/// 类似浏览器标签页的行为，展示 `AppState.openSessionIDs` 中所有已打开的会话。
/// 每个标签显示：
/// - **状态圆点**：运行中 = 实心（fill），已关闭 = 空心（stroke），颜色使用 Agent 主题色。
/// - **标题**：会话标题（单行）。
/// - **关闭按钮**（×）：点击关闭标签（当前会话仅从标签栏移除，不终止进程）。
///
/// 交互方式：
/// - **点击标签**：调用 `appState.selectSession(id)` 切换到该会话。
/// - **点击 ×**：调用 `appState.closeTab(id)` 关闭标签（不杀进程）。
/// - **右键菜单**：
///   - "Open in New Window"：在独立窗口中打开该会话（调 `openWindow(id: "session")`）。
///   - "Close Tab"：关闭标签。
///   - "End Process"：终止 Agent 进程（调 `appState.endSession(id)`）。
///
/// 关联文件：
/// - `TerminalPaneView.swift`：嵌入本视图作为顶栏。
/// - `SessionWindowView.swift`："Open in New Window" 打开的目标窗口。
/// - `AppState.swift`：`openSessionIDs`、`selectSession()`、`closeTab()`、`endSession()`。
/// - `ContentView.swift`：在 `.task` 中注入 `openWindowAction` 到 AppState。
struct TerminalTabBar: View {
    /// 全局应用状态（@EnvironmentObject 由 ContentView 注入）。
    @EnvironmentObject var appState: AppState
    /// SwiftUI 环境提供的打开新窗口能力。
    /// 用于右键菜单 "Open in New Window"：调用 `openWindow(id: "session", value: session.id)`。
    @Environment(\.openWindow) private var openWindow

    private var theme: TerminalTheme.Style {
        TerminalTheme.style(for: appState.terminalThemeMode)
    }

    var body: some View {
        // ---- 水平滚动标签栏 ----
        // 当标签数量超出可见区域时水平滚动，不换行。
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { // 标签之间间隔 6pt
                // 遍历所有已打开会话的 ID（保持打开顺序）
                ForEach(appState.openSessionIDs, id: \.self) { id in
                    // 查找对应的 Session 对象（防御性：ID 可能指向已删除的会话）
                    if let session = appState.sessions.first(where: { $0.id == id }) {
                        tabButton(for: session)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(height: 42)  // 固定标签栏高度 42pt
        .background(Color(nsColor: theme.elevatedBackground))
    }

    /// 构建单个标签按钮（含状态圆点、标题、关闭按钮和右键菜单）。
    ///
    /// - Parameter session: 该标签对应的会话。
    /// - Returns: 完整的标签视图。
    private func tabButton(for session: Session) -> some View {
        // 当前标签是否选中（用于高亮背景）
        let isSelected = appState.selectedSessionID == session.id
        // 该会话所属 Agent 的主题色（找不到时回退到次要色）
        let agentColor = appState.agents.first { $0.id == session.agentId }?.color.swiftUIColor ?? .secondary

        return HStack(spacing: 6) {
            // ---- 状态圆点 ----
            Group {
                if session.status == .running {
                    // 运行中：实心圆，Agent 主题色
                    Circle().fill(agentColor)
                } else {
                    // 已关闭：空心圆环，Agent 主题色描边（1.5pt 线宽）
                    Circle().stroke(agentColor, lineWidth: 1.5)
                }
            }
            .frame(width: 7, height: 7) // 7pt 小圆点

            // ---- 标题文本 ----
            Text(session.title)
                .font(.system(.caption, design: .rounded).weight(isSelected ? .semibold : .regular))
                .lineLimit(1)       // 单行，超出省略
                .foregroundStyle(Color(nsColor: isSelected ? theme.foreground : theme.mutedForeground))

            // ---- 关闭按钮（×） ----
            Button {
                appState.closeTab(session.id) // 仅关闭标签，不终止进程
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: theme.mutedForeground))
            }
            .buttonStyle(.plain)                               // 无边框按钮
            .opacity(isSelected ? 1 : 0.5)                    // 非选中标签的 × 半透明
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // ---- 选中背景 ----
        .background(
            isSelected
                ? Color(nsColor: theme.selectedTabBackground)
                : Color(nsColor: theme.elevatedBackground).opacity(0.78),
            in: RoundedRectangle(cornerRadius: 7) // 圆角矩形背景
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: isSelected ? theme.selectedTabBorder : theme.tabBorder),
                        lineWidth: 1)
        )
        .contentShape(Rectangle()) // 整个区域可点击
        // ---- 点击选中 ----
        .onTapGesture { appState.selectSession(session.id) }
        // ---- 右键上下文菜单 ----
        .contextMenu {
            // 在新窗口中打开（仅运行中会话可用）
            Button(appState.text(.openInNewWindow)) {
                openWindow(id: "session", value: session.id)
            }
            .disabled(session.status != .running)

            Divider()

            // 关闭标签
            Button(appState.text(.closeTab)) { appState.closeTab(session.id) }

            // 终止进程（仅运行中会话可用）
            Button(appState.text(.endProcess), role: .destructive) {
                appState.endSession(session.id) // 杀死 Agent 子进程
            }
            .disabled(session.status != .running)
        }
    }
}
