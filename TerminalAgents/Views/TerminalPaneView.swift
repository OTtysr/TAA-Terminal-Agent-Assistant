import SwiftUI

/// 终端面板视图 — NavigationSplitView 的第三栏（详情栏）。
///
/// 这是应用最复杂的路由组件，根据会话状态分发到不同的子视图：
///
/// ```
/// TerminalPaneView
/// ├── TerminalTabBar          ← 固定顶栏（打开会话的选项卡）
/// ├── Divider
/// └── content (路由分发)
///     ├── [活跃/已退出但标签保留] → TerminalViewRepresentable  ← 共享终端 NSView（PTY 实时交互）
///     ├── [已关闭 + 支持恢复]    → ResumePromptView          ← 恢复按钮（调 resumeSession）
///     ├── [已关闭 + 不支持恢复] → TranscriptReadOnlyView     ← 兜底：PTY 字节重放
///     └── [无选中会话]          → EmptyTerminalPane          ← 空状态占位
/// ```
///
/// 关联文件：
/// - `TerminalTabBar.swift`：顶层选项卡栏，展示 `openSessionIDs` 中的会话。
/// - `TerminalViewRepresentable`：NSViewRepresentable 桥接 SwiftTerm 终端的实时视图。
/// - `TranscriptReadOnlyView.swift`：无头终端重放 transcript 为只读文本。
/// - `AppState.swift`：`selectedSessionID`、`openSessionIDs`、`resumeSession()` 等。
/// - `AgentConfig.swift`：`historyFormat`、`HistoryFormat.supportsResume()` 等恢复逻辑。
struct TerminalPaneView: View {
    /// 全局应用状态（@EnvironmentObject 由 ContentView 注入）。
    @EnvironmentObject var appState: AppState
    private var theme: TerminalTheme.Style {
        TerminalTheme.style(for: appState.terminalThemeMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ---- 选项卡栏（固定顶部） ----
            TerminalTabBar()

            // ---- 分割线 ----
            Rectangle()
                .fill(Color(nsColor: theme.tabBorder))
                .frame(height: 1)

            // ---- 内容区域（根据会话状态路由） ----
            content
        }
        .background(Color(nsColor: theme.background)) // 统一终端背景色
    }

    /// 内容路由：根据当前选中的会话和其状态决定显示哪个子视图。
    ///
    /// 路由优先级：
    /// 1. **活跃会话或已退出但仍在标签中**：只要有终端 NSView 就展示实时交互视图。
    ///    - 条件：`selectedSessionID` 在 `openSessionIDs` 中且 `terminalManager.view(for:) != nil`。
    ///    - 视图：`TerminalViewRepresentable`（复用 TerminalManager 的共享 NSView）。
    ///
    /// 2. **已关闭但支持恢复**：Agent 支持原生历史格式时的恢复提示。
    ///    - 条件：`selectedSession` 存在，对应 Agent 的 `historyFormat != .none`，且 `supportsResume()` 返回 true。
    ///    - 视图：`ResumePromptView`（展示恢复按钮和命令预览）。
    ///
    /// 3. **已关闭且不支持恢复**：兜底的只读 transcript 重放。
    ///    - 视图：`TranscriptReadOnlyView`（无头 SwiftTerm 重放 + 正则降级清洗）。
    ///
    /// 4. **无选中会话**：空状态占位。
    ///    - 视图：`EmptyTerminalPane`（提示用户选择 Agent 并启动会话）。
    @ViewBuilder
    private var content: some View {
        if let id = appState.selectedSessionID,
           appState.openSessionIDs.contains(id),
           appState.terminalManager.view(for: id) != nil {
            // 活跃或已退出但仍在标签里的会话：展示共享的终端 NSView
            TerminalViewRepresentable(sessionID: id, appState: appState)
        } else if let session = appState.selectedSession {
            // 已关闭会话：支持恢复的 Agent 走 ResumePromptView；否则回退 PTY 重放
            if let agent = appState.agents.first(where: { $0.id == session.agentId }),
               agent.historyFormat != .none,
               HistoryFormat.supportsResume(agent) {
                // 支持原生历史恢复的 Agent：显示恢复按钮
                ResumePromptView(session: session, agent: agent)
            } else {
                // 兜底：PTY 字节重放（无头终端模拟 + 正则清洗）
                TranscriptReadOnlyView(ref: session.transcriptRef)
            }
        } else {
            // 无选中会话：空状态提示
            EmptyTerminalPane()
        }
    }
}

// MARK: - 恢复提示视图

