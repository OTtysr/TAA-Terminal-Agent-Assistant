import Foundation

/// 应用持久化层：管理 Agent 配置、Session 记录和终端 transcript 的三层持久化。
///
/// ## 文件布局
///
/// 所有数据存放在 `~/Library/Application Support/com.terminalagents.TerminalAgents/`：
///
/// ```
/// com.terminalagents.TerminalAgents/
/// ├── agents.json              — Agent 配置数组（AgentConfig[]）
/// ├── sessions.json            — Session 记录数组（Session[]）
/// └── transcripts/
///     ├── <uuid-1>.transcript  — 终端输出 transcript（原始字节流）
///     ├── <uuid-2>.transcript
///     └── ...
/// ```
///
/// ## 设计决策
///
/// ### 两层 JSON + 流式 transcript
///
/// - `agents.json` / `sessions.json`：全量读写，适合数组结构。
///   量级不大（Agent 数个，Session 数十个），JSON 序列化的开销可忽略。
/// - `transcripts/`：每个 Session 一个文件，通过 `FileHandle` 流式追加。
///   终端输出可能很大（长会话可达数 MB），全量 JSON 序列化不可行。
///   流式追加 + 定期刷盘（fsync）的方案兼顾了写入性能和持久性。
///
/// ### 原子写入
///
/// JSON 文件使用 `.atomic` 写入模式：先写临时文件，再 rename 到目标位置。
/// 保证 crash 时不会出现半写文件（要么全写完，要么旧文件保留）。
///
/// ### ISO 8601 日期编码
///
/// Session 的 `createdAt` 等日期字段使用 ISO 8601 编码，确保跨时区一致性
/// 和人类可读性（JSON 中直接可读）。
///
/// ## 与其它模块的关系
///
/// - `AgentHistoryParser`：读取 Agent 原生历史文件（非 Store 管理），
///   匹配 session-id 并解析对话条目。
/// - `TerminalManager`：持有 Store 引用，创建终端时打开 transcript `FileHandle`。
/// - `TranscriptCapturingTerminalView`：持有 Store 创建的 `FileHandle`，
///   在 `dataReceived` 中追加 PTY 输出字节。
/// - `AppState`：持有 Store 实例，调用 `load()` / `save()` 驱动序列化/反序列化。
final class Store {
    /// Agent 配置数组，与 agents.json 对应。
    var agents: [AgentConfig] = []
    /// Session 记录数组，与 sessions.json 对应。
    var sessions: [Session] = []
    /// Provider 配置数组，与 providers.json 对应。
    var providers: [ProviderProfile] = []

    private let fm = FileManager.default
    /// 数据根目录：`~/Library/Application Support/com.terminalagents.TerminalAgents/`
    private let baseDir: URL
    /// Transcript 子目录：`<baseDir>/transcripts/`
    private let transcriptsDir: URL

    // MARK: - JSON 编解码器

    /// JSON 编码器：pretty-print + sorted keys（diff 友好） + ISO8601 日期。
    ///
    /// `.sortedKeys` 确保每次编码的 key 顺序一致，与 `.prettyPrinted` 配合使用
    /// 使 git diff 具有可读性（若用户将数据目录纳入版本控制）。
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// JSON 解码器：匹配 encoder 的 ISO8601 日期策略。
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - 初始化（确保目录结构）

    init() {
        // 解析 Application Support 目录路径。
        // `fm.url(for:in:appropriateFor:create:)` 使用标准 AppKit API，
        // 自动处理沙盒路径映射（如果启用沙盒）。
        let support: URL
        if let url = try? fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil,
                                  create: true) {
            support = url
        } else {
            // 兜底：手动拼接路径（极少发生，仅在沙盒或权限异常时）
            support = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        baseDir = support.appendingPathComponent("com.terminalagents.TerminalAgents", isDirectory: true)
        transcriptsDir = baseDir.appendingPathComponent("transcripts", isDirectory: true)

        // 确保目录存在（`.withIntermediateDirectories: true` 一次性创建完整路径树）
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
    }

    // MARK: - 文件路径计算

    private var agentsURL: URL { baseDir.appendingPathComponent("agents.json") }
    private var sessionsURL: URL { baseDir.appendingPathComponent("sessions.json") }
    private var providersURL: URL { baseDir.appendingPathComponent("providers.json") }

    // MARK: - JSON 读写

