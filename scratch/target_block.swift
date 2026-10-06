    func playTrack(_ track: Track, context: [Track] = []) {
        // Clear history when starting a new context (e.g., clicking a new album/playlist)
        playbackHistory.removeAll()
        isNavigatingHistory = false
        
        fireAITelemetry(for: track)

        if !context.isEmpty {
            self.queue = context
            self.unshuffledQueue = context
            self.queueIndex = context.firstIndex(where: { $0.id == track.id }) ?? 0
            if isShuffle { applyShuffle() }
        } else {
            self.queue = [track]
            self.unshuffledQueue = [track]
            self.queueIndex = 0
        }

        loadAndPlay(track: track)
    }

    private func getLocalAudioUrl(for trackId: String) -> URL? {
        let tracksDir = VeloraStorage.tracks
        let audioExtensions = ["mp3", "flac", "m4a", "ogg", "wav", "aac", "opus", "alac"]
        for ext in audioExtensions {
            let path = tracksDir.appendingPathComponent("\(trackId).\(ext)")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return nil
    }

    func loadAndPlay(track: Track) {
        let urlToPlay: URL
        if let localUrl = getLocalAudioUrl(for: track.id) {
            urlToPlay = localUrl
        } else {
            guard let streamUrl = client.getStreamUrl(id: track.id) else { return }
            urlToPlay = streamUrl
        }

        // Cleanup previous observer
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let itemObserver = playerItemObserver {
            NotificationCenter.default.removeObserver(itemObserver)
            playerItemObserver = nil
        }

        let playerItem = AVPlayerItem(url: urlToPlay)
        self.player = AVPlayer(playerItem: playerItem)
        self.currentTrack = track
        self.playbackSessionId = UUID()
        self.artworkRetryCount = 0
        self.nextArtworkRetryTime = nil
        self.progress = 0
        self.duration = 0
        self.hasScrobbledCurrentTrack = false
        self.currentLyrics = nil
        self.currentSyncedLyrics = nil
        self.currentPrimaryColor = .black
        self.currentPalette = [.black, .black, .black, .black, .black]

        // Immediately clear fanart to prevent ghosting on slow networks
        self.currentArtworkTrackId = nil
        FanartManager.shared.currentBackdrop = nil
        FanartManager.shared.currentClearLogo = nil

        let isOnline = NetworkMonitor.shared.isConnected

        // Fetch lyrics â€” works offline (returns disk-cached lyrics)
        client.fetchLyrics(
            trackId: track.id,
            artist: track.artist ?? "",
            title: track.title,
            duration: Double(track.duration ?? 0),
            priority: URLSessionTask.highPriority
        ) { [weak self] lyrics in
            Task { @MainActor in
                self?.applyLyrics(lyrics, for: track)
            }
        }

        FanartManager.shared.fetchBackdrop(for: track.allArtists, artistId: track.artistId)

        player?.play()
        self.isPlaying = true

        // Track progress â€” capture player instance to prevent stale-observer race condition
        guard let capturedPlayer = player else { return }
        timeObserver = capturedPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self,
                      self.player === capturedPlayer,  // Only the ACTIVE player may update progress
                      let item = capturedPlayer.currentItem,
                      item.duration.isNumeric else { return }

                self.progress = time.seconds
                self.duration = item.duration.seconds
                self.updateNowPlayingInfo()

                // Scrobble / Add to recently played at 30% completion
                if !self.hasScrobbledCurrentTrack, self.duration > 0 {
                    if self.progress >= (self.duration * 0.3) {
                        self.hasScrobbledCurrentTrack = true
                        // Fire the scrobble; the client handles offline queuing and instant local history update
                        self.client.scrobble(track: track, submission: true)
                    }
                }
            }
        }

        // Auto-advance to next track when done
        playerItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let manager = self else { return }

                if let track = manager.currentTrack, !manager.hasScrobbledCurrentTrack, NetworkMonitor.shared.isConnected {
                    manager.hasScrobbledCurrentTrack = true
                    manager.client.scrobble(track: track, submission: true)
                }

                switch manager.repeatMode {
                case .one:
                    manager.loadAndPlay(track: manager.queue[manager.queueIndex])
                case .all:
                    manager.skipForward()
                case .off:
                    if manager.queueIndex < manager.queue.count - 1 {
                        manager.skipForward()
                    } else {
                        manager.isPlaying = false
                        manager.player?.pause()
                    }
                }
            }
        }

        // Mark as "Now Playing" on server (only when online)
        if isOnline {
            client.scrobble(track: track, submission: false)
        }

        updateNowPlayingInfo()

        if isOnline {
            prefetchNextTracks()
            prewarmNextTrack()
            // Prioritize downloads for the current playback context
            boostCurrentContextDownloads()
        }
    }

    private func boostCurrentContextDownloads() {
        // Move tracks from the current playback queue to the front of the download queue
        let currentQueueIds = Set(queue.map { $0.id })
        let matchingIndices = downloadQueue.enumerated()
            .filter { currentQueueIds.contains($0.element.id) }
            .map { $0.offset }
            .reversed() // Reverse to maintain stable indices during removal

        var boosted: [Track] = []
        for idx in matchingIndices {
            boosted.insert(downloadQueue.remove(at: idx), at: 0)
        }
        downloadQueue.insert(contentsOf: boosted, at: 0)
    }

    /// Pre-warms the AVPlayerItem for the immediate next track so that when
    /// startCrossfade() fires, the item is already at .readyToPlay.
    ///
    /// Data policy:
    ///   - Local file  â†’ always pre-warm (zero network cost, instant readiness)
    ///   - Stream      â†’ only pre-warm when crossfade is enabled (the item will
    ///                   definitely be needed) and use a conservative 8 s buffer
    ///                   window instead of the full track length.
    private func prewarmNextTrack() {
        // Prewarming and crossfading have been removed per user request.
    }

    private func prefetchNextTracks() {
        let prefetchCount = 3
        let start = queueIndex + 1
        let end = min(start + prefetchCount, queue.count)

        guard start < end else { return }

        for i in start..<end {
            let track = queue[i]
            let artist = track.artist ?? ""
            let delay = Double(i - start) * 1.5 // Stagger by 1.5s per track to respect MB rate limits (1 req/s)

            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // 1. Prefetch Backdrop Silently
                await FanartManager.shared.downloadBackdropSilently(for: track.allArtists)

                // 2. Prefetch Metadata Silently
                await MusicBrainzManager.shared.downloadMetadataSilently(for: artist)
            }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func skipForward() {
        guard !queue.isEmpty else { return }

        // Save current index to history before moving forward
        if !isNavigatingHistory {
            playbackHistory.append(queueIndex)
            // Limit history size to 100 entries
            if playbackHistory.count > 100 { playbackHistory.removeFirst() }
        }

        let nextIndex = (queueIndex + 1) % queue.count

        isNavigatingHistory = false
        queueIndex = nextIndex
        loadAndPlay(track: queue[queueIndex])
    }

    func toggleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func skipBackward() {
        // If more than 3 seconds in, restart the current song
        if progress > 3 {
            player?.seek(to: .zero)
        } else {
            // Check history first for correct backward navigation
            if let lastIndex = playbackHistory.popLast() {
                isNavigatingHistory = true
                queueIndex = lastIndex
                loadAndPlay(track: queue[queueIndex])
            } else {
                // Fallback to sequential previous if history is empty
                let prevIndex = queueIndex - 1
                guard prevIndex >= 0 else { return }
                queueIndex = prevIndex
                loadAndPlay(track: queue[queueIndex])
            }
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
    }

    private func startContinuousSeek(forward: Bool) {
        stopContinuousSeek()
        // Immediate seek
        seek(to: progress + (forward ? 10 : -10))
        // Set up continuous seek every 0.8s
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.seek(to: self.progress + (forward ? 10 : -10))
            }
        }
    }

    private func stopContinuousSeek() {
        seekTimer?.invalidate()
        seekTimer = nil
    }

