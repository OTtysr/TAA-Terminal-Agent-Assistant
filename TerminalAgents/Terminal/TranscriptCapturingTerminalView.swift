import Foundation
import AppKit
import SwiftTerm

/// 终端视图：在渲染终端的同时，把 PTY 输出字节追加落盘到 transcript 文件。
///
/// 继承自 SwiftTerm 的 `LocalProcessTerminalView`，在关键生命周期点注入自定义逻辑：
///
/// 1. **延迟进程启动**：不在初始化时启动，等 `viewDidMoveToWindow` 拿到非零尺寸
/// 2. **transcript 采集**：`dataReceived` 中把 PTY 输出字节追加到 transcript 文件
/// 3. **自动 Enter**：恢复模式下自动发送 Enter 跳过 Agent 的信任确认
/// 4. **安全关闭**：`synchronizeAndClose` 刷盘 + 关闭句柄（deinit 中自动调用）
///
/// ## 延迟进程启动的必要性
///
/// SwiftTerm 内部 `startProcess` 会配置 PTY 的行列尺寸。如果 frame = .zero 时调用，
/// PTY cols/rows = 0 → 终端输出完全空白（不显示任何文字）。
/// 这是 PTY 的 POSIX 行为，不是 SwiftTerm 的 bug。
///
/// 解法：
/// ```
/// TerminalManager.createAndStart:
///   view.prepare(command, env, dir)   ← 暂存参数
///   [NSView 挂入窗口 → frame 有值 → viewDidMoveToWindow 被调用]
///   → startProcess(executable, args, env, dir)  ← 此时尺寸已就绪
/// ```
///
/// ## Transcript 采集
///
/// `dataReceived(slice:)` 是 SwiftTerm 的输出回调，每当 PTY 有数据输出时调用。
/// 我们在调用 `super.dataReceived`（正常渲染）之后，将相同字节追加写入 transcript 文件。
///
/// 文件写入策略：
/// - 每次输出都写入（不缓存，避免崩溃时丢失数据）
/// - 每 30 秒（AppState 控制）调用 `flush()` 执行 fsync
/// - 进程退出 / session 关闭时调用 `synchronizeAndClose()`
///
/// ## 自动 Enter 机制
///
/// `--resume` 恢复已有对话时，Agent（如 Claude Code）通常会请求用户信任确认。
/// 我们预设了信任，因此等 Agent 启动完成（约 4 秒）后自动发送 Enter 跳过确认。
///
/// 时机选择 4 秒的依据：
/// - Agent 进程从 fork 到加载配置文件约 1-2 秒
/// - PTY 初始化约 0.5 秒
/// - 输出信任确认提示约 0.5-1 秒
/// - 总计约 3-4 秒，4 秒给出足够的余量
/// - 过早的 Enter 会被终端缓冲忽略（Agent 还没准备好读取）
///
/// ## 与相关文件的联系
///
/// - `TerminalManager`：创建本视图实例，配置 font/color/handle，调用 `prepare()` 和 `close()`
/// - `SessionProcessDelegate`：设置为 `processDelegate`，监听进程退出
/// - `Store`：提供 transcript 写入 FileHandle
/// - `TerminalViewRepresentable`：在 reattach 中将本视图挂入 SwiftUI 容器
final class TranscriptCapturingTerminalView: LocalProcessTerminalView {

    /// Transcript 写入句柄（由 Store.openTranscript 创建，不清空文件，只追加）。
    ///
    /// 为 nil 时 transcript 功能禁用（不写入文件，但终端渲染正常）。
    /// 典型场景：测试模式、或用户关闭了 transcript 记录。
    var transcriptHandle: FileHandle?

    // MARK: - 延迟启动参数（视图挂窗后才真正 startProcess）

    /// 待启动的命令字符串（prepare 时填入，启动后置 nil 释放内存）。
    private var pendingCommand: String?
    /// 待注入的环境变量（prepare 时填入，启动后置 nil）。
    /// 格式：`["KEY=VALUE", ...]`，已包含用户 shell 环境 + TERM + COLORTERM。
    private var pendingEnv: [String]?
    /// 待启动的工作目录（prepare 时填入，启动后置 nil）。
    private var pendingDir: String?
    /// 是否已启动过进程（防止 viewDidMoveToWindow 重复启动）。
    private var started = false
    /// 恢复模式下，启动后自动发送 Enter 跳过 Agent 的信任确认提示。
    ///
    /// 由 `TerminalManager.createAndStart(autoEnter:)` 参数控制，
    /// 当前仅对 Claude Code 启用，用于自动同意启动/恢复时的信任确认。
    var autoEnter = false
    /// 最近一小段 PTY 输出文本，用于检测 Claude Code 的信任确认提示。
    private var recentOutput = ""
    /// 防止同一轮启动重复自动确认。
    private var didAutoAcceptPrompt = false
    /// 后台恢复启动后，首次挂回真实窗口时需要提示 TUI 重新按真实列宽绘制。
    private var needsRedrawAfterDetachedAttach = false
    /// 避免同一次恢复反复发送重绘按键。
    private var didRedrawAfterDetachedAttach = false

