import Foundation
import CoreData

/// Persistent storage model for track metadata, including AI-enriched content.
@objc(PersistentTrack)
public class PersistentTrack: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var title: String
    @NSManaged public var artist: String?
    @NSManaged public var album: String?
    @NSManaged public var duration: Int32
    @NSManaged public var coverArt: String?
    @NSManaged public var artistId: String?
    @NSManaged public var albumId: String?
    @NSManaged public var suffix: String?
    
    // AI-Enriched Metadata
    @NSManaged public var aiGenrePrediction: String?
    @NSManaged public var aiAtmosphere: String?
    @NSManaged public var aiStyle: String?
    @NSManaged public var aiDescription: String?
    @NSManaged public var lastAuditDate: Date?
    @NSManaged public var hasCustomBackdrop: Bool
    @NSManaged public var localBackdropPath: String?
    @NSManaged public var customCoverArt: String?
    
    // Persistence Layer Optimization
    @NSManaged public var isDownloaded: Bool
    @NSManaged public var localFilePath: String?
    
    // Analytics
    @NSManaged public var playCount: Int32
    @NSManaged public var lastPlayedAt: Date?
    @NSManaged public var isStarred: Bool
}

/// Persistent storage model for artist metadata.
@objc(PersistentArtist)
public class PersistentArtist: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var name: String
    @NSManaged public var coverArt: String?
    @NSManaged public var musicBrainzId: String?
    @NSManaged public var biography: String?
    @NSManaged public var area: String?
    @NSManaged public var type: String?
    @NSManaged public var lifeSpan: String?
    @NSManaged public var lastAuditDate: Date?
}

/// Persistent storage model for album metadata.
@objc(PersistentAlbum)
public class PersistentAlbum: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var name: String
    @NSManaged public var artist: String?
    @NSManaged public var artistId: String?
    @NSManaged public var songCount: Int32
    @NSManaged public var duration: Int32
    @NSManaged public var coverArt: String?
    @NSManaged public var releaseYear: Int32
    @NSManaged public var recordLabel: String?
    @NSManaged public var firstReleaseDate: String?
    @NSManaged public var customCoverArt: String?
}

// MARK: - Initializers (Helpers)

extension PersistentTrack {
    func update(with track: Track) {
        self.id = track.id
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
        self.duration = Int32(track.duration ?? 0)
        self.coverArt = track.coverArt
        self.artistId = track.artistId
        self.albumId = track.albumId
        self.suffix = track.suffix
        self.isStarred = track.isStarred
        self.playCount = Int32(track.playCount ?? 0)
        
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

extension PersistentArtist {
    func update(with artist: Artist) {
        self.id = artist.id
        self.name = artist.name
        self.coverArt = artist.coverArt
    }
}

extension PersistentAlbum {
    func update(with album: Album) {
        self.id = album.id
        self.name = album.name
        self.artist = album.artist
        self.artistId = album.artistId
        self.songCount = Int32(album.songCount ?? 0)
        self.duration = Int32(album.duration ?? 0)
        self.coverArt = album.coverArt
        self.recordLabel = album.recordLabel
        self.firstReleaseDate = album.firstReleaseDate
        if let frd = album.firstReleaseDate, let year = Int(frd.prefix(4)) {
            self.releaseYear = Int32(year)
        }
    }
}
