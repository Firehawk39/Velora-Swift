import Foundation
import CryptoKit

@MainActor
final class NavidromeClient: ObservableObject {
    @Published var artists: [Artist] = []
    @Published var albums: [Album] = []
    @Published var recentlyPlayed: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var allSongs: [Track] = []
    
    private var pendingSaveTask: Task<Void, Never>?

    var recentTracks: [Track] { recentlyPlayed }

    private(set) var username: String = ""
    private var baseUrl: String = ""
    private var token: String = ""
    private var salt: String = ""
    private let clientName = "VeloraSwift"
    private let apiVersion = "1.16.1"

    // MARK: - Configuration

    func configure(url: String, user: String, pass: String) {
        self.baseUrl = url.trimmingCharacters(in: .init(charactersIn: "/"))
        self.username = user
        self.salt = SubsonicAuth.generateSalt()
        self.token = SubsonicAuth.generateToken(password: pass, salt: self.salt)
    }

    // MARK: - URL Construction

    func buildUrl(method: String, params: [String: String] = [:], extraItems: [URLQueryItem] = []) -> URL? {
        guard !baseUrl.isEmpty else { return nil }
        var components = URLComponents(string: "\(baseUrl)/rest/\(method)")
        var items = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
        params.forEach { items.append(URLQueryItem(name: $0.key, value: $0.value)) }
        items.append(contentsOf: extraItems)
        components?.queryItems = items
        return components?.url
    }

    // MARK: - Helpers

    func getStreamUrl(id: String) -> URL? {
        buildUrl(method: "stream.view", params: ["id": id])
    }

    func getCoverArtUrl(id: String, size: Int = 500) -> String {
        buildUrl(method: "getCoverArt.view", params: ["id": id, "size": "\(size)"])?.absoluteString ?? ""
    }

    private var cacheDir: URL {
        return VeloraStorage.root
    }

    func loadOfflineMetadata() {
        let dir = cacheDir
        
        Task.detached(priority: .userInitiated) { [weak self] in

            let decoder = JSONDecoder()
            
            let artistsUrl = dir.appendingPathComponent("cached_artists.json")
            let loadedArtists = (try? Data(contentsOf: artistsUrl)).flatMap { try? decoder.decode([Artist].self, from: $0) }
            
            let albumsUrl = dir.appendingPathComponent("cached_albums.json")
            let loadedAlbums = (try? Data(contentsOf: albumsUrl)).flatMap { try? decoder.decode([Album].self, from: $0) }
            
            let playlistsUrl = dir.appendingPathComponent("cached_playlists.json")
            let loadedPlaylists = (try? Data(contentsOf: playlistsUrl)).flatMap { try? decoder.decode([Playlist].self, from: $0) }
            
            let songsUrl = dir.appendingPathComponent("cached_all_songs.json")
            let loadedSongs = (try? Data(contentsOf: songsUrl)).flatMap { try? decoder.decode([Track].self, from: $0) }
            
            let recentUrl = dir.appendingPathComponent("cached_recently_played.json")
            let loadedRecent = (try? Data(contentsOf: recentUrl)).flatMap { try? decoder.decode([Track].self, from: $0) }
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if let artists = loadedArtists { self.artists = artists }
                if let albums = loadedAlbums { self.albums = albums }
                if let playlists = loadedPlaylists { self.playlists = playlists }
                if let songs = loadedSongs { self.allSongs = songs }
                if let recent = loadedRecent { self.recentlyPlayed = recent }
                
                AppLogger.shared.log("[Offline Cache] Loaded metadata asynchronously: \(self.artists.count) artists, \(self.albums.count) albums, \(self.allSongs.count) songs")
            }
        }
    }

    func saveOfflineMetadata() {
        // Cancel any pending writes to coalesce multiple quick saves (debouncing)
        pendingSaveTask?.cancel()
        
        let dir = cacheDir
        let copyArtists = self.artists
        let copyAlbums = self.albums
        let copyPlaylists = self.playlists
        let copyAllSongs = self.allSongs
        let copyRecentlyPlayed = self.recentlyPlayed
        
        pendingSaveTask = Task {
            // Debounce by 1 second to bundle concurrent network fetch calls
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return // Cancelled by a newer write request
            }
            
            let encoder = JSONEncoder()
            let writeOptions: Data.WritingOptions = .atomic
            
            let artistsUrl = dir.appendingPathComponent("cached_artists.json")
            if let data = try? encoder.encode(copyArtists) {
                try? data.write(to: artistsUrl, options: writeOptions)
            }
            
            let albumsUrl = dir.appendingPathComponent("cached_albums.json")
            if let data = try? encoder.encode(copyAlbums) {
                try? data.write(to: albumsUrl, options: writeOptions)
            }
            
            let playlistsUrl = dir.appendingPathComponent("cached_playlists.json")
            if let data = try? encoder.encode(copyPlaylists) {
                try? data.write(to: playlistsUrl, options: writeOptions)
            }
            
            let songsUrl = dir.appendingPathComponent("cached_all_songs.json")
            if let data = try? encoder.encode(copyAllSongs) {
                try? data.write(to: songsUrl, options: writeOptions)
            }
            
            let recentUrl = dir.appendingPathComponent("cached_recently_played.json")
            if let data = try? encoder.encode(copyRecentlyPlayed) {
                try? data.write(to: recentUrl, options: writeOptions)
            }
            
            AppLogger.shared.log("[Offline Cache] Coalesced metadata saved atomically.")
        }
    }

    func logout() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        
        let savedUser = UserDefaults.standard.string(forKey: "velora_username") ?? ""
        UserDefaults.standard.removeObject(forKey: "velora_server_url")
        UserDefaults.standard.removeObject(forKey: "velora_username")
        UserDefaults.standard.removeObject(forKey: "velora_display_name")
        
        if !savedUser.isEmpty {
            KeychainHelper.shared.delete(service: "velora-password", account: savedUser)
        }
        
        let dir = self.cacheDir
        try? FileManager.default.removeItem(at: VeloraStorage.lyrics)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("cached_artists.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("cached_albums.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("cached_playlists.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("cached_all_songs.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("cached_recently_played.json"))
        
        self.baseUrl = ""
        self.username = ""
        self.token = ""
        self.salt = ""
        // Clear data
        self.artists = []
        self.albums = []
        self.recentlyPlayed = []
        self.playlists = []
        self.allSongs = []
    }
}
