import Foundation

class DiscogsManager: ObservableObject {
    static let shared = DiscogsManager()
    
    private init() {}
    
    private var discogsToken: String? {
        KeychainHelper.shared.read(service: "velora-discogs-token", account: "default")
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    
    // Throttling for Discogs (60 requests per minute for authenticated users)
    private actor Throttler {
        private var lastRequestTime: Date = .distantPast
        private let minRequestInterval: TimeInterval = 1.1 // Slightly over 1s for safety
        
        func wait() async {
            let now = Date()
            let timeSinceLast = now.timeIntervalSince(lastRequestTime)
            let waitTime = max(0, minRequestInterval - timeSinceLast)
            
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            lastRequestTime = Date()
        }
    }
    
    private let throttler = Throttler()

    private func performThrottledRequest(url: URL, retryCount: Int = 0) async -> Data? {
        await throttler.wait()
        
        var request = URLRequest(url: url)
        request.setValue("Velora/1.1 ( +https://github.com/Firehawk39/Velora-Swift )", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 && retryCount < 3 {
                    let backoff = pow(2.0, Double(retryCount)) * 5.0 // Discogs 429s are strict, back off more
                    AppLogger.shared.log("Discogs: Rate Limited (429). Retrying in \(backoff)s...", level: .warning)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    return await performThrottledRequest(url: url, retryCount: retryCount + 1)
                }
                
                if http.statusCode != 200 {
                    AppLogger.shared.log("Discogs: HTTP Error \(http.statusCode) for \(url.absoluteString)", level: .error)
                    return nil
                }
            }
            return data
        } catch {
            AppLogger.shared.log("Discogs: Network error: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
    
    func searchAlbum(artist: String, album: String) async -> DiscogsAlbum? {
        guard let token = discogsToken else { return nil }
        
        let query = "\(artist) - \(album)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.discogs.com/database/search?q=\(query)&type=release&token=\(token)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        if let data = await performThrottledRequest(url: url) {
            do {
                let response = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
                return response.results.first
            } catch {
                AppLogger.shared.log("Discogs: Decoding error: \(error)", level: .error)
            }
        }
        return nil
    }
    
    func fetchReleaseDetails(id: Int) async -> DiscogsRelease? {
        guard let token = discogsToken else { return nil }
        
        let urlString = "https://api.discogs.com/releases/\(id)?token=\(token)"
        guard let url = URL(string: urlString) else { return nil }
        
        if let data = await performThrottledRequest(url: url) {
            do {
                return try JSONDecoder().decode(DiscogsRelease.self, from: data)
            } catch {
                AppLogger.shared.log("Discogs: Decoding error: \(error)", level: .error)
            }
        }
        return nil
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
