import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case folders
    case ai
    case shortcuts

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .folders:
            return "Folders"
        case .ai:
            return "AI"
        case .shortcuts:
            return "Shortcuts"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "Learn what Archive can do"
        case .folders:
            return "Choose your input and archive locations"
        case .ai:
            return "Pick cloud or local AI setup"
        case .shortcuts:
            return "Customize keyboard shortcuts"
        }
    }

    var buttonTitle: String {
        self == .shortcuts ? "Finish" : "Continue"
    }
}

private enum OnboardingProviderMode: String, CaseIterable, Identifiable {
    case cloud
    case local

    var id: String { rawValue }
    var title: String { self == .cloud ? "Cloud" : "Local" }
}

private enum OnboardingCloudVendor: String, CaseIterable, Identifiable {
    case openai
    case anthropic

    var id: String { rawValue }
    var title: String { self == .openai ? "OpenAI" : "Anthropic" }
}

struct OnboardingView: View {
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
        "claude-haiku-4-5-20251001",
    ]

    @State private var step: OnboardingStep = .welcome

    @State private var inputFolderPath: String
    @State private var outputFolderPath: String
    @State private var watchInputFolder: Bool
    @State private var providerMode: OnboardingProviderMode
    @State private var cloudVendor: OnboardingCloudVendor
    @State private var llmModel: String
    @State private var llmBaseURL: String
    @State private var llmAPIKey: String
    @State private var selectedModelOption: String = ""

    @State private var searchShortcut: ShortcutDefinition
    @State private var uploadShortcut: ShortcutDefinition
    @State private var settingsShortcut: ShortcutDefinition

    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil

    let onComplete: () -> Void

    init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
        self._inputFolderPath = State(initialValue: SettingsService.shared.getInputFolder())
        self._outputFolderPath = State(initialValue: SettingsService.shared.getOutputFolder())
        self._watchInputFolder = State(initialValue: SettingsService.shared.getWatchInputFolder())

        let storedProvider = SettingsService.shared.getLLMProvider()
        let storedModel = SettingsService.shared.getLLMModel()
        let storedBaseURL = SettingsService.shared.getLLMBaseURL()

        self._providerMode = State(initialValue: storedProvider == .ollama ? .local : .cloud)
        self._cloudVendor = State(initialValue: storedProvider == .anthropic ? .anthropic : .openai)
        self._llmModel = State(initialValue: storedModel.isEmpty ? "gpt-5.2" : storedModel)
        self._llmBaseURL = State(
            initialValue: storedBaseURL.isEmpty
                ? (storedProvider == .ollama ? "http://localhost:11434" : "https://api.openai.com/v1")
                : storedBaseURL
        )
        self._llmAPIKey = State(initialValue: "")
        self._selectedModelOption = State(initialValue: customModelToken)

        self._searchShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .search))
        self._uploadShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .upload))
        self._settingsShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .settings))
    }

    private var modelOptions: [String] {
        let baseModels = cloudVendor == .openai ? openAIModelOptions : anthropicModelOptions
        return baseModels + [customModelToken]
    }

    private var usingCustomModel: Bool {
        selectedModelOption == customModelToken
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                stepProgressCard

                Group {
                    switch step {
                    case .welcome:
                        welcomeStep
                    case .folders:
                        folderStep
                    case .ai:
                        aiStep
                    case .shortcuts:
                        shortcutStep
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()

            footer
        }
        .frame(width: UIConstants.onboardingWindowWidth, height: UIConstants.onboardingWindowHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if providerMode == .cloud {
                applyCloudVendor()
                syncModelSelection()
            } else {
                if llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    llmBaseURL = "http://localhost:11434"
                }
                if llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    llmModel = "llama3.2"
                }
                selectedModelOption = customModelToken
            }
        }
        .onChange(of: providerMode) { _, newMode in
            if newMode == .local {
                llmBaseURL = "http://localhost:11434"
                if llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    llmModel = "llama3.2"
                }
                selectedModelOption = customModelToken
            } else {
                applyCloudVendor()
                syncModelSelection()
            }
        }
        .onChange(of: cloudVendor) { _, _ in
            guard providerMode == .cloud else { return }
            applyCloudVendor()
            syncModelSelection()
        }
        .onChange(of: selectedModelOption) { _, newValue in
            if providerMode == .cloud && newValue != customModelToken {
                llmModel = newValue
            }
        }
    }

    private var stepProgressCard: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor))
            .overlay {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count): \(step.title)")
                            .font(.system(size: 13, weight: .semibold))
                        Text(step.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        ForEach(OnboardingStep.allCases, id: \.rawValue) { current in
                            Circle()
                                .fill(current.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(height: 66)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.22), Color.teal.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    HStack(spacing: 16) {
                        Text("🗂️")
                            .font(.system(size: 52))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Archive keeps your files organized")
                                .font(.system(size: 22, weight: .semibold))
                            Text("Drop files into your input folder, Archive embeds them, auto-organizes them, and makes them searchable by meaning.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                }
                .frame(height: 186)

            VStack(alignment: .leading, spacing: 12) {
                shortcutHint(icon: "⌘", title: "Search quickly", detail: "Use \(searchShortcut.displayString) to open search instantly.")
                shortcutHint(icon: "📥", title: "Add files fast", detail: "Use \(uploadShortcut.displayString) to open upload.")
                shortcutHint(icon: "⚙️", title: "Adjust anytime", detail: "Use \(settingsShortcut.displayString) to open settings.")
            }

            Spacer(minLength: 0)
        }
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose where files come in and where Archive stores organized files.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            folderRow(title: "Input", path: $inputFolderPath, isInput: true)
            folderRow(title: "Archive", path: $outputFolderPath, isInput: false)
            onboardingWatchInputRow

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tip")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            watchInputFolder
                                ? "Use a dedicated Input folder so new files can be discovered and organized without mixing with other files."
                                : "Input watching is off. You can still upload manually and turn watching on later in Settings."
                        )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                }
                .frame(height: 94)

            Spacer(minLength: 0)
        }
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.2), Color.blue.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .leading) {
                    HStack(spacing: 12) {
                        Text(providerMode == .cloud ? "☁️" : "🧠")
                            .font(.system(size: 36))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect your AI setup")
                                .font(.system(size: 18, weight: .semibold))
                            Text(providerMode == .cloud
                                 ? "Cloud is best for most users. Add your key now or do it later in Settings."
                                 : "Use your local endpoint and model for fully local processing.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                }
                .frame(height: 118)

            Picker("Run Mode", selection: $providerMode) {
                ForEach(OnboardingProviderMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if providerMode == .cloud {
                Picker("Provider", selection: $cloudVendor) {
                    ForEach(OnboardingCloudVendor.allCases) { vendor in
                        Text(vendor.title).tag(vendor)
                    }
                }
                .pickerStyle(.menu)

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

                HStack(spacing: 10) {
                    Text("API Key")
                        .frame(width: 64, alignment: .leading)
                        .foregroundStyle(.secondary)

                    TextField("Paste your API key", text: $llmAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                HStack(spacing: 10) {
                    Text("Model")
                        .frame(width: 64, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("llama3.2", text: $llmModel)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Text("Base URL")
                        .frame(width: 64, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("http://localhost:11434", text: $llmBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(alignment: .leading) {
                    Text("Your key is encrypted before storage. You can change provider/model later in Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                .frame(height: 42)

            Spacer(minLength: 0)
        }
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick shortcuts that feel natural. These are available globally while the app is running.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

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

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button("Back") {
                    previousStep()
                }
                .buttonStyle(.bordered)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()

            if isSaving {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(step.buttonTitle) {
                    continueTapped()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func shortcutHint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func folderRow(title: String, path: Binding<String>, isInput: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(.secondary)

            TextField("", text: path)
                .textFieldStyle(.roundedBorder)

            Button("Browse") {
                chooseFolder(isInput: isInput)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var onboardingWatchInputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Auto")
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(.secondary)

            Text("Watch Input automatically")
                .font(.system(size: 13, weight: .medium))

            Spacer(minLength: 8)

            Toggle("", isOn: $watchInputFolder)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func applyCloudVendor() {
        switch cloudVendor {
        case .openai:
            if llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || llmBaseURL.contains("anthropic") {
                llmBaseURL = "https://api.openai.com/v1"
            }
            if !openAIModelOptions.contains(llmModel) {
                llmModel = openAIModelOptions[0]
            }
        case .anthropic:
            if llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || llmBaseURL.contains("openai.com") {
                llmBaseURL = "https://api.anthropic.com"
            }
            if !anthropicModelOptions.contains(llmModel) {
                llmModel = anthropicModelOptions[0]
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

    private func previousStep() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else {
            return
        }
        step = previous
        errorMessage = nil
    }

    private func continueTapped() {
        errorMessage = nil

        if step != .shortcuts {
            guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
                return
            }
            step = next
            return
        }

        completeOnboarding()
    }

    private func chooseFolder(isInput: Bool) {
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

    private func completeOnboarding() {
        let normalizedInput = inputFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOutput = outputFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalizedModel = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalizedBaseURL = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAPIKey = llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let selectedProvider: LLMProvider = {
            if providerMode == .local {
                return .ollama
            }
            return cloudVendor == .anthropic ? .anthropic : .openai
        }()

        guard !normalizedInput.isEmpty, !normalizedOutput.isEmpty else {
            errorMessage = "Please choose both folders before finishing."
            return
        }

        if normalizedModel.isEmpty {
            normalizedModel = selectedProvider == .anthropic ? "claude-sonnet-4-6" : "gpt-5.2"
            if selectedProvider == .ollama {
                normalizedModel = "llama3.2"
            }
        }

        if normalizedBaseURL.isEmpty {
            switch selectedProvider {
            case .ollama:
                normalizedBaseURL = "http://localhost:11434"
            case .anthropic:
                normalizedBaseURL = "https://api.anthropic.com"
            case .openai:
                normalizedBaseURL = "https://api.openai.com/v1"
            case .openai_compatible:
                normalizedBaseURL = "http://localhost:1234/v1"
            }
        }

        isSaving = true

        SettingsService.shared.setInputFolder(normalizedInput)
        SettingsService.shared.setOutputFolder(normalizedOutput)
        SettingsService.shared.setWatchInputFolder(watchInputFolder)
        SettingsService.shared.setLLMProvider(selectedProvider)
        SettingsService.shared.setLLMModel(normalizedModel)
        SettingsService.shared.setLLMBaseURL(normalizedBaseURL)
        SettingsService.shared.setShortcuts(
            search: searchShortcut,
            upload: uploadShortcut,
            settings: settingsShortcut
        )
        SettingsService.shared.setOnboardingCompleted(true)

        Task(priority: .utility) {
            do {
                try await SettingsService.shared.saveAllSettingsToBackend()

                if selectedProvider != .ollama, !normalizedAPIKey.isEmpty {
                    let keyResponse = try await SettingsService.shared.addOrUpdateAPIKeyInAPI(
                        provider: selectedProvider,
                        apiKey: normalizedAPIKey
                    )
                    SettingsService.shared.setStoredMaskedAPIKey(
                        keyResponse.api_key_masked,
                        for: selectedProvider
                    )
                }
            } catch {
                print("Onboarding sync warning: \(error.localizedDescription)")
            }

            await MainActor.run {
                isSaving = false
                OnboardingWindowManager.shared.hide()
                onComplete()
            }
        }
    }
}
