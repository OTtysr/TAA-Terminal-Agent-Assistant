import SwiftUI

/// Agent 添加/编辑表单（Sheet 弹窗）。
///
/// 功能：设置 Agent 的显示名称、启动命令字符串、主题色、历史对话格式与文件匹配路径。
/// 保存时通过 `AppState.saveAgent()` 持久化到 UserDefaults/JSON 存储。
///
/// 使用场景：点击侧边栏 + 按钮（新增）或右键菜单"Edit"（编辑已有 Agent）时弹出。
///
/// 关联文件：
/// - `SidebarView.swift`：触发 `presentNewAgent()` / `presentEditAgent()` 打开本 Sheet。
/// - `AppState.swift`：`saveAgent()`、`editingAgent`、`newAgentRequest` 等状态属性。
struct AgentEditorSheet: View {
    /// 全局应用状态（@EnvironmentObject 由 ContentView 注入，无需显式传递）。
    @EnvironmentObject var appState: AppState
    /// SwiftUI 环境提供的关闭 Sheet 方法（调 `dismiss()` 即可关闭弹窗）。
    @Environment(\.dismiss) private var dismiss

    /// 编辑模式下的已有 Agent（nil 表示新增模式）。
    private let existing: AgentConfig?
    /// 当颜色未设置时的默认颜色名（如 "blue"），由 `AppState.newAgentDefaultColorName` 提供。
    private let defaultColorName: String

    // MARK: - @State 本地编辑状态

    /// Agent 显示名称（双向绑定到 TextField）。
    @State private var name: String
    /// 启动命令字符串（双向绑定到 TextEditor），支持管道、参数、环境变量。
    @State private var commandString: String
    /// 选中的颜色标识符（双向绑定到颜色选择器的 Circle 点击事件）。
    @State private var colorName: String
    /// 历史对话格式（双向绑定到 Picker）——决定如何解析 Agent 的历史记录。
    @State private var historyFormat: HistoryFormat
    /// 历史文件 glob 路径（如 `~/.claude/history/*.jsonl`），用于扫描 Agent 原生历史文件。
    @State private var historyGlob: String

    // MARK: - 初始化

    /// 构造编辑表单。
    /// - Parameters:
    ///   - agent: 要编辑的 Agent（nil = 新增模式）。
    ///   - defaultColorName: 默认颜色名，新增 Agent 时使用。
    ///
    /// `@State` 的初始化使用 `State(initialValue:)` 方式（因为属性包装器不能直接在 init 中赋值）。
    /// 编辑模式下回填已有 Agent 的字段值；新增模式下使用空字符串和默认配置。
    init(agent: AgentConfig?, defaultColorName: String = "blue") {
        self.existing = agent
        self.defaultColorName = defaultColorName
        _name = State(initialValue: agent?.name ?? "")
        _commandString = State(initialValue: agent?.commandString ?? "")
        _colorName = State(initialValue: agent?.colorName ?? defaultColorName)
        _historyFormat = State(initialValue: agent?.historyFormat ?? .auto)
        _historyGlob = State(initialValue: agent?.historyGlob ?? "")
    }

    // MARK: - 计算属性

    /// 去除首尾空白后的名称（用于校验是否为空）。
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 去除首尾空白后的命令字符串（用于校验是否为空）。
    private var trimmedCmd: String { commandString.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 当名称和命令都不为空时允许保存。
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedCmd.isEmpty }

    /// 自动检测到的历史格式提示。
    /// 基于命令字符串中的关键词检测（如 "claude" → `.claudeCode`、"kimi" → `.kimiCode`）。
    /// 当用户选择 `auto` 时，在 UI 中展示检测结果供参考。
    private var detectedFormat: HistoryFormat {
        HistoryFormat.detect(from: trimmedCmd)
    }

    // MARK: - 视图主体

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ---- 标题行：根据新增/编辑模式显示不同文字 ----
            Text(existing == nil ? appState.text(.newAgent) : appState.text(.editAgent))
                .font(.title2.bold())

