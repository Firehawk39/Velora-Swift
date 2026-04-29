import Foundation

extension NavidromeClient {

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
        guard let url = buildUrl(method: "getRandomSongs.view", params: ["size": "15"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let items = decoded.subsonicResponse?.randomSongs?.song ?? decoded.subsonicResponse?.randomSongs2?.song ?? []
                DispatchQueue.main.async {
                    self.recentlyPlayed = items.map { s in
                        Track(id: s.id, title: s.title ?? "Unknown",
                              album: s.album ?? "Unknown Album", artist: s.artist ?? "Unknown Artist",
                              duration: s.duration ?? 0, coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                              artistId: s.artistId, albumId: s.albumId)
                    }
                }
            } catch { print("Error decoding recent songs: \(error)") }
        }.resume()
    }

    // MARK: - Fetch Albums

    func fetchAlbums() {
        guard let url = buildUrl(method: "getAlbumList.view", params: ["type": "alphabeticalByArtist", "size": "20"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let items = decoded.subsonicResponse?.albumList?.album ?? decoded.subsonicResponse?.albumList2?.album ?? []
                DispatchQueue.main.async {
                    self.albums = items.map { sub in
                        Album(id: sub.id, name: sub.name ?? sub.title ?? "Unknown",
                              artist: sub.artist ?? "Unknown Artist", artistId: sub.artistId ?? "",
                              songCount: sub.songCount ?? 0, duration: sub.duration ?? 0,
                              coverArt: self.getCoverArtUrl(id: sub.coverArt ?? sub.id))
                    }
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
                    completion?(parsed)
                }
            } catch { 
                print("Error decoding artists: \(error)") 
                completion?([])
            }
        }.resume()
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
                          artistId: s.artistId, albumId: s.albumId)
                    t.isStarred = s.starred != nil
                    t.playCount = s.playCount
                    return t
                }
                DispatchQueue.main.async { completion(tracks) }
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

    // MARK: - Search

    func search(query: String, completion: @escaping ([Track], [Album], [Artist]) -> Void) {
        guard let url = buildUrl(method: "search3.view", params: ["query": query]) else {
            completion([], [], []); return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion([], [], []); return }
            do {
                let r = try JSONDecoder().decode(SubsonicResponse.self, from: data).subsonicResponse?.searchResult3
                let tracks = (r?.song ?? []).map { s in
                    var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                          artist: s.artist ?? "", duration: s.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                          artistId: s.artistId, albumId: s.albumId)
                    t.isStarred = s.starred != nil
                    t.playCount = s.playCount
                    return t
                }
                let albums = (r?.album ?? []).map { sub in
                    Album(id: sub.id, name: sub.name ?? sub.title ?? "Unknown",
                          artist: sub.artist ?? "Unknown Artist", artistId: sub.artistId ?? "",
                          songCount: sub.songCount ?? 0, duration: sub.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: sub.coverArt ?? sub.id))
                }
                let artists = (r?.artist ?? []).map { sub in
                    Artist(id: sub.id, name: sub.name, coverArt: self.getCoverArtUrl(id: sub.id))
                }
                DispatchQueue.main.async { completion(tracks, albums, artists) }
            } catch { DispatchQueue.main.async { completion([], [], []) } }
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
                        Playlist(id: p.id, name: p.name, owner: p.owner, songCount: p.songCount, duration: p.duration)
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
                          artistId: s.artistId, albumId: s.albumId)
                    t.isStarred = s.starred != nil
                    t.playCount = s.playCount
                    return t
                }
                DispatchQueue.main.async { completion(tracks) }
            } catch { DispatchQueue.main.async { completion([]) } }
        }.resume()
    }

    // MARK: - All Songs

    func fetchAllSongs(size: Int = 500) {
        guard let url = buildUrl(method: "getRandomSongs.view", params: ["size": String(size)]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let songs = (decoded.subsonicResponse?.randomSongs?.song ?? decoded.subsonicResponse?.randomSongs2?.song ?? []).map { s in
                    var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                          artist: s.artist ?? "", duration: s.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                          artistId: s.artistId, albumId: s.albumId)
                    t.isStarred = s.starred != nil
                    t.playCount = s.playCount
                    return t
                }
                
                if !songs.isEmpty {
                    DispatchQueue.main.async { self.allSongs = songs }
                } else {
                    self.fetchAlphabeticalSongs()
                }
            } catch { 
                print("Error decoding random songs: \(error)")
                self.fetchAlphabeticalSongs()
            }
        }.resume()
    }

    private func fetchAlphabeticalSongs() {
        guard let url = buildUrl(method: "search3.view", params: ["query": "", "songCount": "500"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let songs = (decoded.subsonicResponse?.searchResult3?.song ?? []).map { s in
                    Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                          artist: s.artist ?? "", duration: s.duration ?? 0,
                          coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                          artistId: s.artistId, albumId: s.albumId)
                }
                DispatchQueue.main.async { self.allSongs = songs }
            } catch { print("Search fallback failed: \(error)") }
        }.resume()
    }

    // MARK: - Lyrics

    func fetchLyrics(artist: String, title: String, completion: @escaping (String?) -> Void) {
        guard let url = buildUrl(method: "getLyrics.view", params: ["artist": artist, "title": title]) else {
            completion(nil); return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion(nil); return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let lyrics = decoded.subsonicResponse?.lyrics?.value
                DispatchQueue.main.async { completion(lyrics) }
            } catch { DispatchQueue.main.async { completion(nil) } }
        }.resume()
    }

    // MARK: - Scrobbling

    func scrobble(id: String, submission: Bool) {
        guard let url = buildUrl(method: "scrobble.view", params: [
            "id": id,
            "time": "\(Int(Date().timeIntervalSince1970 * 1000))",
            "submission": submission ? "true" : "false"
        ]) else { return }
        URLSession.shared.dataTask(with: url) { _, _, error in
            if let error = error { print("Scrobble error: \(error)") }
        }.resume()
    }

    func reportNowPlaying(id: String) { scrobble(id: id, submission: false) }

    // MARK: - Batch Fetch

    func fetchEverything() {
        fetchRecentlyPlayed()
        fetchAlbums()
        fetchArtists()
        fetchPlaylists()
        fetchAllSongs()
    }

    // MARK: - Cache Management

    func clearCache() {
        DispatchQueue.main.async {
            self.artists.removeAll()
            self.albums.removeAll()
            self.allSongs.removeAll()
            self.playlists.removeAll()
            self.recentlyPlayed.removeAll()
        }
        URLCache.shared.removeAllCachedResponses()
        let tempDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            contents.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        fetchRecentlyPlayed()
        fetchAlbums()
        fetchArtists()
        fetchPlaylists()
        fetchAllSongs()
    }
}
