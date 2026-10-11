import SwiftUI
import Foundation

/// Tri-state result for MBID resolution. Prevents transient network errors
/// from permanently poisoning the negative cache with fake "not found" markers.
enum MBIDResult: Sendable {
    case found(String)
    case notFound        // API returned valid response, artist genuinely doesn't exist
    case networkError    // Timeout / circuit breaker / DNS — safe to retry later
}

final class SendableImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()
    func object(forKey key: NSString) -> UIImage? { cache.object(forKey: key) }
    func setObject(_ obj: UIImage, forKey key: NSString) { cache.setObject(obj, forKey: key) }
    func removeObject(forKey key: NSString) { cache.removeObject(forKey: key) }
}

@MainActor
final class FanartManager: ObservableObject {
    static let shared = FanartManager()

    @Published var currentBackdrop: UIImage? = nil
    @Published var currentClearLogo: UIImage? = nil
    private let imageCache = SendableImageCache()
    private let logoCache  = SendableImageCache()

    private let fileManager = FileManager.default
    private let backdropDir: URL
    private let portraitDir: URL
    private let clearLogoDir: URL

    // Fanart.tv API Key - User-configured via Settings, strictly NO hardcoded default fallback
    var fanartApiKey: String? {
        guard let custom = UserDefaults.standard.string(forKey: "velora_fanart_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !custom.isEmpty else {
            return nil
        }
        return custom
    }

    var isFanartConfigured: Bool {
        fanartApiKey != nil
    }

    init() {
        self.backdropDir   = VeloraStorage.backdrops
        self.portraitDir   = VeloraStorage.artistPortraits
        self.clearLogoDir  = VeloraStorage.clearLogos
        checkAndInvalidateIfKeyChanged()
    }

    // MARK: - API Key Lifecycle & Cache Invalidation

