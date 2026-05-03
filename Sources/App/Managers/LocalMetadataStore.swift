import Foundation
import SwiftData

/// Persistent storage model for track metadata, including AI-enriched content.
@Model
final class PersistentTrack {
    @Attribute(.unique) var id: String
    var title: String
    var artist: String?
    var album: String?
    var duration: Int?
    var coverArt: String?
    var artistId: String?
    var albumId: String?
    var suffix: String?
    
    // AI-Enriched Metadata
    var aiGenrePrediction: String?
    var aiAtmosphere: String?
    var lastAuditDate: Date?
    var hasCustomBackdrop: Bool = false
    var localBackdropPath: String?
    
    // Persistence Layer Optimization (The Last 3%)
    var isDownloaded: Bool = false
    var localFilePath: String?
    
    // Analytics
    var playCount: Int = 0
    var lastPlayedAt: Date?
    var isStarred: Bool = false
    
    init(track: Track) {
        self.id = track.id
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
        self.duration = track.duration
        self.coverArt = track.coverArt
        self.artistId = track.artistId
        self.albumId = track.albumId
        self.suffix = track.suffix
        self.isStarred = track.isStarred
        self.playCount = track.playCount ?? 0
        
        // Initial check for file existence
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let extensions = ["flac", "mp3", "m4a", "wav"]
        for ext in extensions {
            let url = docs.appendingPathComponent("\(track.id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                self.isDownloaded = true
                self.localFilePath = url.path
                break
            }
        }
    }
}

/// Persistent storage model for artist metadata.
@Model
final class PersistentArtist {
    @Attribute(.unique) var id: String
    var name: String
    var coverArt: String?
    var musicBrainzId: String?
    var biography: String?
    var lastAuditDate: Date?
    
    init(artist: Artist) {
        self.id = artist.id
        self.name = artist.name
        self.coverArt = artist.coverArt
    }
}

/// Persistent storage model for album metadata.
@Model
final class PersistentAlbum {
    @Attribute(.unique) var id: String
    var name: String
    var artist: String?
    var artistId: String?
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var releaseYear: Int?
    
    init(album: Album) {
        self.id = album.id
        self.name = album.name
        self.artist = album.artist
        self.artistId = album.artistId
        self.songCount = album.songCount
        self.duration = album.duration
        self.coverArt = album.coverArt
    }
}

/// Centralized manager for SwiftData operations.
/// High-performance local cache for AI-enriched metadata.
@MainActor
class LocalMetadataStore {
    static let shared = LocalMetadataStore()
    
    private var container: ModelContainer?
    private var context: ModelContext?
    
    init() {
        do {
            let schema = Schema([
                PersistentTrack.self,
                PersistentArtist.self,
                PersistentAlbum.self
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.container = try ModelContainer(for: schema, configurations: [config])
            if let container = self.container {
                self.context = ModelContext(container)
                self.context?.autosaveEnabled = false // Manual batch saving for performance
            }
        } catch {
            print("Failed to initialize SwiftData: \(error)")
        }
    }
    
    // MARK: - Batch Operations
    
    func saveTracks(_ tracks: [Track]) {
        guard let context = context else { return }
        
        for track in tracks {
            let id = track.id
            let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.id == id })
            
            do {
                if let existing = try context.fetch(fetchDescriptor).first {
                    existing.title = track.title
                    existing.artist = track.artist
                    existing.album = track.album
                    existing.isStarred = track.isStarred
                    existing.playCount = track.playCount ?? 0
                    existing.coverArt = track.coverArt
                    
                    // Maintain persistence status
                    if existing.localFilePath == nil || !FileManager.default.fileExists(atPath: existing.localFilePath!) {
                        existing.isDownloaded = false
                        existing.localFilePath = nil
                    }
                } else {
                    let newTrack = PersistentTrack(track: track)
                    context.insert(newTrack)
                }
            } catch {
                continue
            }
        }
        
        try? context.save()
    }
    
    func saveArtists(_ artists: [Artist]) {
        guard let context = context else { return }
        
        for artist in artists {
            let id = artist.id
            let fetchDescriptor = FetchDescriptor<PersistentArtist>(predicate: #Predicate { $0.id == id })
            
            do {
                if let existing = try context.fetch(fetchDescriptor).first {
                    existing.name = artist.name
                    existing.coverArt = artist.coverArt
                } else {
                    let newArtist = PersistentArtist(artist: artist)
                    context.insert(newArtist)
                }
            } catch {
                continue
            }
        }
        
        try? context.save()
    }
    
    func saveAlbums(_ albums: [Album]) {
        guard let context = context else { return }
        
        for album in albums {
            let id = album.id
            let fetchDescriptor = FetchDescriptor<PersistentAlbum>(predicate: #Predicate { $0.id == id })
            
            do {
                if let existing = try context.fetch(fetchDescriptor).first {
                    existing.name = album.name
                    existing.artist = album.artist
                    existing.coverArt = album.coverArt
                } else {
                    let newAlbum = PersistentAlbum(album: album)
                    context.insert(newAlbum)
                }
            } catch {
                continue
            }
        }
        
        try? context.save()
    }
    
    // MARK: - Single Operations
    
    func saveTrack(_ track: Track) {
        saveTracks([track])
    }
    
    func updateAIMetadata(for trackId: String, genre: String?, atmosphere: String?) {
        guard let context = context else { return }
        
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.id == trackId })
        
        do {
            if let persistent = try context.fetch(fetchDescriptor).first {
                persistent.aiGenrePrediction = genre
                persistent.aiAtmosphere = atmosphere
                persistent.lastAuditDate = Date()
                try context.save()
            }
        } catch {
            print("Error updating AI metadata: \(error)")
        }
    }
    
    func updateDownloadStatus(for trackId: String, isDownloaded: Bool, localPath: String?) {
        guard let context = context else { return }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.id == trackId })
        
        do {
            if let persistent = try context.fetch(fetchDescriptor).first {
                persistent.isDownloaded = isDownloaded
                persistent.localFilePath = localPath
                try context.save()
            }
        } catch {
            print("Error updating download status: \(error)")
        }
    }
    
    func fetchTrack(id: String) -> PersistentTrack? {
        guard let context = context else { return nil }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(fetchDescriptor).first
    }
    
    func fetchAllTracks() -> [PersistentTrack] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(sortBy: [SortDescriptor(\.title)])
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func searchTracks(query: String) -> [PersistentTrack] {
        guard let context = context, !query.isEmpty else { return [] }
        
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.title.localizedStandardContains(query) ||
                (track.artist ?? "").localizedStandardContains(query) ||
                (track.album ?? "").localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.title)]
        )
        
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func searchArtists(query: String) -> [PersistentArtist] {
        guard let context = context, !query.isEmpty else { return [] }
        
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(
            predicate: #Predicate<PersistentArtist> { artist in
                artist.name.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.name)]
        )
        
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
}
