import Foundation

extension NavidromeClient {
    


    // MARK: - Ping

    @discardableResult
    func ping() async -> (Bool, String?) {
        guard let url = buildUrl(method: "ping.view") else {
            return (false, "Invalid URL configuration.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            if decoded.subsonicResponse?.status == "ok" {
                return (true, nil)
            } else {
                return (false, decoded.subsonicResponse?.error?.message ?? "Authentication failed.")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Fetch Recently Played

    func fetchRecentlyPlayed() async {
        // Navidrome supports getRecentlyPlayed.view which returns actual recent tracks
        guard let url = buildUrl(method: "getRecentlyPlayed.view", params: ["size": "15"]) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            let recentlyPlayed = decoded.subsonicResponse?.recentlyPlayed
            let items = recentlyPlayed?.song ?? recentlyPlayed?.entry ?? []
            
            // Fallback to random if server doesn't support getRecentlyPlayed or it's empty
            if items.isEmpty {
                // Only fetch random if we don't have ANY recent tracks yet
                if self.recentlyPlayed.isEmpty {
                    await fetchRandomAsRecent()
                }
                return
            }
            
            let tracks = items.map { s in
                Track(id: s.id, title: s.title ?? "Unknown",
                       album: s.album ?? "Unknown Album", artist: s.artist ?? "Unknown Artist",
                       duration: s.duration ?? 0, coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                       artistId: s.artistId, albumId: s.albumId, suffix: s.suffix)
            }
            
            await MainActor.run {
                self.recentlyPlayed = tracks
            }
        } catch { 
            print("Error decoding recent songs: \(error)")
            await fetchRandomAsRecent()
        }
    }

    private func fetchRandomAsRecent() async {
        // Guard: Don't overwrite if we already have data (prevents jumpy UI)
        guard self.recentlyPlayed.isEmpty else { return }
        
        guard let url = buildUrl(method: "getRandomSongs.view", params: ["size": "15"]) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            let wrapper = decoded.subsonicResponse?.randomSongs ?? decoded.subsonicResponse?.randomSongs2
            let items = wrapper?.song ?? wrapper?.entry ?? []
            
            let tracks = items.map { s in
                Track(id: s.id, title: s.title ?? "Unknown",
                       album: s.album ?? "Unknown Album", artist: s.artist ?? "Unknown Artist",
                       duration: s.duration ?? 0, coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                       artistId: s.artistId, albumId: s.albumId, suffix: s.suffix)
            }
            
            await MainActor.run {
                self.recentlyPlayed = tracks
            }
        } catch { 
            print("Error decoding random songs as fallback: \(error)")
        }
    }

    // MARK: - Fetch Albums

    func fetchAlbums() async {
        guard let url = buildUrl(method: "getAlbumList.view", params: ["type": "alphabeticalByArtist", "size": "100"]) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            let items = decoded.subsonicResponse?.albumList?.album ?? decoded.subsonicResponse?.albumList2?.album ?? []
            let parsedAlbums = items.map { sub in
                Album(id: sub.id, name: sub.name ?? sub.title ?? "Unknown",
                      artist: sub.artist ?? "Unknown Artist", artistId: sub.artistId ?? "",
                      songCount: sub.songCount ?? 0, duration: sub.duration ?? 0,
                      coverArt: self.getCoverArtUrl(id: sub.coverArt ?? sub.id))
            }
            await MainActor.run {
                self.albums = parsedAlbums
                LocalMetadataStore.shared.saveAlbums(parsedAlbums)
            }
        } catch { print("Error decoding albums: \(error)") }
    }

    // MARK: - Fetch Artists

    @discardableResult
    func fetchArtists() async -> [Artist] {
        guard let url = buildUrl(method: "getArtists.view") else { 
            return []
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            var parsed: [Artist] = []
            for index in decoded.subsonicResponse?.artists?.index ?? [] {
                for sub in index.artist ?? [] {
                    parsed.append(Artist(id: sub.id, name: sub.name, coverArt: self.getCoverArtUrl(id: sub.id)))
                }
            }
            await MainActor.run { 
                self.artists = parsed 
                LocalMetadataStore.shared.saveArtists(parsed)
            }
            return parsed
        } catch { 
            print("Error decoding artists: \(error)") 
            return []
        }
    }

    // MARK: - Album Tracks

