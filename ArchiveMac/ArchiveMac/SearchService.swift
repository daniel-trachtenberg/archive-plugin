import Foundation

class SearchService {
    static let shared = SearchService()
    private let maxRetries = 3
    private let backendKickMinInterval: TimeInterval = 8
    private let backendKickQueue = DispatchQueue(label: "archive.search.backend-kick")
    private var lastBackendKickAt = Date.distantPast
    
    private init() {}

    private func ensureBackendStartedIfNeeded() {
        backendKickQueue.async {
            let now = Date()
            guard now.timeIntervalSince(self.lastBackendKickAt) >= self.backendKickMinInterval else {
                return
            }
            self.lastBackendKickAt = now
            BackendService.shared.startIfNeeded()
        }
    }
    
    // Traditional callback-based method (keep for backward compatibility)
    func search(query: String, completion: @escaping ([SearchResult]) -> Void) {
        Task(priority: .utility) {
            let results = await searchAsync(query: query)
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }
    
    // Modern async/await version
    func searchAsync(query: String) async -> [SearchResult] {
        guard !query.isEmpty else {
            return []
        }

        ensureBackendStartedIfNeeded()
        
        return await performSearch(query: query, retryCount: 0)
    }
    
    private func performSearch(query: String, retryCount: Int) async -> [SearchResult] {
        guard var components = URLComponents(
            url: BackendService.shared.baseURL.appendingPathComponent("query"),
            resolvingAgainstBaseURL: false
        ) else {
            return []
        }

        components.queryItems = [
            URLQueryItem(name: "query_text", value: query),
            URLQueryItem(name: "n_results", value: "10"),
        ]

        guard let url = components.url else {
            return []
        }
        
        // Create a URLRequest with a longer timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0 // Increase timeout to 10 seconds
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("Search endpoint returned status: \(http.statusCode)")
                return []
            }
            
            guard !data.isEmpty else {
                print("No data received from search endpoint")
                return []
            }
            
            // Parse the JSON response
            let decoder = JSONDecoder()
            let searchResponse = try decoder.decode(SearchResponse.self, from: data)
            
            // Exclude hidden files/folders in case stale index entries still exist.
            return searchResponse.results
                .filter { !self.isHiddenPath($0) }
                .map { filePath -> SearchResult in
                let url = URL(fileURLWithPath: filePath)
                let fileName = url.lastPathComponent
                let fileDirectory = url.deletingLastPathComponent().path
                let fileType = determineFileType(from: filePath)
                
                return SearchResult(
                    name: fileName,
                    path: fileDirectory,
                    type: fileType
                )
                }
            
        } catch {
            print("Search error: \(error.localizedDescription)")
            
            // Retry logic
            if retryCount < maxRetries {
                print("Retrying search (attempt \(retryCount + 1)/\(maxRetries))")
                
                // Wait with exponential backoff
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (retryCount + 1)))
                return await performSearch(query: query, retryCount: retryCount + 1)
            }
            
            return []
        }
    }
    
    private func determineFileType(from path: String) -> SearchResult.FileType {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        
        switch fileExtension {
        case "pdf", "doc", "docx", "ppt", "pptx":
            return .document
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp":
            return .image
        case "xls", "xlsx", "csv":
            return .spreadsheet
        case "txt", "md", "rtf":
            return .text
        default:
            return .other
        }
    }

    private func isHiddenPath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.contains { component in
            guard component != "/" && component != "." else { return false }
            return component.hasPrefix(".")
        }
    }
}

// Define the structure of the API response
struct SearchResponse: Decodable {
    let results: [String]
}
