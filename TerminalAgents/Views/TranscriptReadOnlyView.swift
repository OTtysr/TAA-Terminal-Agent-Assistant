import SwiftUI
import SwiftTerm

/// 只读 transcript 视图。
///
/// 原始 transcript 是 PTY 的**原始字节流**（含 ANSI 转义、光标定位、全屏 TUI 重绘）。
/// 早期版本用正则剥转义 → 单词全挤在一起（`Accessingworkspace:`），因为 TUI 靠光标跳格摆位、
/// 不是输出空格；正则剥掉 ESC 后空格也丢了。
///
/// 正解：把原始字节**喂回一个无头 SwiftTerm Terminal 实例**重放出最终屏幕，再逐单元格读出——
/// 光标定位被模拟器正确应用（空格回来）、单元格属性保留（颜色回来）。此为 vendored SwiftTerm
/// 的核心价值：拥有完整的终端模拟能力，而非仅 ANSI 剥离正则。
///
/// 性能策略：
/// - **256KB 截断**：截取 transcript 末尾 256KB 重放，避免超长 transcript 卡 UI。
/// - **@State 驱动**：重放结果缓存在 `@State` 中，`.task(id:)` 仅在 ref 变化时重触发。
/// - **兜底正则**：当无头重放失败时（如数据损坏），退化为 `clean()` 纯文本清洗。
///
/// 关联文件：
/// - `TerminalPaneView.swift`：在会话关闭且不支持恢复时渲染本视图。
/// - `SessionWindowView.swift`：独立窗口中关闭会话也会回退到本视图。
/// - `AppState.swift`：`store.readTranscript(for:)` 提供原始字节数据。
/// - `Store.swift`：transcript 文件管理和引用映射。
struct TranscriptReadOnlyView: View {
    /// transcript 引用（由 Store.transcriptRef 生成，对应磁盘文件名）。
    /// nil 表示该会话尚未产生 transcript（如 Agent 启动失败）。
    let ref: String?
    /// 全局应用状态（@EnvironmentObject 由父视图注入）。
    @EnvironmentObject var appState: AppState
    /// 重放后的带颜色 AttributedString（无头终端成功时赋值）。
    @State private var attributed: AttributedString?
    /// 兜底纯文本（无头终端失败时由 `clean()` 产生）。
    @State private var plainFallback: String = ""
    private var theme: TerminalTheme.Style {
        TerminalTheme.style(for: appState.terminalThemeMode)
    }

