import Foundation

extension NavidromeClient {
    
    /// Orchestrates a full refresh of all library metadata (Artists, Albums, Playlists, and Songs).
    func fetchEverything() {
        fetchRecentlyPlayed()
        fetchAlbums()
        fetchArtists()
        fetchPlaylists()
        fetchAllSongs()
    }

    // MARK: - Ping

    func ping(completion: @escaping (Bool, String?) -> Void) {
        guard let url = buildUrl(method: "ping.view") else {
            completion(false, "Invalid URL configuration."); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { completion(false, error.localizedDescription); return }
            guard let data = data else { completion(false, "No data received."); return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                if decoded.subsonicResponse?.status == "ok" {
                    completion(true, nil)
                } else {
                    completion(false, decoded.subsonicResponse?.error?.message ?? "Authentication failed.")
                }
            } catch { completion(false, "Failed to parse server response.") }
        }.resume()
    }

    // MARK: - Fetch Recently Played

    func fetchRecentlyPlayed() {
        // Navidrome supports getRecentlyPlayed.view which returns actual recent tracks
        guard let url = buildUrl(method: "getRecentlyPlayed.view", params: ["size": "15"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let recentlyPlayed = decoded.subsonicResponse?.recentlyPlayed
                let items = recentlyPlayed?.song ?? recentlyPlayed?.entry ?? []
                
                // Fallback to random if server doesn't support getRecentlyPlayed or it's empty
                if items.isEmpty {
                    // Only fetch random if we don't have ANY recent tracks yet
                    // This prevents "jumpy" tracks when switching pages
                    if self.recentlyPlayed.isEmpty {
                        self.fetchRandomAsRecent()
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.recentlyPlayed = items.map { s in
                        Track(id: s.id, title: s.title ?? "Unknown",
                               album: s.album ?? "Unknown Album", artist: s.artist ?? "Unknown Artist",
                               duration: s.duration ?? 0, coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                               artistId: s.artistId, albumId: s.albumId, suffix: s.suffix)
                    }
                }
            } catch { 
                print("Error decoding recent songs: \(error)")
                self.fetchRandomAsRecent()
            }
        }.resume()
    }

    private func fetchRandomAsRecent() {
        // Guard: Don't overwrite if we already have data (prevents jumpy UI)
        guard self.recentlyPlayed.isEmpty else { return }
        
        guard let url = buildUrl(method: "getRandomSongs.view", params: ["size": "15"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let wrapper = decoded.subsonicResponse?.randomSongs ?? decoded.subsonicResponse?.randomSongs2
                let items = wrapper?.song ?? wrapper?.entry ?? []
                
                DispatchQueue.main.async {
                    self.recentlyPlayed = items.map { s in
                        Track(id: s.id, title: s.title ?? "Unknown",
                               album: s.album ?? "Unknown Album", artist: s.artist ?? "Unknown Artist",
                               duration: s.duration ?? 0, coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                               artistId: s.artistId, albumId: s.albumId, suffix: s.suffix)
                    }
                }
            } catch { print("Error decoding random songs as fallback: \(error)") }
        }.resume()
    }

    // MARK: - Fetch Albums

    func fetchAlbums() {
        guard let url = buildUrl(method: "getAlbumList.view", params: ["type": "alphabeticalByArtist", "size": "100"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let items = decoded.subsonicResponse?.albumList?.album ?? decoded.subsonicResponse?.albumList2?.album ?? []
                let parsedAlbums = items.map { sub in
                    Album(id: sub.id, name: sub.name ?? sub.title ?? "Unknown",
                          artist: sub.artist ?? "Unknown Artist", artistId: sub.artistId ?? "",
                          songCount: sub.songCount ?? 0, duration: sub.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: sub.coverArt ?? sub.id))
                }
                DispatchQueue.main.async {
                    self.albums = parsedAlbums
                    LocalMetadataStore.shared.saveAlbums(parsedAlbums)
                }
            } catch { print("Error decoding albums: \(error)") }
        }.resume()
    }

    // MARK: - Fetch Artists

    func fetchArtists(completion: (([Artist]) -> Void)? = nil) {
        guard let url = buildUrl(method: "getArtists.view") else { 
            completion?([])
            return 
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { 
                completion?([])
                return 
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                var parsed: [Artist] = []
                for index in decoded.subsonicResponse?.artists?.index ?? [] {
                    for sub in index.artist ?? [] {
                        parsed.append(Artist(id: sub.id, name: sub.name, coverArt: self.getCoverArtUrl(id: sub.id)))
                    }
                }
                DispatchQueue.main.async { 
                    self.artists = parsed 
                    LocalMetadataStore.shared.saveArtists(parsed)
                    completion?(parsed)
                }
            } catch { 
                print("Error decoding artists: \(error)") 
                completion?([])
            }
        }.resume()
    }

