import Foundation
import SwiftData

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
                    
                    // Update enriched fields only if the incoming model has them (unlikely for Navidrome sync, but good for future)
                    if let area = artist.area { existing.area = area }
                    if let type = artist.type { existing.type = type }
                    if let lifeSpan = artist.lifeSpan { existing.lifeSpan = lifeSpan }
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
                    
                    if let year = album.releaseYear { existing.releaseYear = year }
                    if let label = album.recordLabel { existing.recordLabel = label }
                    if let frd = album.firstReleaseDate { existing.firstReleaseDate = frd }
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
        updateAIMetadataBatch(results: [EnrichedMetadata(id: trackId, genre: genre ?? "", mood: atmosphere ?? "", release_year: 0, style: nil, description: nil)])
    }
    
    func updateAIMetadataBatch(results: [EnrichedMetadata]) {
        guard let context = context else { return }
        
        for result in results {
            guard let id = result.id else { continue }
            let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.id == id })
            
            do {
                if let persistent = try context.fetch(fetchDescriptor).first {
                    persistent.aiGenrePrediction = result.genre
                    persistent.aiAtmosphere = result.mood
                    persistent.aiStyle = result.style
                    persistent.aiDescription = result.description
                    persistent.lastAuditDate = Date()
                }
            } catch {
                print("Error updating AI metadata for \(id): \(error)")
            }
        }
        
        try? context.save()
    }
    
    func updateArtistInfo(for artistId: String, bio: String?, mbid: String?, area: String? = nil, type: String? = nil, lifeSpan: String? = nil) {
        guard let context = context else { return }
        
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(predicate: #Predicate { $0.id == artistId })
        
        do {
            if let persistent = try context.fetch(fetchDescriptor).first {
                if let bio = bio { persistent.biography = bio }
                if let mbid = mbid { persistent.musicBrainzId = mbid }
                if let area = area { persistent.area = area }
                if let type = type { persistent.type = type }
                if let lifeSpan = lifeSpan { persistent.lifeSpan = lifeSpan }
                persistent.lastAuditDate = Date()
                try context.save()
            }
        } catch {
            print("Error updating artist info: \(error)")
        }
    }

    func updateAlbumYear(for albumId: String, year: Int?, label: String? = nil, firstReleaseDate: String? = nil) {
        updateAlbumYearBatch(results: [(id: albumId, year: year, label: label, firstReleaseDate: firstReleaseDate)])
    }
    
    func updateAlbumYearBatch(results: [(id: String, year: Int?, label: String?, firstReleaseDate: String?)]) {
        guard let context = context else { return }
        
        for result in results {
            let id = result.id
            let fetchDescriptor = FetchDescriptor<PersistentAlbum>(predicate: #Predicate { $0.id == id })
            do {
                if let persistent = try context.fetch(fetchDescriptor).first {
                    if let year = result.year { persistent.releaseYear = year }
                    if let label = result.label { persistent.recordLabel = label }
                    if let frd = result.firstReleaseDate { persistent.firstReleaseDate = frd }
                }
            } catch {
                print("Error updating album year for \(id): \(error)")
            }
        }
        
        try? context.save()
    }

    func updateCustomArt(for trackId: String, url: String) {
        updateCustomArtBatch(results: [(trackIds: [trackId], albumId: nil, url: url)])
    }
    
    func updateCustomArtBatch(results: [(trackIds: [String], albumId: String?, url: String)]) {
        guard let context = context else { return }
        
        for result in results {
            // Update the album if provided
            if let albumId = result.albumId {
                let albumFetch = FetchDescriptor<PersistentAlbum>(predicate: #Predicate { $0.id == albumId })
                if let persistentAlbum = (try? context.fetch(albumFetch))?.first {
                    persistentAlbum.customCoverArt = result.url
                }
            }
            
            // Update all tracks
            for trackId in result.trackIds {
                let trackFetch = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.id == trackId })
                if let persistentTrack = (try? context.fetch(trackFetch))?.first {
                    persistentTrack.customCoverArt = result.url
                }
            }
        }
        
        try? context.save()
    }
    
    func updateBackdropStatus(for artistName: String, hasBackdrop: Bool) {
        guard let context = context else { return }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.artist == artistName })
        
        do {
            let tracks = try context.fetch(fetchDescriptor)
            for track in tracks {
                track.hasCustomBackdrop = hasBackdrop
            }
            try context.save()
        } catch {
            print("Error updating backdrop status for \(artistName): \(error)")
        }
    }
    
    func updateAlbumCustomArt(for albumId: String, url: String) {
        updateCustomArtBatch(results: [(trackIds: [], albumId: albumId, url: url)])
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

    func updateTrackMetadata(for trackId: String, title: String? = nil, artist: String? = nil, album: String? = nil) {
        guard let context = context else { return }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { $0.id == trackId })
        
        do {
            if let persistent = try context.fetch(fetchDescriptor).first {
                if let title = title { persistent.title = title }
                if let artist = artist { persistent.artist = artist }
                if let album = album { persistent.album = album }
                try context.save()
            }
        } catch {
            print("Error updating track metadata: \(error)")
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
    
    func fetchAllArtists() -> [PersistentArtist] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func fetchAllAlbums() -> [PersistentAlbum] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func fetchArtist(name: String) -> PersistentArtist? {
        guard let context = context else { return nil }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(predicate: #Predicate { $0.name == name })
        return try? context.fetch(fetchDescriptor).first
    }
    
    func fetchArtistById(id: String) -> PersistentArtist? {
        guard let context = context else { return nil }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(fetchDescriptor).first
    }
    
    func fetchAlbum(name: String, artistName: String) -> PersistentAlbum? {
        guard let context = context else { return nil }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(predicate: #Predicate { $0.name == name && $0.artist == artistName })
        return try? context.fetch(fetchDescriptor).first
    }
    
    func fetchAlbumById(id: String) -> PersistentAlbum? {
        guard let context = context else { return nil }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(fetchDescriptor).first
    }
    
    func searchTracks(query: String) -> [PersistentTrack] {
        guard let context = context, !query.isEmpty else { return [] }
        
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.title.localizedStandardContains(query) ||
                (track.artist ?? "").localizedStandardContains(query) ||
                (track.album ?? "").localizedStandardContains(query) ||
                (track.aiGenrePrediction ?? "").localizedStandardContains(query) ||
                (track.aiAtmosphere ?? "").localizedStandardContains(query)
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
    
    // MARK: - Audit & Enrichment Helpers
    
    func fetchTracksMissingGenre() -> [PersistentTrack] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.aiGenrePrediction == nil
            }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func fetchTracksWithUnknownMetadata() -> [PersistentTrack] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.artist == "Unknown" || track.album == "Unknown"
            }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func fetchAlbumsMissingYear() -> [PersistentAlbum] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(
            predicate: #Predicate<PersistentAlbum> { album in
                album.releaseYear == 0 || album.releaseYear == nil
            }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func fetchTracksWithLowResArt() -> [PersistentTrack] {
        guard let context = context else { return [] }
        // We look for tracks that don't have "size=500" in their coverArt URL (Navidrome convention for high-res)
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.coverArt != nil
            }
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.filter { $0.coverArt?.contains("size=500") == false }
    }
    
    func fetchArtistsMissingInfo() -> [PersistentArtist] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(
            predicate: #Predicate<PersistentArtist> { artist in
                artist.biography == nil || artist.musicBrainzId == nil || artist.area == nil
            }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func fetchTracksMissingBackdrop() -> [PersistentTrack] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                !track.hasCustomBackdrop
            }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }

    func fetchAuditTargets() -> [PersistentTrack] {
        guard let context = context else { return [] }
        
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.aiGenrePrediction == nil || 
                track.artist == "Unknown" || 
                track.album == "Unknown"
            }
        )
        
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
}
