import Foundation
import UIKit

/// Centralized manager for verifying file integrity across the application.
/// Ensures we don't use corrupted, partial, or empty files.
class IntegrityManager {
    static let shared = IntegrityManager()
    private let fileManager = FileManager.default
    
    /// Checks if a music track is valid on disk
    func isTrackValid(id: String) -> Bool {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        // We check for multiple possible extensions
        let extensions = ["mp3", "flac", "m4a", "wav"]
        
        for ext in extensions {
            let url = docs.appendingPathComponent("\(id).\(ext)")
            if fileManager.fileExists(atPath: url.path) {
                if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? UInt64 {
                    // A typical song is at least 500KB. 
                    // Anything smaller is almost certainly a failed/partial download.
                    if size > 500_000 {
                        return true
                    } else {
                        AppLogger.shared.log("[Integrity] Track \(id) is too small (\(size) bytes). Deleting.", level: .warning)
                        try? fileManager.removeItem(at: url)
                    }
                }
            }
        }
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