            // ---- 名称输入区 ----
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.text(.name)).font(.headline)
                TextField("e.g. Claude Code", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            // ---- 启动命令输入区 ----
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.text(.launchCommand)).font(.headline)
                // 使用 TextEditor（支持多行）而非 TextField，因为命令可能含管道、参数很长。
                TextEditor(text: $commandString)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 64, maxHeight: 110)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.35))
                    )
                // 提示：命令会以 login shell 方式执行，支持管道、参数、环境变量。
                Text(appState.text(.launchCommandHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ---- 颜色选择区 ----
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.text(.color)).font(.headline)
                // 水平滚动承载所有预定义颜色（`AgentColor.allCases`），超宽时无需包装。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // 遍历所有可用颜色，每个颜色绘制为一个可点击的 Circle。
                        ForEach(AgentColor.allCases) { c in
                            Circle()
                                .fill(c.swiftUIColor)       // 填充对应颜色
                                .frame(width: 20, height: 20)
                                .overlay(
                                    // 当前选中颜色加粗边框标识；未选中则为透明（clear）。
                                    Circle()
                                        .stroke(colorName == c.rawValue ? Color.primary : Color.clear,
                                                lineWidth: 2)
                                        .padding(-3)
                                )
                                .accessibilityLabel(c.label)          // VoiceOver 可读标签
                                .onTapGesture { colorName = c.rawValue } // 点击选中
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // ---- 历史对话格式（自动检测 + 手动覆盖） ----
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.text(.conversationHistory)).font(.headline)

                HStack(spacing: 10) {
                    // 格式下拉选择器：`menu` 风格（macOS 原生下拉菜单）。
                    Picker(appState.text(.format), selection: $historyFormat) {
                        ForEach(HistoryFormat.allCases, id: \.self) { f in
                            Text(f.label(language: appState.appLanguage)).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    // `.onChange(of:)`：当用户切换格式时，若选中了具体的 Agent 格式（非 auto/none），
                    // 且 glob 字段为空，则自动填入该格式的默认 glob 路径。
                    .onChange(of: historyFormat) { _, f in
                        if f != .none, f != .auto, historyGlob.isEmpty {
                            historyGlob = f.defaultGlob
                        }
                    }

                    // 当格式为 `auto` 时，显示自动检测到的格式信息。
                    if historyFormat == .auto {
                        Text("\(appState.text(.detected)): \(detectedFormat.label(language: appState.appLanguage))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 当格式不为 `none` 时，显示 glob 输入框（用于自定义历史文件匹配路径）。
                if historyFormat != .none {
                    TextField(appState.text(.historyPathGlob), text: $historyGlob)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .help(appState.text(.historyGlobHelp))
                }
            }

            // ---- 操作按钮行 ----
            HStack {
                // 取消按钮：不保存，直接关闭 Sheet。
                Button(appState.text(.cancel), role: .cancel) { dismiss() }
                Spacer()
                // 保存按钮：新增模式显示"Add"，编辑模式显示"Save"。
                Button(existing == nil ? appState.text(.add) : appState.text(.save)) {
                    guard canSave else { return }  // 双重校验：名称和命令不能为空
                    // 以已有 Agent 为基础（新增时构造一个新的），逐个覆盖编辑后的字段。
                    var base = existing ?? AgentConfig(name: trimmedName, commandString: trimmedCmd)
                    base.name = trimmedName
                    base.commandString = trimmedCmd
                    base.colorName = colorName
                    base.historyFormat = historyFormat
                    base.historyGlob = historyGlob.isEmpty ? nil : historyGlob
                    // 调用 AppState 的持久化方法保存 Agent（写入 UserDefaults/JSON）。
                    appState.saveAgent(base)
                    dismiss() // 保存后关闭 Sheet
                }
                .buttonStyle(.borderedProminent) // macOS 强调按钮样式
                .disabled(!canSave)               // 名称或命令为空时禁用
            }
        }
        .padding(20)
        .frame(width: 500) // 固定 Sheet 宽度
    }
}

// MARK: - HistoryFormat 扩展：显示用标签

/// 为 `HistoryFormat` 枚举添加人类可读的中英文混合标签。
/// 用于 Picker 下拉菜单中的选项文字。
private extension HistoryFormat {
    /// 各格式的显示标签。
    func label(language: AppLanguage) -> String {
        switch self {
        case .auto:
            return language == .chinese ? "自动检测" : "Auto-Detect"
        case .none:
            return language == .chinese ? "无（终端重放）" : "None (Terminal Replay)"
        case .claudeCode: return "Claude Code"          // Anthropic Claude Code
        case .kimiCode:   return "KimiCode"             // Moonshot KimiCode
        case .openCode:   return "OpenCode"             // OpenCode
        case .hermes:     return "Hermes"              // Hermes
        case .openClaw:   return "OpenClaw"             // OpenClaw
        }
    }
}
