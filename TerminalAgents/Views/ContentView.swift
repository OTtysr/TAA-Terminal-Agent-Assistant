import SwiftUI

/// 应用根视图 — 三栏页面布局（Sidebar | SessionList | TerminalPane）。
///
/// 使用 `NavigationSplitView` 实现 macOS 经典的三栏界面：
/// - **第一栏（sidebar）**：`SidebarView` — Agent 列表，增删改查。
/// - **第二栏（content）**：`SessionListView` — 当前选中 Agent 的会话列表。
/// - **第三栏（detail）**：`TerminalPaneView` — 终端面板与选项卡栏。
///
/// 额外职责：
/// 1. **openWindow 注入**：通过 `.task` 将 SwiftUI 的 `openWindow` action 注入 `AppState`，
///    供菜单命令或代码中直接打开独立会话窗口（见 `SessionWindowView.swift`）。
/// 2. **transcript 刷盘**：通过 `.onChange(of: scenePhase)` 观察窗口生命周期，
///    当应用进入后台/失焦时调用 `terminalManager.flushAll()` 将终端缓冲区 fsync 到磁盘，
///    避免崩溃后回放时出现截断的乱码转义序列。
///
/// 关联文件：
/// - `SidebarView.swift`：第一栏 Agent 列表。
/// - `SessionListView.swift`：第二栏会话列表。
/// - `TerminalPaneView.swift`：第三栏终端面板。
/// - `AppState.swift`：`openWindowAction`、`terminalManager` 等全局状态。
/// - `SessionWindowView.swift`：`openWindow(id: "session")` 打开的独立窗口。
struct ContentView: View {
    /// 全局应用状态（由 `TerminalAgentsApp` 在入口注入 `.environmentObject(appState)`）。
    @EnvironmentObject var appState: AppState
    /// SwiftUI 环境提供：打开新窗口的能力。
    /// macOS 上对应 `openWindow(id:value:)`，用于创建 `WindowGroup(id: "session")` 的独立窗口。
    @Environment(\.openWindow) private var openWindow
    /// SwiftUI 环境提供：当前场景（窗口）的阶段状态。
    /// 值变化时触发 `.onChange(of: scenePhase)` 回调，用于检测进入后台/失焦。
    @Environment(\.scenePhase) private var scenePhase
    /// 三栏显示模式：`.all` / `.detailOnly` / `.doubleColumn` 等。
    /// `NavigationSplitView` 自动管理拖拽分界线和隐藏切换。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        // ---- 三栏分割视图 ----
        // 双向绑定 `columnVisibility` 允许用户拖拽切换显示模式。
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 第一栏：Agent 侧边栏
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240) // 最小 200pt，推荐 240pt
        } content: {
            // 第二栏：会话列表
            SessionListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280) // 最小 220pt，推荐 280pt
        } detail: {
            // 第三栏：终端面板（含选项卡栏 + 终端内容）
            TerminalPaneView()
        }
        // ---- Agent 编辑 Sheet ----
        // 当 `newAgentRequest` 为 true 时弹出编辑面板（SidebarView 中的 + 按钮或右键 Edit 触发）。
        .sheet(isPresented: $appState.newAgentRequest) {
            AgentEditorSheet(agent: appState.editingAgent,
                             defaultColorName: appState.newAgentDefaultColorName)
        }
        .sheet(isPresented: $appState.providerManagerRequest) {
            ProviderManagerSheet()
                .environmentObject(appState)
        }
        // ---- 异步初始化任务 ----
        // `.task`：视图出现时执行一次，将 `openWindow` 注入 AppState。
        // 这样 AppState 内部（如菜单命令 `openSessionInWindow`）就可以调用打开窗口。
        .task {
            // 注入打开独立窗口的能力，供菜单命令调用
            appState.openWindowAction = { id in
                openWindow(id: "session", value: id)
            }
        }
        // ---- 场景阶段监听 ----
        // `.onChange(of:)`：当 `scenePhase` 变化时触发。
        // 检测进入后台或失焦状态，将所有运行中会话的 transcript 缓冲区刷盘（fsync），
        // 避免异常退出时末尾写入停留在 OS 页缓存、回放时出现截断的半截转义序列（乱码）。
        .onChange(of: scenePhase) { _, phase in
            // 进入后台/失焦时把所有运行中会话的 transcript 刷盘（fsync），
            // 避免异常退出时末尾写入停留在 OS 页缓存、回放时出现截断的半截转义序列（乱码）。
            if phase == .background || phase == .inactive {
                appState.terminalManager.flushAll()
            }
        }
    }
}
