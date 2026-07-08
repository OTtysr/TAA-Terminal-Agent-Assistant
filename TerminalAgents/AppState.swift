import Foundation
import SwiftUI

/// 全局应用状态中心 — 整个应用的状态单例总控。
///
/// 为什么是 `ObservableObject` 而非 `@Observable`（iOS 17+）？
/// —— TerminalAgents 作为 macOS App，底层 SwiftTerm 需要 Objective-C 互操作（NSViewRepresentable、
/// GCD/NSProcess 等）。`@Observable` 宏目前对 @objc 导出的兼容有限，且 macOS 旧版本回退复杂，
/// 变更 ObservableObject → @Observable 会连锁影响 TerminalManager 的 ObjC 委托模式。
///
/// 为什么 vendored SwiftTerm？
/// —— 上游 SwiftTerm SDK 在 macOS 上不支持终端颜色 ANSI 转义的完整解析，且 TUI 光标定位
/// 行为与标准 xterm 存在偏差。项目 fork 了一份本地 SwiftTerm 副本修改，以对齐真实终端
/// 行为，确保 Claude Code 等 TUI Agent 的输出能在 SwiftUI 中正确渲染。
///
/// 关键职责：
/// - **Agent CRUD**：创建、编辑、删除 Agent 配置（`AgentConfig`）。
/// - **Session 生命周期**：启动新会话（`startNewSession`）、恢复会话（`resumeSession`）、
///   关闭标签（`closeTab`）、终止进程（`endSession`）、清除历史（`clearSessions`）。
/// - **会话锚点**：`anchorSession` 延迟抓取 Agent 历史文件中的 session-id，
///   供后续精确恢复时使用 `--resume <id>`。
/// - **自动恢复**：`autoResumeOnLaunch` 在 App 启动时自动恢复可恢复会话。
/// - **标签栏状态**：`openSessionIDs` + `selectedSessionID` 管理多标签并行。
///
/// 关联文件：
/// - `TerminalAgentsApp.swift`：创建 `@StateObject` 实例并通过 `.environmentObject` 注入全局。
/// - `TerminalManager.swift`：终端进程管理（PTY 创建、NSView 复用）。
/// - `Store.swift`：Agent/Session 持久化与 transcript 文件管理。
/// - `AgentConfig.swift`：Agent 模型（name、commandString、historyFormat、color）。
/// - `Session.swift`：Session 模型（ID、agentId、status、transcriptRef 等）。
/// - `All views`：所有 View 文件都通过 `@EnvironmentObject var appState: AppState` 访问。
@MainActor
final class AppState: ObservableObject {

    // MARK: Data

    /// 所有已配置的 Agent 列表。
    /// 通过 SidebarView 展示，由 AgentEditorSheet 增改，由 Store 持久化。
    @Published var agents: [AgentConfig] = []
    /// 所有会话列表（包括运行中、已关闭）。
    /// SessionListView 按 selectedAgentID 过滤展示当前 Agent 的会话。
    @Published var sessions: [Session] = []
    /// AI Provider 配置列表，参考 cc-switch 的 Provider Management。
    @Published var providers: [ProviderProfile] = []
    /// 侧边栏当前选中的 Agent ID。
    /// 驱动 SessionListView 和 TerminalPaneView 的路由切换。
    @Published var selectedAgentID: AgentConfig.ID?
    /// 当前终端面板中选中的会话 ID（对应 TerminalTabBar 高亮标签）。
    /// 驱动 TerminalViewRepresentable / TranscriptReadOnlyView / ResumePromptView 的分发。
    @Published var selectedSessionID: Session.ID?
    /// 右侧标签栏里「打开着」的会话 ID 列表（可多个，支持并排/后台）。
    /// - 新启动会话自动加入此列表。
    /// - 用户手动关闭标签（`closeTab`）则从此列表移除但不杀进程。
    /// - `endSession` 终止进程同时移除此列表。
    @Published var openSessionIDs: [Session.ID] = []

    // MARK: UI state