/// 已关闭会话的恢复提示：点击"恢复对话"即重新启动 Agent 并加精确恢复参数，
/// 让 Agent 自己把历史对话实时拉到 TUI 里（最可靠的方式，绕开 PTY 字节解析）。
///
/// 显示内容：
/// - 会话标题与提示文字
/// - Agent 启动命令预览（含恢复参数）
/// - "Resume Conversation" 按钮
///
/// 恢复参数逻辑：
/// - 优先按时间戳匹配历史文件中的 session-id → 用 `--resume <id>`（更精确）
/// - 仅对允许安全兜底的 Agent 使用 `--continue` / `--resume-latest`
private struct ResumePromptView: View {
    /// 已关闭的会话。
    let session: Session
    /// 对应的 Agent 配置（用于获取命令字符串和历史格式）。
    let agent: AgentConfig
    /// 全局应用状态（用于调用 `resumeSession()`）。
    @EnvironmentObject var appState: AppState

    /// 解析后的历史格式（auto → 实际检测到的格式）。
    private var resolvedFormat: HistoryFormat {
        agent.historyFormat == .auto
            ? HistoryFormat.detect(from: agent.commandString) : agent.historyFormat
    }

    /// 显示给用户的恢复参数（优先 --resume <id>，安全时才显示 --continue）。
    ///
    /// 流程：
    /// 1. 获取 Agent 支持的具体恢复标志（如 claudeCode 的 `--resume`）。
    /// 2. 优先使用已保存的 `agentSessionId`，返回 "`标志` `session-id`"。
    /// 3. 若锚点缺失，再尝试按会话创建时间戳匹配历史文件中的 session-id。
    /// 4. 若匹配失败，仅对允许安全兜底的 Agent 返回 `--continue`。
    private var resumeDisplayArg: String? {
        let fmt = resolvedFormat
        // 优先使用已保存的 Agent 原生 session-id，保证显示与实际恢复命令一致。
        if let byId = fmt.resumeByIdFlag,
           let sid = session.agentSessionId,
           !isAmbiguousNativeSessionId(sid, format: fmt) {
            return "\(byId) \(sid)"
        }
        // 锚点缺失时再尝试按时间戳匹配 session-id
        if let byId = fmt.resumeByIdFlag,
           let sid = AgentHistoryParser.matchSessionID(
               for: session.createdAt,
               format: fmt,
               globOverride: agent.historyGlob,
               excluding: nativeSessionIds(excluding: session.id)),
           !isAmbiguousNativeSessionId(sid, format: fmt) {
            return "\(byId) \(sid)"
        }
        // KimiCode / OpenCode 的 --continue 会恢复同工作目录最近会话，多会话下会串台。
        return fmt.allowsLatestResumeFallback ? fmt.resumeLatestFlag : nil
    }

    private func isAmbiguousNativeSessionId(_ sid: String, format: HistoryFormat) -> Bool {
        guard format == .kimiCode || format == .openCode else { return false }
        return appState.sessions.contains {
            $0.id != session.id &&
            $0.agentId == session.agentId &&
            $0.agentSessionId == sid
        }
    }

    private func nativeSessionIds(excluding sessionID: Session.ID) -> Set<String> {
        Set(appState.sessions.compactMap {
            guard $0.id != sessionID, $0.agentId == session.agentId else { return nil }
            return $0.agentSessionId
        })
    }

    var body: some View {
        VStack(spacing: 16) {
            // ---- 图标 ----
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            // ---- 标题与说明文字 ----
            VStack(spacing: 6) {
                Text(session.title).font(.title3.bold())
                Text(appState.text(.sessionEnded))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // ---- 恢复按钮与命令预览 ----
            if let arg = resumeDisplayArg {
                // 恢复按钮：调用 AppState.resumeSession
                Button {
                    // deleteOld: 删除当前已关闭的会话，创建新会话
                    // selectFirst: 自动切换选中到新创建的恢复会话
                    appState.resumeSession(session, deleteOld: true, selectFirst: true)
                } label: {
                    Label(appState.text(.resumeConversation), systemImage: "play.fill")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent) // 强调按钮
                .controlSize(.large)              // 大号控件

                // 完整命令预览：agentCommand + 恢复参数
                Text("\(appState.text(.runs)): \(agent.commandString) \(arg)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                // 无恢复参数可用：该 Agent 不支持自动恢复
                Text(appState.text(.doesNotSupportResume))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // 居中填满整个内容区域
        .padding(40)
    }
}

// MARK: - 空终端面板

/// 终端面板的空状态占位视图。
/// 当用户尚未选中任何会话时显示，引导用户选择 Agent 并启动新会话。
private struct EmptyTerminalPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ContentUnavailableView(appState.text(.noActiveSession),
            systemImage: "terminal",
            description: Text(appState.text(.noActiveSessionDescription)))
    }
}
