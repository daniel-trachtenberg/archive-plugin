import SwiftUI

private struct FixedLTRTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FixedLTRTextField

        init(parent: FixedLTRTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.isBezeled = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.alignment = .left
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.baseWritingDirection = .leftToRight
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }
}

private enum ProviderMode: String, CaseIterable, Identifiable {
    case local
    case cloud

    var id: String { rawValue }
    var title: String { self == .local ? "Local" : "Cloud" }
}

private enum CloudVendor: String, CaseIterable, Identifiable {
    case openai
    case anthropic

    var id: String { rawValue }
    var title: String { self == .openai ? "OpenAI" : "Anthropic" }
}

struct SettingsView: View {
    @Binding var isSettingsViewShowing: Bool

    @State private var inputFolderPath: String
    @State private var outputFolderPath: String

    @State private var providerMode: ProviderMode
    @State private var cloudVendor: CloudVendor

    @State private var llmProvider: LLMProvider
    @State private var llmModel: String
    @State private var llmBaseURL: String
    @State private var llmAPIKey: String
    @State private var maskedAPIKey: String
    @State private var isUpdatingAPIKey: Bool = false
    @State private var searchShortcut: ShortcutDefinition
    @State private var uploadShortcut: ShortcutDefinition
    @State private var settingsShortcut: ShortcutDefinition

    @State private var selectedModelOption: String = ""

    @State private var isSaving: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isLoadingSettings: Bool = false
    private let providerModeOptions: [ProviderMode] = [.cloud, .local]

    private let customModelToken = "__custom_model__"

    private let openAIModelOptions: [String] = [
        "gpt-5.2",
        "gpt-5-mini",
        "gpt-5-nano",
        "gpt-5.2-pro",
        "gpt-5",
        "gpt-4.1",
    ]

    private let anthropicModelOptions: [String] = [
        "claude-opus-4-6",
        "claude-sonnet-4-6",
        "claude-haiku-4-5-20251001"
    ]

