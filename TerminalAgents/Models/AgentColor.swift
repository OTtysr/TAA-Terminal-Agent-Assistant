import SwiftUI

/// Agent 主题色调色板 —— 为每个 Agent 提供视觉上的身份标识色。
///
/// 设计决策：
/// - 使用 `String` 作为 rawValue（而不是 Int），颜色名直接写入 `AgentConfig.colorName`，
///   方便人类可读的持久化存储（JSON / plist 中看到的是 "blue" 而非数字 8）。
/// - 遵循 `CaseIterable` 让调用方可以遍历整个色板（如设置界面的颜色选择器），
///   遵循 `Identifiable` 让 SwiftUI `Picker` 等控件可以直接使用，遵循 `Codable` 保证持久化。
/// - 只保留系统内置的 SwiftUI `Color` 名称（不含语义色如 primary / secondary），
///   因为系统语义色在不同平台上映射关系不可控，不适合作为 Agent 的稳定身份色。
/// - 同时参见：`AgentConfig.color` / `AgentConfig.colorName`（此枚举的消费者），
///   `AgentRowView.swift`（UI 中使用该颜色渲染 Agent 卡片和头像）。
enum AgentColor: String, CaseIterable, Identifiable, Codable {
    case red      // 红 — 通常分配给第一个或冲突后的兜底 Agent
    case orange   // 橙
    case yellow   // 黄
    case green    // 绿
    case mint     // 薄荷绿（iOS/macOS 系统色）
    case teal     // 青
    case cyan     // 天蓝
    case blue     // 蓝 — 最常用的中性色，视觉撞色频率高
    case indigo   // 靛蓝
    case purple   // 紫
    case pink     // 粉
    case brown    // 棕 — 12 种色基本覆盖常见 Agent 数量场景

    /// `Identifiable` 协议要求。直接用 `rawValue`（颜色名字符串）作为唯一标识。
    var id: String { rawValue }

    /// UI 展示用的颜色名称（首字母大写），如 "Blue"、"Mint"。
    var label: String { rawValue.capitalized }

    /// 将枚举值映射为 SwiftUI `Color` 实例。
    ///
    /// 注意：这里使用 SwiftUI 内置的语义色常量（`.red`、`.blue` 等），
    /// 而非从 Assets.xcassets 读取。原因：
    /// 1. 内置色不需要额外维护颜色资源文件；
    /// 2. 内置色在 Light / Dark 模式下有系统级的自动适配；
    /// 3. 与 `ColorPicker` / `ForegroundStyle` 等 API 天然兼容。
    var swiftUIColor: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .mint:   return .mint
        case .teal:   return .teal
        case .cyan:   return .cyan
        case .blue:   return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink:   return .pink
        case .brown:  return .brown
        }
    }

    /// 按 Agent 的 `UUID` 确定性地分配一个颜色。
    ///
    /// **为什么需要这个方法？**
    /// - 旧版本数据可能没有 `colorName` 字段（`Codable` 解码后为空串 `""`），
    ///   或存储了非法/已经移除的颜色名；
    /// - 此时必须有一个"永不返回 nil"的兜底逻辑，保证 UI 渲染不崩溃；
    /// - 用 `abs(id.hashValue) % allCases.count` 取模，确保同一 id 每次返回同一颜色
    ///   （App 重启或数据迁移后颜色不变，用户不会看到颜色"漂移"）。
    ///
    /// **边界情况：** `allCases` 在编译期固定为 12 个，除数为 0 不可能发生。
    ///
    /// 调用位置：`AgentConfig.color` 的 getter（当 `colorName` 非法时回退）。
    static func `default`(for id: UUID) -> AgentColor {
        allCases[abs(id.hashValue) % allCases.count]
    }

    /// 为新建 Agent 分配一个"下一个"颜色。
    ///
    /// **设计意图：** 直接取模 `agents.count` 实现轮转（round-robin），
    /// 第 1 个 Agent 得红色、第 2 个橙色……第 13 个回到红色。
    /// 这比纯随机或全用 `default(for:)` 更直观：用户在列表中看到的 Agent
    /// 颜色与创建顺序相关，容易辨识"新加入的 Agent"。
    ///
    /// **注意：** 如果中间删除了 Agent，`agents.count` 变小，会导致颜色前移。
    /// 这在产品上可接受（新建的 Agent 会优先使用已被释放的前面颜色）。
    ///
    /// 调用位置：`AgentConfigStore.addAgent(...)` / 新建 Agent 的 ViewModel。
    static func next(after agents: [AgentConfig]) -> AgentColor {
        allCases[agents.count % allCases.count]
    }
}
