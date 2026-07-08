import SwiftUI
import AppKit

/// 把 SwiftTerm 的 NSView 终端桥接到 SwiftUI 的 `NSViewRepresentable`。
///
/// ## 核心设计：解决「多窗口 / 多标签抢同一份 NSView」
///
/// AppKit 有一条硬约束：**一个 NSView 只能有一个 superview**。
/// 而我们的终端视图是共享资源（一个 session 一个 PTY），
/// SwiftUI 的多标签/多窗口架构可能创建多个 `NSViewRepresentable` 试图展示同一个
/// `TranscriptCapturingTerminalView`，这会引发：
///
/// 1. **经典 bug**：多个窗口/标签同时持有同一个 NSView → AppKit 崩溃或渲染空白
/// 2. **切换标签 bug**：旧标签的终端视图残留在容器里 → 堆叠多个视图 → 渲染混乱
///
/// ### 解决方案：容器 + reattach + dismantle-bump 三位一体
///
/// ```
/// TerminalViewRepresentable(sessionID: "abc")
///   └── makeNSView → 容器 NSView（每次全新）
///         └── [reenact] terminalManager.view(for: "abc") → 唯一 PTY NSView
///               └── 若已在别处 → AppKit 自动摘下 → 归本容器
///               └── 清除容器内其他旧会话视图（修掉切标签堆叠）
///
/// dismantleNSView (容器被卸载时)
///   └── removeFromSuperview（不销毁 PTY NSView）
///   └── coordinator.bump() → terminalLayoutVersion += 1
///         → updateNSView 重新执行 → 其他展示位的容器重新认领这个"孤儿"视图
/// ```
///
/// ### 关键机制：dismantle 不销毁
///
/// SwiftUI 的标准 `dismantleNSView` 实现通常会销毁 NSView，
/// 但我们**不能销毁**终端视图（PTY 进程和 transcript 都在上面）。
///
/// 替代方案：仅 `removeFromSuperview` + `bumpTerminalLayout()`。
/// 视图成为"孤儿"（无 superview），但进程和 transcript 句柄完好。
/// `bumpTerminalLayout()` 递增 `terminalLayoutVersion`，
/// 触发所有使用该 sessionID 的 `TerminalViewRepresentable.updateNSView()`
/// 重新执行 reattach 逻辑——其中一个容器会成功认领这个孤儿视图。
///
/// ### 为什么不用 NSViewControllerRepresentable
///
/// `NSViewControllerRepresentable` 持有 view controller，
/// 而 `TerminalViewRepresentable` 的目标是精确控制 NSView 的父视图关系。
/// 使用 `NSViewRepresentable` 可以：
/// - 在 `makeNSView` 中返回自定义容器
/// - 精确控制 addSubview/removeFromSuperview 时机
/// - 在 `dismantle` 中执行自定义拆解逻辑（不销毁）
///
/// ## 与相关文件的联系
///
/// - `TerminalManager`：持有所有终端视图，提供 `view(for:)` 方法
/// - `TranscriptCapturingTerminalView`：被本桥接"认领"的共享终端视图
/// - `AppState.terminalLayoutVersion`：dismantle 后的重新认领导火索
/// - `ContentView` / 标签视图：使用本桥接展示终端
struct TerminalViewRepresentable: NSViewRepresentable {
    /// 目标 session ID：决定要把哪个终端视图挂到容器里。
    let sessionID: UUID
    /// AppState 引用：用于读取 `terminalLayoutVersion` 和调用 `bumpTerminalLayout()`。
    let appState: AppState

    /// 创建 Coordinator：持有 bump 闭包，dismantle 时触发 layout 重排。
    ///
    /// 使用 `[weak appState]` 捕获避免循环引用：
    /// TerminalViewRepresentable → Coordinator → (weak appState) → AppState
    /// → TerminalViewRepresentable 的视图树。
    /// 虽然是单向持有（AppState 不直接持有 representable），
    /// 但 `[weak appState]` 确保 AppState 被释放后不会崩溃。
    func makeCoordinator() -> Coordinator {
        Coordinator(bump: { [weak appState] in
            Task { @MainActor in appState?.bumpTerminalLayout() }
        })
    }

