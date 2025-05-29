import Foundation
import SwiftData

@Model
class AppSettings {
    var inputFolderPath: String
    var outputFolderPath: String
    var lastModified: Date
    
    init(inputFolderPath: String, outputFolderPath: String) {
        self.inputFolderPath = inputFolderPath
        self.outputFolderPath = outputFolderPath
        self.lastModified = Date()
    }
}

@Model
class OrganizationRuleEntity {
    var id: UUID
    var name: String
    var ruleDescription: String
    var destinationFolder: String
    var textEmbedding: Data?
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool
    
    init(id: UUID, name: String, ruleDescription: String, destinationFolder: String) {
        self.id = id
        self.name = name
        self.ruleDescription = ruleDescription
        self.destinationFolder = destinationFolder
        self.textEmbedding = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isActive = true
    }
}

// MARK: - Organization Rule Model

struct OrganizationRule: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var destinationFolder: String
    var isActive: Bool
    let createdAt: Date
    var updatedAt: Date
    
    init(name: String, description: String, destinationFolder: String) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.destinationFolder = destinationFolder
        self.isActive = true
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    init(id: UUID, name: String, description: String, destinationFolder: String) {
        self.id = id
        self.name = name
        self.description = description
        self.destinationFolder = destinationFolder
        self.isActive = true
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    init(from entity: OrganizationRuleEntity) {
        self.id = entity.id
        self.name = entity.name
        self.description = entity.ruleDescription
        self.destinationFolder = entity.destinationFolder
        self.isActive = entity.isActive
        self.createdAt = entity.createdAt
        self.updatedAt = entity.updatedAt
    }
} 