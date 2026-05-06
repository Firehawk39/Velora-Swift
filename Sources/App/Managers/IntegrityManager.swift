import Foundation
import UIKit
import Combine

/// Centralized manager for verifying file integrity across the application.
/// Ensures we don't use corrupted, partial, or empty files.
@MainActor
class IntegrityManager: ObservableObject {
    static let shared = IntegrityManager()
    private let fileManager = FileManager.default
    
    @Published var isAuditRunning: Bool = false
    @Published var auditProgress: Double = 0.0
    
    /// Checks if a music track is valid on disk
    func isTrackValid(id: String) -> Bool {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let extensions = ["mp3", "flac", "m4a", "wav"]
        
        for ext in extensions {
            let url = docs.appendingPathComponent("\(id).\(ext)")
            if fileManager.fileExists(atPath: url.path) {
                return isFileContentValid(at: url)
            }
        }
        return false
    }
    
    /// Performs a high-speed parallel audit of multiple tracks
    func performBulkAudit(ids: [String]) async -> Int {
        isAuditRunning = true
        auditProgress = 0.0
        var corruptedCount = 0
        let total = Double(ids.count)
        
        AppLogger.shared.log("[Integrity] Starting bulk audit of \(ids.count) tracks using TaskGroup.", level: .info)
        
        await withTaskGroup(of: (String, Bool).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    let isValid = self.isTrackValid(id: id)
                    return (id, isValid)
                }
                
                // Update progress occasionally on main actor
                if index % 10 == 0 {
                    let currentProgress = Double(index) / total
                    await MainActor.run {
                        self.auditProgress = currentProgress
                    }
                }
            }
            
            for await (id, isValid) in group {
                if !isValid {
                    corruptedCount += 1
                    AppLogger.shared.log("[Integrity] Corrupted track identified and pruned: \(id)", level: .warning)
                }
            }
        }
        
        AppLogger.shared.log("[Integrity] Bulk audit complete. Pruned \(corruptedCount) files.", level: .info)
        isAuditRunning = false
        auditProgress = 1.0
        return corruptedCount
    }
    
    private func isFileContentValid(at url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return false }
        
        // Minimum size threshold (e.g., 500KB)
        if size < 500_000 {
            AppLogger.shared.log("[Integrity] Track at \(url.lastPathComponent) is too small (\(size) bytes). Deleting.", level: .warning)
            try? fileManager.removeItem(at: url)
            return false
        }
        
        // Magic Number Verification (First 16 bytes)
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fileHandle.close() }
        
        guard let header = try? fileHandle.read(upToCount: 16) else { return false }
        let hex = header.map { String(format: "%02X", $0) }.joined()
        
        // 1. MP3 (ID3v2 tag): 49 44 33
        if hex.hasPrefix("494433") { return true }
        
        // 2. FLAC: 66 4C 61 43 ("fLaC")
        if hex.hasPrefix("664C6143") { return true }
        
        // 3. WAV: 52 49 46 46 ("RIFF")
        if hex.hasPrefix("52494646") { return true }
        
        // 4. M4A/MP4: contains "66747970" (ftyp) usually starting at offset 4
        if hex.contains("66747970") { return true }
        
        // 5. MP3 (Raw frames): FF FB, FF F3, FF F2
        if hex.hasPrefix("FFFB") || hex.hasPrefix("FFF3") || hex.hasPrefix("FFF2") { return true }
        
        AppLogger.shared.log("[Integrity] Track at \(url.lastPathComponent) has invalid magic number: \(hex.prefix(12)). Deleting.", level: .warning)
        try? fileManager.removeItem(at: url)
        return false
    }
    
    /// Checks if an image (Backdrop/Portrait) is valid on disk
    func isImageValid(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        
        if let data = try? Data(contentsOf: url), let _ = UIImage(data: data) {
            return true
        } else {
            AppLogger.shared.log("[Integrity] Image at \(url.lastPathComponent) is corrupted. Deleting.", level: .warning)
            try? fileManager.removeItem(at: url)
            return false
        }
    }
    
    /// Checks if a metadata JSON file is valid
    func isMetadataValid(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        
        if let data = try? Data(contentsOf: url),
           let _ = try? JSONSerialization.jsonObject(with: data) {
            return true
        } else {
            AppLogger.shared.log("[Integrity] Metadata at \(url.lastPathComponent) is invalid. Deleting.", level: .warning)
            try? fileManager.removeItem(at: url)
            return false
        }
    }
}
