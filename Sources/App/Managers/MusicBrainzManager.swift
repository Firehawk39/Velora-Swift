import Foundation
import UIKit

/// Manages interaction with MusicBrainz API for artist metadata and MBID resolution.
/// Now features local caching to prevent redundant network hits.
class MusicBrainzManager: ObservableObject {
    static let shared = MusicBrainzManager()
    
    @Published var currentArtistInfo: ArtistInfo? = nil
    @Published var currentAlbumInfo: AlbumInfo? = nil
    
    private let userAgent = "VeloraMusicApp/1.1 ( https://github.com/Firehawk39/Velora-Swift ; admin@velora.ai )"
    private let cacheFile = "mbid_cache.json"
    
    // In-memory cache for fast lookups
    private var mbidCache: [String: String] = [:]
    private let mbidCacheLock = NSLock()
    
    // Persistent storage for name-to-MBID mappings
    private var nameToMBIDCache: [String: String] = [:]
    
    init() {
        loadCache()
    }
    
    private func loadCache() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileUrl = docs.appendingPathComponent(cacheFile)
        
        if let data = try? Data(contentsOf: fileUrl),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.nameToMBIDCache = decoded
            AppLogger.shared.log("[MBID] Loaded \(decoded.count) entries from persistent cache")
        }
    }
    
    private func saveCache() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileUrl = docs.appendingPathComponent(cacheFile)
        
        if let data = try? JSONEncoder().encode(nameToMBIDCache) {
            try? data.write(to: fileUrl)
        }
    }
    
    func fetchAboutArtist(artistName: String, mbid: String? = nil) {
        if let mbid = mbid, !mbid.isEmpty {
            fetchArtistWithMBID(mbid: mbid, name: artistName)
        } else {
            resolveMBID(for: artistName) { [weak self] resolvedMBID in
                if let mbid = resolvedMBID {
                    self?.fetchArtistWithMBID(mbid: mbid, name: artistName)
                } else {
                    DispatchQueue.main.async {
                        self?.currentArtistInfo = ArtistInfo(name: artistName, biography: "No biography available.")
                    }
                }
            }
        }
    }
    
    private func fetchArtistWithMBID(mbid: String, name: String) {
        let urlString = "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=aliases+genres+annotation&fmt=json"
        guard let url = URL(string: urlString) else { return }
        
        performMusicBrainzRequest(url: url) { [weak self] data in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            let genres = (json["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let bioSnippet = (json["annotation"] as? [String: Any])?["text"] as? String ?? ""
            
            DispatchQueue.main.async {
                self?.currentArtistInfo = ArtistInfo(
                    name: name,
                    biography: bioSnippet.isEmpty ? "Biographical data is being resolved..." : bioSnippet,
                    genres: genres,
                    mbid: mbid
                )
            }
        }
    }
    
    func fetchAboutAlbum(albumName: String, artistName: String, mbid: String? = nil) {
        if let mbid = mbid, !mbid.isEmpty {
            fetchAlbumWithMBID(mbid: mbid, name: albumName)
        } else {
            resolveAlbumMBID(album: albumName, artist: artistName) { [weak self] resolved in
                if let mbid = resolved {
                    self?.fetchAlbumWithMBID(mbid: mbid, name: albumName)
                }
            }
        }
    }
    
    private func fetchAlbumWithMBID(mbid: String, name: String) {
        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?inc=genres+annotation&fmt=json"
        guard let url = URL(string: urlString) else { return }
        
        performMusicBrainzRequest(url: url) { [weak self] data in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            let genres = (json["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            
            DispatchQueue.main.async {
                self?.currentAlbumInfo = AlbumInfo(
                    name: name,
                    genres: genres,
                    mbid: mbid
                )
            }
        }
    }
    
    // MARK: - Robust MBID Resolution
    
    @discardableResult
    func resolveMBID(for artist: String, completion: @escaping (String?) -> Void) -> URLSessionDataTask? {
        // 1. Check persistent cache first
        if let cached = nameToMBIDCache[artist] {
            completion(cached)
            return nil
        }
        
        let primary = extractPrimaryArtist(artist)
        
        // Check in-memory cache
        self.mbidCacheLock.lock()
        if let cached = mbidCache[primary.lowercased()] {
            self.mbidCacheLock.unlock()
            completion(cached)
            return nil
        }
        self.mbidCacheLock.unlock()

        AppLogger.shared.log("[MBID] Resolving robustly: \"\(artist)\" -> Primary: \"\(primary)\"", level: .info)
        
        // Use a recursive search strategy
        return performMBIDResolution(primary: primary, step: .exactMusicBrainz) { mbid in
            if let mbid = mbid {
                self.mbidCacheLock.lock()
                self.mbidCache[primary.lowercased()] = mbid
                self.mbidCacheLock.unlock()
                
                // Also update persistent cache
                DispatchQueue.main.async {
                    self.nameToMBIDCache[artist] = mbid
                    self.saveCache()
                }
            }
            completion(mbid)
        }
    }
    
    private enum ResolutionStep {
        case exactMusicBrainz
        case looseMusicBrainz
        case theAudioDB
    }
    
    @discardableResult
    private func performMBIDResolution(primary: String, step: ResolutionStep, completion: @escaping (String?) -> Void) -> URLSessionDataTask? {
        switch step {
        case .exactMusicBrainz:
            let query = "artist:\"\(primary)\""
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                completion(nil)
                return nil
            }
            let urlString = "https://musicbrainz.org/ws/2/artist?query=\(encodedQuery)&fmt=json"
            return queryMusicBrainz(urlString: urlString, primary: primary) { mbid in
                if let mbid = mbid {
                    completion(mbid)
                } else {
                    _ = self.performMBIDResolution(primary: primary, step: .looseMusicBrainz, completion: completion)
                }
            }
            
        case .looseMusicBrainz:
            let query = primary
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                completion(nil)
                return nil
            }
            let urlString = "https://musicbrainz.org/ws/2/artist?query=\(encodedQuery)&fmt=json"
            return queryMusicBrainz(urlString: urlString, primary: primary) { mbid in
                if let mbid = mbid {
                    completion(mbid)
                } else {
                    _ = self.performMBIDResolution(primary: primary, step: .theAudioDB, completion: completion)
                }
            }
            
        case .theAudioDB:
            let encoded = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "https://www.theaudiodb.com/api/v1/json/2/search.php?s=\(encoded)"
            
            let task = URLSession.shared.dataTask(with: URL(string: urlString)!) { data, _, _ in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let artists = json["artists"] as? [[String: Any]],
                      let first = artists.first,
                      let mbid = first["strMusicBrainzID"] as? String, !mbid.isEmpty else {
                    completion(nil)
                    return
                }
                AppLogger.shared.log("[MBID] Resolved via TheAudioDB fallback: \(mbid)")
                completion(mbid)
            }
            task.resume()
            return task
        }
    }
    
    private func queryMusicBrainz(urlString: String, primary: String, completion: @escaping (String?) -> Void) -> URLSessionDataTask? {
        guard let url = URL(string: urlString) else { completion(nil); return nil }
        
        return self.performMusicBrainzRequest(url: url) { data in
            guard let data = data else { completion(nil); return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let artists = json["artists"] as? [[String: Any]] {
                    
                    // Filter for best match
                    let bestMatch = artists.first { art in
                        let name = (art["name"] as? String)?.lowercased() ?? ""
                        return name == primary.lowercased()
                    } ?? artists.first { art in
                        let score = Int(art["score"] as? String ?? "0") ?? 0
                        return score > 90
                    } ?? artists.first
                    
                    if let mbid = bestMatch?["id"] as? String {
                        completion(mbid)
                    } else {
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }
    }
    
    @discardableResult
    private func performMusicBrainzRequest(url: URL, retryCount: Int = 0, completion: @escaping (Data?) -> Void) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as NSError?, error.code == NSURLErrorCancelled { return }

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 503 && retryCount < 3 {
                    let delay = pow(2.0, Double(retryCount))
                    AppLogger.shared.log("[MBID] 503 Rate Limited. Retrying in \(delay)s...", level: .warning)
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        _ = self.performMusicBrainzRequest(url: url, retryCount: retryCount + 1, completion: completion)
                    }
                    return
                }
                
                if http.statusCode != 200 {
                    AppLogger.shared.log("[MBID] Request failed with status \(http.statusCode)", level: .error)
                    completion(nil)
                    return
                }
            }
            
            if error != nil {
                completion(nil)
                return
            }
            
            completion(data)
        }
        task.resume()
        return task
    }

    private func extractPrimaryArtist(_ name: String) -> String {
        let delimiters = [",", "&", "feat.", "ft.", " x ", " vs.", " and ", " - ", " / "]
        var primary = name
        
        if let bracketRange = primary.range(of: " (") {
            primary = String(primary[..<bracketRange.lowerBound])
        }
        if let bracketRange = primary.range(of: " [") {
            primary = String(primary[..<bracketRange.lowerBound])
        }

        for delimiter in delimiters {
            if let range = primary.range(of: delimiter, options: .caseInsensitive) {
                primary = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        let result = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? name : result
    }
    
    private func resolveAlbumMBID(album: String, artist: String, completion: @escaping (String?) -> Void) {
        let query = "release:\"\(album)\" AND artist:\"\(artist)\""
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        performMusicBrainzRequest(url: url) { data in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let releases = json["releases"] as? [[String: Any]],
               let first = releases.first {
                completion(first["id"] as? String)
            } else {
                completion(nil)
            }
        }
    }
}

struct ArtistInfo {
    let name: String
    var biography: String
    var genres: [String] = []
    var mbid: String? = nil
}

struct AlbumInfo {
    let name: String
    var genres: [String] = []
    var mbid: String? = nil
}
