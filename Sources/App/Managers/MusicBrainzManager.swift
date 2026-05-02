import SwiftUI
import Foundation

struct MBArtistInfo {
    let mbid: String
    let country: String?
    let type: String?
    let lifeSpan: String?
    let area: String?
    let disambiguation: String?
    let annotation: String?
    var biography: String? = nil
}

struct MBAlbumInfo {
    let mbid: String
    let firstReleaseDate: String?
    let label: String?
    let barcode: String?
    let annotation: String?
}

class MusicBrainzManager: ObservableObject {
    static let shared = MusicBrainzManager()
    
    @Published var currentArtistInfo: MBArtistInfo? = nil
    @Published var currentAlbumInfo: MBAlbumInfo? = nil
    @Published var isLoading = false
    @Published var metadataProgress: Double = 0.0
    
    private var nameToMBIDCache: [String: String] = [:]
    private let cacheFile: URL
    private let metadataDir: URL
    private let fileManager = FileManager.default
    private let userAgent = "VeloraMusicApp/1.1 ( https://github.com/Firehawk39/Velora-Swift ; admin@velora.ai )"
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.metadataDir = docs.appendingPathComponent("Metadata", isDirectory: true)
        self.cacheFile = docs.appendingPathComponent("name_to_mbid.json")
        
        if !FileManager.default.fileExists(atPath: self.metadataDir.path) {
            try? FileManager.default.createDirectory(at: self.metadataDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Load cache
        if let data = try? Data(contentsOf: self.cacheFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            self.nameToMBIDCache = json
        }
    }
    
    private func saveCache() {
        if let data = try? JSONEncoder().encode(nameToMBIDCache) {
            try? data.write(to: cacheFile)
        }
    }
    
    func getMetadataUrl(for artistName: String) -> URL {
        guard let mbid = nameToMBIDCache[artistName] else {
            return metadataDir.appendingPathComponent("artist_unknown.json")
        }
        let fileName = "artist_" + (mbid) + ".json"
        return self.metadataDir.appendingPathComponent(fileName)
    }

    func hasArtistMetadata(for artistName: String) -> Bool {
        let fileUrl = getMetadataUrl(for: artistName)
        return IntegrityManager.shared.isMetadataValid(at: fileUrl)
    }
    
    func hasAlbumMetadata(albumName: String, artistName: String) -> Bool {
        guard let mbid = nameToMBIDCache["\(artistName)_\(albumName)"] else { return false }
        let fileName = "album_" + (mbid) + ".json"
        let fileUrl = self.metadataDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileUrl.path)
    }
    
    func fetchAboutArtist(artistName: String, mbid: String? = nil) {
        DispatchQueue.main.async { 
            self.isLoading = true
            self.metadataProgress = 0.1
        }
        
        let fetchDetails = { (resolvedMBID: String) in
            DispatchQueue.main.async { self.metadataProgress = 0.4 }
            let fileName = "artist_" + (resolvedMBID) + ".json"
            let fileUrl = self.metadataDir.appendingPathComponent(fileName)
            
            // Check disk cache
            if self.fileManager.fileExists(atPath: fileUrl.path),
               let data = try? Data(contentsOf: fileUrl),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                let life = json["life-span"] as? [String: Any]
                let begin = life?["begin"] as? String
                let end = life?["end"] as? String
                let lifeStr = begin != nil ? "\(begin!)\(end != nil ? " to \(end!)" : " — Present")" : nil
                
                let info = MBArtistInfo(
                    mbid: resolvedMBID,
                    country: json["country"] as? String,
                    type: json["type"] as? String,
                    lifeSpan: lifeStr,
                    area: (json["area"] as? [String: Any])?["name"] as? String,
                    disambiguation: json["disambiguation"] as? String,
                    annotation: json["annotation"] as? String
                )
                DispatchQueue.main.async { 
                    self.currentArtistInfo = info
                    self.metadataProgress = 1.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.isLoading = false
                    }
                }
                return
            }

            let urlString = "https://musicbrainz.org/ws/2/artist/\(resolvedMBID)?fmt=json&inc=aliases+tags+annotation"
            guard let url = URL(string: urlString) else { return }
            
