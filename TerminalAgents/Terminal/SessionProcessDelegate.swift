import Foundation
import SwiftTerm
import AppKit

/// 终端进程代理：监听进程退出事件，转发给 AppState 标记会话关闭。
///
/// ## 在数据流中的位置
///
/// ```
/// TerminalManager.createAndStart()
///   → 创建 TranscriptCapturingTerminalView
///   → 创建 SessionProcessDelegate 并设为 view.processDelegate
///   → startProcess 启动 /bin/zsh -lic <command>
///
/// [进程运行中...]
///
/// 进程退出（正常结束 / Ctrl+D / kill）
///   → SwiftTerm 回调 processTerminated(source:exitCode:)
///   → SessionProcessDelegate.onTerminated(sessionID)
///   → AppState 标记 Session 已关闭，UI 更新状态
/// ```
///
/// ## 为什么需要这个代理
///
/// SwiftTerm 使用委托模式通知进程生命周期事件。`LocalProcessTerminalViewDelegate`
/// 定义了 `processTerminated(source:exitCode:)` 回调。我们需要在进程退出时：
/// 1. 更新 `Session.status` → `.closed`
/// 2. 记录退出码（用于 UI 展示是否异常退出）
/// 3. 在 transcript 末尾追加进程退出标记
///
/// 本代理作为 SwiftTerm 和 AppState 之间的桥梁，将进程级事件转化为应用级状态变更。
///
/// ## 线程安全
///
/// SwiftTerm 的委托回调**不一定在主线程**（取决于底层 pty 事件循环实现），
/// 而 `AppState` 的 `@Published` 属性要求在主线程更新（否则触发 SwiftUI 运行时警告）。
/// 因此 `processTerminated` 内部显式 `DispatchQueue.main.async`，
/// 确保 `onTerminated` 闭包（最终修改 AppState）在主线程执行。
///
/// ## 生命周期
///
/// - 创建：`TerminalManager.createAndStart()` 为每个 session 创建一个
/// - 持有：`TerminalManager.delegates` 字典键值对（key = sessionID）
/// - 释放：`TerminalManager.close()` 中 `delegates[sessionID] = nil`
///
/// ## 与相关文件的联系
///
/// - `TerminalManager`：创建和释放本代理实例
/// - `TranscriptCapturingTerminalView`：`processDelegate = self`，建立 SwiftTerm 回调链路
/// - `AppState`：`onTerminated` 闭包最终修改 Session 状态
final class SessionProcessDelegate: LocalProcessTerminalViewDelegate {
    /// 关联的会话 ID，用于在回调中标识具体会话。
    let sessionID: UUID
    /// 进程退出回调闭包，传入 sessionID 以便 AppState 定位并关闭对应会话。
    let onTerminated: (UUID) -> Void

    /// - Parameters:
    ///   - sessionID: 关联的会话 UUID
    ///   - onTerminated: 进程退出时的回调（在主线程执行）
    init(sessionID: UUID, onTerminated: @escaping (UUID) -> Void) {
        self.sessionID = sessionID
        self.onTerminated = onTerminated
    }

    /// SwiftTerm 回调：底层 PTY 进程已退出。
    ///
    /// ## 实现要点
    ///
    /// - 先捕获 `sessionID` 到局部变量（防御性：避免 `self` 在异步闭包中被释放后访问）
    /// - 显式切换到主线程：`DispatchQueue.main.async` 保证 UI 更新安全
    /// - 忽略 `exitCode` 参数：目前 UI 不展示退出码，仅标记 opens/closes 状态
    ///
    /// ## 为什么在主线程更新
    ///
    /// `AppState` 使用 `@Published` 属性包装器，必须在主线程修改。
    /// SwiftTerm 的 pty 事件循环运行在后台线程，不切换会触发
    /// "Publishing changes from background threads is not allowed" 运行时警告。
    ///
    /// - Parameters:
    ///   - source: 触发事件的终端视图（未使用，只需知道是哪个 session 的进程退出）
    ///   - exitCode: 进程退出码（nil 表示异常终止，如被信号杀死）
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = sessionID
        // SwiftTerm 的进程回调可能不在主线程，统一回到主线程更新 UI 状态
        DispatchQueue.main.async { self.onTerminated(id) }
    }

    // MARK: - 未使用但必须实现的协议方法

    /// 终端尺寸变化回调（当前未使用，由 SwiftTerm 内部自动处理布局）。
    /// 空实现满足协议要求，尺寸管理完全交给 AppKit 的 frame 布局系统。
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    /// 终端标题变化回调（当前未使用，因为我们只取系统的窗口标题）。
    /// 某些终端应用会通过 OSC 转义序列设置标题，这里不干预。
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    /// 宿主当前目录变化回调（当前未使用，但可扩展为用户工作目录跟踪）。
    /// OSC 7 转义序列可以让终端通知宿主当前工作目录，可用于后续的"跟随目录"功能。
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
