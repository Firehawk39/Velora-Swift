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
    
    enum SyncType {
        case none
        case metadata
        case media
        case full
        case audit
    }
    
    private var client: NavidromeClient?
    private var playback: PlaybackManager?
    
    func configure(client: NavidromeClient, playback: PlaybackManager) {
        self.client = client
        self.playback = playback
    }
    
    // MARK: - Deep Audit
    
    func startDeepAudit() {
        guard !isAuditing else { return }
        
        isAuditing = true
        isSyncing = true
        auditProgress = 0.0
        auditStatus = "Initializing Deep Audit..."
        
        Task {
            let fileManager = FileManager.default
            let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            
            let metadataDir = docs.appendingPathComponent("Metadata")
            let backdropDir = docs.appendingPathComponent("Backdrops")
            let portraitDir = docs.appendingPathComponent("ArtistPortraits")
            
            var filesToAudit: [URL] = []
            
            let dirs = [docs, metadataDir, backdropDir, portraitDir]
            for dir in dirs {
                if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    let filtered = contents.filter { !$0.hasDirectoryPath && !($0.lastPathComponent == ".DS_Store") }
                    filesToAudit.append(contentsOf: filtered)
                }
            }
            
            let totalFiles = filesToAudit.count
            if totalFiles == 0 {
                isAuditing = false
                if !isMetadataSyncing && !isMediaSyncing { isSyncing = false }
                auditStatus = "Audit Complete: No files found."
                return
            }
            
            var processed = 0
            for fileUrl in filesToAudit {
                if !isAuditing { break }
                
                let fileName = fileUrl.lastPathComponent
                auditStatus = "Auditing: \(fileName)"
                
                // Integrity check logic
                if fileName.hasPrefix("artist_") || fileName.hasPrefix("album_") {
                    _ = IntegrityManager.shared.isMetadataValid(at: fileUrl)
                } else if fileName.hasSuffix(".jpg") || fileName.hasSuffix(".png") {
                    _ = IntegrityManager.shared.isImageValid(at: fileUrl)
                } else if fileName.hasSuffix(".mp3") || fileName.hasSuffix(".flac") || fileName.hasSuffix(".m4a") {
                    let trackId = fileUrl.deletingPathExtension().lastPathComponent
                    _ = IntegrityManager.shared.isTrackValid(id: trackId)
                }
                
                processed += 1
                auditProgress = Double(processed) / Double(totalFiles)
                
                if processed % 50 == 0 { await Task.yield() }
            }
            
            isAuditing = false
            if !isMetadataSyncing && !isMediaSyncing { isSyncing = false }
            auditStatus = "Audit Finished."
            self.playback?.refreshDownloadedTracks()
        }
    }
    
    // MARK: - Metadata Sync
    
    func startMetadataSync() {
        guard let client = client, !isMetadataSyncing else { return }
        
        isMetadataSyncing = true
        isSyncing = true
        metadataProgress = 0.0
        metadataStatus = "Fetching library list..."
        
        Task {
            // Load data if needed
            if client.artists.isEmpty { _ = await client.fetchArtists() }
            if client.albums.isEmpty { await client.fetchAlbums() }
            
            let artists = client.artists
            let albums = client.albums
            let totalTasks = Double(artists.count + albums.count)
            var tasksCompleted = 0.0
            
            // Artist Phase
            for artist in artists {
                if !isMetadataSyncing { break }
                
                let metadataUrl = MusicBrainzManager.shared.getMetadataUrl(for: artist.name)
                let backdropUrl = FanartManager.shared.getBackdropUrl(for: artist.name)
                let portraitUrl = FanartManager.shared.getPortraitUrl(for: artist.name)

                let hasValid = IntegrityManager.shared.isMetadataValid(at: metadataUrl) &&
                               IntegrityManager.shared.isImageValid(at: backdropUrl) &&
                               IntegrityManager.shared.isImageValid(at: portraitUrl)
                
                if !hasValid {
                    metadataStatus = "Syncing Info: \(artist.name)"
                    FanartManager.shared.downloadBackdropSilently(for: artist.name)
                    FanartManager.shared.fetchArtistPortrait(for: artist.name) { _ in }
                    await MusicBrainzManager.shared.downloadMetadataSilently(for: artist.name)
                }
                
                tasksCompleted += 1
                metadataProgress = tasksCompleted / totalTasks
                
                // ETA Update
                let remaining = totalTasks - tasksCompleted
                let remainingSec = Int(remaining * (hasValid ? 0.01 : 1.1))
                metadataEtaString = remainingSec > 60 ? "\(remainingSec/60)m remaining" : "\(remainingSec)s remaining"
            }
            
            // Album Phase
            for album in albums {
                if !isMetadataSyncing { break }
                let artistName = album.artist ?? "Unknown Artist"
                if !MusicBrainzManager.shared.hasAlbumMetadata(albumName: album.name, artistName: artistName) {
                    metadataStatus = "Syncing Info: \(album.name)"
                    await MusicBrainzManager.shared.downloadAlbumMetadataSilently(albumName: album.name, artistName: artistName)
                }
                tasksCompleted += 1
                metadataProgress = tasksCompleted / totalTasks
            }
            
            isMetadataSyncing = false
            if !isMediaSyncing && !isAuditing { isSyncing = false }
            metadataStatus = "Metadata Sync Complete"
        }
    }
    
    // MARK: - Media Sync
    
    func startMediaSync() {
        guard let client = client, !isMediaSyncing else { return }
        
        isMediaSyncing = true
        isSyncing = true
        mediaProgress = 0.0
        mediaStatus = "Analyzing library..."
        
        Task {
            if client.allSongs.isEmpty {
                await client.syncLibrary()
            }
            
            let tracks = client.allSongs
            let tracksToDownload = tracks.filter { track in
                if let persistent = LocalMetadataStore.shared.fetchTrack(id: track.id), persistent.isDownloaded {
                    return false
                }
                return !(playback?.checkFileSystemForTrack(track.id) ?? false)
            }
            let totalTracks = Double(tracks.count)
            let totalToDownload = tracksToDownload.count
            let alreadyDownloaded = Int(totalTracks) - totalToDownload
            
            if totalToDownload == 0 {
                isMediaSyncing = false
                if !isMetadataSyncing && !isAuditing { isSyncing = false }
                mediaStatus = "All tracks already offline."
                return
            }
            
            for track in tracksToDownload {
                if !isMediaSyncing { break }
                playback?.downloadTrack(track)
                await Task.yield()
            }
            
            let startTime = Date()
            while isMediaSyncing {
                let downloaded = tracksToDownload.filter { playback?.isDownloaded($0.id) ?? false }.count
                let failed = tracksToDownload.filter { playback?.failedDownloadIds.contains($0.id) ?? false }.count
                let completed = downloaded + failed
                
                mediaProgress = Double(alreadyDownloaded + completed) / totalTracks
                mediaStatus = "Downloading: \(downloaded)/\(totalToDownload) (\(failed) errors)"
                
                // ETA
                if completed > 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let remaining = Double(totalToDownload - completed) / (Double(completed) / elapsed)
                    mediaEtaString = remaining > 60 ? "\(Int(remaining/60))m remaining" : "\(Int(remaining))s remaining"
                }
                
                if completed >= totalToDownload { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
            isMediaSyncing = false
            if !isMetadataSyncing && !isAuditing { isSyncing = false }
            mediaStatus = "Media Sync Complete"
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
    
    func stopSync() {
        stopMetadataSync()
        stopMediaSync()
        isAuditing = false
        isSyncing = false
    }
}
