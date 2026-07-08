import Foundation

/// Agent 配置模型 —— 定义单个 AI Agent 的所有持久化配置项。
///
/// **架构角色：**
/// - 这是整个 App 的"Agent 定义"核心数据结构，一份配置对应一个可启动的终端 Agent 实例；
/// - 由 `AgentConfigStore`（ObservableObject ViewModel）持有数组并负责持久化（JSON 文件）；
/// - UI 层通过 `AgentRowView` / `AgentDetailView` 展示和编辑；
/// - 会话管理层通过 `SessionManager` 读取此配置来启动 PTY 进程和恢复历史。
///
/// **设计决策：**
/// - `Hashable`：用于 SwiftUI `ForEach` 和 `Set` 去重场景；
/// - `Codable`：整份 Agent 列表作为一个 JSON 数组存入磁盘（`~/.terminal-agents/agents.json`）；
/// - `struct`（值类型）：配合 `@Published` 数组使用时，SwiftUI 能正确检测"整个 struct 变更"并刷新视图；
/// - 没有使用 `@Observable` 宏：沙箱环境下 Swift Macro 插件加载受限，
///   回退到传统的 `Codable + struct + @Published` 模式。
///
/// **相关文件：** `AgentConfigStore.swift`（持有者）、`AgentRowView.swift`（UI 渲染）、
/// `SessionManager.swift`（启动 PTY 时的配置读取）。
struct AgentConfig: Codable, Identifiable, Hashable {

    /// Agent 的唯一标识。使用 `UUID()` 自动生成默认值，
    /// 新建 Agent 时无需手动填充（`Codable` 解码已有 id 则覆盖）。
    var id: UUID = UUID()

    /// Agent 的显示名称，如 "ClaudeCode"、"Kimi Terminal"。
    /// 显示在侧边栏列表、会话标题栏、Agent 选择器中。
    var name: String

    /// Agent 启动命令，即 PTY 中执行的完整命令行字符串。
    /// 例如：`"claude"`、`"kimi"`、`"/usr/local/bin/opencode"`。
    /// —— 同时也是历史格式自动检测的输入（见 `HistoryFormat.detect(from:)`）。
    var commandString: String

    /// Agent 创建时间，默认当前日期。用于列表排序和"最近使用"判断。
    var createdAt: Date = Date()

    /// 主题色名称（对应 `AgentColor` 枚举的 rawValue 字符串）。
    ///
    /// **为什么用 String 而不是直接存储枚举？**
    /// - 向前兼容：旧版数据中无此字段时 `Codable` 解出空串 `""`，不会崩溃；
    /// - 枚举变更安全：如果未来增加或移除颜色 case，已持久化的旧字符串不会导致解码失败；
    /// - 实际颜色解析由计算属性 `color` 完成，空串或非法值 → 通过 `AgentColor.default(for:)`
    ///   按键稳定分配兜底色，保证任何 Agent 都必有一个可见颜色。
    var colorName: String = ""

    /// 解析后的主题色 —— UI 真正使用的颜色。
    ///
    /// **数据流：**
    /// 1. 持久化层存储 `colorName`（字符串）；
    /// 2. UI 层只读取 `color`（`AgentColor` 枚举）；
    /// 3. 若 `colorName` 无法解析为合法枚举值，回退到 `AgentColor.default(for:)`
    ///    按 id 确定性地分配一个颜色（同一 id 永远同一色，重启不变）。
    ///
    /// **边界情况：**
    /// - `colorName` 为空字符串 → 回退到按 id 分配
    /// - `colorName` 为已删除的旧颜色名 → 回退到按 id 分配
    /// - 此 getter 永不返回 nil，保证 UI 渲染不会因缺失颜色而崩溃
    var color: AgentColor {
        AgentColor(rawValue: colorName) ?? .default(for: id)
    }

    /// Agent 原生对话历史文件的 glob 路径。
    ///
    /// **用途：** 用于读取 Agent 的结构化消息日志（JSONL 格式），
    /// 从而在 TerminalAgents 内展示结构化的对话历史（而非原始字节流）。
    ///
    /// **示例值：**
    /// - Claude Code：`"~/.claude/history/*.jsonl"`
    /// - Kimi Code：`"~/.kimi/history/*.jsonl"`
    /// - OpenCode：`"~/.opencode/sessions/*"`
    ///
    /// **为 nil 或空时的行为：** 不读取原生历史文件，回退到 PTY 字节重放模式
    /// （直接回显终端原始输出，不做结构化解析）。
    ///
    /// **与 `historyFormat` 的关系：** 此 glob 指定"从哪里读文件"，
    /// `historyFormat` 指定"用什么格式解析文件内容"。两者独立配置，
    /// 用户可自定义 glob 覆盖 `HistoryFormat.defaultGlob`。
    var historyGlob: String? = nil

    /// 历史文件格式。
    ///
    /// **取值含义：**
    /// - `.auto`：根据 `commandString` 自动检测（见 `HistoryFormat.detect(from:)`）；
    /// - `.none`：跳过原生历史读取，仅使用 PTY 字节流；
    /// - `.claudeCode` / `.kimiCode` / `.openCode` / `.hermes` / `.openClaw`：
    ///   使用对应格式的解析器。
    ///
    /// **设计考量：** 设为 `.auto` 而非固定格式，因为用户可能通过环境变量
    /// 或 alias 启动同一个命令的不同变体，自动检测比手动选择更友好。
    var historyFormat: HistoryFormat = .auto
}
