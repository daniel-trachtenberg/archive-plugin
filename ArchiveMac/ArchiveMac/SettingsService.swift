import Foundation

// Model for custom rules or file organization specifications
struct OrganizationRule: Codable, Identifiable {
    var id = UUID()
    var name: String
    var description: String
    var destinationFolder: String
    
    enum CodingKeys: String, CodingKey {
        case id, name, description, destinationFolder
    }
}

class SettingsService {
    static let shared = SettingsService()
    
    // Keys for UserDefaults
    private let inputFolderKey = "inputFolder"
    private let outputFolderKey = "outputFolder"
    private let organizationRulesKey = "organizationRules"
    
    // Default input folder location
    private let defaultInputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Input").path
    
    // Default output folder location
    private let defaultOutputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Output").path
    
    private init() {}
    
    // MARK: - Input Folder
    
    func getInputFolder() -> String {
        return UserDefaults.standard.string(forKey: inputFolderKey) ?? defaultInputFolder
    }
    
    func setInputFolder(_ path: String) {
        UserDefaults.standard.set(path, forKey: inputFolderKey)
    }
    
    // MARK: - Output Folder
    
    func getOutputFolder() -> String {
        return UserDefaults.standard.string(forKey: outputFolderKey) ?? defaultOutputFolder
    }
    
    func setOutputFolder(_ path: String) {
        UserDefaults.standard.set(path, forKey: outputFolderKey)
    }
    
    // MARK: - Organization Rules
    
    func getOrganizationRules() -> [OrganizationRule] {
        guard let data = UserDefaults.standard.data(forKey: organizationRulesKey) else {
            return []
        }
        
        do {
            return try JSONDecoder().decode([OrganizationRule].self, from: data)
        } catch {
            print("Error decoding organization rules: \(error)")
            return []
        }
    }
    
    func saveOrganizationRules(_ rules: [OrganizationRule]) {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: organizationRulesKey)
        } catch {
            print("Error encoding organization rules: \(error)")
        }
    }
    
    func addOrganizationRule(_ rule: OrganizationRule) {
        var rules = getOrganizationRules()
        rules.append(rule)
        saveOrganizationRules(rules)
    }
    
    func updateOrganizationRule(_ rule: OrganizationRule) {
        var rules = getOrganizationRules()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
            saveOrganizationRules(rules)
        }
    }
    
    func deleteOrganizationRule(withId id: UUID) {
        var rules = getOrganizationRules()
        rules.removeAll { $0.id == id }
        saveOrganizationRules(rules)
    }
    
    // MARK: - Save Settings to Backend
    
    func saveSettingsToBackend(completion: @escaping (Bool, Error?) -> Void) {
        // TODO: Implement backend call to save settings
        // This is a placeholder for the actual implementation
        
        let settings = [
            "inputFolder": getInputFolder(),
            "outputFolder": getOutputFolder(),
            "rules": getOrganizationRules().map { rule in
                return [
                    "id": rule.id.uuidString,
                    "name": rule.name,
                    "description": rule.description,
                    "destinationFolder": rule.destinationFolder
                ]
            }
        ] as [String : Any]
        
        print("Would save settings to backend: \(settings)")
        
        // Simulate successful save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion(true, nil)
        }
    }
} 