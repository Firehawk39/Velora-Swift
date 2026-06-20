import Foundation

extension NavidromeClient {

    // MARK: - Ping

    func ping(completion: @escaping @MainActor @Sendable (Bool, String?) -> Void) {
        guard NetworkMonitor.shared.isConnected else {
            completion(false, "Offline mode is active."); return
        }
        guard let url = buildUrl(method: "ping.view") else {
            completion(false, "Invalid URL configuration."); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                let desc = error.localizedDescription
                DispatchQueue.main.async { completion(false, desc) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { completion(false, "No data received.") }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                if decoded.subsonicResponse?.status == "ok" {
                    DispatchQueue.main.async { completion(true, nil) }
                } else {
                    let msg = decoded.subsonicResponse?.error?.message ?? "Authentication failed."
                    DispatchQueue.main.async { completion(false, msg) }
                }
            } catch {
                DispatchQueue.main.async { completion(false, "Failed to parse server response.") }
            }
        }.resume()
    }

    // MARK: - Fetch Recently Played

    func fetchRecentlyPlayed() {
        guard NetworkMonitor.shared.isConnected else { return }
        guard let url = buildUrl(method: "getRecentlyPlayed.view", params: ["size": "15"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let recentlyPlayed = decoded.subsonicResponse?.recentlyPlayed
                let items = recentlyPlayed?.song ?? recentlyPlayed?.entry ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if items.isEmpty {
                        if self.recentlyPlayed.isEmpty {
                            self.fetchRandomAsRecent()
                        }
                        return
                    }
                    
                    self.recentlyPlayed = items.map { s in
                        var t = Track(id: s.id, title: s.title ?? "Unknown",
                               album: s.album ?? "Unknown Album", artist: s.artist ?? "Unknown Artist",
                               duration: s.duration ?? 0, coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                               artistId: s.artistId, albumId: s.albumId, suffix: s.suffix,
                               track: s.track, discNumber: s.discNumber)
                        t.created = s.created
                        return t
                    }
                    self.saveOfflineMetadata()
                }
            } catch { 
                print("Error decoding recent songs: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.fetchRandomAsRecent()
                }
            }
        }.resume()
    }

    private func fetchRandomAsRecent() {
        guard self.recentlyPlayed.isEmpty else { return }
        guard let url = buildUrl(method: "getRandomSongs.view", params: ["size": "15"]) else { return }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let wrapper = decoded.subsonicResponse?.randomSongs ?? decoded.subsonicResponse?.randomSongs2
                let items = wrapper?.song ?? wrapper?.entry ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.recentlyPlayed = items.map { s in
                        var t = Track(id: s.id, title: s.title ?? "Unknown",
                               album: s.album ?? "Unknown Album", artist: s.artist ?? "Unknown Artist",
                               duration: s.duration ?? 0, coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                               artistId: s.artistId, albumId: s.albumId, suffix: s.suffix,
                               track: s.track, discNumber: s.discNumber)
                        t.created = s.created
                        return t
                    }
                    self.saveOfflineMetadata()
                }
            } catch { print("Error decoding random songs as fallback: \(error)") }
        }.resume()
    }

    // MARK: - Fetch Albums

    func fetchAlbums() {
        guard NetworkMonitor.shared.isConnected else { return }
        guard let url = buildUrl(method: "getAlbumList.view", params: ["type": "alphabeticalByArtist", "size": "20"]) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let items = decoded.subsonicResponse?.albumList?.album ?? decoded.subsonicResponse?.albumList2?.album ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.albums = items.map { sub in
                        var a = Album(id: sub.id, name: sub.name ?? sub.title ?? "Unknown",
                              artist: sub.artist ?? "Unknown Artist", artistId: sub.artistId ?? "",
                              songCount: sub.songCount ?? 0, duration: sub.duration ?? 0,
                              coverArt: self.getCoverArtUrl(id: sub.coverArt ?? sub.id))
                        a.created = sub.created
                        return a
                    }
                    self.saveOfflineMetadata()
                }
            } catch { print("Error decoding albums: \(error)") }
        }.resume()
    }

    // MARK: - Fetch Artists

    func fetchArtists(completion: (@MainActor @Sendable ([Artist]) -> Void)? = nil) {
        guard NetworkMonitor.shared.isConnected else { 
            completion?([])
            return 
        }
        guard let url = buildUrl(method: "getArtists.view") else { 
            completion?([])
            return 
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { 
                DispatchQueue.main.async { completion?([]) }
                return 
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                
                struct RawArtist: Sendable {
                    let id: String
                    let name: String
                }
                var rawArtists: [RawArtist] = []
                for index in decoded.subsonicResponse?.artists?.index ?? [] {
                    for sub in index.artist ?? [] {
                        rawArtists.append(RawArtist(id: sub.id, name: sub.name))
                    }
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { completion?([]); return }
                    let parsed = rawArtists.map { raw in
                        Artist(id: raw.id, name: raw.name, coverArt: self.getCoverArtUrl(id: raw.id))
                    }
                    self.artists = parsed 
                    self.saveOfflineMetadata()
                    completion?(parsed)
                }
            } catch { 
                print("Error decoding artists: \(error)") 
                DispatchQueue.main.async { completion?([]) }
            }
        }.resume()
    }

    // MARK: - Album Tracks

    func fetchAlbumTracks(albumId: String, completion: @escaping @MainActor @Sendable ([Track]) -> Void) {
        guard NetworkMonitor.shared.isConnected else { completion([]); return }
        guard let url = buildUrl(method: "getAlbum.view", params: ["id": albumId]) else { completion([]); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let rawSongs = decoded.subsonicResponse?.album?.song ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { completion([]); return }
                    let tracks = rawSongs.map { s in
                        var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                              artist: s.artist ?? "", duration: s.duration ?? 0,
                              coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                              artistId: s.artistId, albumId: s.albumId, suffix: s.suffix,
                              track: s.track, discNumber: s.discNumber)
                        t.isStarred = s.starred != nil
                        t.playCount = s.playCount
                        t.created = s.created
                        return t
                    }
                    completion(tracks)
                }
            } catch {
                DispatchQueue.main.async { completion([]) }
            }
        }.resume()
    }

    func fetchArtistData(artistId: String, completion: @escaping @MainActor @Sendable ([Track], [Album], String?, String?) -> Void) {
        guard NetworkMonitor.shared.isConnected else {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let artistName = self.artists.first(where: { $0.id == artistId })?.name ?? ""
                let offlineAlbums = self.albums.filter { $0.artistId == artistId }
                let albumIds = Set(offlineAlbums.map { $0.id })
                let offlineTracks = self.allSongs.filter {
                    $0.artistId == artistId || (albumIds.contains($0.albumId ?? "")) || ($0.artist == artistName && !artistName.isEmpty)
                }
                // Filter to only downloaded tracks
                let downloadedTracks = PlaybackManager.shared?.filterOffline(offlineTracks) ?? offlineTracks
                completion(downloadedTracks, offlineAlbums, nil, nil)
            }
            return
        }
        guard let url = buildUrl(method: "getArtist.view", params: ["id": artistId]) else { completion([], [], nil, nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else {
                DispatchQueue.main.async { completion([], [], nil, nil) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let subsonicArtist = decoded.subsonicResponse?.artist
                let albumsData = subsonicArtist?.album ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { completion([], [], nil, nil); return }
                    
                    let albums = albumsData.map { a -> Album in
                        var albumModel = Album(
                            id: a.id,
                            name: a.name ?? a.title ?? "Unknown Album",
                            artist: a.artist,
                            artistId: a.artistId,
                            songCount: a.songCount,
                            duration: a.duration,
                            coverArt: a.coverArt != nil ? self.getCoverArtUrl(id: a.coverArt!) : nil
                        )
                        albumModel.created = a.created
                        return albumModel
                    }
                    
                    var allTracks: [Track] = []
                    var bio: String? = nil
                    var mbid: String? = nil
                    
                    let group = DispatchGroup()
                    
                    for album in albumsData {
                        group.enter()
                        self.fetchAlbumTracks(albumId: album.id) { tracks in
                            allTracks.append(contentsOf: tracks)
                            group.leave()
                        }
                    }
                    
                    group.enter()
                    self.fetchArtistInfo(artistId: artistId) { b, m in
                        bio = b
                        mbid = m
                        group.leave()
                    }
                    
                    group.notify(queue: .main) {
                        completion(allTracks, albums, bio, mbid)
                    }
                }
            } catch {
                print("Error decoding artist details: \(error)")
                DispatchQueue.main.async { completion([], [], nil, nil) }
            }
        }.resume()
    }

    func fetchArtistInfo(artistId: String, completion: @escaping @MainActor @Sendable (String?, String?) -> Void) {
        guard NetworkMonitor.shared.isConnected else { completion(nil, nil); return }
        guard let url = buildUrl(method: "getArtistInfo.view", params: ["id": artistId]) else { completion(nil, nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let info = decoded.subsonicResponse?.artistInfo ?? decoded.subsonicResponse?.artistInfo2
                let biography = info?.biography
                let musicBrainzId = info?.musicBrainzId
                DispatchQueue.main.async { completion(biography, musicBrainzId) }
            } catch {
                DispatchQueue.main.async { completion(nil, nil) }
            }
        }.resume()
    }

    // MARK: - Search

    func search(query: String, completion: @escaping @MainActor @Sendable ([Track], [Album], [Artist]) -> Void) {
        guard NetworkMonitor.shared.isConnected else {
            completion([], [], []); return
        }
        guard let url = buildUrl(method: "search3.view", params: ["query": query]) else {
            completion([], [], []); return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("[Search] Network error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion([], [], []) }
                return
            }
            guard let data = data else {
                print("[Search] No data received from server")
                DispatchQueue.main.async { completion([], [], []) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let r = decoded.subsonicResponse?.searchResult3
                let rawSongs = r?.song ?? []
                let rawAlbums = r?.album ?? []
                let rawArtists = r?.artist ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { completion([], [], []); return }
                    
                    let tracks = rawSongs.map { s in
                        var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                              artist: s.artist ?? "", duration: s.duration ?? 0,
                              coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                              artistId: s.artistId, albumId: s.albumId, suffix: s.suffix,
                              track: s.track, discNumber: s.discNumber)
                        t.isStarred = s.starred != nil
                        t.playCount = s.playCount
                        t.created = s.created
                        return t
                    }
                    let albums = rawAlbums.map { sub in
                        var a = Album(id: sub.id, name: sub.name ?? sub.title ?? "Unknown",
                              artist: sub.artist ?? "Unknown Artist", artistId: sub.artistId ?? "",
                              songCount: sub.songCount ?? 0, duration: sub.duration ?? 0,
                              coverArt: self.getCoverArtUrl(id: sub.coverArt ?? sub.id))
                        a.created = sub.created
                        return a
                    }
                    let artists = rawArtists.map { sub in
                        Artist(id: sub.id, name: sub.name, coverArt: self.getCoverArtUrl(id: sub.id))
                    }
                    completion(tracks, albums, artists)
                }
            } catch {
                print("[Search] JSON decode error: \(error)")
                DispatchQueue.main.async { completion([], [], []) }
            }
        }.resume()
    }

    // MARK: - Playlists

    func fetchPlaylists() {
        guard NetworkMonitor.shared.isConnected else { return }
        guard let url = buildUrl(method: "getPlaylists.view") else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let rawPlaylists = decoded.subsonicResponse?.playlists?.playlist ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.playlists = rawPlaylists.map { p in
                        Playlist(id: p.id, name: p.name, owner: p.owner, songCount: p.songCount, duration: p.duration, created: p.created)
                    }
                    self.saveOfflineMetadata()
                }
            } catch { print("Error decoding playlists: \(error)") }
        }.resume()
    }

    func fetchPlaylistTracks(playlistId: String, completion: @escaping @MainActor @Sendable ([Track]) -> Void) {
        guard NetworkMonitor.shared.isConnected else { completion([]); return }
        guard let url = buildUrl(method: "getPlaylist.view", params: ["id": playlistId]) else { completion([]); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let rawTracks = decoded.subsonicResponse?.playlist?.entry ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { completion([]); return }
                    let tracks = rawTracks.map { s in
                        var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                              artist: s.artist ?? "", duration: s.duration ?? 0,
                              coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                              artistId: s.artistId, albumId: s.albumId, suffix: s.suffix,
                              track: s.track, discNumber: s.discNumber)
                        t.isStarred = s.starred != nil
                        t.playCount = s.playCount
                        t.created = s.created
                        return t
                    }
                    completion(tracks)
                }
            } catch {
                DispatchQueue.main.async { completion([]) }
            }
        }.resume()
    }

    // MARK: - Playlist Management

    func createPlaylist(name: String, songIds: [String], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard NetworkMonitor.shared.isConnected else { completion(false); return }
        let extra = songIds.map { URLQueryItem(name: "songId", value: $0) }
        guard let url = buildUrl(method: "createPlaylist.view", params: ["name": name], extraItems: extra) else {
            completion(false); return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            let success = error == nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { completion(success); return }
                if success { self.fetchPlaylists() }
                completion(success)
            }
        }.resume()
    }

    func deletePlaylist(id: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard NetworkMonitor.shared.isConnected else { completion(false); return }
        guard let url = buildUrl(method: "deletePlaylist.view", params: ["id": id]) else {
            completion(false); return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            let success = error == nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { completion(success); return }
                if success { self.fetchPlaylists() }
                completion(success)
            }
        }.resume()
    }

    func updatePlaylist(id: String, songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = [], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard NetworkMonitor.shared.isConnected else { completion(false); return }
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

    // MARK: - All Songs

    func fetchAllSongs(completion: (@MainActor @Sendable ([Track]) -> Void)? = nil) {
        fetchSongsPage(offset: 0, batchSize: 500) { allFetchedSongs in
            // Guard: never overwrite good cached data with an empty result
            // (network failure returns [] via the pagination error path)
            guard !allFetchedSongs.isEmpty else {
                completion?(allFetchedSongs)
                return
            }
            self.allSongs = allFetchedSongs
            self.syncLosslessPlaylist()
            self.saveOfflineMetadata()
            completion?(allFetchedSongs)
        }
    }
    
    private func fetchSongsPage(offset: Int, batchSize: Int, allSongsSoFar: [Track] = [], completion: @escaping @MainActor @Sendable ([Track]) -> Void) {
        guard NetworkMonitor.shared.isConnected else { 
            completion(allSongsSoFar)
            return 
        }
        guard let url = buildUrl(method: "search3.view", params: ["query": "", "songCount": "\(batchSize)", "songOffset": "\(offset)"]) else { 
            completion(allSongsSoFar)
            return 
        }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { 
                DispatchQueue.main.async { completion(allSongsSoFar) }
                return 
            }
            
            do {
                let decoded = try JSONDecoder().decode(SubsonicResponse.self, from: data)
                let rawSongs = decoded.subsonicResponse?.searchResult3?.song ?? []
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { completion(allSongsSoFar); return }
                    let songs = rawSongs.map { s in
                        var t = Track(id: s.id, title: s.title ?? "Unknown", album: s.album ?? "",
                              artist: s.artist ?? "", duration: s.duration ?? 0,
                              coverArt: self.getCoverArtUrl(id: s.coverArt ?? s.id),
                              artistId: s.artistId, albumId: s.albumId, suffix: s.suffix,
                              track: s.track, discNumber: s.discNumber)
                        t.isStarred = s.starred != nil
                        t.playCount = s.playCount
                        t.created = s.created
                        return t
                    }
                    
                    if !songs.isEmpty {
                        let combined = allSongsSoFar + songs
                        self.fetchSongsPage(offset: offset + batchSize, batchSize: batchSize, allSongsSoFar: combined, completion: completion)
                    } else {
                        completion(allSongsSoFar)
                    }
                }
            } catch { 
                print("Error decoding search3.view at offset \(offset): \(error)")
                DispatchQueue.main.async { completion(allSongsSoFar) }
            }
        }.resume()
    }
    
    // MARK: - Cover Art Caching

    func downloadCoverArt(id: String) {
        let coverArtDir = VeloraStorage.coverArt
        let destinationUrl = coverArtDir.appendingPathComponent("\(id).jpg")
        
        if FileManager.default.fileExists(atPath: destinationUrl.path) {
            if let attr = try? FileManager.default.attributesOfItem(atPath: destinationUrl.path),
               let size = attr[.size] as? Int64, size > 0 {
                return // Valid cache exists
            } else {
                // Delete 0-byte corrupted marker
                try? FileManager.default.removeItem(at: destinationUrl)
            }
        }
        
        guard NetworkMonitor.shared.isConnected else { return }
        guard let url = URL(string: getCoverArtUrl(id: id, size: 600)) else { return }
        
        URLSession.shared.downloadTask(with: url) { tempLocation, response, error in
            guard let tempLocation = tempLocation, error == nil else {
                print("Failed to download cover art for \(id): \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            do {
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    return
                }
                try FileManager.default.moveItem(at: tempLocation, to: destinationUrl)
            } catch {
                print("Failed to save cover art for \(id): \(error)")
            }
        }.resume()
    }

    // MARK: - Lyrics

    func fetchLyrics(trackId: String, artist: String, title: String, duration: Double, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let lyricsDir = VeloraStorage.lyrics
        let cacheFile = lyricsDir.appendingPathComponent("\(trackId).txt")
        let isOnline = NetworkMonitor.shared.isConnected
        
        // If cached on disk, check the contents
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let cachedLyrics = try? String(contentsOf: cacheFile, encoding: .utf8)
            if let lyrics = cachedLyrics, !lyrics.isEmpty {
                completion(lyrics)
                return
            } else if !isOnline {
                // It's an empty marker, and we are offline, so don't bother retrying
                completion(nil)
                return
            }
            // If it's empty but we are online, we fall through and retry fetching
        }
        
        Task {
            guard NetworkMonitor.shared.isConnected else {
                // Do not cache failure if we simply have no connection
                completion(nil)
                return
            }
            
            // Only try LRCLIB API for lyrics (time-synced first, then plain)
            if let lrclibLyrics = await fetchFromLRCLIB(artist: artist, title: title, duration: duration), !lrclibLyrics.isEmpty {
                try? FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
                try? lrclibLyrics.write(to: cacheFile, atomically: true, encoding: .utf8)
                completion(lrclibLyrics)
                return
            }
            
            // Save empty file so we don't retry forever on un-lyric-able songs
            try? FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
            try? "".write(to: cacheFile, atomically: true, encoding: .utf8)
            completion(nil)
        }
    }
    
    nonisolated private func fetchFromLRCLIB(artist: String, title: String, duration: Double) async -> String? {
        guard await NetworkMonitor.shared.isConnected else { return nil }
        
        // Clean up title/artist for better matching (remove feat, remaster tags)
        let cleanTitle = title.replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
                              .replacingOccurrences(of: "\\s*\\[[^]]*\\]", with: "", options: .regularExpression)
                              .trimmingCharacters(in: .whitespaces)
        
        let cleanArtist = artist.components(separatedBy: " feat.").first?
                                .components(separatedBy: " ft.").first?
                                .components(separatedBy: " & ").first?
                                .components(separatedBy: ",").first?
                                .trimmingCharacters(in: .whitespaces) ?? artist
        
        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let getUrl = URL(string: "https://lrclib.net/api/get?track_name=\(encodedTitle)&artist_name=\(encodedArtist)&duration=\(Int(duration))") else {
            return nil
        }
        
        var request = URLRequest(url: getUrl)
        request.setValue("Velora iOS App v1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let synced = json["syncedLyrics"] as? String, !synced.isEmpty { return synced }
                    if let plain = json["plainLyrics"] as? String, !plain.isEmpty { return plain }
                }
            }
            
            // Fallback to SEARCH API if EXACT GET fails (handles slight metadata mismatches)
            guard let q = "\(cleanArtist) \(cleanTitle)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let searchUrl = URL(string: "https://lrclib.net/api/search?q=\(q)") else { return nil }
            
            var searchReq = URLRequest(url: searchUrl)
            searchReq.setValue("Velora iOS App v1.0", forHTTPHeaderField: "User-Agent")
            searchReq.timeoutInterval = 8.0
            
            let (searchData, searchResp) = try await URLSession.shared.data(for: searchReq)
            if let httpSearchResp = searchResp as? HTTPURLResponse, httpSearchResp.statusCode == 200 {
                if let jsonArray = try JSONSerialization.jsonObject(with: searchData) as? [[String: Any]] {
                    
                    // WORLD CLASS HEURISTIC: Find the best match that is within ±3 seconds of our actual audio file
                    // This prevents syncing a "Live Version" to a "Studio Version" and causing drift.
                    let bestMatch = jsonArray.first { result in
                        if let resultDuration = result["duration"] as? Double {
                            return abs(resultDuration - duration) <= 3.0
                        }
                        return false
                    } ?? jsonArray.first // Fallback to first if no duration matches perfectly
                    
                    if let match = bestMatch {
                        if let synced = match["syncedLyrics"] as? String, !synced.isEmpty { return synced }
                        if let plain = match["plainLyrics"] as? String, !plain.isEmpty { return plain }
                    }
                }
            }
        } catch {
            print("[LRCLIB] Fetch error: \(error.localizedDescription)")
            return nil
        }
        return nil
    }

    // MARK: - Scrobbling

    private var pendingScrobblesKey: String { "velora_pending_scrobbles" }

    func scrobble(id: String, submission: Bool) {
        if NetworkMonitor.shared.isConnected {
            sendScrobble(id: id, submission: submission)
        } else if submission {
            // Queue the submission for when we reconnect (nowPlaying pings are fire-and-forget, not worth queuing)
            var pending = UserDefaults.standard.stringArray(forKey: pendingScrobblesKey) ?? []
            if !pending.contains(id) {
                pending.append(id)
                UserDefaults.standard.set(pending, forKey: pendingScrobblesKey)
                AppLogger.shared.log("[Scrobble] Queued offline scrobble for track \(id)")
            }
        }
    }

    private func sendScrobble(id: String, submission: Bool) {
        guard let url = buildUrl(method: "scrobble.view", params: [
            "id": id,
            "time": "\(Int(Date().timeIntervalSince1970 * 1000))",
            "submission": submission ? "true" : "false"
        ]) else { return }
        URLSession.shared.dataTask(with: url) { _, _, error in
            if let error = error { print("Scrobble error: \(error)") }
        }.resume()
    }

    /// Called on reconnect (inside fetchEverything) to flush any queued offline scrobbles.
    func flushPendingScrobbles() {
        let pending = UserDefaults.standard.stringArray(forKey: pendingScrobblesKey) ?? []
        guard !pending.isEmpty else { return }
        AppLogger.shared.log("[Scrobble] Flushing \(pending.count) pending offline scrobble(s)")
        for id in pending {
            sendScrobble(id: id, submission: true)
        }
        UserDefaults.standard.removeObject(forKey: pendingScrobblesKey)
    }

    func reportNowPlaying(id: String) { scrobble(id: id, submission: false) }

    // MARK: - Batch Fetch

    func fetchEverything() {
        // Don't fire server requests when offline — rely on cached metadata
        guard NetworkMonitor.shared.isConnected else {
            AppLogger.shared.log("[Offline] Skipping fetchEverything — no network connection.")
            return
        }
        flushPendingScrobbles() // Flush any scrobbles queued while offline
        fetchRecentlyPlayed()
        fetchAlbums()
        fetchArtists()
        fetchPlaylists()
        fetchAllSongs()
    }
    
    // MARK: - Dedicated Asset Fetchers
    
    func fetchCoverArt(id: String, size: Int = 500, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard NetworkMonitor.shared.isConnected else { 
            DispatchQueue.main.async { completion(false) }
            return 
        }
        let urlStr = getCoverArtUrl(id: id)
        guard let url = URL(string: urlStr) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard error == nil, let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            // Save to VeloraStorage
            let localUrl = VeloraStorage.coverArt.appendingPathComponent("\(extractArtId(from: id)).jpg")
            do {
                try data.write(to: localUrl)
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }
    
    func fetchArtist(id: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard NetworkMonitor.shared.isConnected else { 
            DispatchQueue.main.async { completion(false) }
            return 
        }
        let urlStr = getCoverArtUrl(id: id)
        guard let url = URL(string: urlStr) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard error == nil, let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            // Save to VeloraStorage
            let localUrl = VeloraStorage.artistPortraits.appendingPathComponent("\(id).jpg")
            do {
                try data.write(to: localUrl)
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }


    // MARK: - Cache Management

    func clearMetadataCache() {
        let dirsToClean = [VeloraStorage.backdrops, VeloraStorage.artistPortraits, VeloraStorage.metadata, VeloraStorage.coverArt]
        let fileManager = FileManager.default
        dirsToClean.forEach { dir in
            if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                contents.forEach { try? fileManager.removeItem(at: $0) }
            }
        }
    }
    
    func clearLyricsCache() {
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(at: VeloraStorage.lyrics, includingPropertiesForKeys: nil) {
            contents.forEach { try? fileManager.removeItem(at: $0) }
        }
    }
    
    func clearMediaCache() {
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(at: VeloraStorage.tracks, includingPropertiesForKeys: nil) {
            contents.forEach { try? fileManager.removeItem(at: $0) }
        }
    }

    func clearCache() {
        DispatchQueue.main.async {
            self.artists.removeAll()
            self.albums.removeAll()
            self.allSongs.removeAll()
            self.playlists.removeAll()
            self.recentlyPlayed.removeAll()
        }
        URLCache.shared.removeAllCachedResponses()
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        if let contents = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            contents.forEach { try? fileManager.removeItem(at: $0) }
        }
        
        // Clear all VeloraStorage subdirectories
        let dirsToClean = [
            VeloraStorage.backdrops,
            VeloraStorage.artistPortraits,
            VeloraStorage.metadata,
            VeloraStorage.coverArt,
            VeloraStorage.tracks,
            VeloraStorage.lyrics,
        ]
        
        for dir in dirsToClean {
            if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                contents.forEach { try? fileManager.removeItem(at: $0) }
            }
        }
        
        fetchRecentlyPlayed()
        fetchAlbums()
        fetchArtists()
        fetchPlaylists()
        fetchAllSongs()
    }
    
    nonisolated func getMediaCacheSize() -> String {
        var totalSize: Int64 = 0
        let fileManager = FileManager.default
        
        totalSize += Int64(URLCache.shared.currentDiskUsage)
        
        let tempDir = fileManager.temporaryDirectory
        if let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        
        // Scan VeloraData directory recursively
        if let enumerator = fileManager.enumerator(at: VeloraStorage.root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                    if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalSize += Int64(fileSize)
                    }
                }
            }
        }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}
