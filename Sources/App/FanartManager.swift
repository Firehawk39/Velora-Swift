import SwiftUI
import Foundation

@MainActor
final class FanartManager: ObservableObject {
    static let shared = FanartManager()

    @Published var currentBackdrop: UIImage? = nil
    @Published var currentClearLogo: UIImage? = nil
    private let imageCache = NSCache<NSString, UIImage>()
    private let logoCache  = NSCache<NSString, UIImage>()

    private let fileManager = FileManager.default
    private let backdropDir: URL
    private let portraitDir: URL
    private let clearLogoDir: URL

    // Fanart.tv API Key - Provided by user
    private let fanartApiKey = "faceb56eac838d3e1c2a3ed15bf65a80"

    init() {
        self.backdropDir   = VeloraStorage.backdrops
        self.portraitDir   = VeloraStorage.artistPortraits
        self.clearLogoDir  = VeloraStorage.clearLogos
    }

    // MARK: - TTL Helper

    private func isNegativeCacheExpired(at url: URL, daysTTL: Int = 30) -> Bool {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attr[.modificationDate] as? Date else {
            return true // If we can't read it, assume expired so it gets cleaned up
        }
        let age = Date().timeIntervalSince(modDate)
        return age > TimeInterval(daysTTL * 24 * 60 * 60)
    }

    // MARK: - Backdrops

    private var activeBackdropFetches = Set<String>()
    private var currentArtistName: String?