    /// 从磁盘加载 agents.json 和 sessions.json。
    ///
    /// 使用空合并运算符 `?? []` 处理解码失败（文件损坏、格式不兼容等）：
    /// 解码失败时 `agents` / `sessions` 为空数组，不会崩溃。
    /// 下次 `save()` 将以新的（正确的）结构覆盖损坏的文件。
    func load() {
        if let data = try? Data(contentsOf: agentsURL) {
            agents = (try? decoder.decode([AgentConfig].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: sessionsURL) {
            sessions = (try? decoder.decode([Session].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: providersURL) {
            providers = (try? decoder.decode([ProviderProfile].self, from: data)) ?? []
        }
    }

    /// 将当前 `agents` 和 `sessions` 原子写入磁盘。
    ///
    /// 写入时先序列化数组整体，再原子写入。
    /// 注意：频繁调用 save() 会有性能开销（全量重写），
    /// 因此在 `AppState` 中应在批量操作后调用一次，而非每个修改都保存。
    func save() {
        write(agents, to: agentsURL)
        write(sessions, to: sessionsURL)
        write(providers, to: providersURL)
    }

    // MARK: - Transcript 文件管理

    /// 根据 session UUID 生成 transcript 文件名。
    ///
    /// 格式：`<uuid>.transcript`（扩展名固定为 `.transcript`）
    func transcriptRef(for id: UUID) -> String { "\(id.uuidString).transcript" }

    /// 根据 transcript 引用（文件名）计算完整文件 URL。
    func transcriptURL(for ref: String) -> URL { transcriptsDir.appendingPathComponent(ref) }

    /// 打开（或创建）transcript 文件，返回定位到文件末尾的 `FileHandle` 用于追加写入。
    ///
    /// ## 流程
    ///
    /// 1. 若文件不存在 → `fm.createFile` 创建空文件
    /// 2. `FileHandle(forWritingTo:)` 以写入模式打开（非截断）
    /// 3. `seekToEnd()` 定位到文件末尾，确保后续写入是追加而非覆盖
    ///
    /// ## 为什么用 FileHandle 而不是 OutputStream
    ///
    /// `FileHandle` 的 API 更简单：`write(contentsOf:)` 接受 `Data` 参数，无需管理
    /// buffer 和调度。与 `TranscriptCapturingTerminalView.dataReceived` 中的
    /// `ArraySlice<UInt8>` → `Data` 的转换无缝衔接。
    ///
    /// ## 与相关文件的联系
    ///
    /// - `TerminalManager.createAndStart` 调用本方法打开句柄并传给 `TranscriptCapturingTerminalView`
    /// - `TranscriptCapturingTerminalView.transcriptHandle` 持有返回的 `FileHandle`
    ///
    /// - Parameter ref: transcript 文件名（如 "xxx.transcript"）
    /// - Returns: 可追加写入的 FileHandle；创建或打开失败返回 nil
    func openTranscript(for ref: String) -> FileHandle? {
        let url = transcriptURL(for: ref)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    /// 读取 transcript 文件全部数据。
    ///
    /// - Parameter ref: transcript 文件名；nil 时返回 nil（防御性检查）
    /// - Returns: transcript 文件的全部字节数据；读取失败返回 nil
    func readTranscript(for ref: String?) -> Data? {
        guard let ref else { return nil }
        return try? Data(contentsOf: transcriptURL(for: ref))
    }

    /// 删除指定 session 的 transcript 文件（session 被删除时调用）。
    ///
    /// 注意：删除前应确保对应的 `FileHandle` 已关闭，
    /// 否则在某些文件系统上 close 可能失败或产生未定义行为。
    /// 调用方（如 `AppState`）应先关闭句柄再调用此方法。
    func deleteTranscript(for id: UUID) {
        try? fm.removeItem(at: transcriptURL(for: transcriptRef(for: id)))
    }

    // MARK: - 原子写入私有方法

    /// 将 `Encodable` 值以原子模式写入指定 URL。
    ///
    /// `.atomic` 模式的原理：
    /// 1. 将 JSON 数据写入同目录下的临时文件
    /// 2. 调用 `rename()` 系统调用将临时文件重命名为目标文件名
    /// 3. `rename()` 在同文件系统内是原子操作（POSIX 保证）
    ///
    /// 写入失败时在 DEBUG 模式下打印错误日志（不崩溃、不弹窗），
    /// 因为持久化写入失败不应中断用户操作（数据丢失在下次 save 时自然修复）。
    ///
    /// - Parameters:
    ///   - value: 要编码并写入的值
    ///   - url: 目标文件 URL
    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("Store write error: \(error)")
            #endif
        }
    }
}
