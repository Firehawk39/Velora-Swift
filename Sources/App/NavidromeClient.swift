import Foundation
import CryptoKit

class NavidromeClient: ObservableObject {
    @Published var artists: [Artist] = [] { didSet { saveMetadataToDisk() } }
    @Published var albums: [Album] = [] { didSet { saveMetadataToDisk() } }
    @Published var recentlyPlayed: [Track] = [] { didSet { saveMetadataToDisk() } }
    @Published var playlists: [Playlist] = [] { didSet { saveMetadataToDisk() } }
    @Published var allSongs: [Track] = [] { didSet { saveMetadataToDisk() } }
    @Published var lastSyncDate: Date?

    var recentTracks: [Track] { recentlyPlayed }

    private(set) var username: String = ""
    var baseUrl: String = ""
    var token: String = ""
    var salt: String = ""
    private let clientName = "VeloraSwift"
    private let apiVersion = "1.16.1"
    
    init() {
        loadCredentials()
        loadMetadataFromDisk()
    }

    func loadCredentials() {
        let savedUrl = UserDefaults.standard.string(forKey: "velora_server_url") ?? ""
        let savedUser = UserDefaults.standard.string(forKey: "velora_username") ?? ""
        let isOnline = UserDefaults.standard.bool(forKey: "velora_online_mode")
        
        AppLogger.shared.log("Client: loadCredentials - URL='\(savedUrl)' user='\(savedUser)' online=\(isOnline)", level: .debug)
        
        if !savedUrl.isEmpty && !savedUser.isEmpty {
            // Try Keychain first
            if let passData = KeychainHelper.shared.read(service: "velora-password", account: savedUser),
               let pass = String(data: passData, encoding: .utf8) {
                configure(url: savedUrl, user: savedUser, pass: pass)
                AppLogger.shared.log("Client: Restored session for \(savedUser) from Keychain", level: .info)
                return
            }
            AppLogger.shared.log("Client: Keychain empty for \(savedUser), using fallback", level: .warning)
        } else {
            AppLogger.shared.log("Client: No saved credentials, using defaults", level: .info)
        }
        
        // Fallback: hardcoded defaults for kiosk deployment (same as reconnectWithCurrentMode)
        let fallbackUrl = isOnline ? "https://sopranosnavi.share.zrok.io" : "http://192.168.1.13:4533"
        let fallbackUser = "tony"
        let fallbackPass = "u4vTyG7BcBxR-9-"
        let finalUrl = savedUrl.isEmpty ? fallbackUrl : savedUrl
        let finalUser = savedUser.isEmpty ? fallbackUser : savedUser
        configure(url: finalUrl, user: finalUser, pass: fallbackPass)
        
        // Persist so next launch is faster
        if savedUrl.isEmpty {
            UserDefaults.standard.set(finalUrl, forKey: "velora_server_url")
            UserDefaults.standard.set(finalUser, forKey: "velora_username")
        }
        
        AppLogger.shared.log("Client: Fallback session configured for \(finalUser) at \(finalUrl)", level: .info)
    }

    // MARK: - Configuration

    func configure(url: String, user: String, pass: String) {
        self.baseUrl = url.trimmingCharacters(in: .init(charactersIn: "/"))
        self.username = user
        self.salt = SubsonicAuth.generateSalt()
        self.token = SubsonicAuth.generateToken(password: pass, salt: self.salt)
        AppLogger.shared.log("Client: Configured for \(user) at \(baseUrl)", level: .info)
    }

    // MARK: - URL Construction

    func buildUrl(method: String, params: [String: String] = [:], extraItems: [URLQueryItem] = []) -> URL? {
        guard !baseUrl.isEmpty else { return nil }
        
        // Ensure the URL is properly formed (handle missing http prefix)
        var finalBase = baseUrl
        if !finalBase.hasPrefix("http") {
            finalBase = "http://\(finalBase)"
        }
        
        var components = URLComponents(string: "\(finalBase)/rest/\(method)")
        
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
        
        let url = getMetadataURL()
        try? FileManager.default.removeItem(at: url)
        
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
        getDocumentsDirectory().appendingPathComponent("velora_metadata.json")
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    struct CachedMetadata: Codable {
        let artists: [Artist]
        let albums: [Album]
        let recentlyPlayed: [Track]
        let playlists: [Playlist]
        let allSongs: [Track]
        let lastSyncDate: Date?
    }

    func saveMetadataToDisk() {
        let meta = CachedMetadata(
            artists: self.artists,
            albums: self.albums,
            recentlyPlayed: self.recentlyPlayed,
            playlists: self.playlists,
            allSongs: self.allSongs,
            lastSyncDate: self.lastSyncDate
        )
        DispatchQueue.global(qos: .background).async {
            do {
                let data = try JSONEncoder().encode(meta)
                try data.write(to: self.getMetadataURL())
            } catch {
                AppLogger.shared.log("Cache: Failed to save metadata - \(error.localizedDescription)", level: .warning)
            }
        }
    }

    func loadMetadataFromDisk() {
        let fileUrl = getMetadataURL()
        let oldFileUrl = getDocumentsDirectory().appendingPathComponent("metadata.json")
        
        // Migration check
        let finalUrl: URL
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            finalUrl = fileUrl
        } else if FileManager.default.fileExists(atPath: oldFileUrl.path) {
            finalUrl = oldFileUrl
            AppLogger.shared.log("Offline Check: Found legacy metadata file. Migrating...", level: .info)
        } else {
            AppLogger.shared.log("Offline Check: No metadata found on disk.", level: .info)
            return
        }
        
        do {
            let data = try Data(contentsOf: finalUrl)
            let decoded = try JSONDecoder().decode(CachedMetadata.self, from: data)
            
            DispatchQueue.main.async {
                self.artists = decoded.artists
                self.albums = decoded.albums
                self.recentlyPlayed = decoded.recentlyPlayed
                self.playlists = decoded.playlists
                self.allSongs = decoded.allSongs
                self.lastSyncDate = decoded.lastSyncDate
                AppLogger.shared.log("Offline Check: Successfully loaded \(decoded.artists.count) artists from cache.", level: .info)
            }
            
            // Clean up old file after successful migration
            if finalUrl == oldFileUrl {
                try? FileManager.default.moveItem(at: oldFileUrl, to: fileUrl)
            }
        } catch {
            AppLogger.shared.log("Offline Check: Failed to decode cache - \(error.localizedDescription)", level: .error)
        }
    }
}
