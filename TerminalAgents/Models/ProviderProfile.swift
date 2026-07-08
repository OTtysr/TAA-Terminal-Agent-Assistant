import Foundation

enum ProviderTarget: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case kimiCode
    case codex
    case gemini
    case openCode
    case hermes
    case universal

    var id: String { rawValue }

    static var primaryAgentTools: [ProviderTarget] {
        [.kimiCode, .openCode, .claudeCode, .hermes]
    }

    func label(language: AppLanguage) -> String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .kimiCode: return "KimiCode"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .openCode: return "OpenCode"
        case .hermes: return "Hermes"
        case .universal: return language == .chinese ? "通用 Provider" : "Universal Provider"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode: return "brain.head.profile"
        case .kimiCode: return "moon.stars"
        case .openCode: return "terminal"
        case .hermes: return "sparkle.magnifyingglass"
        case .codex: return "curlybraces"
        case .gemini: return "sparkles"
        case .universal: return "square.stack.3d.up"
        }
    }
}

struct ProviderProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var target: ProviderTarget
    var baseURL: String
    var apiKey: String
    var primaryModel: String
    var smallModel: String
    var largeModel: String
    var modelsURLOverride: String = ""
    var availableModels: [String] = []
    var codexReasoningEffort: String = "high"
    var openCodePackage: String = "@ai-sdk/openai-compatible"
    var websiteURL: String? = nil
    var notes: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastActivatedAt: Date? = nil

    var displayBaseURL: String {
        baseURL.isEmpty ? "official/default" : baseURL
    }

    init(id: UUID = UUID(),
         name: String,
         target: ProviderTarget,
         baseURL: String,
         apiKey: String,
         primaryModel: String,
         smallModel: String,
         largeModel: String,
         modelsURLOverride: String = "",
         availableModels: [String] = [],
         codexReasoningEffort: String = "high",
         openCodePackage: String = "@ai-sdk/openai-compatible",
         websiteURL: String? = nil,
         notes: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         lastActivatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.target = target
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.primaryModel = primaryModel
        self.smallModel = smallModel
        self.largeModel = largeModel
        self.modelsURLOverride = modelsURLOverride
        self.availableModels = availableModels
        self.codexReasoningEffort = codexReasoningEffort
        self.openCodePackage = openCodePackage
        self.websiteURL = websiteURL
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivatedAt = lastActivatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case target
        case baseURL
        case apiKey
        case primaryModel
        case smallModel
        case largeModel
        case modelsURLOverride
        case availableModels
        case codexReasoningEffort
        case openCodePackage
        case websiteURL
        case notes
        case createdAt
        case updatedAt
        case lastActivatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        target = try container.decode(ProviderTarget.self, forKey: .target)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        primaryModel = try container.decodeIfPresent(String.self, forKey: .primaryModel) ?? ""
        smallModel = try container.decodeIfPresent(String.self, forKey: .smallModel) ?? ""
        largeModel = try container.decodeIfPresent(String.self, forKey: .largeModel) ?? ""
        modelsURLOverride = try container.decodeIfPresent(String.self, forKey: .modelsURLOverride) ?? ""
        availableModels = try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        codexReasoningEffort = try container.decodeIfPresent(String.self, forKey: .codexReasoningEffort) ?? "high"
        openCodePackage = try container.decodeIfPresent(String.self, forKey: .openCodePackage) ?? "@ai-sdk/openai-compatible"
        websiteURL = try container.decodeIfPresent(String.self, forKey: .websiteURL)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lastActivatedAt = try container.decodeIfPresent(Date.self, forKey: .lastActivatedAt)
    }

    static func defaultProfile(for target: ProviderTarget) -> ProviderProfile {
        switch target {
        case .claudeCode:
            return ProviderProfile(name: "Claude Code Provider",
                                   target: .claudeCode,
                                   baseURL: "",
                                   apiKey: "",
                                   primaryModel: "claude-sonnet-4-5-20250929",
                                   smallModel: "claude-haiku-4-5-20251001",
                                   largeModel: "claude-opus-4-5-20251101",
                                   openCodePackage: "@ai-sdk/anthropic",
                                   websiteURL: "https://www.anthropic.com/claude-code")
        case .kimiCode:
            return ProviderProfile(name: "KimiCode Provider",
                                   target: .kimiCode,
                                   baseURL: "https://api.kimi.com/coding/v1",
                                   apiKey: "",
                                   primaryModel: "kimi-for-coding",
                                   smallModel: "",
                                   largeModel: "",
                                   availableModels: ["kimi-for-coding"],
                                   openCodePackage: "@ai-sdk/anthropic",
                                   websiteURL: "https://platform.moonshot.cn")
        case .openCode:
            return ProviderProfile(name: "OpenCode Provider",
                                   target: .openCode,
                                   baseURL: "https://api.example.com/v1",
                                   apiKey: "",
                                   primaryModel: "gpt-5.5",
                                   smallModel: "",
                                   largeModel: "",
                                   availableModels: ["gpt-5.5"],
                                   openCodePackage: "@ai-sdk/openai-compatible")
        case .hermes:
            return ProviderProfile(name: "Hermes Provider",
                                   target: .hermes,
                                   baseURL: "https://api.example.com/v1",
                                   apiKey: "",
                                   primaryModel: "gpt-5.5",
                                   smallModel: "",
                                   largeModel: "",
                                   availableModels: ["gpt-5.5"],
                                   openCodePackage: "@ai-sdk/openai-compatible")
        case .codex:
            return ProviderPreset.all.first { $0.target == .codex }?.makeProfile()
                ?? ProviderProfile(name: "Codex Provider", target: .codex, baseURL: "https://api.openai.com/v1", apiKey: "", primaryModel: "gpt-5.5", smallModel: "gpt-5.5", largeModel: "gpt-5.5")
        case .gemini:
            return ProviderPreset.all.first { $0.target == .gemini }?.makeProfile()
                ?? ProviderProfile(name: "Gemini Provider", target: .gemini, baseURL: "https://generativelanguage.googleapis.com", apiKey: "", primaryModel: "gemini-3.5-flash", smallModel: "gemini-2.5-flash-lite", largeModel: "gemini-3.5-pro")
        case .universal:
            return ProviderPreset.all.first { $0.target == .universal }?.makeProfile()
                ?? ProviderProfile(name: "Universal Provider", target: .universal, baseURL: "https://api.example.com", apiKey: "", primaryModel: "claude-sonnet-5", smallModel: "claude-haiku-4-5-20251001", largeModel: "claude-opus-4-8")
        }
    }
}

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let target: ProviderTarget
    let baseURL: String
    let primaryModel: String
    let smallModel: String
    let largeModel: String
    let codexReasoningEffort: String
    let openCodePackage: String
    let websiteURL: String?

    func makeProfile(apiKey: String = "") -> ProviderProfile {
        ProviderProfile(name: name,
                        target: target,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        primaryModel: primaryModel,
                        smallModel: smallModel,
                        largeModel: largeModel,
                        codexReasoningEffort: codexReasoningEffort,
                        openCodePackage: openCodePackage,
                        websiteURL: websiteURL)
    }

    static let all: [ProviderPreset] = [
        ProviderPreset(id: "claude-official",
                       name: "Claude Official",
                       target: .claudeCode,
                       baseURL: "",
                       primaryModel: "claude-sonnet-4-5-20250929",
                       smallModel: "claude-haiku-4-5-20251001",
                       largeModel: "claude-opus-4-5-20251101",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/anthropic",
                       websiteURL: "https://www.anthropic.com/claude-code"),
        ProviderPreset(id: "anthropic-compatible",
                       name: "Anthropic Compatible",
                       target: .claudeCode,
                       baseURL: "https://api.example.com/anthropic",
                       primaryModel: "claude-sonnet-4-5-20250929",
                       smallModel: "claude-haiku-4-5-20251001",
                       largeModel: "claude-opus-4-5-20251101",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/anthropic",
                       websiteURL: nil),
        ProviderPreset(id: "newapi-universal",
                       name: "NewAPI Universal",
                       target: .universal,
                       baseURL: "https://your-newapi.example.com",
                       primaryModel: "claude-sonnet-5",
                       smallModel: "claude-haiku-4-5-20251001",
                       largeModel: "claude-opus-4-8",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/openai-compatible",
                       websiteURL: "https://www.newapi.pro"),
        ProviderPreset(id: "openrouter-claude",
                       name: "OpenRouter Claude",
                       target: .claudeCode,
                       baseURL: "https://openrouter.ai/api/v1",
                       primaryModel: "anthropic/claude-sonnet-4.5",
                       smallModel: "anthropic/claude-haiku-4.5",
                       largeModel: "anthropic/claude-opus-4.5",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/openai-compatible",
                       websiteURL: "https://openrouter.ai"),
        ProviderPreset(id: "deepseek-anthropic",
                       name: "DeepSeek Anthropic",
                       target: .claudeCode,
                       baseURL: "https://api.deepseek.com/anthropic",
                       primaryModel: "deepseek-chat",
                       smallModel: "deepseek-chat",
                       largeModel: "deepseek-reasoner",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/anthropic",
                       websiteURL: "https://platform.deepseek.com"),
        ProviderPreset(id: "codex-openai",
                       name: "OpenAI Codex",
                       target: .codex,
                       baseURL: "https://api.openai.com/v1",
                       primaryModel: "gpt-5.5",
                       smallModel: "gpt-5.5",
                       largeModel: "gpt-5.5",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/openai",
                       websiteURL: "https://platform.openai.com"),
        ProviderPreset(id: "gemini-google",
                       name: "Google Gemini",
                       target: .gemini,
                       baseURL: "https://generativelanguage.googleapis.com",
                       primaryModel: "gemini-3.5-flash",
                       smallModel: "gemini-2.5-flash-lite",
                       largeModel: "gemini-3.5-pro",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/google",
                       websiteURL: "https://ai.google.dev"),
        ProviderPreset(id: "opencode-compatible",
                       name: "OpenCode Compatible",
                       target: .openCode,
                       baseURL: "https://api.example.com/v1",
                       primaryModel: "gpt-5.5",
                       smallModel: "gpt-5.5-mini",
                       largeModel: "gpt-5.5",
                       codexReasoningEffort: "high",
                       openCodePackage: "@ai-sdk/openai-compatible",
                       websiteURL: nil)
    ]
}
