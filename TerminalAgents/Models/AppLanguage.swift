import Foundation

/// 应用界面语言偏好。
///
/// 先提供英文与中文两种显示；后续新增语言只需要扩展 `text(_:)` 的 switch。
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case english
    case chinese

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    func text(_ key: AppText) -> String {
        switch (self, key) {
        case (.english, .newSession): return "New Session"
        case (.english, .newAgent): return "New Agent"
        case (.english, .newAgentEllipsis): return "New Agent..."
        case (.english, .editAgent): return "Edit Agent"
        case (.english, .openInNewWindow): return "Open in New Window"
        case (.english, .language): return "Language"
        case (.english, .switchToChinese): return "Switch to Chinese"
        case (.english, .switchToEnglish): return "Switch to English"
        case (.english, .agents): return "Agents"
        case (.english, .sessions): return "Sessions"
        case (.english, .edit): return "Edit"
        case (.english, .startNewSession): return "Start New Session"
        case (.english, .delete): return "Delete"
        case (.english, .noAgents): return "No Agents"
        case (.english, .noAgentsDescription): return "Click + to add an Agent launch command."
        case (.english, .clearAll): return "Clear All"
        case (.english, .clearAllTitle): return "Clear all session history?"
        case (.english, .clear): return "Clear"
        case (.english, .cancel): return "Cancel"
        case (.english, .clearAllMessage): return "This will delete all sessions and terminal recordings for the current Agent. This action cannot be undone."
        case (.english, .selectAgent): return "Select an Agent"
        case (.english, .selectAgentDescription): return "Pick an Agent from the sidebar."
        case (.english, .noSessions): return "No Sessions"
        case (.english, .noSessionsDescription): return "Click play to start this Agent in a terminal."
        case (.english, .closeTab): return "Close Tab"
        case (.english, .endProcess): return "End Process"
        case (.english, .sessionUnavailable): return "Session Unavailable"
        case (.english, .session): return "Session"
        case (.english, .name): return "Name"
        case (.english, .launchCommand): return "Launch Command"
        case (.english, .launchCommandHelp): return "Run as a login shell: /bin/zsh -lic \"<command>\". Supports pipes, args, env."
        case (.english, .color): return "Color"
        case (.english, .conversationHistory): return "Conversation History"
        case (.english, .format): return "Format"
        case (.english, .detected): return "detected"
        case (.english, .historyPathGlob): return "History path glob"
        case (.english, .historyGlobHelp): return "Glob pattern for native history files, e.g. ~/.claude/projects/**/*.jsonl"
        case (.english, .add): return "Add"
        case (.english, .save): return "Save"
        case (.english, .sessionEnded): return "Session ended. Resume Claude Code to view the conversation."
        case (.english, .resumeConversation): return "Resume Conversation"
        case (.english, .runs): return "Runs"
        case (.english, .doesNotSupportResume): return "This Agent does not support auto-resume."
        case (.english, .noActiveSession): return "No Active Session"
        case (.english, .noActiveSessionDescription): return "Select an Agent and start a session, or pick a session from the list."
        case (.english, .noTranscript): return "No Transcript"
        case (.english, .noTranscriptDescription): return "This session has no recorded output."
        case (.english, .terminalTheme): return "Terminal Theme"
        case (.english, .terminalThemeLight): return "Light Terminal"
        case (.english, .terminalThemeDark): return "Dark Terminal"
        case (.english, .providers): return "Providers"
        case (.english, .manageProviders): return "Manage Providers"
        case (.english, .providerPresets): return "Provider Presets"
        case (.english, .addProvider): return "Add Provider"
        case (.english, .activateProvider): return "Activate Provider"
        case (.english, .providerApplied): return "Provider applied. Updated files:"
        case (.english, .providerApplyFailed): return "Provider apply failed"
        case (.english, .quickSwitchProvider): return "Quick Switch Provider"
        case (.english, .importProviders): return "Import Providers..."
        case (.english, .exportProviders): return "Export Providers..."
        case (.english, .providerImported): return "Providers imported"
        case (.english, .lastActivated): return "Last activated"
        case (.english, .mainAgents): return "Main Agents"
        case (.english, .modelsEndpoint): return "Models Endpoint"
        case (.english, .modelMapping): return "Model Mapping"
        case (.english, .fetchModels): return "Fetch Models"
        case (.english, .autoMapModels): return "Auto Map"
        case (.english, .noModelsDetected): return "No models detected"
        case (.english, .modelsDetected): return "models detected"
        case (.english, .modelsFetched): return "Models fetched and mapped."
        case (.english, .configPath): return "Config path"
        case (.english, .envPath): return "Env path"
        case (.english, .baseURL): return "Base URL"
        case (.english, .apiKey): return "API Key"
        case (.english, .primaryModel): return "Primary Model"
        case (.english, .smallModel): return "Small Model"
        case (.english, .largeModel): return "Large Model"
        case (.english, .targetTool): return "Target Tool"
        case (.english, .reasoningEffort): return "Reasoning Effort"
        case (.english, .openCodePackage): return "OpenCode Package"
        case (.english, .providerHelp): return "Activating a provider backs up and updates the matching CLI config files."

        case (.chinese, .newSession): return "新建会话"
        case (.chinese, .newAgent): return "新建 Agent"
        case (.chinese, .newAgentEllipsis): return "新建 Agent..."
        case (.chinese, .editAgent): return "编辑 Agent"
        case (.chinese, .openInNewWindow): return "在新窗口打开"
        case (.chinese, .language): return "语言"
        case (.chinese, .switchToChinese): return "切换到中文"
        case (.chinese, .switchToEnglish): return "切换到英文"
        case (.chinese, .agents): return "Agent"
        case (.chinese, .sessions): return "会话"
        case (.chinese, .edit): return "编辑"
        case (.chinese, .startNewSession): return "启动新会话"
        case (.chinese, .delete): return "删除"
        case (.chinese, .noAgents): return "还没有 Agent"
        case (.chinese, .noAgentsDescription): return "点击 + 添加一个 Agent 启动命令。"
        case (.chinese, .clearAll): return "清空全部"
        case (.chinese, .clearAllTitle): return "清空全部历史会话？"
        case (.chinese, .clear): return "清空"
        case (.chinese, .cancel): return "取消"
        case (.chinese, .clearAllMessage): return "将删除当前 Agent 的所有历史会话及其终端记录，此操作不可撤销。"
        case (.chinese, .selectAgent): return "选择一个 Agent"
        case (.chinese, .selectAgentDescription): return "请从侧边栏选择一个 Agent。"
        case (.chinese, .noSessions): return "还没有会话"
        case (.chinese, .noSessionsDescription): return "点击播放按钮，在终端里启动这个 Agent。"
        case (.chinese, .closeTab): return "关闭标签"
        case (.chinese, .endProcess): return "结束进程"
        case (.chinese, .sessionUnavailable): return "会话不可用"
        case (.chinese, .session): return "会话"
        case (.chinese, .name): return "名称"
        case (.chinese, .launchCommand): return "启动命令"
        case (.chinese, .launchCommandHelp): return "以登录交互 shell 运行：/bin/zsh -lic \"<command>\"。支持管道、参数和环境变量。"
        case (.chinese, .color): return "颜色"
        case (.chinese, .conversationHistory): return "对话历史"
        case (.chinese, .format): return "格式"
        case (.chinese, .detected): return "检测到"
        case (.chinese, .historyPathGlob): return "历史路径 glob"
        case (.chinese, .historyGlobHelp): return "Agent 原生历史文件的 glob 路径，例如 ~/.claude/projects/**/*.jsonl"
        case (.chinese, .add): return "添加"
        case (.chinese, .save): return "保存"
        case (.chinese, .sessionEnded): return "会话已结束。恢复 Claude Code 后可查看这段对话。"
        case (.chinese, .resumeConversation): return "恢复对话"
        case (.chinese, .runs): return "运行"
        case (.chinese, .doesNotSupportResume): return "这个 Agent 不支持自动恢复。"
        case (.chinese, .noActiveSession): return "没有活跃会话"
        case (.chinese, .noActiveSessionDescription): return "选择一个 Agent 并启动会话，或从会话列表中选择一条记录。"
        case (.chinese, .noTranscript): return "没有终端记录"
        case (.chinese, .noTranscriptDescription): return "这个会话没有录制到输出。"
        case (.chinese, .terminalTheme): return "终端主题"
        case (.chinese, .terminalThemeLight): return "亮色终端"
        case (.chinese, .terminalThemeDark): return "暗色终端"
        case (.chinese, .providers): return "Provider"
        case (.chinese, .manageProviders): return "管理 Provider"
        case (.chinese, .providerPresets): return "Provider 预设"
        case (.chinese, .addProvider): return "添加 Provider"
        case (.chinese, .activateProvider): return "启用 Provider"
        case (.chinese, .providerApplied): return "Provider 已启用，已更新文件："
        case (.chinese, .providerApplyFailed): return "Provider 启用失败"
        case (.chinese, .quickSwitchProvider): return "快速切换 Provider"
        case (.chinese, .importProviders): return "导入 Provider..."
        case (.chinese, .exportProviders): return "导出 Provider..."
        case (.chinese, .providerImported): return "已导入 Provider"
        case (.chinese, .lastActivated): return "最近启用"
        case (.chinese, .mainAgents): return "主流 Agent"
        case (.chinese, .modelsEndpoint): return "模型端点"
        case (.chinese, .modelMapping): return "模型映射"
        case (.chinese, .fetchModels): return "获取模型"
        case (.chinese, .autoMapModels): return "自动映射"
        case (.chinese, .noModelsDetected): return "未识别模型"
        case (.chinese, .modelsDetected): return "个模型"
        case (.chinese, .modelsFetched): return "已获取模型并完成映射。"
        case (.chinese, .configPath): return "配置路径"
        case (.chinese, .envPath): return "环境文件"
        case (.chinese, .baseURL): return "Base URL"
        case (.chinese, .apiKey): return "API Key"
        case (.chinese, .primaryModel): return "主模型"
        case (.chinese, .smallModel): return "小模型"
        case (.chinese, .largeModel): return "大模型"
        case (.chinese, .targetTool): return "目标工具"
        case (.chinese, .reasoningEffort): return "推理强度"
        case (.chinese, .openCodePackage): return "OpenCode 包"
        case (.chinese, .providerHelp): return "启用 Provider 时会先备份，再更新对应 CLI 的配置文件。"
        }
    }
}

