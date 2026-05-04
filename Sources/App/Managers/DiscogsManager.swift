import Foundation

class DiscogsManager: ObservableObject {
    static let shared = DiscogsManager()
    
    private init() {}
    
    private var discogsToken: String? {
        KeychainHelper.shared.read(service: "velora-discogs-token", account: "default")
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    
    func searchAlbum(artist: String, album: String) async -> DiscogsAlbum? {
        guard let token = discogsToken else { return nil }
        
        let query = "\(artist) - \(album)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.discogs.com/database/search?q=\(query)&type=release&token=\(token)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("Velora/1.0 +https://github.com/Firehawk39/Velora-Swift", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
            return response.results.first
        } catch {
            AppLogger.shared.log("Discogs Search Error: \(error)", level: .error)
            return nil
        }
    }
    
    func fetchReleaseDetails(id: Int) async -> DiscogsRelease? {
        guard let token = discogsToken else { return nil }
        
        let urlString = "https://api.discogs.com/releases/\(id)?token=\(token)"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("Velora/1.0 +https://github.com/Firehawk39/Velora-Swift", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(DiscogsRelease.self, from: data)
        } catch {
            AppLogger.shared.log("Discogs Release Error: \(error)", level: .error)
            return nil
        }
    }
}

// MARK: - Models

struct DiscogsSearchResponse: Codable {
    let results: [DiscogsAlbum]
}

struct DiscogsAlbum: Codable, Identifiable {
    let id: Int
    let title: String
    let year: String?
    let genre: [String]?
    let style: [String]?
    let cover_image: String?
    let resource_url: String
}

struct DiscogsRelease: Codable {
    let id: Int
    let title: String
    let year: Int?
    let genres: [String]?
    let styles: [String]?
    let images: [DiscogsImage]?
    let notes: String?
}

struct DiscogsImage: Codable {
    let uri: String
    let type: String
}
