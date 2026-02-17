import Foundation

struct DirectoryConfig: Codable {
    var input_dir: String
    var archive_dir: String
}

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

final class SettingsService {
    static let shared = SettingsService()

    private let baseURL = "http://localhost:8000"

    private let inputFolderKey = "inputFolder"
    private let outputFolderKey = "outputFolder"

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
        // Remove legacy organization rules key during upgrade.
        UserDefaults.standard.removeObject(forKey: "organizationRules")
    }

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

            return try JSONDecoder().decode(DirectoryConfig.self, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
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

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw APIError.serverError(httpResponse.statusCode)
            }

            return try JSONDecoder().decode(DirectoryConfig.self, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }

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

    func saveSettingsToBackend() async throws -> DirectoryConfig {
        try await updateDirectoriesInAPI(
            inputDir: getInputFolder(),
            archiveDir: getOutputFolder()
        )
    }

    func saveSettingsToBackend(completion: @escaping (Bool, Error?) -> Void) {
        Task {
            do {
                let result = try await saveSettingsToBackend()
                setInputFolder(result.input_dir)
                setOutputFolder(result.archive_dir)

                await MainActor.run {
                    completion(true, nil)
                }
            } catch {
                await MainActor.run {
                    completion(false, error)
                }
            }
        }
    }

    func loadDirectoriesFromBackend() async throws {
        let config = try await fetchDirectoriesFromAPI()
        setInputFolder(config.input_dir)
        setOutputFolder(config.archive_dir)
    }
}
