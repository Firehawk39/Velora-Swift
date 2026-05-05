import SwiftUI
import Foundation

/// Manages interaction with Fanart.tv API for artist backdrops and portraits.
/// Features modern async/await architecture and rate limiting.
class FanartManager: ObservableObject {
    static let shared = FanartManager()
    
    @Published var currentBackdrop: UIImage? = nil
    @Published var cachedArtistImages: [String: UIImage] = [:]
    
    private let fileManager = FileManager.default
    private let backdropDir: URL
    private let portraitDir: URL
    
    // Fanart.tv API Key
    private let fanartApiKey = "faceb56eac838d3e1c2a3ed15bf65a80" 
    private let userAgent = "VeloraMusicApp/1.1 ( https://github.com/Firehawk39/Velora-Swift ; admin@velora.ai )"

    private actor Throttler {
        private var lastRequestTime: Date = .distantPast
        private let minRequestInterval: TimeInterval = 0.5 // Fanart.tv is more lenient than MB (2 req/s)
        private var activeFetches = Set<String>()
        
        func wait() async {
            let now = Date()
            let timeSinceLast = now.timeIntervalSince(lastRequestTime)
            let waitTime = max(0, minRequestInterval - timeSinceLast)
            
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            lastRequestTime = Date()
        }
        
        func isFetching(_ key: String) -> Bool {
            activeFetches.contains(key)
        }
        
        func startFetch(_ key: String) {
            activeFetches.insert(key)
        }
        
        func stopFetch(_ key: String) {
            activeFetches.remove(key)
        }
    }
    
    private let throttler = Throttler()
    private var currentArtistName: String?
    private var currentTask: Task<Void, Never>?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.backdropDir = docs.appendingPathComponent("Backdrops", isDirectory: true)
        self.portraitDir = docs.appendingPathComponent("ArtistPortraits", isDirectory: true)
        
