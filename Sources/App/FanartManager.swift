import SwiftUI
import Foundation

@MainActor
final class FanartManager: ObservableObject {
    static let shared = FanartManager()
    
    @Published var currentBackdrop: UIImage? = nil
    @Published var cachedArtistImages: [String: UIImage] = [:]
    
    private let fileManager = FileManager.default
    private let backdropDir: URL
    private let portraitDir: URL
    
    // Fanart.tv API Key - Provided by user
    private let fanartApiKey = "faceb56eac838d3e1c2a3ed15bf65a80" 
    
    init() {
        self.backdropDir = VeloraStorage.backdrops
        self.portraitDir = VeloraStorage.artistPortraits
    }
    
    // MARK: - Backdrops
    
    private var activeBackdropFetches = Set<String>()
    private var currentArtistName: String?
    
    /// Synchronously checks if a backdrop exists in cache and returns it
    func getCachedBackdrop(for artist: String) -> UIImage? {
        let sanitized = sanitizeFileName(artist)
        let fileName = sanitized + ".jpg"
        let fileUrl = self.backdropDir.appendingPathComponent(fileName)
        
        if FileManager.default.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl) {
            return UIImage(data: data)
        }
        return nil
    }

    func hasBackdrop(for artist: String) -> Bool {
        let sanitized = sanitizeFileName(artist)
        let fileUrl = self.backdropDir.appendingPathComponent(sanitized + ".jpg")
        return FileManager.default.fileExists(atPath: fileUrl.path)
    }
    
    func hasPortrait(for artist: String) -> Bool {
        let sanitized = sanitizeFileName(artist)
        let fileUrl = self.portraitDir.appendingPathComponent(sanitized + ".jpg")
        return FileManager.default.fileExists(atPath: fileUrl.path)
    }
    
    func fetchBackdrop(for artists: [String], mbid: String? = nil) {
        guard !artists.isEmpty else { return }
        let primaryArtist = artists[0]
        let isNewArtist = self.currentArtistName != primaryArtist
        
        // 1. Check Cache Synchronously BEFORE nilling anything
        for artist in artists {
            if let cached = getCachedBackdrop(for: artist) {
                AppLogger.shared.log("[Fanart] Cache hit for \(artist)")
                self.currentArtistName = primaryArtist
                // Use animation if it's a new artist, otherwise just set it
                if isNewArtist {
                    withAnimation(.easeInOut(duration: 0.6)) { self.currentBackdrop = cached }
                } else {
                    self.currentBackdrop = cached
                }
                return
            }
            
            // Check for negative cache marker (0 byte file)
            let sanitized = sanitizeFileName(artist)
            let fileUrl = self.backdropDir.appendingPathComponent(sanitized + ".jpg")
            if FileManager.default.fileExists(atPath: fileUrl.path),
               let attr = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
               let size = attr[.size] as? Int64, size == 0 {
                continue // Marker found, skip to next artist
            }
        }
        
        // 2. Clear current UI if new artist
        if isNewArtist {
            self.currentArtistName = primaryArtist
            withAnimation(.easeInOut(duration: 0.4)) { self.currentBackdrop = nil }
        }
        
        fetchBackdropRecursive(artists: artists, index: 0, providedMbid: mbid)
    }
    
    private func fetchBackdropRecursive(artists: [String], index: Int, providedMbid: String?) {
        guard index < artists.count else { return }
        let artist = artists[index]
        let primaryArtist = artists[0]
        let sanitized = sanitizeFileName(artist)
        let fileUrl = self.backdropDir.appendingPathComponent(sanitized + ".jpg")
        
        let alreadyFetching = activeBackdropFetches.contains(sanitized)
        if alreadyFetching { return }
        
        guard NetworkMonitor.shared.isConnected else { return }
        
        activeBackdropFetches.insert(sanitized)
        
        let queryFanart: @MainActor @Sendable (String) -> Void = { resolvedMBID in
            AppLogger.shared.log("[Fanart] Querying Fanart.tv for \(artist) (MBID: \(resolvedMBID))")
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist) { url, isEmpty in
                if let url = url {
                    AppLogger.shared.log("[Fanart] Found backdrop URL for \(artist)")
                    self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, priority: URLSessionTask.highPriority) { image in
                        self.activeBackdropFetches.remove(sanitized)
                    }
                } else {
                    if isEmpty {
                        AppLogger.shared.log("[Fanart] No backdrop found for \(artist)")
                        try? Data().write(to: fileUrl)
                    } else {
                        AppLogger.shared.log("[Fanart] Fetch failed/rate-limited for \(artist)")
                    }
                    self.activeBackdropFetches.remove(sanitized)
                    self.fetchBackdropRecursive(artists: artists, index: index + 1, providedMbid: nil)
                }
            }
        }
        
        // 3. Resolve MBID and Fetch
        if index == 0, let validMBID = providedMbid, !validMBID.isEmpty {
            queryFanart(validMBID)
        } else {
            self.getMBID(for: artist, priority: URLSessionTask.highPriority) { resolved in
                if let resolved = resolved {
                    queryFanart(resolved)
                } else {
                    try? Data().write(to: fileUrl)
                    self.activeBackdropFetches.remove(sanitized)
                    self.fetchBackdropRecursive(artists: artists, index: index + 1, providedMbid: nil)
                }
            }
        }
    }
    
    func downloadBackdropSilently(for artists: [String], mbid: String? = nil) async {
        guard !artists.isEmpty else { return }
        let primaryArtist = artists[0]
        
        for (index, artist) in artists.enumerated() {
            let sanitized = sanitizeFileName(artist)
            let fileUrl = backdropDir.appendingPathComponent(sanitized + ".jpg")
            
            if fileManager.fileExists(atPath: fileUrl.path) {
                if let attr = try? fileManager.attributesOfItem(atPath: fileUrl.path), let size = attr[.size] as? Int64, size > 0 {
                    return // Found a valid image!
                }
                if index == artists.count - 1 { return } // Last fallback artist has a marker, we're done
                continue // Current artist has marker, try next
            }
            
            let alreadyFetching = activeBackdropFetches.contains(sanitized)
            if !alreadyFetching { activeBackdropFetches.insert(sanitized) }
            if alreadyFetching { return }
            
            guard NetworkMonitor.shared.isConnected else {
                self.activeBackdropFetches.remove(sanitized)
                return
            }
            
            let success: Bool = await withCheckedContinuation { continuation in
                let query: @MainActor @Sendable (String) -> Void = { resolvedMBID in
                    let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
                    self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist, priority: URLSessionTask.lowPriority) { url, isEmpty in
                        if let url = url {
                            self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, priority: URLSessionTask.lowPriority) { _ in
                                self.activeBackdropFetches.remove(sanitized)
                                continuation.resume(returning: true)
                            }
                        } else {
                            if isEmpty {
                                try? Data().write(to: fileUrl)
                            }
                            self.activeBackdropFetches.remove(sanitized)
                            continuation.resume(returning: false)
                        }
                    }
                }
                
                if index == 0, let validMBID = mbid, !validMBID.isEmpty {
                    Task { @MainActor in query(validMBID) }
                } else {
                    getMBID(for: artist, priority: URLSessionTask.lowPriority) { resolved in
                        if let resolved = resolved {
                            Task { @MainActor in query(resolved) }
                        } else {
                            if isEmpty {
                                try? Data().write(to: fileUrl)
                            }
                            self.activeBackdropFetches.remove(sanitized)
                            continuation.resume(returning: false)
                        }
                    }
                }
            }
            
            if success { return } // We got one, stop cascading
        }
    }
    
    // MARK: - Artist Portraits
    
    func fetchArtistPortrait(for artist: String, mbid: String? = nil, completion: @escaping @Sendable @MainActor (UIImage?) -> Void) {
        let sanitized = sanitizeFileName(artist)
        let fileName = sanitized + ".jpg"
        let fileUrl = portraitDir.appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            completion(image)
            return
        }
        
        guard NetworkMonitor.shared.isConnected else {
            completion(nil)
            return
        }
        
        let apiKey = self.fanartApiKey
        let queryFanartPortrait: @Sendable @MainActor (String) -> Void = { [weak self] resolvedMBID in
            guard let self = self else { completion(nil); return }
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(apiKey)"
            self.fetchFromFanart(urlString: urlString, type: .portrait, artistName: artist, priority: URLSessionTask.highPriority) { url, isEmpty in
                if let url = url {
                    self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: artist, completion: completion)
                } else {
                    completion(nil)
                }
            }
        }
        
        guard let validMBID = mbid, !validMBID.isEmpty else {
            self.getMBID(for: artist) { [weak self] resolved in
                guard self != nil else { completion(nil); return }
                if let resolved = resolved {
                    queryFanartPortrait(resolved)
                } else {
                    completion(nil)
                }
            }
            return
        }
        
        let originalUrlString = "https://webservice.fanart.tv/v3/music/\(validMBID)?api_key=\(fanartApiKey)"
        self.fetchFromFanart(urlString: originalUrlString, type: .portrait, artistName: artist, priority: URLSessionTask.highPriority) { [weak self] url, isEmpty in
            guard let self = self else { completion(nil); return }
            if let url = url {
                self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: artist, priority: URLSessionTask.highPriority, completion: completion)
            } else {
                self.getMBID(for: artist, priority: URLSessionTask.highPriority) { resolved in
                    if let resolved = resolved, resolved != validMBID {
                        queryFanartPortrait(resolved)
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }
    
    // MARK: - API Helpers
    
    private enum FanartType { case background, portrait }
    
    nonisolated private func fetchFromFanart(urlString: String, type: FanartType, artistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (String?, Bool) -> Void) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil, false) }
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                let desc = error.localizedDescription
                DispatchQueue.main.async {
                    AppLogger.shared.log("[Fanart] Network error for \(artistName): \(desc)")
                }
            }
            guard let data = data else {
                DispatchQueue.main.async { completion(nil, false) }
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    // Artist genuinely not found on Fanart.tv, this is a true empty result
                    DispatchQueue.main.async { completion(nil, true) }
                    return
                } else if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                    // Rate limit exceeded, DO NOT negative cache!
                    DispatchQueue.main.async { completion(nil, false) }
                    return
                }
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if type == .background {
                        if let bgs = json["artistbackground"] as? [[String: Any]], !bgs.isEmpty {
                            let hashValue = self.stableHash(artistName.lowercased())
                            let index = abs(hashValue) % bgs.count
                            let selected = bgs[index]["url"] as? String
                            DispatchQueue.main.async { completion(selected, false) }
                            return
                        } else {
                            // Valid JSON but no background
                            DispatchQueue.main.async { completion(nil, true) }
                            return
                        }
                    } else {
                        if let thumbs = json["artistthumb"] as? [[String: Any]], 
                           let first = thumbs.first?["url"] as? String {
                            DispatchQueue.main.async { completion(first, false) }
                            return
                        } else {
                            // Valid JSON but no thumbs
                            DispatchQueue.main.async { completion(nil, true) }
                            return
                        }
                    }
                }
            } catch { print("Fanart JSON error: \(error)") }
            DispatchQueue.main.async { completion(nil, false) }
        }
        task.priority = priority
        task.resume()
    }
    
    // MARK: - Helpers
    
    nonisolated private func stableHash(_ s: String) -> Int {
        var h: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return Int(truncatingIfNeeded: h)
    }
    
    nonisolated private func downloadAndCache(from urlString: String, to localUrl: URL, primaryArtistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (UIImage?) -> Void) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil, false) }
            return
        }
        
        var request = URLRequest(url: url)
        request.networkServiceType = priority == URLSessionTask.highPriority ? .responsiveData : .background
        
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                try? data.write(to: localUrl)
                
                // CRITICAL: Even if this was a "silent" or background fetch, 
                // if the artist is the one we are currently viewing, update the UI!
                DispatchQueue.main.async {
                    if self.currentArtistName == primaryArtistName {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            self.currentBackdrop = image
                        }
                    }
                    completion(image)
                }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
        task.priority = priority
        task.resume()
    }
    
    nonisolated private func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }
    
    nonisolated private func extractPrimaryArtist(_ name: String) -> String {
        let delimiters = [",", "&", "feat.", "ft.", " x ", " vs.", " and "]
        var primary = name
        for delimiter in delimiters {
            if let range = primary.range(of: delimiter, options: .caseInsensitive) {
                primary = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return primary.isEmpty ? name : primary
    }

    nonisolated private func getMBID(for artistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (String?) -> Void) {
        let primary = extractPrimaryArtist(artistName)
        let encodedName = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // Use exact name query to improve accuracy
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=artist:\"\(encodedName)\"&fmt=json"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("VeloraApp/1.0 ( https://github.com/Firehawk39/Velora-Swift )", forHTTPHeaderField: "User-Agent")
        
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let artists = json["artists"] as? [[String: Any]],
               let firstArtist = artists.first,
               let id = firstArtist["id"] as? String {
                DispatchQueue.main.async { completion(id) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
        task.priority = priority
        task.resume()
    }
}
