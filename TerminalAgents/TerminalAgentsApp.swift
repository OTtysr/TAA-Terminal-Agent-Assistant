import SwiftUI

/// TerminalAgents 应用入口。
///
/// 架构决策：
///
/// **为什么不用 `NSApplicationDelegateAdaptor`？**
/// —— 此项目使用 `scenePhase`（SwiftUI 生命周期）处理应用级状态（flush 持久化），
/// 而非传统 AppDelegate。SwiftUI 的 `@main` + `App` 协议在 macOS 上已足够成熟，
/// 自定义 AppDelegate 仅在需要拦截 NSApplication 生命周期事件
/// （如 `applicationShouldTerminateAfterLastWindowClosed`）时才有必要，
/// 本项目不需要这些高级 NSApplication 控制。
///
/// **多窗口架构：**
/// - `WindowGroup("Terminal Agents")`：主窗口（NavigationSplitView 三栏布局）。
/// - `WindowGroup("session")`：独立会话窗口（单终端全屏），
///   通过 `for: Session.ID.self` 参数化创建，macOS 为每个不同 UUID 生成独立窗口。
///
/// **快捷键设计：**
/// - `⌘N`：新建会话 → `startNewSession()`。
/// - `⌘⌥N`：新建 Agent → `presentNewAgent()`（与 ⌘N 区分，避免误创建）。
/// - `⌘⇧N`：在新窗口中打开当前会话 → `openWindowForSession(id)`。
///
/// 关联文件：
/// - `ContentView.swift`：主窗口根视图，接收 `.environmentObject(appState)`。
/// - `SessionWindowView.swift`：独立窗口内容，接收 `$sessionID` + `.environmentObject(appState)`。
/// - `AppState.swift`：全局状态（`@StateObject` 在此创建，生命周期与进程绑定）。
@main
struct TerminalAgentsApp: App {
    /// 全局应用状态单例。
    /// 使用 `@StateObject` 而非 `@State`：App 只有一处实例，且 appState 需要跨越
    /// 多个 WindowGroup 共享同一个 ObservableObject 实例。
    @StateObject private var appState = AppState()

    var body: some Scene {
        // ---- 主窗口："Terminal Agents" ----
        // 三栏 NavigationSplitView 布局（SidebarView + SessionListView + TerminalPaneView）。
        WindowGroup("Terminal Agents") {
            ContentView()
                .environmentObject(appState)               // 注入全局状态到整个视图树
                .frame(minWidth: 900, minHeight: 560)      // 主窗口最小尺寸（容纳三栏）
        }
        .defaultSize(width: 1180, height: 760)              // 首次启动默认尺寸
        .windowToolbarStyle(.unified(showsTitle: true))     // macOS 统一工具栏样式
        .commands {
            // ---- ⌘N 新建会话 ----
            // 替换系统的 'New Window' 为自定义 'New Session'（语义更准确）。
            CommandGroup(replacing: .newItem) {
                Button(appState.text(.newSession)) {
                    appState.startNewSession()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.selectedAgent == nil)   // 无选中 Agent 时禁用
            }
            // ---- ⌘⌥N 新建 Agent ----
            // 放在 .newItem 组之后，避免与 ⌘N 冲突。
            CommandGroup(after: .newItem) {
                Button(appState.text(.newAgentEllipsis)) {
                    appState.presentNewAgent()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button(appState.text(.manageProviders)) {
                    appState.presentProviderManager()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }
            // ---- ⌘⇧N 在新窗口打开当前会话 ----
            // 放在 .sidebar 组之后，利用 shift 修饰符与上面两个 N 快捷键区分。
            CommandGroup(after: .sidebar) {
                Button(appState.text(.openInNewWindow)) {
                    if let id = appState.selectedSessionID {
                        appState.openWindowForSession(id)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(appState.selectedSessionID == nil)
            }
            CommandMenu(appState.text(.language)) {
                Button(appState.text(.switchToChinese)) {
                    appState.appLanguage = .chinese
                }
                .disabled(appState.appLanguage == .chinese)

                Button(appState.text(.switchToEnglish)) {
                    appState.appLanguage = .english
                }
                .disabled(appState.appLanguage == .english)
            }
            CommandMenu(appState.text(.providers)) {
                let visibleProviders = appState.providers.filter { ProviderTarget.primaryAgentTools.contains($0.target) }
                if visibleProviders.isEmpty {
                    Button(appState.text(.manageProviders)) {
                        appState.presentProviderManager()
                    }
                } else {
                    ForEach(visibleProviders) { provider in
                        Button(provider.name) {
                            appState.activateProvider(provider)
                        }
                    }
                    Divider()
                    Button(appState.text(.manageProviders)) {
                        appState.presentProviderManager()
                    }
                }
            }
            CommandMenu(appState.text(.terminalTheme)) {
                Button(appState.text(.terminalThemeLight)) {
                    appState.terminalThemeMode = .light
                }
                .disabled(appState.terminalThemeMode == .light)

                Button(appState.text(.terminalThemeDark)) {
                    appState.terminalThemeMode = .dark
                }
                .disabled(appState.terminalThemeMode == .dark)
            }
        }

        // ---- 独立窗口场景："session" ----
        // `for: Session.ID.self` 将 Session.ID 类型作为窗口值（value），
        // 每次 openWindow(id: "session", value: uuid) 都创建一个新的独立窗口。
        // 关闭窗口时 macOS 自动释放资源，无需手动管理窗口生命周期。
        WindowGroup("session", for: Session.ID.self) { $sessionID in
            SessionWindowView(sessionID: $sessionID)
                .environmentObject(appState)                // 共享同一个 appState
                .frame(minWidth: 480, minHeight: 320)      // 独立窗口最小尺寸
        }
    }
}
