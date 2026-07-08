import SwiftUI

/// 独立窗口场景：在单独的 `Window` 中显示单个会话终端。
///
/// 使用场景：
/// - 用户在 TerminalTabBar 右键菜单选择 "Open in New Window"
/// - 菜单栏 → View → Open Session in New Window
/// - 多个此类窗口配合 macOS 分屏/平铺，实现多终端并排监控
///
/// 实现方式：通过 `ContentView` 中注入的 `appState.openWindowAction`，
/// 调用 `openWindow(id: "session", value: sessionID)` 创建本窗口。
/// macOS 根据 `WindowGroup(id: "session")` 自动为每个不同 UUID 创建独立窗口。
///
/// 内容路由：
/// - **运行中且终端可用** → `TerminalViewRepresentable`（复用 TerminalManager 中同一个共享 NSView）
/// - **已关闭或终端不可用** → `TranscriptReadOnlyView`（无头重放 transcript 字节流）
/// - **找不到会话** → `ContentUnavailableView`
///
/// 注意：同一会话只有一个 PTY/NSView 实例，所有窗口显示的是同一终端快照。
///
/// 关联文件：
/// - `ContentView.swift`：在 `.task` 中注入 `openWindowAction`。
/// - `TerminalViewRepresentable`：NSViewRepresentable 桥接 SwiftTerm 终端视图。
/// - `TerminalTabBar.swift`："Open in New Window" 菜单入口。
/// - `AppState.swift`：`terminalManager` 管理终端实例生命周期。
struct SessionWindowView: View {
    /// 会话 ID 的绑定（WindowGroup 的 value 参数绑定）。
    /// 当外部（如 TerminalTabBar）传递不同的 UUID 时，窗口内容自动刷新。
    let sessionID: Binding<UUID?>
    /// 全局应用状态（环境注入，提供 sessions 列表和 terminalManager）。
    @EnvironmentObject var appState: AppState

    /// 根据 sessionID 查找对应的会话对象，找不到则返回 nil。
    private var session: Session? {
        guard let id = sessionID.wrappedValue else { return nil }
        return appState.sessions.first { $0.id == id }
    }

    var body: some View {
        // `Group` 用作逻辑容器，根据会话状态分支渲染不同内容。
        Group {
            if let session {
                // 会话存在：检查是否为运行状态且终端视图已就绪
                if session.status == .running,
                   appState.terminalManager.view(for: session.id) != nil {
                    // 活跃终端：复用 TerminalManager 中的共享 NSView（同一进程只一份 PTY）
                    TerminalViewRepresentable(sessionID: session.id, appState: appState)
                } else {
                    // 已关闭终端：回退到只读 transcript 重放
                    TranscriptReadOnlyView(ref: session.transcriptRef)
                }
            } else {
                // 找不到会话：显示占位提示
                ContentUnavailableView(appState.text(.sessionUnavailable), systemImage: "terminal")
            }
        }
        .navigationTitle(session?.title ?? appState.text(.session)) // 窗口标题 = 会话标题
        .frame(minWidth: 480, minHeight: 320)          // 独立窗口最小尺寸
    }
}
