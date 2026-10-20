import Foundation

/// Centralized storage paths for the Velora app.
/// All data lives in Application Support/VeloraData/ — invisible to the user's Files app,
/// matching the storage strategy of Apple Music, Spotify, and Amazon Music.
enum VeloraStorage {

    static let root: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let veloraDir = appSupport.appendingPathComponent("VeloraData", isDirectory: true)
        try? FileManager.default.createDirectory(at: veloraDir, withIntermediateDirectories: true)
        // Exclude from iCloud backup — all content is re-downloadable
        var url = veloraDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return veloraDir
    }()

    /// Audio track files: {trackId}.{mp3|flac|m4a|...}
    static var tracks: URL { root.appendingPathComponent("Tracks", isDirectory: true) }

    /// Album/track cover art JPEGs
    static var coverArt: URL { root.appendingPathComponent("CoverArt", isDirectory: true) }

    /// Cached LRC/plain lyrics text files
    static var lyrics: URL { root.appendingPathComponent("Lyrics", isDirectory: true) }

    /// Artist background images from Fanart.tv
    static var backdrops: URL { root.appendingPathComponent("Backdrops", isDirectory: true) }

    /// Artist portrait/thumbnail images from Fanart.tv
    static var artistPortraits: URL { root.appendingPathComponent("ArtistPortraits", isDirectory: true) }

    /// MusicBrainz artist/album metadata JSON files
    static var metadata: URL { root.appendingPathComponent("Metadata", isDirectory: true) }

    /// Artist clearlogos (transparent PNG) from Fanart.tv hdmusiclogo
    static var clearLogos: URL { root.appendingPathComponent("ClearLogos", isDirectory: true) }

    /// Persistent diagnostic logs and rotating JSONL journals
    static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }

    /// Centralized SQLite database path
    static var database: URL { root.appendingPathComponent("velora.sqlite") }

    /// Ensure all subdirectories exist. Call once at app launch.
    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [tracks, coverArt, lyrics, backdrops, artistPortraits, metadata, clearLogos, logs] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        autoCleanupCorruptedAssets()
    }

    /// Automatically sweeps cache directories (Backdrops, ClearLogos, CoverArt, ArtistPortraits)
    /// and purges any 0-byte or corrupted assets (<= 100 bytes), self-healing storage.
    @discardableResult
    static func autoCleanupCorruptedAssets() -> Int {
        let fm = FileManager.default
        let targetDirs = [backdrops, clearLogos, coverArt, artistPortraits]
        var purgedCount = 0

        for dir in targetDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files {
                let ext = file.pathExtension.lowercased()
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                // Purge corrupted/zero-byte image files and empty sidecars
                if (ext == "jpg" || ext == "jpeg" || ext == "png" || ext == "webp") && size <= 100 {
                    try? fm.removeItem(at: file)
                    purgedCount += 1
                } else if ext == "mbid" && size == 0 {
                    try? fm.removeItem(at: file)
                    purgedCount += 1
                }
            }
        }
        if purgedCount > 0 {
            Task { @MainActor in
                AppLogger.shared.log("[Storage] 🧹 Auto-cleaned \(purgedCount) corrupted/0-byte cache assets.", level: .info)
            }
        }
        return purgedCount
    }

    /// One-time migration from Documents/ to Application Support/VeloraData/.
    /// Safe to call multiple times — skips if already migrated.
    static func migrateFromDocumentsIfNeeded() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let migrationFlag = root.appendingPathComponent(".migrated_v1")
        if fm.fileExists(atPath: migrationFlag.path) { return } // Already done

        ensureDirectories()

        // Migrate subdirectories
        let dirMap: [(String, URL)] = [
            ("CoverArt", coverArt),
            ("Lyrics", lyrics),
            ("Backdrops", backdrops),
            ("ArtistPortraits", artistPortraits),
            ("Metadata", metadata),
        ]
        for (oldName, newDir) in dirMap {
            let oldDir = docs.appendingPathComponent(oldName)
            if fm.fileExists(atPath: oldDir.path) {
                if let contents = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
                    for file in contents {
                        let dest = newDir.appendingPathComponent(file.lastPathComponent)
                        if !fm.fileExists(atPath: dest.path) {
                            try? fm.moveItem(at: file, to: dest)
                        }
                    }
                }
                try? fm.removeItem(at: oldDir) // Clean up empty old dir
            }
        }

        // Migrate loose audio files (Documents/{id}.mp3 → Tracks/{id}.mp3)
        let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "ogg", "wav", "aac", "opus", "alac"]
        if let contents = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for file in contents {
                if audioExtensions.contains(file.pathExtension.lowercased()) {
                    let dest = tracks.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: file, to: dest)
                    }
                }
            }
        }

        // Migrate name_to_mbid.json
        let oldMbid = docs.appendingPathComponent("name_to_mbid.json")
        let newMbid = root.appendingPathComponent("name_to_mbid.json")
        if fm.fileExists(atPath: oldMbid.path) && !fm.fileExists(atPath: newMbid.path) {
            try? fm.moveItem(at: oldMbid, to: newMbid)
        }

        // Migrate SQLite database files (velora.sqlite, -wal, -shm)
        let dbFiles = ["velora.sqlite", "velora.sqlite-wal", "velora.sqlite-shm"]
        for dbFile in dbFiles {
            let oldPath = docs.appendingPathComponent(dbFile)
            let newPath = root.appendingPathComponent(dbFile)
            if fm.fileExists(atPath: oldPath.path) && !fm.fileExists(atPath: newPath.path) {
                try? fm.moveItem(at: oldPath, to: newPath)
            }
        }

        // Mark migration complete
        fm.createFile(atPath: migrationFlag.path, contents: nil)
        Task { @MainActor in
            AppLogger.shared.log("[Storage] Migration from Documents/ to Application Support/VeloraData/ complete.")
        }
    }
}
