import Foundation
import Combine

/*
 * FileOperationsService.swift
 * 
 * This service handles safe file operations for the Smart File Organizer.
 * It provides secure file moving with conflict resolution, undo functionality,
 * and comprehensive error handling.
 * 
 * Features:
 * - Safe file moving with atomic operations
 * - Automatic conflict resolution (duplicate naming)
 * - Undo functionality with operation history
 * - Directory creation and validation
 * - Comprehensive error handling and recovery
 */

// MARK: - File Operation Models

struct FileOperation {
    let id: UUID
    let type: OperationType
    let sourceURL: URL
    let destinationURL: URL
    let timestamp: Date
    let rule: OrganizationRule?
    let matchResult: MatchResult?
    
    enum OperationType {
        case move
        case copy
        case undo
    }
    
    init(type: OperationType, sourceURL: URL, destinationURL: URL, rule: OrganizationRule? = nil, matchResult: MatchResult? = nil) {
        self.id = UUID()
        self.type = type
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.timestamp = Date()
        self.rule = rule
        self.matchResult = matchResult
    }
}

// MARK: - Operation Result

struct OperationResult {
    let operation: FileOperation
    let success: Bool
    let error: FileOperationError?
    let finalDestinationURL: URL?
    
    init(operation: FileOperation, success: Bool, error: FileOperationError? = nil, finalDestinationURL: URL? = nil) {
        self.operation = operation
        self.success = success
        self.error = error
        self.finalDestinationURL = finalDestinationURL ?? (success ? operation.destinationURL : nil)
    }
}

// MARK: - File Operation Errors

enum FileOperationError: Error {
    case sourceFileNotFound
    case destinationNotAccessible
    case insufficientSpace
    case permissionDenied
    case fileInUse
    case operationCancelled
    case unknownError(String)
    
    var localizedDescription: String {
        switch self {
        case .sourceFileNotFound:
            return "Source file not found"
        case .destinationNotAccessible:
            return "Destination folder not accessible"
        case .insufficientSpace:
            return "Insufficient disk space"
        case .permissionDenied:
            return "Permission denied"
        case .fileInUse:
            return "File is currently in use"
        case .operationCancelled:
            return "Operation was cancelled"
        case .unknownError(let message):
            return "Unknown error: \(message)"
        }
    }
}

// MARK: - File Operations Service

class FileOperationsService: ObservableObject {
    static let shared = FileOperationsService()
    
    // MARK: - Published Properties
    @Published var isProcessing: Bool = false
    @Published var currentOperation: String? = nil
    @Published var operationHistory: [FileOperation] = []
    
    // MARK: - Private Properties
    private let fileManager = FileManager.default
    private let operationQueue = DispatchQueue(label: "com.archivemac.fileoperations", qos: .userInitiated)
    private var operationHistoryLimit = 100
    
    // Callbacks
    var onOperationComplete: ((OperationResult) -> Void)?
    var onOperationProgress: ((String) -> Void)?
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Move a file to its destination based on a match result
    func moveFile(from sourceURL: URL, using matchResult: MatchResult) async -> OperationResult {
        let destinationFolder = matchResult.rule.destinationFolder
        let destinationURL = URL(fileURLWithPath: destinationFolder).appendingPathComponent(sourceURL.lastPathComponent)
        
        let operation = FileOperation(
            type: .move,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            rule: matchResult.rule,
            matchResult: matchResult
        )
        
        return await performFileOperation(operation)
    }
    
