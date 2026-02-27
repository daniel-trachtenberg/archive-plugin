import Darwin
import Foundation

final class BackendService {
    static let shared = BackendService()

    private let queue = DispatchQueue(label: "archive.backend.service")
    private var process: Process?
    private var logPipe: Pipe?
    private var isStarting = false
    private var monitorTimer: DispatchSourceTimer?
    private var unhealthyRunningChecks = 0

    private let host: String
    private let port: Int
    private let monitorIntervalSeconds: TimeInterval = 45
    private let maxUnhealthyRunningChecksBeforeRestart = 3

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

    func startLifecycleMonitoring() {
        queue.async { [weak self] in
            self?.startLifecycleMonitoringSync()
        }
    }

    func stopLifecycleMonitoring() {
        queue.async { [weak self] in
            self?.stopLifecycleMonitoringSync()
        }
    }

    func stopManagedBackend() {
        queue.async { [weak self] in
            self?.stopManagedBackendSync()
        }
    }

    func shutdownForApplicationTermination(timeout: TimeInterval = 8.0) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.stopLifecycleMonitoringSync()
            self?.stopManagedBackendSync(force: true)
            _ = self?.stopUnmanagedBackendIfPresentSync()
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func startIfNeededSync() {
        if process == nil, isBackendHealthy(timeout: 1.0) {
            if !stopUnmanagedBackendIfPresentSync() {
                unhealthyRunningChecks = 0
                return
            }
        }

        if isBackendHealthy(timeout: 1.0) {
            unhealthyRunningChecks = 0
            return
        }

        if process?.isRunning == true {
            unhealthyRunningChecks += 1

            if unhealthyRunningChecks >= maxUnhealthyRunningChecksBeforeRestart {
                log("Managed backend is running but unhealthy. Restarting process.")
                stopManagedBackendSync()
                unhealthyRunningChecks = 0
            } else {
                log("Managed backend is running but not healthy (\(unhealthyRunningChecks)/\(maxUnhealthyRunningChecksBeforeRestart)).")
                return
            }
        }

        guard !isStarting else {
            return
        }
        isStarting = true
        defer { isStarting = false }
        unhealthyRunningChecks = 0

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

    private func stopManagedBackendSync(force: Bool = false) {
        guard let process else {
            return
        }

        logPipe?.fileHandleForReading.readabilityHandler = nil

        if !process.isRunning {
            self.process = nil
            self.logPipe = nil
            unhealthyRunningChecks = 0
            return
        }

        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(force ? 1.5 : 4.0)
        while process.isRunning && Date() < gracefulDeadline {
            usleep(100_000)
        }

        if process.isRunning {
            let pid = process.processIdentifier
            log("Managed backend did not terminate gracefully. Sending SIGKILL to pid \(pid).")
            _ = kill(pid, SIGKILL)

            let killDeadline = Date().addingTimeInterval(1.5)
            while process.isRunning && Date() < killDeadline {
                usleep(50_000)
            }
        }

        self.process = nil
        self.logPipe = nil
        unhealthyRunningChecks = 0
        log("Stopped managed backend process.")
    }

    private func startLifecycleMonitoringSync() {
        guard monitorTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + 1.0,
            repeating: .milliseconds(Int(monitorIntervalSeconds * 1000))
        )
        timer.setEventHandler { [weak self] in
            self?.startIfNeededSync()
        }
        monitorTimer = timer
        timer.resume()

        startIfNeededSync()
    }

    private func stopLifecycleMonitoringSync() {
        monitorTimer?.cancel()
        monitorTimer = nil
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
        environment["ARCHIVE_MANAGED_BY_APP"] = "1"
        environment["ARCHIVE_APP_PID"] = String(getpid())
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

                guard self?.monitorTimer != nil else {
                    return
                }

                self?.queue.asyncAfter(deadline: .now() + 1.0) {
                    self?.startIfNeededSync()
                }
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

    private func stopUnmanagedBackendIfPresentSync() -> Bool {
        guard process == nil else {
            return true
        }

        guard isBackendHealthy(timeout: 0.9) else {
            return true
        }

        log("Detected backend process not managed by current app instance. Attempting to stop it.")
        let requestedShutdown = requestBackendShutdown(timeout: 1.5)
        if requestedShutdown {
            waitForBackendToStop(timeout: 4.0)
        }

        if isBackendHealthy(timeout: 0.9) {
            _ = terminateListeningBackendProcessIfKnown()
            waitForBackendToStop(timeout: 2.0)
        }

        if isBackendHealthy(timeout: 0.9) {
            log("Unable to stop unmanaged backend process; skipping managed restart to avoid port conflict.")
            return false
        }

        log("Stopped unmanaged backend process.")
        return true
    }

    private func requestBackendShutdown(timeout: TimeInterval) -> Bool {
        let shutdownURL = baseURL.appendingPathComponent("shutdown")
        var request = URLRequest(url: shutdownURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var accepted = false

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else {
                return
            }
            accepted = (200...299).contains(http.statusCode)
        }

        task.resume()
        let waited = semaphore.wait(timeout: .now() + timeout + 0.5)
        if waited == .timedOut {
            task.cancel()
            return false
        }

        return accepted
    }

    private func waitForBackendToStop(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while Date() < deadline {
            if !isBackendHealthy(timeout: 0.4) {
                return
            }
            usleep(150_000)
        }
    }

    private func terminateListeningBackendProcessIfKnown() -> Bool {
        guard let pid = listeningPIDForBackendPort() else {
            return false
        }

        guard let command = commandLineForPID(pid), isLikelyArchiveBackendCommand(command) else {
            log("Refusing to kill pid \(pid) because it does not look like Archive backend.")
            return false
        }

        log("Sending SIGTERM to unmanaged backend pid \(pid).")
        _ = kill(pid, SIGTERM)
        waitForBackendToStop(timeout: 1.5)

        if isBackendHealthy(timeout: 0.7) {
            log("Unmanaged backend pid \(pid) still running. Sending SIGKILL.")
            _ = kill(pid, SIGKILL)
        }

        return true
    }

    private func listeningPIDForBackendPort() -> Int32? {
        let output = runCommand(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
            timeout: 2.0
        )

        guard let output else {
            return nil
        }

        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = Int32(firstLine), pid > 1 else {
            return nil
        }
        return pid
    }

    private func commandLineForPID(_ pid: Int32) -> String? {
        let output = runCommand(
            executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="],
            timeout: 2.0
        )
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runCommand(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitDeadline = Date().addingTimeInterval(max(timeout, 0.2))
        while process.isRunning && Date() < waitDeadline {
            usleep(50_000)
        }

        if process.isRunning {
            process.terminate()
            usleep(100_000)
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func isLikelyArchiveBackendCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("/backend/main.py")
            || normalized.contains("archivemac.app/contents/resources/backend")
            || normalized.contains("archive-plugin/backend")
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
