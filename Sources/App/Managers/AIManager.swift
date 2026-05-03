import Foundation
import SwiftUI

/// Velora AI Engine — Stub (Decommissioned)
/// Kept as a placeholder to prevent build errors. No active AI processing.
class AIManager: ObservableObject {
    static let shared = AIManager()
    
    @Published var isProcessing = false
    @Published var lastAIResponse: String? = nil
    @Published var auditResults: [AuditResult] = []
    @Published var auditStatus: String = ""
    @Published var fixProgress: Double = 0.0
    
    private init() {}
    
    @MainActor
    func runLibraryAudit(forceRefresh: Bool = false) async {
        // AI Engine decommissioned — no-op
    }
    
    @MainActor
    func fixLibraryIssues(stages: Set<IssueType>? = nil) async {
        // AI Engine decommissioned — no-op
    }
}

// MARK: - Models (kept for compile compatibility)

enum IssueType: Hashable {
    case missingGenre, missingYear, lowResArt, missingMetadata, missingBackdrop
}

struct AuditResult: Identifiable {
    let id = UUID()
    let type: IssueType
    let count: Int
    let description: String
}

struct EnrichedMetadata: Codable {
    let genre: String
    let mood: String
    let release_year: Int
    let style: String?
    let description: String?
}
