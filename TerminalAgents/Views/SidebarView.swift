import SwiftUI

/// 侧边栏视图 — NavigationSplitView 的第一栏（左侧栏）。
///
/// 显示所有已配置的 Agent 列表（`AppState.agents`），选中后驱动整个应用的路由：
/// - `selectedAgentID` 更新 → `SessionListView` 切换到该 Agent 的会话列表。
///
/// 每行由 `AgentRow` 组件渲染，包含：
/// - 颜色圆点（Agent 主题色）
/// - 名称（粗体）
/// - 启动命令（等宽字体、单行截断）
///
/// 交互：
/// - **点击行**：选中 Agent（`selectedAgentID` 更新）。
/// - **右键菜单**：Edit（编辑 Agent）、Start New Session（直接启动新会话）、Delete（删除 Agent）。
/// - **工具栏 + 按钮**：新增 Agent（调用 `presentNewAgent()` 弹出编辑 Sheet）。
///
/// 关联文件：
/// - `AppState.swift`：`agents`、`selectedAgentID`、`presentNewAgent()`、`presentEditAgent()`。
/// - `AgentEditorSheet.swift`：通过 `newAgentRequest` / `editingAgent` 弹出的编辑表单。
/// - `ContentView.swift`：将本视图嵌入 NavigationSplitView 的 sidebar 栏。
/// - `AgentConfig.swift`：Agent 配置模型（name、commandString、color 等）。
struct SidebarView: View {
    /// 全局应用状态（@EnvironmentObject 由 ContentView 注入）。
    @EnvironmentObject var appState: AppState

    var body: some View {
        // ---- Agent 列表 ----
        // `selection: $appState.selectedAgentID` 双向绑定：
        // 用户点击/键盘导航选中 → selectedAgentID 更新 → SessionListView 和 TerminalPaneView 响应。
        List(selection: $appState.selectedAgentID) {
            ForEach(appState.agents) { agent in
                AgentRow(agent: agent)
                    // ---- 右键上下文菜单 ----
                    .contextMenu {
                        // 编辑：弹出 AgentEditorSheet，回填已有配置
                        Button(appState.text(.edit)) { appState.presentEditAgent(agent) }
                        // 直接为该 Agent 启动新会话
                        Button(appState.text(.startNewSession)) {
                            appState.selectedAgentID = agent.id
                            appState.startNewSession()
                        }
                        Divider()
                        // 删除：移除 Agent 及其所有关联会话
                        Button(appState.text(.delete), role: .destructive) { appState.deleteAgent(agent) }
                    }
            }
        }
        .navigationTitle(appState.text(.agents))
        // ---- 工具栏：添加按钮 ----
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    let visibleProviders = appState.providers.filter { ProviderTarget.primaryAgentTools.contains($0.target) }
                    if visibleProviders.isEmpty {
                        Button(appState.text(.manageProviders)) {
                            appState.presentProviderManager()
                        }
                    } else {
                        if !appState.recentlyActivatedProviders.isEmpty {
                            Section(appState.text(.lastActivated)) {
                                ForEach(appState.recentlyActivatedProviders.prefix(3)) { provider in
                                    ProviderSwitchButton(provider: provider)
                                }
                            }
                        }
                        Section(appState.text(.providers)) {
                            ForEach(visibleProviders) { provider in
                                ProviderSwitchButton(provider: provider)
                            }
                        }
                        Divider()
                        Button(appState.text(.manageProviders)) {
                            appState.presentProviderManager()
                        }
                    }
                } label: {
                    Label(appState.text(.quickSwitchProvider), systemImage: "switch.2")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // 弹出空表单（新增模式）
                    appState.presentNewAgent()
                } label: {
                    Label(appState.text(.newAgent), systemImage: "plus")
                }
            }
        }
        // ---- 空状态占位 ----
        .overlay {
            if appState.agents.isEmpty {
                ContentUnavailableView(appState.text(.noAgents),
                    systemImage: "terminal",
                    description: Text(appState.text(.noAgentsDescription)))
            }
        }
    }
}

private struct ProviderSwitchButton: View {
    let provider: ProviderProfile
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            appState.activateProvider(provider)
        } label: {
            Label(provider.name, systemImage: appState.activeProviderIDs.contains(provider.id) ? "checkmark.circle" : "circle")
        }
    }
}

// MARK: - Agent 行组件

/// 单个 Agent 的列表行视图。
///
/// 视觉结构：
/// ```
/// [●] Agent Name
///     launch-command --arg1 --arg2
/// ```
/// - 左侧圆形色块：Agent 主题色（11pt 直径）。
/// - 上排：Agent 名称（粗体、headline 字号）。
/// - 下排：启动命令（等宽字体、caption 字号、单行截断中间省略）。
private struct AgentRow: View {
    /// 要渲染的 Agent 配置。
    let agent: AgentConfig

    var body: some View {
        HStack(spacing: 10) {
            // ---- 颜色圆点 ----
            // 将 AgentConfig.AgentColor 枚举转为 SwiftUI Color 并填充圆形。
            Circle()
                .fill(agent.color.swiftUIColor)
                .frame(width: 11, height: 11)

            // ---- 名称与命令文本 ----
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.headline)               // 名称（粗体）
                Text(agent.commandString)                       // 启动命令
                    .font(.system(.caption, design: .monospaced)) // 等宽小字
                    .foregroundStyle(.secondary)                 // 次要色（灰色）
                    .lineLimit(1)                                // 单行
                    .truncationMode(.middle)                     // 过长时中间截断
            }
        }
        .padding(.vertical, 4) // 行内上下留白，增大点击区域
    }
}
