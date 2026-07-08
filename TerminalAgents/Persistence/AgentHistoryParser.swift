import Foundation
import Darwin

/// 通用 Agent 历史文件解析器。
///
/// 背景：不同的 AI Coding Agent（Claude Code、KimiCode、OpenCode、Hermes 等）各自维护
/// 自己的对话历史目录，文件格式以 JSONL（每行一个 JSON 对象）为主。本解析器屏蔽差异，
/// 提供统一的 session-id 匹配和 JSONL 解析能力。
///
/// ## 两大核心功能入口
///
/// ### 1. Session-ID 匹配 (`matchSessionID`)
/// 按会话创建时间戳在 Agent 历史目录/数据库中递归匹配创建时间最接近的那条记录，
/// 取其文件名、目录名或数据库 id 作为 session-id。
///
/// **用途**：`--resume <id>` / `--session <id>` 精确恢复已有会话。Claude/Hermes
/// 通常用 JSONL 文件名作 session-id，KimiCode 用 `session_<uuid>` 目录名，
/// OpenCode 新版用 SQLite `session.id`。通过时间戳匹配可以在 Agent 层面上
/// 精确关联到 App 中的 Session。
///
/// **为什么用 birthtime 而不是 mtime**：
/// - `mtime`（modification time）是文件最后写入时间，长对话的 mtime 会远晚于会话启动时间点。
/// - `birthtime`（creation date）是文件首次创建的物理时间戳，与 App session 的 `createdAt`
///   高度吻合（允许极小负向误差和 300 秒正向窗口）。
///
/// **为什么需要递归**：
/// Claude Code 的历史文件存放在 `<history-dir>/<encoded-cwd>/` 子目录结构中，而非平铺。
/// 因此必须使用 `FileManager.enumerator` 递归遍历整个目录树。
///
/// ### 2. JSONL 解析 (`load` / `parseJSONL`)
/// 将 Agent 的历史 JSONL 文件解析为 `ConversationEntry` 数组（role + content），
/// 用于聊天气泡回放展示。
///
/// **用途**：当 `--resume` 不可用或无 session-id 时的兜底展示方案（历史回放）。
///
/// ## 数据流关系
/// - `Store.swift`：管理 Agent 配置与 Session 的持久化，不确定义历史文件路径。
    /// - `AgentConfig.historyGlob`：用户可配置的 glob 路径，作为额外历史候选来源。
/// - `HistoryFormat`：枚举了支持的 Agent 类型（.claudeCode、.kimiCode、.openCode、.hermes 等），
///   每种格式定义了不同的默认历史目录和文件扩展名。
enum AgentHistoryParser {

    private struct HistoryCandidate {
        let birth: Date
        let id: String
        let url: URL?
    }

    // MARK: - 公共入口：JSONL → 对话条目（兜底展示用）

    /// 按时间戳匹配历史文件并解析为 `ConversationEntry` 数组。
    ///
    /// 这是「resume 不可用时的兜底展示」入口：
    /// 1. 解析格式（支持 .auto 自动检测）
    /// 2. 复用 `matchSessionID` 的递归 + birthtime 逻辑拿到匹配文件
    /// 3. 用 `findFile` 递归定位文件 URL
    /// 4. 解析 JSONL → 对话条目
    ///
    /// - Parameters:
    ///   - sessionCreatedAt: 会话创建时间，用于时间戳匹配
    ///   - glob: 用户可配置的 glob 路径，会作为额外候选参与匹配
    ///   - format: 历史格式枚举
    /// - Returns: 解析出的对话条目数组；任一环节失败返回 nil
    static func load(for sessionCreatedAt: Date, glob: String?, format: HistoryFormat) -> [ConversationEntry]? {
        let resolved = resolvedFormat(from: format, glob: glob)
        // 复用 matchCandidate 的递归 + birthtime 逻辑拿到文件/目录锚点，再定位可解析文件。
        guard let candidate = matchCandidate(for: sessionCreatedAt, format: resolved, globOverride: glob),
              let url = parseableHistoryFile(for: candidate, format: resolved) else { return nil }
        return parseJSONL(url)
    }

