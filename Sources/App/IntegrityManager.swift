import Foundation
import SwiftUI

/// IntegrityManager handles the local download index and disk space monitoring.
/// This replaces expensive disk scanning with a lightning-fast JSON manifest,
/// optimized for older hardware like the iPhone SE (1st Gen).
class IntegrityManager: ObservableObject {
    static let shared = IntegrityManager()
    
    private let manifestName = "downloads_manifest.json"
    private var manifestUrl: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent(manifestName)
    }
    
    struct DownloadIndex: Codable {
        var version: Int = 1
        var tracks: [String: TrackStatus] = [:]
    }
    
    struct TrackStatus: Codable {
        let id: String
        let fileName: String
        let fileSize: Int64
        let downloadDate: Date
    }
    
    @Published var downloadedIds: Set<String> = []
    private var index = DownloadIndex()
    
    private init() {
        loadIndex()
    }
    
    // MARK: - Manifest Persistence
    
    func loadIndex() {
        if let data = try? Data(contentsOf: manifestUrl),
           let decoded = try? JSONDecoder().decode(DownloadIndex.self, from: data) {
            self.index = decoded
            self.downloadedIds = Set(decoded.tracks.keys)
        } else {
            // First run or missing manifest: index will be built by PlaybackManager
            self.index = DownloadIndex()
        }
    }
    
    func saveIndex() {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: manifestUrl)
        }
    }
    
    // MARK: - Track Management
    
    func registerDownload(trackId: String, fileName: String, size: Int64) {
        let status = TrackStatus(
            id: trackId,
            fileName: fileName,
            fileSize: size,
            downloadDate: Date()
        )
        index.tracks[trackId] = status
        downloadedIds.insert(trackId)
        saveIndex()
    }
    
    func unregisterDownload(trackId: String) {
        index.tracks.removeValue(forKey: trackId)
        downloadedIds.remove(trackId)
        saveIndex()
    }
    
    /// Rebuilds the index from scratch by scanning the Documents directory.
    /// Used for backwards compatibility or recovery.
    func rebuildIndex(from fileURLs: [URL]) {
        index.tracks.removeAll()
        downloadedIds.removeAll()
        
        let audioExtensions = ["mp3", "flac", "m4a", "ogg", "wav", "aac", "opus", "alac"]
        
        for url in fileURLs {
            // Only process actual audio files
            if !audioExtensions.contains(url.pathExtension.lowercased()) {
                continue
            }
            
            let trackId = url.deletingPathExtension().lastPathComponent
            let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attr?[.size] as? Int64 ?? 0
            
            // Integrity Check: Ignore ghost files (0-byte)
            if size > 1024 {
                registerDownload(trackId: trackId, fileName: url.lastPathComponent, size: size)
            } else {
                // Potential corruption - delete it
                try? FileManager.default.removeItem(at: url)
            }
        }
        saveIndex()
    }
    
    // MARK: - Storage Monitoring
    
    struct StorageInfo {
        let total: Int64
        let available: Int64
        let usedByApp: Int64
        
        var availableGB: String { String(format: "%.1f GB", Double(available) / 1_000_000_000) }
        var usedByAppMB: String { String(format: "%.1f MB", Double(usedByApp) / 1_000_000) }
    }
    
    func getStorageInfo() -> StorageInfo {
        let fileManager = FileManager.default
        let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        
        var totalSpace: Int64 = 0
        var freeSpace: Int64 = 0
        var appSpace: Int64 = 0
        
        // System Space
        if let attrs = try? fileManager.attributesOfFileSystem(forPath: path) {
            totalSpace = attrs[.systemSize] as? Int64 ?? 0
            freeSpace = attrs[.systemFreeSize] as? Int64 ?? 0
        }
        
        // App Space (Documents folder)
        let docUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let contents = try? fileManager.contentsOfDirectory(at: docUrl, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in contents {
                let res = try? url.resourceValues(forKeys: [.fileSizeKey])
                appSpace += Int64(res?.fileSize ?? 0)
            }
        }
        
        return StorageInfo(total: totalSpace, available: freeSpace, usedByApp: appSpace)
    }
}
