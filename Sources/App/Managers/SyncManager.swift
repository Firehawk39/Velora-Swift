import SwiftUI
import Foundation

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    // Global and Specific Flags
    @Published var isSyncing: Bool = false
    @Published var isMetadataSyncing: Bool = false
    @Published var isMediaSyncing: Bool = false
    @Published var isAuditing: Bool = false
    
    // Progress Tracking
    @Published var syncProgress: Double = 0.0 // Global legacy
    @Published var metadataProgress: Double = 0.0
    @Published var mediaProgress: Double = 0.0
    @Published var auditProgress: Double = 0.0
    
    // Status Tracking
    @Published var currentStatus: String = "" // Global legacy
    @Published var metadataStatus: String = ""
    @Published var mediaStatus: String = ""
    @Published var auditStatus: String = ""
    
    // ETA Tracking
    @Published var syncType: SyncType = .none
    @Published var etaString: String = ""
    @Published var mediaEtaString: String = ""
    @Published var metadataEtaString: String = ""
    
    // Error & Retry Tracking
    @Published var lastErrorMessage: String? = nil
    private var mediaRetryCounts: [String: Int] = [:]
    private let maxRetries = 2 // 3 attempts total
    
    // Last Run Tracking
    @AppStorage("velora_last_audit_date") var lastAuditDate: Double = 0
    @AppStorage("velora_last_metadata_sync_date") var lastMetadataSyncDate: Double = 0
    @AppStorage("velora_last_media_sync_date") var lastMediaSyncDate: Double = 0
    
    enum SyncType {
        case none
        case metadata
        case media
        case full
        case audit
    }
    
    enum SyncError: LocalizedError {
        case metadataFailed(String)
        case mediaFailed(String)
        case auditFailed(String)
        case networkUnavailable
        case storageFull
        case userCancelled
        
        var errorDescription: String? {
            switch self {
            case .metadataFailed(let msg): return "Metadata Sync: \(msg)"
            case .mediaFailed(let msg): return "Media Sync: \(msg)"
            case .auditFailed(let msg): return "Integrity Audit: \(msg)"
            case .networkUnavailable: return "Network unavailable. Please check your connection."
            case .storageFull: return "Device storage is almost full."
            case .userCancelled: return "Operation cancelled."
            }
        }
    }
    
    private var client: NavidromeClient?
    private var playback: PlaybackManager?
    
    func configure(client: NavidromeClient, playback: PlaybackManager) {
        self.client = client
        self.playback = playback
    }
    
    // MARK: - Deep Audit
    
    @discardableResult
    func startDeepAudit() async -> Bool {
        await MainActor.run {
            isAuditing = true
            isSyncing = true
            auditProgress = 0.0
            auditStatus = "Initializing Deep Audit..."
            lastErrorMessage = nil
        }
        
        do {
            let success = await performDeepAudit()
            await MainActor.run {
                isAuditing = false
                if !isMetadataSyncing && !isMediaSyncing { isSyncing = false }
                if success {
                    lastAuditDate = Date().timeIntervalSince1970
                    NotificationManager.shared.sendNotification(title: "Audit Complete", body: "Your library integrity has been verified.")
                }
            }
            return success
        } catch {
            await MainActor.run {
                isAuditing = false
                if !isMetadataSyncing && !isMediaSyncing { isSyncing = false }
                lastErrorMessage = "Audit failed: \(error.localizedDescription)"
                auditStatus = "Failed"
                NotificationManager.shared.sendNotification(title: "Audit Failed", body: error.localizedDescription)
            }
            return false
        }
    }
    
    private func performDeepAudit() async throws -> Bool {
        let tracks = LocalMetadataStore.shared.fetchAllTracks()
        let artists = LocalMetadataStore.shared.fetchAllArtists()
        let albums = LocalMetadataStore.shared.fetchAllAlbums()
        
        // Step 4 is orphaned cleanup - we count the directories we scan
        let totalItems = tracks.count + artists.count + albums.count + 4 
        if totalItems == 0 {
            await MainActor.run { auditStatus = "Audit Complete: Database empty." }
            return true
        }
        
        var processed = 0
        
        // 1. Audit Tracks (Downloads)
        for track in tracks {
            if !isAuditing { throw SyncError.userCancelled }
            await MainActor.run { auditStatus = "Verifying: \(track.title)" }
            
            if track.isDownloaded {
                let isValid = IntegrityManager.shared.isTrackValid(id: track.id)
                if !isValid {
                    LocalMetadataStore.shared.updateDownloadStatus(for: track.id, isDownloaded: false, localPath: nil)
                }
            }
            
            processed += 1
            await MainActor.run { auditProgress = Double(processed) / Double(totalItems) }
            if processed % 50 == 0 { await Task.yield() }
        }
        
        // 2. Audit Artists (Portraits & Metadata)
        for artist in artists {
            if !isAuditing { throw SyncError.userCancelled }
            await MainActor.run { auditStatus = "Verifying: \(artist.name)" }
            
            let portraitUrl = FanartManager.shared.getPortraitUrl(for: artist.name)
            let metadataUrl = MusicBrainzManager.shared.getMetadataUrl(for: artist.name)
            
            _ = IntegrityManager.shared.isImageValid(at: portraitUrl)
            _ = IntegrityManager.shared.isMetadataValid(at: metadataUrl)
            
            processed += 1
            await MainActor.run { auditProgress = Double(processed) / Double(totalItems) }
            await Task.yield() // Yield more frequently for UI
        }
        
        // 3. Audit Albums (Metadata)
        for album in albums {
            if !isAuditing { throw SyncError.userCancelled }
            await MainActor.run { auditStatus = "Verifying: \(album.name)" }
            
            let artistName = album.artist ?? "Unknown Artist"
            let metadataUrl = MusicBrainzManager.shared.getAlbumMetadataUrl(albumName: album.name, artistName: artistName)
            
            _ = IntegrityManager.shared.isMetadataValid(at: metadataUrl)
            
            processed += 1
            await MainActor.run { auditProgress = Double(processed) / Double(totalItems) }
            await Task.yield()
        }
        
        // 4. Cleanup Orphaned Files
        await MainActor.run { auditStatus = "Cleaning up orphaned assets..." }
        MusicBrainzManager.shared.verifyCacheIntegrity()
        await cleanupOrphanedFiles(processed: &processed, totalItems: totalItems)
        
        await MainActor.run {
            auditStatus = "Audit Finished."
            AppLogger.shared.log("SyncManager: Deep Audit complete. Processed \(processed) items.", level: .info)
            self.playback?.refreshDownloadedTracks()
        }
        
        return true
    }
    
    // MARK: - Metadata Sync
    
    @discardableResult
    func startMetadataSync() async -> Bool {
        guard let client = client else { return false }
        await MainActor.run {
            isMetadataSyncing = true
            isSyncing = true
            metadataProgress = 0.0
            metadataStatus = "Fetching library list..."
            lastErrorMessage = nil
        }
        
        do {
            let success = await performMetadataSync(client: client)
            await MainActor.run {
                isMetadataSyncing = false
                if !isMediaSyncing && !isAuditing { isSyncing = false }
                if success {
                    lastMetadataSyncDate = Date().timeIntervalSince1970
                    NotificationManager.shared.sendNotification(title: "Metadata Synced", body: "Artist and Album info updated.")
                }
            }
            return success
        } catch {
            await MainActor.run {
                isMetadataSyncing = false
                if !isMediaSyncing && !isAuditing { isSyncing = false }
                lastErrorMessage = "Metadata sync failed: \(error.localizedDescription)"
                metadataStatus = "Failed"
                NotificationManager.shared.sendNotification(title: "Sync Failed", body: error.localizedDescription)
            }
            return false
        }
    }
    
    private func performMetadataSync(client: NavidromeClient) async throws -> Bool {
        // Load data if needed
        if client.artists.isEmpty { 
            let _ = await client.fetchArtists()
            if client.artists.isEmpty { throw SyncError.metadataFailed("Could not fetch artists from server.") }
        }
        if client.albums.isEmpty { 
            await client.fetchAlbums() 
            if client.albums.isEmpty { throw SyncError.metadataFailed("Could not fetch albums from server.") }
        }
        
        let artists = client.artists
        let albums = client.albums
        let totalTasks = Double(artists.count + albums.count)
        var tasksCompleted = 0.0
        
        // Artist Phase
        for artist in artists {
            if !isMetadataSyncing { throw SyncError.userCancelled }
            
            let metadataUrl = MusicBrainzManager.shared.getMetadataUrl(for: artist.name)
            let backdropUrl = FanartManager.shared.getBackdropUrl(for: artist.name)
            let portraitUrl = FanartManager.shared.getPortraitUrl(for: artist.name)

            let hasValid = IntegrityManager.shared.isMetadataValid(at: metadataUrl) &&
                           IntegrityManager.shared.isImageValid(at: backdropUrl) &&
                           IntegrityManager.shared.isImageValid(at: portraitUrl)
            
            if !hasValid {
                await MainActor.run { metadataStatus = "Syncing Info: \(artist.name)" }
                FanartManager.shared.downloadBackdropSilently(for: artist.name)
                _ = await FanartManager.shared.fetchArtistPortrait(for: artist.name)
                await MusicBrainzManager.shared.downloadMetadataSilently(for: artist.name)
                await Task.yield()
            }
            
            tasksCompleted += 1
            await MainActor.run {
                metadataProgress = tasksCompleted / totalTasks
                
                // ETA Update
                let remaining = totalTasks - tasksCompleted
                let remainingSec = Int(remaining * (hasValid ? 0.01 : 1.1))
                metadataEtaString = remainingSec > 60 ? "\(remainingSec/60)m remaining" : "\(remainingSec)s remaining"
            }
            if Int(tasksCompleted) % 10 == 0 { await Task.yield() }
        }
        
        // Album Phase
        for album in albums {
            if !isMetadataSyncing { throw SyncError.userCancelled }
            let artistName = album.artist ?? "Unknown Artist"
            if !MusicBrainzManager.shared.hasAlbumMetadata(albumName: album.name, artistName: artistName) {
                await MainActor.run { metadataStatus = "Syncing Info: \(album.name)" }
                await MusicBrainzManager.shared.downloadAlbumMetadataSilently(albumName: album.name, artistName: artistName)
                await Task.yield()
            }
            tasksCompleted += 1
            await MainActor.run {
                metadataProgress = tasksCompleted / totalTasks
            }
        }
        
        await MainActor.run { metadataStatus = "Metadata Sync Complete" }
        return true
    }
    
    // MARK: - Media Sync
    
    @discardableResult
    func startMediaSync() async -> Bool {
        guard let client = client, let playback = playback, !isMediaSyncing else { return false }
        
        await MainActor.run {
            isMediaSyncing = true
            isSyncing = true
            mediaProgress = 0.0
            mediaStatus = "Analyzing library..."
            lastErrorMessage = nil
        }
        
        do {
            // Ensure library is synced
            if client.allSongs.isEmpty {
                await client.syncLibrary()
            }
            
            let tracks = client.allSongs
            let tracksToDownload = tracks.filter { track in
                if let persistent = LocalMetadataStore.shared.fetchTrack(id: track.id), persistent.isDownloaded {
                    return false
                }
                return !playback.checkFileSystemForTrack(track.id)
            }
            
            let totalTracks = Double(tracks.count)
            let totalToDownload = tracksToDownload.count
            let alreadyDownloaded = Int(totalTracks) - totalToDownload
            
            if totalToDownload == 0 {
                await MainActor.run {
                    isMediaSyncing = false
                    if !isMetadataSyncing && !isAuditing { isSyncing = false }
                    mediaStatus = "All tracks offline."
                    lastMediaSyncDate = Date().timeIntervalSince1970
                }
                return true
            }
            
            // Initial Queue
            for track in tracksToDownload {
                if !isMediaSyncing { return false }
                playback.downloadTrack(track)
                await Task.yield()
            }
            
            let startTime = Date()
            var lastCompletedCount = -1
            var tracksPendingRetry = Set<String>()
            
            while isMediaSyncing {
                let downloadedCount = tracksToDownload.filter { playback.isDownloaded(id: $0.id) }.count
                let currentlyFailed = tracksToDownload.filter { playback.failedDownloadIds.contains($0.id) }
                
                // Retry Logic
                for failedTrack in currentlyFailed {
                    let retryCount = mediaRetryCounts[failedTrack.id, default: 0]
                    if retryCount < maxRetries {
                        AppLogger.shared.log("SyncManager: Retrying download for \(failedTrack.title) (\(retryCount + 1)/\(maxRetries))", level: .warning)
                        mediaRetryCounts[failedTrack.id] = retryCount + 1
                        playback.failedDownloadIds.remove(failedTrack.id) // Clear failure from manager
                        playback.downloadTrack(failedTrack)
                    } else {
                        tracksPendingRetry.insert(failedTrack.id)
                    }
                }
                
                let failedCount = tracksPendingRetry.count
                let completed = downloadedCount + failedCount
                
                if completed != lastCompletedCount {
                    lastCompletedCount = completed
                    await MainActor.run {
                        mediaProgress = Double(alreadyDownloaded + completed) / totalTracks
                        mediaStatus = "Downloading: \(downloadedCount)/\(totalToDownload) (\(failedCount) errors)"
                        
                        // ETA Calculation (Smoothed)
                        if completed > 0 {
                            let elapsed = Date().timeIntervalSince(startTime)
                            let rate = Double(completed) / elapsed
                            let remaining = Double(totalToDownload - completed) / rate
                            mediaEtaString = remaining > 60 ? "\(Int(remaining/60))m remaining" : "\(Int(remaining))s remaining"
                        }
                    }
                }
                
                if completed >= totalToDownload { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2s to allow batching
            }
            
            await MainActor.run {
                isMediaSyncing = false
                if !isMetadataSyncing && !isAuditing { isSyncing = false }
                mediaStatus = completed == downloadedCount ? "Media Sync Complete" : "Sync Finished (\(failedCount) failed)"
                lastMediaSyncDate = Date().timeIntervalSince1970
                
                if failedCount == 0 {
                    NotificationManager.shared.sendNotification(title: "Library Offline", body: "All tracks downloaded successfully.")
                } else {
                    NotificationManager.shared.sendNotification(title: "Library Partial", body: "\(failedCount) tracks could not be downloaded.")
                }
            }
            
            return true
        } catch {
            await MainActor.run {
                isMediaSyncing = false
                if !isMetadataSyncing && !isAuditing { isSyncing = false }
                lastErrorMessage = "Media sync failed: \(error.localizedDescription)"
                mediaStatus = "Failed"
            }
            return false
        }
    }
    }
    
    // MARK: - Scheduling & Maintenance
    
    var needsAudit: Bool {
        let oneWeek: Double = 7 * 24 * 60 * 60
        return Date().timeIntervalSince1970 - lastAuditDate > oneWeek
    }
    
    var needsMetadataSync: Bool {
        let oneDay: Double = 24 * 60 * 60
        return Date().timeIntervalSince1970 - lastMetadataSyncDate > oneDay
    }
    
    func performAutoMaintenance() async {
        guard !isSyncing else { return }
        
        do {
            if needsMetadataSync {
                AppLogger.shared.log("SyncManager: Auto-starting metadata sync...", level: .info)
                let success = await startMetadataSync()
                if !success && lastErrorMessage != nil {
                    AppLogger.shared.log("SyncManager: Auto-metadata sync failed: \(lastErrorMessage!)", level: .warning)
                }
            }
            
            if needsAudit {
                AppLogger.shared.log("SyncManager: Auto-starting deep audit...", level: .info)
                let success = await startDeepAudit()
                if !success && lastErrorMessage != nil {
                    AppLogger.shared.log("SyncManager: Auto-audit failed: \(lastErrorMessage!)", level: .warning)
                }
            }
        } catch {
            AppLogger.shared.log("SyncManager: Auto-maintenance encountered an error: \(error.localizedDescription)", level: .error)
        }
    }
    
    // MARK: - Controls
    
    func stopMetadataSync() {
        isMetadataSyncing = false
        metadataStatus = "Stopped"
        if !isMediaSyncing && !isAuditing { isSyncing = false }
    }
    
    func stopMediaSync() {
        isMediaSyncing = false
        mediaStatus = "Stopped"
        if !isMetadataSyncing && !isAuditing { isSyncing = false }
        playback?.stopAllDownloads()
    }
    
    func stopAudit() {
        isAuditing = false
        auditStatus = "Stopped"
        if !isMetadataSyncing && !isMediaSyncing { isSyncing = false }
    }
    
    func stopSync() {
        stopMetadataSync()
        stopMediaSync()
        stopAudit()
    }
    // MARK: - Orphaned Cleanup
    
    private func cleanupOrphanedFiles(processed: inout Int, totalItems: Int) async {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let backdropsDir = docs.appendingPathComponent("Backdrops")
        let portraitsDir = docs.appendingPathComponent("ArtistPortraits")
        let metadataDir = docs.appendingPathComponent("metadata")
        
        // Helper to scan a directory and delete files not in the provided set
        func cleanupDir(url: URL, validNames: Set<String>, isTrack: Bool = false, categoryName: String) async {
            guard let files = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
            
            await MainActor.run {
                auditStatus = "Cleaning \(categoryName)..."
            }
            
            let fileCount = files.count
            var fileIndex = 0
            
            for file in files {
                if !isAuditing { break }
                
                let fileName = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension.lowercased()
                
                // Skip directories and system files
                if file.hasDirectoryPath || fileName.starts(with: ".") { continue }
                
                var isOrphaned = false
                if isTrack {
                    // For tracks, we only care about audio extensions
                    if ["mp3", "flac", "m4a", "wav"].contains(ext) {
                        isOrphaned = !validNames.contains(fileName)
                    }
                } else {
                    // For images/metadata, we check the sanitized name or MBID
                    isOrphaned = !validNames.contains(fileName)
                }
                
                if isOrphaned {
                    AppLogger.shared.log("SyncManager: Deleting orphaned file: \(file.lastPathComponent)", level: .info)
                    try? fileManager.removeItem(at: file)
                }
                
                fileIndex += 1
                // Periodically update progress and yield
                if fileIndex % 20 == 0 {
                    await MainActor.run {
                        let subProgress = Double(fileIndex) / Double(max(1, fileCount))
                        // We use a weighted progress for the cleanup phase (each dir is 1 unit of totalItems)
                        let currentStepProgress = Double(processed) + subProgress
                        self.auditProgress = currentStepProgress / Double(totalItems)
                    }
                    await Task.yield()
                }
            }
            
            processed += 1
            await MainActor.run {
                self.auditProgress = Double(processed) / Double(totalItems)
            }
        }
        
        // 1. Tracks (Document Root)
        let trackIds = LocalMetadataStore.shared.fetchTrackIds()
        await cleanupDir(url: docs, validNames: trackIds, isTrack: true, categoryName: "Tracks")
        
        // 2. Backdrops (Sanitized Artist Names)
        let rawArtistNames = LocalMetadataStore.shared.fetchArtistNames()
        let sanitizedArtistNames = Set(rawArtistNames.map { sanitizeFileName($0) })
        await cleanupDir(url: backdropsDir, validNames: sanitizedArtistNames, categoryName: "Backdrops")
        
        // 3. Portraits (Sanitized Artist Names)
        await cleanupDir(url: portraitsDir, validNames: sanitizedArtistNames, categoryName: "Artist Portraits")
        
        // 4. Metadata (MBIDs or Artist/Album names)
        var validMeta = Set<String>()
        let mbids = LocalMetadataStore.shared.fetchArtistMBIDs()
        for mbid in mbids {
            validMeta.insert("artist_\(mbid)")
        }
        
        let albumInfos = LocalMetadataStore.shared.fetchAlbumNamesAndArtists()
        for alb in albumInfos {
            let safeAlb = alb.name.replacingOccurrences(of: "/", with: "_")
            let safeArt = alb.artist.replacingOccurrences(of: "/", with: "_")
            validMeta.insert("album_\(safeArt)_\(safeAlb)")
        }
        await cleanupDir(url: metadataDir, validNames: validMeta, categoryName: "Metadata Cache")
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }
}
