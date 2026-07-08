import Foundation

/// Agent 原生对话历史的格式枚举。
///
/// **核心职责：** 集中管理每种已支持 Agent 的"恢复参数"和"历史文件路径"知识。
/// 所有 Agent 差异（Claude 用 `--resume`、Kimi 用 `--session`……）都编码在这个枚举的
/// 计算属性中，而非散落在各个 ViewModel 的 if/else 分支里。
///
/// **设计决策 —— 为什么只保留 5 个主流 Agent？**
/// - 每个新增 Agent 需要对应编写 JSONL 解析逻辑（`AgentHistoryParser` 的子类化
///   或策略模式），维护成本高；
/// - 前 5 个已覆盖 95%+ 的目标用户场景（Claude Code、Kimi Code、OpenCode、
///   Hermes、OpenClaw）；
/// - 其他 Agent 可以通过 `.auto` 模式享受基本的 PTY 重放功能，
///   只是没有结构化历史解析能力。
///
/// **为什么使用 enum 而非 protocol + struct 组合？**
/// - 枚举的 switch 穷尽检查在编译期保证每个新 case 都会被处理；
/// - 对于"已知有限集合"的领域模型，enum 比协议扩展更直接、代码更集中；
/// - 计算属性（resumeLatestFlag / historyDir 等）天然地按 case 分组，可读性好。
///
/// **相关文件：**
/// - `AgentConfig.swift`：通过 `historyFormat` 字段引用此枚举，控制解析和恢复行为
/// - `SessionManager.swift`：恢复会话时使用 `resumeByIdFlag` 拼接启动命令
/// - `AgentHistoryParser.swift`：根据此枚举值选择对应的 JSONL 解析策略
/// - `AgentConfigView.swift`：UI 中提供格式选择器（Picker + auto-detect 标签）
enum HistoryFormat: String, Codable, CaseIterable {

    /// 不读取原生历史文件，仅保留 PTY 字节流重放功能。
    /// 适用于：未支持的 Agent 或用户主动禁用历史读取。
    case none

    /// Claude Code（Anthropic 官方 CLI）。历史文件位置：
    /// `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`
    case claudeCode

    /// Kimi Code（Moonshot AI）。新版历史目录：
    /// `~/.kimi-code/sessions/<workspace>/session_<uuid>/`
    case kimiCode

    /// OpenCode（开源 CLI Agent）。新版历史在 XDG 数据目录的 SQLite 库里，
    /// 旧版可能使用 `~/.opencode/sessions/<uuid>`（无扩展名）。
    case openCode

    /// Hermes（Agent 框架）。历史文件：
    /// `~/.hermes/history/<uuid>.jsonl`
    case hermes

    /// OpenClaw（Agent 框架）。无 per-session 历史文件，
    /// 使用 session key 机制管理会话。
    case openClaw

    /// 自动检测模式 —— 根据 `AgentConfig.commandString` 推断实际格式。
    /// 在 `AgentConfigStore` 新建 Agent 时的默认值。
    case auto

    // MARK: - Auto-detect（自动检测）

    /// 从 Agent 命令字符串推断历史格式。
    ///
    /// **检测策略：** 对 commandString 做大小写不敏感的包含匹配，
    /// 按优先级从高到低依次尝试（Claude → Kimi → OpenCode → Hermes → OpenClaw）。
    ///
    /// **已知局限：**
    /// - 如果命令串中同时包含多个关键词（如 `claude-kimi-wrapper`），
    ///   会命中第一个匹配项，结果可能不正确；但实际场景中无人会这样命名；
    /// - 无法区分 Claude Code 和 Claude API CLI：两者在命令中都有 "claude"，
    ///   但 API CLI 无结构化历史文件 → 实际使用时如遇异常，用户可手动切换为 `.none`；
    /// - 对 alias 透明：如果用户用 `/usr/bin/claude` 的别名 `c`，
    ///   检测会失败 → 回退为 `.none`（安全默认值）。
    ///
    /// **调用位置：**
    /// - `AgentConfigStore` 中新建 Agent 时预填 `historyFormat`
    /// - `SessionManager` 恢复会话前判断是否支持按 session-id 恢复
    static func detect(from command: String) -> HistoryFormat {
        let cmd = command.lowercased()
        if cmd.contains("claude")   { return .claudeCode }
        if cmd.contains("kimi")     { return .kimiCode }
        if cmd.contains("opencode") { return .openCode }
        if cmd.contains("hermes")   { return .hermes }
        if cmd.contains("openclaw") { return .openClaw }
        return .none
    }

    // MARK: - Resume params（会话恢复参数）

