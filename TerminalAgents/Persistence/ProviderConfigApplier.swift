import Foundation

enum ProviderApplyError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidJSON(URL, String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is required for this provider."
        case .invalidBaseURL:
            return "Base URL must be empty or start with http:// or https://."
        case .invalidJSON(let url, let message):
            return "Failed to parse \(url.path): \(message)"
        case .writeFailed(let message):
            return message
        }
    }
}

struct ProviderApplyResult {
    let touchedFiles: [URL]
    let backupFiles: [URL]
}

enum ProviderConfigApplier {
    static func runtimeEnvironment(for provider: ProviderProfile) -> [String: String] {
        switch provider.target {
        case .claudeCode:
            var env: [String: String] = [:]
            if !provider.baseURL.isEmpty {
                env["ANTHROPIC_BASE_URL"] = anthropicCompatibleBaseURL(provider.baseURL)
            }
            if !provider.apiKey.isEmpty {
                env["ANTHROPIC_AUTH_TOKEN"] = provider.apiKey
            }
            if !provider.primaryModel.isEmpty {
                env["ANTHROPIC_MODEL"] = provider.primaryModel
                env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = provider.primaryModel
            }
            if !provider.smallModel.isEmpty {
                env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = provider.smallModel
            }
            if !provider.largeModel.isEmpty {
                env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = provider.largeModel
            }
            return env
        case .kimiCode:
            let baseURL = provider.baseURL.trimmedSlash()
            var env: [String: String] = [:]
            if !baseURL.isEmpty {
                env["KIMI_MODEL_BASE_URL"] = baseURL
            }
            if !provider.apiKey.isEmpty {
                env["KIMI_MODEL_API_KEY"] = provider.apiKey
            }
            if !provider.primaryModel.isEmpty {
                env["KIMI_MODEL_NAME"] = provider.primaryModel
                env["KIMI_MODEL_PROVIDER_TYPE"] = "kimi"
                env["KIMI_MODEL_MAX_CONTEXT_SIZE"] = "262144"
                env["KIMI_MODEL_CAPABILITIES"] = "thinking"
                env["KIMI_MODEL_DISPLAY_NAME"] = provider.primaryModel
            }
            return env
        case .openCode, .hermes, .codex, .gemini, .universal:
            var env: [String: String] = [:]
            if !provider.baseURL.isEmpty {
                env["OPENAI_BASE_URL"] = openAICompatibleBaseURL(provider.baseURL)
            }
            if !provider.apiKey.isEmpty {
                env["OPENAI_API_KEY"] = provider.apiKey
            }
            if !provider.primaryModel.isEmpty {
                env["OPENAI_MODEL"] = provider.primaryModel
            }
            return env
        }
    }

    static func apply(_ provider: ProviderProfile) throws -> ProviderApplyResult {
        try validate(provider)
        var touched: [URL] = []
        var backups: [URL] = []

        func record(_ result: ProviderApplyResult) {
            touched.append(contentsOf: result.touchedFiles)
            backups.append(contentsOf: result.backupFiles)
        }

        switch provider.target {
        case .claudeCode:
            record(try applyClaude(provider))
        case .kimiCode:
            record(try applyKimi(provider))
        case .codex:
            record(try applyCodex(provider))
        case .gemini:
            record(try applyGemini(provider))
        case .openCode:
            record(try applyOpenCode(provider))
        case .hermes:
            record(try applyHermes(provider))
        case .universal:
            record(try applyClaude(provider))
            record(try applyCodex(provider))
            record(try applyGemini(provider))
        }

        return ProviderApplyResult(touchedFiles: touched, backupFiles: backups)
    }

