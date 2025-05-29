import Foundation
import SwiftData
import NaturalLanguage
import Combine

/*
 * DatabaseService.swift
 * 
 * This service manages the Core Data stack and provides database operations
 * for the Smart File Organizer. It handles:
 * - App settings (input/output folders)
 * - Organization rules with vector embeddings
 * - Processed file cache with embeddings
 * - Vector similarity operations
 */

// MARK: - Database Errors

enum DatabaseError: Error {
    case contextSaveFailed(Error)
    case entityNotFound
    case embeddingGenerationFailed
    case invalidData
    case migrationFailed
    
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
        case .migrationFailed:
            return "Database migration failed"
        }
    }
}

// MARK: - Models

struct ProcessedFile {
    let filePath: String
    let fileName: String
    let fileType: String
    let extractedText: String?
    let fileSize: Int64
    let fileHash: String
    let processedAt: Date
    let lastModified: Date
    let matchedRuleId: UUID?
    
    init(fileURL: URL, extractedText: String?, fileSize: Int64, fileHash: String, matchedRuleId: UUID? = nil) {
        self.filePath = fileURL.path
        self.fileName = fileURL.lastPathComponent
        self.fileType = fileURL.pathExtension.lowercased()
        self.extractedText = extractedText
        self.fileSize = fileSize
        self.fileHash = fileHash
        self.processedAt = Date()
        self.lastModified = Date()
        self.matchedRuleId = matchedRuleId
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
            modelContainer = try ModelContainer(for: AppSettings.self, OrganizationRuleEntity.self)
            context = ModelContext(modelContainer)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
    
    // MARK: - Settings
    
    func getSettings() -> (inputFolder: String, outputFolder: String) {
        do {
            let descriptor = FetchDescriptor<AppSettings>()
            let settings = try context.fetch(descriptor).first
            
            if let settings = settings {
                return (settings.inputFolderPath, settings.outputFolderPath)
            } else {
                return createDefaultSettings()
            }
        } catch {
            print("Failed to fetch settings: \(error)")
            return createDefaultSettings()
        }
    }
    
    func updateSettings(inputFolder: String, outputFolder: String) {
        do {
            let descriptor = FetchDescriptor<AppSettings>()
            let settings = try context.fetch(descriptor).first
            
            if let existingSettings = settings {
                // Update existing settings
                existingSettings.inputFolderPath = inputFolder
                existingSettings.outputFolderPath = outputFolder
                existingSettings.lastModified = Date()
            } else {
                // Create new settings
                let newSettings = AppSettings(inputFolderPath: inputFolder, outputFolderPath: outputFolder)
                context.insert(newSettings)
            }
            
            try context.save()
        } catch {
            print("Failed to update settings: \(error)")
        }
    }
    
    private func createDefaultSettings() -> (String, String) {
        let defaultInputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Input").path
        let defaultOutputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Output").path
        
        updateSettings(inputFolder: defaultInputFolder, outputFolder: defaultOutputFolder)
        return (defaultInputFolder, defaultOutputFolder)
    }
    
    // MARK: - Organization Rules
    
    func getAllRules() -> [OrganizationRule] {
        do {
            let descriptor = FetchDescriptor<OrganizationRuleEntity>(sortBy: [SortDescriptor(\.createdAt)])
            let entities = try context.fetch(descriptor)
            return entities.map { OrganizationRule(from: $0) }
        } catch {
            print("Failed to fetch rules: \(error)")
            return []
        }
    }
    
    func saveRule(_ rule: OrganizationRule) {
        do {
            let descriptor = FetchDescriptor<OrganizationRuleEntity>(predicate: #Predicate { $0.id == rule.id })
            let existingEntity = try context.fetch(descriptor).first
            
            let entity: OrganizationRuleEntity
            if let existing = existingEntity {
                // Update existing entity
                entity = existing
            } else {
                // Create new entity
                entity = OrganizationRuleEntity(
                    id: rule.id,
                    name: rule.name,
                    ruleDescription: rule.description,
                    destinationFolder: rule.destinationFolder
                )
                context.insert(entity)
            }
            
            // Update properties
            entity.name = rule.name
            entity.ruleDescription = rule.description
            entity.destinationFolder = rule.destinationFolder
            entity.updatedAt = Date()
            
            // Generate and store embedding with proper security
            if let embedding = generateTextEmbedding(for: rule.description) {
                do {
                    let embeddingData = try NSKeyedArchiver.archivedData(
                        withRootObject: embedding, 
                        requiringSecureCoding: true
                    )
                    entity.textEmbedding = embeddingData
                } catch {
                    print("Failed to archive embedding: \(error)")
                    // Fallback: store as JSON
                    if let jsonData = try? JSONSerialization.data(withJSONObject: embedding) {
                        entity.textEmbedding = jsonData
                    }
                }
            }
            
            try context.save()
        } catch {
            print("Failed to save rule: \(error)")
        }
    }
    
    func deleteRule(withId id: UUID) {
        do {
            let descriptor = FetchDescriptor<OrganizationRuleEntity>(predicate: #Predicate { $0.id == id })
            if let entity = try context.fetch(descriptor).first {
                context.delete(entity)
                try context.save()
            }
        } catch {
            print("Failed to delete rule: \(error)")
        }
    }
    
    // MARK: - Vector Matching
    
    func findBestMatchingRule(for textEmbedding: [Double]) -> (rule: OrganizationRule, similarity: Double)? {
        let rules = getAllRules().filter { $0.isActive }
        var bestMatch: (rule: OrganizationRule, similarity: Double)?
        
        for rule in rules {
            if let ruleEmbedding = getRuleEmbedding(ruleId: rule.id) {
                let similarity = cosineSimilarity(textEmbedding, ruleEmbedding)
                
                if similarity >= 0.6 && (bestMatch == nil || similarity > bestMatch!.similarity) {
                    bestMatch = (rule, similarity)
                }
            }
        }
        
        return bestMatch
    }
    
    private func getRuleEmbedding(ruleId: UUID) -> [Double]? {
        do {
            let descriptor = FetchDescriptor<OrganizationRuleEntity>(predicate: #Predicate { $0.id == ruleId })
            if let entity = try context.fetch(descriptor).first,
               let embeddingData = entity.textEmbedding {
                
                // Try NSKeyedUnarchiver first (for existing data)
                do {
                    let allowedClasses = [NSArray.self, NSNumber.self]
                    if let embedding = try NSKeyedUnarchiver.unarchivedObject(
                        ofClasses: Set(_immutableCocoaSet: allowedClasses),
                        from: embeddingData
                    ) as? [Double] {
                        return embedding
                    }
                } catch {
                    // Fallback: try JSON deserialization
                    if let embedding = try? JSONSerialization.jsonObject(with: embeddingData) as? [Double] {
                        return embedding
                    }
                }
            }
        } catch {
            print("Failed to retrieve rule embedding: \(error)")
        }
        return nil
    }
    
    // MARK: - Embedding Generation
    
    private func generateTextEmbedding(for text: String) -> [Double]? {
        guard let embedding = nlEmbedding else { return nil }
        
        let processedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = processedText
        
        var wordVectors: [[Double]] = []
        
        tokenizer.enumerateTokens(in: processedText.startIndex..<processedText.endIndex) { tokenRange, _ in
            let token = String(processedText[tokenRange])
            
            guard token.count > 2 && !token.allSatisfy({ $0.isPunctuation }) else {
                return true
            }
            
            if let vector = embedding.vector(for: token) {
                wordVectors.append(vector)
            }
            
            return true
        }
        
        guard !wordVectors.isEmpty else { return nil }
        
        // Calculate mean vector
        let vectorSize = wordVectors[0].count
        var meanVector = Array(repeating: 0.0, count: vectorSize)
        
        for vector in wordVectors {
            for i in 0..<vectorSize {
                meanVector[i] += vector[i]
            }
        }
        
        let count = Double(wordVectors.count)
        let normalizedVector = meanVector.map { $0 / count }
        
        // Normalize to unit length
        let magnitude = sqrt(normalizedVector.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return normalizedVector }
        
        return normalizedVector.map { $0 / magnitude }
    }
    
    private func cosineSimilarity(_ vector1: [Double], _ vector2: [Double]) -> Double {
        guard vector1.count == vector2.count else { return 0 }
        
        let dotProduct = zip(vector1, vector2).map(*).reduce(0, +)
        let magnitude1 = sqrt(vector1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(vector2.map { $0 * $0 }.reduce(0, +))
        
        guard magnitude1 > 0 && magnitude2 > 0 else { return 0 }
        
        return dotProduct / (magnitude1 * magnitude2)
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
    
    func setInputFolder(_ path: String) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: path, outputFolder: currentSettings.outputFolder)
    }
    
    func setOutputFolder(_ path: String) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: currentSettings.inputFolder, outputFolder: path)
    }
} 
