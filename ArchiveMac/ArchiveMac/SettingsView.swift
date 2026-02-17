import SwiftUI

struct SettingsView: View {
    @Binding var isSettingsViewShowing: Bool

    @State private var inputFolderPath: String
    @State private var outputFolderPath: String

    @State private var isSaving: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isLoadingDirectories: Bool = false

    init(isSettingsViewShowing: Binding<Bool>) {
        self._isSettingsViewShowing = isSettingsViewShowing
        self._inputFolderPath = State(initialValue: SettingsService.shared.getInputFolder())
        self._outputFolderPath = State(initialValue: SettingsService.shared.getOutputFolder())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formContent
            Divider()
            footer
        }
        .frame(width: UIConstants.settingsWindowWidth, height: UIConstants.settingsWindowHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadDirectoriesFromBackend()
        }
        .onDisappear {
            isSettingsViewShowing = false
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: UIConstants.settingsTitleSize, weight: .semibold))
                Text("Configure input and archive locations")
                    .font(.system(size: UIConstants.resultSubtitleSize))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, UIConstants.settingsHeaderPadding)
        .padding(.vertical, UIConstants.settingsHeaderVerticalPadding)
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIConstants.settingsGroupSpacing) {
                GroupBox("Input Folder") {
                    VStack(alignment: .leading, spacing: UIConstants.settingsItemSpacing) {
                        Text("Files dropped here are ingested, embedded, and then organized automatically.")
                            .foregroundColor(.secondary)
                            .font(.system(size: UIConstants.settingsLabelSize))

                        HStack {
                            TextField("Path to input folder", text: $inputFolderPath)
                                .textFieldStyle(.roundedBorder)

                            Button("Browse...") {
                                selectFolderPath(isInput: true)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Archive Folder") {
                    VStack(alignment: .leading, spacing: UIConstants.settingsItemSpacing) {
                        Text("Organized files and the local semantic index are stored here.")
                            .foregroundColor(.secondary)
                            .font(.system(size: UIConstants.settingsLabelSize))

                        HStack {
                            TextField("Path to archive folder", text: $outputFolderPath)
                                .textFieldStyle(.roundedBorder)

                            Button("Browse...") {
                                selectFolderPath(isInput: false)
                            }
                        }
                    }
                    .padding(8)
                }

                Button {
                    loadDirectoriesFromBackend()
                } label: {
                    Label("Reload from backend", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.system(size: UIConstants.resultSubtitleSize))
                .foregroundColor(.secondary)
            }
            .padding(UIConstants.settingsContentPadding)
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.system(size: UIConstants.resultSubtitleSize))
            } else if saveSuccess {
                Text("Settings saved")
                    .foregroundColor(.green)
                    .font(.system(size: UIConstants.resultSubtitleSize))
            } else if isLoadingDirectories {
                Text("Loading folders from backend...")
                    .foregroundColor(.secondary)
                    .font(.system(size: UIConstants.resultSubtitleSize))
            }

            Spacer()

            if isSaving {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Save") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputFolderPath.isEmpty || outputFolderPath.isEmpty)
            }
        }
        .padding(.horizontal, UIConstants.settingsHeaderPadding)
        .padding(.vertical, UIConstants.settingsHeaderVerticalPadding)
    }

    private func loadDirectoriesFromBackend() {
        Task {
            isLoadingDirectories = true
            errorMessage = nil

            do {
                try await SettingsService.shared.loadDirectoriesFromBackend()
                await MainActor.run {
                    inputFolderPath = SettingsService.shared.getInputFolder()
                    outputFolderPath = SettingsService.shared.getOutputFolder()
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
                isLoadingDirectories = false
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

        Task {
            do {
                _ = try await SettingsService.shared.saveSettingsToBackend()
                await MainActor.run {
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
}
