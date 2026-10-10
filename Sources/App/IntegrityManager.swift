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

    func getIndex() -> DownloadIndex {
        return self.index
    }

    func restoreIndex(_ newIndex: DownloadIndex) {
        self.index = newIndex
        self.downloadedIds = Set(newIndex.tracks.keys)
        saveIndex()
    }

    // MARK: - Track Management

    func clearAll() {
        index.tracks.removeAll()
        downloadedIds.removeAll()
        saveIndex()
    }

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

    // MARK: - Library Offline Audit

    struct LibraryAuditStats {
        let totalLibraryTracks: Int
        let offlineTracks: Int
        let cachedCoverArt: Int
        let cachedPortraits: Int
        let unlistedPortraits: Int
        let cachedBackdrops: Int
        let unlistedBackdrops: Int
        let cachedLogos: Int
        let unlistedLogos: Int
        let cachedLyrics: Int
        let instrumentalLyrics: Int
        let totalStorageMB: String
        let availableStorageGB: String

        var isOfflineReady: Bool {
            totalLibraryTracks > 0 && offlineTracks >= totalLibraryTracks
        }
    }

    func performLibraryAudit(totalTracks: Int) async -> LibraryAuditStats {
        let fm = FileManager.default
        let storage = getStorageInfo()
        let offlineTracksCount = downloadedIds.count

        // Count Cover Art
        let coverCount = (try? fm.contentsOfDirectory(at: VeloraStorage.coverArt, includingPropertiesForKeys: [.fileSizeKey]))?.filter {
            let size = (try? fm.attributesOfItem(atPath: $0.path)[.size]) as? Int64 ?? 0
            return size > 100
        }.count ?? 0

        // Count Portraits
        var portraitCount = 0
        var unlistedPortraitsCount = 0
        if let portraitFiles = try? fm.contentsOfDirectory(at: VeloraStorage.artistPortraits, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in portraitFiles {
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                if size > 100 { portraitCount += 1 }
                else { unlistedPortraitsCount += 1 }
            }
        }

        // Count Backdrops
        var backdropCount = 0
        var unlistedBackdropsCount = 0
        if let backdropFiles = try? fm.contentsOfDirectory(at: VeloraStorage.backdrops, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in backdropFiles {
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                if size > 100 { backdropCount += 1 }
                else { unlistedBackdropsCount += 1 }
            }
        }

        // Count Logos
        var logoCount = 0
        var unlistedLogosCount = 0
        if let logoFiles = try? fm.contentsOfDirectory(at: VeloraStorage.clearLogos, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in logoFiles {
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                if size > 100 { logoCount += 1 }
                else { unlistedLogosCount += 1 }
            }
        }

        // Count Lyrics
        var lyricsCount = 0
        var instrumentalCount = 0
        if let lyricFiles = try? fm.contentsOfDirectory(at: VeloraStorage.lyrics, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in lyricFiles {
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                if size == 9, let str = try? String(contentsOf: file, encoding: .utf8), str == "NO_LYRICS" {
                    instrumentalCount += 1
                } else if size > 0 {
                    lyricsCount += 1
                }
            }
        }

        // Merge with AssetRegistry records
        unlistedPortraitsCount = max(unlistedPortraitsCount, AssetRegistry.shared.unavailablePortraitsCount)
        unlistedBackdropsCount = max(unlistedBackdropsCount, AssetRegistry.shared.unavailableBackdropsCount)
        unlistedLogosCount = max(unlistedLogosCount, AssetRegistry.shared.unavailableLogosCount)
        instrumentalCount = max(instrumentalCount, AssetRegistry.shared.unavailableLyricsCount)

        return LibraryAuditStats(
            totalLibraryTracks: totalTracks,
            offlineTracks: offlineTracksCount,
            cachedCoverArt: coverCount,
            cachedPortraits: portraitCount,
            unlistedPortraits: unlistedPortraitsCount,
            cachedBackdrops: backdropCount,
            unlistedBackdrops: unlistedBackdropsCount,
            cachedLogos: logoCount,
            unlistedLogos: unlistedLogosCount,
            cachedLyrics: lyricsCount,
            instrumentalLyrics: instrumentalCount,
            totalStorageMB: storage.usedByAppMB,
            availableStorageGB: storage.availableGB
        )
    }
}