    /// 解析明确已知路径的单个历史文件。
    ///
    /// 根据格式枚举决定解析策略：
    /// - `.claudeCode` / `.kimiCode` / `.openCode` / `.hermes`：JSONL 格式，走 `parseJSONL`
    /// - `.openClaw` / `.none` / `.auto`（无法确定时）：目前不支持，返回 nil
    ///
    /// - Parameters:
    ///   - file: 历史文件的 URL；nil 则直接返回 nil
    ///   - format: 历史格式（用于决定解析策略）
    /// - Returns: 解析出的对话条目数组；不支持或失败返回 nil
    static func parse(file: URL?, format: HistoryFormat) -> [ConversationEntry]? {
        guard let file else { return nil }
        let resolved = resolvedFormat(from: format, glob: file.path)
        switch resolved {
        case .claudeCode, .kimiCode, .openCode, .hermes:
            return parseJSONL(file)
        case .openClaw, .none, .auto:
            return nil
        }
    }

    // MARK: - Session-ID 匹配（用于精确 --resume <id>）

    /// 按会话创建时间戳，递归扫描 Agent 历史目录，匹配 birthtime（文件创建时间）最接近的文件，
    /// 返回文件名（去扩展名）作为 session-id。
    ///
    /// ## 匹配算法
    ///
    /// 1. 解析 `HistoryFormat`，获取历史目录和文件扩展名
    /// 2. 用 `FileManager.enumerator` 递归枚举目录下所有匹配扩展名的文件
    ///    （Claude 的历史文件在 `<encoded-cwd>/` 子目录下，所以必须递归）
    /// 3. 记录每个文件的 `birthtime`（优先 `.creationDate`，回退 `.modificationDate`）
    ///    和文件名（去扩展名）作为候选 session-id
    /// 4. 在启动后 5 分钟窗口内，找 birthtime 与 `sessionCreatedAt` 最接近的文件
    /// 5. 若时间窗口内无匹配 → 返回 nil（表示未找到对应的 Agent 会话）
    ///
    /// ## 为什么用 birthtime 而非 mtime
    ///
    /// - `mtime`（modificationTime）是文件最后写入时间。在长对话中，最后一次写入
    ///   可能远晚于会话启动时间，导致匹配到错误的 session。
    /// - `birthtime`（creationDate）是文件首次在磁盘上创建的物理时间戳。
    ///   Agent 通常在一开始就会创建历史文件（即便内容为空），因此与 App session 的
    ///   `createdAt` 高度吻合。
    /// - 极端情况：某些文件系统不记录 creationDate → 回退到 modificationDate。
    ///
    /// ## 时间窗口
    ///
    /// Agent 从 App 创建 session 到真正启动并写入第一个历史文件存在固有延迟
    /// （进程 fork、pty 初始化、shell 启动、OpenCode 首条消息落库等），5 分钟正向窗口给足了容忍度。
    /// 只允许 10 秒负向误差，避免匹配到启动前已存在的"最近会话"。
    /// 如果出现跨会话歧义（两个 session 创建时间非常接近），取 diff 最小的那个。
    ///
    /// ## 与相关文件的联系
    ///
    /// - `Store.swift`：Session 的 `createdAt` 由此传入
    /// - `AgentConfig.historyGlob`：`globOverride` 作为额外候选，用于用户自定义路径
    /// - `HistoryFormat`：定义了每种 Agent 的默认历史目录和文件扩展名
    ///
    /// - Parameters:
    ///   - sessionCreatedAt: 会话创建时间（来自 Session.createdAt）
    ///   - format: 历史格式（决定历史目录与扩展名）
    ///   - globOverride: 用户可配置的 glob 覆盖路径，会作为额外候选参与匹配
    /// - Returns: 匹配到的 session-id（文件名去扩展名）；匹配失败返回 nil
    static func matchSessionID(for sessionCreatedAt: Date,
                                format: HistoryFormat,
                                globOverride: String? = nil,
                                excluding excludedIDs: Set<String> = []) -> String? {
        let resolved = resolvedFormat(from: format, glob: globOverride ?? "")
        return matchCandidate(for: sessionCreatedAt,
                              format: resolved,
                              globOverride: globOverride,
                              excluding: excludedIDs)?.id
    }