enum AppText {
    case newSession
    case newAgent
    case newAgentEllipsis
    case editAgent
    case openInNewWindow
    case language
    case switchToChinese
    case switchToEnglish
    case agents
    case sessions
    case edit
    case startNewSession
    case delete
    case noAgents
    case noAgentsDescription
    case clearAll
    case clearAllTitle
    case clear
    case cancel
    case clearAllMessage
    case selectAgent
    case selectAgentDescription
    case noSessions
    case noSessionsDescription
    case closeTab
    case endProcess
    case sessionUnavailable
    case session
    case name
    case launchCommand
    case launchCommandHelp
    case color
    case conversationHistory
    case format
    case detected
    case historyPathGlob
    case historyGlobHelp
    case add
    case save
    case sessionEnded
    case resumeConversation
    case runs
    case doesNotSupportResume
    case noActiveSession
    case noActiveSessionDescription
    case noTranscript
    case noTranscriptDescription
    case terminalTheme
    case terminalThemeLight
    case terminalThemeDark
    case providers
    case manageProviders
    case providerPresets
    case addProvider
    case activateProvider
    case providerApplied
    case providerApplyFailed
    case quickSwitchProvider
    case importProviders
    case exportProviders
    case providerImported
    case lastActivated
    case mainAgents
    case modelsEndpoint
    case modelMapping
    case fetchModels
    case autoMapModels
    case noModelsDetected
    case modelsDetected
    case modelsFetched
    case configPath
    case envPath
    case baseURL
    case apiKey
    case primaryModel
    case smallModel
    case largeModel
    case targetTool
    case reasoningEffort
    case openCodePackage
    case providerHelp
}
