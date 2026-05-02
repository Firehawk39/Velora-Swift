import Foundation
import CryptoKit

class NavidromeClient: ObservableObject {
    @Published var artists: [Artist] = [] { didSet { saveMetadataToDisk() } }
    @Published var albums: [Album] = [] { didSet { saveMetadataToDisk() } }
    @Published var recentlyPlayed: [Track] = [] { didSet { saveMetadataToDisk() } }
    @Published var playlists: [Playlist] = [] { didSet { saveMetadataToDisk() } }
    @Published var allSongs: [Track] = [] { didSet { saveMetadataToDisk() } }

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

    func getCoverArtUrl(id: String) -> String {
        buildUrl(method: "getCoverArt.view", params: ["id": id, "size": "500"])?.absoluteString ?? ""
    }

    func logout() {
        let savedUser = UserDefaults.standard.string(forKey: "velora_username") ?? ""
        UserDefaults.standard.removeObject(forKey: "velora_server_url")
        UserDefaults.standard.removeObject(forKey: "velora_username")
        UserDefaults.standard.removeObject(forKey: "velora_display_name")
        
        if !savedUser.isEmpty {
            KeychainHelper.shared.delete(service: "velora-password", account: savedUser)
        }
        
        self.baseUrl = ""
        self.username = ""
        self.token = ""
        self.salt = ""
        
        // Clear files
        let url = getMetadataURL()
        try? FileManager.default.removeItem(at: url)
        
        // Clear data
        DispatchQueue.main.async {
            self.artists = []
            self.albums = []
            self.recentlyPlayed = []
            self.playlists = []
            self.allSongs = []
        }
    }

    // MARK: - Persistence

    private func getMetadataURL() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("velora_metadata.json")
    }

    struct PersistedMetadata: Codable {
        let artists: [Artist]
        let albums: [Album]
        let recentlyPlayed: [Track]
        let playlists: [Playlist]
        let allSongs: [Track]
    }

    func saveMetadataToDisk() {
        // We do this on a background thread to avoid blocking UI during fast updates
        let meta = PersistedMetadata(
            artists: self.artists,
            albums: self.albums,
            recentlyPlayed: self.recentlyPlayed,
            playlists: self.playlists,
            allSongs: self.allSongs
        )
        DispatchQueue.global(qos: .background).async {
            do {
                let data = try JSONEncoder().encode(meta)
                try data.write(to: self.getMetadataURL())
            } catch {
                // Silently fail as this is just a cache
            }
        }
    }

    func loadMetadataFromDisk() {
        let url = getMetadataURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PersistedMetadata.self, from: data)
            DispatchQueue.main.async {
                // Assign to backing variables to avoid triggering didSet loop
                self.artists = decoded.artists
                self.albums = decoded.albums
                self.recentlyPlayed = decoded.recentlyPlayed
                self.playlists = decoded.playlists
                self.allSongs = decoded.allSongs
            }
        } catch {
            AppLogger.shared.log("Failed to load metadata cache: \(error.localizedDescription)", level: .warning)
        }
    }
}