    /// Async version of fetchArtists for modern concurrency.
    @discardableResult
    func fetchArtistsAsync() async -> [Artist] {
        await withCheckedContinuation { continuation in
            fetchArtists { artists in
                continuation.resume(returning: artists)
            }
        }
    }

    // MARK: - Album Tracks

    func fetchAlbumTracks(albumId: String, completion: @escaping ([Track]) -> Void) {
        guard let url = buildUrl(method: "getAlbum.view", params: ["id": albumId]) else { completion([]); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion([]); return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let tracks = (decoded.subsonicResponse?.album?.song ?? []).map { s in
                    var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                          artist: s.artist ?? "", duration: s.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                          artistId: s.artistId, albumId: s.albumId, suffix: s.suffix)
                    t.isStarred = s.starred != nil
                    t.playCount = s.playCount
                    return t
                }
                DispatchQueue.main.async { 
                    completion(tracks)
                    LocalMetadataStore.shared.saveTracks(tracks)
                }
            } catch { DispatchQueue.main.async { completion([]) } }
        }.resume()
    }

    func fetchArtistData(artistId: String, completion: @escaping ([Track], [Album], String?, String?) -> Void) {
        guard let url = buildUrl(method: "getArtist.view", params: ["id": artistId]) else { completion([], [], nil, nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion([], [], nil, nil); return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let subsonicArtist = decoded.subsonicResponse?.artist
                let albumsData = subsonicArtist?.album ?? []
                
                let albums = albumsData.map { a -> Album in
                    Album(
                        id: a.id,
                        name: a.name ?? a.title ?? "Unknown Album",
                        artist: a.artist,
                        artistId: a.artistId,
                        songCount: a.songCount,
                        duration: a.duration,
                        coverArt: a.coverArt != nil ? self.getCoverArtUrl(id: a.coverArt!) : nil
                    )
                }
                
                var allTracks: [Track] = []
                let group = DispatchGroup()
                let lock = NSLock()
                
                for album in albumsData {
                    group.enter()
                    self.fetchAlbumTracks(albumId: album.id) { tracks in
                        lock.lock()
                        allTracks.append(contentsOf: tracks)
                        lock.unlock()
                        group.leave()
                    }
                }
                
                // Also fetch bio & MBID
                var bio: String? = nil
                var mbid: String? = nil
                group.enter()
                self.fetchArtistInfo(artistId: artistId) { b, m in
                    bio = b
                    mbid = m
                    group.leave()
                }
                
                group.notify(queue: .main) {
                    completion(allTracks, albums, bio, mbid)
                }
            } catch {
                print("Error decoding artist details: \(error)")
                DispatchQueue.main.async { completion([], [], nil, nil) }
            }
        }.resume()
    }

    func fetchArtistInfo(artistId: String, completion: @escaping (String?, String?) -> Void) {
        guard let url = buildUrl(method: "getArtistInfo.view", params: ["id": artistId]) else { completion(nil, nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion(nil, nil); return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let info = decoded.subsonicResponse?.artistInfo ?? decoded.subsonicResponse?.artistInfo2
                completion(info?.biography, info?.musicBrainzId)
            } catch { completion(nil, nil) }
        }.resume()
    }

    func fetchArtistInfoAsync(artistId: String) async -> (String?, String?) {
        guard let url = buildUrl(method: "getArtistInfo.view", params: ["id": artistId]) else { return (nil, nil) }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            let info = decoded.subsonicResponse?.artistInfo ?? decoded.subsonicResponse?.artistInfo2
            return (info?.biography, info?.musicBrainzId)
        } catch {
            AppLogger.shared.log("Navidrome: Error fetching artist info: \(error)", level: .error)
            return (nil, nil)
        }
    }

    // MARK: - Search
    
    /// High-performance search that queries the local persistence layer first for instant results.
    func search(query: String, completion: @escaping ([Track], [Album], [Artist]) -> Void) {
        // 1. Instant local search (Persistence Layer Optimization)
        let localTracks = LocalMetadataStore.shared.searchTracks(query: query).map { p in
            var t = Track(id: p.id, title: p.title, album: p.album ?? "", artist: p.artist ?? "",
                  duration: p.duration ?? 0, coverArt: p.coverArt ?? "",
                  artistId: p.artistId, albumId: p.albumId, suffix: p.suffix)
            t.isStarred = p.isStarred
            t.playCount = p.playCount
            return t
        }
        
        let localArtists = LocalMetadataStore.shared.searchArtists(query: query).map { p in
            Artist(id: p.id, name: p.name, coverArt: p.coverArt)
        }
        
        // If we have local results, return them immediately for UI responsiveness
        if !localTracks.isEmpty || !localArtists.isEmpty {
            DispatchQueue.main.async {
                completion(localTracks, [], localArtists)
            }
        }
        
        // 2. Background remote search to catch anything not yet synced
        guard let url = buildUrl(method: "search3.view", params: ["query": query]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let r = try JSONDecoder().decode(SubsonicResponse.self, from: data).subsonicResponse?.searchResult3
                let tracks = (r?.song ?? []).map { self.mapSubsonicSongToTrack($0) }
                let albums = (r?.album ?? []).map { sub in
                    Album(id: sub.id, name: sub.name ?? sub.title ?? "Unknown",
                          artist: sub.artist ?? "Unknown Artist", artistId: sub.artistId ?? "",
                          songCount: sub.songCount ?? 0, duration: sub.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: sub.coverArt ?? sub.id))
                }
                let artists = (r?.artist ?? []).map { sub in
                    Artist(id: sub.id, name: sub.name, coverArt: self.getCoverArtUrl(id: sub.id))
                }
                
                DispatchQueue.main.async {
                    completion(tracks, albums, artists)
                    
                    // Proactively save results to local store
                    LocalMetadataStore.shared.saveTracks(tracks)
                    LocalMetadataStore.shared.saveArtists(artists)
                    LocalMetadataStore.shared.saveAlbums(albums)
                }
            } catch { }
        }.resume()
    }

    // MARK: - Playlists

    func fetchPlaylists() {
        guard let url = buildUrl(method: "getPlaylists.view") else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                DispatchQueue.main.async {
                    self.playlists = (decoded.subsonicResponse?.playlists?.playlist ?? []).map { p in
                        Playlist(id: p.id, name: p.name, owner: p.owner, songCount: p.songCount, duration: p.duration, created: nil)
                    }
                }
            } catch { print("Error decoding playlists: \(error)") }
        }.resume()
    }

    func fetchPlaylistTracks(playlistId: String, completion: @escaping ([Track]) -> Void) {
        guard let url = buildUrl(method: "getPlaylist.view", params: ["id": playlistId]) else { completion([]); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion([]); return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let tracks = (decoded.subsonicResponse?.playlist?.entry ?? []).map { s in
                    var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                          artist: s.artist ?? "", duration: s.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                          artistId: s.artistId, albumId: s.albumId, suffix: s.suffix)
                    t.isStarred = s.starred != nil
                    t.playCount = s.playCount
                    return t
                }
                DispatchQueue.main.async { 
                    completion(tracks)
                    LocalMetadataStore.shared.saveTracks(tracks)
                }
            } catch { DispatchQueue.main.async { completion([]) } }
        }.resume()
    }

    // MARK: - Playlist Management

    func createPlaylist(name: String, songIds: [String], completion: @escaping (Bool) -> Void) {
        let extra = songIds.map { URLQueryItem(name: "songId", value: $0) }
        guard let url = buildUrl(method: "createPlaylist.view", params: ["name": name], extraItems: extra) else {
            completion(false); return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            let success = error == nil
            DispatchQueue.main.async {
                if success { self.fetchPlaylists() }
                completion(success)
            }
        }.resume()
    }

    func deletePlaylist(id: String, completion: @escaping (Bool) -> Void) {
        guard let url = buildUrl(method: "deletePlaylist.view", params: ["id": id]) else {
            completion(false); return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            let success = error == nil
            DispatchQueue.main.async {
                if success { self.fetchPlaylists() }
                completion(success)
            }
        }.resume()
    }

    func updatePlaylist(id: String, songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = [], completion: @escaping (Bool) -> Void) {
        var extra: [URLQueryItem] = []
        songIdsToAdd.forEach { extra.append(URLQueryItem(name: "songIdToAdd", value: $0)) }
        songIndicesToRemove.forEach { extra.append(URLQueryItem(name: "songIndexToRemove", value: String($0))) }
        
        guard let url = buildUrl(method: "updatePlaylist.view", params: ["playlistId": id], extraItems: extra) else {
            completion(false); return
        }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            let success = error == nil
            DispatchQueue.main.async { completion(success) }
        }.resume()
    }
    
    func syncLosslessPlaylist() {
        let flacIds = allSongs.filter { $0.suffix?.lowercased() == "flac" }.map { $0.id }
        guard !flacIds.isEmpty else { return }
        
        // 1. Check if "Lossless" playlist exists
        if let existing = playlists.first(where: { $0.name == "Lossless" }) {
            updatePlaylist(id: existing.id, songIdsToAdd: flacIds) { _ in
                print("Synced \(flacIds.count) tracks to existing Lossless playlist.")
            }
        } else {
            createPlaylist(name: "Lossless", songIds: flacIds) { success in
                if success { print("Created new Lossless playlist with \(flacIds.count) tracks.") }
            }
        }
    }

    // MARK: - All Songs (Adaptive Batching)
    
    /// Fetches all songs in the library using adaptive batching to prevent memory spikes.
    func fetchAllSongs() {
        self.allSongs.removeAll()
        // Start with a conservative batch size for older devices (SE 1st gen)
        let initialBatchSize = ProcessInfo.processInfo.processorCount <= 2 ? 300 : 1000
        fetchSongsPage(offset: 0, batchSize: initialBatchSize)
    }
    
    private func fetchSongsPage(offset: Int, batchSize: Int) {
        guard let url = buildUrl(method: "search3.view", params: [
            "query": "",
            "songCount": "\(batchSize)",
            "songOffset": "\(offset)"
        ]) else { return }
        
        let startTime = Date()
        URLSession.shared.dataTask(with: url) { data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            guard error == nil, let data = data else { 
                // Retry with smaller batch on error
                if batchSize > 100 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.fetchSongsPage(offset: offset, batchSize: batchSize / 2)
                    }
                }
                return 
            }
            
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let songs = (decoded.subsonicResponse?.searchResult3?.song ?? []).map { self.mapSubsonicSongToTrack($0) }
                
                if !songs.isEmpty {
                    DispatchQueue.main.async {
                        self.allSongs.append(contentsOf: songs)
                        LocalMetadataStore.shared.saveTracks(songs)
                        
                        // Adaptive logic: Target 1.5s per request for stability on older hardware
                        var nextBatchSize = batchSize
                        if duration < 0.8 && batchSize < 2000 {
                            nextBatchSize += 200
                        } else if duration > 3.0 && batchSize > 200 {
                            nextBatchSize -= 200
                        }
                        
                        self.fetchSongsPage(offset: offset + batchSize, batchSize: nextBatchSize)
                    }
                } else {
                    // Finished fetching all pages
                    DispatchQueue.main.async {
                        self.syncLosslessPlaylist()
                        AppLogger.shared.log("[Sync] Finished fetching all \(self.allSongs.count) songs.", level: .info)
                    }
                }
            } catch {
                print("Error decoding songs page at offset \(offset): \(error)")
                if batchSize > 100 {
                    self.fetchSongsPage(offset: offset, batchSize: batchSize / 2)
                }
            }
        }.resume()
    }

    /// Fetches all tracks for AI auditing with adaptive limits and full pagination support.
    func fetchAllTracks(completion: @escaping ([Track]) -> Void) {
        if !allSongs.isEmpty {
            completion(allSongs)
            return
        }
        
        var collectedTracks: [Track] = []
        let initialBatchSize = ProcessInfo.processInfo.processorCount <= 2 ? 400 : 800
        
        func fetchInternal(offset: Int, currentBatch: Int) {
            guard let url = buildUrl(method: "search3.view", params: [
                "query": "",
                "songCount": "\(currentBatch)",
                "songOffset": "\(offset)"
            ]) else {
                completion(collectedTracks)
                return
            }
            
            let startTime = Date()
            URLSession.shared.dataTask(with: url) { data, _, error in
                let duration = Date().timeIntervalSince(startTime)
                guard error == nil, let data = data else {
                    completion(collectedTracks); return
                }
                
                do {
                    let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                    let songs = (decoded.subsonicResponse?.searchResult3?.song ?? []).map { self.mapSubsonicSongToTrack($0) }
                    
                    if !songs.isEmpty {
                        collectedTracks.append(contentsOf: songs)
                        LocalMetadataStore.shared.saveTracks(songs)
                        
                        var nextBatchSize = currentBatch
                        if duration < 0.7 && currentBatch < 1500 {
                            nextBatchSize += 200
                        } else if duration > 2.0 && currentBatch > 200 {
                            nextBatchSize -= 200
                        }
                        
                        fetchInternal(offset: offset + currentBatch, currentBatch: nextBatchSize)
                    } else {
                        DispatchQueue.main.async { completion(collectedTracks) }
                    }
                } catch {
                    DispatchQueue.main.async { completion(collectedTracks) }
                }
            }.resume()
        }
        
        fetchInternal(offset: 0, currentBatch: initialBatchSize)
    }

    /// Async version of fetchAllTracks for modern concurrency.
    func fetchAllTracksAsync() async -> [Track] {
        await withCheckedContinuation { continuation in
            fetchAllTracks { tracks in
                continuation.resume(returning: tracks)
            }
        }
    }
    
    private func mapSubsonicSongToTrack(_ s: SubsonicSong) -> Track {
        var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
              artist: s.artist ?? "", duration: s.duration ?? 0,
              coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
              artistId: s.artistId, albumId: s.albumId, suffix: s.suffix)
        t.isStarred = s.starred != nil
        t.playCount = s.playCount ?? 0
        return t
    }

}