    /// 是否弹出新建/编辑 Agent 的表单（AgentEditorSheet）。
    /// 由 `presentNewAgent()` 或 `presentEditAgent()` 设为 true，
    /// 表单关闭时由 AgentEditorSheet 设回 false。
    @Published var newAgentRequest: Bool = false
    /// 是否展示 Provider 管理器。
    @Published var providerManagerRequest: Bool = false
    /// 正在编辑的 Agent（nil 表示新建模式）。
    /// 由 `presentEditAgent()` 设置，用于回填 AgentEditorSheet 表单。
    @Published var editingAgent: AgentConfig? = nil
    /// 由 ContentView 注入：用于从菜单/非视图处打开独立会话窗口。
    /// 类型为 `(UUID) -> Void`，内部调用 `openWindow(id: "session", value:)`。
    var openWindowAction: ((UUID) -> Void)?
    /// 终端布局版本号：每次有终端视图被拆离（如独立窗口关闭）时自增，
    /// 触发所有 TerminalViewRepresentable 重新认领所属会话的 NSView，
    /// 避免「共享 NSView 被某窗口抢走后，另一处永久空白/无响应」的 bug。
    @Published var terminalLayoutVersion: Int = 0
    /// 新建 Agent 时预选的主题色名称（轮转调色板 `AgentColor.next(after:)`，
    /// 确保相邻 Agent 尽量不重色）。
    var newAgentDefaultColorName: String = "blue"
    /// 应用界面语言偏好，保存在 UserDefaults 中，所有窗口共享。
    @Published var appLanguage: AppLanguage = .english {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: Self.languageDefaultsKey)
        }
    }
    /// 内置终端主题，默认亮色；切换时会立即重刷已打开的终端。
    @Published var terminalThemeMode: TerminalThemeMode = .light {
        didSet {
            UserDefaults.standard.set(terminalThemeMode.rawValue, forKey: Self.terminalThemeDefaultsKey)
            terminalManager.applyTheme(terminalThemeMode)
            bumpTerminalLayout()
        }
    }
    /// Provider 启用结果提示。
    @Published var providerStatusMessage: String? = nil

    /// 持久化存储管理器（Agent/Session 的 JSON + transcript 二进制文件）。
    let store = Store()
    /// 终端管理器：管理 PTY 进程生命周期、NSView 创建与复用。
    /// 初始化时传入 `store`，用于 transcript 文件路径管理。
    let terminalManager: TerminalManager
    private static let languageDefaultsKey = "appLanguage"
    private static let terminalThemeDefaultsKey = "terminalThemeMode"

    /// 初始化：创建 TerminalManager，加载持久化数据，
    /// 自动选中第一个 Agent，标记所有 running 会话为 closed，
    /// 然后对可恢复会话触发 `autoResumeOnLaunch`。
    init() {
        terminalManager = TerminalManager(store: store)
        if let raw = UserDefaults.standard.string(forKey: Self.languageDefaultsKey),
           let language = AppLanguage(rawValue: raw) {
            appLanguage = language
        }
        if let raw = UserDefaults.standard.string(forKey: Self.terminalThemeDefaultsKey),
           let themeMode = TerminalThemeMode(rawValue: raw) {
            terminalThemeMode = themeMode
        }
        load()
        if selectedAgentID == nil { selectedAgentID = agents.first?.id }
    }

    // MARK: Loading / persistence

    /// 从磁盘加载持久化数据并标记残留 running 会话。
    ///
    /// 策略：
    /// 1. `store.load()` 读取 JSON + transcript 元数据。
    /// 2. 将所有 `status == .running` 的会话标记为 `.closed`（进程已随 App 退出而消亡）。
    /// 3. `store.save()` 回写修正后的状态。
    /// 4. `autoResumeOnLaunch()` 对支持恢复的 Agent 自动重启会话。
    func load() {
        store.load()
        agents = store.agents
        sessions = store.sessions
        providers = store.providers
        ensurePrimaryAgentProviders()
        // App 重启后所有 running 会话的进程已不存在，标记为 closed（PTY 不可恢复）
        for i in sessions.indices where sessions[i].status == .running {
            sessions[i].status = .closed
        }
        store.sessions = sessions
        store.save()
        // 自动恢复支持 --continue 的 Agent 会话：重启 App 即自动拉回历史对话，无需手动点击
        autoResumeOnLaunch()
    }

    /// App 启动时对每个已关闭且 Agent 支持恢复的会话自动重启。
    /// 旧 Session 被删除（避免残留），新 Session 继承 agentId 与命令 + resume 参数。
    ///
    /// 筛选条件：
    /// - `status == .closed`：会话已关闭（进程已退出）。
    /// - `historyFormat != .none`：Agent 配置了历史格式。
    /// - `HistoryFormat.supportsResume(agent)`：该格式的恢复标志非空。
    private func autoResumeOnLaunch() {
        let resumable = sessions.filter { s in
            s.status == .closed &&
            agents.contains { agent in
                agent.id == s.agentId &&
                agent.historyFormat != .none &&
                HistoryFormat.supportsResume(agent)
            }
        }
        guard !resumable.isEmpty else { return }
        var firstNewID: Session.ID?
        var resumedCount = 0
        for old in resumable {
            let delay = Self.detachedResumeLaunchDelay(index: resumedCount)
            if let id = resumeSession(old,
                                      deleteOld: true,
                                      selectFirst: false,
                                      detachedStartDelay: delay) {
                if firstNewID == nil {
                    firstNewID = id
                }
                resumedCount += 1
            }
        }
        if let id = firstNewID { selectedSessionID = id }
        persist()
    }

    /// 将当前状态持久化到磁盘。
    /// 每次 Agent/Session 变更后都应调用此方法。
    func persist() {
        store.agents = agents
        store.sessions = sessions
        store.providers = providers
        store.save()
    }

    // MARK: Derived

    /// 当前选中的 Agent 配置（通过 selectedAgentID 查找）。
    var selectedAgent: AgentConfig? { agents.first { $0.id == selectedAgentID } }
    /// 当前选中的 Session（通过 selectedSessionID 查找）。
    var selectedSession: Session? { sessions.first { $0.id == selectedSessionID } }
    /// 最近启用的 Provider，用于侧边栏快速切换菜单显示当前状态。
    var recentlyActivatedProviders: [ProviderProfile] {
        providers
            .filter { $0.lastActivatedAt != nil && ProviderTarget.primaryAgentTools.contains($0.target) }
            .sorted { ($0.lastActivatedAt ?? .distantPast) > ($1.lastActivatedAt ?? .distantPast) }
    }
    /// 每个目标工具当前最近启用的 Provider ID。
    var activeProviderIDs: Set<ProviderProfile.ID> {
        let grouped = Dictionary(grouping: providers.filter { $0.lastActivatedAt != nil }, by: \.target)
        return Set(grouped.values.compactMap { group in
            group.max { ($0.lastActivatedAt ?? .distantPast) < ($1.lastActivatedAt ?? .distantPast) }?.id
        })
    }
    /// 当前 Agent 对应的已启用 Provider 环境变量。用于内置终端启动时即时生效。
    private func providerRuntimeEnvironment(for agent: AgentConfig) -> [String: String] {
        let format = agent.historyFormat == .auto
            ? HistoryFormat.detect(from: agent.commandString)
            : agent.historyFormat
        guard let target = providerTarget(for: format),
              let provider = activeProvider(for: target) else {
            return [:]
        }
        return ProviderConfigApplier.runtimeEnvironment(for: provider)
    }

    private func providerTarget(for format: HistoryFormat) -> ProviderTarget? {
        switch format {
        case .claudeCode: return .claudeCode
        case .kimiCode: return .kimiCode
        case .openCode: return .openCode
        case .hermes: return .hermes
        case .auto, .none, .openClaw: return nil
        }
    }

    private func activeProvider(for target: ProviderTarget) -> ProviderProfile? {
        providers
            .filter { $0.target == target && $0.lastActivatedAt != nil }
            .max { ($0.lastActivatedAt ?? .distantPast) < ($1.lastActivatedAt ?? .distantPast) }
    }
    /// 根据当前界面语言取用户可见文案。
    func text(_ key: AppText) -> String { appLanguage.text(key) }
    /// 当前选中 Agent 的所有会话，按创建时间降序排列（最新的在前）。
    var sessionsForSelectedAgent: [Session] {
        sessions.filter { $0.agentId == selectedAgentID }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Agent CRUD

    /// 弹出新建 Agent 表单。
    /// 设置 `newAgentDefaultColorName` 为循环调色板的下一个颜色，
    /// 清空 `editingAgent`（nil = 新建模式），置 `newAgentRequest = true`。
    func presentNewAgent() {
        newAgentDefaultColorName = AgentColor.next(after: agents).rawValue
        editingAgent = nil
        newAgentRequest = true
    }

    /// 弹出编辑 Agent 表单（回填已有配置）。
    /// - Parameter agent: 要编辑的 Agent。
    func presentEditAgent(_ agent: AgentConfig) { editingAgent = agent; newAgentRequest = true }

    /// 保存 Agent 草稿（新增或更新）。
    ///
    /// 逻辑：
    /// - 若 draft.id 已存在 → 更新现有 Agent。
    /// - 若不存在 → 追加新 Agent 并自动选中。
    /// - 调用 `persist()` 写入磁盘。
    ///
    /// - Parameter draft: AgentEditorSheet 产出的 Agent 草稿。
    func saveAgent(_ draft: AgentConfig) {
        if let idx = agents.firstIndex(where: { $0.id == draft.id }) {
            agents[idx] = draft
        } else {
            agents.append(draft)
            selectedAgentID = draft.id
        }
        persist()
    }

    // MARK: Provider Management

    func presentProviderManager() {
        providerManagerRequest = true
    }

    func saveProvider(_ provider: ProviderProfile) {
        var next = provider
        next.updatedAt = Date()
        if let idx = providers.firstIndex(where: { $0.id == next.id }) {
            providers[idx] = next
        } else {
            providers.append(next)
        }
        persist()
    }

    func addProvider(from preset: ProviderPreset) {
        providers.append(preset.makeProfile())
        persist()
    }

    func providerIndex(for target: ProviderTarget) -> Int? {
        providers.firstIndex { $0.target == target }
    }

    func provider(for target: ProviderTarget) -> ProviderProfile? {
        providers.first { $0.target == target }
    }

    func ensureProvider(for target: ProviderTarget) {
        guard providerIndex(for: target) == nil else { return }
        providers.append(ProviderProfile.defaultProfile(for: target))
        persist()
    }

    func deleteProvider(_ provider: ProviderProfile) {
        providers.removeAll { $0.id == provider.id }
        persist()
    }

    func importProviders(_ imported: [ProviderProfile]) {
        var changed = 0
        for provider in imported {
            var next = provider
            next.updatedAt = Date()
            if let idx = providers.firstIndex(where: { $0.id == next.id }) {
                providers[idx] = next
            } else {
                providers.append(next)
            }
            changed += 1
        }
        persist()
        providerStatusMessage = "\(text(.providerImported)): \(changed)"
    }

    func activateProvider(_ provider: ProviderProfile) {
        do {
            let result = try ProviderConfigApplier.apply(provider)
            if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
                providers[idx].lastActivatedAt = Date()
                providers[idx].updatedAt = Date()
            }
            persist()
            let touched = result.touchedFiles.map(\.path).joined(separator: "\n")
            providerStatusMessage = "\(text(.providerApplied))\n\(touched)"
        } catch {
            providerStatusMessage = "\(text(.providerApplyFailed)): \(error.localizedDescription)"
        }
    }

    private func ensurePrimaryAgentProviders() {
        var didChange = false
        for target in ProviderTarget.primaryAgentTools where providerIndex(for: target) == nil {
            providers.append(ProviderProfile.defaultProfile(for: target))
            didChange = true
        }
        if didChange {
            store.providers = providers
        }
    }

    /// 删除 Agent 及其所有关联会话。
    ///
    /// 清理步骤：
    /// 1. 关闭所有关联会话的终端进程（`terminalManager.close`，不杀进程）。
    /// 2. 删除所有关联 transcript 文件。
    /// 3. 从 sessions 和 agents 数组中移除。
    /// 4. 若被删除的是当前选中 Agent，选中下一个。
    /// 5. 裁剪 openSessionIDs（移除不再有效的 ID）。
    /// 6. 持久化。
    ///
    /// - Parameter agent: 要删除的 Agent。
    func deleteAgent(_ agent: AgentConfig) {
        let doomed = sessions.filter { $0.agentId == agent.id }
        for s in doomed {
            terminalManager.close(sessionID: s.id, kill: false)
            store.deleteTranscript(for: s.id)
        }
        sessions.removeAll { $0.agentId == agent.id }
        agents.removeAll { $0.id == agent.id }
        if selectedAgentID == agent.id { selectedAgentID = agents.first?.id }
        pruneOpenTabs()
        persist()
    }

    // MARK: Sessions

    /// 为当前选中的 Agent 启动一个新会话。
    ///
    /// 流程：
    /// 1. 获取 `selectedAgent` 配置。
    /// 2. 创建 `Session`（UUID、agentId、标题含时间戳、status=.running）。
    /// 3. 分配 transcript 文件引用（`store.transcriptRef`）。
    /// 4. 加入 sessions 数组。
    /// 5. 调用 `terminalManager.createAndStart` 启动 PTY + 子进程。
    /// 6. 自动加入 openSessionIDs 并选中。
    /// 7. 延迟抓取会话锚点（`anchorSession`）。
    /// 8. 持久化。
    func startNewSession() {
        guard let agent = selectedAgent else { return }
        var session = Session(id: UUID(),
                              agentId: agent.id,
                              title: "\(agent.name) · \(Self.shortTime(Date()))",
                              createdAt: Date(),
                              status: .running,
                              transcriptRef: nil)
        session.transcriptRef = store.transcriptRef(for: session.id)
        sessions.append(session)
        terminalManager.createAndStart(
            session: session,
            command: agent.commandString,
            onTerminated: { [weak self] id in
                self?.markSessionClosed(id)
            },
            autoEnter: shouldAutoAcceptClaudePrompts(for: agent),
            themeMode: terminalThemeMode,
            environmentOverrides: providerRuntimeEnvironment(for: agent)
        )
        if !openSessionIDs.contains(session.id) { openSessionIDs.append(session.id) }
        selectedSessionID = session.id
        // 延迟抓取"锚点"：等 Agent 启动完毕并写入历史文件后，从文件名里拿 session-id 存下来
        anchorSession(sessionId: session.id, agent: agent)
        persist()
    }

    /// 恢复一个已关闭会话：删掉旧的（避免残留），用 Agent 原生 `--resume <id>` 或 `--continue` 重启，
    /// 让 Agent 自己把完整对话历史拉回 TUI。
    ///
    /// 多会话不撞车的关键：优先按旧 Session 的 `agentSessionId` 锚点精确恢复
    /// （`--resume <id>`）；锚点缺失则尝试 createdAt 时间戳匹配历史文件；
    /// 都匹配不到时，仅对允许安全恢复最近会话的 Agent 退化为 `--continue`。
    ///
    /// 恢复参数优先级：
    /// 1. **锚点精确恢复**：`old.agentSessionId` + `format.resumeByIdFlag` → `--resume <id>`。
    /// 2. **时间戳匹配**：`AgentHistoryParser.matchSessionID(createdAt:)` 扫描历史目录匹配文件名。
    /// 3. **安全退化恢复**：仅 `format.allowsLatestResumeFallback` 为 true 时使用 `resumeLatestFlag`。
    ///
    /// - Parameters:
    ///   - old: 要恢复的旧 Session。
    ///   - deleteOld: true 时删除旧 Session（手动恢复 / 启动自动恢复都应 true）。
    ///   - selectFirst: 是否选中新建的 Session（手动恢复应 true；批量自动恢复时可选）。
    @discardableResult
    func resumeSession(_ old: Session,
                       deleteOld: Bool,
                       selectFirst: Bool,
                       detachedStartDelay: TimeInterval? = nil) -> Session.ID? {
        guard let agent = agents.first(where: { $0.id == old.agentId }) else { return nil }
        let fmt = agent.historyFormat == .auto
            ? HistoryFormat.detect(from: agent.commandString) : agent.historyFormat
        guard fmt != .none else { return nil }

        // 优先用锚点精确恢复：Session 保存的 agentSessionId
        var resumeArg: String? = nil
        var resolvedAgentSessionId: String? = old.agentSessionId
        let storedSessionIDIsAmbiguous = old.agentSessionId.map {
            isAmbiguousNativeSessionId($0, for: old, format: fmt)
        } ?? false
        if let sid = old.agentSessionId, !storedSessionIDIsAmbiguous, let byId = fmt.resumeByIdFlag {
            resumeArg = "\(byId) \(sid)"
        }
        // 锚点缺失 → 尝试 birthtime 匹配
        if resumeArg == nil, let byId = fmt.resumeByIdFlag,
           let sid = AgentHistoryParser.matchSessionID(
               for: old.createdAt,
               format: fmt,
               globOverride: agent.historyGlob,
               excluding: nativeSessionIds(agentId: old.agentId, excluding: old.id)),
           !nativeSessionIdExists(sid, agentId: old.agentId, excluding: old.id) {
            resumeArg = "\(byId) \(sid)"
            resolvedAgentSessionId = sid
        }
        // KimiCode / OpenCode 的 --continue 会恢复同工作目录最近会话，多会话下会串台。
        if resumeArg == nil, fmt.allowsLatestResumeFallback {
            resumeArg = fmt.resumeLatestFlag
        }
        guard let arg = resumeArg else { return nil }

        let cmd = agent.commandString + " " + arg
        var session = Session(id: UUID(),
                              agentId: agent.id,
                              title: "\(agent.name) · resumed · \(Self.shortTime(Date()))",
                              createdAt: old.createdAt,
                              status: .running,
                              transcriptRef: nil)
        session.transcriptRef = store.transcriptRef(for: session.id)
        session.agentSessionId = resolvedAgentSessionId
        sessions.append(session)
        // Claude Code 恢复模式：自动 Enter 跳过信任确认；其它 Agent 暂不自动输入。
        terminalManager.createAndStart(session: session, command: cmd, onTerminated: { [weak self] id in
            self?.markSessionClosed(id)
        },
        autoEnter: shouldAutoAcceptClaudePrompts(for: agent),
        themeMode: terminalThemeMode,
        detachedStartDelay: detachedStartDelay,
        environmentOverrides: providerRuntimeEnvironment(for: agent))
        if !openSessionIDs.contains(session.id) { openSessionIDs.append(session.id) }
        if deleteOld {
            terminalManager.close(sessionID: old.id, kill: false)
            store.deleteTranscript(for: old.id)
            sessions.removeAll { $0.id == old.id }
            openSessionIDs.removeAll { $0 == old.id }
        }
        if selectFirst { selectedSessionID = session.id }
        anchorSession(sessionId: session.id, agent: agent)
        persist()
        return session.id
    }

    /// 选中指定会话（更新 selectedSessionID 并确保其在标签栏中打开）。
    ///
    /// - 若会话运行中、终端视图存在且不在标签栏中，自动加入 openSessionIDs。
    /// - 用于从 SessionListView 点击历史会话跳转到终端面板。
    ///
    /// - Parameter id: 要选中的会话 ID。
    func selectSession(_ id: Session.ID) {
        selectedSessionID = id
        // 重新打开一个仍在后台运行的会话标签
        if let s = sessions.first(where: { $0.id == id }),
           s.status == .running,
           terminalManager.view(for: id) != nil,
           !openSessionIDs.contains(id) {
            openSessionIDs.append(id)
        }
    }

    /// 关闭标签：仅从标签栏移除。
    ///
    /// 注意：运行中的会话进程**不终止**、transcript 继续落盘；
    /// 用户可通过 SessionListView 随时重新打开。
    /// 已结束的会话则释放其终端视图（`terminalManager.close(kill: false)`）。
    ///
    /// - Parameter id: 要关闭标签的会话 ID。
    func closeTab(_ id: Session.ID) {
        openSessionIDs.removeAll { $0 == id }
        if selectedSessionID == id { selectedSessionID = openSessionIDs.last }
        if let s = sessions.first(where: { $0.id == id }), s.status == .closed {
            terminalManager.close(sessionID: id, kill: false)
        }
    }

    /// 结束会话：终止进程、关闭 transcript、标记 closed。
    ///
    /// - 调用 `terminalManager.close(kill: true)` 杀死子进程。
    /// - 从 openSessionIDs 移除该标签。
    /// - 标记 status 为 `.closed`。
    /// - 若选中会话被关闭，自动选下一个标签。
    ///
    /// - Parameter id: 要结束的会话 ID。
    func endSession(_ id: Session.ID) {
        terminalManager.close(sessionID: id, kill: true)
        openSessionIDs.removeAll { $0 == id }
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].status = .closed
        }
        if selectedSessionID == id { selectedSessionID = openSessionIDs.last }
        persist()
    }

    /// 进程退出回调：由 TerminalManager 在子进程退出时调用。
    ///
    /// 将对应 Session 的 status 标记为 `.closed` 并持久化。
    ///
    /// - Parameter id: 已退出的会话 ID。
    func markSessionClosed(_ id: Session.ID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].status = .closed
        }
        persist()
    }

    // MARK: Session deletion

    /// 删除单条历史会话：终止其进程（若仍在运行）、删除 transcript 文件、从列表移除。
    ///
    /// - Parameter session: 要删除的会话。
    func deleteSession(_ session: Session) {
        terminalManager.close(sessionID: session.id, kill: true)
        store.deleteTranscript(for: session.id)
        sessions.removeAll { $0.id == session.id }
        pruneOpenTabs()
        persist()
    }

    /// 清空当前选中 Agent 的全部历史会话（含 transcript 与仍在运行的进程）。
    ///
    /// 用于 SessionListView 的 "Clear All" 操作，批量删除一个 Agent 的所有会话记录。
    func clearSessions() {
        guard let agentID = selectedAgentID else { return }
        let doomed = sessions.filter { $0.agentId == agentID }
        for s in doomed {
            terminalManager.close(sessionID: s.id, kill: true)
            store.deleteTranscript(for: s.id)
        }
        sessions.removeAll { $0.agentId == agentID }
        pruneOpenTabs()
        persist()
    }

    /// 对指定会话 ID 调用注入的 `openWindowAction`，在独立窗口中打开该会话终端。
    ///
    /// 用于：
    /// - 菜单栏 `View → Open in New Window`。
    /// - TerminalTabBar 右键菜单 "Open in New Window"。
    ///
    /// - Parameter id: 要打开的会话 ID。
    func openWindowForSession(_ id: Session.ID) {
        openWindowAction?(id)
    }

    /// 延迟抓取 Agent 会话锚点：等 Agent 启动完毕写入历史文件后，扫描目录取文件名作为 session-id，
    /// 存到 `Session.agentSessionId`，供后续 `--resume <id>` 精确恢复。
    ///
    /// 工作流程：
    /// 1. 解析 Agent 的 HistoryFormat（auto → 自动检测）。
    /// 2. 若该格式不支持 `resumeByIdFlag` → 直接返回（无需锚点）。
    /// 3. 记录当前 session.createdAt 时间戳。
    /// 4. 延迟 8 秒（等 Agent 写入历史文件）。
    /// 5. 调用 `AgentHistoryParser.matchSessionID` 按时间戳匹配历史文件名。
    /// 6. 匹配成功 → 写入 `sessions[idx].agentSessionId` 并持久化。
    ///
    /// - Parameters:
    ///   - sessionId: 会话 ID（用于查找/更新 Session）。
    ///   - agent: 关联的 Agent 配置（提供 historyFormat）。
    private func anchorSession(sessionId: Session.ID, agent: AgentConfig) {
        let fmt = agent.historyFormat == .auto
            ? HistoryFormat.detect(from: agent.commandString) : agent.historyFormat
        guard fmt.resumeByIdFlag != nil else { return }
        let createdAt = sessions.first(where: { $0.id == sessionId })?.createdAt
        Task { @MainActor in
            // OpenCode 通常在第一条消息后才写入 SQLite session，单次 8 秒扫描容易过早。
            let retryDelays: [UInt64] = [8, 12, 20, 40, 80]
            for delay in retryDelays {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let ts = createdAt,
                      let idx = sessions.firstIndex(where: { $0.id == sessionId }),
                      sessions[idx].agentSessionId == nil else { return }
                let excluded = nativeSessionIds(agentId: agent.id, excluding: sessionId)
                if let sid = AgentHistoryParser.matchSessionID(for: ts,
                                                               format: fmt,
                                                               globOverride: agent.historyGlob,
                                                               excluding: excluded) {
                    guard !nativeSessionIdExists(sid, agentId: agent.id, excluding: sessionId) else { continue }
                    sessions[idx].agentSessionId = sid
                    persist()
                    return
                }
            }
        }
    }

    /// 通知所有终端展示位重新认领各自会话的 NSView。
    ///
    /// 场景：当用户关闭独立窗口时，该窗口持有的 TerminalViewRepresentable
    /// 释放其 NSView 引用。调用此方法自增 `terminalLayoutVersion`，
    /// 触发所有尚存的 TerminalViewRepresentable 在 `updateNSView` 中重新检查
    /// 是否需要重新填充 NSView，避免出现空白/无响应终端。
    func bumpTerminalLayout() {
        terminalLayoutVersion += 1
    }

    // MARK: Helpers

    /// 裁剪 openSessionIDs：移除指向已删除会话的 ID。
    ///
    /// 在删除 Agent/Session 后调用，确保标签栏不残留无效标签。
    /// 同时更新 selectedSessionID（若指向已删除会话则自动切换到最后一个有效标签）。
    private func pruneOpenTabs() {
        let valid = Set(sessions.map { $0.id })
        openSessionIDs = openSessionIDs.filter { valid.contains($0) }
        if let sel = selectedSessionID, !valid.contains(sel) {
            selectedSessionID = openSessionIDs.last
        }
    }

    /// 目前只深度适配 Claude Code：启动与恢复时自动确认其信任/继续提示。
    private func shouldAutoAcceptClaudePrompts(for agent: AgentConfig) -> Bool {
        let fmt = agent.historyFormat == .auto
            ? HistoryFormat.detect(from: agent.commandString) : agent.historyFormat
        return fmt == .claudeCode || agent.commandString.lowercased().contains("claude")
    }

    /// Kimi/OpenCode 曾经可能因为 `--continue` 或过早锚定而把多个 App Session
    /// 写成同一个原生 session-id。重复 id 对这两类 Agent 来说不可信，恢复时应重新匹配；
    /// 如果匹配不到，就保持关闭，避免再次串到同一个最新会话。
    private func isAmbiguousNativeSessionId(_ sid: String, for session: Session, format: HistoryFormat) -> Bool {
        guard format == .kimiCode || format == .openCode else { return false }
        return nativeSessionIdExists(sid, agentId: session.agentId, excluding: session.id)
    }

    private func nativeSessionIdExists(_ sid: String, agentId: AgentConfig.ID, excluding sessionId: Session.ID) -> Bool {
        sessions.contains {
            $0.id != sessionId &&
            $0.agentId == agentId &&
            $0.agentSessionId == sid
        }
    }

    private func nativeSessionIds(agentId: AgentConfig.ID, excluding sessionId: Session.ID) -> Set<String> {
        Set(sessions.compactMap {
            guard $0.id != sessionId, $0.agentId == agentId else { return nil }
            return $0.agentSessionId
        })
    }

    /// 生成短时间戳字符串（"MM-dd HH:mm" 格式）。
    ///
    /// 用于 Session 标题拼接和会话启动时间显示。
    ///
    /// - Parameter d: 时间戳。
    /// - Returns: 格式化的时间字符串。
    private static func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    private static func detachedResumeLaunchDelay(index: Int) -> TimeInterval {
        0.8 + Double(index) * 1.4
    }
}
