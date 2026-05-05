import Foundation
import SwiftData

/// Centralized manager for SwiftData operations.
/// High-performance local cache for AI-enriched metadata.
@available(iOS 17.0, *)
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
        
        let trackIds = tracks.map { $0.id }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { trackIds.contains($0.id) })
        
        let existingTracks: [String: PersistentTrack]
        do {
            let fetched = try context.fetch(fetchDescriptor)
            existingTracks = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        } catch {
            AppLogger.shared.log("LocalMetadataStore: Failed to fetch existing tracks for batch save.", level: .error)
            return
        }
        
        for track in tracks {
            if let existing = existingTracks[track.id] {
                existing.title = track.title
                existing.artist = track.artist
                existing.album = track.album
                existing.isStarred = track.isStarred
                existing.playCount = track.playCount ?? 0
                existing.coverArt = track.coverArt
                
                // Integrity checks are deferred to the Deep Audit to avoid I/O stalls during sync
            } else {
                let newTrack = PersistentTrack(track: track)
                context.insert(newTrack)
            }
        }
        
        do {
            try context.save()
        } catch {
            AppLogger.shared.log("LocalMetadataStore: Failed to save context: \(error)", level: .error)
        }
    }
    
    func saveArtists(_ artists: [Artist]) {
        guard let context = context else { return }
        
        let artistIds = artists.map { $0.id }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(predicate: #Predicate { artistIds.contains($0.id) })
        
        let existingArtists: [String: PersistentArtist]
        do {
            let fetched = try context.fetch(fetchDescriptor)
            existingArtists = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        } catch {
            return
        }
        
        for artist in artists {
            if let existing = existingArtists[artist.id] {
                existing.name = artist.name
                existing.coverArt = artist.coverArt
                
                if let area = artist.area { existing.area = area }
                if let type = artist.type { existing.type = type }
                if let lifeSpan = artist.lifeSpan { existing.lifeSpan = lifeSpan }
            } else {
                let newArtist = PersistentArtist(artist: artist)
                context.insert(newArtist)
            }
        }
        
        try? context.save()
    }
    
    func saveAlbums(_ albums: [Album]) {
        guard let context = context else { return }
        
        let albumIds = albums.map { $0.id }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(predicate: #Predicate { albumIds.contains($0.id) })
        
        let existingAlbums: [String: PersistentAlbum]
        do {
            let fetched = try context.fetch(fetchDescriptor)
            existingAlbums = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        } catch {
            return
        }
        
        for album in albums {
            if let existing = existingAlbums[album.id] {
                existing.name = album.name
                existing.artist = album.artist
                existing.coverArt = album.coverArt
                
                // Selectively update aggregate stats to avoid overwriting with partial batch data
                if let sc = album.songCount { existing.songCount = sc }
                if let dur = album.duration { existing.duration = dur }
                
                if let dateString = album.firstReleaseDate, let year = Int(dateString.prefix(4)) {
                    existing.releaseYear = year
                }
                if let label = album.recordLabel { existing.recordLabel = label }
                if let frd = album.firstReleaseDate { existing.firstReleaseDate = frd }
            } else {
                let newAlbum = PersistentAlbum(album: album)
                context.insert(newAlbum)
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
    
    func fetchTracksByIds(_ ids: [String]) -> [PersistentTrack] {
        guard let context = context, !ids.isEmpty else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(predicate: #Predicate { ids.contains($0.id) })
        return (try? context.fetch(fetchDescriptor)) ?? []
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
    
    func trackCount() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>()
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func artistCount() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>()
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func albumCount() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>()
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func fetchTrackIds() -> Set<String> {
        guard let context = context else { return [] }
        // Fetch only the ID property to save memory
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(propertiesToFetch: [\.id])
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return Set(results.map { $0.id })
    }
    
    func fetchArtistNames() -> Set<String> {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(propertiesToFetch: [\.name])
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return Set(results.map { $0.name })
    }
    
    func fetchAlbumNamesAndArtists() -> [(name: String, artist: String)] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(propertiesToFetch: [\.name, \.artist])
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.map { ($0.name, $0.artist ?? "Unknown Artist") }
    }
    
    func fetchArtistMBIDs() -> Set<String> {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(
            predicate: #Predicate<PersistentArtist> { $0.musicBrainzId != nil },
            propertiesToFetch: [\.musicBrainzId]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return Set(results.compactMap { $0.musicBrainzId })
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
    
    func fetchArtistsByIds(_ ids: [String]) -> [PersistentArtist] {
        guard let context = context, !ids.isEmpty else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(predicate: #Predicate { ids.contains($0.id) })
        return (try? context.fetch(fetchDescriptor)) ?? []
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
    
    func fetchAlbumsByIds(_ ids: [String]) -> [PersistentAlbum] {
        guard let context = context, !ids.isEmpty else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(predicate: #Predicate { ids.contains($0.id) })
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func searchTracks(query: String) -> [PersistentTrack] {
        guard let context = context, !query.isEmpty else { return [] }
        
        // Use a broad fetch to avoid compiler timeout on complex predicates
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(sortBy: [SortDescriptor(\.title)])
        
        do {
            let allTracks = try context.fetch(fetchDescriptor)
            // Perform high-performance in-memory filtering
            return allTracks.filter { track in
                track.title.localizedStandardContains(query) ||
                (track.artist ?? "").localizedStandardContains(query) ||
                (track.album ?? "").localizedStandardContains(query) ||
                (track.aiGenrePrediction ?? "").localizedStandardContains(query) ||
                (track.aiAtmosphere ?? "").localizedStandardContains(query)
            }
        } catch {
            print("Error searching tracks: \(error)")
            return []
        }
    }
    
    func searchArtists(query: String) -> [PersistentArtist] {
        guard let context = context, !query.isEmpty else { return [] }
        
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(sortBy: [SortDescriptor(\.name)])
        
        do {
            let allArtists = try context.fetch(fetchDescriptor)
            return allArtists.filter { artist in
                artist.name.localizedStandardContains(query)
            }
        } catch {
            print("Error searching artists: \(error)")
            return []
        }
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
    
    func countTracksMissingGenre() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { $0.aiGenrePrediction == nil }
        )
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func fetchTracksMissingGenreIds() -> [String] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { $0.aiGenrePrediction == nil },
            propertiesToFetch: [\.id]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.map { $0.id }
    }
    
    func fetchTracksWithUnknownMetadata() -> [PersistentTrack] {
        guard let context = context else { return [] }
        
        let artistDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.artist == "Unknown"
            }
        )
        let artistResults = (try? context.fetch(artistDescriptor)) ?? []
        
        let albumDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.album == "Unknown"
            }
        )
        let albumResults = (try? context.fetch(albumDescriptor)) ?? []
        
        var combined = artistResults
        let existingIds = Set(artistResults.map { $0.id })
        for track in albumResults {
            if !existingIds.contains(track.id) {
                combined.append(track)
            }
        }
        return combined
    }
    
    func fetchAlbumsMissingYear() -> [PersistentAlbum] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(
            predicate: #Predicate<PersistentAlbum> { album in
                album.releaseYear == nil || album.releaseYear == 0
            }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func countAlbumsMissingYear() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(
            predicate: #Predicate<PersistentAlbum> { $0.releaseYear == nil || $0.releaseYear == 0 }
        )
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func fetchAlbumsMissingYearIds() -> [String] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentAlbum>(
            predicate: #Predicate<PersistentAlbum> { $0.releaseYear == nil || $0.releaseYear == 0 },
            propertiesToFetch: [\.id]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.map { $0.id }
    }
    
    func fetchTracksWithLowResArt() -> [PersistentTrack] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.coverArt != nil
            }
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.filter { $0.coverArt?.contains("size=500") == false }
    }
    
    func countTracksWithLowResArt() -> Int {
        // We still have to fetch the strings to check contains, but we can fetch only the coverArt property
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { $0.coverArt != nil },
            propertiesToFetch: [\.coverArt]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.filter { $0.coverArt?.contains("size=500") == false }.count
    }
    
    func fetchTracksWithLowResArtIds() -> [String] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { $0.coverArt != nil },
            propertiesToFetch: [\.id, \.coverArt]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.filter { $0.coverArt?.contains("size=500") == false }.map { $0.id }
    }
    
    func fetchArtistsMissingInfo() -> [PersistentArtist] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(
            predicate: #Predicate<PersistentArtist> { artist in
                artist.musicBrainzId == nil || artist.biography == nil || artist.area == nil
            }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    func countArtistsMissingInfo() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(
            predicate: #Predicate<PersistentArtist> { $0.musicBrainzId == nil || $0.biography == nil || $0.area == nil }
        )
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func fetchArtistsMissingInfoIds() -> [String] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentArtist>(
            predicate: #Predicate<PersistentArtist> { $0.musicBrainzId == nil || $0.biography == nil || $0.area == nil },
            propertiesToFetch: [\.id]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.map { $0.id }
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
    
    func countTracksMissingBackdrop() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { !$0.hasCustomBackdrop }
        )
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func fetchTracksMissingBackdropIds() -> [String] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { !$0.hasCustomBackdrop },
            propertiesToFetch: [\.id]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.map { $0.id }
    }
    
    func countTracksWithUnknownMetadata() -> Int {
        guard let context = context else { return 0 }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { $0.artist == "Unknown" || $0.album == "Unknown" }
        )
        return (try? context.fetchCount(fetchDescriptor)) ?? 0
    }
    
    func fetchTracksWithUnknownMetadataIds() -> [String] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { $0.artist == "Unknown" || $0.album == "Unknown" },
            propertiesToFetch: [\.id]
        )
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        return results.map { $0.id }
    }

    func fetchAuditTargets() -> [PersistentTrack] {
        guard let context = context else { return [] }
        
        // Simplified predicate to avoid compiler timeout
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { track in
                track.aiGenrePrediction == nil
            }
        )
        
        let results = (try? context.fetch(fetchDescriptor)) ?? []
        // Post-filter complex conditions in memory
        return results.filter { $0.artist == "Unknown" || $0.album == "Unknown" }
    }

    func fetchDownloadedTracks() -> [PersistentTrack] {
        guard let context = context else { return [] }
        let fetchDescriptor = FetchDescriptor<PersistentTrack>(
            predicate: #Predicate<PersistentTrack> { $0.isDownloaded }
        )
        return (try? context.fetch(fetchDescriptor)) ?? []
    }

    /// Verifies all tracks marked as downloaded still exist and are valid on disk.
    /// Performs this on the MainActor but yields to avoid blocking.
    func verifyLocalPersistence() {
        Task {
            let tracks = self.fetchDownloadedTracks()
            for track in tracks {
                let id = track.id
                let isValid = IntegrityManager.shared.isTrackValid(id: id)
                if !isValid {
                    self.updateDownloadStatus(for: id, isDownloaded: false, localPath: nil)
                    AppLogger.shared.log("[Persistence] Fixed stale download status for: \(track.title)", level: .info)
                }
                
                // Yield frequently to keep UI responsive during large library verification
                await Task.yield()
            }
        }
    }
}
