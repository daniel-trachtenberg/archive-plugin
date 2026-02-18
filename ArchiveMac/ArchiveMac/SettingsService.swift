import Foundation

struct DirectoryConfig: Codable {
    var input_dir: String
    var archive_dir: String
}

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case ollama
    case openai
    case anthropic
    case openai_compatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Local (Ollama)"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openai_compatible: return "OpenAI-Compatible"
        }
    }
}

struct LLMSettingsRequest: Codable {
    var provider: String
    var model: String
    var base_url: String
    var api_key: String
}

struct LLMSettingsResponse: Codable {
    var provider: String
    var model: String
    var base_url: String
    var api_key_masked: String
}

struct LLMAPIKeyRequest: Codable {
    var provider: String
    var api_key: String
}

struct LLMAPIKeyResponse: Codable {
    var provider: String
    var api_key_masked: String
}

enum APIError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case serverError(Int, String?)
    case invalidResponse

    var localizedDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .serverError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Server error (\(statusCode)): \(message)"
            }
            return "Server error with status code: \(statusCode)"
        case .invalidResponse:
            return "Invalid server response"
        }
    }
}

final class SettingsService {
    static let shared = SettingsService()

    private let baseURL = "http://localhost:8000"

    private let didRunAPIKeyStorageResetMigrationKey = "didRunAPIKeyStorageResetMigration"
    private let inputFolderKey = "inputFolder"
    private let outputFolderKey = "outputFolder"
    private let llmProviderKey = "llmProvider"
    private let llmModelKey = "llmModel"
    private let llmBaseURLKey = "llmBaseURL"
    private let onboardingCompletedKey = "onboardingCompleted"
    private let searchShortcutKey = "searchShortcut"
    private let uploadShortcutKey = "uploadShortcut"
    private let settingsShortcutKey = "settingsShortcut"

    private let openAIAPIKeyKey = "openaiAPIKey"
    private let anthropicAPIKeyKey = "anthropicAPIKey"
    private let openAICompatibleAPIKeyKey = "openaiCompatibleAPIKey"

    private let openAIMaskedAPIKeyKey = "openaiMaskedAPIKey"
    private let anthropicMaskedAPIKeyKey = "anthropicMaskedAPIKey"
    private let openAICompatibleMaskedAPIKeyKey = "openaiCompatibleMaskedAPIKey"

    private let defaultInputFolder = FileManager.default
        .urls(for: .desktopDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("Input")
        .path

    private let defaultOutputFolder = FileManager.default
        .urls(for: .desktopDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("Archive")
        .path

    private init() {
        runMigrationsIfNeeded()
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var detailMessage: String?
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                detailMessage = payload["detail"] as? String
            }
            throw APIError.serverError(httpResponse.statusCode, detailMessage)
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func providerAPIKeyStorageKey(_ provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openAIAPIKeyKey
        case .anthropic: return anthropicAPIKeyKey
        case .openai_compatible: return openAICompatibleAPIKeyKey
        case .ollama: return ""
        }
    }

    private func providerMaskedAPIKeyStorageKey(_ provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openAIMaskedAPIKeyKey
        case .anthropic: return anthropicMaskedAPIKeyKey
        case .openai_compatible: return openAICompatibleMaskedAPIKeyKey
        case .ollama: return ""
        }
    }

    private func runMigrationsIfNeeded() {
        let defaults = UserDefaults.standard

        defaults.removeObject(forKey: "organizationRules")
        defaults.removeObject(forKey: "llmApiKey")

        if !defaults.bool(forKey: didRunAPIKeyStorageResetMigrationKey) {
            defaults.removeObject(forKey: openAIAPIKeyKey)
            defaults.removeObject(forKey: anthropicAPIKeyKey)
            defaults.removeObject(forKey: openAICompatibleAPIKeyKey)
            defaults.removeObject(forKey: openAIMaskedAPIKeyKey)
            defaults.removeObject(forKey: anthropicMaskedAPIKeyKey)
            defaults.removeObject(forKey: openAICompatibleMaskedAPIKeyKey)
            defaults.set(true, forKey: didRunAPIKeyStorageResetMigrationKey)
        }
    }

