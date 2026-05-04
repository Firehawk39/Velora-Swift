import Foundation
import SwiftData

/// Persistent storage model for track metadata, including AI-enriched content.
@available(iOS 17.0, *)
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
    var customCoverArt: String?
    
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
@available(iOS 17.0, *)
@Model
final class PersistentArtist {
    @Attribute(.unique) var id: String
    var name: String
    var coverArt: String?
    var musicBrainzId: String?
    var biography: String?
    var area: String?
    var type: String?
    var lifeSpan: String?
    var lastAuditDate: Date?
    
    init(artist: Artist) {
        self.id = artist.id
        self.name = artist.name
        self.coverArt = artist.coverArt
    }
}

/// Persistent storage model for album metadata.
@available(iOS 17.0, *)
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
    var recordLabel: String?
    var firstReleaseDate: String?
    var customCoverArt: String?
    
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

