import Foundation
import AppKit

struct UpdateCheckResult {
    let currentVersion: String
    let currentBuild: String
    let latestVersion: String
    let releaseURL: URL?
    let releaseName: String
    let isUpdateAvailable: Bool
}

enum UpdateServiceError: Error {
    case invalidRepository
    case noPublishedVersion
    case rateLimited(retryDate: Date?)
    case requestFailed(statusCode: Int, message: String?)
    case invalidResponse

    var localizedDescription: String {
        switch self {
        case .invalidRepository:
            return "Update repository is not configured correctly or is not accessible."
        case .noPublishedVersion:
            return "No published release or tag found yet. Publish a GitHub release (or create a version tag) to enable update checks."
        case .rateLimited(let retryDate):
            if let retryDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "GitHub rate limit reached. Try again after \(formatter.string(from: retryDate))."
            }
            return "GitHub rate limit reached. Try again in a few minutes."
        case .requestFailed(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Update service error (\(statusCode)): \(message)"
            }
            return "Update service error (\(statusCode))."
        case .invalidResponse:
            return "Could not parse update metadata from GitHub."
        }
    }
}

private struct GitHubLatestReleaseResponse: Decodable {
    let tag_name: String
    let name: String?
    let html_url: String?
}

private struct GitHubTagResponse: Decodable {
    let name: String
}

private struct GitHubErrorResponse: Decodable {
    let message: String?
}

final class UpdateService {
    static let shared = UpdateService()

    private let fallbackRepository = "daniel-trachtenberg/archive-plugin"

    private init() {}

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"
    }

    var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    }

    var versionDisplayString: String {
        "\(currentVersion) (\(currentBuild))"
    }

    func checkForUpdates() async throws -> UpdateCheckResult {
        let repository = configuredRepository
        guard repository.contains("/") else {
            throw UpdateServiceError.invalidRepository
        }

        let latest = try await fetchLatestVersionInfo(repository: repository)
        let current = normalizedVersion(currentVersion)
        let latestVersion = normalizedVersion(latest.version)
        let isUpdateAvailable = compareVersions(current, latestVersion) == .orderedAscending

        return UpdateCheckResult(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            latestVersion: latestVersion,
            releaseURL: latest.url,
            releaseName: latest.name,
            isUpdateAvailable: isUpdateAvailable
        )
    }

    @MainActor
    func presentResultAlert(_ result: UpdateCheckResult, source: String = "Archive") {
        let alert = NSAlert()

        if result.isUpdateAvailable {
            alert.messageText = "Update available"
            alert.informativeText = "\(result.releaseName) is available. You’re on \(result.currentVersion) (\(result.currentBuild))."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Download")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn, let url = result.releaseURL {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.messageText = "You’re up to date"
            alert.informativeText = "\(source) is running version \(result.currentVersion) (\(result.currentBuild))."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @MainActor
    func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()

        if case UpdateServiceError.noPublishedVersion = error {
            alert.messageText = "No published release yet"
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Update check failed"
            alert.alertStyle = .warning
        }

        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var configuredRepository: String {
        if let repo = (Bundle.main.object(forInfoDictionaryKey: "ArchiveUpdateRepository") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !repo.isEmpty {
            return repo
        }
        return fallbackRepository
    }

    private func fetchLatestVersionInfo(repository: String) async throws -> (version: String, name: String, url: URL?) {
        let releasesURL = try makeGitHubAPIURL(path: "/repos/\(repository)/releases/latest")
        let (releaseData, releaseResponse) = try await performGitHubRequest(url: releasesURL)

        switch releaseResponse.statusCode {
        case 200:
            let releasePayload = try decode(GitHubLatestReleaseResponse.self, from: releaseData)
            let downloadURL = releasePayload.html_url.flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repository)/releases")
            let displayName = normalizedReleaseName(releasePayload.name, fallback: releasePayload.tag_name)
            return (
                version: releasePayload.tag_name,
                name: displayName,
                url: downloadURL
            )

        case 404:
            return try await fetchLatestTagInfo(repository: repository)

        case 403:
            throw mapRateLimitIfNeeded(response: releaseResponse, data: releaseData)

        default:
            let message = decodeGitHubErrorMessage(from: releaseData)
            throw UpdateServiceError.requestFailed(statusCode: releaseResponse.statusCode, message: message)
        }
    }

    private func fetchLatestTagInfo(repository: String) async throws -> (version: String, name: String, url: URL?) {
        let tagsURL = try makeGitHubAPIURL(path: "/repos/\(repository)/tags?per_page=1")
        let (tagData, tagResponse) = try await performGitHubRequest(url: tagsURL)

        switch tagResponse.statusCode {
        case 200:
            let tags = try decode([GitHubTagResponse].self, from: tagData)
            guard let first = tags.first else {
                throw UpdateServiceError.noPublishedVersion
            }
            return (
                version: first.name,
                name: "Tag \(first.name)",
                url: URL(string: "https://github.com/\(repository)/releases")
            )

        case 404:
            throw UpdateServiceError.invalidRepository

        case 403:
            throw mapRateLimitIfNeeded(response: tagResponse, data: tagData)

        default:
            let message = decodeGitHubErrorMessage(from: tagData)
            throw UpdateServiceError.requestFailed(statusCode: tagResponse.statusCode, message: message)
        }
    }

    private func performGitHubRequest(url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ArchiveMac/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateServiceError.invalidResponse
        }

        return (data, httpResponse)
    }

    private func makeGitHubAPIURL(path: String) throws -> URL {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw UpdateServiceError.invalidRepository
        }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UpdateServiceError.invalidResponse
        }
    }

    private func decodeGitHubErrorMessage(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data) else {
            return nil
        }
        return payload.message?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mapRateLimitIfNeeded(response: HTTPURLResponse, data: Data) -> UpdateServiceError {
        let message = decodeGitHubErrorMessage(from: data)?.lowercased() ?? ""
        if message.contains("rate limit") {
            var retryDate: Date?
            if let resetValue = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
               let epoch = TimeInterval(resetValue) {
                retryDate = Date(timeIntervalSince1970: epoch)
            }
            return .rateLimited(retryDate: retryDate)
        }

        return .requestFailed(statusCode: response.statusCode, message: decodeGitHubErrorMessage(from: data))
    }

    private func normalizedReleaseName(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericComponents(from: lhs)
        let right = numericComponents(from: rhs)

        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r {
                return .orderedAscending
            }
            if l > r {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    private func numericComponents(from version: String) -> [Int] {
        var values: [Int] = []
        var current = ""

        for char in version {
            if char.isNumber {
                current.append(char)
            } else if !current.isEmpty {
                values.append(Int(current) ?? 0)
                current = ""
            }
        }

        if !current.isEmpty {
            values.append(Int(current) ?? 0)
        }

        return values.isEmpty ? [0] : values
    }
}