    /// 填入启动信息（不立即启动，等挂窗后由 `viewDidMoveToWindow` 触发）。
    ///
    /// 这是 `TerminalManager.createAndStart` 在创建视图后调用的方法。
    /// 参数在此暂存，不调用 `startProcess`：
    /// - frame 在挂窗前是 .zero，提前启动 PTY 会拿到 0 尺寸 → 输出空白
    /// - 视图可能还没添加到窗口（NSView 的 window 为 nil），挂窗后才可用
    ///
    /// - Parameters:
    ///   - command: 要执行的命令串（可能包含管道、变量等）
    ///   - env: 环境变量数组，格式 `["KEY=VALUE", ...]`
    ///   - dir: 工作目录（目前固定为 NSHomeDirectory()）
    ///   - autoEnter: 是否在启动后自动发送 Enter
    func prepare(command: String, env: [String], dir: String, autoEnter: Bool = false) {
        pendingCommand = command
        pendingEnv = env
        pendingDir = dir
        self.autoEnter = autoEnter
    }

    /// 对后台恢复出来、暂时没有挂窗的终端做兜底启动。
    ///
    /// 自动恢复会一次性创建多个标签，但 SwiftUI 只会挂载当前选中的那个终端视图。
    /// 如果后台标签永远等 `viewDidMoveToWindow()`，它们会被持久化成 running，却实际
    /// 没有任何 PTY 进程。这里用稳定的默认尺寸启动后台 PTY；之后真正挂窗时会按窗口
    /// 尺寸重新 resize。
    func startPendingProcessDetachedIfNeeded() {
        guard !started, pendingCommand != nil else { return }
        needsRedrawAfterDetachedAttach = true
        startPendingProcessIfNeeded(useFallbackSize: true)
    }

