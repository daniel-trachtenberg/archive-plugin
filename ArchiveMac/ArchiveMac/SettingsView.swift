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

private enum MoveLogsTimeframe: Int, CaseIterable, Identifiable {
    case oneHour = 1
    case oneDay = 24
    case sevenDays = 168
    case thirtyDays = 720

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneHour:
            return "1h"
        case .oneDay:
            return "24h"
        case .sevenDays:
            return "7d"
        case .thirtyDays:
            return "30d"
        }
    }
}

struct SettingsView: View {
    @Binding var isSettingsViewShowing: Bool

    @State private var inputFolderPath: String
    @State private var outputFolderPath: String
    @State private var watchInputFolder: Bool

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
    @State private var updateStatusMessage: String? = nil
    @State private var moveLogsTimeframe: MoveLogsTimeframe = .oneDay
    @State private var moveLogs: [MoveLogEntry] = []
    @State private var isLoadingMoveLogs: Bool = false
    @State private var moveLogsErrorMessage: String? = nil
    @State private var expandedMoveLogIDs: Set<Int> = []
    @State private var showUninstallConfirmation: Bool = false
    @State private var isRunningUninstallCleanup: Bool = false
    @State private var uninstallStatusMessage: String? = nil
    private let providerModeOptions: [ProviderMode] = [.cloud, .local]

    private let customModelToken = "__custom_model__"
    private let folderLabelWidth: CGFloat = 56
    private let folderPathFieldWidth: CGFloat = 440
    private let folderBrowseButtonWidth: CGFloat = 72

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
        self._watchInputFolder = State(initialValue: SettingsService.shared.getWatchInputFolder())

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
                settingsHeroCard
                    .padding(.vertical, 4)
                    .listRowInsets(
                        EdgeInsets(
                            top: 8,
                            leading: UIConstants.settingsHeaderPadding,
                            bottom: 8,
                            trailing: UIConstants.settingsHeaderPadding
                        )
                    )
                    .listRowBackground(Color.clear)

