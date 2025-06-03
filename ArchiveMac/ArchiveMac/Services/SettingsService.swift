import Foundation

/*
 * SettingsService.swift
 * 
 * Provides a simplified interface for managing app settings and organization rules.
 * Acts as a facade over DatabaseService for settings-related operations.
 */

class SettingsService {
    static let shared = SettingsService()
    
    private let database = DatabaseService.shared
    
    private init() {}
    
    // MARK: - Folder Settings
    
    /// Get the current input folder path
    func getInputFolder() -> String {
        return database.inputFolder
    }
    
    /// Set the input folder path
    func setInputFolder(_ path: String) {
        database.setInputFolder(path)
    }
    
    /// Get the current output folder path
    func getOutputFolder() -> String {
        return database.outputFolder
    }
    
    /// Set the output folder path
    func setOutputFolder(_ path: String) {
        database.setOutputFolder(path)
    }
    
    // MARK: - File Monitoring Settings
    
    /// Get the current file monitoring active status
    func getIsFileMonitoringActive() -> Bool {
        return database.isFileMonitoringActive
    }
    
    /// Set the file monitoring active status
    func setIsFileMonitoringActive(_ isActive: Bool) {
        database.setIsFileMonitoringActive(isActive)
    }
    
    // MARK: - Organization Rules
    
    /// Get all organization rules
    func getOrganizationRules() -> [OrganizationRule] {
        return database.getAllRules()
    }
    
    /// Save multiple organization rules
    func saveOrganizationRules(_ rules: [OrganizationRule]) {
        for rule in rules {
            database.saveRule(rule)
        }
    }
    
    /// Add or update a single organization rule
    func saveOrganizationRule(_ rule: OrganizationRule) {
        database.saveRule(rule)
    }
    
    /// Delete an organization rule by ID
    func deleteOrganizationRule(withId id: UUID) {
        database.deleteRule(withId: id)
    }
} 