    /// Wipes 0-byte negative cache markers from disk. Preserves valid 36-byte .mbid sidecars.
    func wipeNegativeFanartCaches() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: backdropDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                let ext = file.pathExtension.lowercased()
                if (ext == "jpg" || ext == "jpeg" || ext == "png") && size <= 100 {
                    try? fm.removeItem(at: file)
                } else if ext == "mbid" && size == 0 {
                    try? fm.removeItem(at: file)
                }
            }
        }
        if let files = try? fm.contentsOfDirectory(at: clearLogoDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                let ext = file.pathExtension.lowercased()
                if (ext == "png" || ext == "jpg") && size <= 100 {
                    try? fm.removeItem(at: file)
                } else if ext == "mbid" && size == 0 {
                    try? fm.removeItem(at: file)
                }
            }
        }
        AppLogger.shared.log("[Fanart] Negative cache markers purged.", level: .info)
    }

    /// Called when the user configures, updates, or pastes a new Fanart API key.
    func handleApiKeyUpdated() {
        wipeNegativeFanartCaches()
        AssetRegistry.shared.resetFanartUnavailableRecords()
    }

    /// Automatically detects if the configured Fanart key changed from the last recorded session.
    /// Resets false negative records so user isn't permanently locked out of Fanart downloads.
    func checkAndInvalidateIfKeyChanged() {
        let currentKey = fanartApiKey ?? ""
        let lastKey = UserDefaults.standard.string(forKey: "velora_last_active_fanart_key") ?? ""
        if currentKey != lastKey {
            UserDefaults.standard.set(currentKey, forKey: "velora_last_active_fanart_key")
            if !currentKey.isEmpty {
                handleApiKeyUpdated()
            }
        }
    }

    // MARK: - TTL Helper

    nonisolated private func isNegativeCacheExpired(at url: URL, daysTTL: Int = 30) -> Bool {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attr[.modificationDate] as? Date else {
            return false // Keep marker intact
        }
        let age = Date().timeIntervalSince(modDate)
        return age > TimeInterval(daysTTL * 24 * 60 * 60)
    }

    // MARK: - Deduplication Reset

    /// Clears in-flight fetch guards so that a new sync pass can retry artists
    /// that were blocked by a stuck or timed-out previous pass.
    func resetActiveFetches() {
        activeBackdropFetches.removeAll()
        activeClearLogoFetches.removeAll()
    }

    // MARK: - Backdrops

    private var activeBackdropFetches = Set<String>()
    private var currentArtistName: String?

    /// Synchronously checks if a backdrop exists in cache and returns it
    nonisolated func getCachedBackdrop(for artist: String, artistId: String? = nil, mbid: String? = nil) -> UIImage? {
        let primary = extractPrimaryArtist(artist)
        let keys = [mbid, artistId, sanitizeFileName(artist), sanitizeFileName(primary)].compactMap { $0 }.filter { !$0.isEmpty }
        for key in keys {
            if let memoryCached = imageCache.object(forKey: key as NSString) {
                return memoryCached
            }

            let fileName = key + ".jpg"
            let fileUrl = self.backdropDir.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: fileUrl.path),
               let attr = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
               let size = attr[.size] as? Int64, size > 100,
               let data = try? Data(contentsOf: fileUrl),
               let image = UIImage(data: data) {
                self.imageCache.setObject(image, forKey: key as NSString)
                return image
            }
        }
        return nil
    }

    func hasBackdrop(for artist: String, artistId: String? = nil, mbid: String? = nil) -> Bool {
        let primary = extractPrimaryArtist(artist)
        let keys = [mbid, artistId, sanitizeFileName(artist), sanitizeFileName(primary)].compactMap { $0 }.filter { !$0.isEmpty }
        for key in keys {
            let fileUrl = self.backdropDir.appendingPathComponent(key + ".jpg")
            if FileManager.default.fileExists(atPath: fileUrl.path) {
                let size = (try? FileManager.default.attributesOfItem(atPath: fileUrl.path)[.size]) as? Int64 ?? 0
                if size > 100 { return true }
            }
        }
        return false
    }

    /// Returns true if a valid backdrop exists OR it was verified unavailable
    func hasCheckedBackdrop(for artist: String, artistId: String? = nil, mbid: String? = nil) -> Bool {
        let primary = extractPrimaryArtist(artist)
        let keys = [mbid, artistId, sanitizeFileName(artist), sanitizeFileName(primary)].compactMap { $0 }.filter { !$0.isEmpty }
        for key in keys {
            if AssetRegistry.shared.isBackdropUnavailable(key: key) { return true }
            let fileUrl = self.backdropDir.appendingPathComponent(key + ".jpg")
            if FileManager.default.fileExists(atPath: fileUrl.path) {
                let size = (try? FileManager.default.attributesOfItem(atPath: fileUrl.path)[.size]) as? Int64 ?? 0
                if size > 100 { return true }
                if isNegativeCacheExpired(at: fileUrl) {
                    try? FileManager.default.removeItem(at: fileUrl)
                    return false
                }
                return true // Verified unavailable within TTL
            }
        }
        return false
    }

    func hasPortrait(for artist: String) -> Bool {
        let sanitized = sanitizeFileName(artist)
        let fileUrl = self.portraitDir.appendingPathComponent(sanitized + ".jpg")
        guard FileManager.default.fileExists(atPath: fileUrl.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileUrl.path)[.size]) as? Int64 ?? 0
        return size > 100
    }

    func hasClearLogo(for artist: String, mbid: String? = nil) -> Bool {
        let primary = extractPrimaryArtist(artist)
        let keys = [mbid.map { "logo_" + $0 }, "logo_" + sanitizeFileName(artist), "logo_" + sanitizeFileName(primary)].compactMap { $0 }
        for k in keys {
            let fileUrl = clearLogoDir.appendingPathComponent(k + ".png")
            if fileManager.fileExists(atPath: fileUrl.path) {
                let size = (try? fileManager.attributesOfItem(atPath: fileUrl.path)[.size]) as? Int64 ?? 0
                if size > 100 { return true }
            }
        }
        return false
    }

    /// Returns true if a valid clear logo exists OR it was verified unavailable on TheAudioDB
    func hasCheckedClearLogo(for artist: String, mbid: String? = nil) -> Bool {
        let primary = extractPrimaryArtist(artist)
        let keys = [mbid.map { "logo_" + $0 }, "logo_" + sanitizeFileName(artist), "logo_" + sanitizeFileName(primary)].compactMap { $0 }
        for key in keys {
            if AssetRegistry.shared.isLogoUnavailable(key: key) { return true }
            let fileUrl = clearLogoDir.appendingPathComponent(key + ".png")
            if fileManager.fileExists(atPath: fileUrl.path) {
                let size = (try? fileManager.attributesOfItem(atPath: fileUrl.path)[.size]) as? Int64 ?? 0
                if size > 100 { return true }
                if isNegativeCacheExpired(at: fileUrl) {
                    try? fileManager.removeItem(at: fileUrl)
                    return false
                }
                return true // Verified unavailable within TTL
            }
        }
        return false
    }

    func fetchBackdrop(for artists: [String], artistId: String? = nil, mbid: String? = nil, allowNetwork: Bool = true) {
        guard !artists.isEmpty else { return }
        let primaryArtist = artists[0]
        let isNewArtist = self.currentArtistName != primaryArtist

        if isNewArtist {
            self.currentArtistName = primaryArtist
            withAnimation(.easeInOut(duration: 0.4)) { self.currentBackdrop = nil }
        }

        Task.detached {
            var hitImage: UIImage? = nil
            var hitArtist = ""

            for (index, artist) in artists.enumerated() {
                let currentArtistId = (index == 0) ? artistId : nil
                let currentMbid = (index == 0) ? mbid : nil
                if let cached = self.getCachedBackdrop(for: artist, artistId: currentArtistId, mbid: currentMbid) {
                    hitImage = cached
                    hitArtist = artist
                    break
                }

                // Check for negative cache marker (<= 100 byte file)
                if index == 0, let validMbid = mbid, !validMbid.isEmpty {
                    let mbidFile = self.backdropDir.appendingPathComponent("\(validMbid).jpg")
                    if FileManager.default.fileExists(atPath: mbidFile.path),
                       let attr = try? FileManager.default.attributesOfItem(atPath: mbidFile.path),
                       let size = attr[.size] as? Int64, size <= 100 {
                        if self.isNegativeCacheExpired(at: mbidFile) {
                            try? FileManager.default.removeItem(at: mbidFile)
                        } else {
                            continue
                        }
                    }
                }

                let key = self.getCacheKey(artistName: artist, artistId: currentArtistId)
                let fileUrl = self.backdropDir.appendingPathComponent(key + ".jpg")
                if FileManager.default.fileExists(atPath: fileUrl.path),
                   let attr = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
                   let size = attr[.size] as? Int64, size <= 100 {
                    if self.isNegativeCacheExpired(at: fileUrl) {
                        try? FileManager.default.removeItem(at: fileUrl)
                    } else {
                        continue // Verified no backdrop on Fanart, skip
                    }
                }
            }

            await MainActor.run {
                if let cached = hitImage {
                    AppLogger.shared.log("[Fanart] Cache hit for \(hitArtist)")
                    self.currentArtistName = primaryArtist
                    if isNewArtist {
                        withAnimation(.easeInOut(duration: 0.6)) { self.currentBackdrop = cached }
                    } else {
                        self.currentBackdrop = cached
                    }
                } else {
                    self.currentArtistName = primaryArtist
                    self.fetchBackdropRecursive(artists: artists, index: 0, artistId: artistId, providedMbid: mbid, allowNetwork: allowNetwork)
                }
            }
        }
    }

    func cycleBackdrop(for artists: [String], artistId: String? = nil, completion: @escaping @MainActor () -> Void = {}) {
        guard !artists.isEmpty, self.isFanartConfigured else {
            completion()
            return
        }
        let primaryArtist = artists[0]
        let key = getCacheKey(artistName: primaryArtist, artistId: artistId)
        let fileUrl = self.backdropDir.appendingPathComponent(key + ".jpg")
        let sidecarUrl = self.backdropDir.appendingPathComponent(key + ".mbid")

        let doCycle: (String) -> Void = { [weak self] resolvedMBID in
            guard let self = self, let apiKey = self.fanartApiKey, !apiKey.isEmpty else {
                completion()
                return
            }
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(apiKey)"
            self.fetchFromFanart(urlString: urlString, type: .background, artistName: primaryArtist, randomize: true, priority: URLSessionTask.highPriority) { url, isEmpty in
                if let url = url {
                    AppLogger.shared.log("[Fanart] Cycling backdrop to random URL for \(primaryArtist)")
                    self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, cacheKey: key, priority: URLSessionTask.highPriority) { image in
                        if let img = image, self.currentArtistName == primaryArtist {
                            withAnimation(.easeInOut(duration: 0.5)) { self.currentBackdrop = img }
                        }
                        completion()
                    }
                } else {
                    AppLogger.shared.log("[Fanart] Could not cycle backdrop for \(primaryArtist)")
                    completion()
                }
            }
        }

        if let data = try? Data(contentsOf: sidecarUrl), let cachedMbid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !cachedMbid.isEmpty {
            doCycle(cachedMbid)
            return
        }
        
        let logoSidecarUrl = self.clearLogoDir.appendingPathComponent("logo_" + sanitizeFileName(primaryArtist) + ".mbid")
        if let data = try? Data(contentsOf: logoSidecarUrl), let cachedMbid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !cachedMbid.isEmpty {
            try? cachedMbid.write(to: sidecarUrl, atomically: true, encoding: .utf8)
            doCycle(cachedMbid)
            return
        }

        self.getMBIDSafe(for: primaryArtist, priority: URLSessionTask.highPriority) { [weak self] result in
            guard self != nil else { return }
            switch result {
            case .found(let resolvedMBID):
                try? resolvedMBID.write(to: sidecarUrl, atomically: true, encoding: .utf8)
                doCycle(resolvedMBID)
            case .notFound, .networkError:
                AppLogger.shared.log("[Fanart] Cannot cycle backdrop — MBID not found or network error.")
                completion()
            }
        }
    }

    private func fetchBackdropRecursive(artists: [String], index: Int, artistId: String?, providedMbid: String?, allowNetwork: Bool) {
        guard index < artists.count else { return }
        let artist = artists[index]
        let primaryArtist = artists[0]
        let key = getCacheKey(artistName: artist, artistId: index == 0 ? artistId : nil)
        let fileUrl = self.backdropDir.appendingPathComponent(key + ".jpg")

        let alreadyFetching = activeBackdropFetches.contains(key)
        if alreadyFetching { return }

        guard allowNetwork, NetworkMonitor.shared.isConnected else { return }

        activeBackdropFetches.insert(key)

        // 3. Resolve MBID and Fetch (prefer provided MBID from Picard / Navidrome)
        if index == 0, let validMBID = providedMbid, !validMBID.isEmpty {
            let sidecarUrl = self.backdropDir.appendingPathComponent(key + ".mbid")
            try? validMBID.write(to: sidecarUrl, atomically: true, encoding: .utf8)
            self.executeFanartQuery(resolvedMBID: validMBID, isProvided: true, artist: artist, primaryArtist: primaryArtist, key: key, fileUrl: fileUrl, artists: artists, index: index, allowNetwork: allowNetwork)
        } else {
            self.getMBIDSafe(for: artist, priority: URLSessionTask.highPriority) { result in
                switch result {
                case .found(let resolved):
                    let sidecarUrl = self.backdropDir.appendingPathComponent(key + ".mbid")
                    try? resolved.write(to: sidecarUrl, atomically: true, encoding: .utf8)
                    Task { @MainActor in
                        self.executeFanartQuery(resolvedMBID: resolved, isProvided: false, artist: artist, primaryArtist: primaryArtist, key: key, fileUrl: fileUrl, artists: artists, index: index, allowNetwork: allowNetwork)
                    }
                case .notFound:
                    // Genuinely not on MusicBrainz — write negative cache
                    try? Data().write(to: fileUrl)
                    self.activeBackdropFetches.remove(key)
                    self.fetchBackdropRecursive(artists: artists, index: index + 1, artistId: nil, providedMbid: nil, allowNetwork: allowNetwork)
                case .networkError:
                    // Transient failure — do NOT write negative cache, allow retry on next pass
                    self.activeBackdropFetches.remove(key)
                    self.fetchBackdropRecursive(artists: artists, index: index + 1, artistId: nil, providedMbid: nil, allowNetwork: allowNetwork)
                }
            }
        }
    }

    private func executeFanartQuery(
        resolvedMBID: String,
        isProvided: Bool,
        artist: String,
        primaryArtist: String,
        key: String,
        fileUrl: URL,
        artists: [String],
        index: Int,
        allowNetwork: Bool
    ) {
        let tryTheAudioDBFallback: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self = self else { return }
            self.fetchFromTheAudioDB(artistName: artist, mbid: resolvedMBID, priority: URLSessionTask.highPriority) { result in
                if let tadbUrl = result.backdropUrls.first {
                    AppLogger.shared.log("[TheAudioDB] Found fallback backdrop URL for \(artist)")
                    self.downloadAndCache(from: tadbUrl, to: fileUrl, primaryArtistName: primaryArtist, cacheKey: key, mbid: resolvedMBID, priority: URLSessionTask.highPriority) { image in
                        self.activeBackdropFetches.remove(key)
                    }
                } else {
                    AppLogger.shared.log("[TheAudioDB] No backdrop found for \(artist). Negative caching.")
                    try? Data().write(to: fileUrl)
                    let mbidFile = self.backdropDir.appendingPathComponent("\(resolvedMBID).jpg")
                    try? Data().write(to: mbidFile)
                    self.activeBackdropFetches.remove(key)
                    self.fetchBackdropRecursive(artists: artists, index: index + 1, artistId: nil, providedMbid: nil, allowNetwork: allowNetwork)
                }
            }
        }

        guard let apiKey = self.fanartApiKey, !apiKey.isEmpty else {
            // Fanart not configured — seamlessly fallback to TheAudioDB
            tryTheAudioDBFallback()
            return
        }

        AppLogger.shared.log("[Fanart] Querying Fanart.tv for \(artist) (MBID: \(resolvedMBID))")
        let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(apiKey)"
        self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist) { [weak self] url, isEmpty in
            guard let self = self else { return }
            if let url = url {
                AppLogger.shared.log("[Fanart] Found backdrop URL for \(artist)")
                self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, cacheKey: key, mbid: resolvedMBID, priority: URLSessionTask.highPriority) { image in
                    self.activeBackdropFetches.remove(key)
                }
            } else if isEmpty {
                AppLogger.shared.log("[Fanart] No backdrop on Fanart for \(artist), trying TheAudioDB fallback...")
                tryTheAudioDBFallback()
            } else {
                AppLogger.shared.log("[Fanart] Fetch failed/rate-limited for \(artist)")
                self.activeBackdropFetches.remove(key)
                self.fetchBackdropRecursive(artists: artists, index: index + 1, artistId: nil, providedMbid: nil, allowNetwork: allowNetwork)
            }
        }
    }

    func downloadBackdropSilently(for artists: [String], artistId: String? = nil, mbid: String? = nil) async {
        guard !artists.isEmpty else { return }
        let primaryArtist = artists[0]

        // 1. Direct MBID check: if we already have the backdrop by MBID, skip immediately!
        if let validMBID = mbid, !validMBID.isEmpty {
            let mbidFileUrl = backdropDir.appendingPathComponent("\(validMBID).jpg")
            if fileManager.fileExists(atPath: mbidFileUrl.path) {
                let size = (try? fileManager.attributesOfItem(atPath: mbidFileUrl.path)[.size]) as? Int64 ?? 0
                if size > 100 {
                    return // Found valid backdrop by MBID!
                }
                if !isNegativeCacheExpired(at: mbidFileUrl) {
                    return // Verified unavailable
                }
                try? fileManager.removeItem(at: mbidFileUrl)
            }
        }

        for (index, artist) in artists.enumerated() {
            let key = getCacheKey(artistName: artist, artistId: index == 0 ? artistId : nil)
            let fileUrl = backdropDir.appendingPathComponent(key + ".jpg")

            if fileManager.fileExists(atPath: fileUrl.path) {
                let size = (try? fileManager.attributesOfItem(atPath: fileUrl.path)[.size]) as? Int64 ?? 0
                if size > 100 {
                    return // Found a valid image!
                }
                if isNegativeCacheExpired(at: fileUrl) {
                    try? fileManager.removeItem(at: fileUrl)
                } else {
                    if index == artists.count - 1 { return } // Last fallback artist has a marker, we're done
                    continue // Current artist has marker, try next
                }
            }

            let alreadyFetching = activeBackdropFetches.contains(key)
            if !alreadyFetching { activeBackdropFetches.insert(key) }
            if alreadyFetching { return }

            guard NetworkMonitor.shared.isConnected else {
                self.activeBackdropFetches.remove(key)
                return
            }

            let success: Bool = await withCheckedContinuation { continuation in
                let fetchTadbFallback: @MainActor @Sendable (String) -> Void = { resolvedMBID in
                    self.fetchFromTheAudioDB(artistName: artist, mbid: resolvedMBID, priority: URLSessionTask.lowPriority) { result in
                        if let tadbUrl = result.backdropUrls.first {
                            self.downloadAndCache(from: tadbUrl, to: fileUrl, primaryArtistName: primaryArtist, cacheKey: key, mbid: resolvedMBID, priority: URLSessionTask.lowPriority) { _ in
                                self.activeBackdropFetches.remove(key)
                                continuation.resume(returning: true)
                            }
                        } else {
                            if NetworkMonitor.shared.isConnected {
                                try? Data().write(to: fileUrl)
                                let mbidFile = self.backdropDir.appendingPathComponent("\(resolvedMBID).jpg")
                                try? Data().write(to: mbidFile)
                                Task { @MainActor in AssetRegistry.shared.markBackdropUnavailable(key: key) }
                            }
                            self.activeBackdropFetches.remove(key)
                            continuation.resume(returning: false)
                        }
                    }
                }

                let query: @MainActor @Sendable (String) -> Void = { resolvedMBID in
                    guard let apiKey = self.fanartApiKey, !apiKey.isEmpty else {
                        fetchTadbFallback(resolvedMBID)
                        return
                    }
                    let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(apiKey)"
                    self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist, priority: URLSessionTask.lowPriority) { [weak self] url, isEmpty in
                        guard let self = self else { continuation.resume(returning: false); return }
                        if let url = url {
                            self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, cacheKey: key, mbid: resolvedMBID, priority: URLSessionTask.lowPriority) { _ in
                                self.activeBackdropFetches.remove(key)
                                continuation.resume(returning: true)
                            }
                        } else if isEmpty {
                            fetchTadbFallback(resolvedMBID)
                        } else {
                            self.activeBackdropFetches.remove(key)
                            continuation.resume(returning: false)
                        }
                    }
                }

                if index == 0, let validMBID = mbid, !validMBID.isEmpty {
                    Task { @MainActor in query(validMBID) }
                } else {
                    getMBIDSafe(for: artist, priority: URLSessionTask.lowPriority) { result in
                        switch result {
                        case .found(let resolved):
                            Task { @MainActor in query(resolved) }
                        case .notFound:
                            if NetworkMonitor.shared.isConnected {
                                try? Data().write(to: fileUrl)
                                Task { @MainActor in AssetRegistry.shared.markBackdropUnavailable(key: key) }
                            }
                            self.activeBackdropFetches.remove(key)
                            continuation.resume(returning: false)
                        case .networkError:
                            // Transient — skip negative cache, allow retry
                            self.activeBackdropFetches.remove(key)
                            continuation.resume(returning: false)
                        }
                    }
                }
            }

            if success { return } // We got one, stop cascading
        }
    }

    // MARK: - Artist Portraits (Managed strictly by Navidrome)

    /// Artist profile photos are served and downloaded directly by Navidrome. No-op to avoid external calls.
    func downloadArtistPortraitSilently(for artist: String, artistId: String, mbid: String? = nil) async {}

    func fetchArtistPortrait(for artist: String, mbid: String? = nil, completion: @escaping @Sendable @MainActor (UIImage?) -> Void) {
        completion(nil)
    }

    // MARK: - Clear Logos (TheAudioDB ONLY)

    private var activeClearLogoFetches = Set<String>()
    private var currentClearLogoArtist: String?

    /// Fetch transparent artist ClearLogo strictly from TheAudioDB.
    func fetchClearLogo(for artist: String, mbid: String? = nil) {
        let isNewArtist = self.currentClearLogoArtist != artist
        if isNewArtist {
            self.currentClearLogoArtist = artist
            withAnimation(.easeOut(duration: 0.2)) { self.currentClearLogo = nil }
        }

        let primary = extractPrimaryArtist(artist)
        let key = "logo_" + sanitizeFileName(primary)
        let mbidKey = (mbid != nil && !mbid!.isEmpty) ? "logo_\(mbid!)" : nil

        // 1. Check in-memory cache
        for k in [mbidKey, key].compactMap({ $0 }) {
            if let cached = logoCache.object(forKey: k as NSString) {
                if self.currentClearLogoArtist == artist {
                    withAnimation(.easeInOut(duration: 0.5)) { self.currentClearLogo = cached }
                }
                return
            }
        }

        // 2. Check disk cache
        for k in [mbidKey, key].compactMap({ $0 }) {
            let fileUrl = clearLogoDir.appendingPathComponent(k + ".png")
            if FileManager.default.fileExists(atPath: fileUrl.path),
               let attr = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
               let size = attr[.size] as? Int64 {
                if size > 100, let data = try? Data(contentsOf: fileUrl), let img = UIImage(data: data) {
                    logoCache.setObject(img, forKey: k as NSString)
                    if let other = (k == mbidKey ? key : mbidKey) {
                        logoCache.setObject(img, forKey: other as NSString)
                    }
                    if self.currentClearLogoArtist == artist {
                        withAnimation(.easeInOut(duration: 0.5)) { self.currentClearLogo = img }
                    }
                    return
                } else if size <= 100 {
                    if isNegativeCacheExpired(at: fileUrl) {
                        try? FileManager.default.removeItem(at: fileUrl)
                    } else {
                        return // Verified unavailable
                    }
                }
            }
        }

        // 3. Deduplicate in-flight fetch
        guard !activeClearLogoFetches.contains(key) else { return }
        activeClearLogoFetches.insert(key)
        if let mk = mbidKey { activeClearLogoFetches.insert(mk) }

        guard NetworkMonitor.shared.isConnected else {
            activeClearLogoFetches.remove(key)
            if let mk = mbidKey { activeClearLogoFetches.remove(mk) }
            return
        }

        // 4. Fetch strictly from TheAudioDB
        let destFileUrl = clearLogoDir.appendingPathComponent(key + ".png")
        self.fetchFromTheAudioDB(artistName: primary, mbid: mbid, priority: URLSessionTask.highPriority) { [weak self] result in
            guard let self = self else { return }
            let resolvedMbid = result.mbid ?? mbid

            if let rm = resolvedMbid, !rm.isEmpty {
                self.mbidCache[primary] = rm
            }

            if let tadbUrl = result.logoUrl {
                AppLogger.shared.log("[TheAudioDB] Fetched clearlogo for \(artist)")
                self.downloadClearLogoFile(from: tadbUrl, to: destFileUrl, artist: artist, cacheKey: key, usedMbid: resolvedMbid)
            } else if result.isTrueNotFound {
                AppLogger.shared.log("[TheAudioDB] No clearlogo found for \(artist). Negative caching.")
                try? Data().write(to: destFileUrl)
                if let mk = mbidKey {
                    let mbidFileUrl = self.clearLogoDir.appendingPathComponent(mk + ".png")
                    try? Data().write(to: mbidFileUrl)
                }
                self.activeClearLogoFetches.remove(key)
                if let mk = mbidKey { self.activeClearLogoFetches.remove(mk) }
            } else {
                self.activeClearLogoFetches.remove(key)
                if let mk = mbidKey { self.activeClearLogoFetches.remove(mk) }
            }

            // Bonus: If TheAudioDB has a backdrop and we don't have one cached yet, cache it!
            if let backdropUrl = result.backdropUrls.first, !self.hasBackdrop(for: primary, mbid: resolvedMbid) {
                let backdropKey = self.getCacheKey(artistName: primary)
                let backdropFile = self.backdropDir.appendingPathComponent(backdropKey + ".jpg")
                self.downloadAndCache(from: backdropUrl, to: backdropFile, primaryArtistName: primary, cacheKey: backdropKey, mbid: resolvedMbid, priority: URLSessionTask.defaultPriority) { _ in }
            }
        }
    }

    /// Background-priority prefetch for ClearLogos strictly from TheAudioDB.
    func downloadClearLogoSilently(for artist: String, mbid: String? = nil) async {
        let primary = extractPrimaryArtist(artist)
        let key = "logo_" + sanitizeFileName(primary)
        let mbidKey = (mbid != nil && !mbid!.isEmpty) ? "logo_\(mbid!)" : nil

        for k in [mbidKey, key].compactMap({ $0 }) {
            let fileUrl = clearLogoDir.appendingPathComponent(k + ".png")
            if FileManager.default.fileExists(atPath: fileUrl.path),
               let attr = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
               let size = attr[.size] as? Int64 {
                if size > 100 { return } // Already cached
                if !isNegativeCacheExpired(at: fileUrl) { return } // Verified unavailable
                try? FileManager.default.removeItem(at: fileUrl)
            }
        }

        guard NetworkMonitor.shared.isConnected else { return }
        guard !activeClearLogoFetches.contains(key) else { return }
        activeClearLogoFetches.insert(key)
        if let mk = mbidKey { activeClearLogoFetches.insert(mk) }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let destFileUrl = clearLogoDir.appendingPathComponent(key + ".png")
            self.fetchFromTheAudioDB(artistName: primary, mbid: mbid, priority: URLSessionTask.lowPriority) { [weak self] result in
                guard let self = self else { continuation.resume(); return }
                let resolvedMbid = result.mbid ?? mbid

                if let rm = resolvedMbid, !rm.isEmpty {
                    self.mbidCache[primary] = rm
                }

                // If TheAudioDB has a backdrop and we lack one, fetch it silently too
                if let backdropUrl = result.backdropUrls.first, !self.hasBackdrop(for: primary, mbid: resolvedMbid) {
                    let backdropKey = self.getCacheKey(artistName: primary)
                    let backdropFile = self.backdropDir.appendingPathComponent(backdropKey + ".jpg")
                    self.downloadAndCache(from: backdropUrl, to: backdropFile, primaryArtistName: primary, cacheKey: backdropKey, mbid: resolvedMbid, priority: URLSessionTask.lowPriority) { _ in }
                }

                if let tadbUrl = result.logoUrl {
                    self.downloadClearLogoFile(from: tadbUrl, to: destFileUrl, artist: artist, cacheKey: key, usedMbid: resolvedMbid) {
                        self.activeClearLogoFetches.remove(key)
                        if let mk = mbidKey { self.activeClearLogoFetches.remove(mk) }
                        continuation.resume()
                    }
                } else {
                    if NetworkMonitor.shared.isConnected {
                        try? Data().write(to: destFileUrl)
                        if let mk = mbidKey {
                            let mbidFileUrl = self.clearLogoDir.appendingPathComponent(mk + ".png")
                            try? Data().write(to: mbidFileUrl)
                        }
                        AssetRegistry.shared.markLogoUnavailable(key: key)
                    }
                    self.activeClearLogoFetches.remove(key)
                    if let mk = mbidKey { self.activeClearLogoFetches.remove(mk) }
                    continuation.resume()
                }
            }
        }
    }

    private func downloadClearLogoFile(from urlString: String, to localUrl: URL, artist: String, cacheKey: String, usedMbid: String? = nil, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let url = URL(string: urlString) else {
            activeClearLogoFetches.remove(cacheKey)
            completion?()
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20.0
        ThrottledNetworkManager.shared.enqueue(request: req) { [weak self] data, _, error in
            guard let self = self else {
                Task { @MainActor in completion?() }
                return
            }
            DispatchQueue.main.async {
                if let data = data, let img = UIImage(data: data) {
                    try? data.write(to: localUrl)
                    if let mbid = usedMbid, !mbid.isEmpty {
                        let mbidFileUrl = self.clearLogoDir.appendingPathComponent("logo_\(mbid).png")
                        if mbidFileUrl.path != localUrl.path {
                            try? data.write(to: mbidFileUrl)
                        }
                        self.logoCache.setObject(img, forKey: "logo_\(mbid)" as NSString)
                        let sidecarUrl = localUrl.deletingPathExtension().appendingPathExtension("mbid")
                        try? mbid.write(to: sidecarUrl, atomically: true, encoding: .utf8)
                    }
                    self.logoCache.setObject(img, forKey: cacheKey as NSString)
                    if self.currentClearLogoArtist == artist {
                        withAnimation(.easeInOut(duration: 0.6)) { self.currentClearLogo = img }
                    }
                } else if error != nil {
                    AppLogger.shared.log("[TheAudioDB] Clearlogo download failed for \(artist) — will retry next pass", level: .warning)
                } else {
                    try? Data().write(to: localUrl)
                }
                self.activeClearLogoFetches.remove(cacheKey)
                completion?()
            }
        }
    }

    // MARK: - TheAudioDB Fetcher (ClearLogos & Backdrops)

    struct TheAudioDBArtistResult: Sendable {
        let logoUrl: String?
        let backdropUrls: [String]
        let mbid: String?
        let isTrueNotFound: Bool
    }

    nonisolated private func fetchFromTheAudioDB(artistName: String, mbid: String? = nil, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (TheAudioDBArtistResult) -> Void) {
        let primary = extractPrimaryArtist(artistName)
        let encoded = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? primary

        let parseArtistJson: @Sendable (Data) -> TheAudioDBArtistResult? = { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]] else {
                return nil
            }
            let lowerPrimary = primary.lowercased()
            let matched = artists.first {
                (mbid != nil && ($0["strMusicBrainzID"] as? String)?.lowercased() == mbid!.lowercased()) ||
                ($0["strArtist"] as? String ?? "").lowercased() == lowerPrimary
            } ?? artists.first

            guard let matched = matched else { return nil }
            let logoUrl = (matched["strArtistLogo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let validLogo = (logoUrl?.isEmpty == false) ? logoUrl : nil

            let fanartKeys = ["strArtistFanart", "strArtistFanart2", "strArtistFanart3"]
            let backdrops = fanartKeys.compactMap { matched[$0] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let resolvedMbid = (matched["strMusicBrainzID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let validMbid = (resolvedMbid?.isEmpty == false) ? resolvedMbid : mbid

            return TheAudioDBArtistResult(
                logoUrl: validLogo,
                backdropUrls: backdrops,
                mbid: validMbid,
                isTrueNotFound: false
            )
        }

        let queryNameEndpoint: @Sendable () -> Void = {
            let nameUrlString = "https://theaudiodb.com/api/v1/json/123/search.php?s=\(encoded)"
            guard let url = URL(string: nameUrlString) else {
                DispatchQueue.main.async {
                    completion(TheAudioDBArtistResult(logoUrl: nil, backdropUrls: [], mbid: mbid, isTrueNotFound: true))
                }
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15.0
            ThrottledNetworkManager.shared.enqueue(request: req, priority: priority) { data, response, error in
                guard let data = data, error == nil else {
                    DispatchQueue.main.async {
                        completion(TheAudioDBArtistResult(logoUrl: nil, backdropUrls: [], mbid: mbid, isTrueNotFound: false))
                    }
                    return
                }
                if let result = parseArtistJson(data) {
                    DispatchQueue.main.async { completion(result) }
                } else {
                    DispatchQueue.main.async {
                        completion(TheAudioDBArtistResult(logoUrl: nil, backdropUrls: [], mbid: mbid, isTrueNotFound: true))
                    }
                }
            }
        }

        if let knownMbid = mbid, !knownMbid.isEmpty {
            let mbidUrlString = "https://theaudiodb.com/api/v1/json/123/artist-mb.php?i=\(knownMbid)"
            guard let url = URL(string: mbidUrlString) else {
                queryNameEndpoint()
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15.0
            ThrottledNetworkManager.shared.enqueue(request: req, priority: priority) { data, response, error in
                guard let data = data, error == nil else {
                    queryNameEndpoint()
                    return
                }
                if let result = parseArtistJson(data) {
                    DispatchQueue.main.async { completion(result) }
                } else {
                    queryNameEndpoint()
                }
            }
        } else {
            queryNameEndpoint()
        }
    }

    // MARK: - API Helpers

    private enum FanartType { case background, portrait, clearlogo }

    // Stores the current cycle index for each artist so cycling is sequential
    private var backdropCycleIndices: [String: Int] = [:]

    nonisolated private func fetchFromFanart(urlString: String, type: FanartType, artistName: String, randomize: Bool = false, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (String?, Bool) -> Void) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil, false) }
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15.0
        ThrottledNetworkManager.shared.enqueue(request: req, priority: priority) { data, response, error in
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
                            let defaultIndex = abs(hashValue) % bgs.count
                            let index = defaultIndex
                            
                            if randomize && bgs.count > 1 {
                                Task { @MainActor in
                                    let current = FanartManager.shared.backdropCycleIndices[artistName] ?? defaultIndex
                                    let nextIndex = (current + 1) % bgs.count
                                    FanartManager.shared.backdropCycleIndices[artistName] = nextIndex
                                    let selected = bgs[nextIndex]["url"] as? String
                                    completion(selected, false)
                                }
                                return
                            } else if randomize && bgs.count == 1 {
                                AppLogger.shared.log("[Fanart] Only 1 backdrop exists for \(artistName), cannot cycle.")
                            }
                            
                            let selected = bgs[index]["url"] as? String
                            DispatchQueue.main.async { completion(selected, false) }
                            return
                        } else {
                            // Valid JSON but no background
                            DispatchQueue.main.async { completion(nil, true) }
                            return
                        }
                    } else if type == .clearlogo {
                        // Prefer HD logo, fall back to SD logo
                        let hdUrls  = (json["hdmusiclogo"]  as? [[String: Any]])?.compactMap { $0["url"] as? String }
                        let sdUrls  = (json["musiclogo"]    as? [[String: Any]])?.compactMap { $0["url"] as? String }
                        if let first = (hdUrls?.first ?? sdUrls?.first) {
                            DispatchQueue.main.async { completion(first, false) }
                        } else {
                            DispatchQueue.main.async { completion(nil, true) }
                        }
                        return
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
            } catch { AppLogger.shared.log("Fanart JSON error: \(error)", level: .error) }
            DispatchQueue.main.async { completion(nil, false) }
        }
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

    nonisolated private func downloadAndCache(from urlString: String, to localUrl: URL, primaryArtistName: String, cacheKey: String, mbid: String? = nil, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (UIImage?) -> Void) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20.0
        ThrottledNetworkManager.shared.enqueue(request: req, priority: priority) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                try? data.write(to: localUrl)
                let sanitizedName = self.sanitizeFileName(primaryArtistName)
                let altUrl = self.backdropDir.appendingPathComponent("\(sanitizedName).jpg")
                if altUrl.path != localUrl.path && !FileManager.default.fileExists(atPath: altUrl.path) {
                    try? data.write(to: altUrl)
                }
                if let validMbid = mbid, !validMbid.isEmpty {
                    let mbidUrl = self.backdropDir.appendingPathComponent("\(validMbid).jpg")
                    if mbidUrl.path != localUrl.path && !FileManager.default.fileExists(atPath: mbidUrl.path) {
                        try? data.write(to: mbidUrl)
                    }
                }

                // CRITICAL: Even if this was a "silent" or background fetch,
                // if the artist is the one we are currently viewing, update the UI!
                DispatchQueue.main.async {
                    self.imageCache.setObject(image, forKey: cacheKey as NSString)
                    self.imageCache.setObject(image, forKey: sanitizedName as NSString)
                    if let validMbid = mbid, !validMbid.isEmpty {
                        self.imageCache.setObject(image, forKey: validMbid as NSString)
                    }
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
    }

    nonisolated func getCacheKey(artistName: String, artistId: String? = nil) -> String {
        if let aid = artistId, !aid.isEmpty { return aid }
        return sanitizeFileName(artistName)
    }

    nonisolated func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }

    nonisolated private func extractPrimaryArtist(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if knownBandNamesWithDelimiters.contains(trimmed.lowercased()) {
            return trimmed
        }
        let delimiters = [" • ", "•", "・", " feat.", " ft.", " featuring ", " x ", " vs.", " & ", " / ", ", "]
        var primary = trimmed
        for delimiter in delimiters {
            if let range = primary.range(of: delimiter, options: .caseInsensitive) {
                primary = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return primary.isEmpty ? trimmed : primary
    }

    /// Legacy convenience wrapper — used by fetchClearLogo/fetchArtistPortrait UI paths
    /// that don't need tri-state error handling.
    nonisolated private func getMBID(for artistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (String?) -> Void) {
        getMBIDSafe(for: artistName, priority: priority) { result in
            switch result {
            case .found(let id): completion(id)
            case .notFound, .networkError: completion(nil)
            }
        }
    }

    private var mbidCache: [String: String] = [:]
    private var activeMbidFetches: [String: [(MBIDResult) -> Void]] = [:]

    /// Tri-state MBID resolver that distinguishes "not found" from "network error".
    /// Callers MUST only write negative cache markers on `.notFound`, never on `.networkError`.
    nonisolated private func getMBIDSafe(for artistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (MBIDResult) -> Void) {
        let primary = extractPrimaryArtist(artistName)
        
        Task { @MainActor in
            if let cached = FanartManager.shared.mbidCache[primary] {
                completion(.found(cached))
                return
            }
            
            // Deduplicate in-flight requests
            if FanartManager.shared.activeMbidFetches[primary] != nil {
                FanartManager.shared.activeMbidFetches[primary]?.append(completion)
                return
            }
            FanartManager.shared.activeMbidFetches[primary] = [completion]
            
            let queryTerm = "artist:\"\(primary)\""
            let encodedQuery = queryTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "https://musicbrainz.org/ws/2/artist/?query=\(encodedQuery)&fmt=json"
            guard let url = URL(string: urlString) else {
                FanartManager.shared.resolveMbidFetches(for: primary, with: .notFound)
                return
            }

            var request = URLRequest(url: url)
            request.setValue("VeloraApp/1.0 ( https://github.com/Firehawk39/Velora-Swift )", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15.0

            ThrottledNetworkManager.shared.enqueue(request: request, priority: priority) { data, response, error in
            // CRITICAL: Distinguish network failures from genuine "not found" results.
            // A transient timeout or circuit breaker trip must NOT poison the negative cache.
            if let error = error {
                let nsError = error as NSError
                let isTransient = nsError.code == NSURLErrorTimedOut ||
                                  nsError.code == NSURLErrorCannotConnectToHost ||
                                  nsError.code == NSURLErrorCannotFindHost ||
                                  nsError.code == NSURLErrorNetworkConnectionLost ||
                                  nsError.domain == "CircuitBreaker"
                if isTransient {
                    Task { @MainActor in FanartManager.shared.resolveMbidFetches(for: primary, with: .networkError) }
                    return
                }
            }

            // If we got HTTP 429 or 5xx, that's also transient
            if let http = response as? HTTPURLResponse, (http.statusCode == 429 || http.statusCode >= 500) {
                Task { @MainActor in FanartManager.shared.resolveMbidFetches(for: primary, with: .networkError) }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Task { @MainActor in FanartManager.shared.resolveMbidFetches(for: primary, with: .networkError) }
                return
            }

            // Check if MusicBrainz returned a busy error payload
            if let errorMsg = json["error"] as? String, errorMsg.lowercased().contains("busy") {
                Task { @MainActor in FanartManager.shared.resolveMbidFetches(for: primary, with: .networkError) }
                return
            }

            guard let artists = json["artists"] as? [[String: Any]], !artists.isEmpty else {
                // Valid response but no results — artist genuinely not on MusicBrainz
                Task { @MainActor in FanartManager.shared.resolveMbidFetches(for: primary, with: .notFound) }
                return
            }

            let lowerPrimary = primary.lowercased()

            let parseScore: ([String: Any]) -> Int = { dict in
                if let intVal = dict["score"] as? Int { return intVal }
                if let strVal = dict["score"] as? String, let intVal = Int(strVal) { return intVal }
                return 0
            }

            // 1. Prefer an artist whose name or sort-name is an exact match
            if let exactMatch = artists.first(where: {
                let name = ($0["name"] as? String)?.lowercased()
                let sortName = ($0["sort-name"] as? String)?.lowercased()
                return name == lowerPrimary || sortName == lowerPrimary
            }), let id = exactMatch["id"] as? String {
                Task { @MainActor in
                    FanartManager.shared.mbidCache[primary] = id
                    FanartManager.shared.resolveMbidFetches(for: primary, with: .found(id))
                }
                return
            }

            // 2. Fallback: accept highest score candidate if >= 90
            let topScore = artists.first.map { parseScore($0) } ?? 0
            let topScoreCandidates = artists.filter { parseScore($0) == topScore }
            if topScore >= 90 {
                let candidate = topScoreCandidates.first(where: { ($0["name"] as? String)?.lowercased() == lowerPrimary }) ?? (topScoreCandidates.count == 1 ? topScoreCandidates.first : nil)
                if let id = candidate?["id"] as? String {
                    Task { @MainActor in
                        FanartManager.shared.mbidCache[primary] = id
                        FanartManager.shared.resolveMbidFetches(for: primary, with: .found(id))
                    }
                    return
                }
            }

            // 3. No reliable match found
            Task { @MainActor in FanartManager.shared.resolveMbidFetches(for: primary, with: .notFound) }
        }
        }
    }

    @MainActor
    private func resolveMbidFetches(for artist: String, with result: MBIDResult) {
        let callbacks = activeMbidFetches.removeValue(forKey: artist) ?? []
        for callback in callbacks {
            callback(result)
        }
    }
}
