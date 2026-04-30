import SwiftUI
import Foundation

class SyncManager: ObservableObject {
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
            
            // Phase 1: Artist Metadata & Images
            for artist in artists {
                if !isSyncing { break }
                currentStatus = "Artist Info: \(artist.name)"
                
                FanartManager.shared.downloadBackdropSilently(for: artist.name)
                FanartManager.shared.fetchArtistPortrait(for: artist.name) { _ in }
                await MusicBrainzManager.shared.downloadMetadataSilently(for: artist.name)
                
                tasksCompleted += 1
                let remaining = totalTasks - tasksCompleted
                let remainingSeconds = Int(remaining * 1.1) // 1.1s per item including overhead
                
                DispatchQueue.main.async {
                    if remainingSeconds > 60 {
                        self.etaString = "\(remainingSeconds / 60)m remaining"
                    } else {
                        self.etaString = "\(remainingSeconds)s remaining"
                    }
                }
                
                updateProgress(tasksCompleted / totalTasks)
                try? await Task.sleep(nanoseconds: 1_050_000_000) // MB Rate Limit
            }
            
            // Phase 2: Album Metadata
            for album in albums {
                if !isSyncing { break }
                currentStatus = "Album Info: \(album.name)"
                
                await MusicBrainzManager.shared.downloadAlbumMetadataSilently(
                    albumName: album.name, 
                    artistName: album.artist ?? "Unknown Artist"
                )
                
                tasksCompleted += 1
                updateProgress(tasksCompleted / totalTasks)
                try? await Task.sleep(nanoseconds: 1_050_000_000)
            }
            
            finalizeSync("Metadata Updated")
        }
    }
    
    /// Downloads all tracks in the library
    func startMediaSync() {
        guard let client = client, !isSyncing else { return }
        
        isSyncing = true
        syncType = .media
        syncProgress = 0.0
        currentStatus = "Queueing tracks..."
        
        Task {
            let tracks = client.songs
            let total = Double(tracks.count)
            var current = 0.0
            
            for track in tracks {
                if !isSyncing { break }
                currentStatus = "Queueing \(Int(current + 1))/\(Int(total)): \(track.title)"
                playback?.downloadTrack(track)
                
                current += 1
                updateProgress(current / total)
                
                // Rapid-fire queueing is fine, but we yield to keep UI smooth
                await Task.yield()
            }
            
            finalizeSync("Media Queued")
        }
    }
    
    func stopSync() {
        isSyncing = false
        syncType = .none
    }
    
    private func updateProgress(_ value: Double) {
        DispatchQueue.main.async {
            self.syncProgress = value
        }
    }
    
    private func finalizeSync(_ status: String) {
        DispatchQueue.main.async {
            self.isSyncing = false
            self.syncType = .none
            self.currentStatus = status
            self.syncProgress = 1.0
            self.etaString = ""
        }
    }
}
