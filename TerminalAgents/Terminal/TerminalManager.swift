import Foundation
import AppKit
import SwiftTerm

/// 终端管理器：持有所有活跃会话的 PTY 终端视图，管理其全生命周期。
///
/// ## 核心设计理念
///
/// 终端视图的生命周期**独立于 SwiftUI 视图**：
/// - NSView 只创建一次，PTY 进程始终运行
/// - 切换标签 / 窗口只改变「哪个视图在展示」，不重建 PTY
/// - 这是通过 `TerminalViewRepresentable` 的 reattach 机制实现的
///
/// ## 架构数据流
///
/// ```
/// AppState
///   └── terminalManager: TerminalManager    ← 本类
///         ├── views: [UUID: TranscriptCapturingTerminalView]  ← PTY 持有
///         └── delegates: [UUID: SessionProcessDelegate]        ← 生命周期代理
///
/// TerminalViewRepresentable(sessionID)
///   └── makeNSView → NSView 容器
///         └── terminalManager.view(for: sessionID) 挂入容器
/// ```
///
/// ## 并发安全
///
/// 标记 `@MainActor` 因为：
/// - 字典 `views` 和 `delegates` 的读写必须在主线程（同时创建/操作的还有 NSView）
/// - `TranscriptCapturingTerminalView` 继承自 `NSView`，必须在主线程操作
/// - `flushAll()` 由 `AppState` 在主线程调用
///
/// ## 资源护栏
///
/// `maxActive` = 8：限制同时运行的 PTY 进程数。每个 zsh 子进程消耗 50-100MB 内存，
/// 不做限制可能导致内存压力过大。超出上限时，AppState 应拒绝创建新会话或关闭最老的。
///
/// ## 与相关文件的联系
///
/// - `TranscriptCapturingTerminalView`：终端视图类型，持有 PTY 进程和 transcript FileHandle
/// - `SessionProcessDelegate`：监听进程退出
/// - `Store`：持久化 transcript 文件（openTranscript）
/// - `TerminalViewRepresentable`：SwiftUI 桥接
/// - `AppState`：持有 TerminalManager 实例
@MainActor
final class TerminalManager {

    /// 活跃终端视图字典，key = Session.ID。
    /// 切换标签只是改变「谁在展示」，PTY 进程和视图都保留在此字典中。
    private var views: [UUID: TranscriptCapturingTerminalView] = [:]

    /// 进程退出代理字典，key = Session.ID。
    /// 与 `views` 一一对应：创建时成对创建，关闭时成对释放。
    private var delegates: [UUID: SessionProcessDelegate] = [:]

    /// Store 引用：创建终端时打开 transcript 写入句柄。
    let store: Store

    /// 同时活跃的 PTY 进程上限（资源护栏）。
    ///
    /// 每个 zsh 子进程约 50-100MB RSS，8 个上限意味着 PTY 总计约 400-800MB 上限。
    /// 加上 SwiftTerm 的屏幕缓冲区（每个终端视窗可容纳数千行），
    /// 8 个上限在 M 芯片 Mac 上是安全的。
    static let maxActive: Int = 8

    init(store: Store) { self.store = store }

