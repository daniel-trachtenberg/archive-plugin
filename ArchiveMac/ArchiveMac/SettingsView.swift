import SwiftUI

struct SettingsView: View {
    @Binding var isSettingsViewShowing: Bool
    
    // Settings state
    @State private var inputFolderPath: String
    @State private var outputFolderPath: String
    @State private var organizationRules: [OrganizationRule]
    
    // UI state
    @State private var isEditingNewRule: Bool = false
    @State private var editingRule: OrganizationRule?
    @State private var isSaving: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isLoadingDirectories: Bool = false
    
    // Initialize with values from SettingsService
    init(isSettingsViewShowing: Binding<Bool>) {
        self._isSettingsViewShowing = isSettingsViewShowing
        self._inputFolderPath = State(initialValue: SettingsService.shared.getInputFolder())
        self._outputFolderPath = State(initialValue: SettingsService.shared.getOutputFolder())
        self._organizationRules = State(initialValue: SettingsService.shared.getOrganizationRules())
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with title and close button
            HStack {
                Text("Settings")
                    .font(.system(size: UIConstants.settingsTitleSize, weight: .medium))
                
                Spacer()
                
                Button(action: {
                    isSettingsViewShowing = false
                    SettingsWindowManager.shared.hide()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.system(size: UIConstants.settingsCloseButtonSize))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, UIConstants.settingsHeaderPadding)
            .padding(.vertical, UIConstants.settingsHeaderVerticalPadding)
            
            Divider()
            
            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: UIConstants.settingsGroupSpacing) {
                    // Section titles and content
                    HStack {
                        Text("Input Folder")
                            .font(.headline)
                        
                        if isLoadingDirectories {
                            ProgressView()
                                .scaleEffect(0.7)
                                .padding(.leading, 4)
                        } else {
                            Button(action: loadDirectoriesFromBackend) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Reload directories from backend")
                        }
                    }
                    
                    inputFolderSection
                    
                    Text("Output Folder")
                        .font(.headline)
                    
                    outputFolderSection
                    
                    Text("Organization Rules")
                        .font(.headline)
                    
                    organizationRulesSection
                }
                .padding(UIConstants.settingsContentPadding)
            }
            
            Divider()
            
