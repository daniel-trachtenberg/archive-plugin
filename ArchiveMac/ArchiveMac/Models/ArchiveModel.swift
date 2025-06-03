import Foundation
import SwiftData

// MARK: - App Settings Model

@Model
class AppSettings {
    var inputFolderPath: String
    var outputFolderPath: String
    var lastModified: Date
    var isFileMonitoringActive: Bool
    
    init(inputFolderPath: String, outputFolderPath: String, isFileMonitoringActive: Bool = true) {
        self.inputFolderPath = inputFolderPath
        self.outputFolderPath = outputFolderPath
        self.lastModified = Date()
        self.isFileMonitoringActive = isFileMonitoringActive
    }
}

// MARK: - Organization Rule Model

@Model
class OrganizationRule {
    var id: UUID
    var name: String
    var ruleDescription: String
    var destinationFolder: String
    var textEmbedding: Data?
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool
    
    init(name: String, ruleDescription: String, destinationFolder: String) {
        self.id = UUID()
        self.name = name
        self.ruleDescription = ruleDescription
        self.destinationFolder = destinationFolder
        self.textEmbedding = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isActive = true
    }
    
    /// Update rule properties and set updatedAt timestamp
    func update(name: String, ruleDescription: String, destinationFolder: String) {
        self.name = name
        self.ruleDescription = ruleDescription
        self.destinationFolder = destinationFolder
        self.updatedAt = Date()
    }
} 