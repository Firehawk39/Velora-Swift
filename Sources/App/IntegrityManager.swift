import Foundation
import SwiftUI

/// IntegrityManager handles the local download index and disk space monitoring.
/// This replaces expensive disk scanning with a lightning-fast JSON manifest,
/// optimized for older hardware like the iPhone SE (1st Gen).
@MainActor
final class IntegrityManager: ObservableObject {
    static let shared = IntegrityManager()

    private let manifestName = "downloads_manifest.json"
    private var manifestUrl: URL {
        return VeloraStorage.root.appendingPathComponent(manifestName)
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

    /// Returns the stored file name for a given track ID, or nil if not in the index.
    func getFileName(for trackId: String) -> String? {
        return index.tracks[trackId]?.fileName
    }

    /// Rebuilds the index from scratch by scanning the Documents directory.
    /// Used for backwards compatibility or recovery.
    func rebuildIndex(from fileURLs: [URL]) async {
        let (newTracks, newDownloadedIds) = await Task.detached(priority: .userInitiated) { () -> ([String: TrackStatus], Set<String>) in
            var tracks: [String: TrackStatus] = [:]
            var downloaded: Set<String> = []
            let audioExtensions = ["mp3", "flac", "m4a", "ogg", "wav", "aac", "opus", "alac"]
            let fileManager = FileManager.default

            for url in fileURLs {
                // Only process actual audio files
                if !audioExtensions.contains(url.pathExtension.lowercased()) {
                    continue
                }

                let trackId = url.deletingPathExtension().lastPathComponent
                let attr = try? fileManager.attributesOfItem(atPath: url.path)
                let size = attr?[.size] as? Int64 ?? 0

                // Integrity Check: Ignore ghost files (0-byte)
                if size > 1024 {
                    let status = TrackStatus(
                        id: trackId,
                        fileName: url.lastPathComponent,
                        fileSize: size,
                        downloadDate: Date()
                    )
                    tracks[trackId] = status
                    downloaded.insert(trackId)
                } else {
                    // Potential corruption - delete it
                    try? fileManager.removeItem(at: url)
                }
            }
            return (tracks, downloaded)
        }.value

        self.index.tracks = newTracks
        self.downloadedIds = newDownloadedIds
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
        let storagePath = VeloraStorage.root.path

        var totalSpace: Int64 = 0
        var freeSpace: Int64 = 0
        var appSpace: Int64 = 0

        // System Space
        if let attrs = try? fileManager.attributesOfFileSystem(forPath: storagePath) {
            totalSpace = attrs[.systemSize] as? Int64 ?? 0
            freeSpace = attrs[.systemFreeSize] as? Int64 ?? 0
        }

        // App Space (VeloraData folder — recursive)
        if let enumerator = fileManager.enumerator(at: VeloraStorage.root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                    let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                    appSpace += Int64(res?.fileSize ?? 0)
                }
            }
        }

        return StorageInfo(total: totalSpace, available: freeSpace, usedByApp: appSpace)
    }
}
