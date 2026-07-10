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

@MainActor
final class MusicBrainzManager: ObservableObject {
    static let shared = MusicBrainzManager()

    @Published var currentArtistInfo: MBArtistInfo? = nil
    @Published var currentAlbumInfo: MBAlbumInfo? = nil
    @Published var isLoading = false
    @Published var metadataProgress: Double = 0.0

    private var currentArtistKey: String? = nil
    private var currentAlbumKey: String? = nil
    private var nameToMBIDCache: [String: String] = [:]
    private let cacheFile: URL
    private let metadataDir: URL
    private let fileManager = FileManager.default
    private let userAgent = "VeloraApp/1.0 ( https://github.com/Firehawk39/Velora-Swift )"

    init() {
        self.metadataDir = VeloraStorage.metadata
        self.cacheFile = VeloraStorage.root.appendingPathComponent("name_to_mbid.json")

        // Load persisted cache
        if let data = try? Data(contentsOf: self.cacheFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            self.nameToMBIDCache = json
        }

        // Self-heal: reconstruct any entries missing from the cache by scanning disk.
        // This makes the cache resilient to deletion/corruption of name_to_mbid.json.
        rebuildCacheFromDisk()
    }

    /// Scans all artist_*.json and album_*.json files in the metadata directory and
    /// backfills nameToMBIDCache for any entries not already present.
    /// Called once at init — runs synchronously on a background thread via Task.detached.
    private func rebuildCacheFromDisk() {
        let dir = self.metadataDir

        Task.detached(priority: .background) { [weak self] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

            var rebuilt: [String: String] = [:]

            for file in files {
                let name = file.lastPathComponent
                guard name.hasSuffix(".json") else { continue }

                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let mbid = (json["id"] as? String) ?? ""
                guard !mbid.isEmpty else { continue }

                if name.hasPrefix("artist_") {
                    // MusicBrainz returns artist name under "name"
                    if let artistName = json["name"] as? String {
                        rebuilt[artistName] = mbid
                    }
                } else if name.hasPrefix("album_") {
                    // Albums: MusicBrainz returns title under "title", artist under credit
                    if let title = json["title"] as? String,
                       let credits = json["artist-credit"] as? [[String: Any]],
                       let firstCredit = credits.first,
                       let artist = firstCredit["artist"] as? [String: Any],
                       let artistName = artist["name"] as? String {
                        rebuilt["\(artistName)_\(title)"] = mbid
                    }
                }
            }

            guard !rebuilt.isEmpty else { return }

            await MainActor.run {
                guard let self = self else { return }
                var didChange = false
                for (key, mbid) in rebuilt {
                    if self.nameToMBIDCache[key] == nil {
                        self.nameToMBIDCache[key] = mbid
                        didChange = true
                    }
                }
                if didChange { self.saveCache() }
            }
        }
    }

