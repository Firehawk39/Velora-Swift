import SwiftUI
import Foundation
import UIKit

@MainActor
final class SyncManager: ObservableObject {
    nonisolated static let shared = SyncManager()
    
    nonisolated init() {}
    
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
    var lastErrorMessage: String? = nil
    private var mediaRetryCounts: [String: Int] = [:]
    private let maxRetries = 2 // 3 attempts total
    
    // Last Run Tracking
    @AppStorage("velora_last_audit_date") var lastAuditDate: Double = 0
    @AppStorage("velora_audit_checkpoint_index") var auditCheckpointIndex: Int = 0
    @AppStorage("velora_audit_is_resuming") var isAuditResuming: Bool = false
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
        isAuditing = true
        isSyncing = true
        auditProgress = 0.0
        auditStatus = "Initializing Deep Audit..."
        lastErrorMessage = nil
        
        do {
            let success = try await performDeepAudit()
            isAuditing = false
            if !isMetadataSyncing && !isMediaSyncing { isSyncing = false }
            if success {
                lastAuditDate = Date().timeIntervalSince1970
                NotificationManager.shared.sendNotification(title: "Audit Complete", body: "Your library integrity has been verified.")
            }
            return success
        } catch {
            isAuditing = false
            if !isMetadataSyncing && !isMediaSyncing { isSyncing = false }
            lastErrorMessage = "Audit failed: \(error.localizedDescription)"
            auditStatus = "Failed"
            NotificationManager.shared.sendNotification(title: "Audit Failed", body: error.localizedDescription)
            return false
        }
    }
    
    private func performDeepAudit() async throws -> Bool {
        let tracks = await LocalMetadataStore.shared.fetchAllTracks().map { (id: $0.id, isDownloaded: $0.isDownloaded) }
        let artists = await LocalMetadataStore.shared.fetchAllArtists().map { $0.name }
        let albums = await LocalMetadataStore.shared.fetchAllAlbums().map { (name: $0.name, artist: $0.artist ?? "Unknown Artist") }
        
        let totalItems = tracks.count + artists.count + albums.count + 4
        if totalItems == 0 {
            auditStatus = "Audit Complete: Database empty."
            return true
        }
        
        var processed = isAuditResuming ? auditCheckpointIndex : 0
        await AppLogger.shared.log("SyncManager: Starting audit at index \(processed)/\(totalItems) (Resuming: \(isAuditResuming))", level: .info)
        
        // 1. Audit Tracks (Parallelized)
        if processed < tracks.count {
            auditStatus = "Verifying Tracks..."
            let start = processed
            let tracksToProcess = Array(tracks[start...])
            
            await withTaskGroup(of: Void.self) { group in
                // Limit concurrency to 4 tasks to avoid disk/CPU thrashing on A9
                var index = 0
                for track in tracksToProcess {
                    if !isAuditing { break }
                    
                    group.addTask {
                        if track.isDownloaded {
                            let isValid = await IntegrityManager.shared.isTrackValid(id: track.id)
                            if !isValid {
                                await LocalMetadataStore.shared.updateDownloadStatus(for: track.id, isDownloaded: false, localPath: nil)
                            }
                        }
                    }
                    
                    index += 1
                    processed += 1
                    
                    // Throttled UI updates
                    if index % 25 == 0 {
                        let currentProgress = Double(processed) / Double(totalItems)
                        await MainActor.run { 
                            self.auditProgress = currentProgress 
                            self.auditCheckpointIndex = processed
                        }
                        await Task.yield()
                    }
                    
                    // Simple concurrency limiting: wait for some tasks to finish if we have too many
                    if index % 4 == 0 { await group.next() }
                }
            }
        }
        
        // 2. Audit Artists
        if isAuditing && processed < (tracks.count + artists.count) {
            auditStatus = "Verifying Artists..."
            let start = max(0, processed - tracks.count)
            let artistsToProcess = Array(artists[start...])
            
            for artistName in artistsToProcess {
                if !isAuditing { throw SyncError.userCancelled }
                
                let portraitUrl = await FanartManager.shared.getPortraitUrl(for: artistName)
                let metadataUrl = await MusicBrainzManager.shared.getMetadataUrl(for: artistName)
                
                _ = await IntegrityManager.shared.isImageValid(at: portraitUrl)
                _ = await IntegrityManager.shared.isMetadataValid(at: metadataUrl)
                
                processed += 1
                if processed % 10 == 0 {
                    let currentProgress = Double(processed) / Double(totalItems)
                    await MainActor.run { 
                        self.auditProgress = currentProgress
                        self.auditCheckpointIndex = processed
                    }
                    await Task.yield()
                }
            }
        }
        
        // 3. Audit Albums
        if isAuditing && processed < (tracks.count + artists.count + albums.count) {
            auditStatus = "Verifying Albums..."
            let start = max(0, processed - tracks.count - artists.count)
            let albumsToProcess = Array(albums[start...])
            
            for album in albumsToProcess {
                if !isAuditing { throw SyncError.userCancelled }
                
                let metadataUrl = await MusicBrainzManager.shared.getAlbumMetadataUrl(albumName: album.name, artistName: album.artist)
                
                _ = await IntegrityManager.shared.isMetadataValid(at: metadataUrl)
                
                processed += 1
                if processed % 10 == 0 {
                    let currentProgress = Double(processed) / Double(totalItems)
                    await MainActor.run { 
                        self.auditProgress = currentProgress
                        self.auditCheckpointIndex = processed
                    }
                    await Task.yield()
                }
            }
        }
        
        // 4. Cleanup Orphaned Files
        if isAuditing {
            auditStatus = "Cleaning up orphaned assets..."
            await MusicBrainzManager.shared.verifyCacheIntegrity()
            await cleanupOrphanedFiles(processed: &processed, totalItems: totalItems)
            
            auditStatus = "Audit Finished."
            await AppLogger.shared.log("SyncManager: Deep Audit complete. Processed \(processed) items.", level: .info)
            await self.playback?.refreshDownloadedTracks()
            
            // Reset checkpoints
            auditCheckpointIndex = 0
            isAuditResuming = false
        }
        
        return true
    }
    
    // MARK: - Metadata Sync
    
    @discardableResult
    func startMetadataSync() async -> Bool {
        guard let client = client else { return false }
        isMetadataSyncing = true
        isSyncing = true
        metadataProgress = 0.0
        metadataStatus = "Fetching library list..."
        lastErrorMessage = nil
        
        do {
            let success = try await performMetadataSync(client: client)
            isMetadataSyncing = false
            if !isMediaSyncing && !isAuditing { isSyncing = false }
            if success {
                lastMetadataSyncDate = Date().timeIntervalSince1970
                NotificationManager.shared.sendNotification(title: "Metadata Synced", body: "Artist and Album info updated.")
            }
            return success
        } catch {
            isMetadataSyncing = false
            if !isMediaSyncing && !isAuditing { isSyncing = false }
            lastErrorMessage = "Metadata sync failed: \(error.localizedDescription)"
            metadataStatus = "Failed"
            NotificationManager.shared.sendNotification(title: "Sync Failed", body: error.localizedDescription)
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
            
            let metadataUrl = await MusicBrainzManager.shared.getMetadataUrl(for: artist.name)
            let backdropUrl = await FanartManager.shared.getBackdropUrl(for: artist.name)
            let portraitUrl = await FanartManager.shared.getPortraitUrl(for: artist.name)

            let hasValid = await IntegrityManager.shared.isMetadataValid(at: metadataUrl) &&
                           await IntegrityManager.shared.isImageValid(at: backdropUrl) &&
                           await IntegrityManager.shared.isImageValid(at: portraitUrl)
            
            if !hasValid {
                metadataStatus = "Syncing Info: \(artist.name)"
                await FanartManager.shared.downloadBackdropSilently(for: artist.name)
                _ = await FanartManager.shared.fetchArtistPortrait(for: artist.name)
                await MusicBrainzManager.shared.downloadMetadataSilently(for: artist.name)
                await Task.yield()
            }
            
            tasksCompleted += 1
            metadataProgress = tasksCompleted / totalTasks
            
            // ETA Update
            let remaining = totalTasks - tasksCompleted
            let remainingSec = Int(remaining * (hasValid ? 0.01 : 1.1))
            metadataEtaString = remainingSec > 60 ? "\(remainingSec/60)m remaining" : "\(remainingSec)s remaining"
            if Int(tasksCompleted) % 10 == 0 { await Task.yield() }
        }
        
        // Album Phase
        for album in albums {
            if !isMetadataSyncing { throw SyncError.userCancelled }
            let artistName = album.artist ?? "Unknown Artist"
            if !await MusicBrainzManager.shared.hasAlbumMetadata(albumName: album.name, artistName: artistName) {
                metadataStatus = "Syncing Info: \(album.name)"
                await MusicBrainzManager.shared.downloadAlbumMetadataSilently(albumName: album.name, artistName: artistName)
                await Task.yield()
            }
            tasksCompleted += 1
            metadataProgress = tasksCompleted / totalTasks
        }
        
        metadataStatus = "Metadata Sync Complete"
        return true
    }
    
    // MARK: - Media Sync
    
    @discardableResult
    func startMediaSync() async -> Bool {
        guard let client = client, let playback = playback, !isMediaSyncing else { return false }
        
        isMediaSyncing = true
        isSyncing = true
        mediaProgress = 0.0
        mediaStatus = "Analyzing library..."
        lastErrorMessage = nil
        
        // Background Task Management
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "VeloraMediaSync") {
            Task { @MainActor in
                self.stopMediaSync()
            }
        }
        
        defer {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
        
        do {
            // Ensure library is synced
            if client.allSongs.isEmpty {
                await client.syncLibrary()
            }
            
            let tracks = client.allSongs
            var tracksToDownload: [Track] = []
            for track in tracks {
                let persistent = await LocalMetadataStore.shared.fetchTrack(id: track.id)
                let isDownloaded = persistent?.isDownloaded ?? false
                if !isDownloaded && !playback.checkFileSystemForTrack(track.id) {
                    tracksToDownload.append(track)
                }
            }
            
            let totalTracks = Double(tracks.count)
            let totalToDownload = tracksToDownload.count
            let alreadyDownloaded = Int(totalTracks) - totalToDownload
            
            if totalToDownload == 0 {
                isMediaSyncing = false
                if !isMetadataSyncing && !isAuditing { isSyncing = false }
                mediaStatus = "All tracks offline."
                lastMediaSyncDate = Date().timeIntervalSince1970
                return true
            }
            
            // Subscribe to events before starting downloads
            let stream = playback.downloadStream
            
            // Initial Queue
            for track in tracksToDownload {
                if !isMediaSyncing { return false }
                playback.downloadTrack(track)
                await Task.yield()
            }
            
            let startTime = Date()
            var completedCount = 0
            var failedCount = 0
            var finishedIds = Set<String>()
            
            mediaStatus = "Downloading: 0/\(totalToDownload)"
            
            for await event in stream {
                if !isMediaSyncing { break }
                
                switch event {
                case .success(let trackId):
                    if !finishedIds.contains(trackId) {
                        completedCount += 1
                        finishedIds.insert(trackId)
                    }
                case .failure(let trackId, let error):
                    let retryCount = mediaRetryCounts[trackId, default: 0]
                    if retryCount < maxRetries {
                        await AppLogger.shared.log("SyncManager: Retrying \(trackId) (\(retryCount + 1)/\(maxRetries))", level: .warning)
                        mediaRetryCounts[trackId] = retryCount + 1
                        playback.failedDownloadIds.remove(trackId)
                        if let track = tracksToDownload.first(where: { $0.id == trackId }) {
                            playback.downloadTrack(track)
                        }
                    } else if !finishedIds.contains(trackId) {
                        failedCount += 1
                        finishedIds.insert(trackId)
                        await AppLogger.shared.log("SyncManager: Final failure for \(trackId): \(error?.localizedDescription ?? "Unknown")", level: .error)
                    }
                }
                
                let totalFinished = completedCount + failedCount
                mediaProgress = Double(alreadyDownloaded + totalFinished) / totalTracks
                mediaStatus = "Downloading: \(completedCount)/\(totalToDownload) (\(failedCount) errors)"
                
                // Smoothed ETA Calculation
                let elapsed = Date().timeIntervalSince(startTime)
                if totalFinished > 0 {
                    let rate = Double(totalFinished) / elapsed
                    let remainingSeconds = Double(totalToDownload - totalFinished) / rate
                    if remainingSeconds > 60 {
                        mediaEtaString = "\(Int(remainingSeconds / 60))m remaining"
                    } else {
                        mediaEtaString = "\(Int(remainingSeconds))s remaining"
                    }
                }
                
                if totalFinished >= totalToDownload {
                    break
                }
            }
            
            isMediaSyncing = false
            if !isMetadataSyncing && !isAuditing { isSyncing = false }
            mediaStatus = completedCount == totalToDownload ? "Media Sync Complete" : "Sync Finished (\(failedCount) failed)"
            lastMediaSyncDate = Date().timeIntervalSince1970
            
            if failedCount == 0 {
                NotificationManager.shared.sendNotification(title: "Library Offline", body: "All tracks downloaded successfully.")
            } else {
                NotificationManager.shared.sendNotification(title: "Library Partial", body: "\(failedCount) tracks could not be downloaded.")
            }
            
            return true
        } catch {
            isMediaSyncing = false
            if !isMetadataSyncing && !isAuditing { isSyncing = false }
            lastErrorMessage = "Media sync failed: \(error.localizedDescription)"
            mediaStatus = "Failed"
            return false
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
                await AppLogger.shared.log("SyncManager: Auto-starting metadata sync...", level: .info)
                let success = await startMetadataSync()
                if !success && lastErrorMessage != nil {
                    await AppLogger.shared.log("SyncManager: Auto-metadata sync failed: \(lastErrorMessage!)", level: .warning)
                }
            }
            
            if needsAudit {
                await AppLogger.shared.log("SyncManager: Auto-starting deep audit...", level: .info)
                let success = await startDeepAudit()
                if !success && lastErrorMessage != nil {
                    await AppLogger.shared.log("SyncManager: Auto-audit failed: \(lastErrorMessage!)", level: .warning)
                }
            }
        } catch {
            await AppLogger.shared.log("SyncManager: Auto-maintenance encountered an error: \(error.localizedDescription)", level: .error)
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
            
            auditStatus = "Cleaning \(categoryName)..."
            
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
                    if FileHelper.supportedAudioExtensions.contains(ext) {
                        isOrphaned = !validNames.contains(fileName)
                    }
                } else {
                    // For images/metadata, we check the sanitized name or MBID
                    isOrphaned = !validNames.contains(fileName)
                }
                
                if isOrphaned {
                    await AppLogger.shared.log("SyncManager: Deleting orphaned file: \(file.lastPathComponent)", level: .info)
                    try? fileManager.removeItem(at: file)
                }
                
                fileIndex += 1
                // Periodically update progress and yield
                if fileIndex % 20 == 0 {
                    let subProgress = Double(fileIndex) / Double(max(1, fileCount))
                    // We use a weighted progress for the cleanup phase (each dir is 1 unit of totalItems)
                    let currentStepProgress = Double(processed) + subProgress
                    self.auditProgress = currentStepProgress / Double(totalItems)
                    await Task.yield()
                }
            }
            
            processed += 1
            self.auditProgress = Double(processed) / Double(totalItems)
        }
        
        // 1. Tracks (Document Root)
        let trackIds = await LocalMetadataStore.shared.fetchDownloadedTrackIds()
        await cleanupDir(url: docs, validNames: trackIds, isTrack: true, categoryName: "Tracks")
        
        // 2. Backdrops (Sanitized Artist Names)
        let rawArtistNames = await LocalMetadataStore.shared.fetchArtistNames()
        let sanitizedArtistNames = Set(rawArtistNames.map { FileHelper.sanitize($0) })
        await cleanupDir(url: backdropsDir, validNames: sanitizedArtistNames, categoryName: "Backdrops")
        
        // 3. Portraits (Sanitized Artist Names)
        await cleanupDir(url: portraitsDir, validNames: sanitizedArtistNames, categoryName: "Artist Portraits")
        
        // 4. Metadata (MBIDs or Artist/Album names)
        var validMeta = Set<String>()
        let mbids = await LocalMetadataStore.shared.fetchArtistMBIDs()
        for mbid in mbids {
            validMeta.insert(FileHelper.artistMetadataBaseName(mbid: mbid))
        }
        
        let albumInfos = await LocalMetadataStore.shared.fetchAlbumNamesAndArtists()
        for alb in albumInfos {
            validMeta.insert(FileHelper.albumMetadataBaseName(albumName: alb.name, artistName: alb.artist))
        }
        await cleanupDir(url: metadataDir, validNames: validMeta, categoryName: "Metadata Cache")
    }
}
