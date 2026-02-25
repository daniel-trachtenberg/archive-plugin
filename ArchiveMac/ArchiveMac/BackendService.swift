import Foundation

final class BackendService {
    static let shared = BackendService()

    private let queue = DispatchQueue(label: "archive.backend.service")
    private var process: Process?
    private var logPipe: Pipe?
    private var isStarting = false

    private let host: String
    private let port: Int

    private init() {
        host = BackendService.resolveHost()
        port = BackendService.resolvePort()
    }

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    var baseURLString: String {
        baseURL.absoluteString
    }

    func startIfNeeded() {
        queue.async { [weak self] in
            self?.startIfNeededSync()
        }
    }

    func stopManagedBackend() {
        queue.async { [weak self] in
            self?.stopManagedBackendSync()
        }
    }

    private func startIfNeededSync() {
        if isBackendHealthy(timeout: 1.0) {
            log("Detected healthy backend at \(baseURLString).")
            return
        }

        guard process?.isRunning != true else {
            log("Backend process is already running.")
            return
        }

        guard !isStarting else {
            return
        }
        isStarting = true
        defer { isStarting = false }

        guard let backendDirectory = locateBackendDirectory() else {
            log("Could not find backend directory. Set ARCHIVE_BACKEND_DIR or bundle backend resources.")
            return
        }

        do {
            try launchBackendProcess(backendDirectory: backendDirectory)
        } catch {
            log("Failed to launch backend process: \(error.localizedDescription)")
            return
        }

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if isBackendHealthy(timeout: 1.25) {
                log("Managed backend started successfully.")
                return
            }
            usleep(250_000)
        }

        log("Backend process started but health check timed out.")
    }

    private func stopManagedBackendSync() {
        guard let process, process.isRunning else {
            return
        }

        process.terminate()
        self.process = nil
        self.logPipe = nil
        log("Stopped managed backend process.")
    }

    private func launchBackendProcess(backendDirectory: URL) throws {
        let (executable, arguments) = resolvePythonInvocation(backendDirectory: backendDirectory)
        let fileManager = FileManager.default

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = backendDirectory

        var environment = ProcessInfo.processInfo.environment
        let envFileURL = prepareBackendEnvFile(backendDirectory: backendDirectory, fileManager: fileManager)

        environment["HOST"] = host
        environment["PORT"] = String(port)
        if let envFileURL {
            environment["ARCHIVE_ENV_PATH"] = envFileURL.path
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return
            }

            print("[archive-backend] \(text)")
        }

        process.terminationHandler = { [weak self] exitedProcess in
            self?.queue.async {
                self?.process = nil
                self?.logPipe = nil
                self?.log("Backend process exited (status \(exitedProcess.terminationStatus)).")
            }
        }

        try process.run()
        self.process = process
        self.logPipe = pipe
    }

    private func resolvePythonInvocation(backendDirectory: URL) -> (String, [String]) {
        let fileManager = FileManager.default

        if let overridePath = ProcessInfo.processInfo.environment["ARCHIVE_BACKEND_PYTHON"],
           fileManager.isExecutableFile(atPath: overridePath) {
            return (overridePath, ["main.py"])
        }

        let candidates = [
            backendDirectory.appendingPathComponent(".venv/bin/python3").path,
            backendDirectory.appendingPathComponent(".venv/bin/python").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        if let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return (executable, ["main.py"])
        }

        // Fallback to PATH resolution.
        return ("/usr/bin/env", ["python3", "main.py"])
    }

    private func prepareBackendEnvFile(backendDirectory: URL, fileManager: FileManager) -> URL? {
        let supportDirectory = backendSupportDirectory(fileManager: fileManager)
        do {
            try fileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            log("Failed creating backend support directory: \(error.localizedDescription)")
            return nil
        }

        let envFileURL = supportDirectory.appendingPathComponent("backend.env")
        if fileManager.fileExists(atPath: envFileURL.path) {
            return envFileURL
        }

        let envExampleURL = backendDirectory.appendingPathComponent(".env.example")
        if fileManager.fileExists(atPath: envExampleURL.path) {
            do {
                let contents = try String(contentsOf: envExampleURL, encoding: .utf8)
                try contents.write(to: envFileURL, atomically: true, encoding: .utf8)
                return envFileURL
            } catch {
                log("Failed copying backend env template: \(error.localizedDescription)")
            }
        }

        do {
            try "".write(to: envFileURL, atomically: true, encoding: .utf8)
            return envFileURL
        } catch {
            log("Failed creating backend env file: \(error.localizedDescription)")
            return nil
        }
    }

    private func backendSupportDirectory(fileManager: FileManager) -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["ARCHIVE_BACKEND_SUPPORT_DIR"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }

        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupportBase
            .appendingPathComponent("ArchivePlugin", isDirectory: true)
            .appendingPathComponent("backend", isDirectory: true)
    }

    private func locateBackendDirectory() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["ARCHIVE_BACKEND_DIR"], !envPath.isEmpty {
            let candidate = URL(fileURLWithPath: envPath, isDirectory: true)
            if isValidBackendDirectory(candidate) {
                return candidate
            }
        }

        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("backend", isDirectory: true),
           isValidBackendDirectory(resourceURL) {
            return resourceURL
        }

        let fileManager = FileManager.default
        let searchRoots = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
            Bundle.main.bundleURL,
        ]

        for root in searchRoots {
            if let found = findBackendDirectory(from: root, depthLimit: 8) {
                return found
            }
        }

        return nil
    }

    private func findBackendDirectory(from root: URL, depthLimit: Int) -> URL? {
        var current = root.standardizedFileURL

        for _ in 0..<depthLimit {
            let candidate = current.appendingPathComponent("backend", isDirectory: true)
            if isValidBackendDirectory(candidate) {
                return candidate
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return nil
    }

    private func isValidBackendDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("main.py").path)
    }

    private func isBackendHealthy(timeout: TimeInterval) -> Bool {
        let healthURL = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }

            guard error == nil else {
                return
            }

            guard let http = response as? HTTPURLResponse else {
                return
            }

            healthy = (200...299).contains(http.statusCode)
        }

        task.resume()
        let waited = semaphore.wait(timeout: .now() + timeout + 0.5)
        if waited == .timedOut {
            task.cancel()
        }

        return healthy
    }

    private static func resolveHost() -> String {
        let rawHost = ProcessInfo.processInfo.environment["ARCHIVE_BACKEND_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawHost, !rawHost.isEmpty {
            return rawHost
        }
        return "127.0.0.1"
    }

    private static func resolvePort() -> Int {
        if let rawPort = ProcessInfo.processInfo.environment["ARCHIVE_BACKEND_PORT"],
           let parsed = Int(rawPort),
           parsed > 0 && parsed <= 65535 {
            return parsed
        }
        return 8000
    }

    private func log(_ message: String) {
        print("[BackendService] \(message)")
    }
}
