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
    
    /// Ensure all subdirectories exist. Call once at app launch.
    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [tracks, coverArt, lyrics, backdrops, artistPortraits, metadata] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
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
        
        // Mark migration complete
        fm.createFile(atPath: migrationFlag.path, contents: nil)
        AppLogger.shared.log("[Storage] Migration from Documents/ to Application Support/VeloraData/ complete.")
    }
}
