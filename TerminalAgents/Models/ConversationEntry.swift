import Foundation

/// 从 Agent 原生历史文件解析出的一条对话消息。
///
/// **数据来源：** Agent 在本地存储的结构化会话日志（如 JSONL 格式），
/// 由 `AgentHistoryParser` 解析后生成此模型的数组。
///
/// **与 `Session` 的关系：**
/// - `Session` 描述一个会话的元数据（id、状态、文件引用）；
/// - `ConversationEntry` 是该会话中单条消息的内容载体；
/// - 一个 `Session` 对应多个 `ConversationEntry`（"一对多"关系）。
///
/// **设计决策：**
/// - `Codable`：支持将解析后的历史缓存为本地文件，避免重复解析；
/// - `Hashable` + `Identifiable`：用于 SwiftUI `List` / `ForEach` 渲染对话列表，
///   每条消息需要独立的 identity 以避免 Diff 异常；
/// - 使用 `struct`（值类型）：对话消息本身是数据快照，不需要引用语义，
///   且配合 SwiftUI 的 `@State` / `@Binding` 更安全。
///
/// **相关文件：**
/// - `AgentHistoryParser.swift`：解析逻辑，读取 JSONL 文件生成 `[ConversationEntry]`
/// - `ConversationView.swift`：UI 层渲染对话气泡
/// - `Session.swift`：会话元数据模型
struct ConversationEntry: Codable, Identifiable, Hashable {

    /// 消息的唯一标识。使用 `UUID()` 自动生成，
    /// 因为原生历史文件中通常不提供消息级 uuid（只提供会话级 uuid）。
    /// 每次解析时重新生成 id，这意味着同一条历史消息在两次解析间 id 不同，
    /// 但对于纯展示场景（非编辑/同步）这是可接受的。
    var id = UUID()

    /// 消息发送者角色 —— 定义对话中各方的身份。
    ///
    /// **为什么需要 `.tool`？**
    /// Claude Code / Kimi Code 等工具调用型 Agent 会在对话中插入 tool-use / tool-result 消息。
    /// 这些既不是纯 user 也不是纯 assistant，需要独立分类以便渲染时使用不同的气泡样式
    /// （如：工具调用用等宽字体 + 灰色背景，与普通对话区分）。
    ///
    /// **为什么没有 `.error`？**
    /// Agent 原生历史文件中一般不会单独标记错误消息；
    /// 解析层如果遇到无法解析的条目，会直接丢弃 + 打日志，而非纳入此模型。
    var role: Role

    /// 消息正文内容。可能是纯文本、Markdown、或代码块。
    /// **不做截断**：完整保留 Agent 原文，由 UI 层自行决定是否折叠长文本。
    var content: String

    /// 消息创建时间戳（可选）。
    ///
    /// **为什么是 Optional？**
    /// 部分 Agent（如 Hermes 的旧版本）的历史条目中不包含时间戳字段，
    /// 解析器在这种情况下填 nil，UI 层据此决定是否显示时间分割线。
    /// 非 Optional 会导致必须伪造一个默认时间，反而误导用户。
    var timestamp: Date?

    /// 消息角色枚举 —— 对应对话中不同的发言者身份。
    ///
    /// **为什么用 enum 而非 String？**
    /// 1. 类型安全：编译器保证不会出现拼写错误（`"usre"` 之类）；
    /// 2. 可扩展：未来增加角色（如 `agent`）只需增加 case，不会静默产生 bug；
    /// 3. 序列化一致：`Codable` 编解码角色时与原生 JSON 字段名保持精确映射。
    enum Role: String, Codable, CaseIterable, Hashable {
        case user       /// 用户输入的消息
        case assistant  /// AI Agent 的回复
        case system     /// 系统提示 / 预设消息（通常不在 UI 中展示）
        case tool       /// 工具调用 / 工具执行结果（Agent 内部操作）
    }

    /// 便捷判断是否为用户发送的消息。
    /// 用于 UI 层快速决定气泡对齐方向（用户消息右对齐，其他左对齐）。
    var isUser: Bool { role == .user }
}
