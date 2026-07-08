import Foundation

/// 会话状态枚举 —— 描述一个 TerminalAgents Session 的生命周期阶段。
///
/// **为什么只有两个状态？**
/// - 终端 Agent 会话的状态模型与 GUI 应用不同：终端进程本质上只有"正在运行"
///   和"已退出"两种状态；
/// - "暂停"、"睡眠"等中间态无实际意义（PTY 进程被 SIGSTOP 时 TerminalAgents
///   也无法正确保持交互，且用户对此类状态感知模糊）；
/// - 保持简单可降低 `SessionManager` 中状态机的复杂度，减少 Bug 面。
///
/// **状态转换：**
/// - `running` → `closed`：PTY 进程退出 / 用户手动关闭 / App 退出
/// - `closed` → `running`：用户恢复会话 / 重新打开（创建新的 `Session` 实例，
///   但复用相同的 `agentSessionId`）
///
/// **相关文件：** `SessionManager.swift`（状态机驱动）、
/// `SessionRowView.swift`（根据状态显示运行中/已关闭图标）
enum SessionStatus: String, Codable {
    case running   /// 会话正在运行（PTY 进程活跃）
    case closed    /// 会话已关闭（PTY 进程已退出或用户手动关闭）
}

/// 会话模型 —— 代表一个 Agent 的单个对话实例。
///
/// **架构角色：**
/// - `Session` 是"会话元数据"层：记录谁在何时启动了哪个 Agent，结果存到了哪里；
/// - 实际的对话内容由 `ConversationEntry` 数组承载（通过 `historyFileRef` 和
///   `transcriptRef` 间接引用磁盘文件）；
/// - `Session` 自己不持有对话数据，而是持有文件引用 —— 这种"指针"设计避免了
///   内存中同时存在大量对话文本（一个 Session 可能有上万条消息）。
///
/// **一对多关系：**
/// - 一个 `AgentConfig` → 多个 `Session`（同一 Agent 的多次对话）
/// - 一个 `Session` → 多个 `ConversationEntry`（通过 `historyFileRef` 指向的 JSONL 文件）
///
/// **持久化：** 所有 Session 数组随 `AgentConfigStore` 一起存入
/// `agents.json`（作为顶层 key `"sessions"`），而非单独的文件。
/// 这样保证 Agent 与其 Session 的一致性：删除 Agent 时可以同时清理关联 Session。
///
/// **设计决策：**
/// - `Codable`：JSON 持久化，与 `AgentConfig` 共用同一个存储文件；
/// - `Hashable` + `Identifiable`：SwiftUI `List` / `ForEach` 需要；
/// - 使用 `struct`（值类型）：与 `AgentConfig` 同理，配合 `@Published` 数组工作。
///
/// **相关文件：**
/// - `SessionManager.swift`：创建、关闭、恢复会话，负责管理 Session 生命周期
/// - `AgentHistoryParser.swift`：通过 `historyFileRef` 读取并解析对话历史
/// - `ConversationEntry.swift`：解析后的单条消息模型
/// - `SessionRowView.swift` / `SessionDetailView.swift`：UI 层渲染
/// - `AgentConfig.swift`：通过 `agentId` 关联所属的 Agent 配置
struct Session: Codable, Identifiable, Hashable {

    /// 会话的唯一标识。由 `SessionManager.createSession(...)` 在创建时生成。
    var id: UUID

    /// 所属 Agent 的 `AgentConfig.id`，用作 Sessions → Agent 的关联键。
    ///
    /// **为什么不是外键引用 `AgentConfig` 实例？**
    /// - 避免循环引用（Session 持有 AgentConfig、AgentConfig 又可能间接引用 Session）；
    /// - JSON 持久化时只存 UUID，反序列化后由 `AgentConfigStore` 通过 id 查找；
    /// - 删除 Agent 时通过此字段级联删除所有关联 Session。
    var agentId: UUID

    /// 会话标题。通常自动生成为 "<Agent名> - <创建时间>"，
    /// 用户可在 UI 中手动重命名（如"修复登录 Bug 的对话"）。
    var title: String

    /// 会话创建时间。用于：
    /// 1. 列表排序（最近的排在前面）；
    /// 2. 与 Agent 原生历史文件的时间戳匹配，以确定正确的 session-id
    ///    （见 `AgentHistoryParser.matchSessionID(...)`）。
    var createdAt: Date

    /// 会话当前状态。`SessionManager` 在 PTY 启动/退出时更新此字段。
    var status: SessionStatus

    /// transcript 文件名（相对 transcripts 目录），如 `"<uuid>.transcript"`。
    ///
    /// **transcript 是什么？** 终端字节流的完整记录（包括 ANSI 转义序列），
    /// 用于 PTY 重放——即使 Agent 不支持结构化历史读取，也能回放终端原始输出。
    ///
    /// **为什么是 Optional？** 仅当 `SessionManager` 启动 PTY 并开始录制后才赋值；
    /// 未启动或被取消的 Session 中此字段为 nil。
    ///
    /// **目录约定：** transcript 文件统一存放在沙箱内的 `transcripts/` 目录下，
    /// 经由 `FileManager.default.urls(for: .applicationSupportDirectory, ...)`
    /// 解析的 Application Support 路径。
    var transcriptRef: String?

    /// Agent 原生历史文件的绝对路径，如 `"~/.claude/history/a1b2c3d4.jsonl"`。
    ///
    /// **用途：**
    /// 1. `AgentHistoryParser` 从此路径读取 JSONL 行 → 解析为 `[ConversationEntry]`
    /// 2. 会话概览页通过此路径获取最近几条消息作为摘要预览
    ///
    /// **为什么是可选的且默认为 nil？**
    /// - 不是所有 Agent 都产生结构化历史文件（如自定义脚本、或 `historyFormat == .none`）；
    /// - `AgentHistoryParser.matchSessionID(...)` 在会话结束后的异步任务中填充此字段；
    /// - 如果匹配失败（如 Agent 未写入历史文件），保持 nil，UI 层仅展示 transcript 重放。
    var historyFileRef: String? = nil

    /// Agent 内部的 session-id，从历史文件名中提取。
    ///
    /// **用途：** 恢复会话时拼接启动命令，例如：
    /// ```
    /// claude --resume a1b2c3d4
    /// ```
    /// 其中 `a1b2c3d4` 即 `agentSessionId`。
    ///
    /// **来源：** 由 `AgentHistoryParser.matchSessionID(...)` 从 Agent 历史文件
    /// 的文件名中提取（去掉扩展名后的 UUID 部分）。
    ///
    /// **与 `id` 的区别：**
    /// - `id`：TerminalAgents 自己的 UUID（会话记录层面）；
    /// - `agentSessionId`：Agent 进程内部的 session UUID（进程恢复层面）；
    /// - 两者不同，因为 TerminalAgents 作为"外层管理器"无法控制 Agent 如何生成
    ///   自己的 session-id。
    ///
    /// **为什么是可选的？**
    /// - OpenClaw 无文件存储的 session-id（使用内存中的 session key）；
    /// - 部分 Agent（如 `--continue` 模式）不需要 session-id 也可以恢复；
    /// - 历史文件未生成或匹配失败时此字段保持 nil。
    var agentSessionId: String? = nil
}