        [self.backdropDir, self.portraitDir].forEach { dir in
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            }
        }
    }
    
    // MARK: - Path Helpers
    
    func getBackdropUrl(for artist: String) -> URL {
        let sanitized = sanitizeFileName(artist)
        return self.backdropDir.appendingPathComponent(sanitized + ".jpg")
    }

    func hasBackdrop(for artist: String) -> Bool {
        let fileUrl = getBackdropUrl(for: artist)
        return IntegrityManager.shared.isImageValid(at: fileUrl)
    }

    func getPortraitUrl(for artist: String) -> URL {
        let sanitized = sanitizeFileName(artist)
        return self.portraitDir.appendingPathComponent(sanitized + ".jpg")
    }

    func hasPortrait(for artist: String) -> Bool {
        let fileUrl = getPortraitUrl(for: artist)
        return IntegrityManager.shared.isImageValid(at: fileUrl)
    }
    
    /// Synchronously checks if a backdrop exists in cache and returns it
    func getCachedBackdrop(for artist: String) -> UIImage? {
        let fileUrl = getBackdropUrl(for: artist)
        if FileManager.default.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl) {
            return UIImage(data: data)
        }
        return nil
    }

    // MARK: - Core Async Logic
    
    func fetchBackdrop(for artist: String, mbid: String? = nil) {
        currentTask?.cancel()
        
        currentTask = Task {
            let isNewArtist = self.currentArtistName != artist
            if isNewArtist {
                self.currentArtistName = artist
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        self.currentBackdrop = nil
                    }
                }
            }
            
            if let image = await fetchBackdropAsync(for: artist, mbid: mbid) {
                await MainActor.run {
                    if self.currentArtistName == artist {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            self.currentBackdrop = image
                        }
                    }
                }
            }
        }
    }
    
    func fetchBackdropAsync(for artist: String, mbid: String? = nil) async -> UIImage? {
        // 1. Check Cache
        if let cached = getCachedBackdrop(for: artist) {
            return cached
        }
        
        // 2. Resolve MBID
        let effectiveMBID: String?
        if let mbid = mbid {
            effectiveMBID = mbid
        } else {
            effectiveMBID = await MusicBrainzManager.shared.resolveMBIDAsync(for: artist)
        }
        
        guard let resolvedMBID = effectiveMBID else {
            return nil
        }
        
        // 3. Fetch and Save
        return await fetchImageAsync(mbid: resolvedMBID, artistName: artist, type: .background)
    }
    
    func downloadBackdropSilently(for artist: String, mbid: String? = nil) {
        Task(priority: .background) {
            _ = await fetchBackdropAsync(for: artist, mbid: mbid)
        }
    }
    
    func fetchArtistPortrait(for artist: String, mbid: String? = nil) async -> UIImage? {
        let fileUrl = getPortraitUrl(for: artist)
        
        // 1. Check Cache
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            return image
        }
        
        // 2. Resolve MBID
        let effectiveMBID: String?
        if let mbid = mbid {
            effectiveMBID = mbid
        } else {
            effectiveMBID = await MusicBrainzManager.shared.resolveMBIDAsync(for: artist)
        }
        
        guard let resolvedMBID = effectiveMBID else {
            return nil
        }
        
        // 3. Fetch and Save
        return await fetchImageAsync(mbid: resolvedMBID, artistName: artist, type: .portrait)
    }
    
    // MARK: - Private API Fetchers
    
    private enum FanartType: String { 
        case background = "artistbackground"
        case portrait = "artistthumb"
    }
    
    private func fetchImageAsync(mbid: String, artistName: String, type: FanartType) async -> UIImage? {
        let sanitized = sanitizeFileName(artistName)
        let storageUrl = type == .background ? getBackdropUrl(for: artistName) : getPortraitUrl(for: artistName)
        
        // Prevent redundant simultaneous fetches
        let fetchKey = "\(sanitized)_\(type.rawValue)"
        if await throttler.isFetching(fetchKey) { return nil }
        await throttler.startFetch(fetchKey)
        defer { Task { await throttler.stopFetch(fetchKey) } }
        
        // 1. Get Image URL from Fanart
        let apiUrl = URL(string: "https://webservice.fanart.tv/v3/music/\(mbid)?api_key=\(fanartApiKey)")!
        guard let data = await performThrottledRequest(url: apiUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json[type.rawValue] as? [[String: Any]], !images.isEmpty else {
            return nil
        }
        
        // Select image (stable hash for backdrops, first for portraits)
        let selectedUrlString: String?
        if type == .background {
            let hashValue = stableHash(artistName.lowercased())
            let index = abs(hashValue) % images.count
            selectedUrlString = images[index]["url"] as? String ?? images[index]["url"] as? String
        } else {
            selectedUrlString = images.first?["url"] as? String
        }
        
        guard let urlString = selectedUrlString, let imageUrl = URL(string: urlString) else { return nil }
        
        // 2. Download and Cache
        do {
            let (imageData, _) = try await URLSession.shared.data(from: imageUrl)
            if let image = UIImage(data: imageData) {
                try? imageData.write(to: storageUrl)
                return image
            }
        } catch {
            AppLogger.shared.log("[Fanart] Download error for \(artistName): \(error.localizedDescription)", level: .error)
        }
        
        return nil
    }
    
    private func performThrottledRequest(url: URL, retryCount: Int = 0) async -> Data? {
        await throttler.wait()
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse {
                // Fanart.tv usually uses 429 for rate limiting
                if (http.statusCode == 429 || http.statusCode == 503) && retryCount < 3 {
                    let backoff = pow(2.0, Double(retryCount))
                    AppLogger.shared.log("[Fanart] Rate Limited (\(http.statusCode)). Retrying in \(backoff)s...", level: .warning)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    return await performThrottledRequest(url: url, retryCount: retryCount + 1)
                }
                
                if http.statusCode != 200 {
                    return nil
                }
            }
            
            return data
        } catch {
            if (error as NSError).code != NSURLErrorCancelled {
                AppLogger.shared.log("[Fanart] Network error: \(error.localizedDescription)", level: .error)
            }
            return nil
        }
    }
    
    // MARK: - Helpers
    
    private func stableHash(_ s: String) -> Int {
        var h: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return Int(truncatingIfNeeded: h)
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }
}
