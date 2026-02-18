import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case folders
    case shortcuts

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .folders:
            return "Folders"
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
        case .shortcuts:
            return "Customize keyboard shortcuts"
        }
    }

    var buttonTitle: String {
        self == .shortcuts ? "Finish" : "Continue"
    }
}

struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome

    @State private var inputFolderPath: String
    @State private var outputFolderPath: String

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
        self._searchShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .search))
        self._uploadShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .upload))
        self._settingsShortcut = State(initialValue: SettingsService.shared.getShortcut(for: .settings))
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

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tip")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Use a dedicated Input folder so new files can be discovered and organized without mixing with other files.")
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

        guard !normalizedInput.isEmpty, !normalizedOutput.isEmpty else {
            errorMessage = "Please choose both folders before finishing."
            return
        }

        isSaving = true

        SettingsService.shared.setInputFolder(normalizedInput)
        SettingsService.shared.setOutputFolder(normalizedOutput)
        SettingsService.shared.setShortcuts(
            search: searchShortcut,
            upload: uploadShortcut,
            settings: settingsShortcut
        )
        SettingsService.shared.setOnboardingCompleted(true)

        Task(priority: .utility) {
            do {
                try await SettingsService.shared.saveAllSettingsToBackend()
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