    private func saveCache() {
        let copy = nameToMBIDCache
        let file = cacheFile

        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(copy) {
                try? data.write(to: file)
            }
        }
    }

    func hasArtistMetadata(for artistName: String) -> Bool {
        // Fast path: MBID is in the in-memory cache
        if let mbid = nameToMBIDCache[artistName] {
            if mbid == "NOT_FOUND" { return true }
            return FileManager.default.fileExists(
                atPath: metadataDir.appendingPathComponent("artist_\(mbid).json").path
            )
        }
        // Cache miss — scan disk so a deleted/corrupt name_to_mbid.json
        // doesn't cause every artist to be re-synced on next tap.
        return hasAnyArtistFile(named: artistName)
    }

    /// Scans the metadata directory for an artist JSON whose "name" field matches.
    /// Only called when the MBID cache doesn't have an entry for this artist.
    private func hasAnyArtistFile(named artistName: String) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: metadataDir, includingPropertiesForKeys: nil)
        else { return false }
        for file in files where file.lastPathComponent.hasPrefix("artist_") {
            if let data = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String, name == artistName,
               let mbid = json["id"] as? String {
                // Backfill the cache while we're here
                nameToMBIDCache[artistName] = mbid
                saveCache()
                return true
            }
        }
        return false
    }

    func hasAlbumMetadata(albumName: String, artistName: String) -> Bool {
        let cacheKey = "\(artistName)_\(albumName)"
        if let mbid = nameToMBIDCache[cacheKey] {
            if mbid == "NOT_FOUND" { return true }
            let fileUrl = metadataDir.appendingPathComponent("album_\(mbid).json")
            return FileManager.default.fileExists(atPath: fileUrl.path)
        }
        // Cache miss — scan disk directly
        return hasAnyAlbumFile(albumName: albumName, artistName: artistName)
    }

    private func hasAnyAlbumFile(albumName: String, artistName: String) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: metadataDir, includingPropertiesForKeys: nil)
        else { return false }
        let cacheKey = "\(artistName)_\(albumName)"
        for file in files where file.lastPathComponent.hasPrefix("album_") {
            if let data = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["title"] as? String, title == albumName,
               let mbid = json["id"] as? String {
                nameToMBIDCache[cacheKey] = mbid
                saveCache()
                return true
            }
        }
        return false
    }

    func getArtistBiography(for artistName: String) -> String? {
        let mbid = nameToMBIDCache[artistName]
        guard let validMbid = mbid else { return nil }

        let fileName = "artist_" + (validMbid) + ".json"
        let fileUrl = self.metadataDir.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json["annotation"] as? String ?? (json["annotation"] as? [String: Any])?["text"] as? String
        }
        return nil
    }

    func fetchAboutArtist(artistName: String, mbid: String? = nil) {
        let artistKey = artistName
        self.currentArtistKey = artistKey
        self.isLoading = true
        self.metadataProgress = 0.1

        let fetchDetails: @MainActor @Sendable (String) -> Void = { [weak self] resolvedMBID in
            guard let self = self else { return }
            guard self.currentArtistKey == artistKey else { return }

            self.metadataProgress = 0.4
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
                self.currentArtistInfo = info
                self.metadataProgress = 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.currentArtistKey == artistKey else { return }
                    self.isLoading = false
                }
                return
            }

            let urlString = "https://musicbrainz.org/ws/2/artist/\(resolvedMBID)?fmt=json&inc=aliases+tags+annotation"
            guard let url = URL(string: urlString) else { return }

            guard NetworkMonitor.shared.isConnected else {
                DispatchQueue.main.async {
                    guard self.currentArtistKey == artistKey else { return }
                    self.isLoading = false
                }
                return
            }

            var request = URLRequest(url: url)
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

            ThrottledNetworkManager.shared.enqueue(request: request) { data, _, _ in
                DispatchQueue.main.async {
                    guard self.currentArtistKey == artistKey else { return }
                    self.metadataProgress = 0.7
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    DispatchQueue.main.async {
                        guard self.currentArtistKey == artistKey else { return }
                        self.isLoading = false
                    }
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
                    guard self.currentArtistKey == artistKey else { return }
                    self.currentArtistInfo = info
                    self.metadataProgress = 1.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard self.currentArtistKey == artistKey else { return }
                        self.isLoading = false
                    }
                }
            }
        }

        if let mbid = mbid, !mbid.isEmpty {
            fetchDetails(mbid)
        } else {
            guard NetworkMonitor.shared.isConnected else {
                self.isLoading = false
                return
            }
            resolveMBID(for: artistName) { resolved in
                guard self.currentArtistKey == artistKey else { return }
                if let resolved = resolved {
                    fetchDetails(resolved)
                } else {
                    self.nameToMBIDCache[artistName] = "NOT_FOUND"
                    self.saveCache()
                    self.isLoading = false
                }
            }
        }
    }

    func fetchAboutAlbum(albumName: String, artistName: String, mbid: String? = nil) {
        let albumKey = "\(artistName)_\(albumName)"
        self.currentAlbumKey = albumKey
        self.isLoading = true

        let fetchDetails: @MainActor @Sendable (String) -> Void = { [weak self] resolvedMBID in
            guard let self = self else { return }
            guard self.currentAlbumKey == albumKey else { return }

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
                self.currentAlbumInfo = info
                self.isLoading = false
                return
            }

            let urlString = "https://musicbrainz.org/ws/2/release/\(resolvedMBID)?fmt=json&inc=labels+recordings"
            guard let url = URL(string: urlString) else { return }

            guard NetworkMonitor.shared.isConnected else {
                DispatchQueue.main.async {
                    guard self.currentAlbumKey == albumKey else { return }
                    self.isLoading = false
                }
                return
            }

            var request = URLRequest(url: url)
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

            ThrottledNetworkManager.shared.enqueue(request: request) { data, _, _ in
                guard let data = data,
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    DispatchQueue.main.async {
                        guard self.currentAlbumKey == albumKey else { return }
                        self.isLoading = false
                    }
                    return
                }

                let labels = json["label-info"] as? [[String: Any]]
                let labelName = (labels?.first?["label"] as? [String: Any])?["name"] as? String

                DispatchQueue.main.async {
                    self.fetchAnnotation(entityMBID: resolvedMBID) { annotation in
                        guard self.currentAlbumKey == albumKey else { return }
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

                        self.currentAlbumInfo = info
                        self.isLoading = false
                    }
                }
            }
        }

        if let mbid = mbid, !mbid.isEmpty {
            fetchDetails(mbid)
        } else {
            guard NetworkMonitor.shared.isConnected else {
                self.isLoading = false
                return
            }
            resolveAlbumMBID(album: albumName, artist: artistName) { resolved in
                guard self.currentAlbumKey == albumKey else { return }
                if let resolved = resolved {
                    fetchDetails(resolved)
                } else {
                    self.nameToMBIDCache["\(artistName)_\(albumName)"] = "NOT_FOUND"
                    self.saveCache()
                    self.isLoading = false
                }
            }
        }
    }

    private func resolveMBID(for artist: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let primary = extractPrimaryArtist(artist)
        let encoded = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // Use exact name query to improve accuracy
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=artist:\"\(encoded)\"&fmt=json"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        ThrottledNetworkManager.shared.enqueue(request: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]], !artists.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let lowerPrimary = primary.lowercased()

            // 1. Prefer an artist whose name is an exact case-insensitive match.
            //    This prevents e.g. "Zimmer" resolving to "Hans Zimmer" which has
            //    "Zimmer" as a search-hint alias and ranks first in MusicBrainz results.
            if let exactMatch = artists.first(where: {
                ($0["name"] as? String)?.lowercased() == lowerPrimary
            }), let id = exactMatch["id"] as? String {
                DispatchQueue.main.async { completion(id) }
                return
            }

            // 2. Fallback: only accept the top result when score is 100 and unambiguous.
            let topScore = artists.first.flatMap { $0["score"] as? Int } ?? 0
            let topScoreCandidates = artists.filter { ($0["score"] as? Int) == topScore }
            if topScore == 100, topScoreCandidates.count == 1,
               let id = topScoreCandidates.first?["id"] as? String {
                DispatchQueue.main.async { completion(id) }
                return
            }

            // 3. No reliable match — return nil to avoid showing wrong artist art.
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private func extractPrimaryArtist(_ name: String) -> String {
        let delimiters = ["feat.", "ft.", " x ", " vs.", " featuring "]
        var primary = name
        for delimiter in delimiters {
            if let range = primary.range(of: delimiter, options: .caseInsensitive) {
                primary = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return primary.isEmpty ? name : primary
    }

    private func resolveAlbumMBID(album: String, artist: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let query = "release:\(album) AND artist:\(artist)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        ThrottledNetworkManager.shared.enqueue(request: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let releases = json["releases"] as? [[String: Any]],
               let first = releases.first {
                let mbid = first["id"] as? String
                DispatchQueue.main.async { completion(mbid) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private func fetchAnnotation(entityMBID: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let urlString = "https://musicbrainz.org/ws/2/annotation/?query=entity:\(entityMBID)&fmt=json"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        ThrottledNetworkManager.shared.enqueue(request: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let annotations = json["annotations"] as? [[String: Any]],
               let first = annotations.first {
                let text = first["text"] as? String
                DispatchQueue.main.async { completion(text) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: - Silent Bulk Fetchers

    func downloadMetadataSilently(for artistName: String, mbid: String? = nil) async {
        let finalMbid: String
        if let providedMbid = mbid, !providedMbid.isEmpty {
            finalMbid = providedMbid
        } else if let resolved = await resolveMBIDAsync(for: artistName) {
            finalMbid = resolved
        } else {
            AppLogger.shared.log("[Metadata] Silent prefetch: Failed to resolve MBID for \(artistName)")
            self.nameToMBIDCache[artistName] = "NOT_FOUND"
            self.saveCache()
            return
        }

        AppLogger.shared.log("[Metadata] Silent prefetch: Resolved \(artistName) to \(finalMbid)")
        self.nameToMBIDCache[artistName] = finalMbid
        self.saveCache()

        let fileName = "artist_" + (finalMbid) + ".json"
        let fileUrl = self.metadataDir.appendingPathComponent(fileName)

        if self.fileManager.fileExists(atPath: fileUrl.path) { return }

        let urlString = "https://musicbrainz.org/ws/2/artist/\(finalMbid)?fmt=json&inc=aliases+tags"
        guard let url = URL(string: urlString) else { return }

        guard NetworkMonitor.shared.isConnected else { return }

        var request = URLRequest(url: url)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? Data().write(to: fileUrl)
                return
            }

            let annotation = await fetchAnnotationAsync(entityMBID: finalMbid)
            json["annotation"] = annotation
            if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                try? savedData.write(to: fileUrl)
            } else {
                try? Data().write(to: fileUrl)
            }
        } catch {
            try? Data().write(to: fileUrl)
        }
    }

    func downloadAlbumMetadataSilently(albumName: String, artistName: String) async {
        let resolved = await resolveAlbumMBIDAsync(album: albumName, artist: artistName)
        guard let mbid = resolved else {
            self.nameToMBIDCache["\(artistName)_\(albumName)"] = "NOT_FOUND"
            self.saveCache()
            return
        }

        self.nameToMBIDCache["\(artistName)_\(albumName)"] = mbid
        self.saveCache()

        let fileName = "album_" + (mbid) + ".json"
        let fileUrl = self.metadataDir.appendingPathComponent(fileName)

        if self.fileManager.fileExists(atPath: fileUrl.path) { return }

        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?fmt=json&inc=labels+recordings"
        guard let url = URL(string: urlString) else { return }

        guard NetworkMonitor.shared.isConnected else { return }

        var request = URLRequest(url: url)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? Data().write(to: fileUrl)
                return
            }

            let annotation = await fetchAnnotationAsync(entityMBID: mbid)
            json["annotation"] = annotation
            if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                try? savedData.write(to: fileUrl)
            } else {
                try? Data().write(to: fileUrl)
            }
        } catch {
            try? Data().write(to: fileUrl)
        }
    }

    private func resolveMBIDAsync(for artist: String) async -> String? {
        let cached = nameToMBIDCache[artist]
        if let cached = cached { return cached }

        let primary = extractPrimaryArtist(artist)
        let queryTerm = "artist:\"\(primary)\""
        let encoded = queryTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]], !artists.isEmpty else {
                return nil
            }

            let lowerPrimary = primary.lowercased()

            // 1. Exact name match — prevents "Zimmer" → "Hans Zimmer"
            if let exactMatch = artists.first(where: {
                ($0["name"] as? String)?.lowercased() == lowerPrimary
            }), let id = exactMatch["id"] as? String {
                return id
            }

            // 2. Unambiguous top score (100, single candidate)
            let topScore = artists.first.flatMap { $0["score"] as? Int } ?? 0
            let topScoreCandidates = artists.filter { ($0["score"] as? Int) == topScore }
            if topScore == 100, topScoreCandidates.count == 1,
               let id = topScoreCandidates.first?["id"] as? String {
                return id
            }

            // 3. Ambiguous — refuse to guess
            return nil
        } catch { return nil }
    }


    private func resolveAlbumMBIDAsync(album: String, artist: String) async -> String? {
        let cached = nameToMBIDCache["\(artist)_\(album)"]
        if let cached = cached { return cached }

        let query = "release:\(album) AND artist:\(artist)"
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
