import Foundation

/// Persistent registry tracking verified offline assets and confirmed unavailable external items.
/// Prevents redundant network queries for items known not to exist on Fanart.tv, LRCLIB, or MusicBrainz.
@MainActor
final class AssetRegistry {
    static let shared = AssetRegistry()

    private let registryFileName = "asset_registry.json"
    private var registryUrl: URL {
        VeloraStorage.root.appendingPathComponent(registryFileName)
    }

    struct RegistryData: Codable {
        var version: Int = 1
        /// Keys of backdrops verified unavailable on Fanart.tv
        var unavailableBackdrops: Set<String> = []
        /// Keys of clearlogos verified unavailable on Fanart.tv
        var unavailableLogos: Set<String> = []
        /// Track IDs verified not to have lyrics on LRCLIB (instrumental / unlisted)
        var unavailableLyrics: Set<String> = []
        /// Artist IDs verified not to have portraits on Navidrome & Fanart.tv
        var unavailablePortraits: Set<String> = []
        /// Artist names verified not to have MusicBrainz data
        var unavailableArtists: Set<String> = []
        /// Album keys (artist_album) verified not to have MusicBrainz album data
        var unavailableAlbums: Set<String> = []
    }

    private var data = RegistryData()
    private var isDirty = false

    private init() {
        load()
    }

    func load() {
        if let fileData = try? Data(contentsOf: registryUrl),
           let decoded = try? JSONDecoder().decode(RegistryData.self, from: fileData) {
            self.data = decoded
        } else {
            self.data = RegistryData()
        }
    }

    func save() {
        guard isDirty else { return }
        isDirty = false
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: registryUrl)
        }
    }

    // MARK: - Backdrop
    func isBackdropUnavailable(key: String) -> Bool {
        data.unavailableBackdrops.contains(key)
    }

    func markBackdropUnavailable(key: String) {
        data.unavailableBackdrops.insert(key)
        isDirty = true
        save()
    }

    // MARK: - Logo
    func isLogoUnavailable(key: String) -> Bool {
        data.unavailableLogos.contains(key)
    }

    func markLogoUnavailable(key: String) {
        data.unavailableLogos.insert(key)
        isDirty = true
        save()
    }

    // MARK: - Lyrics
    func isLyricsUnavailable(trackId: String) -> Bool {
        data.unavailableLyrics.contains(trackId)
    }

    func markLyricsUnavailable(trackId: String) {
        data.unavailableLyrics.insert(trackId)
        isDirty = true
        save()
    }

    // MARK: - Portrait
    func isPortraitUnavailable(artistId: String) -> Bool {
        data.unavailablePortraits.contains(artistId)
    }

    func markPortraitUnavailable(artistId: String) {
        data.unavailablePortraits.insert(artistId)
        isDirty = true
        save()
    }

    // MARK: - MusicBrainz Artist & Album
    func isArtistUnavailable(artistName: String) -> Bool {
        data.unavailableArtists.contains(artistName)
    }

    func markArtistUnavailable(artistName: String) {
        data.unavailableArtists.insert(artistName)
        isDirty = true
        save()
    }

    func isAlbumUnavailable(albumKey: String) -> Bool {
        data.unavailableAlbums.contains(albumKey)
    }

    func markAlbumUnavailable(albumKey: String) {
        data.unavailableAlbums.insert(albumKey)
        isDirty = true
        save()
    }

    // MARK: - Counts
    var unavailableBackdropsCount: Int { data.unavailableBackdrops.count }
    var unavailableLogosCount: Int { data.unavailableLogos.count }
    var unavailableLyricsCount: Int { data.unavailableLyrics.count }
    var unavailablePortraitsCount: Int { data.unavailablePortraits.count }

    // MARK: - Deep Reset
    /// Wipes all negative caches so the user can force a 100% deep re-scan if desired
    func resetUnavailableRecords() {
        data.unavailableBackdrops.removeAll()
        data.unavailableLogos.removeAll()
        data.unavailableLyrics.removeAll()
        data.unavailablePortraits.removeAll()
        data.unavailableArtists.removeAll()
        data.unavailableAlbums.removeAll()
        isDirty = true
        save()
    }

    // MARK: - Fanart Reset
    /// Wipes unavailable backdrop and logo records so that entering or updating a Fanart API key
    /// allows all artists to be queried again without false "not available" blocks.
    func resetFanartUnavailableRecords() {
        data.unavailableBackdrops.removeAll()
        data.unavailableLogos.removeAll()
        isDirty = true
        save()
    }
}
