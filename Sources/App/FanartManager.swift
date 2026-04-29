import SwiftUI
import Foundation

class FanartManager: ObservableObject {
    static let shared = FanartManager()
    
    @Published var currentBackdrop: UIImage? = nil
    @Published var cachedArtistImages: [String: UIImage] = [:]
    
    private let fileManager = FileManager.default
    private let backdropDir: URL
    private let portraitDir: URL
    private let fetchQueue = DispatchQueue(label: "com.velora.fanart.fetches")
    
    // Fanart.tv API Key - Provided by user
    private let fanartApiKey = "faceb56eac838d3e1c2a3ed15bf65a80" 
    
    init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        backdropDir = docs.appendingPathComponent("Backdrops", isDirectory: true)
        portraitDir = docs.appendingPathComponent("ArtistPortraits", isDirectory: true)
        
        [backdropDir, portraitDir].forEach { dir in
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            }
        }
    }
    
    // MARK: - Backdrops
    
    private var activeBackdropFetches = Set<String>()
    private var currentArtistName: String?
    
    /// Synchronously checks if a backdrop exists in cache and returns it
    func getCachedBackdrop(for artist: String) -> UIImage? {
        let sanitized = sanitizeFileName(artist)
        let fileName = sanitized + ".jpg"
        let fileUrl = backdropDir.appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl) {
            return UIImage(data: data)
        }
        return nil
    }

    func fetchBackdrop(for artist: String, mbid: String? = nil) {
        // Clear previous state immediately to avoid "sticky" visuals
        DispatchQueue.main.async {
            if self.currentArtistName != artist {
                self.currentBackdrop = nil
                self.currentArtistName = artist
            }
        }
        
        // 1. Check Cache Synchronously first
        if let cached = getCachedBackdrop(for: artist) {
            DispatchQueue.main.async {
                if self.currentBackdrop == nil || self.currentBackdrop?.size != cached.size {
                    self.currentBackdrop = cached
                }
            }
            return
        }
        
        let sanitized = sanitizeFileName(artist)
        let fileUrl = backdropDir.appendingPathComponent(sanitized + ".jpg")
        
        // 2. Prevent duplicate active fetches safely
        var alreadyFetching = false
        fetchQueue.sync {
            alreadyFetching = activeBackdropFetches.contains(sanitized)
            if !alreadyFetching {
                activeBackdropFetches.insert(sanitized)
            }
        }
        if alreadyFetching { return }
        
        let queryFanart = { (resolvedMBID: String) in
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist) { url in
                if let url = url {
                    // Priority: UI fetch
                    self.downloadAndCache(from: url, to: fileUrl, artistName: artist, priority: .high) { image in
                        self.fetchQueue.async { self.activeBackdropFetches.remove(sanitized) }
                    }
                } else {
                    self.fetchQueue.async { self.activeBackdropFetches.remove(sanitized) }
                }
            }
        }
        
        // 3. Resolve MBID and Fetch
        guard let validMBID = mbid, !validMBID.isEmpty else {
            self.getMBID(for: artist) { resolved in
                if let resolved = resolved {
                    queryFanart(resolved)
                } else {
                    self.fetchQueue.async { self.activeBackdropFetches.remove(sanitized) }
                }
            }
            return
        }
        
        queryFanart(validMBID)
    }
    
    func downloadBackdropSilently(for artist: String, mbid: String? = nil) {
        let sanitized = sanitizeFileName(artist)
        let fileUrl = backdropDir.appendingPathComponent(sanitized + ".jpg")
        
        if fileManager.fileExists(atPath: fileUrl.path) { return }
        
        var alreadyFetching = false
        fetchQueue.sync {
            alreadyFetching = activeBackdropFetches.contains(sanitized)
            if !alreadyFetching {
                activeBackdropFetches.insert(sanitized)
            }
        }
        if alreadyFetching { return }
        
        let query = { (resolvedMBID: String) in
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist) { url in
                if let url = url {
                    self.downloadAndCache(from: url, to: fileUrl, artistName: artist, priority: .low) { _ in
                        self.fetchQueue.async { self.activeBackdropFetches.remove(sanitized) }
                    }
                } else {
                    self.fetchQueue.async { self.activeBackdropFetches.remove(sanitized) }
                }
            }
        }
        
        if let mbid = mbid, !mbid.isEmpty {
            query(mbid)
        } else {
            getMBID(for: artist) { resolved in
                if let resolved = resolved { query(resolved) }
                else { self.fetchQueue.async { self.activeBackdropFetches.remove(sanitized) } }
            }
        }
    }
    
    // MARK: - Artist Portraits
    
    func fetchArtistPortrait(for artist: String, mbid: String? = nil, completion: @escaping (UIImage?) -> Void) {
        let sanitized = sanitizeFileName(artist)
        let fileName = sanitized + ".jpg"
        let fileUrl = portraitDir.appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            completion(image)
            return
        }
        
        let queryFanartPortrait = { (resolvedMBID: String) in
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .portrait, artistName: artist) { url in
                if let url = url {
                    self.downloadAndCache(from: url, to: fileUrl, completion: completion)
                } else {
                    completion(nil)
                }
            }
        }
        
        guard let validMBID = mbid, !validMBID.isEmpty else {
            self.getMBID(for: artist) { resolved in
                if let resolved = resolved {
                    queryFanartPortrait(resolved)
                } else {
                    completion(nil)
                }
            }
            return
        }
        
        let originalUrlString = "https://webservice.fanart.tv/v3/music/\(validMBID)?api_key=\(fanartApiKey)"
        self.fetchFromFanart(urlString: originalUrlString, type: .portrait, artistName: artist) { url in
            if let url = url {
                self.downloadAndCache(from: url, to: fileUrl, completion: completion)
            } else {
                self.getMBID(for: artist) { resolved in
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
    
    private func fetchFromFanart(urlString: String, type: FanartType, artistName: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data else { completion(nil); return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if type == .background {
                        if let bgs = json["artistbackground"] as? [[String: Any]], !bgs.isEmpty {
                            // Stable Deterministic Selection: FNV-1a hash ensures consistency across app launches
                            let hashValue = self.stableHash(artistName.lowercased())
                            let index = abs(hashValue) % bgs.count
                            let selected = bgs[index]["url"] as? String
                            completion(selected); return
                        }
                    } else {
                        if let thumbs = json["artistthumb"] as? [[String: Any]], 
                           let first = thumbs.first?["url"] as? String {
                            completion(first); return
                        }
                    }
                }
            } catch { print("Fanart JSON error: \(error)") }
            completion(nil)
        }.resume()
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
    
    private func downloadAndCache(from urlString: String, to localUrl: URL, artistName: String, priority: URLSessionTask.Priority = .default, completion: @escaping (UIImage?) -> Void) {
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.networkServiceType = priority == .high ? .responsiveData : .background
        
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                try? data.write(to: localUrl)
                
                // CRITICAL: Even if this was a "silent" or background fetch, 
                // if the artist is the one we are currently viewing, update the UI!
                DispatchQueue.main.async {
                    if self.currentArtistName == artistName {
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
        task.priority = priority.rawValue
        task.resume()
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }
    
    private func extractPrimaryArtist(_ name: String) -> String {
        let delimiters = [",", "&", "feat.", "ft.", " x ", " vs.", " and "]
        var primary = name
        for delimiter in delimiters {
            if let range = primary.range(of: delimiter, options: .caseInsensitive) {
                primary = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return primary.isEmpty ? name : primary
    }

    private func getMBID(for artistName: String, completion: @escaping (String?) -> Void) {
        let primary = extractPrimaryArtist(artistName)
        let encodedName = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=artist:\(encodedName)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue("VeloraApp/1.0", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let artists = json["artists"] as? [[String: Any]],
               let firstArtist = artists.first,
               let id = firstArtist["id"] as? String {
                completion(id)
            } else {
                completion(nil)
            }
        }.resume()
    }
}
