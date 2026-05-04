import Foundation
import CryptoKit

/// The primary client for communicating with a Navidrome (Subsonic) server.
/// Handles authentication, URL construction, and core data fetching operations.
class NavidromeClient: ObservableObject {
    static let shared = NavidromeClient()
    
    @Published var artists: [Artist] = []
    @Published var albums: [Album] = []
    @Published var recentlyPlayed: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var allSongs: [Track] = []
    @Published var lastFullSync: Date? = nil

    var recentTracks: [Track] { recentlyPlayed }

    private(set) var username: String = ""
    private var baseUrl: String = ""
    private var token: String = ""
    private var salt: String = ""
    private let clientName = "VeloraSwift"
    private let apiVersion = "1.16.1"

    // MARK: - Configuration

    /// Configures the client with server credentials.
    /// - Parameters:
    ///   - url: The base URL of the Navidrome server.
    ///   - user: The username for authentication.
    ///   - pass: The password for authentication.
    func configure(url: String, user: String, pass: String) {
        self.baseUrl = url.trimmingCharacters(in: .init(charactersIn: "/"))
        self.username = user
        self.salt = SubsonicAuth.generateSalt()
        self.token = SubsonicAuth.generateToken(password: pass, salt: self.salt)
    }

    // MARK: - URL Construction

    /// Builds a Subsonic API URL for a given method and parameters.
    /// - Parameters:
    ///   - method: The Subsonic API method (e.g., "getArtists.view").
    ///   - params: A dictionary of query parameters.
    ///   - extraItems: Additional URLQueryItems to append.
    /// - Returns: A fully constructed URL if configuration is valid.
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

    /// Returns the streaming URL for a given track ID.
    func getStreamUrl(id: String) -> URL? {
        buildUrl(method: "stream.view", params: ["id": id])
    }

    /// Returns the cover art URL for a given ID.
    func getCoverArtUrl(id: String) -> String {
        buildUrl(method: "getCoverArt.view", params: ["id": id, "size": "500"])?.absoluteString ?? ""
    }

    /// Returns the download URL for a given track ID.
    func getDownloadUrl(id: String) -> URL? {
        buildUrl(method: "download.view", params: ["id": id])
    }

    /// Fetches synced (LRC) or plain lyrics via the Subsonic getLyrics endpoint.
    func fetchLyrics(artist: String, title: String) async -> String? {
        guard let url = buildUrl(method: "getLyrics.view", params: ["artist": artist, "title": title]) else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            return decoded.subsonicResponse?.lyrics?.value
        } catch {
            AppLogger.shared.log("Navidrome: Error fetching lyrics: \(error)", level: .error)
            return nil
        }
    }

    /// Clears user credentials and local data.
    func logout() {
        let savedUser = UserDefaults.standard.string(forKey: "velora_username") ?? ""
        UserDefaults.standard.removeObject(forKey: "velora_server_url")
        UserDefaults.standard.removeObject(forKey: "velora_username")
        
        if !savedUser.isEmpty {
            KeychainHelper.shared.delete(service: "velora-password", account: savedUser)
        }
        
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

    // MARK: - Cache Size

    /// Calculates the total size of cached media and backdrops.
    func getMediaCacheSize() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mediaDir = docs.appendingPathComponent("Media")
        let backdropDir = docs.appendingPathComponent("Backdrops")

        var totalSize: Int64 = 0
        [mediaDir, backdropDir].forEach { url in
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileUrl as URL in enumerator {
                    if let attrs = try? fileUrl.resourceValues(forKeys: [.fileSizeKey]), let size = attrs.fileSize {
                        totalSize += Int64(size)
                    }
                }
            }
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    // MARK: - API methods are moved to NavidromeClient+API.swift to keep this file manageable.
}

// MARK: - Authentication Helpers

/// Helper for generating Subsonic-compatible authentication tokens and salts.
struct SubsonicAuth {
    /// Generates an MD5 token based on password and salt.
    static func generateToken(password: String, salt: String) -> String {
        let combined = password + salt
        let data = Data(combined.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Generates a random 10-character alphanumeric salt.
    static func generateSalt() -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<10).map { _ in characters.randomElement()! })
    }
}

