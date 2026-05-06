import Foundation
import CoreData

/// Centralized manager for Core Data operations.
/// High-performance local cache for AI-enriched metadata.
/// Optimized for iOS 15 compatibility.
@MainActor
class LocalMetadataStore {
    nonisolated static let shared = LocalMetadataStore()
    
    private let persistentContainer: NSPersistentContainer
    
    private var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    private lazy var backgroundContext: NSManagedObjectContext = {
        let ctx = persistentContainer.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.undoManager = nil // Memory optimization
        return ctx
    }()
    
    nonisolated init() {
        // Find the model in the bundle
        guard let modelURL = Bundle.module.url(forResource: "Velora", withExtension: "momd") else {
            fatalError("Failed to find Velora.xcdatamodeld in bundle")
        }
        
        guard let managedObjectModel = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Failed to load managed object model")
        }
        
        persistentContainer = NSPersistentContainer(name: "Velora", managedObjectModel: managedObjectModel)
        
        // Optimize for performance
        let description = persistentContainer.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        
        persistentContainer.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                print("Failed to initialize Core Data: \(error), \(error.userInfo)")
            }
        }
        
        // Merge policy to handle conflicts (favor in-memory changes)
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
    }
    
    func save() {
        save(context: persistentContainer.viewContext)
    }

    private func save(context: NSManagedObjectContext) {
        context.perform {
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    AppLogger.shared.log("LocalMetadataStore: Failed to save context: \(error)", level: .error)
                }
            }
        }
    }
    
    // MARK: - Batch Operations
    
    func saveTracks(_ tracks: [Track]) {
        let ctx = backgroundContext
        ctx.perform {
            let trackIds = tracks.map { $0.id }
            let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", trackIds)
            
            let existingTracks: [String: PersistentTrack]
            do {
                let fetched = try ctx.fetch(fetchRequest)
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
                    existing.playCount = Int32(track.playCount ?? 0)
                    existing.coverArt = track.coverArt
                } else {
                    let newTrack = PersistentTrack(context: ctx)
                    newTrack.update(with: track)
                }
            }
            
            if ctx.hasChanges { try? ctx.save() }
        }
    }
    
    func saveArtists(_ artists: [Artist]) {
        let ctx = backgroundContext
        ctx.perform {
            let artistIds = artists.map { $0.id }
            let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", artistIds)
            
            let existingArtists: [String: PersistentArtist]
            do {
                let fetched = try ctx.fetch(fetchRequest)
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
                    let newArtist = PersistentArtist(context: ctx)
                    newArtist.update(with: artist)
                }
            }
            
            if ctx.hasChanges { try? ctx.save() }
        }
    }
    
    func saveAlbums(_ albums: [Album]) {
        let ctx = backgroundContext
        ctx.perform {
            let albumIds = albums.map { $0.id }
            let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", albumIds)
            
            let existingAlbums: [String: PersistentAlbum]
            do {
                let fetched = try ctx.fetch(fetchRequest)
                existingAlbums = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            } catch {
                return
            }
            
            for album in albums {
                if let existing = existingAlbums[album.id] {
                    existing.name = album.name
                    existing.artist = album.artist
                    existing.coverArt = album.coverArt
                    
                    if let sc = album.songCount { existing.songCount = Int32(sc) }
                    if let dur = album.duration { existing.duration = Int32(dur) }
                    
                    if let dateString = album.firstReleaseDate, let year = Int(dateString.prefix(4)) {
                        existing.releaseYear = Int32(year)
                    }
                    if let label = album.recordLabel { existing.recordLabel = label }
                    if let frd = album.firstReleaseDate { existing.firstReleaseDate = frd }
                } else {
                    let newAlbum = PersistentAlbum(context: ctx)
                    newAlbum.update(with: album)
                }
            }
            
            if ctx.hasChanges { try? ctx.save() }
        }
    }
    
    // MARK: - Single Operations
    
    func saveTrack(_ track: Track) {
        saveTracks([track])
    }
    
    func updateAIMetadata(for trackId: String, genre: String?, atmosphere: String?) {
        updateAIMetadataBatch(results: [EnrichedMetadata(id: trackId, genre: genre ?? "", mood: atmosphere ?? "", release_year: 0, style: nil, description: nil)])
    }
    
    func updateAIMetadataBatch(results: [EnrichedMetadata]) {
        for result in results {
            guard let id = result.id else { continue }
            let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", id)
            
            do {
                if let persistent = try context.fetch(fetchRequest).first {
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
        
        save()
    }
    
    func updateArtistInfo(for artistId: String, bio: String?, mbid: String?, area: String? = nil, type: String? = nil, lifeSpan: String? = nil) {
        updateArtistInfoBatch(results: [(id: artistId, bio: bio, mbid: mbid, area: area, type: type, lifeSpan: lifeSpan)])
    }
    
    func updateArtistInfoBatch(results: [(id: String, bio: String?, mbid: String?, area: String?, type: String?, lifeSpan: String?)]) {
        for result in results {
            let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", result.id)
            
            do {
                if let persistent = try context.fetch(fetchRequest).first {
                    if let bio = result.bio { persistent.biography = bio }
                    if let mbid = result.mbid { persistent.musicBrainzId = mbid }
                    if let area = result.area { persistent.area = area }
                    if let type = result.type { persistent.type = type }
                    if let lifeSpan = result.lifeSpan { persistent.lifeSpan = lifeSpan }
                    persistent.lastAuditDate = Date()
                }
            } catch {
                print("Error updating artist info: \(error)")
            }
        }
        save()
    }

    func updateAlbumYear(for albumId: String, year: Int?, label: String? = nil, firstReleaseDate: String? = nil) {
        updateAlbumYearBatch(results: [(id: albumId, year: year, label: label, firstReleaseDate: firstReleaseDate)])
    }
    
    func updateAlbumYearBatch(results: [(id: String, year: Int?, label: String?, firstReleaseDate: String?)]) {
        for result in results {
            let id = result.id
            let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", id)
            do {
                if let persistent = try context.fetch(fetchRequest).first {
                    if let year = result.year { persistent.releaseYear = Int32(year) }
                    if let label = result.label { persistent.recordLabel = label }
                    if let frd = result.firstReleaseDate { persistent.firstReleaseDate = frd }
                }
            } catch {
                print("Error updating album year for \(id): \(error)")
            }
        }
        
        save()
    }

    func updateCustomArt(for trackId: String, url: String) {
        updateCustomArtBatch(results: [(trackIds: [trackId], albumId: nil, url: url)])
    }
    
    func updateCustomArtBatch(results: [(trackIds: [String], albumId: String?, url: String)]) {
        for result in results {
            if let albumId = result.albumId {
                let albumFetch: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
                albumFetch.predicate = NSPredicate(format: "id == %@", albumId)
                if let persistentAlbum = (try? context.fetch(albumFetch))?.first {
                    persistentAlbum.customCoverArt = result.url
                }
            }
            
            for trackId in result.trackIds {
                let trackFetch: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
                trackFetch.predicate = NSPredicate(format: "id == %@", trackId)
                if let persistentTrack = (try? context.fetch(trackFetch))?.first {
                    persistentTrack.customCoverArt = result.url
                }
            }
        }
        
        save()
    }
    
    func updateBackdropStatus(for artistName: String, hasBackdrop: Bool) {
        updateBackdropStatusBatch(results: [(artistName: artistName, hasBackdrop: hasBackdrop)])
    }
    
    func updateBackdropStatusBatch(results: [(artistName: String, hasBackdrop: Bool)]) {
        for result in results {
            let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "artist == %@", result.artistName)
            
            do {
                let tracks = try context.fetch(fetchRequest)
                for track in tracks {
                    track.hasCustomBackdrop = result.hasBackdrop
                }
            } catch {
                print("Error updating backdrop status for \(result.artistName): \(error)")
            }
        }
        save()
    }
    
    func updateAlbumCustomArt(for albumId: String, url: String) {
        updateCustomArtBatch(results: [(trackIds: [], albumId: albumId, url: url)])
    }
    
    func updateDownloadStatus(for trackId: String, isDownloaded: Bool, localPath: String?) {
        context.perform {
            let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", trackId)
            
            do {
                if let persistent = try self.context.fetch(fetchRequest).first {
                    persistent.isDownloaded = isDownloaded
                    persistent.localFilePath = localPath
                    Task { @MainActor in self.save() }
                }
            } catch {
                print("Error updating download status: \(error)")
            }
        }
    }

    func updateTrackMetadata(for trackId: String, title: String? = nil, artist: String? = nil, album: String? = nil) {
        updateTrackMetadataBatch(results: [(id: trackId, title: title, artist: artist, album: album)])
    }
    
    func updateTrackMetadataBatch(results: [(id: String, title: String?, artist: String?, album: String?)]) {
        for result in results {
            let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", result.id)
            
            do {
                if let persistent = try context.fetch(fetchRequest).first {
                    if let title = result.title { persistent.title = title }
                    if let artist = result.artist { persistent.artist = artist }
                    if let album = result.album { persistent.album = album }
                }
            } catch {
                print("Error updating track metadata for \(result.id): \(error)")
            }
        }
        save()
    }
    
    func fetchTrack(id: String) -> PersistentTrack? {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)
        return try? context.fetch(fetchRequest).first
    }
    
    func fetchTracksByIds(_ ids: [String]) -> [PersistentTrack] {
        if ids.isEmpty { return [] }
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func fetchAllTracks() -> [PersistentTrack] {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func fetchAllArtists() -> [PersistentArtist] {
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func fetchAllAlbums() -> [PersistentAlbum] {
        let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func trackCount() -> Int {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func artistCount() -> Int {
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func albumCount() -> Int {
        let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func fetchTrackIds() -> Set<String> {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentTrack.fetchRequest()
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id"]
        
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return Set(results.compactMap { $0["id"] })
    }

    func fetchDownloadedTrackIds() -> Set<String> {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id"]
        
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return Set(results.compactMap { $0["id"] })
    }
    
    func fetchArtistNames() -> Set<String> {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentArtist.fetchRequest()
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["name"]
        
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return Set(results.compactMap { $0["name"] })
    }
    
    func fetchAlbumNamesAndArtists() -> [(name: String, artist: String)] {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentAlbum.fetchRequest()
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["name", "artist"]
        
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return results.map { ($0["name"] ?? "", $0["artist"] ?? "Unknown Artist") }
    }
    
    func fetchArtistMBIDs() -> Set<String> {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "musicBrainzId != nil")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["musicBrainzId"]
        
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return Set(results.compactMap { $0["musicBrainzId"] })
    }
    
    func fetchArtist(name: String) -> PersistentArtist? {
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "name == %@", name)
        return try? context.fetch(fetchRequest).first
    }
    
    func fetchArtistById(id: String) -> PersistentArtist? {
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)
        return try? context.fetch(fetchRequest).first
    }
    
    func fetchArtistsByIds(_ ids: [String]) -> [PersistentArtist] {
        if ids.isEmpty { return [] }
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func fetchAlbum(name: String, artistName: String) -> PersistentAlbum? {
        let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "name == %@ AND artist == %@", name, artistName)
        return try? context.fetch(fetchRequest).first
    }
    
    func fetchAlbumById(id: String) -> PersistentAlbum? {
        let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)
        return try? context.fetch(fetchRequest).first
    }
    
    func fetchAlbumsByIds(_ ids: [String]) -> [PersistentAlbum] {
        if ids.isEmpty { return [] }
        let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func searchTracks(query: String) -> [PersistentTrack] {
        if query.isEmpty { return [] }
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        // Core Data doesn't have localizedStandardContains in predicates directly for all store types, 
        // but [cd] (case and diacritic insensitive) works well.
        fetchRequest.predicate = NSPredicate(format: "title CONTAINS[cd] %@ OR artist CONTAINS[cd] %@ OR album CONTAINS[cd] %@ OR aiGenrePrediction CONTAINS[cd] %@ OR aiAtmosphere CONTAINS[cd] %@", query, query, query, query, query)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func searchArtists(query: String) -> [PersistentArtist] {
        if query.isEmpty { return [] }
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "name CONTAINS[cd] %@", query)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    // MARK: - Audit & Enrichment Helpers
    
    func fetchTracksMissingGenre() -> [PersistentTrack] {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "aiGenrePrediction == nil")
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func countTracksMissingGenre() -> Int {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "aiGenrePrediction == nil")
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func fetchTracksMissingGenreIds() -> [String] {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "aiGenrePrediction == nil")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id"]
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return results.compactMap { $0["id"] }
    }
    
    func fetchTracksWithUnknownMetadata() -> [PersistentTrack] {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "artist == %@ OR album == %@", "Unknown", "Unknown")
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func fetchAlbumsMissingYear() -> [PersistentAlbum] {
        let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "releaseYear == 0 OR releaseYear == nil")
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func countAlbumsMissingYear() -> Int {
        let fetchRequest: NSFetchRequest<PersistentAlbum> = PersistentAlbum.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "releaseYear == 0 OR releaseYear == nil")
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func fetchAlbumsMissingYearIds() -> [String] {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentAlbum.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "releaseYear == 0 OR releaseYear == nil")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id"]
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return results.compactMap { $0["id"] }
    }
    
    func fetchTracksWithLowResArt() -> [PersistentTrack] {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "coverArt != nil")
        let results = (try? context.fetch(fetchRequest)) ?? []
        return results.filter { $0.coverArt?.contains("size=500") == false }
    }
    
    func countTracksWithLowResArt() -> Int {
        return fetchTracksWithLowResArtIds().count
    }
    
    func fetchTracksWithLowResArtIds() -> [String] {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "coverArt != nil")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id", "coverArt"]
        
        guard let results = (try? context.fetch(fetchRequest)) as? [[String: String]] else { return [] }
        
        // Filter in memory but only on strings, not full objects
        return results.filter { 
            let art = $0["coverArt"] ?? ""
            return !art.contains("size=500") 
        }.compactMap { $0["id"] }
    }
    
    func fetchArtistsMissingInfo() -> [PersistentArtist] {
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "musicBrainzId == nil OR biography == nil OR area == nil")
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func countArtistsMissingInfo() -> Int {
        let fetchRequest: NSFetchRequest<PersistentArtist> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "musicBrainzId == nil OR biography == nil OR area == nil")
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func fetchArtistsMissingInfoIds() -> [String] {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentArtist.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "musicBrainzId == nil OR biography == nil OR area == nil")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id"]
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return results.compactMap { $0["id"] }
    }
    
    func fetchTracksMissingBackdrop() -> [PersistentTrack] {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "hasCustomBackdrop == NO")
        return (try? context.fetch(fetchRequest)) ?? []
    }
    
    func countTracksMissingBackdrop() -> Int {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "hasCustomBackdrop == NO")
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func fetchTracksMissingBackdropIds() -> [String] {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "hasCustomBackdrop == NO")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id"]
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return results.compactMap { $0["id"] }
    }
    
    func countTracksWithUnknownMetadata() -> Int {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "artist == %@ OR album == %@", "Unknown", "Unknown")
        return (try? context.count(for: fetchRequest)) ?? 0
    }
    
    func fetchTracksWithUnknownMetadataIds() -> [String] {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "artist == %@ OR album == %@", "Unknown", "Unknown")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["id"]
        let results = (try? context.fetch(fetchRequest)) as? [[String: String]] ?? []
        return results.compactMap { $0["id"] }
    }

    func fetchAuditTargets() -> [PersistentTrack] {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "aiGenrePrediction == nil AND (artist == %@ OR album == %@)", "Unknown", "Unknown")
        return (try? context.fetch(fetchRequest)) ?? []
    }

    func fetchDownloadedTracks() -> [PersistentTrack] {
        let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
        return (try? context.fetch(fetchRequest)) ?? []
    }

    func verifyLocalPersistence() {
        let ctx = backgroundContext
        ctx.perform {
            let fetchRequest: NSFetchRequest<PersistentTrack> = PersistentTrack.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isDownloaded == YES")
            
            do {
                let tracks = try ctx.fetch(fetchRequest)
                for track in tracks {
                    let id = track.id
                    let isValid = IntegrityManager.shared.isTrackValid(id: id)
                    if !isValid {
                        track.isDownloaded = false
                        track.localFilePath = nil
                        print("[Persistence] Fixed stale download status for: \(track.title ?? "Unknown")")
                    }
                }
                if ctx.hasChanges {
                    try ctx.save()
                }
            } catch {
                print("[Persistence] Failed to verify local persistence: \(error)")
            }
        }
    }
}

// MARK: - Core Data Helpers
extension PersistentTrack {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PersistentTrack> {
        return NSFetchRequest<PersistentTrack>(entityName: "PersistentTrack")
    }
}

extension PersistentArtist {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PersistentArtist> {
        return NSFetchRequest<PersistentArtist>(entityName: "PersistentArtist")
    }
}

extension PersistentAlbum {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PersistentAlbum> {
        return NSFetchRequest<PersistentAlbum>(entityName: "PersistentAlbum")
    }
}
