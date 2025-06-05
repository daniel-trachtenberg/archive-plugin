import Foundation
import SwiftData
import NaturalLanguage
import Combine

/*
 * DatabaseService.swift
 * 
 * Manages the SwiftData stack and provides database operations for the Smart File Organizer.
 * Handles app settings, organization rules, and data persistence only.
 * Vector matching logic has been moved to VectorMatchingService.
 */

// MARK: - Database Errors

enum DatabaseError: Error {
    case contextSaveFailed(Error)
    case entityNotFound
    case embeddingGenerationFailed
    case invalidData
    
    var localizedDescription: String {
        switch self {
        case .contextSaveFailed(let error):
            return "Failed to save database context: \(error.localizedDescription)"
        case .entityNotFound:
            return "Required database entity not found"
        case .embeddingGenerationFailed:
            return "Failed to generate text embeddings"
        case .invalidData:
            return "Invalid data provided to database"
        }
    }
}

// MARK: - Database Service

class DatabaseService: ObservableObject {
    static let shared = DatabaseService()
    
    private var modelContainer: ModelContainer
    private var context: ModelContext
    private let nlEmbedding = NLEmbedding.wordEmbedding(for: .english)
    
    private init() {
        do {
            modelContainer = try ModelContainer(for: AppSettings.self, OrganizationRule.self)
            context = ModelContext(modelContainer)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
    
    // MARK: - Settings Management
    
    /// Get current app settings (input and output folder paths, monitoring status)
    func getSettings() -> (inputFolder: String, outputFolder: String, isFileMonitoringActive: Bool) {
        do {
            let descriptor = FetchDescriptor<AppSettings>()
            let settings = try context.fetch(descriptor).first
            
            if let settings = settings {
                return (settings.inputFolderPath, settings.outputFolderPath, settings.isFileMonitoringActive)
            } else {
                return createDefaultSettings()
            }
        } catch {
            print("Failed to fetch settings: \(error)")
            return createDefaultSettings()
        }
    }
    
    /// Update app settings with new folder paths and monitoring status
    func updateSettings(inputFolder: String, outputFolder: String, isFileMonitoringActive: Bool) {
        do {
            let descriptor = FetchDescriptor<AppSettings>()
            let settings = try context.fetch(descriptor).first
            
            if let existingSettings = settings {
                existingSettings.inputFolderPath = inputFolder
                existingSettings.outputFolderPath = outputFolder
                existingSettings.isFileMonitoringActive = isFileMonitoringActive
                existingSettings.lastModified = Date()
            } else {
                let newSettings = AppSettings(inputFolderPath: inputFolder, outputFolderPath: outputFolder, isFileMonitoringActive: isFileMonitoringActive)
                context.insert(newSettings)
            }
            
            try context.save()
        } catch {
            print("Failed to update settings: \(error)")
        }
    }
    
    /// Create default settings if none exist
    private func createDefaultSettings() -> (String, String, Bool) {
        let defaultInputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Input").path
        let defaultOutputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Output").path
        let defaultMonitoringStatus = true
        
        updateSettings(inputFolder: defaultInputFolder, outputFolder: defaultOutputFolder, isFileMonitoringActive: defaultMonitoringStatus)
        return (defaultInputFolder, defaultOutputFolder, defaultMonitoringStatus)
    }
    
    // MARK: - Organization Rules Management
    
    /// Get all organization rules, sorted by creation date
    func getAllRules() -> [OrganizationRule] {
        do {
            let descriptor = FetchDescriptor<OrganizationRule>(sortBy: [SortDescriptor(\.createdAt)])
            return try context.fetch(descriptor)
        } catch {
            print("Failed to fetch rules: \(error)")
            return []
        }
    }
    
    /// Save or update an organization rule with vector embedding
    func saveRule(_ rule: OrganizationRule) {
        do {
            // Generate and store keyword embeddings for potential future use
            if let keywordEmbeddings = generateKeywordEmbeddings(for: rule.keywords) {
                if let jsonData = try? JSONSerialization.data(withJSONObject: keywordEmbeddings) {
                    rule.textEmbedding = jsonData
                } else {
                    print("Failed to serialize keyword embeddings to JSON")
                }
            }
            
            // Insert the rule. If it's already managed, SwiftData handles this gracefully.
            context.insert(rule)
            
            try context.save()
        } catch {
            print("Failed to save rule: \(error)")
        }
    }
    
    /// Delete an organization rule by ID
    func deleteRule(withId id: UUID) {
        do {
            let descriptor = FetchDescriptor<OrganizationRule>(predicate: #Predicate { $0.id == id })
            if let rule = try context.fetch(descriptor).first {
                context.delete(rule)
                try context.save()
            }
        } catch {
            print("Failed to delete rule: \(error)")
        }
    }
    
    // MARK: - Keyword Embedding Generation (for storage only)
    
    /// Generate word embedding for a single word (for storage purposes)
    private func generateWordEmbedding(for word: String) -> [Double]? {
        guard let embedding = nlEmbedding else {
            return nil
        }
        
        let processedWord = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !processedWord.isEmpty else {
            return nil
        }
        
        // Get word embedding
        guard let vector = embedding.vector(for: processedWord) else {
            return nil
        }
        
        // Normalize to unit length for consistent similarity calculations
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else {
            return vector
        }
        
        return vector.map { $0 / magnitude }
    }
    
    /// Generate embeddings for multiple keywords (for storage)
    private func generateKeywordEmbeddings(for keywords: [String]) -> [[Double]]? {
        let embeddings = keywords.compactMap { generateWordEmbedding(for: $0) }
        return embeddings.isEmpty ? nil : embeddings
    }
}

// MARK: - Convenience Extensions

extension DatabaseService {
    var inputFolder: String {
        return getSettings().inputFolder
    }
    
    var outputFolder: String {
        return getSettings().outputFolder
    }

    var isFileMonitoringActive: Bool {
        return getSettings().isFileMonitoringActive
    }
    
    func setInputFolder(_ path: String) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: path, outputFolder: currentSettings.outputFolder, isFileMonitoringActive: currentSettings.isFileMonitoringActive)
    }
    
    func setOutputFolder(_ path: String) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: currentSettings.inputFolder, outputFolder: path, isFileMonitoringActive: currentSettings.isFileMonitoringActive)
    }

    func setIsFileMonitoringActive(_ isActive: Bool) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: currentSettings.inputFolder, outputFolder: currentSettings.outputFolder, isFileMonitoringActive: isActive)
    }
} 