    init(isSettingsViewShowing: Binding<Bool>) {
        self._isSettingsViewShowing = isSettingsViewShowing
        self._inputFolderPath = State(initialValue: SettingsService.shared.getInputFolder())
        self._outputFolderPath = State(initialValue: SettingsService.shared.getOutputFolder())

        let storedProvider = SettingsService.shared.getLLMProvider()
        self._llmProvider = State(initialValue: storedProvider)
        self._llmModel = State(initialValue: SettingsService.shared.getLLMModel())
        self._llmBaseURL = State(initialValue: SettingsService.shared.getLLMBaseURL())
        self._llmAPIKey = State(initialValue: "")
        self._maskedAPIKey = State(initialValue: SettingsService.shared.getStoredMaskedAPIKey(for: storedProvider))
        self._searchShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .search))
        self._uploadShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .upload))
        self._settingsShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .settings))

        self._providerMode = State(initialValue: storedProvider == .ollama ? .local : .cloud)
        self._cloudVendor = State(initialValue: storedProvider == .anthropic ? .anthropic : .openai)
    }

    private var modelOptions: [String] {
        return (cloudVendor == .openai ? openAIModelOptions : anthropicModelOptions) + [customModelToken]
    }

    private var usingCustomModel: Bool {
        selectedModelOption == customModelToken
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Folders") {
                    folderRow(title: "Input", path: $inputFolderPath, isInput: true)
                    folderRow(title: "Archive", path: $outputFolderPath, isInput: false)
                }

                Section("AI") {
                    Picker("Run Mode", selection: $providerMode) {
                        ForEach(providerModeOptions) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if providerMode == .cloud {
                        Picker("Provider", selection: $cloudVendor) {
                            ForEach(CloudVendor.allCases) { vendor in
                                Text(vendor.title).tag(vendor)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    if providerMode == .local {
                        TextField("Model ID", text: $llmModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $selectedModelOption) {
                            ForEach(modelOptions, id: \.self) { model in
                                Text(model == customModelToken ? "Custom..." : model)
                                    .tag(model)
                            }
                        }
                        .pickerStyle(.menu)

                        if usingCustomModel {
                            TextField("Type model name", text: $llmModel)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if providerMode == .local {
                        TextField("Base URL", text: $llmBaseURL)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        LabeledContent("API Key") {
                            if maskedAPIKey.isEmpty {
                                HStack(spacing: 8) {
                                    FixedLTRTextField(text: $llmAPIKey, placeholder: "API Key")
                                        .frame(width: 420)
                                    Spacer(minLength: 0)

                                    if isUpdatingAPIKey {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Button("Add") {
                                            addAPIKey()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    Text(displayMaskedAPIKey(maskedAPIKey))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)

                                    if isUpdatingAPIKey {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Button(role: .destructive) {
                                            deleteAPIKey()
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Delete API key")
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Shortcuts") {
                    shortcutEditorRows
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: UIConstants.settingsWindowWidth, height: UIConstants.settingsWindowHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadSettingsFromBackend()
        }
        .onDisappear {
            isSettingsViewShowing = false
        }
        .onChange(of: providerMode) { _, newMode in
            if newMode == .local {
                llmProvider = .ollama
                llmBaseURL = "http://localhost:11434"
                if llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    llmModel = "llama3.2"
                }
            } else {
                applyCloudVendor()
            }
            refreshProviderAPIKeyState()
            refreshProviderAPIKeyStateFromBackend()
            syncModelSelection()
        }
        .onChange(of: cloudVendor) { _, _ in
            if providerMode == .cloud {
                applyCloudVendor()
                refreshProviderAPIKeyState()
                refreshProviderAPIKeyStateFromBackend()
                syncModelSelection()
            }
        }
        .onChange(of: selectedModelOption) { _, newValue in
            if providerMode == .cloud && newValue != customModelToken {
                llmModel = newValue
            }
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            } else if saveSuccess {
                Text("Saved")
                    .foregroundColor(.green)
                    .font(.caption)
            } else if isLoadingSettings {
                Text("Loading...")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Spacer()

            if isSaving {
                ProgressView().controlSize(.small)
            } else {
                Button("Save") { saveSettings() }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputFolderPath.isEmpty || outputFolderPath.isEmpty || llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, UIConstants.settingsHeaderPadding)
        .padding(.vertical, 10)
    }

    private var shortcutEditorRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShortcutEditorRow(
                title: ShortcutAction.search.title,
                subtitle: ShortcutAction.search.subtitle,
                shortcut: $searchShortcut
            )

            ShortcutEditorRow(
                title: ShortcutAction.upload.title,
                subtitle: ShortcutAction.upload.subtitle,
                shortcut: $uploadShortcut
            )

            ShortcutEditorRow(
                title: ShortcutAction.settings.title,
                subtitle: ShortcutAction.settings.subtitle,
                shortcut: $settingsShortcut
            )
        }
        .padding(.vertical, 2)
    }

    private func folderRow(title: String, path: Binding<String>, isInput: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 56, alignment: .leading)
                .foregroundColor(.secondary)
            TextField("", text: path)
                .textFieldStyle(.roundedBorder)
            Button("Browse") {
                selectFolderPath(isInput: isInput)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func applyCloudVendor() {
        switch cloudVendor {
        case .openai:
            llmProvider = .openai
            llmBaseURL = "https://api.openai.com/v1"
            if !openAIModelOptions.contains(llmModel) {
                llmModel = openAIModelOptions[0]
            }
        case .anthropic:
            llmProvider = .anthropic
            llmBaseURL = "https://api.anthropic.com"
            if !anthropicModelOptions.contains(llmModel) {
                llmModel = anthropicModelOptions[0]
            }
        }
    }

    private func refreshProviderAPIKeyState() {
        llmAPIKey = ""
        maskedAPIKey = SettingsService.shared.getStoredMaskedAPIKey(for: llmProvider)
    }

    private func refreshProviderAPIKeyStateFromBackend() {
        let provider = llmProvider
        guard provider != .ollama else {
            maskedAPIKey = ""
            return
        }

        Task(priority: .utility) {
            if let response = try? await SettingsService.shared.fetchAPIKeyMaskFromAPI(provider: provider) {
                await MainActor.run {
                    SettingsService.shared.setStoredMaskedAPIKey(response.api_key_masked, for: provider)
                    if llmProvider == provider {
                        maskedAPIKey = response.api_key_masked
                    }
                }
            }
        }
    }

    private func syncModelSelection() {
        if providerMode == .local {
            selectedModelOption = customModelToken
            return
        }
        if modelOptions.contains(llmModel) {
            selectedModelOption = llmModel
        } else {
            selectedModelOption = customModelToken
        }
    }

    private func displayMaskedAPIKey(_ value: String) -> String {
        if value.isEmpty {
            return ""
        }
        if value.count <= 8 {
            return value
        }
        let prefix = String(value.prefix(3))
        let suffix = String(value.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    private func loadSettingsFromBackend() {
        Task(priority: .utility) {
            isLoadingSettings = true
            errorMessage = nil

            do {
                try await SettingsService.shared.loadSettingsFromBackend()
                await MainActor.run {
                    inputFolderPath = SettingsService.shared.getInputFolder()
                    outputFolderPath = SettingsService.shared.getOutputFolder()
                    llmProvider = SettingsService.shared.getLLMProvider()
                    llmModel = SettingsService.shared.getLLMModel()
                    llmBaseURL = SettingsService.shared.getLLMBaseURL()
                    llmAPIKey = ""
                    maskedAPIKey = SettingsService.shared.getStoredMaskedAPIKey(for: llmProvider)
                    searchShortcut = SettingsService.shared.getShortcut(for: .search)
                    uploadShortcut = SettingsService.shared.getShortcut(for: .upload)
                    settingsShortcut = SettingsService.shared.getShortcut(for: .settings)

                    if llmProvider == .ollama {
                        providerMode = .local
                        if llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            llmBaseURL = "http://localhost:11434"
                        }
                    } else {
                        providerMode = .cloud
                        cloudVendor = llmProvider == .anthropic ? .anthropic : .openai
                    }
                    syncModelSelection()
                }
            } catch let error as APIError {
                await MainActor.run {
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                isLoadingSettings = false
            }
        }
    }

    private func selectFolderPath(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    if isInput {
                        inputFolderPath = url.path
                    } else {
                        outputFolderPath = url.path
                    }
                }
            }
        }
    }

    private func saveSettings() {
        errorMessage = nil
        saveSuccess = false
        isSaving = true

        SettingsService.shared.setInputFolder(inputFolderPath)
        SettingsService.shared.setOutputFolder(outputFolderPath)
        SettingsService.shared.setLLMProvider(llmProvider)
        SettingsService.shared.setLLMModel(llmModel.trimmingCharacters(in: .whitespacesAndNewlines))

        var normalizedBaseURL = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if llmProvider == .ollama && normalizedBaseURL.isEmpty {
            normalizedBaseURL = "http://localhost:11434"
        } else if llmProvider == .openai && normalizedBaseURL.isEmpty {
            normalizedBaseURL = "https://api.openai.com/v1"
        } else if llmProvider == .anthropic && normalizedBaseURL.isEmpty {
            normalizedBaseURL = "https://api.anthropic.com"
        }
        llmBaseURL = normalizedBaseURL
        SettingsService.shared.setLLMBaseURL(normalizedBaseURL)
        SettingsService.shared.setShortcuts(
            search: searchShortcut,
            upload: uploadShortcut,
            settings: settingsShortcut
        )

        Task(priority: .utility) {
            do {
                try await SettingsService.shared.saveAllSettingsToBackend()
                await MainActor.run {
                    maskedAPIKey = SettingsService.shared.getStoredMaskedAPIKey(for: llmProvider)
                    isSaving = false
                    saveSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        saveSuccess = false
                    }
                }
            } catch let error as APIError {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func addAPIKey() {
        let key = llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = llmProvider
        guard !key.isEmpty, provider != .ollama else { return }

        isUpdatingAPIKey = true
        errorMessage = nil

        Task(priority: .utility) {
            do {
                let response = try await SettingsService.shared.addOrUpdateAPIKeyInAPI(
                    provider: provider,
                    apiKey: key
                )
                await MainActor.run {
                    SettingsService.shared.setStoredMaskedAPIKey(response.api_key_masked, for: provider)
                    if llmProvider == provider {
                        llmAPIKey = ""
                        maskedAPIKey = response.api_key_masked
                    }
                    isUpdatingAPIKey = false
                }
            } catch let error as APIError {
                await MainActor.run {
                    isUpdatingAPIKey = false
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            } catch {
                await MainActor.run {
                    isUpdatingAPIKey = false
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteAPIKey() {
        let provider = llmProvider
        guard provider != .ollama else { return }

        isUpdatingAPIKey = true
        errorMessage = nil

        Task(priority: .utility) {
            do {
                _ = try await SettingsService.shared.deleteAPIKeyInAPI(provider: provider)
                await MainActor.run {
                    SettingsService.shared.setStoredMaskedAPIKey("", for: provider)
                    if llmProvider == provider {
                        llmAPIKey = ""
                        maskedAPIKey = ""
                    }
                    isUpdatingAPIKey = false
                }
            } catch let error as APIError {
                await MainActor.run {
                    isUpdatingAPIKey = false
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            } catch {
                await MainActor.run {
                    isUpdatingAPIKey = false
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
