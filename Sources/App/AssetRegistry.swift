import Foundation

/// Persistent registry tracking verified offline assets and confirmed unavailable external items.
/// Prevents redundant network queries for items known not to exist on Fanart.tv, LRCLIB, or MusicBrainz.
/// Thread-safe via internal NSLock to allow synchronous access from background tasks and MainActor alike.
final class AssetRegistry: @unchecked Sendable {
    static let shared = AssetRegistry()

    private let lock = NSLock()
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
        /// Cover art IDs verified unavailable on Navidrome server
        var unavailableCoverArts: Set<String> = []
    }

    private var data = RegistryData()
    private var isDirty = false

    private init() {
        load()
    }

    func load() {
        lock.lock()
        defer { lock.unlock() }
        if let fileData = try? Data(contentsOf: registryUrl),
           let decoded = try? JSONDecoder().decode(RegistryData.self, from: fileData) {
            self.data = decoded
        } else {
            self.data = RegistryData()
        }
    }

    private func saveLocked() {
        guard isDirty else { return }
        isDirty = false
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: registryUrl)
        }
    }

    func save() {
        lock.lock()
        defer { lock.unlock() }
        saveLocked()
    }

    // MARK: - Backdrop
    func isBackdropUnavailable(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableBackdrops.contains(key)
    }

    func markBackdropUnavailable(key: String) {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableBackdrops.insert(key)
        isDirty = true
        saveLocked()
    }

    // MARK: - Logo
    func isLogoUnavailable(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableLogos.contains(key)
    }

    func markLogoUnavailable(key: String) {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableLogos.insert(key)
        isDirty = true
        saveLocked()
    }

    // MARK: - Lyrics
    func isLyricsUnavailable(trackId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableLyrics.contains(trackId)
    }

    func markLyricsUnavailable(trackId: String) {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableLyrics.insert(trackId)
        isDirty = true
        saveLocked()
    }

    // MARK: - Portrait
    func isPortraitUnavailable(artistId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailablePortraits.contains(artistId)
    }

    func markPortraitUnavailable(artistId: String) {
        lock.lock()
        defer { lock.unlock() }
        data.unavailablePortraits.insert(artistId)
        isDirty = true
        saveLocked()
    }

    // MARK: - MusicBrainz Artist & Album
    func isArtistUnavailable(artistName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableArtists.contains(artistName)
    }

    func markArtistUnavailable(artistName: String) {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableArtists.insert(artistName)
        isDirty = true
        saveLocked()
    }

    func isAlbumUnavailable(albumKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableAlbums.contains(albumKey)
    }

    func markAlbumUnavailable(albumKey: String) {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableAlbums.insert(albumKey)
        isDirty = true
        saveLocked()
    }

    // MARK: - Cover Art
    func isCoverArtUnavailable(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableCoverArts.contains(id)
    }

    func markCoverArtUnavailable(id: String) {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableCoverArts.insert(id)
        isDirty = true
        saveLocked()
    }

    // MARK: - Counts
    var unavailableBackdropsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableBackdrops.count
    }
    var unavailableLogosCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableLogos.count
    }
    var unavailableLyricsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableLyrics.count
    }
    var unavailablePortraitsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailablePortraits.count
    }
    var unavailableCoverArtCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.unavailableCoverArts.count
    }

    // MARK: - Deep Reset
    /// Wipes all negative caches so the user can force a 100% deep re-scan if desired
    func resetUnavailableRecords() {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableBackdrops.removeAll()
        data.unavailableLogos.removeAll()
        data.unavailableLyrics.removeAll()
        data.unavailablePortraits.removeAll()
        data.unavailableArtists.removeAll()
        data.unavailableAlbums.removeAll()
        data.unavailableCoverArts.removeAll()
        isDirty = true
        saveLocked()
    }

    // MARK: - Fanart Reset
    /// Wipes unavailable backdrop and logo records so that entering or updating a Fanart API key
    /// allows all artists to be queried again without false "not available" blocks.
    func resetFanartUnavailableRecords() {
        lock.lock()
        defer { lock.unlock() }
        data.unavailableBackdrops.removeAll()
        data.unavailableLogos.removeAll()
        isDirty = true
        saveLocked()
    }
}