    var body: some View {
        ScrollView {
            Group {
                if let attributed {
                    // 主路径：无头终端重放成功 → 带颜色的 AttributedString
                    Text(attributed)
                } else {
                    // 兜底路径：正则清洗后的纯文本
                    Text(plainFallback)
                }
            }
            .font(.system(size: 13.5, design: .monospaced)) // 等宽字体
            .foregroundStyle(Color(nsColor: theme.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled) // 允许用户选中复制
            .padding(.horizontal, TerminalTheme.horizontalPadding)
            .padding(.vertical, TerminalTheme.verticalPadding)
        }
        .background(Color(nsColor: theme.background)) // 终端背景色
        .overlay {
            // 无数据时的占位提示（attributed 和 plainFallback 都为空）
            if attributed == nil && plainFallback.isEmpty {
                ContentUnavailableView(appState.text(.noTranscript),
                    systemImage: "doc.text",
                    description: Text(appState.text(.noTranscriptDescription)))
            }
        }
        // 当 ref 变化时（如用户切换会话），自动触发重放
        .task(id: ref) { render() }
    }

    /// 从磁盘读取 transcript 数据并重放为 AttributedString。
    ///
    /// 流程：
    /// 1. 通过 `AppState.store.readTranscript(for:)` 读取原始字节。
    /// 2. 截取末尾 256KB 数据（避免超长 transcript 卡 UI）。
    /// 3. 尝试 `ReplayRenderer.render()` 无头终端重放。
    /// 4. 成功 → 赋值 `attributed`，清空 `plainFallback`。
    /// 5. 失败 → 回退 `clean()` 正则清洗，赋值 `plainFallback`，清空 `attributed`。
    private func render() {
        guard let data = appState.store.readTranscript(for: ref), !data.isEmpty else {
            attributed = nil; plainFallback = ""; return
        }
        // 截取末尾 256KB 重放，避免超长 transcript 卡 UI
        let feedData = data.count > 262_144 ? data.suffix(262_144) : data
        if let attr = ReplayRenderer.render(Data(feedData)), !attr.characters.isEmpty {
            attributed = attr
            plainFallback = ""
        } else {
            // 兜底：重放失败时退化为纯文本清洗
            let raw = String(decoding: feedData, as: UTF8.self)
            plainFallback = Self.clean(raw)
            attributed = nil
        }
    }

    /// 兜底纯文本清洗（仅在无头重放失败时使用）。
    ///
    /// 多层正则剥离 ANSI 转义序列：
    /// 1. OSC 序列（如窗口标题修改 `\x1b]0;...`）
    /// 2. DCS/SOS/PM/APC 字符串
    /// 3. CSI 序列（颜色、光标控制）
    /// 4. 字符集选择序列
    /// 5. 设备控制序列
    /// 6. 单独的 ESC
    /// 7. ASCII 控制字符（除 tab/lf/cr）
    ///
    /// 清洗后还会：去除行尾空白、合并连续空行为最多一个、裁掉首尾空行。
    static func clean(_ s: String) -> String {
        var r = s
        r = strip(r, "\u{1B}\\][^\u{0007}\u{1B}\n]*(?:\u{0007}|\u{1B}\\\\)?")
        r = strip(r, "\u{1B}[PX^_][^\u{1B}]*\u{1B}\\\\")
        r = strip(r, "\u{1B}\\[[0-9;:<=>?]*[ -/]*[@-~]")
        r = strip(r, "\u{1B}[()*+.][A-Za-z0-9]")
        r = strip(r, "\u{1B}[=>78DEHMNOPZc]")
        r = strip(r, "\u{1B}")
        r = strip(r, "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}]")
        let lines = r.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
        var out: [String] = []; var blank = 0
        for ln in lines {
            if ln.isEmpty { blank += 1; if blank <= 1 { out.append(ln) } }
            else { blank = 0; out.append(ln) }
        }
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// 对字符串应用正则替换（删除匹配部分）。
    /// - Parameters:
    ///   - s: 源字符串。
    ///   - pattern: 正则模式。
    /// - Returns: 删除所有匹配后的字符串。
    private static func strip(_ s: String, _ pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s), withTemplate: "")
    }
}

/// 无头终端重放器：把原始 PTY 字节喂进一个离线 SwiftTerm `Terminal`，
/// 按单元格读出最终屏幕，渲染成带颜色的 `AttributedString`。
///
/// 为什么用 vendored SwiftTerm 而不是正则解析？
/// —— TUI 程序（如 Claude Code、vim）大量使用光标定位（CSI n;m H）和区域重绘，
/// 仅靠正则剥离 ANSI 转义会导致文本错位和空白丢失。完整模拟终端网格布局后逐格
/// 读取才能还原原始视觉效果。
///
/// 关联文件：
/// - `TranscriptReadOnlyView.swift`：调用 `ReplayRenderer.render()` 产出 AttributedString。
/// - `SwiftTerm`（vendored）：整个 vendored 模块的存在理由就是让此重放器能以 100% 保真度还原 TUI 输出。
enum ReplayRenderer {
    /// 重放终端列数：130 列容纳常见 TUI（Claude Code 默认约 120 列，留余量）。
    static let cols = 130
    /// 重放终端行数：300 行以完整容纳单屏 TUI 输出（超出部分走 scrollback）。
    /// 取较大值而非真实终端行数，确保 TUI 全屏内容不被截断。
    static let rows = 300

