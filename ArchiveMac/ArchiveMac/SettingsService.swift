import Foundation

/*
 * SettingsService.swift
 * 
 * This service handles all settings-related functionality for the Archive app.
 * It provides:
 * 1. Local storage for settings using UserDefaults
 * 2. API integration with the backend service to fetch and update directory configurations
 * 3. Organization rules management
 * 
 * The service uses Swift Concurrency (async/await) for network operations,
 * while maintaining backward compatibility with completion handler APIs.
 */

// Model for directory configuration that matches the backend API
struct DirectoryConfig: Codable {
    var input_dir: String
    var archive_dir: String
}

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

// API errors
enum APIError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case serverError(Int)
    case invalidResponse
    
    var localizedDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .serverError(let statusCode):
            return "Server error with status code: \(statusCode)"
        case .invalidResponse:
            return "Invalid server response"
        }
    }
}

class SettingsService {
    static let shared = SettingsService()
    
    // API base URL
    private let baseURL = "http://localhost:8000"
    
    // Keys for UserDefaults
    private let inputFolderKey = "inputFolder"
    private let outputFolderKey = "outputFolder"
    private let organizationRulesKey = "organizationRules"
    
    // Default input folder location
    private let defaultInputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Input").path
    
    // Default output folder location
    private let defaultOutputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Output").path
    
    private init() {}
    
    // MARK: - API Methods
    
    /// Fetch directories from the backend API
    func fetchDirectoriesFromAPI() async throws -> DirectoryConfig {
        guard let url = URL(string: "\(baseURL)/directories") else {
            throw APIError.invalidURL
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let config = try JSONDecoder().decode(DirectoryConfig.self, from: data)
            return config
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }
    
    /// Update directories through the backend API
    func updateDirectoriesInAPI(inputDir: String, archiveDir: String) async throws -> DirectoryConfig {
        guard let url = URL(string: "\(baseURL)/directories") else {
            throw APIError.invalidURL
        }
        
        let config = DirectoryConfig(input_dir: inputDir, archive_dir: archiveDir)
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(config)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let updatedConfig = try JSONDecoder().decode(DirectoryConfig.self, from: data)
            return updatedConfig
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }
    
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
    
    /// Modern async/await version for saving settings
    func saveSettingsToBackend() async throws -> DirectoryConfig {
        return try await updateDirectoriesInAPI(
            inputDir: getInputFolder(),
            archiveDir: getOutputFolder()
        )
    }
    
    /// Legacy completion handler version for backward compatibility
    func saveSettingsToBackend(completion: @escaping (Bool, Error?) -> Void) {
        Task {
            do {
                let result = try await saveSettingsToBackend()
                
                // Update local settings with the values from the server response
                setInputFolder(result.input_dir)
                setOutputFolder(result.archive_dir)
                
                DispatchQueue.main.async {
                    completion(true, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error)
                }
            }
        }
    }
    
    /// Load directories from the backend
    func loadDirectoriesFromBackend() async throws {
        let config = try await fetchDirectoriesFromAPI()
        setInputFolder(config.input_dir)
        setOutputFolder(config.archive_dir)
    }
} 