            // Footer with save button
            HStack {
                if errorMessage != nil {
                    Text(errorMessage!)
                        .foregroundColor(.red)
                        .font(.system(size: UIConstants.resultSubtitleSize))
                } else if saveSuccess {
                    Text("Settings saved successfully")
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .font(.system(size: UIConstants.resultSubtitleSize))
                }
                
                Spacer()
                
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 80, height: 30)
                } else {
                    Button("Save") {
                        saveSettings()
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.regular)
                    .frame(width: 80)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .frame(height: 50)
        }
        .frame(width: UIConstants.settingsWindowWidth, height: UIConstants.settingsWindowHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(UIConstants.windowCornerRadius)
        .shadow(radius: UIConstants.windowShadowRadius)
        .sheet(isPresented: $isEditingNewRule) {
            RuleEditView(
                rule: editingRule ?? OrganizationRule(name: "", description: "", destinationFolder: ""),
                isPresented: $isEditingNewRule,
                onSave: { updatedRule in
                    if let editingRule = editingRule,
                       let index = organizationRules.firstIndex(where: { $0.id == editingRule.id }) {
                        // Update existing rule
                        organizationRules[index] = updatedRule
                    } else {
                        // Add new rule
                        organizationRules.append(updatedRule)
                    }
                }
            )
            .frame(width: UIConstants.ruleEditWidth, height: UIConstants.ruleEditHeight)
        }
        .task {
            // Load directories when view appears
            await loadDirectoriesFromBackend()
        }
    }
    
    // MARK: - Component Views
    
    private var inputFolderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UIConstants.settingsItemSpacing) {
                Text("Files will be processed from this location")
                    .font(.system(size: UIConstants.settingsLabelSize))
                    .foregroundColor(.secondary)
                
                HStack {
                    TextField("Path to input folder", text: $inputFolderPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Button("Browse...") {
                        selectFolderPath(isInput: true)
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
            }
            .padding(8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private var outputFolderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UIConstants.settingsItemSpacing) {
                Text("Files will be organized to this location")
                    .font(.system(size: UIConstants.settingsLabelSize))
                    .foregroundColor(.secondary)
                
                HStack {
                    TextField("Path to output folder", text: $outputFolderPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Button("Browse...") {
                        selectFolderPath(isInput: false)
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
            }
            .padding(8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private var organizationRulesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UIConstants.settingsItemSpacing) {
                Text("Customize how files should be organized (map file type to destination)")
                    .font(.system(size: UIConstants.settingsLabelSize))
                    .foregroundColor(.secondary)
                
                if organizationRules.isEmpty {
                    HStack {
                        Spacer()
                        Text("No rules defined")
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .padding(.vertical, UIConstants.smallPadding)
                    .frame(height: 50)
                } else {
                    VStack(spacing: 0) {
                        ForEach(organizationRules) { rule in
                            ruleRow(for: rule)
                            
                            if rule.id != organizationRules.last?.id {
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: min(300, CGFloat(organizationRules.count * 60)))
                }
                
                Button("Add Rule") {
                    editingRule = nil
                    isEditingNewRule = true
                }
                .buttonStyle(BorderedButtonStyle())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, UIConstants.smallPadding)
            }
            .padding(8)
        }
        .fixedSize(horizontal: false, vertical: organizationRules.isEmpty)
    }
    
    private func ruleRow(for rule: OrganizationRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                Text(rule.name)
                    .font(.system(size: UIConstants.settingsLabelSize, weight: .medium))
                
                Text("\(rule.description) → \(rule.destinationFolder)")
                    .font(.system(size: UIConstants.resultSubtitleSize))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            HStack(spacing: UIConstants.standardPadding) {
                Button(action: {
                    editingRule = rule
                    isEditingNewRule = true
                }) {
                    Image(systemName: "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {
                    organizationRules.removeAll { $0.id == rule.id }
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, UIConstants.smallPadding)
    }
    
    // MARK: - API Methods
    
    private func loadDirectoriesFromBackend() async {
        isLoadingDirectories = true
        errorMessage = nil
        
        do {
            try await SettingsService.shared.loadDirectoriesFromBackend()
            
            // Update UI with values from the backend
            inputFolderPath = SettingsService.shared.getInputFolder()
            outputFolderPath = SettingsService.shared.getOutputFolder()
            
        } catch let error as APIError {
            errorMessage = "Error: \(error.localizedDescription)"
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
        
        isLoadingDirectories = false
    }
    
    private func loadDirectoriesFromBackend() {
        Task {
            await loadDirectoriesFromBackend()
        }
    }
    
    // MARK: - Helper Methods
    
    private func selectFolderPath(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    if isInput {
                        self.inputFolderPath = url.path
                    } else {
                        self.outputFolderPath = url.path
                    }
                }
            }
        }
    }
    
    private func saveSettings() {
        // Reset status
        errorMessage = nil
        saveSuccess = false
        isSaving = true
        
        // Save settings to local storage first
        SettingsService.shared.setInputFolder(inputFolderPath)
        SettingsService.shared.setOutputFolder(outputFolderPath)
        SettingsService.shared.saveOrganizationRules(organizationRules)
        
        // Save to backend using Task
        Task {
            do {
                _ = try await SettingsService.shared.saveSettingsToBackend()
                
                // UI updates must be done on the main thread
                await MainActor.run {
                    isSaving = false
                    saveSuccess = true
                    
                    // Auto-hide success message after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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

// MARK: - Rule Edit View

struct RuleEditView: View {
    @State private var name: String
    @State private var description: String
    @State private var destinationFolder: String
    @State private var id: UUID
    
    @Binding var isPresented: Bool
    var onSave: (OrganizationRule) -> Void
    
    init(rule: OrganizationRule, isPresented: Binding<Bool>, onSave: @escaping (OrganizationRule) -> Void) {
        self._name = State(initialValue: rule.name)
        self._description = State(initialValue: rule.description)
        self._destinationFolder = State(initialValue: rule.destinationFolder)
        self._id = State(initialValue: rule.id)
        self._isPresented = isPresented
        self.onSave = onSave
    }
    
    var body: some View {
        VStack(spacing: UIConstants.settingsContentSpacing) {
            Text(id == UUID() ? "Add Rule" : "Edit Rule")
                .font(.title3)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: UIConstants.settingsItemSpacing) {
                Text("Rule Name")
                    .fontWeight(.medium)
                TextField("e.g. Screenshots, Math Homework, Finances", text: $name)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Text("File Descriptions")
                    .fontWeight(.medium)
                TextField("e.g. PDFs or images associated with my MATH 101 course", text: $description)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Text("Destination Folder")
                    .fontWeight(.medium)
                TextField("e.g. /Users/username/Documents/Homework/Math", text: $destinationFolder)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                HStack {
                    Button("Browse...") {
                        selectDestinationFolder()
                    }
                    .buttonStyle(BorderedButtonStyle())
                    
                    Spacer()
                }
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(BorderedButtonStyle())
                
                Spacer()
                
                Button("Save") {
                    let rule = OrganizationRule(
                        id: id,
                        name: name,
                        description: description,
                        destinationFolder: destinationFolder
                    )
                    
                    onSave(rule)
                    isPresented = false
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .disabled(name.isEmpty || description.isEmpty || destinationFolder.isEmpty)
            }
        }
        .padding()
    }
    
    private func selectDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    self.destinationFolder = url.path
                }
            }
        }
    }
} 