    /// Move a file to a specific destination
    func moveFile(from sourceURL: URL, to destinationURL: URL) async -> OperationResult {
        let operation = FileOperation(
            type: .move,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        
        return await performFileOperation(operation)
    }
    
    /// Undo the last file operation
    func undoLastOperation() async -> OperationResult? {
        guard let lastOperation = operationHistory.last else { return nil }
        
        // Create undo operation (reverse the last operation)
        let undoOperation = FileOperation(
            type: .undo,
            sourceURL: lastOperation.destinationURL,
            destinationURL: lastOperation.sourceURL
        )
        
        let result = await performFileOperation(undoOperation)
        
        if result.success {
            // Remove the undone operation from history
            operationHistory.removeLast()
        }
        
        return result
    }
    
    /// Undo a specific operation by ID
    func undoOperation(withId operationId: UUID) async -> OperationResult? {
        guard let operation = operationHistory.first(where: { $0.id == operationId }) else {
            return nil
        }
        
        let undoOperation = FileOperation(
            type: .undo,
            sourceURL: operation.destinationURL,
            destinationURL: operation.sourceURL
        )
        
        let result = await performFileOperation(undoOperation)
        
        if result.success {
            // Remove the undone operation from history
            operationHistory.removeAll { $0.id == operationId }
        }
        
        return result
    }
    
    /// Get recent operations
    func getRecentOperations(limit: Int = 10) -> [FileOperation] {
        return Array(operationHistory.suffix(limit).reversed())
    }
    
    /// Clear operation history
    func clearHistory() {
        operationHistory.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func performFileOperation(_ operation: FileOperation) async -> OperationResult {
        return await withCheckedContinuation { continuation in
            operationQueue.async {
                // Update UI on main thread with proper QoS
                DispatchQueue.main.async(qos: .userInitiated) {
                    self.isProcessing = true
                    self.currentOperation = "Processing \(operation.sourceURL.lastPathComponent)..."
                }
                
                let result = self.executeOperation(operation)
                
                // Update UI on main thread with proper QoS
                DispatchQueue.main.async(qos: .userInitiated) {
                    self.isProcessing = false
                    self.currentOperation = nil
                    
                    if result.success && operation.type != .undo {
                        self.addToHistory(operation)
                    }
                    
                    self.onOperationComplete?(result)
                }
                
                continuation.resume(returning: result)
            }
        }
    }
    
    private func executeOperation(_ operation: FileOperation) -> OperationResult {
        do {
            // Validate source file exists
            guard fileManager.fileExists(atPath: operation.sourceURL.path) else {
                return OperationResult(operation: operation, success: false, error: .sourceFileNotFound)
            }
            
            // Ensure destination directory exists
            let destinationDirectory = operation.destinationURL.deletingLastPathComponent()
            try createDirectoryIfNeeded(destinationDirectory)
            
            // Handle file name conflicts
            let finalDestinationURL = try resolveFileNameConflict(operation.destinationURL)
            
            // Check available space
            try validateDiskSpace(sourceURL: operation.sourceURL, destinationURL: finalDestinationURL)
            
            // Perform the actual file operation
            switch operation.type {
            case .move, .undo:
                try fileManager.moveItem(at: operation.sourceURL, to: finalDestinationURL)
            case .copy:
                try fileManager.copyItem(at: operation.sourceURL, to: finalDestinationURL)
            }
            
            print("Successfully \(operation.type == .move ? "moved" : "copied") file: \(operation.sourceURL.lastPathComponent) -> \(finalDestinationURL.path)")
            
            return OperationResult(
                operation: operation,
                success: true,
                finalDestinationURL: finalDestinationURL
            )
            
        } catch let error as FileOperationError {
            print("File operation failed: \(error.localizedDescription)")
            return OperationResult(operation: operation, success: false, error: error)
            
        } catch {
            print("File operation failed with system error: \(error.localizedDescription)")
            let operationError = mapSystemError(error)
            return OperationResult(operation: operation, success: false, error: operationError)
        }
    }
    
    private func createDirectoryIfNeeded(_ directoryURL: URL) throws {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            print("Created directory: \(directoryURL.path)")
        } catch {
            throw FileOperationError.destinationNotAccessible
        }
    }
    
    private func resolveFileNameConflict(_ originalURL: URL) throws -> URL {
        var destinationURL = originalURL
        var counter = 1
        
        while fileManager.fileExists(atPath: destinationURL.path) {
            let fileName = originalURL.deletingPathExtension().lastPathComponent
            let fileExtension = originalURL.pathExtension
            let directory = originalURL.deletingLastPathComponent()
            
            let newFileName: String
            if fileExtension.isEmpty {
                newFileName = "\(fileName) (\(counter))"
            } else {
                newFileName = "\(fileName) (\(counter)).\(fileExtension)"
            }
            
            destinationURL = directory.appendingPathComponent(newFileName)
            counter += 1
            
            // Prevent infinite loops
            if counter > 1000 {
                throw FileOperationError.unknownError("Too many file name conflicts")
            }
        }
        
        return destinationURL
    }
    
    private func validateDiskSpace(sourceURL: URL, destinationURL: URL) throws {
        do {
            // Get source file size
            let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            let fileSize = sourceAttributes[.size] as? Int64 ?? 0
            
            // Get available space at destination volume
            let destinationDirectory = destinationURL.deletingLastPathComponent()
            let volumeAttributes = try fileManager.attributesOfFileSystem(forPath: destinationDirectory.path)
            let availableSpace = volumeAttributes[.systemFreeSize] as? Int64 ?? 0
            
            print("📊 File size: \(formatFileSize(fileSize)), Available space: \(formatFileSize(availableSpace))")
            
            // Check if there's enough space (with 10% buffer, but at least 1MB minimum)
            let bufferSpace = max(Int64(Double(fileSize) * 0.1), 1_048_576) // 1MB minimum buffer
            let requiredSpace = fileSize + bufferSpace
            
            if availableSpace < requiredSpace {
                print("❌ Insufficient space: need \(formatFileSize(requiredSpace)), have \(formatFileSize(availableSpace))")
                throw FileOperationError.insufficientSpace
            }
            
            print("✅ Sufficient space available for file operation")
            
        } catch FileOperationError.insufficientSpace {
            throw FileOperationError.insufficientSpace
        } catch {
            // If we can't check space, proceed anyway but log warning
            print("⚠️ Warning: Could not verify disk space: \(error.localizedDescription)")
            print("📁 Destination: \(destinationURL.deletingLastPathComponent().path)")
        }
    }
    
    private func mapSystemError(_ error: Error) -> FileOperationError {
        let nsError = error as NSError
        
        switch nsError.code {
        case NSFileReadNoSuchFileError:
            return .sourceFileNotFound
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .permissionDenied
        case NSFileWriteFileExistsError:
            return .unknownError("File already exists")
        case NSFileWriteVolumeReadOnlyError:
            return .destinationNotAccessible
        default:
            return .unknownError(error.localizedDescription)
        }
    }
    
    private func addToHistory(_ operation: FileOperation) {
        operationHistory.append(operation)
        
        // Limit history size
        if operationHistory.count > operationHistoryLimit {
            operationHistory.removeFirst(operationHistory.count - operationHistoryLimit)
        }
    }
    
    // MARK: - Utility Methods
    
    /// Check if a file can be moved (not in use, accessible, etc.)
    func canMoveFile(at url: URL) -> Bool {
        // Check if file exists
        guard fileManager.fileExists(atPath: url.path) else { return false }
        
        // Check if file is readable
        guard fileManager.isReadableFile(atPath: url.path) else { return false }
        
        // Check if file is writable (for moving)
        guard fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path) else { return false }
        
        // Additional checks could be added here (file locks, etc.)
        
        return true
    }
    
    /// Get file size in bytes
    func getFileSize(at url: URL) -> Int64? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64
        } catch {
            return nil
        }
    }
    
    /// Format file size for display
    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
} 