    private static func validate(_ provider: ProviderProfile) throws {
        if provider.target != .claudeCode || !provider.baseURL.isEmpty {
            guard !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderApplyError.missingAPIKey
            }
        }
        let trimmed = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           URL(string: trimmed)?.scheme?.hasPrefix("http") != true {
            throw ProviderApplyError.invalidBaseURL
        }
    }

    private static func applyClaude(_ provider: ProviderProfile) throws -> ProviderApplyResult {
        let path = home(".claude/settings.json")
        var json = try readJSONObject(path)
        var env = json["env"] as? [String: Any] ?? [:]

        if provider.baseURL.isEmpty {
            env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        } else {
            env["ANTHROPIC_BASE_URL"] = anthropicCompatibleBaseURL(provider.baseURL)
        }
        if !provider.apiKey.isEmpty {
            env["ANTHROPIC_AUTH_TOKEN"] = provider.apiKey
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
        }
        if !provider.primaryModel.isEmpty {
            env["ANTHROPIC_MODEL"] = provider.primaryModel
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = provider.primaryModel
        }
        if !provider.smallModel.isEmpty {
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = provider.smallModel
        }
        if !provider.largeModel.isEmpty {
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = provider.largeModel
        }

        json["env"] = env
        let backup = try backupIfNeeded(path)
        try writeJSON(json, to: path)
        return ProviderApplyResult(touchedFiles: [path], backupFiles: backup.map { [$0] } ?? [])
    }

    private static func applyKimi(_ provider: ProviderProfile) throws -> ProviderApplyResult {
        let path = kimiConfigPath()
        let raw = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let next = upsertKimiManagedProvider(in: raw, provider: provider)

        let backup = try backupIfNeeded(path)
        try writeText(next, to: path)
        return ProviderApplyResult(touchedFiles: [path], backupFiles: backup.map { [$0] } ?? [])
    }

    private static func applyCodex(_ provider: ProviderProfile) throws -> ProviderApplyResult {
        let authPath = home(".codex/auth.json")
        let configPath = home(".codex/config.toml")
        let baseURL = codexBaseURL(provider.baseURL)
        let model = provider.primaryModel.isEmpty ? "gpt-5.5" : provider.primaryModel
        let effort = provider.codexReasoningEffort.isEmpty ? "high" : provider.codexReasoningEffort

        let auth: [String: Any] = ["OPENAI_API_KEY": provider.apiKey]
        let config = """
        model_provider = "terminalagents"
        model = "\(escapeToml(model))"
        model_reasoning_effort = "\(escapeToml(effort))"
        disable_response_storage = true

        [model_providers.terminalagents]
        name = "\(escapeToml(provider.name))"
        base_url = "\(escapeToml(baseURL))"
        wire_api = "responses"
        requires_openai_auth = true
        """

        var backups: [URL] = []
        if let backup = try backupIfNeeded(authPath) { backups.append(backup) }
        if let backup = try backupIfNeeded(configPath) { backups.append(backup) }
        try writeJSON(auth, to: authPath)
        try writeText(config + "\n", to: configPath)
        return ProviderApplyResult(touchedFiles: [authPath, configPath], backupFiles: backups)
    }

    private static func applyGemini(_ provider: ProviderProfile) throws -> ProviderApplyResult {
        let envPath = home(".gemini/.env")
        let settingsPath = home(".gemini/settings.json")
        var env = readEnv(envPath)
        env["GEMINI_API_KEY"] = provider.apiKey
        if !provider.baseURL.isEmpty {
            env["GOOGLE_GEMINI_BASE_URL"] = provider.baseURL.trimmedSlash()
        }
        if !provider.primaryModel.isEmpty {
            env["GEMINI_MODEL"] = provider.primaryModel
        }

        var settings = try readJSONObject(settingsPath)
        var security = settings["security"] as? [String: Any] ?? [:]
        var auth = security["auth"] as? [String: Any] ?? [:]
        auth["selectedType"] = "gemini-api-key"
        security["auth"] = auth
        settings["security"] = security

        var backups: [URL] = []
        if let backup = try backupIfNeeded(envPath) { backups.append(backup) }
        if let backup = try backupIfNeeded(settingsPath) { backups.append(backup) }
        try writeText(serializeEnv(env), to: envPath)
        try writeJSON(settings, to: settingsPath)
        return ProviderApplyResult(touchedFiles: [envPath, settingsPath], backupFiles: backups)
    }

    private static func applyOpenCode(_ provider: ProviderProfile) throws -> ProviderApplyResult {
        let path = home(".config/opencode/opencode.json")
        var json = try readJSONObject(path, allowJSONC: true)
        if json["$schema"] == nil {
            json["$schema"] = "https://opencode.ai/config.json"
        }
        var providers = json["provider"] as? [String: Any] ?? [:]
        let model = provider.primaryModel.isEmpty ? "gpt-5.5" : provider.primaryModel
        let packageName = provider.openCodePackage.isEmpty
            ? "@ai-sdk/openai-compatible"
            : provider.openCodePackage

        let modelMap = openCodeModelMap(for: provider)
        providers["terminalagents"] = [
            "npm": packageName,
            "name": provider.name,
            "options": [
                "baseURL": openAICompatibleBaseURL(provider.baseURL),
                "apiKey": provider.apiKey,
                "setCacheKey": true
            ],
            "models": modelMap.isEmpty ? [
                model: ["name": model]
            ] : modelMap
        ]
        json["provider"] = providers
        json["model"] = "terminalagents/\(model)"

        let backup = try backupIfNeeded(path)
        try writeJSON(json, to: path)
        return ProviderApplyResult(touchedFiles: [path], backupFiles: backup.map { [$0] } ?? [])
    }

    private static func applyHermes(_ provider: ProviderProfile) throws -> ProviderApplyResult {
        let path = home(".hermes/config.yaml")
        let raw = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        var next = upsertHermesCustomProvider(in: raw, provider: provider)
        next = replaceYAMLSection(in: next, key: "model", with: hermesModelSection(provider))

        let backup = try backupIfNeeded(path)
        try writeText(next, to: path)
        return ProviderApplyResult(touchedFiles: [path], backupFiles: backup.map { [$0] } ?? [])
    }

    private static func openCodeModelMap(for provider: ProviderProfile) -> [String: Any] {
        let models = modelIdentifiers(for: provider)
        return Dictionary(uniqueKeysWithValues: models.sorted().map { model in
            (model, ["name": model])
        })
    }

    private static func modelIdentifiers(for provider: ProviderProfile) -> Set<String> {
        Set(([provider.primaryModel] + provider.availableModels)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private static func codexBaseURL(_ raw: String) -> String {
        openAICompatibleBaseURL(raw, defaultValue: "https://api.openai.com/v1")
    }

    private static func openAICompatibleBaseURL(_ raw: String, defaultValue: String = "") -> String {
        let trimmed = raw.trimmedSlash()
        guard !trimmed.isEmpty else { return defaultValue }
        guard let url = URL(string: trimmed),
              let host = url.host,
              url.path.isEmpty || url.path == "/" else {
            return trimmed
        }
        if trimmed.hasSuffix("/v1") { return trimmed }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        components.port = url.port
        components.path = "/v1"
        return components.url?.absoluteString ?? "\(url.scheme ?? "https")://\(host)/v1"
    }

    private static func anthropicCompatibleBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmedSlash()
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasSuffix("/anthropic") ||
            lower.hasSuffix("/api/anthropic") ||
            lower.hasSuffix("/claudecode") ||
            lower.hasSuffix("/api/claudecode") ||
            lower.hasSuffix("/coding") ||
            lower.hasSuffix("/api/coding") ||
            lower.hasSuffix("/v1") {
            return trimmed
        }
        guard let url = URL(string: trimmed),
              url.host != nil,
              url.path.isEmpty || url.path == "/" else {
            return trimmed
        }
        return "\(trimmed)/anthropic"
    }

    private static func kimiConfigPath() -> URL {
        if let raw = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw).appendingPathComponent("config.toml")
        }
        return home(".kimi-code/config.toml")
    }

    private static func upsertKimiManagedProvider(in raw: String, provider: ProviderProfile) -> String {
        let defaultModel = kimiModelAlias(for: kimiDefaultModel(provider))
        var result = replaceTopLevelTomlString(in: raw,
                                               key: "default_model",
                                               value: defaultModel)
        result = replaceManagedBlock(in: result,
                                     start: "# BEGIN TERMINALAGENTS KIMI PROVIDER",
                                     end: "# END TERMINALAGENTS KIMI PROVIDER",
                                     block: kimiManagedBlock(provider))
        if !result.hasSuffix("\n") {
            result.append("\n")
        }
        return result
    }

    private static func kimiManagedBlock(_ provider: ProviderProfile) -> String {
        let providerID = "managed:kimi-code"
        let baseURL = provider.baseURL.trimmedSlash()
        let models = Array(modelIdentifiers(for: provider)).sorted()
        let effectiveModels = models.isEmpty ? [kimiDefaultModel(provider)] : models
        let modelBlocks = effectiveModels.map { model in
            """
            [models.\(tomlDottedQuoted(kimiModelAlias(for: model)))]
            provider = \(tomlQuote(providerID))
            model_name = \(tomlQuote(model))
            display_name = \(tomlQuote(model))
            max_context_size = 262144
            capabilities = ["thinking"]
            """
        }.joined(separator: "\n\n")

        return """
        # BEGIN TERMINALAGENTS KIMI PROVIDER
        # Managed by TerminalAgents. Edit this app's Provider settings instead of this block.
        [providers.\(tomlDottedQuoted(providerID))]
        type = "kimi"
        base_url = \(tomlQuote(baseURL))
        api_key = \(tomlQuote(provider.apiKey))

        \(modelBlocks)
        # END TERMINALAGENTS KIMI PROVIDER
        """
    }

    private static func kimiModelAlias(for model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("kimi-code/") ? trimmed : "kimi-code/\(trimmed)"
    }

    private static func kimiDefaultModel(_ provider: ProviderProfile) -> String {
        let trimmed = provider.primaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "kimi-for-coding" : trimmed
    }

    private static func replaceManagedBlock(in raw: String,
                                            start: String,
                                            end: String,
                                            block: String) -> String {
        let normalizedBlock = block.trimmingCharacters(in: .newlines)
        if let startRange = raw.range(of: start),
           let endRange = raw.range(of: end, range: startRange.lowerBound..<raw.endIndex) {
            var result = raw
            result.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: normalizedBlock)
            return result
        }
        var result = raw.trimmingCharacters(in: .newlines)
        if !result.isEmpty {
            result.append("\n\n")
        }
        result.append(normalizedBlock)
        return result
    }

    private static func replaceTopLevelTomlString(in raw: String, key: String, value: String) -> String {
        let assignment = "\(key) = \(tomlQuote(value))"
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var replaced = false
        var inTopLevel = true

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inTopLevel = false
            }
            if inTopLevel,
               !trimmed.hasPrefix("#"),
               trimmed.hasPrefix("\(key)") {
                let remainder = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if remainder.hasPrefix("=") {
                    if !replaced {
                        result.append(assignment)
                        replaced = true
                    }
                    continue
                }
            }
            result.append(line)
        }

        if !replaced {
            if result.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                result.insert("", at: 0)
            }
            result.insert(assignment, at: 0)
        }
        return result.joined(separator: "\n")
    }

    private static func home(_ relative: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
    }

    private static func readJSONObject(_ url: URL, allowJSONC: Bool = false) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        let preparedData: Data
        if allowJSONC, let text = String(data: data, encoding: .utf8) {
            preparedData = Data(prepareJSONC(text).utf8)
        } else {
            preparedData = data
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: preparedData) as? [String: Any] else {
                throw ProviderApplyError.invalidJSON(url, "top-level value is not an object")
            }
            return object
        } catch let error as ProviderApplyError {
            throw error
        } catch {
            throw ProviderApplyError.invalidJSON(url, error.localizedDescription)
        }
    }

    private static func writeJSON(_ value: Any, to url: URL) throws {
        try ensureParent(url)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try secure(url)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try ensureParent(url)
        guard let data = text.data(using: .utf8) else {
            throw ProviderApplyError.writeFailed("Could not encode text for \(url.path)")
        }
        try data.write(to: url, options: .atomic)
        try secure(url)
    }

    private static func backupIfNeeded(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = backupStamp()
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).terminalagents-backup-\(stamp)")
        try ensureParent(backup)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    private static func ensureParent(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private static func secure(_ url: URL) throws {
        #if os(macOS)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    private static func readEnv(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let idx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func serializeEnv(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n") + "\n"
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func escapeToml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func tomlQuote(_ value: String) -> String {
        "\"\(escapeToml(value))\""
    }

    private static func tomlDottedQuoted(_ value: String) -> String {
        value.split(separator: ".").map { tomlQuote(String($0)) }.joined(separator: ".")
    }

    private static func hermesModelSection(_ provider: ProviderProfile) -> String {
        """
        model:
          default: \(yamlQuote(provider.primaryModel))
          provider: \(yamlQuote("terminalagents"))
          base_url: \(yamlQuote(hermesBaseURL(provider.baseURL)))
        """
    }

    private static func hermesProviderBlock(_ provider: ProviderProfile) -> String {
        let uniqueModels = Array(modelIdentifiers(for: provider)).sorted()
        let modelLines = uniqueModels.isEmpty
            ? ""
            : "\n    models:\n" + uniqueModels.map { "      \(yamlQuote($0)): {}" }.joined(separator: "\n")
        let singularModel = provider.primaryModel.isEmpty ? "" : "\n    model: \(yamlQuote(provider.primaryModel))"
        return """
          - name: terminalagents
            base_url: \(yamlQuote(hermesBaseURL(provider.baseURL)))
            api_key: \(yamlQuote(provider.apiKey))\(singularModel)\(modelLines)
            api_mode: chat_completions
        """
    }

    private static func hermesBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmedSlash()
        guard !trimmed.isEmpty else { return trimmed }
        if endsWithVersionSegment(trimmed) { return trimmed }
        if trimmed.hasSuffix("/chat/completions") {
            return String(trimmed.dropLast("/chat/completions".count))
        }
        if trimmed.hasSuffix("/v1") || trimmed.hasSuffix("/openai") {
            return trimmed
        }
        guard let url = URL(string: trimmed),
              url.host != nil,
              url.path.isEmpty || url.path == "/" else {
            return trimmed
        }
        return "\(trimmed)/v1"
    }

    private static func endsWithVersionSegment(_ raw: String) -> Bool {
        guard let last = raw.split(separator: "/").last,
              last.first == "v" else {
            return false
        }
        let digits = last.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    private static func upsertHermesCustomProvider(in raw: String, provider: ProviderProfile) -> String {
        let block = hermesProviderBlock(provider)
        guard let range = yamlSectionRange(in: raw, key: "custom_providers") else {
            var result = raw
            if !result.isEmpty, !result.hasSuffix("\n") {
                result.append("\n")
            }
            result.append("custom_providers:\n")
            result.append(block)
            result.append("\n")
            return result
        }

        let section = String(raw[range])
        let cleaned = removeHermesManagedProvider(fromCustomProvidersSection: section)
            .trimmingCharacters(in: .newlines)
        let replacement: String
        if cleaned == "custom_providers:" {
            replacement = "custom_providers:\n\(block)\n"
        } else {
            replacement = "\(cleaned)\n\(block)\n"
        }

        var result = raw
        result.replaceSubrange(range, with: replacement)
        return result
    }

    private static func removeHermesManagedProvider(fromCustomProvidersSection section: String) -> String {
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return section }

        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("  - name: terminalagents") || line.hasPrefix("- name: terminalagents") {
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.hasPrefix("  - ") || current.hasPrefix("- ") {
                        break
                    }
                    index += 1
                }
                continue
            }
            result.append(line)
            index += 1
        }
        return result.joined(separator: "\n")
    }

    private static func replaceYAMLSection(in raw: String, key: String, with section: String) -> String {
        let normalized = section.hasSuffix("\n") ? section : section + "\n"
        guard let range = yamlSectionRange(in: raw, key: key) else {
            var result = raw
            if !result.isEmpty, !result.hasSuffix("\n") {
                result.append("\n")
            }
            result.append(normalized)
            return result
        }
        var result = raw
        result.replaceSubrange(range, with: normalized)
        return result
    }

    private static func yamlSectionRange(in raw: String, key: String) -> Range<String.Index>? {
        let target = "\(key):"
        var start: String.Index?
        var lineStart = raw.startIndex

        while lineStart < raw.endIndex {
            let lineEnd = raw[lineStart...].firstIndex(of: "\n") ?? raw.endIndex
            let line = String(raw[lineStart..<lineEnd])
            if start == nil,
               isTopLevelYAMLKeyLine(line),
               line.hasPrefix(target) {
                start = lineStart
            } else if let sectionStart = start,
                      isTopLevelYAMLKeyLine(line) {
                return sectionStart..<lineStart
            }
            lineStart = lineEnd == raw.endIndex ? raw.endIndex : raw.index(after: lineEnd)
        }
        if let start {
            return start..<raw.endIndex
        }
        return nil
    }

    private static func isTopLevelYAMLKeyLine(_ line: String) -> Bool {
        guard let first = line.first,
              first != " ",
              first != "\t",
              first != "#",
              first != "-" else {
            return false
        }
        guard let colon = line.firstIndex(of: ":") else { return false }
        let after = line[line.index(after: colon)...]
        return after.isEmpty || after.first == " " || after.first == "\t" || after.first == "\r"
    }

    private static func yamlQuote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func prepareJSONC(_ text: String) -> String {
        removeTrailingCommas(from: stripJSONComments(from: text))
    }

    private static func stripJSONComments(from text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)

            if inString {
                result.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index = next
                continue
            }

            if char == "\"" {
                inString = true
                result.append(char)
                index = next
                continue
            }

            if char == "/", next < text.endIndex {
                let lookahead = text[next]
                if lookahead == "/" {
                    index = text.index(after: next)
                    while index < text.endIndex, !text[index].isNewline {
                        index = text.index(after: index)
                    }
                    continue
                }
                if lookahead == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let commentNext = text.index(after: index)
                        if text[index] == "*", commentNext < text.endIndex, text[commentNext] == "/" {
                            index = text.index(after: commentNext)
                            break
                        }
                        index = commentNext
                    }
                    continue
                }
            }

            result.append(char)
            index = next
        }

        return result
    }

    private static func removeTrailingCommas(from text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let char = text[index]

            if inString {
                result.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if char == "\"" {
                inString = true
                result.append(char)
                index = text.index(after: index)
                continue
            }

            if char == "," {
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex, text[lookahead].isWhitespace {
                    lookahead = text.index(after: lookahead)
                }
                if lookahead < text.endIndex, text[lookahead] == "}" || text[lookahead] == "]" {
                    index = text.index(after: index)
                    continue
                }
            }

            result.append(char)
            index = text.index(after: index)
        }

        return result
    }
}

private extension String {
    func trimmedSlash() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }
}