                Section("Folders") {
                    folderRow(title: "Input", path: $inputFolderPath, isInput: true)
                    folderRow(title: "Archive", path: $outputFolderPath, isInput: false)
                    watchInputRow
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

                Section("Move Logs") {
                    HStack(spacing: 10) {
                        Picker("Timeframe", selection: $moveLogsTimeframe) {
                            ForEach(MoveLogsTimeframe.allCases) { timeframe in
                                Text(timeframe.title).tag(timeframe)
                            }
                        }
                        .pickerStyle(.segmented)

                        if isLoadingMoveLogs {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Refresh") {
                                loadMoveLogs()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if let moveLogsErrorMessage {
                        Text(moveLogsErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if moveLogs.isEmpty && !isLoadingMoveLogs {
                        Text("No file movements in the selected timeframe.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(moveLogs) { entry in
                                    moveLogRow(entry)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 140, maxHeight: 220)
                    }
                }

                Section("About") {
                    LabeledContent("Version") {
                        Text(UpdateService.shared.versionDisplayString)
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }

                    Text("Updates are downloaded and installed in-app via Sparkle.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        if let updateStatusMessage {
                            Text(updateStatusMessage)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }

                        Spacer()

                        Button("Check for Updates") {
                            checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!SparkleUpdateController.shared.canCheckForUpdates)
                    }
                }

                Section("Uninstall") {
                    Text("This removes all local Archive data, then quits the app.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let uninstallStatusMessage {
                        Text(uninstallStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        if isRunningUninstallCleanup {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running cleanup...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Button("Uninstall", role: .destructive) {
                                showUninstallConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.small)
                        }

                        Spacer()

                        Button("Open Applications Folder") {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: "/Applications", isDirectory: true)
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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
            loadMoveLogs()
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
        .onChange(of: moveLogsTimeframe) { _, _ in
            loadMoveLogs()
        }
        .confirmationDialog(
            "Clean up local data and quit Archive?",
            isPresented: $showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                runUninstallCleanupAndQuit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All local Archive data will be permanently removed. You can then drag ArchiveMac.app to Trash.")
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

    private var settingsHeroCard: some View {
        let autoValue = watchInputFolder ? "On" : "Off"
        let modeValue = providerMode == .cloud ? "Cloud" : "Local"
        let versionValue = UpdateService.shared.versionDisplayString

        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.indigo.opacity(0.2), Color.teal.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("⚙️")
                            .font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Archive Settings")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Control folders, AI, shortcuts, updates, and uninstall.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        settingsStatusPill(label: "Auto", value: autoValue, tint: autoValue == "On" ? .green : .orange)
                        settingsStatusPill(label: "Mode", value: modeValue, tint: modeValue == "Cloud" ? .blue : .teal)
                        Spacer()
                        Text(versionValue)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            .frame(height: 108)
    }

    private func settingsStatusPill(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.18), in: Capsule())
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
                .frame(width: folderLabelWidth, alignment: .leading)
                .foregroundColor(.secondary)
            FixedLTRTextField(text: path, placeholder: "Folder path")
                .frame(width: folderPathFieldWidth)
            Button("Browse") {
                selectFolderPath(isInput: isInput)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: folderBrowseButtonWidth)
        }
    }

    private var watchInputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Auto")
                .frame(width: folderLabelWidth, alignment: .leading)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Watch Input automatically")
                    .font(.system(size: 13, weight: .medium))
                Text("When off, files are not auto-processed from Input.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $watchInputFolder)
                .labelsHidden()
                .toggleStyle(.switch)
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

    private func moveLogRow(_ entry: MoveLogEntry) -> some View {
        let isExpanded = expandedMoveLogIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleMoveLogExpansion(entry.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(formattedMoveLogTimestamp(entry.created_at))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(entry.item_type.capitalized)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(entry.status.capitalized)
                            .font(.caption2)
                            .foregroundColor(entry.status.lowercased() == "success" ? .green : .red)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text(compactPath(entry.source_path))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(compactPath(entry.destination_path))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let note = entry.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    moveLogPathLink(
                        label: "Source",
                        path: entry.source_path,
                        icon: "arrow.up.left"
                    )
                    moveLogPathLink(
                        label: "Destination",
                        path: entry.destination_path,
                        icon: "arrow.down.right"
                    )
                }
                .padding(10)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(9)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private func compactPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func formattedMoveLogTimestamp(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: value) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            return formatter.string(from: date)
        }
        return value
    }

    private func toggleMoveLogExpansion(_ id: Int) {
        if expandedMoveLogIDs.contains(id) {
            expandedMoveLogIDs.remove(id)
        } else {
            expandedMoveLogIDs.insert(id)
        }
    }

    private func moveLogPathLink(label: String, path: String, icon: String) -> some View {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let canOpen = !trimmedPath.isEmpty

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            Button {
                openMoveLogPath(trimmedPath)
            } label: {
                Text(canOpen ? trimmedPath : "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(canOpen ? .accentColor : .secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .help(canOpen ? "Open in Finder" : "")
        }
    }

    private func openMoveLogPath(_ trimmedPath: String) {
        guard !trimmedPath.isEmpty else {
            return
        }

        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: trimmedPath)

        if fileManager.fileExists(atPath: trimmedPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        let parentURL = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parentURL.path) {
            NSWorkspace.shared.open(parentURL)
            return
        }

        NSSound.beep()
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
                    watchInputFolder = SettingsService.shared.getWatchInputFolder()
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
        SettingsService.shared.setWatchInputFolder(watchInputFolder)
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
                    isSettingsViewShowing = false
                    SettingsWindowManager.shared.hide()
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

    private func loadMoveLogs() {
        isLoadingMoveLogs = true
        moveLogsErrorMessage = nil
        let timeframe = moveLogsTimeframe

        Task(priority: .utility) {
            do {
                let response = try await SettingsService.shared.fetchMoveLogsFromAPI(
                    hours: timeframe.rawValue
                )
                await MainActor.run {
                    moveLogs = response.logs
                    let validIDs = Set(response.logs.map(\.id))
                    expandedMoveLogIDs = expandedMoveLogIDs.intersection(validIDs)
                    isLoadingMoveLogs = false
                }
            } catch let error as APIError {
                await MainActor.run {
                    isLoadingMoveLogs = false
                    moveLogsErrorMessage = "Error: \(error.localizedDescription)"
                    moveLogs = []
                    expandedMoveLogIDs.removeAll()
                }
            } catch {
                await MainActor.run {
                    isLoadingMoveLogs = false
                    moveLogsErrorMessage = "Error: \(error.localizedDescription)"
                    moveLogs = []
                    expandedMoveLogIDs.removeAll()
                }
            }
        }
    }

    private func checkForUpdates() {
        updateStatusMessage = "Checking..."
        SparkleUpdateController.shared.checkForUpdates()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            updateStatusMessage = nil
        }
    }

    private func runUninstallCleanupAndQuit() {
        guard !isRunningUninstallCleanup else {
            return
        }

        isRunningUninstallCleanup = true
        uninstallStatusMessage = nil
        errorMessage = nil

        Task(priority: .utility) {
            do {
                let response = try await SettingsService.shared.runUninstallCleanup()

                await MainActor.run {
                    isRunningUninstallCleanup = false
                    if response.warnings.isEmpty {
                        uninstallStatusMessage = "Cleanup complete. Quitting..."
                    } else {
                        uninstallStatusMessage = "Cleanup completed with warnings. Quitting..."
                        errorMessage = response.warnings.joined(separator: " | ")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NSApplication.shared.terminate(nil)
                    }
                }
            } catch let error as APIError {
                await MainActor.run {
                    isRunningUninstallCleanup = false
                    errorMessage = "Cleanup failed: \(error.localizedDescription)"
                }
            } catch {
                await MainActor.run {
                    isRunningUninstallCleanup = false
                    errorMessage = "Cleanup failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
