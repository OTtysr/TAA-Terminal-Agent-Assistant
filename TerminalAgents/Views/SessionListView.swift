import SwiftUI

/// 会话列表视图 — NavigationSplitView 的第二栏（中间栏）。
///
/// 显示当前选中 Agent 的所有会话（运行中、已关闭、已恢复），由 `AppState.sessionsForSelectedAgent` 驱动。
/// 每行由一个 `SessionRow` 组件渲染，包含状态圆点和标题/时间信息。
///
/// 工具栏提供两个按钮：
/// - **New Session（▶）**：启动新的 Agent 会话（调用 `AppState.startNewSession()`）。
/// - **Clear All（🗑）**：弹出确认对话框后清空当前 Agent 所有历史会话（调用 `AppState.clearSessions()`）。
///
/// 空状态处理：
/// - 未选中 Agent → "Select an Agent" 提示。
/// - 选中 Agent 但无会话 → "No Sessions" 提示。
///
/// 关联文件：
/// - `AppState.swift`：`sessionsForSelectedAgent`、`startNewSession()`、`clearSessions()`。
/// - `Session.swift`：`Session` 模型（id、title、status、agentId、createdAt 等）。
/// - `ContentView.swift`：将本视图嵌入 NavigationSplitView 的 content 栏。
struct SessionListView: View {
    /// 全局应用状态（@EnvironmentObject 由 ContentView 注入）。
    @EnvironmentObject var appState: AppState
    /// 是否显示"清空全部"确认对话框（`.confirmationDialog` 的布尔绑定）。
    @State private var confirmClear = false

    var body: some View {
        // ---- 当前 Agent 的会话列表 ----
        let list = appState.sessionsForSelectedAgent
        // `selection: $appState.selectedSessionID` 实现双向绑定：
        // 用户点击行 → `selectedSessionID` 更新 → TerminalPaneView 切换到对应终端。
        List(selection: $appState.selectedSessionID) {
            ForEach(list) { session in
                SessionRow(session: session)
                    .tag(session.id) // 行的 tag 值等于 session.id，供 selection 匹配
            }
        }
        .navigationTitle(appState.selectedAgent?.name ?? appState.text(.sessions)) // 导航栏标题随 Agent 变化
        // ---- 工具栏按钮 ----
        .toolbar {
            // 主要操作：新建会话（▶ 播放图标）
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.startNewSession()
                } label: {
                    Label(appState.text(.newSession), systemImage: "play.fill")
                }
                .disabled(appState.selectedAgent == nil) // 未选中 Agent 时禁用
            }
            // 破坏性操作：清空所有会话（🗑 删除图标）
            ToolbarItem(placement: .destructiveAction) {
                Button {
                    confirmClear = true // 先弹确认对话框
                } label: {
                    Label(appState.text(.clearAll), systemImage: "trash")
                }
                .disabled(list.isEmpty) // 列表为空时禁用
            }
        }
        // ---- 清空确认对话框 ----
        // macOS 原生 .confirmationDialog：当 `confirmClear` 为 true 时弹出。
        .confirmationDialog(
            appState.text(.clearAllTitle),
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button(appState.text(.clear), role: .destructive) { appState.clearSessions() }
            Button(appState.text(.cancel), role: .cancel) {}
        } message: {
            Text(appState.text(.clearAllMessage))
        }
        // ---- 空状态占位 ----
        .overlay {
            if appState.selectedAgent == nil {
                // 未选中任何 Agent
                ContentUnavailableView(appState.text(.selectAgent),
                    systemImage: "sidebar.left",
                    description: Text(appState.text(.selectAgentDescription)))
            } else if list.isEmpty {
                // 已选中 Agent 但无会话
                ContentUnavailableView(appState.text(.noSessions),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(appState.text(.noSessionsDescription)))
            }
        }
    }
}

// MARK: - 会话行组件

/// 单行会话视图（List 每一行的呈现）。
///
/// 包含：
/// - **状态圆点**：运行中 = `circle.fill`（实心），已关闭 = `circle`（空心），颜色取自 Agent 主题色。
/// - **标题**：会话标题（取自 Agent 进程输出的首行或默认名称）。
/// - **相对时间**：会话创建时间的相对显示（如 "3 分钟前"）。
/// - **右键菜单**：删除该会话（调 `AppState.deleteSession(session)`）。
private struct SessionRow: View {
    /// 当前行对应的会话模型。
    let session: Session
    /// 全局应用状态（通过 EnvironmentObject 获取 agents 列表和 deleteSession 方法）。
    @EnvironmentObject var appState: AppState

    /// 该会话所属 Agent 的主题色；找不到时回退到次要色，保证有颜色。
    private var dotColor: Color {
        appState.agents.first { $0.id == session.agentId }?.color.swiftUIColor ?? .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            // ---- 状态圆点 ----
            Image(systemName: session.status == .running ? "circle.fill" : "circle")
                .foregroundStyle(dotColor)      // Agent 主题色
                .font(.system(size: 8))         // 小圆点（8pt）

            // ---- 标题与时间 ----
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.subheadline)
                // `.relative` 日期样式：自动显示 "3 分钟前" / "1 小时前" 等
                Text(session.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        // ---- 右键上下文菜单 ----
        .contextMenu {
            Button(role: .destructive) {
                appState.deleteSession(session)
            } label: {
                Label(appState.text(.delete), systemImage: "trash")
            }
        }
    }
}