    /// 将原始 PTY 字节数据重放为带 ANSI 颜色的 AttributedString。
    ///
    /// 流程：
    /// 1. 创建 `HeadlessDelegate`（无 UI 输出的 delegate）。
    /// 2. 配置 `TerminalOptions`（130x300 网格 + 4000 行 scrollback）。
    /// 3. 创建离线 `Terminal` 实例并喂入字节数据。
    /// 4. 调用 `buildAttributed(from:)` 读取终端网格生成 AttributedString。
    ///
    /// - Parameter data: 原始 PTY 输出字节（含 ANSI 转义、TUI 重绘等）。
    /// - Returns: 带颜色的 AttributedString，或 nil（数据为空/损坏）。
    static func render(_ data: Data) -> AttributedString? {
        let delegate = HeadlessDelegate()
        var opts = TerminalOptions.default
        opts.cols = cols
        opts.rows = rows
        opts.scrollback = 4000                      // 4000 行回滚缓冲
        opts.convertEol = true                       // 自动转换换行符
        let term = Terminal(delegate: delegate, options: opts)
        term.feed(byteArray: [UInt8](data))          // 喂入字节
        return buildAttributed(from: term)
    }

    /// 从终端网格逐行逐列读取单元格，按属性分片合并为 AttributedString。
    ///
    /// 输出格式：
    /// - 每行扫描 `cols` 列，找到最后一个非空字符位置（裁掉右侧尾随空白）。
    /// - 相邻同属性（颜色、样式）单元格合并为一个 AttributedString run。
    /// - 空行重复最多保留 1 行（压缩空白）。
    /// - 首行之前和末行之后的空白都会被裁掉。
    ///
    /// - Parameter term: 已喂入数据的 Terminal 实例。
    /// - Returns: 完整 AttributedString，或 nil（没有有效内容）。
    private static func buildAttributed(from term: Terminal) -> AttributedString? {
        var result = AttributedString()
        var consecutiveBlank = 0
        var sawContent = false

        for row in 0..<rows {
            // 找该行最后一个非空单元格，裁掉右侧尾随空白
            var lastNonBlank = -1
            for col in 0..<cols {
                guard let cd = term.getCharData(col: col, row: row) else { continue }
                let ch = term.getCharacter(for: cd)
                guard ch != " ", ch != "\0" else { continue }
                lastNonBlank = col
            }

            if lastNonBlank < 0 {
                if sawContent {
                    consecutiveBlank += 1
                    if consecutiveBlank <= 1 { result.append(AttributedString("\n")) }
                }
                continue
            }
            sawContent = true
            consecutiveBlank = 0

            // 按属性分片：相邻同属性单元格合并为一个 run
            var runText = ""
            var runAttr: Attribute? = nil
            for col in 0...lastNonBlank {
                let cd = term.getCharData(col: col, row: row)
                let ch = cd.map { term.getCharacter(for: $0) } ?? " "
                let attr = cd?.attribute ?? Attribute.empty
                if attr == runAttr {
                    runText.append(ch)
                } else {
                    flush(runText, runAttr, into: &result)
                    runText = String(ch)
                    runAttr = attr
                }
            }
            flush(runText, runAttr, into: &result)
            result.append(AttributedString("\n"))
        }

        return result.characters.isEmpty ? nil : result
    }

    /// 将一个属性分片的文本写入 AttributedString。
    ///
    /// - Parameters:
    ///   - text: 该分片的文本内容。
    ///   - attr: SwiftTerm `Attribute`（包含前景色、粗体/斜体/下划线样式）。
    ///   - result: 累积输出的 AttributedString。
    private static func flush(_ text: String, _ attr: Attribute?, into result: inout AttributedString) {
        guard !text.isEmpty, let attr else { return }
        var seg = AttributedString(text)
        let bold = attr.style.contains(.bold)
        // 前景色（粗体时对低 8 色自动提升为亮色，模拟 xterm bold-is-bright 行为）
        if let c = color(for: attr.fg, bold: bold) {
            seg.foregroundColor = c
        }
        // 粗体样式
        if attr.style.contains(.bold) {
            seg.font = .system(.callout, design: .monospaced).bold()
        }
        // 斜体样式
        if attr.style.contains(.italic) {
            seg.font = .system(.callout, design: .monospaced).italic()
        }
        // 下划线样式
        if attr.style.contains(.underline) {
            seg.underlineStyle = .single
        }
        result.append(seg)
    }