    @discardableResult
    func fetchAlbumTracks(albumId: String) async -> [Track] {
        guard let url = buildUrl(method: "getAlbum.view", params: ["id": albumId]) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
            
            await MainActor.run {
                LocalMetadataStore.shared.saveTracks(tracks)
            }
            return tracks
        } catch {
            print("Error fetching album tracks: \(error)")
            return []
        }
    }

    func fetchAlbumTracks(albumId: String, completion: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await fetchAlbumTracks(albumId: albumId)
            completion(tracks)
        }
    }

    func fetchArtistData(artistId: String) async -> ([Track], [Album], String?, String?) {
        guard let url = buildUrl(method: "getArtist.view", params: ["id": artistId]) else { return ([], [], nil, nil) }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
            
            // Fetch all tracks and artist info in parallel
            return await withTaskGroup(of: ArtistDataResult.self) { group in
                // 1. Fetch artist info
                group.addTask {
                    let info = await self.fetchArtistInfoAsync(artistId: artistId)
                    return .info(info.0, info.1)
                }
                
                // 2. Fetch all album tracks
                for album in albumsData {
                    group.addTask {
                        let tracks = await self.fetchAlbumTracks(albumId: album.id)
                        return .tracks(tracks)
                    }
                }
                
                var allTracks: [Track] = []
                var bio: String? = nil
                var mbid: String? = nil
                
                for await result in group {
                    switch result {
                    case .info(let b, let m):
                        bio = b
                        mbid = m
                    case .tracks(let tracks):
                        allTracks.append(contentsOf: tracks)
                    }
                }
                
                return (allTracks, albums, bio, mbid)
            }
        } catch {
            print("Error fetching artist data: \(error)")
            return ([], [], nil, nil)
        }
    }
    
    private enum ArtistDataResult {
        case info(String?, String?)
        case tracks([Track])
    }

    func fetchArtistData(artistId: String, completion: @escaping ([Track], [Album], String?, String?) -> Void) {
        Task {
            let result = await fetchArtistData(artistId: artistId)
            completion(result.0, result.1, result.2, result.3)
        }
    }

    func fetchArtistInfo(artistId: String, completion: @escaping (String?, String?) -> Void) {
        Task {
            let info = await fetchArtistInfoAsync(artistId: artistId)
            completion(info.0, info.1)
        }
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
    func searchAsync(query: String) async -> ([Track], [Album], [Artist]) {
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
        
        // 2. Background remote search to catch anything not yet synced
        guard let url = buildUrl(method: "search3.view", params: ["query": query]) else {
            return (localTracks, [], localArtists)
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
            
            // Proactively save results to local store
            await MainActor.run {
                LocalMetadataStore.shared.saveTracks(tracks)
                LocalMetadataStore.shared.saveArtists(artists)
                LocalMetadataStore.shared.saveAlbums(albums)
            }
            
            // Merge or return? Usually remote search returns everything including what's local.
            return (tracks, albums, artists)
        } catch {
            print("Error during remote search: \(error)")
            return (localTracks, [], localArtists)
        }
    }

    func search(query: String, completion: @escaping ([Track], [Album], [Artist]) -> Void) {
        // 1. Return local results immediately
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
        
        if !localTracks.isEmpty || !localArtists.isEmpty {
            completion(localTracks, [], localArtists)
        }
        
        // 2. Perform remote search
        Task {
            let result = await searchAsync(query: query)
            completion(result.0, result.1, result.2)
        }
    }

    // MARK: - Playlists

    func fetchPlaylists() async {
        guard let url = buildUrl(method: "getPlaylists.view") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
            let parsed = (decoded.subsonicResponse?.playlists?.playlist ?? []).map { p in
                Playlist(id: p.id, name: p.name, owner: p.owner, songCount: p.songCount, duration: p.duration, created: nil)
            }
            await MainActor.run {
                self.playlists = parsed
            }
        } catch { print("Error decoding playlists: \(error)") }
    }

    func fetchPlaylistTracks(playlistId: String) async -> [Track] {
        guard let url = buildUrl(method: "getPlaylist.view", params: ["id": playlistId]) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
            await MainActor.run { 
                LocalMetadataStore.shared.saveTracks(tracks)
            }
            return tracks
        } catch { return [] }
    }

    func fetchPlaylistTracks(playlistId: String, completion: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await fetchPlaylistTracks(playlistId: playlistId)
            completion(tracks)
        }
    }

    // MARK: - Playlist Management

    @discardableResult
    func createPlaylist(name: String, songIds: [String]) async -> Bool {
        let extra = songIds.map { URLQueryItem(name: "songId", value: $0) }
        guard let url = buildUrl(method: "createPlaylist.view", params: ["name": name], extraItems: extra) else {
            return false
        }
        do {
            let _ = try await URLSession.shared.data(from: url)
            await fetchPlaylists()
            return true
        } catch {
            return false
        }
    }

    func createPlaylist(name: String, songIds: [String], completion: @escaping (Bool) -> Void) {
        Task {
            let success = await createPlaylist(name: name, songIds: songIds)
            completion(success)
        }
    }

    @discardableResult
    func deletePlaylist(id: String) async -> Bool {
        guard let url = buildUrl(method: "deletePlaylist.view", params: ["id": id]) else {
            return false
        }
        do {
            let _ = try await URLSession.shared.data(from: url)
            await fetchPlaylists()
            return true
        } catch {
            return false
        }
    }

    func deletePlaylist(id: String, completion: @escaping (Bool) -> Void) {
        Task {
            let success = await deletePlaylist(id: id)
            completion(success)
        }
    }

    @discardableResult
    func updatePlaylist(id: String, songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = []) async -> Bool {
        var extra: [URLQueryItem] = []
        songIdsToAdd.forEach { extra.append(URLQueryItem(name: "songIdToAdd", value: $0)) }
        songIndicesToRemove.forEach { extra.append(URLQueryItem(name: "songIndexToRemove", value: String($0))) }
        
        guard let url = buildUrl(method: "updatePlaylist.view", params: ["playlistId": id], extraItems: extra) else {
            return false
        }
        
        do {
            let _ = try await URLSession.shared.data(from: url)
            return true
        } catch {
            return false
        }
    }
    
    func updatePlaylist(id: String, songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = [], completion: @escaping (Bool) -> Void) {
        Task {
            let success = await updatePlaylist(id: id, songIdsToAdd: songIdsToAdd, songIndicesToRemove: songIndicesToRemove)
            completion(success)
        }
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

    // MARK: - Song Fetching (Adaptive Batching)
    
    /// Modern async entry point for a complete library synchronization.
    func syncLibrary() async {
        AppLogger.shared.log("[Sync] Starting full library synchronization...", level: .info)
        
        // 1. Fetch recently played and playlists in parallel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchRecentlyPlayed() }
            group.addTask { await self.fetchPlaylists() }
        }
        
        // 2. Perform the high-performance track fetch which also populates artists and albums
        let tracks = await fetchAllTracksAsync()
        
        await MainActor.run {
            self.allSongs = tracks
            self.lastFullSync = Date()
            self.syncLosslessPlaylist()
            AppLogger.shared.log("[Sync] Finished fetching all \(tracks.count) songs and associated metadata.", level: .info)
        }
    }
    

    
    /// Fetches all tracks with adaptive limits and full pagination support.
    func fetchAllTracks(completion: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await fetchAllTracksAsync()
            completion(tracks)
        }
    }

    /// Async version of fetchAllTracks with adaptive batching and full pagination support.
    /// This method is the engine of the synchronization process.
    func fetchAllTracksAsync() async -> [Track] {
        var collectedTracks: [Track] = []
        var currentBatch = ProcessInfo.processInfo.processorCount <= 2 ? 400 : 800
        var offset = 0
        
        while true {
            guard let url = buildUrl(method: "search3.view", params: [
                "query": "",
                "songCount": "\(currentBatch)",
                "songOffset": "\(offset)"
            ]) else { break }
            
            let startTime = Date()
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let duration = Date().timeIntervalSince(startTime)
                
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let songs = (decoded.subsonicResponse?.searchResult3?.song ?? []).map { self.mapSubsonicSongToTrack($0) }
                
                if songs.isEmpty { break }
                
                collectedTracks.append(contentsOf: songs)
                
                // Proactively save to local store in batches
                await MainActor.run {
                    LocalMetadataStore.shared.saveTracks(songs)
                    
                    // Extract and save unique artists/albums from this batch to avoid memory pressure later
                    let batchArtists = Dictionary(grouping: songs, by: { $0.artistId }).compactMap { (id, tracks) -> Artist? in
                        guard let id = id, let first = tracks.first else { return nil }
                        return Artist(id: id, name: first.artist ?? "Unknown Artist", coverArt: self.getCoverArtUrl(id: id))
                    }
                    LocalMetadataStore.shared.saveArtists(batchArtists)
                    
                    let batchAlbums = Dictionary(grouping: songs, by: { $0.albumId }).compactMap { (id, tracks) -> Album? in
                        guard let id = id, let first = tracks.first else { return nil }
                        return Album(id: id, name: first.album ?? "Unknown Album", artist: first.artist, artistId: first.artistId ?? "", songCount: tracks.count, duration: tracks.reduce(0, { $0 + ($1.duration ?? 0) }), coverArt: first.coverArt)
                    }
                    LocalMetadataStore.shared.saveAlbums(batchAlbums)
                }
                
                // Adaptive logic: Target ~1s per request for stability
                if duration < 0.7 && currentBatch < 1500 {
                    currentBatch += 200
                } else if duration > 1.5 && currentBatch > 200 {
                    currentBatch -= 200
                }
                
                offset += songs.count
                if songs.count < currentBatch { break }
                
            } catch {
                AppLogger.shared.log("Navidrome: Error fetching songs page at offset \(offset): \(error)", level: .error)
                if currentBatch > 100 {
                    currentBatch /= 2
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                } else {
                    break
                }
            }
        }
        
        // Final update to client state for UI consistency
        let artists = await LocalMetadataStore.shared.fetchAllArtists().map { Artist(id: $0.id, name: $0.name, coverArt: $0.coverArt) }
        let albums = await LocalMetadataStore.shared.fetchAllAlbums().map { Album(id: $0.id, name: $0.name, artist: $0.artist, artistId: $0.artistId, songCount: $0.songCount, duration: $0.duration, coverArt: $0.coverArt) }
        
        await MainActor.run {
            self.artists = artists
            self.albums = albums
            self.lastFullSync = Date()
        }
        
        return collectedTracks
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