    /// 恢复"最近一次"会话的命令行参数。
    ///
    /// **使用场景：** 用户不指定历史会话，只希望"接着上次继续聊"。
    /// 此时 PTY 启动命令追加此 flag（如 `claude --continue`）。
    ///
    /// **重要警告 —— 多会话撞车风险：**
    /// - 如果同一 Agent 有多个会话（如两个不同的 TerminalAgents Session
    ///   指向同一个 Claude Code），`--continue` 会恢复 Claude Code 自己记录的
    ///   "最近一次"会话，可能与 TerminalAgents 期望的不一致；
    /// - **因此，多会话场景优先使用 `resumeByIdFlag`（精确恢复），
    ///   `resumeLatestFlag` 仅作为单会话的兜底方案。**
    ///
    /// **返回 nil 的情况：**
    /// - `.openClaw`：该 Agent 没有"最近会话"的概念，完全基于 session key；
    /// - `.none` / `.auto`：无已知恢复参数。
    var resumeLatestFlag: String? {
        switch self {
        case .claudeCode: return "--continue"
        case .kimiCode:   return "--continue"
        case .openCode:   return "--continue"
        case .hermes:     return "-c"
        case .openClaw:   return nil          // 无"最近"概念，靠 session key
        case .none, .auto: return nil
        }
    }

    /// 是否允许在找不到精确 session-id 时退回"恢复最近一次会话"。
    ///
    /// KimiCode / OpenCode 的 `--continue` 都是"当前工作目录最近会话"语义。
    /// 多个 TerminalAgents 会话共用同一工作目录时，它会把不同会话恢复成同一个最新会话，
    /// 因此这两类必须只走精确 session-id。
    var allowsLatestResumeFallback: Bool {
        switch self {
        case .claudeCode, .hermes:
            return true
        case .kimiCode, .openCode, .openClaw, .none, .auto:
            return false
        }
    }

    /// 按 session-id 精确恢复的参数前缀。
    ///
    /// **使用方式：** PTY 启动时拼接为 `"<resumeByIdFlag> <agentSessionId>"`，
    /// 如 `claude --resume a1b2c3d4`。
    ///
    /// **为什么是"前缀"而非完整参数？**
    /// - 不同 Agent 的参数拼接方式不同：有的是 `--resume=<id>`，有的是 `--resume <id>`；
    /// - 枚举只返回 flag 部分（如 `"--resume"`），调用方（`SessionManager`）
    ///   负责决定拼接方式（目前统一用空格分隔），未来可扩展为更多拼接策略；
    /// - 这也允许调用方在 flag 和 id 之间插入其他参数（如 `--resume --verbose <id>`）。
    ///
    /// **返回 nil 的情况：** 与 `resumeLatestFlag` 一致。
    var resumeByIdFlag: String? {
        switch self {
        case .claudeCode: return "--resume"
        case .kimiCode:   return "--session"
        case .openCode:   return "-s"
        case .hermes:     return "--resume"
        case .openClaw:   return "--session"
        case .none, .auto: return nil
        }
    }

    // MARK: - History directory（历史文件目录，用于按时间戳匹配 session-id）

    /// 存放 per-session 历史文件的首选目录。
    ///
    /// **用途：** 恢复会话时，TerminalAgents 需要找到 Agent 原生历史文件，
    /// 从中提取 session-id（即文件名，不含扩展名）用于精确恢复。
    /// 匹配逻辑见 `AgentHistoryParser.matchSessionID(...)`。
    ///
    /// **为什么要用目录扫描而非硬编码路径？**
    /// - 每个 Agent 的 session-id 是一个随机 UUID，无法从 TerminalAgents 侧推算；
    /// - 只能通过"终端 Agent 启动时间 ≈ 历史文件修改时间"的方式匹配；
    /// - 因此需要枚举该目录下所有文件，找到修改时间最接近的那个。
    ///
    /// **返回 nil 的情况：**
    /// - `.openClaw`：不使用文件存储 session，而是用内存中的 session key；
    /// - `.none` / `.auto`：无已知历史目录。
    ///
    /// **特殊处理 —— Claude Code 的子目录结构：**
    /// - Claude Code 的历史在 `~/.claude/projects/<encoded-cwd>/` 子目录下，
    ///   每个项目目录内才是 `<uuid>.jsonl`；
    /// - 因此 `historyDir` 返回的是 `~/.claude/projects/`（父目录），
    ///   由 `AgentHistoryParser.matchSessionID` 负责递归扫描子目录。
    ///   详见该方法的注释。
    var historyDir: URL? {
        historyDirs.first
    }

