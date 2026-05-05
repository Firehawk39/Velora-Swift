import Foundation
import UIKit
import os

/// Manages interaction with MusicBrainz API for artist metadata and MBID resolution.
/// Now features local caching to prevent redundant network hits.
class MusicBrainzManager: ObservableObject {
    static let shared = MusicBrainzManager()
    
    @Published var currentArtistInfo: ArtistInfo? = nil
    @Published var currentAlbumInfo: AlbumInfo? = nil
    @Published var isLoading: Bool = false
    @Published var metadataProgress: Double = 0.0
    
    private let userAgent = "VeloraMusicApp/1.1 ( https://github.com/Firehawk39/Velora-Swift ; admin@velora.ai )"
    private let cacheFile = "mbid_cache.json"
    private let fileManager = FileManager.default
    
    private var metadataDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("metadata")
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    // In-memory cache for fast lookups
    private var nameToMBIDCache: [String: String] = [:]
    private var mbidCache: [String: String] = [:]
    private let mbidCacheLock = OSAllocatedUnfairLock(initialState: [String: String]())
    
    // Throttling for MusicBrainz (1 request per second limit)
    private actor Throttler {
        private var lastRequestTime: Date = .distantPast
        private let minRequestInterval: TimeInterval = 1.1
        
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
    
    init() {
        loadCache()
    }
    
    func getMetadataUrl(for artist: String) -> URL {
        let mbid = nameToMBIDCache[artist] ?? "unknown"
        return metadataDir.appendingPathComponent("artist_\(mbid).json")
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
    
    func fetchAboutArtistAsync(artistName: String, mbid: String? = nil) async {
        if let mbid = mbid, !mbid.isEmpty {
            await fetchArtistWithMBID(mbid: mbid, name: artistName)
        } else {
            if let mbid = await resolveMBIDAsync(for: artistName) {
                await fetchArtistWithMBID(mbid: mbid, name: artistName)
            } else {
                await MainActor.run {
                    self.currentArtistInfo = ArtistInfo(name: artistName, biography: "No biography available.")
                }
            }
        }
    }
    
    // Maintain legacy signature for UI compatibility if needed, but mark as Task-wrapped
    func fetchAboutArtist(artistName: String, mbid: String? = nil) {
        Task {
            await fetchAboutArtistAsync(artistName: artistName, mbid: mbid)
        }
    }
    
    func fetchArtistDetailsAsync(mbid: String) async -> (type: String?, area: String?, lifeSpan: String?) {
        let urlString = "https://musicbrainz.org/ws/2/artist/\(mbid)?fmt=json"
        guard let url = URL(string: urlString) else { return (nil, nil, nil) }
        
        guard let data = await performThrottledRequest(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        
        let type = json["type"] as? String
        let area = (json["area"] as? [String: Any])?["name"] as? String
        let lifeSpanObj = json["life-span"] as? [String: Any]
        let begin = lifeSpanObj?["begin"] as? String
        let end = lifeSpanObj?["end"] as? String
        var lifeSpan: String? = nil
        if let b = begin {
            lifeSpan = b + (end != nil ? " – \(end!)" : " – Present")
        }
        
        return (type, area, lifeSpan)
    }
    
    private func fetchArtistWithMBID(mbid: String, name: String) async {
        let urlString = "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=aliases+genres+annotation&fmt=json"
        guard let url = URL(string: urlString) else { return }
        
        guard let data = await performThrottledRequest(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        let genres = (json["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let bioSnippet = (json["annotation"] as? [String: Any])?["text"] as? String ?? ""
        
        let type = json["type"] as? String
        let area = (json["area"] as? [String: Any])?["name"] as? String
        let lifeSpanObj = json["life-span"] as? [String: Any]
        let begin = lifeSpanObj?["begin"] as? String
        let end = lifeSpanObj?["end"] as? String
        var lifeSpan: String? = nil
        if let b = begin {
            lifeSpan = b + (end != nil ? " – \(end!)" : " – Present")
        }
        
        await MainActor.run {
            self.currentArtistInfo = ArtistInfo(
                name: name,
                biography: bioSnippet.isEmpty ? "Biographical data is being resolved..." : bioSnippet,
                genres: genres,
                mbid: mbid,
                type: type,
                area: area,
                lifeSpan: lifeSpan
            )
        }
    }
    
    func fetchAboutAlbumAsync(albumName: String, artistName: String, mbid: String? = nil) async {
        if let mbid = mbid, !mbid.isEmpty {
            await fetchAlbumWithMBID(mbid: mbid, name: albumName)
        } else {
            if let resolved = await resolveAlbumMBIDAsync(album: albumName, artist: artistName) {
                await fetchAlbumWithMBID(mbid: resolved, name: albumName)
            }
        }
    }
    
    func fetchAboutAlbum(albumName: String, artistName: String, mbid: String? = nil) {
        Task {
            await fetchAboutAlbumAsync(albumName: albumName, artistName: artistName, mbid: mbid)
        }
    }
    
    func fetchReleaseDetailsAsync(mbid: String) async -> (title: String?, artist: String?, album: String?, label: String?, releaseDate: String?) {
        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?inc=artist-credits+labels&fmt=json"
        guard let url = URL(string: urlString) else { return (nil, nil, nil, nil, nil) }
        
        guard let data = await performThrottledRequest(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil, nil, nil)
        }
        
        let title = json["title"] as? String
        let album = title // In MusicBrainz, release title is effectively the album name
        let artistCredits = json["artist-credit"] as? [[String: Any]]
        let artist = artistCredits?.first?["name"] as? String
        
        let label = (json["label-info"] as? [[String: Any]])?.first.flatMap { ($0["label"] as? [String: Any])?["name"] as? String }
        let firstReleaseDate = json["date"] as? String
        
        return (title, artist, album, label, firstReleaseDate)
    }
    
    private func fetchAlbumWithMBID(mbid: String, name: String) async {
        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?inc=genres+annotation&fmt=json"
        guard let url = URL(string: urlString) else { return }
        
        guard let data = await performThrottledRequest(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        let genres = (json["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let label = (json["label-info"] as? [[String: Any]])?.first.flatMap { ($0["label"] as? [String: Any])?["name"] as? String }
        let firstReleaseDate = json["date"] as? String
        let annotation = (json["annotation"] as? [String: Any])?["text"] as? String
        
        await MainActor.run {
            self.currentAlbumInfo = AlbumInfo(
                name: name,
                genres: genres,
                mbid: mbid,
                label: label,
                firstReleaseDate: firstReleaseDate,
                annotation: annotation
            )
        }
    }
    
    // MARK: - Robust MBID Resolution
    
    func resolveMBIDAsync(for artist: String) async -> String? {
        // 1. Check persistent cache first
        if let cached = nameToMBIDCache[artist] {
            return cached
        }
        
        let primary = extractPrimaryArtist(artist)
        
        // Check in-memory cache
        if let cached = mbidCacheLock.withLock({ $0[primary.lowercased()] }) {
            return cached
        }

        AppLogger.shared.log("[MBID] Resolving robustly: \"\(artist)\" -> Primary: \"\(primary)\"", level: .info)
        
        // Use a recursive search strategy
        if let mbid = await performMBIDResolutionAsync(primary: primary, step: .exactMusicBrainz) {
            mbidCacheLock.withLock { cache in
                cache[primary.lowercased()] = mbid
            }
            
            // Also update persistent cache
            await MainActor.run {
                self.nameToMBIDCache[artist] = mbid
                self.saveCache()
            }
            return mbid
        }
        return nil
    }
    

    
    private enum ResolutionStep {
        case exactMusicBrainz
        case looseMusicBrainz
        case theAudioDB
    }
    
    private func performMBIDResolutionAsync(primary: String, step: ResolutionStep) async -> String? {
        switch step {
        case .exactMusicBrainz:
            let query = "artist:\"\(primary)\""
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            let urlString = "https://musicbrainz.org/ws/2/artist?query=\(encodedQuery)&fmt=json"
            if let mbid = await queryMusicBrainzAsync(urlString: urlString, primary: primary) {
                return mbid
            } else {
                return await performMBIDResolutionAsync(primary: primary, step: .looseMusicBrainz)
            }
            
        case .looseMusicBrainz:
            let query = primary
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            let urlString = "https://musicbrainz.org/ws/2/artist?query=\(encodedQuery)&fmt=json"
            if let mbid = await queryMusicBrainzAsync(urlString: urlString, primary: primary) {
                return mbid
            } else {
                return await performMBIDResolutionAsync(primary: primary, step: .theAudioDB)
            }
            
        case .theAudioDB:
            let encoded = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "https://www.theaudiodb.com/api/v1/json/2/search.php?s=\(encoded)"
            guard let url = URL(string: urlString) else { return nil }
            
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let artists = json["artists"] as? [[String: Any]],
                      let first = artists.first,
                      let mbid = first["strMusicBrainzID"] as? String, !mbid.isEmpty else {
                    return nil
                }
                AppLogger.shared.log("[MBID] Resolved via TheAudioDB fallback: \(mbid)")
                return mbid
            } catch {
                return nil
            }
        }
    }
    
    private func queryMusicBrainzAsync(urlString: String, primary: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        
        guard let data = await performThrottledRequest(url: url) else { return nil }
        
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
                
                return bestMatch?["id"] as? String
            }
        } catch { }
        return nil
    }

    private func performThrottledRequest(url: URL, retryCount: Int = 0) async -> Data? {
        await throttler.wait()
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 503 && retryCount < 3 {
                    let backoff = pow(2.0, Double(retryCount))
                    AppLogger.shared.log("[MBID] 503 Rate Limited. Retrying in \(backoff)s...", level: .warning)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    return await performThrottledRequest(url: url, retryCount: retryCount + 1)
                }
                
                if http.statusCode != 200 {
                    AppLogger.shared.log("[MBID] HTTP Error \(http.statusCode) for \(url.absoluteString)", level: .error)
                    return nil
                }
            }
            
            return data
        } catch {
            AppLogger.shared.log("[MBID] Network error: \(error.localizedDescription)", level: .error)
            return nil
        }
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
    
    func resolveAlbumMBIDAsync(album: String, artist: String, query: String? = nil) async -> String? {
        let searchQuery: String
        if let q = query, !q.isEmpty {
            searchQuery = q
        } else {
            searchQuery = "release:\"\(album)\" AND artist:\"\(artist)\""
        }
        
        let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        
        if let data = await performThrottledRequest(url: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let releases = json["releases"] as? [[String: Any]],
           let first = releases.first {
            return first["id"] as? String
        }
        return nil
    }

    // MARK: - Silent Bulk Fetchers

    func downloadMetadataSilently(for artistName: String) async {
        guard let mbid = await resolveMBIDAsync(for: artistName) else { return }
        
        let fileUrl = self.getMetadataUrl(for: artistName)
        if self.fileManager.fileExists(atPath: fileUrl.path) { return }

        let urlString = "https://musicbrainz.org/ws/2/artist/\(mbid)?fmt=json&inc=aliases+tags"
        guard let url = URL(string: urlString) else { return }
        
        if let data = await performThrottledRequest(url: url),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            let annotation = await self.fetchAnnotationAsync(entityMBID: mbid)
            json["annotation"] = annotation
            if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                try? savedData.write(to: fileUrl)
            }
        }
    }

    private func fetchAnnotationAsync(entityMBID: String) async -> String? {
        let urlString = "https://musicbrainz.org/ws/2/annotation/?query=entity:\(entityMBID)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        
        if let data = await performThrottledRequest(url: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let annotations = json["annotations"] as? [[String: Any]],
           let first = annotations.first {
            return first["text"] as? String
        }
        return nil
    }
    
    // MARK: - Album Metadata Helpers
    
    func hasAlbumMetadata(albumName: String, artistName: String) -> Bool {
        let safeAlbum = albumName.replacingOccurrences(of: "/", with: "_")
        let safeArtist = artistName.replacingOccurrences(of: "/", with: "_")
        let fileUrl = metadataDir.appendingPathComponent("album_\(safeArtist)_\(safeAlbum).json")
        return fileManager.fileExists(atPath: fileUrl.path)
    }
    
    func downloadAlbumMetadataSilently(albumName: String, artistName: String) async {
        if hasAlbumMetadata(albumName: albumName, artistName: artistName) { return }
        
        if let mbid = await resolveAlbumMBIDAsync(album: albumName, artist: artistName) {
            let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?fmt=json&inc=genres"
            guard let url = URL(string: urlString) else { return }
            
            if let data = await performThrottledRequest(url: url) {
                let safeAlbum = albumName.replacingOccurrences(of: "/", with: "_")
                let safeArtist = artistName.replacingOccurrences(of: "/", with: "_")
                let fileUrl = self.metadataDir.appendingPathComponent("album_\(safeArtist)_\(safeAlbum).json")
                try? data.write(to: fileUrl)
            }
        }
    }
}