    /// Synchronously checks if a backdrop exists in cache and returns it
    func getCachedBackdrop(for artist: String, artistId: String? = nil) -> UIImage? {
        let key = getCacheKey(artistName: artist, artistId: artistId)
        if let memoryCached = imageCache.object(forKey: key as NSString) {
            return memoryCached
        }

        let fileName = key + ".jpg"
        let fileUrl = self.backdropDir.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            self.imageCache.setObject(image, forKey: key as NSString)
            return image
        }
        return nil
    }

    func hasBackdrop(for artist: String, artistId: String? = nil) -> Bool {
        let key = getCacheKey(artistName: artist, artistId: artistId)
        let fileUrl = self.backdropDir.appendingPathComponent(key + ".jpg")
        return FileManager.default.fileExists(atPath: fileUrl.path)
    }

    func hasPortrait(for artist: String) -> Bool {
        let sanitized = sanitizeFileName(artist)
        let fileUrl = self.portraitDir.appendingPathComponent(sanitized + ".jpg")
        return FileManager.default.fileExists(atPath: fileUrl.path)
    }

    func hasClearLogo(for artist: String) -> Bool {
        let key = "logo_" + sanitizeFileName(artist)
        let fileUrl = clearLogoDir.appendingPathComponent(key + ".png")
        return fileManager.fileExists(atPath: fileUrl.path)
    }

    func fetchBackdrop(for artists: [String], artistId: String? = nil, mbid: String? = nil, allowNetwork: Bool = true) {
        guard !artists.isEmpty else { return }
        let primaryArtist = artists[0]
        let isNewArtist = self.currentArtistName != primaryArtist

        // 1. Check Cache Synchronously BEFORE nilling anything
        for (index, artist) in artists.enumerated() {
            let currentArtistId = (index == 0) ? artistId : nil
            if let cached = getCachedBackdrop(for: artist, artistId: currentArtistId) {
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
            let key = getCacheKey(artistName: artist, artistId: currentArtistId)
            let fileUrl = self.backdropDir.appendingPathComponent(key + ".jpg")
            if FileManager.default.fileExists(atPath: fileUrl.path),
               let attr = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
               let size = attr[.size] as? Int64, size == 0 {
                if NetworkMonitor.shared.isConnected {
                    // SELF-HEAL: Delete the marker and try fetching again since we are online.
                    try? FileManager.default.removeItem(at: fileUrl)
                } else {
                    continue // Offline, so trust the marker and skip
                }
            }
        }

        // 2. Clear current UI if new artist
        if isNewArtist {
            self.currentArtistName = primaryArtist
            withAnimation(.easeInOut(duration: 0.4)) { self.currentBackdrop = nil }
        }

        fetchBackdropRecursive(artists: artists, index: 0, artistId: artistId, providedMbid: mbid, allowNetwork: allowNetwork)
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

        let queryFanart: @MainActor @Sendable (String) -> Void = { resolvedMBID in
            AppLogger.shared.log("[Fanart] Querying Fanart.tv for \(artist) (MBID: \(resolvedMBID))")
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist) { url, isEmpty in
                if let url = url {
                    AppLogger.shared.log("[Fanart] Found backdrop URL for \(artist)")
                    self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, cacheKey: key, priority: URLSessionTask.highPriority) { image in
                        self.activeBackdropFetches.remove(key)
                    }
                } else {
                    if isEmpty {
                        AppLogger.shared.log("[Fanart] No backdrop found for \(artist)")
                        try? Data().write(to: fileUrl)
                    } else {
                        AppLogger.shared.log("[Fanart] Fetch failed/rate-limited for \(artist)")
                    }
                    self.activeBackdropFetches.remove(key)
                    self.fetchBackdropRecursive(artists: artists, index: index + 1, artistId: nil, providedMbid: nil, allowNetwork: allowNetwork)
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
                    self.activeBackdropFetches.remove(key)
                    self.fetchBackdropRecursive(artists: artists, index: index + 1, artistId: nil, providedMbid: nil, allowNetwork: allowNetwork)
                }
            }
        }
    }

    func downloadBackdropSilently(for artists: [String], artistId: String? = nil, mbid: String? = nil) async {
        guard !artists.isEmpty else { return }
        let primaryArtist = artists[0]

        for (index, artist) in artists.enumerated() {
            let key = getCacheKey(artistName: artist, artistId: index == 0 ? artistId : nil)
            let fileUrl = backdropDir.appendingPathComponent(key + ".jpg")

            if fileManager.fileExists(atPath: fileUrl.path) {
                if let attr = try? fileManager.attributesOfItem(atPath: fileUrl.path), let size = attr[.size] as? Int64, size > 0 {
                    return // Found a valid image!
                }
                if index == artists.count - 1 { return } // Last fallback artist has a marker, we're done
                continue // Current artist has marker, try next
            }

            let alreadyFetching = activeBackdropFetches.contains(key)
            if !alreadyFetching { activeBackdropFetches.insert(key) }
            if alreadyFetching { return }

            guard NetworkMonitor.shared.isConnected else {
                self.activeBackdropFetches.remove(key)
                return
            }

            let success: Bool = await withCheckedContinuation { continuation in
                let query: @MainActor @Sendable (String) -> Void = { resolvedMBID in
                    let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
                    self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist, priority: URLSessionTask.lowPriority) { url, isEmpty in
                        if let url = url {
                            self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, cacheKey: key, priority: URLSessionTask.lowPriority) { _ in
                                self.activeBackdropFetches.remove(key)
                                continuation.resume(returning: true)
                            }
                        } else {
                            if isEmpty && NetworkMonitor.shared.isConnected {
                                try? Data().write(to: fileUrl)
                            }
                            self.activeBackdropFetches.remove(key)
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
                            if NetworkMonitor.shared.isConnected { try? Data().write(to: fileUrl) }
                            self.activeBackdropFetches.remove(key)
                            continuation.resume(returning: false)
                        }
                    }
                }
            }

            if success { return } // We got one, stop cascading
        }
    }

    // MARK: - Artist Portraits

    func downloadArtistPortraitSilently(for artist: String, artistId: String, mbid: String? = nil) async {
        let fileUrl = portraitDir.appendingPathComponent("\(artistId).jpg")

        if fileManager.fileExists(atPath: fileUrl.path) {
            if let attr = try? fileManager.attributesOfItem(atPath: fileUrl.path), let size = attr[.size] as? Int64, size > 0 {
                return // Found a valid image!
            }
            return // Skip if negative cached
        }

        guard NetworkMonitor.shared.isConnected else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let query: @MainActor @Sendable (String) -> Void = { resolvedMBID in
                let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
                self.fetchFromFanart(urlString: urlString, type: .portrait, artistName: artist, priority: URLSessionTask.lowPriority) { url, isEmpty in
                    if let url = url {
                        self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: artist, cacheKey: artistId, priority: URLSessionTask.lowPriority) { _ in
                            continuation.resume()
                        }
                    } else {
                        if isEmpty && NetworkMonitor.shared.isConnected {
                            try? Data().write(to: fileUrl)
                        }
                        continuation.resume()
                    }
                }
            }

            if let validMBID = mbid, !validMBID.isEmpty {
                Task { @MainActor in query(validMBID) }
            } else {
                getMBID(for: artist, priority: URLSessionTask.lowPriority) { resolved in
                    if let resolved = resolved {
                        Task { @MainActor in query(resolved) }
                    } else {
                        if NetworkMonitor.shared.isConnected { try? Data().write(to: fileUrl) }
                        continuation.resume()
                    }
                }
            }
        }
    }

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
                    self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: artist, cacheKey: self.getCacheKey(artistName: artist), completion: completion)
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
                self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: artist, cacheKey: self.getCacheKey(artistName: artist), priority: URLSessionTask.highPriority, completion: completion)
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

    // MARK: - Clear Logos

    private var activeClearLogoFetches = Set<String>()
    private var currentClearLogoArtist: String?

    /// Fetch the hdmusiclogo (transparent PNG) for `artist` and update `currentClearLogo`.
    /// Falls back to `hdmusiclogo` → `musiclogo` in the API response.
    ///
    /// IMPORTANT: This function ALWAYS validates the cached logo against the artist's
    /// MusicBrainz ID before serving it. This prevents "Zimmer" from showing "Hans Zimmer"'s
    /// logo when the wrong logo was previously cached.
    func fetchClearLogo(for artist: String, mbid: String? = nil) {
        let isNewArtist = self.currentClearLogoArtist != artist
        if isNewArtist {
            self.currentClearLogoArtist = artist
            // Instantly clear old stale logo so it doesn't linger while resolving or fetching
            withAnimation(.easeOut(duration: 0.2)) { self.currentClearLogo = nil }
        }

        let key = "logo_" + sanitizeFileName(artist)
        let fileUrl = clearLogoDir.appendingPathComponent(key + ".png")
        let sidecarUrl = clearLogoDir.appendingPathComponent(key + ".mbid")

        // 1. Disk cache hit — ALWAYS validate via sidecar before serving
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            if let data = try? Data(contentsOf: fileUrl), !data.isEmpty, let img = UIImage(data: data) {
                let cachedMbid = (try? String(contentsOf: sidecarUrl, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let knownMbid = mbid, !knownMbid.isEmpty {
                    // Caller supplied an authoritative MBID (e.g. from Navidrome) — validate immediately.
                    if cachedMbid == knownMbid {
                        // MBID matches — safe to serve.
                        logoCache.setObject(img, forKey: key as NSString)
                        withAnimation(.easeInOut(duration: 0.5)) { self.currentClearLogo = img }
                        return
                    } else {
                        // Mismatch — cached logo belongs to a different artist. Wipe it.
                        AppLogger.shared.log("[Fanart] Clearlogo MBID mismatch for \(artist) (cached: \(cachedMbid ?? "none"), expected: \(knownMbid)) — wiping stale cache.", level: .info)
                        try? FileManager.default.removeItem(at: fileUrl)
                        try? FileManager.default.removeItem(at: sidecarUrl)
                        logoCache.removeObject(forKey: key as NSString)
                        // Fall through to network fetch below
                    }
                } else if let cachedMbid = cachedMbid, !cachedMbid.isEmpty {
                    // No caller-MBID but sidecar exists — must resolve MBID to validate.
                    // Don't serve until confirmed correct (prevents showing Hans Zimmer's logo).
                    withAnimation(.easeInOut(duration: 0.3)) { self.currentClearLogo = nil }
                    guard !activeClearLogoFetches.contains(key) else { return }
                    activeClearLogoFetches.insert(key)
                    getMBID(for: artist) { [weak self] resolved in
                        guard let self = self else { return }
                        if let resolved = resolved, resolved == cachedMbid {
                            // Confirmed — serve cached logo.
                            self.logoCache.setObject(img, forKey: key as NSString)
                            if self.currentClearLogoArtist == artist {
                                withAnimation(.easeInOut(duration: 0.5)) { self.currentClearLogo = img }
                            }
                            self.activeClearLogoFetches.remove(key)
                        } else {
                            // Wrong artist in cache — wipe and fetch the correct logo.
                            AppLogger.shared.log("[Fanart] Clearlogo confirmed wrong artist for \(artist) — wiping and re-fetching.", level: .info)
                            try? FileManager.default.removeItem(at: fileUrl)
                            try? FileManager.default.removeItem(at: sidecarUrl)
                            self.logoCache.removeObject(forKey: key as NSString)
                            self.activeClearLogoFetches.remove(key)
                            if let resolved = resolved {
                                self.fetchClearLogo(for: artist, mbid: resolved)
                            } else {
                                // Can't resolve MBID — write negative marker to stop retries.
                                try? Data().write(to: fileUrl)
                            }
                        }
                    }
                    return
                } else {
                    // No sidecar: legacy cache with no MBID metadata.
                    // Serve it but retroactively write a sidecar for future validation.
                    logoCache.setObject(img, forKey: key as NSString)
                    if self.currentClearLogoArtist == artist {
                        withAnimation(.easeInOut(duration: 0.5)) { self.currentClearLogo = img }
                    }
                    Task { [weak self] in
                        guard let self = self else { return }
                        await self.validateAndRepairClearLogoSidecar(artist: artist, sidecarUrl: sidecarUrl)
                    }
                    return
                }
            } else {
                // Empty or invalid file — negative cache entry
                if isNegativeCacheExpired(at: fileUrl) {
                    AppLogger.shared.log("[Fanart] Wiping old negative clearlogo cache for \(artist) to allow retry")
                    try? FileManager.default.removeItem(at: fileUrl)
                    try? FileManager.default.removeItem(at: sidecarUrl)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) { self.currentClearLogo = nil }
                    return
                }
            }
        }

        // 2. Memory cache
        if let cached = logoCache.object(forKey: key as NSString) {
            if self.currentClearLogoArtist == artist {
                withAnimation(.easeInOut(duration: 0.5)) { self.currentClearLogo = cached }
            }
            return
        }

        // 3. Guard dedup
        guard !activeClearLogoFetches.contains(key) else { return }
        activeClearLogoFetches.insert(key)

        // Clear stale logo immediately while we fetch
        withAnimation(.easeInOut(duration: 0.3)) { self.currentClearLogo = nil }

        guard NetworkMonitor.shared.isConnected else {
            activeClearLogoFetches.remove(key)
            return
        }

        // 4. Resolve MBID then fetch from Fanart.tv (fallback: TheAudioDB)
        let doFetch: (String) -> Void = { [weak self] resolvedMbid in
            guard let self = self else { return }
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMbid)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .clearlogo, artistName: artist, priority: URLSessionTask.highPriority) { [weak self] url, _ in
                guard let self = self else { return }
                if let url = url {
                    AppLogger.shared.log("[Fanart] Fetched clearlogo from Fanart for \(artist)")
                    self.downloadClearLogoFile(from: url, to: fileUrl, artist: artist, cacheKey: key, usedMbid: resolvedMbid)
                } else {
                    AppLogger.shared.log("[Fanart] Fanart has no clearlogo for \(artist), trying TheAudioDB fallback...")
                    self.fetchFromTheAudioDB(artistName: artist, mbid: resolvedMbid, priority: URLSessionTask.highPriority) { [weak self] tadbUrl in
                        guard let self = self else { return }
                        if let tadbUrl = tadbUrl {
                            AppLogger.shared.log("[Fanart] Fetched clearlogo from TheAudioDB for \(artist)")
                            self.downloadClearLogoFile(from: tadbUrl, to: fileUrl, artist: artist, cacheKey: key, usedMbid: resolvedMbid)
                        } else {
                            AppLogger.shared.log("[Fanart] TheAudioDB also has no clearlogo for \(artist). Writing negative cache.")
                            try? Data().write(to: fileUrl)
                            self.activeClearLogoFetches.remove(key)
                        }
                    }
                }
            }
        }

        if let m = mbid, !m.isEmpty {
            doFetch(m)
        } else {
            getMBID(for: artist) { [weak self] resolved in
                guard let self = self else { return }
                if let resolved = resolved {
                    doFetch(resolved)
                } else {
                    try? Data().write(to: fileUrl)  // negative marker — no MBID found
                    self.activeClearLogoFetches.remove(key)
                }
            }
        }
    }

    /// Resolves the correct MBID for `artist` and writes a sidecar file retroactively
    /// for legacy cached logos that have no MBID metadata. This ensures the next call
    /// with an authoritative MBID will be able to detect and correct a wrong logo.
    private func validateAndRepairClearLogoSidecar(artist: String, sidecarUrl: URL) async {
        return await withCheckedContinuation { continuation in
            self.getMBID(for: artist) { resolved in
                if let resolved = resolved {
                    try? resolved.write(to: sidecarUrl, atomically: true, encoding: .utf8)
                    AppLogger.shared.log("[Fanart] Retroactively wrote sidecar for \(artist): \(resolved)", level: .info)
                }
                continuation.resume()
            }
        }
    }

    /// Background-priority prefetch — same as fetchClearLogo but lower network priority.
    func downloadClearLogoSilently(for artist: String, mbid: String? = nil) async {
        let key = "logo_" + sanitizeFileName(artist)
        let fileUrl = clearLogoDir.appendingPathComponent(key + ".png")
        let sidecarUrl = clearLogoDir.appendingPathComponent(key + ".mbid")

        if FileManager.default.fileExists(atPath: fileUrl.path) {
            if let data = try? Data(contentsOf: fileUrl), !data.isEmpty {
                let cachedMbid = (try? String(contentsOf: sidecarUrl, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let knownMbid = mbid, !knownMbid.isEmpty {
                    if cachedMbid == knownMbid {
                        return // valid cache
                    } else {
                        // Wrong artist — wipe and fall through to re-fetch
                        AppLogger.shared.log("[Fanart] Silent prefetch: MBID mismatch for \(artist) — wiping.", level: .info)
                        try? FileManager.default.removeItem(at: fileUrl)
                        try? FileManager.default.removeItem(at: sidecarUrl)
                    }
                } else {
                    return // No MBID to validate against, trust existing cache
                }
            } else {
                if isNegativeCacheExpired(at: fileUrl) {
                    try? FileManager.default.removeItem(at: fileUrl)
                    try? FileManager.default.removeItem(at: sidecarUrl)
                } else {
                    return
                }
            }
        }

        guard NetworkMonitor.shared.isConnected else { return }
        guard !activeClearLogoFetches.contains(key) else { return }
        activeClearLogoFetches.insert(key)

        let resolve: (String) -> Void = { [weak self] resolvedMbid in
            guard let self = self else { return }
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMbid)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .clearlogo, artistName: artist, priority: URLSessionTask.lowPriority) { [weak self] url, _ in
                guard let self = self else { return }
                if let url = url {
                    self.downloadClearLogoFile(from: url, to: fileUrl, artist: artist, cacheKey: key, usedMbid: resolvedMbid)
                } else {
                    self.fetchFromTheAudioDB(artistName: artist, mbid: resolvedMbid, priority: URLSessionTask.lowPriority) { [weak self] tadbUrl in
                        guard let self = self else { return }
                        if let tadbUrl = tadbUrl {
                            self.downloadClearLogoFile(from: tadbUrl, to: fileUrl, artist: artist, cacheKey: key, usedMbid: resolvedMbid)
                        } else {
                            try? Data().write(to: fileUrl)
                            self.activeClearLogoFetches.remove(key)
                        }
                    }
                }
            }
        }

        if let m = mbid, !m.isEmpty {
            resolve(m)
        } else {
            getMBID(for: artist) { [weak self] resolved in
                guard let self = self else { return }
                if let r = resolved { resolve(r) } else {
                    try? Data().write(to: fileUrl)
                    self.activeClearLogoFetches.remove(key)
                }
            }
        }
    }

    private func downloadClearLogoFile(from urlString: String, to localUrl: URL, artist: String, cacheKey: String, usedMbid: String? = nil) {
        guard let url = URL(string: urlString) else {
            activeClearLogoFetches.remove(cacheKey)
            return
        }
        ThrottledNetworkManager.shared.enqueue(url: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let data = data, let img = UIImage(data: data) {
                    try? data.write(to: localUrl)
                    // Always write sidecar MBID so future cache loads can validate artist identity
                    if let mbid = usedMbid, !mbid.isEmpty {
                        let sidecarUrl = localUrl.deletingPathExtension().appendingPathExtension("mbid")
                        try? mbid.write(to: sidecarUrl, atomically: true, encoding: .utf8)
                    }
                    self.logoCache.setObject(img, forKey: cacheKey as NSString)
                    if self.currentClearLogoArtist == artist {
                        withAnimation(.easeInOut(duration: 0.6)) { self.currentClearLogo = img }
                    }
                } else {
                    try? Data().write(to: localUrl)  // negative marker
                }
                self.activeClearLogoFetches.remove(cacheKey)
            }
        }
    }

    // MARK: - TheAudioDB Fallback

    nonisolated private func fetchFromTheAudioDB(artistName: String, mbid: String? = nil, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (String?) -> Void) {
        let primary = extractPrimaryArtist(artistName)
        
        let urlString: String
        if let knownMbid = mbid, !knownMbid.isEmpty {
            urlString = "https://theaudiodb.com/api/v1/json/2/artist-mb.php?i=\(knownMbid)"
        } else {
            let encoded = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? primary
            urlString = "https://www.theaudiodb.com/api/v1/json/2/search.php?s=\(encoded)"
        }
        
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        ThrottledNetworkManager.shared.enqueue(url: url, priority: priority) { data, response, error in
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let artists = json["artists"] as? [[String: Any]] {
                    
                    let lowerPrimary = primary.lowercased()
                    // CRITICAL: Strictly match artist name. TheAudioDB returns "Hans Zimmer"
                    // for queries like "Zimmer" — we must reject those.
                    // If we searched by MBID, we assume it's correct.
                    let matched = artists.first {
                        (mbid != nil && !mbid!.isEmpty) || ($0["strArtist"] as? String ?? "").lowercased() == lowerPrimary
                    }
                    if let matched = matched,
                       let logoUrl = matched["strArtistLogo"] as? String,
                       !logoUrl.isEmpty {
                        DispatchQueue.main.async { completion(logoUrl) }
                    } else {
                        DispatchQueue.main.async { completion(nil) }
                    }
                } else {
                    DispatchQueue.main.async { completion(nil) }
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: - API Helpers

    private enum FanartType { case background, portrait, clearlogo }

    nonisolated private func fetchFromFanart(urlString: String, type: FanartType, artistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (String?, Bool) -> Void) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil, false) }
            return
        }

        ThrottledNetworkManager.shared.enqueue(url: url, priority: priority) { data, response, error in
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

    nonisolated private func downloadAndCache(from urlString: String, to localUrl: URL, primaryArtistName: String, cacheKey: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (UIImage?) -> Void) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        ThrottledNetworkManager.shared.enqueue(url: url, priority: priority) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                try? data.write(to: localUrl)

                // CRITICAL: Even if this was a "silent" or background fetch,
                // if the artist is the one we are currently viewing, update the UI!
                DispatchQueue.main.async {
                    self.imageCache.setObject(image, forKey: cacheKey as NSString)
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

    nonisolated
    func getCacheKey(artistName: String, artistId: String? = nil) -> String {
        if let aid = artistId, !aid.isEmpty { return aid }
        return sanitizeFileName(artistName)
    }

    nonisolated func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }

    nonisolated private func extractPrimaryArtist(_ name: String) -> String {
        let delimiters = ["feat.", "ft.", " x ", " vs.", " featuring "]
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
        let queryTerm = "artist:\"\(primary)\""
        let encodedQuery = queryTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=\(encodedQuery)&fmt=json"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("VeloraApp/1.0 ( https://github.com/Firehawk39/Velora-Swift )", forHTTPHeaderField: "User-Agent")

        ThrottledNetworkManager.shared.enqueue(request: request, priority: priority) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]], !artists.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let lowerPrimary = primary.lowercased()

            // 1. Prefer an artist whose name is an exact case-insensitive match.
            //    This prevents "Zimmer" from resolving to "Hans Zimmer" which has
            //    "Zimmer" as a search-hint alias and ranks first in MusicBrainz results.
            if let exactMatch = artists.first(where: {
                ($0["name"] as? String)?.lowercased() == lowerPrimary
            }), let id = exactMatch["id"] as? String {
                DispatchQueue.main.async { completion(id) }
                return
            }

            // 2. Fallback: only accept the top result if it has the maximum possible
            //    score (100) AND the top-score group contains exactly one artist,
            //    meaning MusicBrainz itself is unambiguous about the match.
            let topScore = artists.first.flatMap { $0["score"] as? Int } ?? 0
            let topScoreCandidates = artists.filter { ($0["score"] as? Int) == topScore }
            if topScore == 100, topScoreCandidates.count == 1,
               let id = topScoreCandidates.first?["id"] as? String {
                DispatchQueue.main.async { completion(id) }
                return
            }

            // 3. No reliable match found — return nil so callers don't show wrong art.
            DispatchQueue.main.async { completion(nil) }
        }
    }
}