    /// 返回一个全新的空容器 NSView。
    ///
    /// **重要**：每次 `makeNSView` 返回**新容器**，满足 `NSViewRepresentable` 的契约
    /// （SwiftUI 期望每次创建 NSView 时得到独立的新实例）。
    /// 真正共享的是容器内部挂着的 `TranscriptCapturingTerminalView`。
    ///
    /// ## 容器配置
    ///
    /// - `wantsLayer = true`：启用 Core Animation 图层（提升渲染性能，消除闪烁）
    /// - `translatesAutoresizingMaskIntoConstraints = true`：使用 frame-based 布局（不冲突）
    /// - `autoresizingMask = [.width, .height]`：子视图自动跟随容器尺寸变化
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = TerminalTheme.style(for: appState.terminalThemeMode).background.cgColor
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        reattach(into: container)
        return container
    }

    /// SwiftUI 状态变化时调用（包括 `terminalLayoutVersion` 变化）。
    ///
    /// ## 触发条件
    ///
    /// 1. SwiftUI 的 diff 检测到 `appState.terminalLayoutVersion` 变化
    ///    （因为 `updateNSView` 中读取了它，建立了依赖关系）
    /// 2. 任何其他 `@Published` 属性变化
    ///
    /// ## 执行内容
    ///
    /// 重新执行 reattach 逻辑：清除旧会话视图，认领或挂载本会话视图。
    /// 这是 dismantle-bump-reattach 机制的关键唤醒点：
    ///   别的容器拆了 -> bump terminalLayoutVersion -> 本容器的 updateNSView 被调用 -> 认领孤儿视图
    func updateNSView(_ nsView: NSView, context: Context) {
        // 读取 layoutVersion 以建立依赖：任意展示位拆离后，这里会重新执行并重新认领。
        _ = appState.terminalLayoutVersion
        nsView.layer?.backgroundColor = TerminalTheme.style(for: appState.terminalThemeMode).background.cgColor
        reattach(into: nsView)
    }

    /// 容器被 SwiftUI 拆除时（独立窗口关闭、标签切走等）调用。
    ///
    /// ## 传统实现 vs 本实现
    ///
    /// **传统实现**（会销毁）：
    /// ```
    /// nsView.removeFromSuperview()
    /// nsView = nil  // ← 销毁终端视图和 PTY 进程
    /// ```
    ///
    /// **本实现**（不销毁）：
    /// ```
    /// for sub in nsView.subviews { sub.removeFromSuperview() }  // 仅摘除
    /// coordinator.bump()  // ← 通知其他展示位重新认领
    /// ```
    ///
    /// ## 后续流程（bump → reattach）
    ///
    /// 1. `terminaLayoutVersion += 1`（`@Published` 属性，触发 SwiftUI diff）
    /// 2. SwiftUI 检测到变化 → 调用所有 `TerminalViewRepresentable.updateNSView()`
    /// 3. 每个 representable 的 `reattach` 尝试认领孤儿视图
    /// 4. 其中**展示本 sessionID 的那个容器**成功认领（view.superview === container → 挂上）
    /// 5. 其他容器因为没有该 sessionID 的 view，跳过
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // 仅从本容器摘下共享终端视图（不销毁），并通知其它展示位重新认领。
        for sub in nsView.subviews { sub.removeFromSuperview() }
        coordinator.bump()
    }

    /// 确保 container 里只有本会话的终端视图：清掉其他会话的、挂上本会话的。
    ///
    /// ## 操作步骤
    ///
    /// 1. 从 `terminalManager` 获取本 session 的终端视图（若不存在 → 跳过，等下次更新）
    /// 2. 遍历容器的所有 subview，移除不属于本 session 的视图
    ///    （**修复切标签堆叠 bug**：切标签时旧会话视图残留在容器中）
    /// 3. 本会话视图的认领判断：
    ///    - 已在容器内 → 只更新 frame
    ///    - 在别的容器里 → AppKit 自动从旧 superview 摘下（`addSubview` 语义保证）
    ///    - 没有 superview → 直接挂入
    ///
    /// ## AppKit NSView 的 addSubview 语义
    ///
    /// 当 `term.superview !== container` 时调用 `container.addSubview(term)`：
    /// AppKit 内部先执行 `term.removeFromSuperview()`（从旧父视图摘下），
    /// 再添加为容器的子视图。这是 AppKit 的隐式行为，不是我们的显式操作。
    ///
    /// - Parameter container: 本 representable 的容器 NSView
    private func reattach(into container: NSView) {
        guard let term = appState.terminalManager.view(for: sessionID) else { return }
        // 1) 移除容器内任何不是本会话的视图（切标签时旧会话视图留在原地会导致堆叠）
        for sub in container.subviews where sub !== term {
            sub.removeFromSuperview()
        }
        // 2) 本会话视图若未在容器内，则挂上（若已在别处，AppKit 会自动摘下旧的）
        if term.superview !== container {
            term.removeFromSuperview()
            term.translatesAutoresizingMaskIntoConstraints = true
            term.autoresizingMask = [.width, .height]
            term.frame = terminalFrame(in: container)
            container.addSubview(term)
        } else {
            term.frame = terminalFrame(in: container)
        }
        term.scheduleSizeSynchronizationAfterAttach()
    }

    private func terminalFrame(in container: NSView) -> CGRect {
        let dx = min(TerminalTheme.horizontalPadding, max(0, container.bounds.width / 4))
        let dy = min(TerminalTheme.verticalPadding, max(0, container.bounds.height / 4))
        return container.bounds.insetBy(dx: dx, dy: dy)
    }

    /// Coordinator：持有 bump 闭包，在 dismantle 时调用。
    ///
    /// Coordinator 是 SwiftUI 的 `NSViewRepresentable` 配套类，
    /// 生命周期与 representable 绑定，在 `makeNSView` 时创建，`dismantleNSView` 时销毁。
    ///
    /// 这里只用它传递一个闭包——在 dismantle 时安全递增 `terminalLayoutVersion`。
    final class Coordinator {
        let bump: () -> Void
        init(bump: @escaping () -> Void) { self.bump = bump }
    }
}