    /// NSView 生命周期：视图挂入窗口时调用。
    ///
    /// ## 核心逻辑
    ///
    /// 1. 调用 `super.viewDidMoveToWindow()`：确保 SwiftTerm 内部生命周期正常
    /// 2. 检查三个条件同时满足才启动进程：
    ///    - `self.window != nil`：视图确实挂入了某个窗口
    ///    - `!started`：未重复启动（防御性，避免多窗口场景重复调用）
    ///    - `pendingCommand != nil`：`prepare()` 已被调用
    /// 3. 调用 `startProcess(executable:args:environment:currentDirectory:)`
    /// 4. 清空 `pendingCommand` / `pendingEnv` / `pendingDir`（释放内存，防止误用）
    /// 5. 若 `autoEnter == true` → 延迟 4 秒后发送 `\r`（Enter 键）
    ///
    /// ## started 标志位的重要性
    ///
    /// SwiftUI 多窗口场景可能触发多次 `viewDidMoveToWindow`（容器被不同 representable
    /// 认领、窗口展示与隐藏等）。`started` 标志位保证 PTY 进程只启动一次。
    ///
    /// ## 窗口退出时
    ///
    /// `viewDidMoveToWindow` 在视图被移出窗口时也会调用（此时 `self.window == nil`）。
    /// 不会触发启动逻辑，因为 `window != nil` 条件不满足。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil {
            TerminalTheme.enableMetalIfAvailable(on: self)
        }
        // 视图进入窗口且尚未启动过 → 此刻尺寸已就绪，启动 PTY 进程
        if self.window != nil {
            startPendingProcessIfNeeded(useFallbackSize: false)
            scheduleSizeSynchronizationAfterAttach()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if oldSize != newSize {
            scheduleSizeSynchronizationAfterAttach()
        }
    }

    /// 视图从后台恢复容器重新挂入窗口后，显式把真实 view size 同步给 SwiftTerm 与 PTY。
    func scheduleSizeSynchronizationAfterAttach() {
        let delays: [TimeInterval] = [0, 0.06, 0.22]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.synchronizeSizeAfterAttach()
            }
        }
    }

    private func synchronizeSizeAfterAttach() {
        guard window != nil, frame.width >= 80, frame.height >= 80 else { return }
        layoutSubtreeIfNeeded()
        let changed = synchronizeSizeWithCurrentFrame(forceNotify: true)
        if changed {
            needsDisplay = true
        }
        redrawDetachedTUIIfNeeded(sizeChanged: changed)
    }

    private func redrawDetachedTUIIfNeeded(sizeChanged: Bool) {
        guard started,
              needsRedrawAfterDetachedAttach,
              !didRedrawAfterDetachedAttach,
              window != nil else { return }
        didRedrawAfterDetachedAttach = true
        needsRedrawAfterDetachedAttach = false
        DispatchQueue.main.asyncAfter(deadline: .now() + (sizeChanged ? 0.04 : 0.12)) { [weak self] in
            guard let self, self.window != nil else { return }
            self.insertText("\u{0c}", replacementRange: NSRange())
        }
    }

    private func startPendingProcessIfNeeded(useFallbackSize: Bool) {
        guard !started, let cmd = pendingCommand else { return }
        if useFallbackSize {
            ensureUsableDetachedSize()
        }
        started = true
        startProcess(executable: "/bin/zsh",
                     args: ["-lic", cmd],
                     environment: pendingEnv ?? [],
                     currentDirectory: pendingDir ?? NSHomeDirectory())
        pendingCommand = nil
        pendingEnv = nil
        pendingDir = nil
        // Claude Code：等 Agent 启动完成（约 4 秒）后自动按 Enter 作为兜底。
        // 常规路径会在 dataReceived 中检测到确认提示后立即回车。
        if autoEnter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.autoAcceptClaudePromptIfNeeded(force: true)
            }
        }
    }

    private func ensureUsableDetachedSize() {
        if frame.width < 100 || frame.height < 100 {
            frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        }
        if getTerminal().cols < 20 || getTerminal().rows < 10 {
            resize(cols: 120, rows: 36)
        }
    }

    /// SwiftTerm 回调：PTY 有数据输出时调用。
    ///
    /// ## 数据流
    ///
    /// ```
    /// PTY 子进程 stdout/stderr → 内核 PTY 缓冲区 → SwiftTerm 读取
    ///   → 1. super.dataReceived(slice)  ← 喂给终端渲染引擎（屏幕显示）
    ///   → 2. transcriptHandle.write(slice) ← 追加写入 transcript 文件
    /// ```
    ///
    /// ## 为什么在 super 之后写入
    ///
    /// 顺序不影响正确性（两个操作独立），但先渲染给用户看到再落盘更符合心理预期。
    /// 如果写入失败（文件系统满等），终端渲染不受影响。
    ///
    /// ## 性能考虑
    ///
    /// - 每次输出都写入文件（不缓存），避免 crash 时丢失数据
    /// - `write(contentsOf:)` 是系统调用级写入，无用户态缓冲
    /// - 高频输出（如 cat 大文件）可能产生大量小写入 → `flush()` 定期执行 fsync 合并
    /// - `Data(slice)` 从 `ArraySlice<UInt8>` 创建 Data 对象，零拷贝（Swift Foundation 保证）
    ///
    /// - Parameter slice: PTY 输出的字节片断
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)           // 照常喂给终端渲染
        if let h = transcriptHandle {
            try? h.write(contentsOf: Data(slice))   // 追加到 transcript 文件
        }
        if autoEnter {
            observeOutputForClaudePrompt(slice)
        }
    }

    /// 观察 Claude Code 输出中的信任/继续提示，命中后自动回车确认。
    private func observeOutputForClaudePrompt(_ slice: ArraySlice<UInt8>) {
        guard let chunk = String(data: Data(slice), encoding: .utf8), !chunk.isEmpty else { return }
        recentOutput += Self.cleanControlSequences(chunk).lowercased()
        if recentOutput.count > 6000 {
            recentOutput = String(recentOutput.suffix(6000))
        }
        autoAcceptClaudePromptIfNeeded(force: false)
    }

    /// 自动确认 Claude Code 的启动/恢复提示。
    ///
    /// - Parameter force: true 时用于启动后的兜底回车；false 时只在检测到提示文案后回车。
    private func autoAcceptClaudePromptIfNeeded(force: Bool) {
        guard autoEnter, !didAutoAcceptPrompt else { return }
        guard force || Self.looksLikeClaudeConfirmationPrompt(recentOutput) else { return }
        didAutoAcceptPrompt = true
        let input = Self.looksLikeYesNoPrompt(recentOutput) ? "y\r" : "\r"
        insertText(input, replacementRange: NSRange())
    }

    /// 粗略剥掉 ANSI 控制序列，方便在 PTY 原始输出中匹配提示文本。
    private static func cleanControlSequences(_ s: String) -> String {
        var r = s
        r = strip(r, "\u{1B}\\][^\u{0007}\u{1B}\n]*(?:\u{0007}|\u{1B}\\\\)?")
        r = strip(r, "\u{1B}[PX^_][^\u{1B}]*\u{1B}\\\\")
        r = strip(r, "\u{1B}\\[[0-9;:<=>?]*[ -/]*[@-~]")
        r = strip(r, "\u{1B}[()*+.][A-Za-z0-9]")
        r = strip(r, "\u{1B}[=>78DEHMNOPZc]")
        return strip(r, "\u{1B}")
    }

    /// Claude Code 常见的信任/继续确认提示特征。
    private static func looksLikeClaudeConfirmationPrompt(_ output: String) -> Bool {
        let mentionsClaude = output.contains("claude")
        let asksTrust = output.contains("trust") || output.contains("trusted")
        let asksProceed = output.contains("proceed") || output.contains("continue")
        let asksConfirm = output.contains("confirm") || output.contains("permission")
        let hasPositiveChoice = output.contains("yes") || output.contains("press enter") || output.contains("enter to")
        return mentionsClaude && (asksTrust || asksProceed || asksConfirm) && hasPositiveChoice
    }

    private static func looksLikeYesNoPrompt(_ output: String) -> Bool {
        output.contains("y/n") ||
        output.contains("yes/no") ||
        output.contains("[y") ||
        output.contains("(y")
    }

    private static func strip(_ s: String, _ pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s), withTemplate: "")
    }

    /// 运行中刷盘：执行 fsync 将缓冲数据写入磁盘，但**保持句柄打开**。
    ///
    /// ## 与 synchronizeAndClose 的区别
    ///
    /// | 方法 | 操作 | 句柄状态 | 调用场景 |
    /// |------|------|----------|----------|
    /// | `flush()` | fsync | 保持打开 | 定时刷盘（每 30s）、App 进入后台 |
    /// | `synchronizeAndClose()` | fsync + close | 关闭 | 会话关闭、App 退出 |
    ///
    /// 分开的原因：会话仍在运行时需要持续写入，关闭句柄会丢失后续数据。
    /// 但长时间不刷盘会导致系统崩溃时丢失数据（FileHandle 写入可能在内核缓冲区中）。
    ///
    /// 调用方：`TerminalManager.flushAll()`（在主线程调用，App 定时触发）
    func flush() {
        try? transcriptHandle?.synchronize()
    }

    /// 刷盘并关闭 transcript 句柄（幂等操作）。
    ///
    /// ## 幂等性
    ///
    /// 方法内部判断 `transcriptHandle != nil`，关闭后置 nil。
    /// 多次调用安全（第二次调用时 handle 已是 nil，什么都不做）。
    ///
    /// ## 操作顺序（重要）
    ///
    /// 1. `synchronize()`：先 fsync 确保数据落到磁盘
    /// 2. `close()`：关闭文件描述符，释放内核资源
    /// 3. `transcriptHandle = nil`：标记为已关闭，防止重复 close
    ///
    /// 不能先 close 再 sync：close 释放了文件描述符，后续 sync 操作在无效 fd 上执行
    /// 会产生 `EBADF`（Bad file descriptor）错误。
    ///
    /// ## 调用场景
    ///
    /// - `TerminalManager.close()`：session 被主动关闭
    /// - 本类的 `deinit`：SwiftTerm 视图被释放时自动触发
    /// - App 退出前最后一次 flush（在 flushAll 之后）
    func synchronizeAndClose() {
        if let h = transcriptHandle {
            try? h.synchronize()
            try? h.close()
            transcriptHandle = nil
        }
    }

    /// 析构时安全关闭 transcript 句柄。
    ///
    /// 这是最后的安全网：如果调用方忘记显式调用 `synchronizeAndClose()`，
    /// Swift 的 ARC 会在视图被释放时自动调用 deinit → 关闭句柄。
    ///
    /// 注意：deinit 中的 `synchronizeAndClose()` 可能在某些边缘情况下失败
    /// （如 FileHandle 已被其他地方关闭），但由于方法内部 try? 吞掉了错误，
    /// 不会导致析构异常。
    deinit {
        synchronizeAndClose()
    }
}
