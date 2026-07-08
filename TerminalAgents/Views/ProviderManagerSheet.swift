import SwiftUI
import UniformTypeIdentifiers

struct ProviderManagerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTarget: ProviderTarget = .kimiCode
    @State private var isImportingProviders = false
    @State private var isExportingProviders = false
    @State private var exportDocument = ProviderExchangeDocument()

    private var selectedIndex: Int? {
        appState.providerIndex(for: selectedTarget)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                providerToolbar
                List(selection: $selectedTarget) {
                    Section(appState.text(.mainAgents)) {
                        ForEach(ProviderTarget.primaryAgentTools) { target in
                            ProviderToolRow(target: target, provider: appState.provider(for: target))
                                .tag(target)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationTitle(appState.text(.providers))
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            if let idx = selectedIndex {
                ProviderToolEditor(provider: $appState.providers[idx])
                    .id(appState.providers[idx].id)
            } else {
                ContentUnavailableView(appState.text(.providers),
                                       systemImage: selectedTarget.iconName,
                                       description: Text(appState.text(.providerHelp)))
                    .onAppear {
                        appState.ensureProvider(for: selectedTarget)
                    }
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(appState.text(.cancel)) { dismiss() }
            }
        }
        .onAppear {
            for target in ProviderTarget.primaryAgentTools {
                appState.ensureProvider(for: target)
            }
        }
        .fileImporter(isPresented: $isImportingProviders,
                      allowedContentTypes: [.json]) { result in
            importProviders(result)
        }
        .fileExporter(isPresented: $isExportingProviders,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: "terminalagents-providers.json") { result in
            if case .failure(let error) = result {
                appState.providerStatusMessage = error.localizedDescription
            }
        }
        .alert(appState.text(.providers),
               isPresented: Binding(get: { appState.providerStatusMessage != nil },
                                    set: { if !$0 { appState.providerStatusMessage = nil } })) {
            Button("OK", role: .cancel) { appState.providerStatusMessage = nil }
        } message: {
            Text(appState.providerStatusMessage ?? "")
        }
    }

    private var providerToolbar: some View {
        HStack(spacing: 10) {
            Button {
                isImportingProviders = true
            } label: {
                Label(appState.text(.importProviders), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)

            Button {
                exportDocument = ProviderExchangeDocument(providers: appState.providers)
                isExportingProviders = true
            } label: {
                Label(appState.text(.exportProviders), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func importProviders(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let payload = try? decoder.decode(ProviderExchangePayload.self, from: data) {
                appState.importProviders(payload.providers)
            } else {
                appState.importProviders(try decoder.decode([ProviderProfile].self, from: data))
            }
        } catch {
            appState.providerStatusMessage = error.localizedDescription
        }
    }
}

private struct ProviderToolRow: View {
    let target: ProviderTarget
    let provider: ProviderProfile?
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: target.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.label(language: appState.appLanguage))
                    .font(.headline)
                Text(provider?.displayBaseURL ?? "official/default")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if provider.flatMap({ appState.activeProviderIDs.contains($0.id) }) == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderToolEditor: View {
    @Binding var provider: ProviderProfile
    @EnvironmentObject var appState: AppState
    @State private var isFetchingModels = false
    @State private var modelFetchMessage: String?

    var body: some View {
        Form {
            Section {
                Text(appState.text(.providerHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(appState.text(.targetTool)) {
                    Label(provider.target.label(language: appState.appLanguage), systemImage: provider.target.iconName)
                }
                TextField(appState.text(.name), text: $provider.name)
                TextField(appState.text(.baseURL), text: $provider.baseURL)
                    .font(.system(.body, design: .monospaced))
                SecureField(appState.text(.apiKey), text: $provider.apiKey)
                    .font(.system(.body, design: .monospaced))
            }

            modelMappingSection
            toolSpecificSection

            Section {
                HStack {
                    Button(appState.text(.save)) {
                        appState.saveProvider(provider)
                    }
                    Button {
                        appState.saveProvider(provider)
                        appState.activateProvider(provider)
                    } label: {
                        Label(appState.text(.activateProvider), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    if appState.activeProviderIDs.contains(provider.id) {
                        Label(appState.text(.lastActivated), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .navigationTitle(provider.target.label(language: appState.appLanguage))
    }

    @ViewBuilder
    private var modelMappingSection: some View {
        Section(appState.text(.modelMapping)) {
            modelFetchControls

            if let modelFetchMessage {
                Text(modelFetchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch provider.target {
            case .claudeCode:
                ModelField(title: localized(zh: "Sonnet 模型", en: "Sonnet Model"),
                           value: $provider.primaryModel,
                           options: provider.availableModels)
                ModelField(title: localized(zh: "Haiku 模型", en: "Haiku Model"),
                           value: $provider.smallModel,
                           options: provider.availableModels)
                ModelField(title: localized(zh: "Opus 模型", en: "Opus Model"),
                           value: $provider.largeModel,
                           options: provider.availableModels)
            case .kimiCode, .openCode, .hermes:
                ModelField(title: localized(zh: "默认模型", en: "Default Model"),
                           value: $provider.primaryModel,
                           options: provider.availableModels)
                EditableModelList(models: $provider.availableModels,
                                  defaultModel: $provider.primaryModel,
                                  title: localized(zh: "模型列表", en: "Models"),
                                  addTitle: localized(zh: "添加模型", en: "Add Model"),
                                  deleteTitle: appState.text(.delete))
            default:
                ModelField(title: appState.text(.primaryModel),
                           value: $provider.primaryModel,
                           options: provider.availableModels)
            }
        }
    }

    private var modelFetchControls: some View {
        HStack {
            Button {
                fetchModels()
            } label: {
                if isFetchingModels {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(appState.text(.fetchModels), systemImage: "arrow.down.circle")
                }
            }
            .disabled(isFetchingModels)

            Button(appState.text(.autoMapModels)) {
                applyAutoMapping()
            }
            .disabled(provider.availableModels.isEmpty)

            Spacer()

            Text(modelCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var toolSpecificSection: some View {
        switch provider.target {
        case .openCode:
            Section("OpenCode") {
                Picker(appState.text(.openCodePackage), selection: $provider.openCodePackage) {
                    Text("OpenAI Compatible").tag("@ai-sdk/openai-compatible")
                    Text("OpenAI Responses").tag("@ai-sdk/openai")
                    Text("Anthropic").tag("@ai-sdk/anthropic")
                    Text("Google Gemini").tag("@ai-sdk/google")
                    Text("Amazon Bedrock").tag("@ai-sdk/amazon-bedrock")
                }
            }
        case .claudeCode:
            Section("Claude Code") {
                LabeledContent(appState.text(.configPath), value: "~/.claude/settings.json")
            }
        case .kimiCode:
            Section("KimiCode") {
                LabeledContent(appState.text(.configPath), value: "~/.kimi-code/config.toml")
            }
        case .hermes:
            Section("Hermes") {
                LabeledContent(appState.text(.configPath), value: "~/.hermes/config.yaml")
            }
        default:
            EmptyView()
        }
    }

    private var modelCountText: String {
        provider.availableModels.isEmpty
            ? appState.text(.noModelsDetected)
            : "\(provider.availableModels.count) \(appState.text(.modelsDetected))"
    }

    private func fetchModels() {
        isFetchingModels = true
        modelFetchMessage = nil
        let snapshot = provider
        Task {
            do {
                let models = try await ProviderModelFetcher.fetchModels(for: snapshot)
                let ids = models.map(\.id)
                await MainActor.run {
                    provider.availableModels = ids
                    applyAutoMapping()
                    appState.saveProvider(provider)
                    modelFetchMessage = appState.text(.modelsFetched)
                    isFetchingModels = false
                }
            } catch {
                await MainActor.run {
                    modelFetchMessage = error.localizedDescription
                    isFetchingModels = false
                }
            }
        }
    }

    private func applyAutoMapping() {
        let mapping = ProviderModelFetcher.autoMap(models: provider.availableModels, for: provider.target)
        if !mapping.primary.isEmpty { provider.primaryModel = mapping.primary }
        switch provider.target {
        case .claudeCode:
            if !mapping.small.isEmpty { provider.smallModel = mapping.small }
            if !mapping.large.isEmpty { provider.largeModel = mapping.large }
        case .kimiCode, .openCode, .hermes:
            provider.smallModel = ""
            provider.largeModel = ""
        default:
            break
        }
    }

    private func localized(zh: String, en: String) -> String {
        appState.appLanguage == .chinese ? zh : en
    }
}

private struct ModelField: View {
    let title: String
    @Binding var value: String
    let options: [String]

    var body: some View {
        if options.isEmpty {
            TextField(title, text: $value)
                .font(.system(.body, design: .monospaced))
        } else {
            Picker(title, selection: $value) {
                if value.isEmpty {
                    Text("").tag("")
                }
                ForEach(options, id: \.self) { model in
                    Text(model).tag(model)
                }
                if !value.isEmpty, !options.contains(value) {
                    Text(value).tag(value)
                }
            }
        }
    }
}

private struct EditableModelList: View {
    @Binding var models: [String]
    @Binding var defaultModel: String
    let title: String
    let addTitle: String
    let deleteTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addModel()
                } label: {
                    Label(addTitle, systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            if models.isEmpty {
                TextField(addTitle, text: $defaultModel)
                    .font(.system(.body, design: .monospaced))
            } else {
                ForEach(models.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField(title, text: modelBinding(at: index))
                            .font(.system(.body, design: .monospaced))
                        Button {
                            removeModel(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(deleteTitle)
                    }
                }
            }
        }
    }

    private func modelBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard models.indices.contains(index) else { return "" }
                return models[index]
            },
            set: { newValue in
                guard models.indices.contains(index) else { return }
                let oldValue = models[index]
                models[index] = newValue
                if defaultModel == oldValue {
                    defaultModel = newValue
                }
            }
        )
    }

    private func addModel() {
        let candidate = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty, !models.contains(candidate) {
            models.append(candidate)
        } else {
            models.append("")
        }
    }

    private func removeModel(at index: Int) {
        guard models.indices.contains(index) else { return }
        let removed = models.remove(at: index)
        if defaultModel == removed {
            defaultModel = models.first ?? ""
        }
    }
}