    // MARK: - 内部辅助方法

    private static func matchCandidate(for sessionCreatedAt: Date,
                                       format: HistoryFormat,
                                       globOverride: String?,
                                       excluding excludedIDs: Set<String> = []) -> HistoryCandidate? {
        let candidates = collectCandidates(format: format, globOverride: globOverride)
        guard !candidates.isEmpty else { return nil }

        // 找创建时间与 sessionCreatedAt 最接近的文件/目录/数据库记录。
        // Agent 历史通常在 TerminalAgents 创建 Session 后才写入；只允许极小负向误差，
        // 避免 OpenCode 这类"懒创建 session"的 Agent 把启动前的旧会话当成新锚点。
        let earlyTolerance: TimeInterval = 10
        let lateWindow: TimeInterval = 300
        var best: HistoryCandidate?
        var bestDiff: TimeInterval = .greatestFiniteMagnitude
        for candidate in candidates {
            guard !excludedIDs.contains(candidate.id) else { continue }
            let delta = candidate.birth.timeIntervalSince(sessionCreatedAt)
            guard delta >= -earlyTolerance, delta <= lateWindow else { continue }
            let absDelta = abs(delta)
            if absDelta < bestDiff {
                bestDiff = absDelta
                best = candidate
            }
        }
        return best
    }

    private static func collectCandidates(format: HistoryFormat,
                                          globOverride: String?) -> [HistoryCandidate] {
        var result: [HistoryCandidate] = []

        // 用户配置的 glob 是额外候选，不作为唯一来源。这样旧默认值失效时，
        // Kimi/OpenCode 仍能从新版默认目录/数据库里抓到精确锚点。
        if let glob = globOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !glob.isEmpty {
            result.append(contentsOf: candidates(fromGlob: glob, format: format))
        }

        for db in format.historyDatabaseFiles {
            result.append(contentsOf: openCodeCandidates(fromDatabase: db))
        }

        for dir in format.historyDirs {
            result.append(contentsOf: candidates(inDirectory: dir, format: format))
        }

        return result
    }