    private func shortcutStorageKey(for action: ShortcutAction) -> String {
        switch action {
        case .search:
            return searchShortcutKey
        case .upload:
            return uploadShortcutKey
        case .settings:
            return settingsShortcutKey
        }
    }

    // MARK: - Directories API

    func fetchDirectoriesFromAPI() async throws -> DirectoryConfig {
        guard let url = URL(string: "\(baseURL)/directories") else {
            throw APIError.invalidURL
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            return try decode(DirectoryConfig.self, data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    func updateDirectoriesInAPI(inputDir: String, archiveDir: String) async throws -> DirectoryConfig {
        guard let url = URL(string: "\(baseURL)/directories") else {
            throw APIError.invalidURL
        }

        let config = DirectoryConfig(input_dir: inputDir, archive_dir: archiveDir)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(config)
            let (data, response) = try await URLSession.shared.data(for: request)
            return try decode(DirectoryConfig.self, data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch let error as EncodingError {
            throw APIError.networkError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }

    // MARK: - LLM Settings API

    func fetchLLMSettingsFromAPI() async throws -> LLMSettingsResponse {
        guard let url = URL(string: "\(baseURL)/llm-settings") else {
            throw APIError.invalidURL
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            return try decode(LLMSettingsResponse.self, data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    func updateLLMSettingsInAPI(provider: String, model: String, llmBaseURL: String) async throws -> LLMSettingsResponse {
        guard let url = URL(string: "\(baseURL)/llm-settings") else {
            throw APIError.invalidURL
        }

        let config = LLMSettingsRequest(
            provider: provider,
            model: model,
            base_url: llmBaseURL,
            api_key: ""
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(config)
            let (data, response) = try await URLSession.shared.data(for: request)
            return try decode(LLMSettingsResponse.self, data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch let error as EncodingError {
            throw APIError.networkError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }

    func fetchAPIKeyMaskFromAPI(provider: LLMProvider) async throws -> LLMAPIKeyResponse {
        guard provider != .ollama else {
            return LLMAPIKeyResponse(provider: provider.rawValue, api_key_masked: "")
        }

        guard let encodedProvider = provider.rawValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/llm-api-key?provider=\(encodedProvider)") else {
            throw APIError.invalidURL
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            return try decode(LLMAPIKeyResponse.self, data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    func addOrUpdateAPIKeyInAPI(provider: LLMProvider, apiKey: String) async throws -> LLMAPIKeyResponse {
        guard provider != .ollama else {
            return LLMAPIKeyResponse(provider: provider.rawValue, api_key_masked: "")
        }

        guard let url = URL(string: "\(baseURL)/llm-api-key") else {
            throw APIError.invalidURL
        }

        let payload = LLMAPIKeyRequest(provider: provider.rawValue, api_key: apiKey)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            return try decode(LLMAPIKeyResponse.self, data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch let error as EncodingError {
            throw APIError.networkError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }

    func deleteAPIKeyInAPI(provider: LLMProvider) async throws -> LLMAPIKeyResponse {
        guard provider != .ollama else {
            return LLMAPIKeyResponse(provider: provider.rawValue, api_key_masked: "")
        }

        guard let encodedProvider = provider.rawValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/llm-api-key?provider=\(encodedProvider)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return try decode(LLMAPIKeyResponse.self, data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    // MARK: - Local Storage

    func getInputFolder() -> String {
        UserDefaults.standard.string(forKey: inputFolderKey) ?? defaultInputFolder
    }

    func setInputFolder(_ path: String) {
        UserDefaults.standard.set(path, forKey: inputFolderKey)
    }

    func getOutputFolder() -> String {
        UserDefaults.standard.string(forKey: outputFolderKey) ?? defaultOutputFolder
    }

    func setOutputFolder(_ path: String) {
        UserDefaults.standard.set(path, forKey: outputFolderKey)
    }

    func getLLMProvider() -> LLMProvider {
        let raw = UserDefaults.standard.string(forKey: llmProviderKey) ?? LLMProvider.openai.rawValue
        return LLMProvider(rawValue: raw) ?? .openai
    }

    func setLLMProvider(_ provider: LLMProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: llmProviderKey)
    }

    func getLLMModel() -> String {
        UserDefaults.standard.string(forKey: llmModelKey) ?? "gpt-5.2"
    }

    func setLLMModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: llmModelKey)
    }

    func getLLMBaseURL() -> String {
        UserDefaults.standard.string(forKey: llmBaseURLKey) ?? ""
    }

    func setLLMBaseURL(_ value: String) {
        UserDefaults.standard.set(value, forKey: llmBaseURLKey)
    }

    func getStoredAPIKey(for provider: LLMProvider) -> String {
        let key = providerAPIKeyStorageKey(provider)
        guard !key.isEmpty else { return "" }
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    func setStoredAPIKey(_ value: String, for provider: LLMProvider) {
        let key = providerAPIKeyStorageKey(provider)
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    func getStoredMaskedAPIKey(for provider: LLMProvider) -> String {
        let key = providerMaskedAPIKeyStorageKey(provider)
        guard !key.isEmpty else { return "" }
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    func setStoredMaskedAPIKey(_ value: String, for provider: LLMProvider) {
        let key = providerMaskedAPIKeyStorageKey(provider)
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    func hasCompletedOnboarding() -> Bool {
        UserDefaults.standard.bool(forKey: onboardingCompletedKey)
    }

    func setOnboardingCompleted(_ completed: Bool) {
        UserDefaults.standard.set(completed, forKey: onboardingCompletedKey)
    }

    func getShortcut(for action: ShortcutAction) -> ShortcutDefinition {
        let storageKey = shortcutStorageKey(for: action)
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ShortcutDefinition.self, from: data) else {
            return action.defaultShortcut
        }

        var normalized = decoded
        normalized.normalize()
        return normalized
    }

    func setShortcut(_ shortcut: ShortcutDefinition, for action: ShortcutAction, notify: Bool = true) {
        let storageKey = shortcutStorageKey(for: action)
        var normalized = shortcut
        normalized.normalize()

        if let encoded = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }

        if notify {
            NotificationCenter.default.post(name: .archiveShortcutsDidChange, object: nil)
        }
    }

    func setShortcuts(
        search: ShortcutDefinition,
        upload: ShortcutDefinition,
        settings: ShortcutDefinition
    ) {
        setShortcut(search, for: .search, notify: false)
        setShortcut(upload, for: .upload, notify: false)
        setShortcut(settings, for: .settings, notify: false)
        NotificationCenter.default.post(name: .archiveShortcutsDidChange, object: nil)
    }

    // Backward-compatible wrappers for currently-selected provider
    func getLLMAPIKey() -> String {
        getStoredAPIKey(for: getLLMProvider())
    }

    func setLLMAPIKey(_ value: String) {
        setStoredAPIKey(value, for: getLLMProvider())
    }

    func getMaskedAPIKey() -> String {
        getStoredMaskedAPIKey(for: getLLMProvider())
    }

    // MARK: - Save/Load

    func saveAllSettingsToBackend() async throws {
        let dirs = try await updateDirectoriesInAPI(
            inputDir: getInputFolder(),
            archiveDir: getOutputFolder()
        )

        setInputFolder(dirs.input_dir)
        setOutputFolder(dirs.archive_dir)

        let llm = try await updateLLMSettingsInAPI(
            provider: getLLMProvider().rawValue,
            model: getLLMModel(),
            llmBaseURL: getLLMBaseURL()
        )

        if let provider = LLMProvider(rawValue: llm.provider) {
            setLLMProvider(provider)
            setStoredMaskedAPIKey(llm.api_key_masked, for: provider)
        }
        setLLMModel(llm.model)
        setLLMBaseURL(llm.base_url)
    }

    func loadSettingsFromBackend() async throws {
        let directories = try await fetchDirectoriesFromAPI()
        setInputFolder(directories.input_dir)
        setOutputFolder(directories.archive_dir)

        let llm = try await fetchLLMSettingsFromAPI()
        if let provider = LLMProvider(rawValue: llm.provider) {
            setLLMProvider(provider)
            setStoredMaskedAPIKey(llm.api_key_masked, for: provider)

            // Refresh masked state for supported cloud providers.
            if provider != .ollama {
                if let mask = try? await fetchAPIKeyMaskFromAPI(provider: provider) {
                    setStoredMaskedAPIKey(mask.api_key_masked, for: provider)
                }
            }
        }
        setLLMModel(llm.model)
        setLLMBaseURL(llm.base_url)
    }
}
