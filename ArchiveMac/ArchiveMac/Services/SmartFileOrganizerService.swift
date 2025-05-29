import Foundation
import Combine

/*
 * SmartFileOrganizerService.swift
 * 
 * Main coordinator service for the Smart File Organizer that orchestrates the complete file processing pipeline.
 * Integrates file monitoring, content extraction, semantic matching, and file operations for automated organization.
 */

// MARK: - Smart File Organizer Service

class SmartFileOrganizerService: ObservableObject {
    static let shared = SmartFileOrganizerService()
    
    @Published var isActive: Bool = false
    @Published var isProcessing: Bool = false
    @Published var currentFile: String? = nil
    @Published var processedCount: Int = 0
    
    private let fileMonitor = FileMonitoringService.shared
    private let contentExtractor = ContentExtractionService.shared
    private let vectorMatcher = VectorMatchingService.shared
    private let fileOperations = FileOperationsService.shared
    private let database = DatabaseService.shared
    
    private init() {
        setupFileMonitoring()
        start() // Always start when initialized
    }
    
    /// Set up file monitoring callbacks
    private func setupFileMonitoring() {
        fileMonitor.onFileDetected = { [weak self] fileURL in
            print("🔍 File detected: \(fileURL.lastPathComponent)")
            self?.processFile(fileURL)
        }
    }
    
    /// Start the organizer service with current settings
    private func start() {
        let settings = database.getSettings()
        let inputFolder = settings.inputFolder
        
        print("📁 Starting Smart File Organizer...")
        print("📂 Input folder: \(inputFolder)")
        print("📤 Output folder: \(settings.outputFolder)")
        
        // Ensure input folder exists
        if !FileManager.default.fileExists(atPath: inputFolder) {
            do {
                try FileManager.default.createDirectory(atPath: inputFolder, withIntermediateDirectories: true, attributes: nil)
                print("✅ Created input folder: \(inputFolder)")
            } catch {
                print("❌ Failed to create input folder: \(error)")
                return
            }
        }
        
        fileMonitor.startMonitoringFromSettings()
        
        DispatchQueue.main.async(qos: .userInitiated) {
            self.isActive = true
        }
        print("✅ Smart File Organizer started successfully")
        print("👁 Watching for new files in: \(inputFolder)")
    }
    
    /// Process a file through the complete organization pipeline
    func processFile(_ fileURL: URL) async -> Bool {
        await MainActor.run {
            self.isProcessing = true
            self.currentFile = fileURL.lastPathComponent
        }
        
        let success = await performFileProcessing(fileURL)
        
        await MainActor.run {
            self.isProcessing = false
            self.currentFile = nil
            if success {
                self.processedCount += 1
            }
        }
        
        return success
    }
    
    /// Execute the complete file processing pipeline
    private func performFileProcessing(_ fileURL: URL) async -> Bool {
        print("🔄 Processing file: \(fileURL.lastPathComponent)")
        
        do {
            // Step 1: Extract content from file
            print("📄 Extracting content from: \(fileURL.lastPathComponent)")
            let extractedContent = try await contentExtractor.extractContent(from: fileURL)
            print("✅ Extracted \(extractedContent.contentLength) characters from \(fileURL.lastPathComponent)")
            
            // Step 2: Find matching rule using semantic analysis
            print("🧠 Finding matching rule for: \(fileURL.lastPathComponent)")
            guard let matchResult = vectorMatcher.findBestMatch(for: extractedContent) else {
                print("❌ No matching rule found for: \(fileURL.lastPathComponent)")
                return false
            }
            
            print("✅ Match details for \(fileURL.lastPathComponent): \(matchResult.explanation)")
            
            // Step 3: Move file to destination
            print("📦 Moving \(fileURL.lastPathComponent) to: \(matchResult.rule.destinationFolder)")
            let operationResult = await fileOperations.moveFile(
                from: fileURL, 
                to: URL(fileURLWithPath: matchResult.rule.destinationFolder).appendingPathComponent(fileURL.lastPathComponent)
            )
            
            if operationResult.success {
                print("✅ Successfully organized: \(fileURL.lastPathComponent)")
                return true
            } else {
                print("❌ Failed to move \(fileURL.lastPathComponent): \(operationResult.error?.localizedDescription ?? "Unknown error")")
                return false
            }
            
        } catch {
            print("❌ Processing error for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
    
    /// Wrapper for private processFile method to maintain compatibility
    private func processFile(_ fileURL: URL) {
        Task {
            _ = await performFileProcessing(fileURL)
        }
    }
    
    /// Get recent file operations for UI display
    func getRecentOperations(limit: Int = 10) -> [FileOperation] {
        return fileOperations.getRecentOperations(limit: limit)
    }
    
    /// Update organizer settings when configuration changes
    func updateSettings() {
        print("🔄 Updating file monitoring settings...")
        fileMonitor.updateMonitoringFromSettings()
    }
    
    /// Stop the organizer service
    func stop() {
        fileMonitor.stopMonitoring()
        DispatchQueue.main.async(qos: .userInitiated) {
            self.isActive = false
        }
        print("🛑 Smart File Organizer stopped")
    }
} 