    /// 创建终端视图、配置进程、注入环境变量，但不立即启动进程。
    ///
    /// ## 流程
    ///
    /// 1. 若该 session 已有旧终端视图 → `close()` 清理（先杀进程，再关 transcript）
    /// 2. 创建 `TranscriptCapturingTerminalView`（frame 初始为零，等挂窗后再布局）
    /// 3. 配置外观（字体、颜色）
    /// 4. 打开 transcript 写入 handle
    /// 5. 创建 `SessionProcessDelegate` 并注册
    /// 6. 注入 TERM/COLORTERM 环境变量
    /// 7. 调用 `view.prepare(...)` 暂存启动参数，**不立即 startProcess**
    ///
    /// ## 为什么不在此处启动进程
    ///
    /// 终端进程需要知道 PTY 的窗口尺寸（行列数）才能正确渲染。
    /// 如果此时（frame = .zero）启动，PTY 初始尺寸为 0，终端的 ANSI 转义序列会
    /// 产生空白输出（表现为「终端没反应」）。
    ///
    /// 进程延迟到 `TranscriptCapturingTerminalView.viewDidMoveToWindow()`
    /// 视图真正挂到窗口并拿到非零 frame 后才启动。
    ///
    /// ## TERM 和 COLORTERM 环境变量
    ///
    /// **这是关键的兼容性修复**：
    ///
    /// SwiftTerm 只在 `environment == nil` 时才自动补 `TERM` 和 `COLORTERM`（调用内部
    /// `getEnvironmentVariables`）。我们传了**非 nil** 的自定义 `env`（为了继承用户 PATH
    /// 等 Shell 环境变量），所以必须手动追加这两个变量。
    ///
    /// 缺少 TERM/COLORTERM 的后果：
    /// - Claude Code / Codex / Aider 等 TUI 应用检测不到终端能力
    /// - 不输出 ANSI 颜色（界面全白/无高亮）
    /// - 交互式光标操作失效
    ///
    /// ## Shell 选择：`/bin/zsh -lic`
    ///
    /// - `-l`：login shell → 加载 `/etc/zprofile` → 继承完整的 PATH（包括 Homebrew 的 `/opt/homebrew/bin`）
    /// - `-i`：interactive → 加载 `.zshrc`（自定义 prompt、alias 等）
    /// - `-c`：执行命令后退出
    ///
    /// `/bin/zsh` 硬编码：不依赖用户 chsh 的设置，确保 shell 始终是 zsh（SwiftTerm 的
    /// POSIX PTY 实现需要 Bourne-compatible shell）。
    ///
    /// - Parameters:
    ///   - session: Session 模型（提取 id、transcriptRef）
    ///   - command: 要执行的命令字符串（可能包含管道、变量、参数等）
    ///   - onTerminated: 进程退出回调闭包
    ///   - autoEnter: 恢复模式下自动发送 Enter 跳过信任确认
    func createAndStart(session: Session,
                        command: String,
                        onTerminated: @escaping (UUID) -> Void,
                        autoEnter: Bool = false,
                        themeMode: TerminalThemeMode = .light,
                        detachedStartDelay: TimeInterval? = nil,
                        environmentOverrides: [String: String] = [:]) {
        // 若该会话已存在旧视图，先清理（包括杀进程和关 transcript 句柄）
        if views[session.id] != nil { close(sessionID: session.id, kill: true) }

        // 创建终端视图（初始 frame = .zero，等挂窗后由 reattach 设置正确尺寸）
        let view = TranscriptCapturingTerminalView(frame: .zero)
        TerminalTheme.apply(to: view, mode: themeMode)

        // 打开 transcript 写入 FileHandle，传给视图在 dataReceived 中追加字节
        if let ref = session.transcriptRef {
            view.transcriptHandle = store.openTranscript(for: ref)
        }

        // 创建进程退出代理（见 SessionProcessDelegate 文档了解线程安全细节）
        let delegate = SessionProcessDelegate(sessionID: session.id, onTerminated: onTerminated)
        view.processDelegate = delegate
        delegates[session.id] = delegate
        views[session.id] = view

        // 用登录 shell 执行用户的命令串，继承 PATH / 环境变量，支持管道/参数/env 等。
        // 注意：不在此处直接 startProcess——进程延迟到视图挂窗、拿到非零尺寸后再启动，
        // 否则 PTY 初始尺寸为 0，终端屏幕会空白（表现为「没反应」）。
        //
        // 关键：必须手动注入 TERM 和 COLORTERM。
        // SwiftTerm 只在 environment==nil 时才自动补这两个变量（调用 getEnvironmentVariables）；
        // 我们传了非 nil 的自定义 env（为了保留用户 PATH 等），所以必须自己加上，
        // 否则 claude/codex/aider 这类 TUI 应用检测不到终端能力 → 不输出 ANSI 颜色。
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        let env = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        view.prepare(command: command, env: env, dir: NSHomeDirectory(), autoEnter: autoEnter)
        if let detachedStartDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + detachedStartDelay) { [weak view] in
                view?.startPendingProcessDetachedIfNeeded()
            }
        }
    }

    /// 根据 session ID 获取终端视图（用于 TerminalViewRepresentable 的 reattach）。
    func view(for id: UUID) -> TranscriptCapturingTerminalView? { views[id] }

    /// 关闭并释放某会话的终端视图和代理。
    ///
    /// ## kill 参数语义
    ///
    /// - `kill: true`：先终止 PTY 进程再关闭（主动关闭 session / App 退出时）
    /// - `kill: false`：进程已自然退出（进程退出回调中二次清理时避免重复 kill）
    ///
    /// ## 操作顺序（重要：先 kill 再 close，避免资源竞争）
    ///
    /// 1. `terminate()`：发送 SIGTERM → 等进程退出（SwiftTerm 内部有超时 + SIGKILL 兜底）
    /// 2. `synchronizeAndClose()`：刷盘 transcript + 关闭 FileHandle
    /// 3. `nil`：释放视图和代理引用
    ///
    /// - Parameters:
    ///   - sessionID: 要关闭的会话 ID
    ///   - kill: 是否终止 PTY 进程
    func close(sessionID: UUID, kill: Bool) {
        if kill { views[sessionID]?.terminate() }
        views[sessionID]?.synchronizeAndClose()
        views[sessionID] = nil
        delegates[sessionID] = nil
    }

    /// 当前活跃终端数量（用于资源护栏检查）。
    var activeCount: Int { views.count }

    /// 立即把新的主题应用到所有已经打开的终端视图。
    func applyTheme(_ mode: TerminalThemeMode) {
        for view in views.values {
            TerminalTheme.apply(to: view, mode: mode)
        }
    }

    /// App 退出 / 进入后台时调用：把所有 transcript 刷盘（不关闭句柄，运行中仍可继续落盘）。
    ///
    /// 为什么只 flush 不 close：
    /// - App 进入后台 → 进程仍在运行，继续落盘
    /// - App 退出 → 后续 `deinit` 或显式 close 再关闭句柄
    /// - 刷盘（fsync）确保 crash 时不丢失已输出的数据
    func flushAll() {
        for v in views.values { v.flush() }
    }
}