            var request = URLRequest(url: url)
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
            
            URLSession.shared.dataTask(with: request) { data, _, _ in
                DispatchQueue.main.async { self.metadataProgress = 0.7 }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { 
                    DispatchQueue.main.async { self.isLoading = false }
                    return 
                }
                
                let life = json["life-span"] as? [String: Any]
                let begin = life?["begin"] as? String
                let end = life?["end"] as? String
                let lifeStr = begin != nil ? "\(begin!)\(end != nil ? " to \(end!)" : " — Present")" : nil
                
                    let info = MBArtistInfo(
                        mbid: resolvedMBID,
                        country: json["country"] as? String,
                        type: json["type"] as? String,
                        lifeSpan: lifeStr,
                        area: (json["area"] as? [String: Any])?["name"] as? String,
                        disambiguation: json["disambiguation"] as? String,
                        annotation: json["annotation"] as? String ?? (json["annotation"] as? [String: Any])?["text"] as? String
                    )
                    
                    DispatchQueue.main.async { 
                        self.currentArtistInfo = info
                        self.metadataProgress = 1.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.isLoading = false
                        }
                    }
            }.resume()
        }
        
        if let mbid = mbid, !mbid.isEmpty {
            fetchDetails(mbid)
        } else {
            resolveMBID(for: artistName) { resolved in
                if let resolved = resolved {
                    fetchDetails(resolved)
                } else {
                    DispatchQueue.main.async { self.isLoading = false }
                }
            }
        }
    }
    
    func fetchAboutAlbum(albumName: String, artistName: String, mbid: String? = nil) {
        self.isLoading = true
        
        let fetchDetails = { (resolvedMBID: String) in
            let fileName = "album_" + (resolvedMBID) + ".json"
            let fileUrl = self.metadataDir.appendingPathComponent(fileName)
            
            if self.fileManager.fileExists(atPath: fileUrl.path),
               let data = try? Data(contentsOf: fileUrl),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                let labels = json["label-info"] as? [[String: Any]]
                let labelName = (labels?.first?["label"] as? [String: Any])?["name"] as? String
                
                let info = MBAlbumInfo(
                    mbid: resolvedMBID,
                    firstReleaseDate: json["date"] as? String,
                    label: labelName,
                    barcode: json["barcode"] as? String,
                    annotation: json["annotation"] as? String
                )
                DispatchQueue.main.async { 
                    self.currentAlbumInfo = info
                    self.isLoading = false
                }
                return
            }

            let urlString = "https://musicbrainz.org/ws/2/release/\(resolvedMBID)?fmt=json&inc=labels+recordings"
            guard let url = URL(string: urlString) else { return }
            
            var request = URLRequest(url: url)
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
            
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    DispatchQueue.main.async { self.isLoading = false }
                    return
                }
                
                let labels = json["label-info"] as? [[String: Any]]
                let labelName = (labels?.first?["label"] as? [String: Any])?["name"] as? String
                
                self.fetchAnnotation(entityMBID: resolvedMBID) { annotation in
                    json["annotation"] = annotation
                    // Save to disk
                    if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                        try? savedData.write(to: fileUrl)
                    }

                    let info = MBAlbumInfo(
                        mbid: resolvedMBID,
                        firstReleaseDate: json["date"] as? String,
                        label: labelName,
                        barcode: json["barcode"] as? String,
                        annotation: annotation
                    )
                    
                    DispatchQueue.main.async { 
                        self.currentAlbumInfo = info
                        self.isLoading = false
                    }
                }
            }.resume()
        }
        
        if let mbid = mbid, !mbid.isEmpty {
            fetchDetails(mbid)
        } else {
            resolveAlbumMBID(album: albumName, artist: artistName) { resolved in
                if let resolved = resolved {
                    fetchDetails(resolved)
                } else {
                    DispatchQueue.main.async { self.isLoading = false }
                }
            }
        }
    }
    
    // MARK: - Robust MBID Resolution
    
    /// Resolves an artist name to a MusicBrainz ID with multiple fallbacks and robust matching
    func resolveMBID(for artist: String, completion: @escaping (String?) -> Void) {
        // 1. Check persistent cache first
        if let cached = nameToMBIDCache[artist] {
            completion(cached)
            return
        }
        
        let primary = extractPrimaryArtist(artist)
        AppLogger.shared.log("[MBID] Resolving robustly: \"\(artist)\" -> Primary: \"\(primary)\"", level: .info)
        
        // Use a recursive search strategy
        performMBIDResolution(primary: primary, step: .exactMusicBrainz) { mbid in
            if let mbid = mbid {
                self.nameToMBIDCache[artist] = mbid
                self.nameToMBIDCache[primary] = mbid // Also cache the primary name
                self.saveCache()
                AppLogger.shared.log("[MBID] Successfully resolved \"\(artist)\" to \(mbid)", level: .info)
            } else {
                AppLogger.shared.log("[MBID] Failed to resolve \"\(artist)\" after all fallbacks", level: .error)
            }
            completion(mbid)
        }
    }
    
    private enum ResolutionStep {
        case exactMusicBrainz
        case looseMusicBrainz
        case theAudioDB
    }
    
    private func performMBIDResolution(primary: String, step: ResolutionStep, retryCount: Int = 0, completion: @escaping (String?) -> Void) {
        switch step {
        case .exactMusicBrainz:
            // First attempt: Exact artist name match
            let query = "artist:\"\(primary)\""
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                completion(nil)
                return
            }
            let urlString = "https://musicbrainz.org/ws/2/artist?query=\(encodedQuery)&fmt=json"
            queryMusicBrainz(urlString: urlString, primary: primary, retryCount: retryCount) { mbid in
                if let mbid = mbid {
                    completion(mbid)
                } else {
                    self.performMBIDResolution(primary: primary, step: .looseMusicBrainz, completion: completion)
                }
            }
            
        case .looseMusicBrainz:
            // Second attempt: Loose search with just the name
            let query = primary
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                completion(nil)
                return
            }
            let urlString = "https://musicbrainz.org/ws/2/artist?query=\(encodedQuery)&fmt=json"
            queryMusicBrainz(urlString: urlString, primary: primary, retryCount: retryCount) { mbid in
                if let mbid = mbid {
                    completion(mbid)
                } else {
                    self.performMBIDResolution(primary: primary, step: .theAudioDB, completion: completion)
                }
            }
            
        case .theAudioDB:
            // Final attempt: TheAudioDB search
            let encoded = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "https://www.theaudiodb.com/api/v1/json/2/search.php?s=\(encoded)"
            
            URLSession.shared.dataTask(with: URL(string: urlString)!) { data, _, _ in
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
            }.resume()
        }
    }
    
    private func queryMusicBrainz(urlString: String, primary: String, retryCount: Int, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 503 && retryCount < 3 {
                    // Rate limited - wait and retry
                    let delay = Double(retryCount + 1) * 1.5
                    AppLogger.shared.log("[MBID] MusicBrainz 503 (Rate Limited). Retrying in \(delay)s...", level: .warning)
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.queryMusicBrainz(urlString: urlString, primary: primary, retryCount: retryCount + 1, completion: completion)
                    }
                    return
                }
                if http.statusCode != 200 {
                    AppLogger.shared.log("[MBID] MusicBrainz returned \(http.statusCode)", level: .error)
                    completion(nil); return
                }
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]] else {
                completion(nil); return
            }
            
            // Validation Logic: Find the best match
            for artistObj in artists {
                let mbid = artistObj["id"] as? String
                let name = artistObj["name"] as? String ?? ""
                let score = Int(artistObj["score"] as? String ?? "0") ?? 0
                let aliases = (artistObj["aliases"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                
                // If score is high (above 85) and name or alias matches case-insensitively
                let nameMatches = name.lowercased() == primary.lowercased() || 
                                 name.lowercased().contains(primary.lowercased()) ||
                                 aliases.contains(where: { $0.lowercased() == primary.lowercased() })
                
                if score >= 85 && nameMatches {
                    completion(mbid)
                    return
                }
                // Fallback: If score is very high (100) and the primary search term is contained in the name
                if score >= 95 && name.lowercased().contains(primary.lowercased()) {
                    completion(mbid)
                    return
                }
            }
            
            AppLogger.shared.log("[MBID] No high-confidence match found for \"\(primary)\" in results", level: .warning)
            completion(nil)
        }.resume()
    }

    private func extractPrimaryArtist(_ name: String) -> String {
        // Clean common artist naming noise
        let delimiters = [",", "&", "feat.", "ft.", " x ", " vs.", " and ", " - ", " / "]
        var primary = name
        
        // Remove content in brackets like (Official Video) or [Remix]
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
        
        // Final trim and return
        let result = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? name : result
    }
    
    private func resolveAlbumMBID(album: String, artist: String, completion: @escaping (String?) -> Void) {
        let query = "release:\"\(album)\" AND artist:\"\(artist)\""
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let releases = json["releases"] as? [[String: Any]],
               let first = releases.first {
                completion(first["id"] as? String)
            } else {
                completion(nil)
            }
        }.resume()
    }
    
    private func fetchAnnotation(entityMBID: String, completion: @escaping (String?) -> Void) {
        let urlString = "https://musicbrainz.org/ws/2/annotation/?query=entity:\(entityMBID)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let annotations = json["annotations"] as? [[String: Any]],
               let first = annotations.first {
                completion(first["text"] as? String)
            } else {
                completion(nil)
            }
        }.resume()
    }

    // MARK: - Silent Bulk Fetchers

    func downloadMetadataSilently(for artistName: String) async {
        // Resolve using the robust method
        return await withCheckedContinuation { continuation in
            resolveMBID(for: artistName) { mbid in
                guard let mbid = mbid else {
                    continuation.resume()
                    return
                }
                
                Task {
                    let fileName = "artist_" + (mbid) + ".json"
                    let fileUrl = self.metadataDir.appendingPathComponent(fileName)
                    
                    if self.fileManager.fileExists(atPath: fileUrl.path) {
                        continuation.resume()
                        return
                    }

                    let urlString = "https://musicbrainz.org/ws/2/artist/\(mbid)?fmt=json&inc=aliases+tags"
                    guard let url = URL(string: urlString) else { continuation.resume(); return }
                    var request = URLRequest(url: url)
                    request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
                    
                    do {
                        let (data, _) = try await URLSession.shared.data(for: request)
                        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { 
                            continuation.resume(); return 
                        }
                        
                        let annotation = await self.fetchAnnotationAsync(entityMBID: mbid)
                        json["annotation"] = annotation
                        if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                            try? savedData.write(to: fileUrl)
                        }
                    } catch { }
                    continuation.resume()
                }
            }
        }
    }

    func downloadAlbumMetadataSilently(albumName: String, artistName: String) async {
        let resolved = await resolveAlbumMBIDAsync(album: albumName, artist: artistName)
        guard let mbid = resolved else { return }
        
        self.nameToMBIDCache["\(artistName)_\(albumName)"] = mbid
        saveCache()
        
        let fileName = "album_" + (mbid) + ".json"
        let fileUrl = self.metadataDir.appendingPathComponent(fileName)
        
        if self.fileManager.fileExists(atPath: fileUrl.path) { return }

        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?fmt=json&inc=labels+recordings"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            let annotation = await fetchAnnotationAsync(entityMBID: mbid)
            json["annotation"] = annotation
            if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                try? savedData.write(to: fileUrl)
            }
        } catch { }
    }
    
    private func resolveMBIDAsync(for artist: String) async -> String? {
        return await withCheckedContinuation { continuation in
            resolveMBID(for: artist) { mbid in
                continuation.resume(returning: mbid)
            }
        }
    }
    
    private func resolveAlbumMBIDAsync(album: String, artist: String) async -> String? {
        if let cached = nameToMBIDCache["\(artist)_\(album)"] { return cached }
        
        let query = "release:\"\(album)\" AND artist:\"\(artist)\""
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let releases = json?["releases"] as? [[String: Any]]
            return releases?.first?["id"] as? String
        } catch { return nil }
    }
    
    private func fetchAnnotationAsync(entityMBID: String) async -> String? {
        let urlString = "https://musicbrainz.org/ws/2/annotation/?query=entity:\(entityMBID)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let annotations = json?["annotations"] as? [[String: Any]]
            return annotations?.first?["text"] as? String
        } catch { return nil }
    }
}
