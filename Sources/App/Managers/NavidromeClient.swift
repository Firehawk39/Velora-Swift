import Foundation
import CryptoKit

class NavidromeClient: ObservableObject {
    static let shared = NavidromeClient()
    
    @Published var artists: [Artist] = []
    @Published var albums: [Album] = []
    @Published var recentlyPlayed: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var allSongs: [Track] = []

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

    func getDownloadUrl(id: String) -> URL? {
        buildUrl(method: "download.view", params: ["id": id])
    }

    /// Fetches synced (LRC) or plain lyrics via the Subsonic getLyrics endpoint.
    func fetchLyrics(artist: String, title: String, completion: @escaping (String?) -> Void) {
        guard let url = buildUrl(method: "getLyrics.view", params: ["artist": artist, "title": title]) else {
            completion(nil); return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion(nil); return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let value = decoded.subsonicResponse?.lyrics?.value
                DispatchQueue.main.async { completion(value) }
            } catch { DispatchQueue.main.async { completion(nil) } }
        }.resume()
    }

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

    // MARK: - Cache Size (not in API extension)

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
}
