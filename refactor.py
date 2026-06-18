import sys

with open('Sources/App/FanartManager.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Replace fetchBackdrop block
old_fetch = '''    func fetchBackdrop(for artist: String, mbid: String? = nil) {
        let isNewArtist = self.currentArtistName != artist
        let sanitized = sanitizeFileName(artist)
        let fileUrl = self.backdropDir.appendingPathComponent(sanitized + ".jpg")
        
        // 1. Check Cache Synchronously BEFORE nilling anything
        if let cached = getCachedBackdrop(for: artist) {
            AppLogger.shared.log("[Fanart] Cache hit for \(artist)")
            self.currentArtistName = artist
            // Use animation if it's a new artist, otherwise just set it
            if isNewArtist {
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.currentBackdrop = cached
                }
            } else {
                self.currentBackdrop = cached
            }
            return
        }
        
        // 2. Check if we are ALREADY fetching it (e.g. from prefetch)
        let alreadyFetching = activeBackdropFetches.contains(sanitized)
        
        // 3. Only if NOT in cache and it's a new artist, immediately clear the stale backdrop.
        //    Previously we skipped nilling when alreadyFetching=true to allow "smooth transitions",
        //    but this caused stale backdrops to persist indefinitely when the prefetch was slow/failed.
        //    Now we always clear immediately so the dynamic gradient fallback shows right away.
        if isNewArtist {
            self.currentArtistName = artist
            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentBackdrop = nil
            }
        }
        
        if alreadyFetching { return }
        
        guard NetworkMonitor.shared.isConnected else {
            return
        }
        
        activeBackdropFetches.insert(sanitized)
        
        let queryFanart: @MainActor @Sendable (String) -> Void = { resolvedMBID in
            AppLogger.shared.log("[Fanart] Querying Fanart.tv for \(artist) (MBID: \(resolvedMBID))")
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist) { url in
                if let url = url {
                    AppLogger.shared.log("[Fanart] Found backdrop URL for \(artist)")
                    self.downloadAndCache(from: url, to: fileUrl, artistName: artist, priority: URLSessionTask.highPriority) { image in
                        self.activeBackdropFetches.remove(sanitized)
                    }
                } else {
                    AppLogger.shared.log("[Fanart] No backdrop found for \(artist)")
                    self.activeBackdropFetches.remove(sanitized)
                }
            }
        }
        
        // 3. Resolve MBID and Fetch
        guard let validMBID = mbid, !validMBID.isEmpty else {
            self.getMBID(for: artist, priority: URLSessionTask.highPriority) { resolved in
                if let resolved = resolved {
                    queryFanart(resolved)
                } else {
                    self.activeBackdropFetches.remove(sanitized)
                }
            }
            return
        }
        
        AppLogger.shared.log("[Fanart] Fetch start for \(artist)")
        queryFanart(validMBID)
    }'''

new_fetch = '''    func fetchBackdrop(for artists: [String], mbid: String? = nil) {
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
            self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist) { url in
                if let url = url {
                    AppLogger.shared.log("[Fanart] Found backdrop URL for \(artist)")
                    self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, priority: URLSessionTask.highPriority) { image in
                        self.activeBackdropFetches.remove(sanitized)
                    }
                } else {
                    AppLogger.shared.log("[Fanart] No backdrop found for \(artist)")
                    try? Data().write(to: fileUrl)
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
    }'''

content = content.replace(old_fetch, new_fetch)

# 2. Replace downloadBackdropSilently
old_silent = '''    func downloadBackdropSilently(for artist: String, mbid: String? = nil) async {
        let sanitized = sanitizeFileName(artist)
        let fileUrl = backdropDir.appendingPathComponent(sanitized + ".jpg")
        
        if fileManager.fileExists(atPath: fileUrl.path) { return }
        
        let alreadyFetching = activeBackdropFetches.contains(sanitized)
        if !alreadyFetching {
            activeBackdropFetches.insert(sanitized)
        }
        if alreadyFetching { return }
        
        guard NetworkMonitor.shared.isConnected else {
            self.activeBackdropFetches.remove(sanitized)
            return
        }
        
        await withCheckedContinuation { continuation in
            let query: @MainActor @Sendable (String) -> Void = { resolvedMBID in
                let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
                self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist, priority: URLSessionTask.lowPriority) { url in
                    if let url = url {
                        self.downloadAndCache(from: url, to: fileUrl, artistName: artist, priority: URLSessionTask.lowPriority) { _ in
                            self.activeBackdropFetches.remove(sanitized)
                            continuation.resume()
                        }
                    } else {
                        try? Data().write(to: fileUrl)
                        self.activeBackdropFetches.remove(sanitized)
                        continuation.resume()
                    }
                }
            }
            
            if let mbid = mbid, !mbid.isEmpty {
                Task { @MainActor in query(mbid) }
            } else {
                getMBID(for: artist, priority: URLSessionTask.lowPriority) { resolved in
                    if let resolved = resolved {
                        Task { @MainActor in query(resolved) }
                    } else {
                        try? Data().write(to: fileUrl)
                        self.activeBackdropFetches.remove(sanitized)
                        continuation.resume()
                    }
                }
            }
        }
    }'''

new_silent = '''    func downloadBackdropSilently(for artists: [String], mbid: String? = nil) async {
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
                    self.fetchFromFanart(urlString: urlString, type: .background, artistName: artist, priority: URLSessionTask.lowPriority) { url in
                        if let url = url {
                            self.downloadAndCache(from: url, to: fileUrl, primaryArtistName: primaryArtist, priority: URLSessionTask.lowPriority) { _ in
                                self.activeBackdropFetches.remove(sanitized)
                                continuation.resume(returning: true)
                            }
                        } else {
                            try? Data().write(to: fileUrl)
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
                            try? Data().write(to: fileUrl)
                            self.activeBackdropFetches.remove(sanitized)
                            continuation.resume(returning: false)
                        }
                    }
                }
            }
            
            if success { return } // We got one, stop cascading
        }
    }'''

content = content.replace(old_silent, new_silent)

# 3. Replace downloadAndCache signature and check
old_cache = '''nonisolated private func downloadAndCache(from urlString: String, to localUrl: URL, artistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (UIImage?) -> Void)'''
new_cache = '''nonisolated private func downloadAndCache(from urlString: String, to localUrl: URL, primaryArtistName: String, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable @MainActor (UIImage?) -> Void)'''
content = content.replace(old_cache, new_cache)

old_check = '''                    if self.currentArtistName == artistName {'''
new_check = '''                    if self.currentArtistName == primaryArtistName {'''
content = content.replace(old_check, new_check)

with open('Sources/App/FanartManager.swift', 'w', encoding='utf-8') as f:
    f.write(content)
print("done")