    private static func candidates(inDirectory dir: URL, format: HistoryFormat) -> [HistoryCandidate] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: dir,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles],
                                             errorHandler: nil) else { return [] }
        var result: [HistoryCandidate] = []
        for case let url as URL in enumerator {
            if let candidate = candidate(from: url, format: format) {
                result.append(candidate)
            }
        }
        return result
    }

    private static func candidates(fromGlob rawGlob: String, format: HistoryFormat) -> [HistoryCandidate] {
        let pattern = expandPath(rawGlob)
        guard !pattern.isEmpty else { return [] }

        if !containsGlobWildcard(pattern) {
            return candidates(fromExplicitURL: URL(fileURLWithPath: pattern), format: format)
        }

        let base = baseDirectory(forGlob: pattern)
        let baseURL = URL(fileURLWithPath: base)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: baseURL,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles],
                                             errorHandler: nil) else { return [] }

        var result: [HistoryCandidate] = []
        if fnmatch(pattern, baseURL.path, 0) == 0 {
            result.append(contentsOf: candidates(fromExplicitURL: baseURL, format: format))
        }
        for case let url as URL in enumerator where fnmatch(pattern, url.path, 0) == 0 {
            result.append(contentsOf: candidates(fromExplicitURL: url, format: format))
        }
        return result
    }

    private static func candidates(fromExplicitURL url: URL, format: HistoryFormat) -> [HistoryCandidate] {
        if format == .openCode, url.lastPathComponent == "opencode.db" {
            return openCodeCandidates(fromDatabase: url)
        }
        if isDirectory(url) {
            var result: [HistoryCandidate] = []
            if let candidate = candidate(from: url, format: format) {
                result.append(candidate)
            }
            result.append(contentsOf: candidates(inDirectory: url, format: format))
            return result
        }
        if let candidate = candidate(from: url, format: format) {
            return [candidate]
        }
        return []
    }

    private static func candidate(from url: URL, format: HistoryFormat) -> HistoryCandidate? {
        let name = url.lastPathComponent
        let isDir = isDirectory(url)

        switch format {
        case .claudeCode, .hermes:
            guard !isDir, url.pathExtension == "jsonl" else { return nil }
            return HistoryCandidate(birth: fileBirthDate(url),
                                    id: url.deletingPathExtension().lastPathComponent,
                                    url: url)

        case .kimiCode:
            if isDir, looksLikeKimiSessionID(name) {
                return HistoryCandidate(birth: kimiSessionCreatedAt(in: url) ?? fileBirthDate(url),
                                        id: name,
                                        url: url)
            }
            guard !isDir, name != "session_index.jsonl", url.pathExtension == "jsonl" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            return HistoryCandidate(birth: fileBirthDate(url), id: id, url: url)

        case .openCode:
            if isDir, looksLikeOpenCodeSessionID(name) {
                return HistoryCandidate(birth: fileBirthDate(url), id: name, url: url)
            }
            guard !isDir, name != "opencode.db" else { return nil }
            let id = url.pathExtension.isEmpty ? name : url.deletingPathExtension().lastPathComponent
            guard (url.pathExtension.isEmpty || url.pathExtension == "jsonl"),
                  looksLikeOpenCodeSessionID(id) else { return nil }
            return HistoryCandidate(birth: fileBirthDate(url), id: id, url: url)

        case .openClaw, .none, .auto:
            return nil
        }
    }

    private static func openCodeCandidates(fromDatabase db: URL) -> [HistoryCandidate] {
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-separator", "\t",
            db.path,
            "select id, time_created from session;"
        ]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }

        return text
            .components(separatedBy: .newlines)
            .compactMap { line -> HistoryCandidate? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 2, let rawTime = Double(parts[1]) else { return nil }
                let seconds = rawTime > 10_000_000_000 ? rawTime / 1000 : rawTime
                return HistoryCandidate(birth: Date(timeIntervalSince1970: seconds),
                                        id: String(parts[0]),
                                        url: db)
            }
    }

    private static func parseableHistoryFile(for candidate: HistoryCandidate,
                                             format: HistoryFormat) -> URL? {
        guard let url = candidate.url else { return nil }
        if !isDirectory(url) {
            return url.lastPathComponent == "opencode.db" ? nil : url
        }

        switch format {
        case .kimiCode:
            let primary = url.appendingPathComponent("agents/main/wire.jsonl")
            if FileManager.default.fileExists(atPath: primary.path) { return primary }
            return firstJSONLFile(in: url)
        case .claudeCode, .openCode, .hermes:
            return firstJSONLFile(in: url)
        case .openClaw, .none, .auto:
            return nil
        }
    }

    private static func firstJSONLFile(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: dir,
                                                              includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles],
                                                              errorHandler: nil) else { return nil }
        for case let url as URL in enumerator where !isDirectory(url) && url.pathExtension == "jsonl" {
            return url
        }
        return nil
    }

    private static func kimiSessionCreatedAt(in dir: URL) -> Date? {
        let state = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: state),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["createdAt"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    private static func fileBirthDate(_ url: URL) -> Date {
        if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            return values.creationDate ?? values.contentModificationDate ?? Date.distantPast
        }
        return Date.distantPast
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func looksLikeKimiSessionID(_ value: String) -> Bool {
        value.hasPrefix("session_") || UUID(uuidString: value) != nil
    }

    private static func looksLikeOpenCodeSessionID(_ value: String) -> Bool {
        value.hasPrefix("ses_") || UUID(uuidString: value) != nil
    }

    private static func expandPath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }

    private static func containsGlobWildcard(_ path: String) -> Bool {
        path.contains("*") || path.contains("?") || path.contains("[")
    }

    private static func baseDirectory(forGlob pattern: String) -> String {
        guard let wildcard = pattern.firstIndex(where: { $0 == "*" || $0 == "?" || $0 == "[" }) else {
            return (pattern as NSString).deletingLastPathComponent
        }
        let prefix = String(pattern[..<wildcard])
        let base = prefix.hasSuffix("/")
            ? String(prefix.dropLast())
            : (prefix as NSString).deletingLastPathComponent
        return base.isEmpty ? "/" : base
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 解析格式：支持 `.auto` 自动检测。
    ///
    /// - 若 format == `.auto` → 根据 glob 路径特征自动判定（如路径包含 "claude" 则判定为 .claudeCode）
    /// - 否则直接返回原格式枚举
    private static func resolvedFormat(from format: HistoryFormat, glob: String?) -> HistoryFormat {
        if format == .auto { return HistoryFormat.detect(from: glob ?? "") }
        return format
    }

    // MARK: - JSONL 解析引擎（Claude / KimiCode / OpenCode / Hermes 通用）

    /// 递归查找目录下指定文件名（含扩展名）的文件 URL。
    ///
    /// 与 `matchSessionID` 的递归逻辑一致：必须递归遍历，因为 Claude 的文件在子目录中。
    ///
    /// - Parameters:
    ///   - id: 文件名（不含扩展名）
    ///   - ext: 扩展名（为空时直接匹配 id 即完整文件名）
    ///   - dir: 起始目录 URL
    /// - Returns: 找到的文件 URL；未找到返回 nil
    private static func findFile(named id: String, ext: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir.path) else { return nil }
        let target = ext.isEmpty ? id : "\(id).\(ext)"
        for case let subpath as String in enumerator {
            if (subpath as NSString).lastPathComponent == target {
                return dir.appendingPathComponent(subpath)
            }
        }
        return nil
    }

    /// JSONL 格式解析核心逻辑。
    ///
    /// JSONL（JSON Lines）格式：每行一个独立的 JSON 对象，行与行之间没有逗号分隔。
    /// 这是 Claude Code / KimiCode / OpenCode / Hermes 等 Agent 的标准历史格式。
    ///
    /// ## 解析流程
    ///
    /// 1. 读取整个文件为 UTF-8 字符串
    /// 2. 按 `\n` 拆分，逐行解析
    /// 3. 每行 JSON 提取 `role` 和 `content` 字段
    /// 4. `content` 支持两种格式：
    ///    - **数组格式**（Claude 的 block 结构）：`[{"type": "text", "text": "..."}, ...]`
    ///      → 取所有 text block 拼接
    ///    - **字符串格式**（简单 Agent）：直接取值
    /// 5. 跳过空行、无法解析的行、无 role 的行、空 content 的行
    ///
    /// ## 边界情况处理
    ///
    /// - JSON 解析失败的行 → 静默跳过（不中断整体解析，宁缺毋滥）
    /// - role 不在 `ConversationEntry.Role` 枚举中 → 跳过
    /// - content 为空字符串 → 跳过（没有实际信息的条目不展示）
    /// - 全文件无可解析条目 → 返回 nil（与空数组语义不同，上层据此判断"无法解析"）
    ///
    /// - Parameter url: JSONL 文件的 URL
    /// - Returns: 解析出的对话条目数组；无有效条目或读取失败返回 nil
    static func parseJSONL(_ url: URL) -> [ConversationEntry]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var entries: [ConversationEntry] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roleStr = json["role"] as? String,
                  let role = ConversationEntry.Role(rawValue: roleStr) else { continue }
            // content 可能是 block 数组（如 Claude 的 [{type: "text", text: "..."}]）
            // 也可能是纯字符串（简单 Agent），两种都要兼容
            let contentText: String
            if let blocks = json["content"] as? [[String: Any]] {
                contentText = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else if let s = json["content"] as? String {
                contentText = s
            } else { continue }
            guard !contentText.isEmpty else { continue }
            entries.append(ConversationEntry(role: role, content: contentText))
        }
        return entries.isEmpty ? nil : entries
    }
}