    /// 存放 per-session 历史文件/目录的候选目录。
    ///
    /// KimiCode 和 OpenCode 都有过路径变化：
    /// - KimiCode 当前使用 `~/.kimi-code/sessions/.../session_<uuid>/` 目录；
    /// - OpenCode 当前使用 XDG 数据目录下的 SQLite 数据库，同时旧版可能有
    ///   `sessions/<id>` 文件或目录。
    ///
    /// 因此这里保留多候选路径，解析器会扫描所有存在的目录，而不是只押注一个位置。
    var historyDirs: [URL] {
        let home = NSHomeDirectory()
        let root = URL(fileURLWithPath: home)
        switch self {
        case .claudeCode:
            // ~/.claude/projects/（下含 <encoded-cwd>/<uuid>.jsonl，递归扫描）
            return [root.appendingPathComponent(".claude/projects")]
        case .kimiCode:
            return [
                root.appendingPathComponent(".kimi-code/sessions"),
                root.appendingPathComponent(".kimi/history"),
                root.appendingPathComponent(".kimicode/history"),
                root.appendingPathComponent(".config/kimi-code/sessions"),
                root.appendingPathComponent("Library/Application Support/KimiCode/sessions")
            ]
        case .openCode:
            return [
                root.appendingPathComponent(".opencode/sessions"),
                root.appendingPathComponent(".local/share/opencode/sessions"),
                root.appendingPathComponent(".local/share/opencode"),
                root.appendingPathComponent(".config/opencode/sessions"),
                root.appendingPathComponent("Library/Application Support/opencode/sessions"),
                root.appendingPathComponent("Library/Application Support/opencode")
            ]
        case .hermes:
            return [root.appendingPathComponent(".hermes/history")]
        case .openClaw:
            return []   // 用 session key，无 per-session 文件
        case .none, .auto:
            return []
        }
    }

    /// OpenCode 新版把 session 存入 SQLite。这里列出只读查询候选库文件。
    var historyDatabaseFiles: [URL] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
        switch self {
        case .openCode:
            return [
                root.appendingPathComponent(".local/share/opencode/opencode.db"),
                root.appendingPathComponent(".opencode/opencode.db"),
                root.appendingPathComponent(".config/opencode/opencode.db"),
                root.appendingPathComponent("Library/Application Support/opencode/opencode.db")
            ]
        default:
            return []
        }
    }

    /// 历史文件的扩展名，用于目录扫描时过滤文件。
    ///
    /// **OpenCode 无扩展名的情况：**
    /// - 旧版 OpenCode 的 session 文件可能为 `~/.opencode/sessions/<uuid>`（无 `.jsonl` 后缀）；
    /// - 新版 OpenCode 优先走 SQLite；无扩展名扫描只作为兼容兜底。
    var historyFileExtension: String {
        historyFileExtensions.first ?? ""
    }

    /// 历史文件扩展名候选。空字符串代表无扩展名文件。
    var historyFileExtensions: [String] {
        switch self {
        case .claudeCode, .hermes: return ["jsonl"]
        case .kimiCode: return ["jsonl"]
        case .openCode: return ["", "jsonl"]
        case .openClaw: return [""]
        case .none, .auto: return []
        }
    }

    /// 该格式的默认历史 glob 表达式（供 UI 提示和新建 Agent 时的预填值）。
    ///
    /// **与 `AgentConfig.historyGlob` 的关系：**
    /// - `defaultGlob` 是"建议值"，用户可在 UI 中覆盖为自定义路径；
    /// - `AgentConfig.historyGlob` 是"额外候选"，为空时 `AgentHistoryParser`
    ///   使用内置候选目录/数据库作为回退；
    /// - 这个设计允许用户对同一 Agent 类型使用不同的历史目录（如多机器同步场景）。
    var defaultGlob: String {
        switch self {
        case .claudeCode: return "~/.claude/history/*.jsonl"
        case .kimiCode:   return "~/.kimi-code/sessions/**/session_*"
        case .openCode:   return "~/.local/share/opencode/opencode.db"
        case .hermes:     return "~/.hermes/history/*.jsonl"
        case .openClaw:   return ""
        case .none, .auto: return ""
        }
    }

    /// 判断指定 Agent 是否支持会话恢复功能。
    ///
    /// **判断逻辑：**
    /// 1. 若 `historyFormat == .auto`，先通过 `detect(from:)` 从命令串推断实际格式；
    /// 2. 检查实际格式是否有 `resumeLatestFlag` 或 `resumeByIdFlag`；
    /// 3. 任一存在即表示"可恢复"。
    ///
    /// **为什么同时检查两种 flag？**
    /// - OpenClaw 只有 `resumeByIdFlag` 没有 `resumeLatestFlag`，
    ///   但它确实支持按 session key 精确恢复；
    /// - 只要有一种恢复方式就可以工作，不需要两种都满足。
    ///
    /// **调用位置：** `SessionManager` 判断是否在启动命令后追加恢复参数；
    /// `AgentRowView` 判断是否显示"恢复"按钮。
    static func supportsResume(_ agent: AgentConfig) -> Bool {
        let fmt = agent.historyFormat == .auto
            ? detect(from: agent.commandString) : agent.historyFormat
        return fmt.resumeLatestFlag != nil || fmt.resumeByIdFlag != nil
    }
}
