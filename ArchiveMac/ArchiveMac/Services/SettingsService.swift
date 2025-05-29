import Foundation

class SettingsService {
    static let shared = SettingsService()
    
    private let database = DatabaseService.shared
    
    // UserDefaults keys for migration
    private let inputFolderKey = "inputFolder"
    private let outputFolderKey = "outputFolder"
    private let organizationRulesKey = "organizationRules"
    
    private init() {
        migrateFromUserDefaults()
    }
    
    // MARK: - Migration from UserDefaults
    
    private func migrateFromUserDefaults() {
        let userDefaults = UserDefaults.standard
        
        // Migrate folders if they exist in UserDefaults
        let currentSettings = database.getSettings()
        if let inputFolder = userDefaults.string(forKey: inputFolderKey),
           let outputFolder = userDefaults.string(forKey: outputFolderKey) {
            
            // Only migrate if database has default values
            if currentSettings.inputFolder.contains("Input") && currentSettings.outputFolder.contains("Output") {
                database.updateSettings(inputFolder: inputFolder, outputFolder: outputFolder)
                print("Migrated folder settings from UserDefaults to database")
            }
            
            // Clean up UserDefaults
            userDefaults.removeObject(forKey: inputFolderKey)
            userDefaults.removeObject(forKey: outputFolderKey)
        }
        
        // Migrate organization rules
        if let rulesData = userDefaults.data(forKey: organizationRulesKey) {
            do {
                let oldRules = try JSONDecoder().decode([LegacyOrganizationRule].self, from: rulesData)
                
                for oldRule in oldRules {
                    let newRule = OrganizationRule(
                        name: oldRule.name,
                        description: oldRule.description,
                        destinationFolder: oldRule.destinationFolder
                    )
                    
                    database.saveRule(newRule)
                }
                
                print("Migrated \(oldRules.count) rules from UserDefaults to database")
                userDefaults.removeObject(forKey: organizationRulesKey)
                
            } catch {
                print("Failed to migrate rules from UserDefaults: \(error)")
            }
        }
    }
    
    // MARK: - Input Folder
    
    func getInputFolder() -> String {
        return database.inputFolder
    }
    
    func setInputFolder(_ path: String) {
        database.setInputFolder(path)
    }
    
    // MARK: - Output Folder
    
    func getOutputFolder() -> String {
        return database.outputFolder
    }
    
    func setOutputFolder(_ path: String) {
        database.setOutputFolder(path)
    }
    
    // MARK: - Organization Rules
    
    func getOrganizationRules() -> [OrganizationRule] {
        return database.getAllRules()
    }
    
    func saveOrganizationRules(_ rules: [OrganizationRule]) {
        for rule in rules {
            database.saveRule(rule)
        }
    }
    
    func addOrganizationRule(_ rule: OrganizationRule) {
        database.saveRule(rule)
    }
    
    func updateOrganizationRule(_ rule: OrganizationRule) {
        database.saveRule(rule)
    }
    
    func deleteOrganizationRule(withId id: UUID) {
        database.deleteRule(withId: id)
    }
}

// MARK: - Legacy Model for Migration

private struct LegacyOrganizationRule: Codable {
    var id = UUID()
    var name: String
    var description: String
    var destinationFolder: String
    
    enum CodingKeys: String, CodingKey {
        case id, name, description, destinationFolder
    }
} 