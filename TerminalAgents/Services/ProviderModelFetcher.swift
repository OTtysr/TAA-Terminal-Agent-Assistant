import Foundation

struct ProviderModel: Identifiable, Hashable {
    var id: String
    var ownedBy: String?
}

enum ProviderModelFetchError: LocalizedError {
    case missingAPIKey
    case emptyBaseURL
    case invalidEndpoint
    case requestFailed(String)
    case parseFailed(String)
    case allCandidatesFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API Key is required to fetch models."
        case .emptyBaseURL:
            return "Base URL is required to fetch models."
        case .invalidEndpoint:
            return "Cannot derive models endpoint from this URL."
        case .requestFailed(let message), .parseFailed(let message), .allCandidatesFailed(let message):
            return message
        }
    }
}

enum ProviderModelFetcher {
    private static let knownCompatSuffixes = [
        "/api/claudecode",
        "/api/anthropic",
        "/apps/anthropic",
        "/api/coding",
        "/claudecode",
        "/anthropic",
        "/step_plan",
        "/coding",
        "/claude"
    ]

    static func fetchModels(for provider: ProviderProfile) async throws -> [ProviderModel] {
        let apiKey = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw ProviderModelFetchError.missingAPIKey }

        let candidates = try modelURLCandidates(baseURL: provider.baseURL)
        var lastError: String?

        for endpoint in candidates {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("TerminalAgents/0.1", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderModelFetchError.requestFailed("Invalid response from \(endpoint.absoluteString)")
                }
                if (200..<300).contains(http.statusCode) {
                    let models = try parseModels(data)
                    return models.sorted { $0.id < $1.id }
                }
                let body = String(data: data, encoding: .utf8).map(truncate) ?? ""
                if http.statusCode == 404 || http.statusCode == 405 {
                    lastError = "HTTP \(http.statusCode): \(body)"
                    continue
                }
                throw ProviderModelFetchError.requestFailed("HTTP \(http.statusCode): \(body)")
            } catch let error as ProviderModelFetchError {
                throw error
            } catch {
                throw ProviderModelFetchError.requestFailed(error.localizedDescription)
            }
        }

        throw ProviderModelFetchError.allCandidatesFailed(
            "All model endpoints failed: \(lastError ?? "no candidates")"
        )
    }

    static func modelURLCandidates(baseURL: String) throws -> [URL] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmedSlash()
        guard !trimmed.isEmpty else { throw ProviderModelFetchError.emptyBaseURL }

        var candidates: [String] = []
        if endsWithVersionSegment(trimmed) {
            candidates.append("\(trimmed)/models")
            if !trimmed.hasSuffix("/v1") {
                candidates.append("\(trimmed)/v1/models")
            }
        } else {
            candidates.append("\(trimmed)/v1/models")
        }

        if let stripped = stripCompatSuffix(trimmed) {
            let root = stripped.trimmedSlash()
            if !root.isEmpty, root.contains("://") {
                candidates.append("\(root)/v1/models")
                candidates.append("\(root)/models")
            }
        }

        var unique: [URL] = []
        for candidate in candidates where !unique.contains(where: { $0.absoluteString == candidate }) {
            if let url = URL(string: candidate) {
                unique.append(url)
            }
        }
        guard !unique.isEmpty else { throw ProviderModelFetchError.invalidEndpoint }
        return unique
    }

    static func autoMap(models: [String], for target: ProviderTarget) -> (primary: String, small: String, large: String) {
        let sorted = models.sorted()
        func first(containing needles: [String]) -> String? {
            sorted.first { model in
                let lower = model.lowercased()
                return needles.contains { lower.contains($0) }
            }
        }

        switch target {
        case .claudeCode:
            let primary = first(containing: ["sonnet", "k2", "kimi", "claude"]) ?? sorted.first ?? ""
            let small = first(containing: ["haiku", "mini", "small", "lite", "flash"]) ?? primary
            let large = first(containing: ["opus", "large", "pro", "reasoner"]) ?? primary
            return (primary, small, large)
        case .kimiCode:
            let primary = first(containing: ["kimi-for-coding", "kimi", "moonshot", "k2"]) ?? sorted.first ?? ""
            return (primary, "", "")
        case .openCode, .hermes, .codex, .universal:
            let primary = first(containing: ["gpt", "claude", "kimi", "deepseek", "qwen"]) ?? sorted.first ?? ""
            return (primary, "", "")
        case .gemini:
            let primary = first(containing: ["flash", "gemini"]) ?? sorted.first ?? ""
            let small = first(containing: ["lite", "flash"]) ?? primary
            let large = first(containing: ["pro", "ultra"]) ?? primary
            return (primary, small, large)
        }
    }

    private static func parseModels(_ data: Data) throws -> [ProviderModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderModelFetchError.parseFailed("Failed to parse response.")
        }
        let entries = object["data"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return ProviderModel(id: id, ownedBy: entry["owned_by"] as? String)
        }
    }

    private static func endsWithVersionSegment(_ raw: String) -> Bool {
        guard let last = raw.split(separator: "/").last else { return false }
        guard last.first == "v" else { return false }
        let digits = last.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    private static func stripCompatSuffix(_ raw: String) -> String? {
        for suffix in knownCompatSuffixes where raw.hasSuffix(suffix) {
            return String(raw.dropLast(suffix.count))
        }
        return nil
    }

    private static func truncate(_ text: String) -> String {
        if text.count <= 512 { return text }
        return String(text.prefix(512)) + "..."
    }
}

private extension String {
    func trimmedSlash() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }
}
