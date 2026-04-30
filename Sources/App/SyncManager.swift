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
            let artists = client.artists
            let albums = client.albums
            
            let totalTasks = Double(artists.count + albums.count)
            var tasksCompleted = 0.0
            var skippedCount = 0
            
            // Phase 1: Artist Metadata & Images
            for artist in artists {
                if !isSyncing { break }
                
                let mb = MusicBrainzManager.shared
                let fa = FanartManager.shared
                
                let hasAll = mb.hasArtistMetadata(for: artist.name) && 
                             fa.hasBackdrop(for: artist.name) && 
                             fa.hasPortrait(for: artist.name)
                
                if hasAll {
                    skippedCount += 1
                } else {
                    currentStatus = "Syncing: \(artist.name)"
                    FanartManager.shared.downloadBackdropSilently(for: artist.name)
                    FanartManager.shared.fetchArtistPortrait(for: artist.name) { _ in }
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
            
            finalizeSync("Sync Complete (\(skippedCount) items skipped)")
        }
    }
    
    /// Downloads all tracks in the library
    func startMediaSync() {
        guard let client = client, !isSyncing else { return }
        
        isSyncing = true
        syncType = .media
        syncProgress = 0.0
        currentStatus = "Analyzing library..."
        
        Task {
            // 1. Ensure we actually have the songs list
            if client.allSongs.isEmpty {
                currentStatus = "Fetching song list..."
                client.fetchAllSongs()
                // Wait for songs to populate (poll for up to 10s)
                for _ in 0..<20 {
                    if !client.allSongs.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            
            let tracks = client.allSongs
            if tracks.isEmpty {
                finalizeSync("No tracks found in library.")
                return
            }
            
            let tracksToDownload = tracks.filter { !(playback?.checkFileSystemForTrack($0.id) ?? false) }
            let totalTracks = Double(tracks.count)
            let totalToDownload = tracksToDownload.count
            let alreadyDownloadedCount = Int(totalTracks) - totalToDownload
            
            if totalToDownload == 0 {
                finalizeSync("All \(Int(totalTracks)) tracks already offline.")
                return
            }
            
            currentStatus = "Queueing \(totalToDownload) tracks..."
            for track in tracksToDownload {
                if !isSyncing { break }
                playback?.downloadTrack(track)
                // Small yield to keep UI responsive during mass queueing
                await Task.yield()
            }
            
            // Phase 2: Monitor progress with a timeout safety
            var lastDownloadedCount = -1
            var stallCounter = 0
            
            while isSyncing {
                let currentlyDownloaded = tracksToDownload.filter { playback?.isDownloaded($0.id) ?? false }.count
                let totalCompleted = Double(alreadyDownloadedCount + currentlyDownloaded)
                
                updateProgress(totalCompleted / totalTracks)
                currentStatus = "Downloading: \(currentlyDownloaded)/\(totalToDownload) (\(alreadyDownloadedCount) skipped)"
                
                if currentlyDownloaded >= totalToDownload {
                    break
                }
                
                if currentlyDownloaded == lastDownloadedCount {
                    stallCounter += 1
                } else {
                    stallCounter = 0
                    lastDownloadedCount = currentlyDownloaded
                }
                
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second interval
            }
            
            if isSyncing {
                finalizeSync("Media Sync Complete (\(alreadyDownloadedCount) skipped, \(totalToDownload) downloaded)")
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