    /// SwiftTerm `Attribute.Color` → SwiftUI `Color` 转换。
    ///
    /// 颜色来源：
    /// - `.defaultColor` / `.defaultInvertedColor`：使用终端默认前景色（nil，由 Text 继承）。
    /// - `.ansi256(code)`：从标准 xterm 256 色查找表取色，
    ///   粗体时低 8 色 (0-7) 自动推到亮色范围 (8-15)，模拟终端 bold-is-bright 行为。
    /// - `.trueColor(r, g, b)`：直接映射为 SwiftUI RGB Color。
    ///
    /// - Parameters:
    ///   - c: SwiftTerm 颜色枚举。
    ///   - bold: 是否粗体（用于 bright 颜色提升）。
    /// - Returns: SwiftUI Color，或 nil（使用默认色）。
    private static func color(for c: Attribute.Color, bold: Bool) -> SwiftUI.Color? {
        switch c {
        case .defaultColor, .defaultInvertedColor:
            return nil
        case .ansi256(let code):
            let resolved = (bold && code < 8) ? code + 8 : code
            return ansi256(Int(resolved))
        case .trueColor(let r, let g, let b):
            return SwiftUI.Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
        }
    }

    /// 标准 xterm 256 色调色板查找。
    ///
    /// 色域划分：
    /// - **0-15**：系统标准色（8 个基本色 + 8 个亮色）。
    /// - **16-231**：216 色阶（6×6×6 RGB 立方体，每通道 6 级）。
    /// - **232-255**：24 级灰度。
    ///
    /// - Parameter idx: 颜色索引（0-255）。
    /// - Returns: 对应的 SwiftUI Color。
    private static func ansi256(_ idx: Int) -> SwiftUI.Color {
        if idx < 16 {
            let pal: [(Double, Double, Double)] = [
                (0,0,0),(128,0,0),(0,128,0),(128,128,0),(0,0,128),(128,0,128),(0,128,128),(192,192,192),
                (128,128,128),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)
            ]
            let p = pal[idx]
            return SwiftUI.Color(red: p.0/255, green: p.1/255, blue: p.2/255)
        }
        if idx < 232 {
            let i = idx - 16
            let r = i / 36, g = (i / 6) % 6, b = i % 6
            let v: (Int) -> Double = { $0 == 0 ? 0 : Double(40 * $0 + 55) }
            return SwiftUI.Color(red: v(r)/255, green: v(g)/255, blue: v(b)/255)
        }
        let gray = Double(8 + (idx - 232) * 10) / 255
        return SwiftUI.Color(red: gray, green: gray, blue: gray)
    }
}

/// 无头 `TerminalDelegate`：只实现必需的 `send`（空操作），其余走协议默认实现。
///
/// 在离线重放中，Terminal 不需要向 PTY 发送任何输入（因为只是渲染历史输出），
/// 所以 `send(source:data:)` 为空操作。其他 delegate 方法（如 `bell`、`titleChanged`、
/// `sizeChanged` 等）由 TerminalDelegate 协议默认实现处理，均不影响重放结果。
///
/// 关联文件：
/// - `TerminalManager.swift`：在线会话使用 `TerminalManager.SessionDelegate`
///   实现完整的 PTY 读写 delegate。
final class HeadlessDelegate: TerminalDelegate {
    /// 空白发送操作：重放不需要向 PTY 发送数据。
    func send(source: Terminal, data: ArraySlice<UInt8>) { }
}
