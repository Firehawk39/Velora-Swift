import SwiftUI
import Foundation

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    @Published var isSyncing: Bool = false
    @Published var syncProgress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var syncType: SyncType = .none
    @Published var etaString: String = ""
    
    enum SyncType {
        case none
        case metadata
        case media
        case full
    }
    
    private var client: NavidromeClient?
    private var playback: PlaybackManager?
    
    func configure(client: NavidromeClient, playback: PlaybackManager) {
        self.client = client
        self.playback = playback
    }
    
    /// Syncs Artist/Album info and images, but NO media files
    func startMetadataSync() {
        guard let client = client, !isSyncing else { return }
        
        isSyncing = true
        syncType = .metadata
        syncProgress = 0.0
        
        Task {
            // 1. Ensure artists are loaded
            if client.artists.isEmpty {
                currentStatus = "Fetching artist list..."
                client.fetchArtists()
                for _ in 0..<30 {
                    if !client.artists.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            
            // 2. Ensure albums are loaded
            if client.albums.isEmpty {
                currentStatus = "Fetching album list..."
                client.fetchAlbums()
                for _ in 0..<30 {
                    if !client.albums.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            
            let artists = client.artists
            let albums = client.albums
            let songs = client.allSongs
            
            if artists.isEmpty && albums.isEmpty && songs.isEmpty {
                finalizeSync("No items found.")
                return
            }
            
            let totalTasks = Double(artists.count + albums.count + songs.count)
            var tasksCompleted = 0.0
            var skippedCount = 0
            
            // Phase 1: Artist Metadata & Images
            for artist in artists {
                if !isSyncing { break }
                
                let mb = MusicBrainzManager.shared
                let fa = FanartManager.shared
                
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let localPortraitUrl = docs.appendingPathComponent("CoverArt/\(artist.id).jpg")
                let hasLocalPortrait = FileManager.default.fileExists(atPath: localPortraitUrl.path)
                
                let hasAll = mb.hasArtistMetadata(for: artist.name) && 
                             fa.hasBackdrop(for: artist.name) && 
                             hasLocalPortrait
                
                if hasAll {
                    skippedCount += 1
                } else {
                    currentStatus = "Syncing: \(artist.name)"
                    FanartManager.shared.downloadBackdropSilently(for: artist.name)
                    client.downloadCoverArt(id: artist.id)
                    await MusicBrainzManager.shared.downloadMetadataSilently(for: artist.name)
                    
                    // Only sleep if we actually hit the API
                    try? await Task.sleep(nanoseconds: 1_050_000_000)
                }
                
                tasksCompleted += 1
                let remaining = totalTasks - tasksCompleted
                let remainingSeconds = Int(remaining * (hasAll ? 0.01 : 1.1)) // Near instant for skipped items
                
                if remainingSeconds > 60 {
                    self.etaString = "\(remainingSeconds / 60)m remaining"
                } else {
                    self.etaString = "\(remainingSeconds)s remaining"
                }
                
                updateProgress(tasksCompleted / totalTasks)
            }
            
            // Phase 2: Album Metadata
            for album in albums {
                if !isSyncing { break }
                
                let artistName = album.artist ?? "Unknown Artist"
                if MusicBrainzManager.shared.hasAlbumMetadata(albumName: album.name, artistName: artistName) {
                    skippedCount += 1
                } else {
                    currentStatus = "Syncing: \(album.name)"
                    await MusicBrainzManager.shared.downloadAlbumMetadataSilently(
                        albumName: album.name, 
                        artistName: artistName
                    )
                    try? await Task.sleep(nanoseconds: 1_050_000_000)
                }
                
                tasksCompleted += 1
                updateProgress(tasksCompleted / totalTasks)
            }
            
            // Phase 3: Track Lyrics (Rate-Limit Protected Concurrent Batching)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let maxConcurrentLyricsRequests = 6
            
            // Filter out songs that already have local cached lyrics first so we skip them instantly
            let missingSongs = songs.filter { song in
                let cacheFile = docs.appendingPathComponent("Lyrics/\(song.id).txt")
                if FileManager.default.fileExists(atPath: cacheFile.path) {
                    skippedCount += 1
                    tasksCompleted += 1
                    updateProgress(tasksCompleted / totalTasks)
                    return false
                }
                return true
            }
            
            if !missingSongs.isEmpty {
                var startIndex = 0
                while startIndex < missingSongs.count && isSyncing {
                    let endIndex = min(startIndex + maxConcurrentLyricsRequests, missingSongs.count)
                    let batch = Array(missingSongs[startIndex..<endIndex])
                    
                    currentStatus = "Syncing Lyrics: \(startIndex)/\(missingSongs.count) songs"
                    
                    // Download this batch of 6 tracks in parallel
                    await withTaskGroup(of: Void.self) { group in
                        for song in batch {
                            group.addTask {
                                await withCheckedContinuation { continuation in
                                    client.fetchLyrics(trackId: song.id, artist: song.artist ?? "", title: song.title) { _ in
                                        continuation.resume()
                                    }
                                }
                            }
                        }
                    }
                    
                    // Update progress on the MainActor for the entire batch
                    tasksCompleted += Double(batch.count)
                    updateProgress(tasksCompleted / totalTasks)
                    
                    // Cooldown between batches to prevent spamming the LRCLIB server
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    
                    startIndex += maxConcurrentLyricsRequests
                }
            }
            
            finalizeSync("Sync Complete (\(skippedCount) items skipped)")
        }
    }
    
    /// Downloads all tracks in the library
    func startMediaSync() {
        AppLogger.shared.log("startMediaSync() triggered. isSyncing: \(isSyncing), client: \(client != nil ? "present" : "nil")", level: .info)
        guard let client = client, !isSyncing else { 
            AppLogger.shared.log("startMediaSync() aborted: guard failed.", level: .error)
            return 
        }
        
        isSyncing = true
        syncType = .media
        syncProgress = 0.0
        currentStatus = "Analyzing library..."
        
        Task {
            playback?.resetDownloadState()
            
            // 1. Ensure we actually have the songs list
            let tracks: [Track]
            if client.allSongs.isEmpty {
                currentStatus = "Fetching song list..."
                tracks = await withCheckedContinuation { continuation in
                    client.fetchAllSongs { songs in
                        continuation.resume(returning: songs)
                    }
                }
            } else {
                tracks = client.allSongs
            }
            if tracks.isEmpty {
                AppLogger.shared.log("Songs list still empty after polling. Aborting.", level: .error)
                finalizeSync("No tracks found in library.")
                return
            }
            
            AppLogger.shared.log("Total tracks in library: \(tracks.count). Checking which need download.", level: .debug)
            
            let tracksToDownload = tracks.filter { !(playback?.checkFileSystemForTrack($0.id) ?? false) }
            let totalTracks = Double(tracks.count)
            let totalToDownload = tracksToDownload.count
            let alreadyDownloadedCount = Int(totalTracks) - totalToDownload
            
            if totalToDownload == 0 {
                finalizeSync("All \(Int(totalTracks)) tracks already offline.")
                return
            }
            
            currentStatus = "Queueing \(totalToDownload) tracks..."
            AppLogger.shared.log("Queueing \(totalToDownload) tracks.", level: .info)
            for track in tracksToDownload {
                if !isSyncing { break }
                playback?.downloadTrack(track)
                // Small yield to keep UI responsive during mass queueing
                await Task.yield()
            }
            AppLogger.shared.log("Finished queueing. Starting monitor loop.", level: .debug)
            
            // Phase 2: Monitor progress with a timeout safety
            var lastDownloadedCount = -1
            var stallCounter = 0
            
            let startTime = Date()
            while isSyncing {
                let currentlyDownloaded = tracksToDownload.filter { playback?.isDownloaded($0.id) ?? false }.count
                let currentlyFailed = tracksToDownload.filter { playback?.failedDownloadIds.contains($0.id) ?? false }.count
                let totalCompleted = Double(alreadyDownloadedCount + currentlyDownloaded + currentlyFailed)
                
                if currentlyDownloaded + currentlyFailed == 0 {
                    AppLogger.shared.log("Sync loop heartbeat: 0/\(totalToDownload) processed. isSyncing: \(isSyncing)", level: .debug)
                }
                
                updateProgress(totalCompleted / totalTracks)
                currentStatus = "Downloading: \(currentlyDownloaded)/\(totalToDownload) (\(alreadyDownloadedCount) skipped, \(currentlyFailed) failed)"
                
                // ETA Calculation
                let processedInThisBatch = currentlyDownloaded + currentlyFailed
                if processedInThisBatch > 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let tracksPerSecond = Double(processedInThisBatch) / elapsed
                    let remainingTracks = Double(totalToDownload - processedInThisBatch)
                    let remainingSeconds = Int(remainingTracks / tracksPerSecond)
                    
                    if remainingSeconds > 3600 {
                        self.etaString = "\(remainingSeconds / 3600)h remaining"
                    } else if remainingSeconds > 60 {
                        self.etaString = "\(remainingSeconds / 60)m remaining"
                    } else {
                        self.etaString = "\(remainingSeconds)s remaining"
                    }
                } else {
                    self.etaString = "Calculating..."
                }

                if (currentlyDownloaded + currentlyFailed) >= totalToDownload {
                    break
                }
                
                if (currentlyDownloaded + currentlyFailed) == lastDownloadedCount {
                    stallCounter += 1
                    if stallCounter > 300 { // 5 minutes stall
                        finalizeSync("Sync Stalled. Check your connection.")
                        return
                    }
                } else {
                    stallCounter = 0
                    lastDownloadedCount = currentlyDownloaded + currentlyFailed
                }
                
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
            if isSyncing {
                let successCount = tracksToDownload.filter { playback?.isDownloaded($0.id) ?? false }.count
                let failCount = tracksToDownload.filter { playback?.failedDownloadIds.contains($0.id) ?? false }.count
                
                if failCount > 0 {
                    finalizeSync("Sync Finished with \(failCount) errors. (\(successCount) saved)")
                } else {
                    finalizeSync("Media Sync Complete (\(alreadyDownloadedCount) skipped, \(successCount) downloaded)")
                }
            }
        }
    }
    
    func stopSync() {
        isSyncing = false
        syncType = .none
    }
    
    private func updateProgress(_ value: Double) {
        self.syncProgress = value
    }
    
    private func finalizeSync(_ status: String) {
        self.isSyncing = false
        self.syncType = .none
        self.currentStatus = status
        self.syncProgress = 1.0
        self.etaString = ""
        
        // Ensure UI is updated with new offline tracks
        self.playback?.refreshDownloadedTracks()
    }
}
