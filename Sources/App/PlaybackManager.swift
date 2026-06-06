import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct LyricWord: Hashable {
    let time: Double
    let text: String
}

struct LyricLine: Hashable {
    let time: Double
    let text: String
    let words: [LyricWord]
}

@MainActor
final class PlaybackManager: NSObject, ObservableObject, @preconcurrency URLSessionDownloadDelegate {
    @MainActor static var shared: PlaybackManager?
    @MainActor static var sharedBackgroundCompletion: (() -> Void)?
    
    @Published var currentTrack: Track?
    @Published var playbackSessionId: UUID = UUID()
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var currentLyrics: String? = nil
    @Published var currentSyncedLyrics: [LyricLine]? = nil
    @Published var isLyricsMode: Bool = false
    @Published var currentPrimaryColor: UIColor = .black
    @Published var currentPalette: [UIColor] = [.black, .black, .black, .black, .black]
    // Queue support
    @Published var queue: [Track] = []
    @Published var queueIndex: Int = 0
    @Published var isShuffle: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var downloadedTrackIds = Set<String>()
    @Published var failedDownloadIds = Set<String>()
    @Published var activeDownloadCount = 0
    
    // Playback History for correct 'Previous' behavior
    private var playbackHistory: [Int] = []
    private var isNavigatingHistory = false
    
    private var integrityManager = IntegrityManager.shared
    private var integrityCancellable: Any?
    
    func isDownloaded(_ trackId: String) -> Bool {
        return downloadedTrackIds.contains(trackId)
    }
    
    func checkFileSystemForTrack(_ trackId: String) -> Bool {
        if isDownloaded(trackId) { return true }
        
        let tracksDir = VeloraStorage.tracks
        let audioExtensions = ["mp3", "flac", "m4a", "ogg", "wav", "aac", "opus", "alac"]
        
        for ext in audioExtensions {
            let path = tracksDir.appendingPathComponent("\(trackId).\(ext)").path
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        return false
    }
    
    func filterOffline(_ tracks: [Track]) -> [Track] {
        return tracks.filter { isDownloaded($0.id) }
    }
    
    enum RepeatMode {
        case off, one, all
    }
    
    enum DownloadPriority {
        case high    // Currently playing album/playlist — inserted at front of queue
        case normal  // Bulk sync, manual background downloads
    }
    
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadETAs: [String: String] = [:]
    @Published var pausedDownloadIds = Set<String>()
    
    private var downloadQueue: [Track] = []
    private var activeDownloadTasksByTrackId: [String: URLSessionDownloadTask] = [:]
    private var downloadStartTimes: [String: Date] = [:]
    private var maxConcurrentDownloads: Int {
        UserDefaults.standard.integer(forKey: "velora_download_concurrency") == 0 
            ? 5 : UserDefaults.standard.integer(forKey: "velora_download_concurrency")
    }
    private var isCrossfadeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "velora_crossfade_enabled")
    }
    private var crossfadeDuration: Double {
        let val = UserDefaults.standard.double(forKey: "velora_crossfade_duration")
        return val == 0 ? 5.0 : val
    }
    private var isDownloadingAll = false
    private var downloadTasks: [Int: String] = [:] // Task ID to Track ID
    private var downloadRetryCount: [String: Int] = [:] // trackId -> retry count
    private let maxRetries = 3
    
    private var player: AVPlayer?
    private var secondaryPlayer: AVPlayer?
    private var isCrossfading = false
    private var timeObserver: Any?
    private var playerItemObserver: Any?
    @Published var currentArtworkTrackId: String? = nil
    // Artwork download race-proofing
    private var artworkDownloadTask: URLSessionDataTask? = nil
    private var downloadingArtworkTrackId: String? = nil
    private var artworkRetryCount = 0
    private var nextArtworkRetryTime: Date? = nil
    // Pre-warmed next-track item for zero-wait crossfading
    private var prewarmedItem: AVPlayerItem? = nil
    private var prewarmedTrackId: String? = nil
    private var prewarmPlayer: AVPlayer? = nil
    var client: NavidromeClient
    
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.velora.downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        // Maximize connections to the same host for faster concurrent downloads
        configuration.httpMaximumConnectionsPerHost = maxConcurrentDownloads
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    } ()
    
    init(client: NavidromeClient) {
        self.client = client
        super.init()
        PlaybackManager.shared = self
        configureAudioSession()
        setupRemoteCommandCenter()
        
        // Bind to IntegrityManager's indexed IDs
        self.downloadedTrackIds = integrityManager.downloadedIds
        // Use a simple sink or notification to keep it in sync
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in }
        
        loadDownloadedTracks()
        
        // Listen for app termination to clear now playing info
        NotificationCenter.default.addObserver(self, selector: #selector(handleTerminate), name: UIApplication.willTerminateNotification, object: nil)
    }
    
    @objc private func handleTerminate() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player?.pause()
        cancelAllDownloads()
    }
    
    func cancelAllDownloads() {
        for task in activeDownloadTasksByTrackId.values {
            task.cancel()
        }
        activeDownloadTasksByTrackId.removeAll()
        downloadQueue.removeAll()
        downloadTasks.removeAll()
        DispatchQueue.main.async {
            self.downloadProgress.removeAll()
            self.pausedDownloadIds.removeAll()
            self.activeDownloadCount = 0
        }
    }
    
    // MARK: - Audio Session
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            
            // Gold Standard: Handle Audio Interruptions (e.g., phone calls)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleInterruption),
                                                   name: AVAudioSession.interruptionNotification,
                                                   object: AVAudioSession.sharedInstance())
            
            // Gold Standard: Handle Route Changes (e.g., headphones unplugged)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleRouteChange),
                                                   name: AVAudioSession.routeChangeNotification,
                                                   object: AVAudioSession.sharedInstance())
            
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // Interruption began, take appropriate actions
            DispatchQueue.main.async {
                self.isPlaying = false
                self.player?.pause()
                self.updateNowPlayingInfo()
            }
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    DispatchQueue.main.async {
                        self.player?.play()
                        self.isPlaying = true
                        self.updateNowPlayingInfo()
                    }
                }
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            // e.g., headphones pulled out
            DispatchQueue.main.async {
                self.isPlaying = false
                self.player?.pause()
                self.updateNowPlayingInfo()
            }
        default: break
        }
    }
    
    // MARK: - Playback Controls
    
    /// Play a single track, optionally with a full queue context
    func playTrack(_ track: Track, context: [Track] = []) {
        // Clear history when starting a new context (e.g., clicking a new album/playlist)
        playbackHistory.removeAll()
        isNavigatingHistory = false
        
        if !context.isEmpty {
            self.queue = context
            self.queueIndex = context.firstIndex(where: { $0.id == track.id }) ?? 0
        } else {
            self.queue = [track]
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

    private func loadAndPlay(track: Track) {
        // Cancel crossfade if active
        if isCrossfading {
            isCrossfading = false
            secondaryPlayer?.pause()
            secondaryPlayer = nil
            player?.volume = 1.0
        }

        // Invalidate any pre-warmed item — it was for the old next track
        prewarmedItem = nil
        prewarmedTrackId = nil
        prewarmPlayer?.pause()
        prewarmPlayer = nil

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
        self.currentLyrics = nil
        self.currentSyncedLyrics = nil
        self.currentPrimaryColor = .black
        self.currentPalette = [.black, .black, .black, .black, .black]
        
        // Immediately clear backdrop to prevent ghosting on slow networks
        self.currentArtworkTrackId = nil
        FanartManager.shared.currentBackdrop = nil
        
        let isOnline = NetworkMonitor.shared.isConnected
        
        // Fetch lyrics — works offline too (returns disk-cached lyrics)
        client.fetchLyrics(trackId: track.id, artist: track.artist ?? "", title: track.title) { lyrics in
            DispatchQueue.main.async {
                if self.currentTrack?.id == track.id {
                    if let lyrics = lyrics {
                        self.currentLyrics = lyrics
                        if lyrics.contains("[00:") || lyrics.contains("[01:") || lyrics.contains("[02:") {
                            self.currentSyncedLyrics = self.parseLRC(lyrics)
                        } else {
                            self.currentSyncedLyrics = nil
                        }
                    } else {
                        self.currentLyrics = nil
                        self.currentSyncedLyrics = nil
                    }
                }
            }
        }
        
        // Network-only side effects: skip when offline to avoid hanging requests
        if isOnline {
            // Fetch Backdrop (Fanart/Discogs)
            if let artistId = track.artistId {
                client.fetchArtistInfo(artistId: artistId) { _, mbid in
                    DispatchQueue.main.async {
                        FanartManager.shared.fetchBackdrop(for: track.artist ?? "", mbid: mbid)
                    }
                }
            } else {
                FanartManager.shared.fetchBackdrop(for: track.artist ?? "")
            }
        }
        
        player?.play()
        self.isPlaying = true
        
        // Track progress — capture player instance to prevent stale-observer race condition
        let capturedPlayer = player
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak capturedPlayer] time in
            MainActor.assumeIsolated {
                guard let self = self,
                      let capturedPlayer = capturedPlayer,
                      self.player === capturedPlayer,  // Only the ACTIVE player may update progress
                      let item = capturedPlayer.currentItem,
                      item.duration.isNumeric else { return }
                
                self.progress = time.seconds
                self.duration = item.duration.seconds
                self.updateNowPlayingInfo()
                
                // Crossfade check — also gate against short tracks shorter than 2x the fade window
                let triggerTime = self.duration - self.crossfadeDuration
                if self.isCrossfadeEnabled &&
                   !self.isCrossfading &&
                   self.duration > (self.crossfadeDuration * 2.0) &&
                   time.seconds > triggerTime {
                    self.startCrossfade()
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
                guard let self = self else { return }
                if self.isCrossfading { return }
                
                if let track = self.currentTrack, self.isOnline {
                    self.client.scrobble(id: track.id, submission: true)
                }
                
                switch self.repeatMode {
                case .one:
                    self.loadAndPlay(track: self.queue[self.queueIndex])
                case .all:
                    self.skipForward()
                case .off:
                    if self.queueIndex < self.queue.count - 1 {
                        self.skipForward()
                    } else {
                        self.isPlaying = false
                        self.player?.pause()
                    }
                }
            }
        }
        
        // Mark as "Now Playing" on server (only when online)
        if isOnline {
            client.scrobble(id: track.id, submission: false)
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
    ///   - Local file  → always pre-warm (zero network cost, instant readiness)
    ///   - Stream      → only pre-warm when crossfade is enabled (the item will
    ///                   definitely be needed) and use a conservative 8 s buffer
    ///                   window instead of the full track length.
    private func prewarmNextTrack() {
        guard queue.count > 1 else { return }

        let nextIndex = (queueIndex + 1) % queue.count
        guard nextIndex != queueIndex else { return }   // single-item queue

        let nextTrack = queue[nextIndex]

        // Don't re-warm the same track twice
        if prewarmedTrackId == nextTrack.id { return }

        if let localUrl = getLocalAudioUrl(for: nextTrack.id) {
            // ── Offline path: always pre-warm, no data cost ────────────────────────
            let item = AVPlayerItem(url: localUrl)
            // Local files resolve instantly; a large buffer just forces the OS to
            // read ahead into RAM — fine because this is already downloaded data.
            item.preferredForwardBufferDuration = 30.0
            prewarmedItem    = item
            prewarmedTrackId = nextTrack.id

        } else if isCrossfadeEnabled {
            // ── Stream path: only pre-warm when crossfade is turned on ─────────────
            // We use 8 s of forward buffer — enough to guarantee readiness by the
            // time the crossfade trigger fires, without wasting mobile data on a
            // full pre-download of the entire next track.
            guard let streamUrl = client.getStreamUrl(id: nextTrack.id) else { return }
            let item = AVPlayerItem(url: streamUrl)
            item.preferredForwardBufferDuration = 8.0
            prewarmedItem    = item
            prewarmedTrackId = nextTrack.id

            // Attach a silent AVPlayer to the item so AVFoundation actually starts
            // pulling bytes. Without a player owner, the item never buffers.
            let warmupPlayer = AVPlayer(playerItem: item)
            warmupPlayer.volume = 0.0
            warmupPlayer.play()
            self.prewarmPlayer = warmupPlayer

            // Keep the player alive long enough to fill the buffer, then discard it.
            // 12 s is generous — even a slow connection will have 8 s buffered by then.
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                // If the item is still the one we warmed (no skip happened), pause
                // the warmup player to stop consuming bandwidth. The buffered bytes
                // already in the AVPlayerItem are retained for startCrossfade() to use.
                if self.prewarmedTrackId == nextTrack.id {
                    self.prewarmPlayer?.pause()
                    self.prewarmPlayer = nil
                }
            }
        }
        // Stream + crossfade disabled → no pre-warm, save data.
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
                FanartManager.shared.downloadBackdropSilently(for: artist)
                
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
        
        let nextIndex: Int
        if isShuffle {
            var rand = Int.random(in: 0..<queue.count)
            // Avoid playing the same song twice if possible
            if rand == queueIndex && queue.count > 1 { rand = (rand + 1) % queue.count }
            nextIndex = rand
        } else {
            nextIndex = (queueIndex + 1) % queue.count
        }
        
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
    
    // MARK: - Remote Control Center
    
    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artist ?? ""
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = track.album ?? ""
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // Asynchronously load artwork for the Control Center:
        // - Cancel any in-flight download for a previous track
        // - Track downloadingArtworkTrackId separately from currentArtworkTrackId so a
        //   failed/slow download can be retried on the next updateNowPlayingInfo() call
        if currentArtworkTrackId != track.id && downloadingArtworkTrackId != track.id {
            if let retryTime = nextArtworkRetryTime, Date() < retryTime {
                return
            }

            // Cancel the previous download task if it is still in flight
            artworkDownloadTask?.cancel()
            artworkDownloadTask = nil

            if let artworkUrl = track.coverArtUrl {
                downloadingArtworkTrackId = track.id

                let task = URLSession.shared.dataTask(with: artworkUrl) { [weak self] data, _, error in
                    guard let self = self else { return }

                    // On failure, clear downloadingArtworkTrackId so the next tick can retry
                    if error != nil || data == nil {
                        DispatchQueue.main.async {
                            if self.downloadingArtworkTrackId == track.id {
                                self.downloadingArtworkTrackId = nil
                                self.artworkRetryCount += 1
                                let delay = min(pow(2.0, Double(self.artworkRetryCount)), 60.0)
                                self.nextArtworkRetryTime = Date().addingTimeInterval(delay)
                            }
                        }
                        return
                    }

                    guard let data = data, let image = UIImage(data: data) else {
                        DispatchQueue.main.async {
                            if self.downloadingArtworkTrackId == track.id {
                                self.downloadingArtworkTrackId = nil
                                self.artworkRetryCount += 1
                                let delay = min(pow(2.0, Double(self.artworkRetryCount)), 60.0)
                                self.nextArtworkRetryTime = Date().addingTimeInterval(delay)
                            }
                        }
                        return
                    }

                    // Persist to the local CoverArt cache so subsequent plays load instantly
                    var artId = track.coverArt ?? track.albumId ?? track.id.components(separatedBy: ".").first ?? track.id
                    // Extract the real ID from a server URL (e.g., "https://...?id=al-123" → "al-123")
                    if artId.contains("getCoverArt"),
                       let artUrl = URL(string: artId),
                       let artComponents = URLComponents(url: artUrl, resolvingAgainstBaseURL: false),
                       let idParam = artComponents.queryItems?.first(where: { $0.name == "id" })?.value {
                        artId = idParam
                    }
                    let coverArtDir = VeloraStorage.coverArt
                    let localUrl = coverArtDir.appendingPathComponent("\(artId).jpg")
                    if !FileManager.default.fileExists(atPath: coverArtDir.path) {
                        try? FileManager.default.createDirectory(at: coverArtDir, withIntermediateDirectories: true, attributes: nil)
                    }
                    try? data.write(to: localUrl)

                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    let extractedColor = image.dominantColor() ?? .black
                    let extractedPalette = image.extractPalette(count: 5)

                    DispatchQueue.main.async {
                        if self.currentTrack?.id == track.id {
                            var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
                            updatedInfo[MPMediaItemPropertyArtwork] = artwork
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                            self.currentPrimaryColor = extractedColor
                            self.currentPalette = extractedPalette
                            
                            // If this was a successful self-healing attempt after a failure, force the UI to refresh
                            if self.currentArtworkTrackId != track.id {
                                self.playbackSessionId = UUID()
                            }
                            self.currentArtworkTrackId = track.id
                        }
                        self.artworkRetryCount = 0
                        self.nextArtworkRetryTime = nil
                        self.downloadingArtworkTrackId = nil
                        self.artworkDownloadTask = nil
                    }
                }
                artworkDownloadTask = task
                task.resume()
            }
        }
    }
    
    private func parseLRC(_ lyrics: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let lines = lyrics.components(separatedBy: .newlines)
        
        let wordTagRegex = try? NSRegularExpression(pattern: "<(\\d+):(\\d+\\.\\d+)>\\s*([^<]+)")
        
        for line in lines {
            guard line.hasPrefix("["), let bracketEnd = line.firstIndex(of: "]") else { continue }
            let timeString = String(line[line.index(after: line.startIndex)..<bracketEnd])
            let rawText = String(line[line.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)
            let parts = timeString.components(separatedBy: ":")
            guard parts.count >= 2, let min = Double(parts[0]), let sec = Double(parts[1]) else { continue }
            let time = min * 60 + sec
            
            var lyricWords: [LyricWord] = []
            
            if let regex = wordTagRegex, rawText.contains("<") {
                let nsRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
                let matches = regex.matches(in: rawText, range: nsRange)
                
                for match in matches {
                    if match.numberOfRanges == 4,
                       let minRange = Range(match.range(at: 1), in: rawText),
                       let secRange = Range(match.range(at: 2), in: rawText),
                       let textRange = Range(match.range(at: 3), in: rawText),
                       let wMin = Double(rawText[minRange]),
                       let wSec = Double(rawText[secRange]) {
                        
                        let wTime = wMin * 60 + wSec
                        let wText = String(rawText[textRange]).trimmingCharacters(in: .whitespaces)
                        lyricWords.append(LyricWord(time: wTime, text: wText))
                    }
                }
            }
            
            let plainText = rawText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            
            if !plainText.isEmpty {
                result.append(LyricLine(time: time, text: plainText, words: lyricWords))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
    
    // MARK: - Offline Downloads Management
    
    

    
    func loadDownloadedTracks() {
        // Optimization: Use IntegrityManager's index if it's already populated
        if !integrityManager.downloadedIds.isEmpty {
            self.downloadedTrackIds = integrityManager.downloadedIds
            return
        }
        
        let tracksDirectory = VeloraStorage.tracks
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil)
            
            // Rebuild index from disk (First run or recovery)
            integrityManager.rebuildIndex(from: fileURLs)
            
            DispatchQueue.main.async {
                self.downloadedTrackIds = self.integrityManager.downloadedIds
                self.objectWillChange.send()
            }
        } catch {
            print("Error loading downloaded tracks: \(error)")
        }
    }
    
    func refreshDownloadedTracks() {
        loadDownloadedTracks()
    }
    
    func deleteDownload(trackId: String) {
        // 1. Cancel active download if in progress
        if let task = activeDownloadTasksByTrackId[trackId] {
            task.cancel()
            activeDownloadTasksByTrackId.removeValue(forKey: trackId)
            downloadProgress.removeValue(forKey: trackId)
            downloadETAs.removeValue(forKey: trackId)
            downloadStartTimes.removeValue(forKey: trackId)
            pausedDownloadIds.remove(trackId)
        }
        // Also remove from pending queue
        downloadQueue.removeAll { $0.id == trackId }
        
        // 2. Delete the file from disk
        if let fileName = integrityManager.getFileName(for: trackId) {
            let filePath = VeloraStorage.tracks.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: filePath)
        } else {
            // Fallback: scan all extensions
            let audioExtensions = ["mp3","flac","m4a","ogg","wav","aac","opus","alac"]
            for ext in audioExtensions {
                let path = VeloraStorage.tracks.appendingPathComponent("\(trackId).\(ext)")
                if FileManager.default.fileExists(atPath: path.path) {
                    try? FileManager.default.removeItem(at: path)
                    break
                }
            }
        }
        
        // 3. Unregister from index
        integrityManager.unregisterDownload(trackId: trackId)
        downloadedTrackIds.remove(trackId)
        failedDownloadIds.remove(trackId)
        objectWillChange.send()
        
        AppLogger.shared.log("Deleted download for track \(trackId)", level: .info)
    }

    func deleteAlbumDownloads(albumId: String) {
        let tracks = client.allSongs.filter { $0.albumId == albumId }
        for track in tracks {
            if isDownloaded(track.id) { deleteDownload(trackId: track.id) }
        }
    }

    func deleteArtistDownloads(artistId: String) {
        let tracks = client.allSongs.filter { $0.artistId == artistId }
        for track in tracks {
            if isDownloaded(track.id) { deleteDownload(trackId: track.id) }
        }
    }
    
    /// Returns (downloaded, total) count for an album
    func albumDownloadStatus(albumId: String) -> (downloaded: Int, total: Int) {
        let tracks = client.allSongs.filter { $0.albumId == albumId }
        let downloaded = tracks.filter { isDownloaded($0.id) }.count
        return (downloaded, tracks.count)
    }

    /// Returns (downloaded, total) for a list of tracks (e.g., playlist tracks)
    func tracksDownloadStatus(_ tracks: [Track]) -> (downloaded: Int, total: Int) {
        let downloaded = tracks.filter { isDownloaded($0.id) }.count
        return (downloaded, tracks.count)
    }
    
    func downloadAlbum(albumId: String) {
        let tracks = client.allSongs.filter { $0.albumId == albumId }
        for track in tracks {
            downloadTrack(track)
        }
    }
    
    func downloadPlaylist(playlistId: String) {
        client.fetchPlaylistTracks(playlistId: playlistId) { tracks in
            DispatchQueue.main.async {
                for track in tracks {
                    self.downloadTrack(track)
                }
            }
        }
    }
    
    func downloadTrack(_ track: Track, priority: DownloadPriority = .normal) {
        AppLogger.shared.log("downloadTrack requested for \(track.id) - \(track.title)", level: .debug)
        
        // Can't download without network
        guard NetworkMonitor.shared.isConnected else {
            AppLogger.shared.log("downloadTrack skipped for \(track.id) — offline", level: .info)
            return
        }
        
        // 1. Check if already downloaded
        if checkFileSystemForTrack(track.id) {
            return 
        }
        
        // 2. TOGGLE LOGIC: Check if it's already active (Downloading or Paused)
        if let existingTask = activeDownloadTasksByTrackId[track.id] {
            if pausedDownloadIds.contains(track.id) {
                AppLogger.shared.log("Resuming download for \(track.id)", level: .info)
                existingTask.resume()
                DispatchQueue.main.async { self.pausedDownloadIds.remove(track.id) }
            } else {
                AppLogger.shared.log("Pausing download for \(track.id)", level: .info)
                existingTask.suspend()
                DispatchQueue.main.async { self.pausedDownloadIds.insert(track.id) }
            }
            return
        }
        
        // 3. Add to queue if not already there
        if downloadProgress[track.id] != nil { 
            return 
        }
        
        // Mark as queued immediately
        DispatchQueue.main.async {
            self.downloadProgress[track.id] = 0.0
        }
        
        switch priority {
        case .high:
            // Insert at front (after any already-active items)
            downloadQueue.insert(track, at: 0)
        case .normal:
            downloadQueue.append(track)
        }
        processQueue()
    }
    
    private func processQueue() {
        AppLogger.shared.log("processQueue() - active: \(activeDownloadCount)/\(maxConcurrentDownloads), queue: \(downloadQueue.count)", level: .debug)
        guard activeDownloadCount < maxConcurrentDownloads, !downloadQueue.isEmpty else { return }
        
        let track = downloadQueue.removeFirst()
        activeDownloadCount += 1
        
        let streamUrl = client.getStreamUrl(id: track.id)
        
        guard let url = streamUrl else { 
            AppLogger.shared.log("Could not get stream URL for track \(track.id)", level: .error)
            DispatchQueue.main.async {
                self.failedDownloadIds.insert(track.id)
                self.downloadProgress.removeValue(forKey: track.id)
                self.activeDownloadCount -= 1
                self.processQueue()
            }
            return 
        }
        
        AppLogger.shared.log("Starting download task for \(track.id) from \(url.absoluteString)", level: .info)
        let task = downloadSession.downloadTask(with: url)
        downloadTasks[task.taskIdentifier] = track.id
        activeDownloadTasksByTrackId[track.id] = task // Save reference for pause/resume
        downloadStartTimes[track.id] = Date()
        task.resume()
        
        // Trigger cover art download alongside the track
        let rawArtId = track.coverArt ?? track.albumId ?? track.id.components(separatedBy: ".").first ?? track.id
        // Extract the real ID from a server URL if needed (e.g., "https://...?id=al-123" → "al-123")
        let cleanArtId: String
        if rawArtId.contains("getCoverArt"),
           let url = URL(string: rawArtId),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value {
            cleanArtId = idParam
        } else {
            cleanArtId = rawArtId
        }
        client.downloadCoverArt(id: cleanArtId)
    }

    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let trackId = downloadTasks[downloadTask.taskIdentifier] else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        let now = Date()
        if let start = downloadStartTimes[trackId] {
            let elapsed = now.timeIntervalSince(start)
            if elapsed > 1.0 && progress > 0.05 {
                let speed = Double(totalBytesWritten) / elapsed // bytes/sec
                let remainingBytes = Double(totalBytesExpectedToWrite - totalBytesWritten)
                let remainingTime = remainingBytes / speed
                
                DispatchQueue.main.async {
                    if remainingTime > 3600 {
                        self.downloadETAs[trackId] = String(format: "%dh remaining", Int(remainingTime / 3600))
                    } else if remainingTime > 60 {
                        self.downloadETAs[trackId] = String(format: "%dm remaining", Int(remainingTime / 60))
                    } else {
                        self.downloadETAs[trackId] = String(format: "%ds remaining", Int(remainingTime))
                    }
                }
            }
        }

        DispatchQueue.main.async {
            self.downloadProgress[trackId] = progress
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        AppLogger.shared.log("didFinishDownloadingTo called for task \(downloadTask.taskIdentifier)", level: .debug)
        
        guard let trackId = downloadTasks[downloadTask.taskIdentifier] else { 
            AppLogger.shared.log("No trackId found for task \(downloadTask.taskIdentifier)", level: .warning)
            return 
        }
        
        // Use track's suffix if available, fallback to mp3
        activeDownloadTasksByTrackId.removeValue(forKey: trackId)
        
        var suffix = "mp3"
        if let track = client.allSongs.first(where: { $0.id == trackId }), let s = track.suffix {
            suffix = s.lowercased()
        } else if let track = queue.first(where: { $0.id == trackId }), let s = track.suffix {
            suffix = s.lowercased()
        }
        
        let downloadsDir = VeloraStorage.tracks
        let destinationUrl = downloadsDir.appendingPathComponent("\(trackId).\(suffix)")
        
        do {
            if FileManager.default.fileExists(atPath: destinationUrl.path) {
                try FileManager.default.removeItem(at: destinationUrl)
            }
            try FileManager.default.moveItem(at: location, to: destinationUrl)
            
            // Integrity Check: Verify that the downloaded file is valid (AFTER moving from temp background session location)
            let attributes = try FileManager.default.attributesOfItem(atPath: destinationUrl.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            if fileSize < 1024 {
                 AppLogger.shared.log("FAILURE: Downloaded file for \(trackId) is empty or corrupted (\(fileSize) bytes). Will retry.", level: .error)
                 try FileManager.default.removeItem(at: destinationUrl)
                 
                 // Auto-retry with backoff
                 let retries = downloadRetryCount[trackId, default: 0]
                 if retries < maxRetries {
                     downloadRetryCount[trackId] = retries + 1
                     let delay = pow(2.0, Double(retries)) // 1s, 2s, 4s
                     AppLogger.shared.log("Scheduling retry \(retries + 1)/\(maxRetries) for \(trackId) in \(delay)s", level: .info)
                     
                     // Re-queue the track for download after delay
                     Task {
                         try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                         if let track = self.client.allSongs.first(where: { $0.id == trackId }) ?? self.queue.first(where: { $0.id == trackId }) {
                             DispatchQueue.main.async {
                                 self.downloadProgress[trackId] = nil // Reset so downloadTrack accepts it
                                 self.downloadTrack(track)
                             }
                         }
                     }
                     return // Don't mark as failed yet
                 } else {
                     AppLogger.shared.log("Track \(trackId) failed after \(maxRetries) retries. Giving up.", level: .error)
                     downloadRetryCount.removeValue(forKey: trackId)
                     throw NSError(domain: "com.velora.integrity", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty or corrupted file download"])
                 }
            }

            // Register in the Lightning Index
            integrityManager.registerDownload(trackId: trackId, fileName: destinationUrl.lastPathComponent, size: fileSize)
            
            DispatchQueue.main.async {
                self.downloadedTrackIds.insert(trackId)
                self.downloadProgress.removeValue(forKey: trackId)
                self.downloadETAs.removeValue(forKey: trackId)
                self.downloadStartTimes.removeValue(forKey: trackId)
                self.objectWillChange.send()
            }
            AppLogger.shared.log("SUCCESS: Saved track \(trackId) to \(destinationUrl.path)", level: .info)
        } catch {
            AppLogger.shared.log("Failed to save track \(trackId): \(error.localizedDescription)", level: .error)
            DispatchQueue.main.async {
                self.failedDownloadIds.insert(trackId)
                self.downloadProgress.removeValue(forKey: trackId)
            }
        }
        // Removed: downloadTasks.removeValue(forKey: downloadTask.taskIdentifier) 
        // We now only remove in didCompleteWithError to ensure the ID is available there.
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        AppLogger.shared.log("didCompleteWithError called for task \(task.taskIdentifier)", level: .debug)
        
        if let trackId = downloadTasks[task.taskIdentifier] {
            activeDownloadTasksByTrackId.removeValue(forKey: trackId)
        }
        
        if let error = error {
            let nsError = error as NSError
            // Don't retry user-cancelled downloads
            if nsError.code != NSURLErrorCancelled, let trackId = downloadTasks[task.taskIdentifier] {
                let retries = downloadRetryCount[trackId, default: 0]
                if retries < maxRetries {
                    downloadRetryCount[trackId] = retries + 1
                    let delay = pow(2.0, Double(retries))
                    AppLogger.shared.log("Scheduling retry \(retries + 1)/\(maxRetries) for \(trackId) in \(delay)s after network error", level: .info)
                    
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if let track = self.client.allSongs.first(where: { $0.id == trackId }) ?? self.queue.first(where: { $0.id == trackId }) {
                            DispatchQueue.main.async {
                                self.downloadProgress[trackId] = nil
                                self.downloadTrack(track)
                            }
                        }
                    }
                    downloadTasks.removeValue(forKey: task.taskIdentifier)
                    activeDownloadCount -= 1
                    processQueue()
                    return
                }
            }
            
            AppLogger.shared.log("Download task \(task.taskIdentifier) failed: \(error.localizedDescription)", level: .error)
            if let trackId = downloadTasks[task.taskIdentifier] {
                DispatchQueue.main.async {
                    self.failedDownloadIds.insert(trackId)
                    self.downloadProgress.removeValue(forKey: trackId)
                    self.downloadETAs.removeValue(forKey: trackId)
                    self.downloadStartTimes.removeValue(forKey: trackId)
                    self.downloadRetryCount.removeValue(forKey: trackId)
                }
            }
        } else {
            AppLogger.shared.log("Download task \(task.taskIdentifier) completed without error.", level: .debug)
        }
        downloadTasks.removeValue(forKey: task.taskIdentifier)
        activeDownloadCount -= 1
        processQueue()
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            PlaybackManager.sharedBackgroundCompletion?()
            PlaybackManager.sharedBackgroundCompletion = nil
            // Ensure the manifest is persisted after a background sync completes
            IntegrityManager.shared.saveIndex()
        }
    }
    
    func downloadAll(tracks: [Track]) {
        for track in tracks {
            downloadTrack(track)
        }
    }
    
    func resetDownloadState() {
        AppLogger.shared.log("Resetting download state.", level: .info)
        downloadQueue.removeAll()
        downloadTasks.removeAll()
        activeDownloadTasksByTrackId.removeAll()
        downloadProgress.removeAll()
        downloadStartTimes.removeAll()
        downloadRetryCount.removeAll()
        activeDownloadCount = 0
        failedDownloadIds.removeAll()
        pausedDownloadIds.removeAll()
    }
    
    func shufflePlay(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let shuffled = tracks.shuffled()
        if let first = shuffled.first {
            playTrack(first, context: shuffled)
        }
    }

    private func startCrossfade() {
        guard !isCrossfading, currentTrack != nil, queue.count > 0 else { return }

        let nextIndex = (queueIndex + 1) % queue.count
        if nextIndex == queueIndex && repeatMode == .off { return }

        let nextTrack = queue[nextIndex]
        isCrossfading = true

        // ── Resolve the AVPlayerItem ───────────────────────────────────────────────
        // Prefer the pre-warmed item that has been buffering since track start.
        // If it matches the next track, reuse it directly → Phase 1 wait is ~0 ms.
        // If there's no pre-warmed item (e.g. crossfade was toggled on mid-track),
        // fall back to creating a fresh item with a conservative buffer hint.
        let playerItem: AVPlayerItem
        if let warmed = prewarmedItem, prewarmedTrackId == nextTrack.id {
            playerItem = warmed
            prewarmedItem    = nil
            prewarmedTrackId = nil
        } else {
            // Cold fallback path
            let urlToPlay: URL
            if let localUrl = getLocalAudioUrl(for: nextTrack.id) {
                urlToPlay = localUrl
            } else {
                urlToPlay = client.getStreamUrl(id: nextTrack.id) ?? URL(string: "about:blank")!
            }
            playerItem = AVPlayerItem(url: urlToPlay)
            playerItem.preferredForwardBufferDuration = 6.0
        }

        let secPlayer = AVPlayer(playerItem: playerItem)
        secPlayer.volume = 0.0      // Silent until buffered
        secPlayer.play()            // Ensure playback is running
        secondaryPlayer = secPlayer

        Task { @MainActor in
            // ── Phase 1: Wait for readyToPlay (max 10 s) ──────────────────────────
            // With a pre-warmed item this resolves instantly (0–1 poll iterations).
            // With a cold item this may take 2–4 s on a slow network; the primary
            // player stays at 1.0 volume the whole time — zero audible gap.
            var waitSteps = 100     // 100 × 100 ms = 10 s timeout
            while self.secondaryPlayer?.currentItem?.status != .readyToPlay && waitSteps > 0 {
                guard self.isCrossfading else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 s
                waitSteps -= 1
            }

            guard self.isCrossfading else { return }

            // ── Phase 2: Override the audio-graph volume reset ─────────────────────
            // AVPlayer resets volume to 1.0 when its audio nodes connect on
            // readyToPlay. Pin it back to 0 before starting the fade loop.
            self.secondaryPlayer?.volume = 0.0

            // ── Phase 3: Equal-power crossfade ─────────────────────────────────────
            let fadeDuration = self.crossfadeDuration
            let steps = 60
            let interval = fadeDuration / Double(steps)

            for step in 1...steps {
                guard self.isCrossfading else { break }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard self.isCrossfading else { break }

                let t = Double(step) / Double(steps)
                let angle = t * (.pi / 2.0)
                self.player?.volume = Float(cos(angle))
                self.secondaryPlayer?.volume = Float(sin(angle))
            }

            if self.isCrossfading {
                if let nextItem = self.secondaryPlayer?.currentItem {
                    self.completeCrossfade(nextTrack: nextTrack, nextItem: nextItem)
                }
            }
        }
    }

    private func completeCrossfade(nextTrack: Track, nextItem: AVPlayerItem) {
        // Scrobble previous track
        if let track = self.currentTrack {
            self.client.scrobble(id: track.id, submission: true)
        }

        // Cleanly tear down the old player's observers BEFORE swapping references
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let itemObserver = playerItemObserver {
            NotificationCenter.default.removeObserver(itemObserver)
            playerItemObserver = nil
        }
        player?.pause()

        // Swap primary ← secondary
        player = secondaryPlayer
        secondaryPlayer = nil
        currentTrack = nextTrack
        queueIndex = (queueIndex + 1) % queue.count
        isCrossfading = false
        player?.volume = 1.0

        // Clear stale visual & artwork state so the new track loads fresh assets
        self.progress = 0
        self.duration = 0
        self.currentArtworkTrackId = nil
        self.downloadingArtworkTrackId = nil
        self.artworkDownloadTask?.cancel()
        self.artworkDownloadTask = nil
        FanartManager.shared.currentBackdrop = nil

        // Wire up observers and fetch metadata for the new track
        setupObservers(for: nextItem, track: nextTrack)
        fetchMetadata(for: nextTrack)
    }
    
    private func setupObservers(for item: AVPlayerItem, track: Track) {
        // Capture the player instance so stale observers from a previous item
        // cannot update progress/duration after the player has been replaced.
        let capturedPlayer = player
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak capturedPlayer] time in
            guard let self = self,
                  let capturedPlayer = capturedPlayer,
                  self.player === capturedPlayer,  // Only the ACTIVE player may update progress
                  let currentItem = capturedPlayer.currentItem,
                  currentItem.duration.isNumeric else { return }

            self.progress = time.seconds
            self.duration = currentItem.duration.seconds
            self.updateNowPlayingInfo()

            // Gate: only crossfade when the track is at least 2× the fade window long
            let triggerTime = self.duration - self.crossfadeDuration
            if self.isCrossfadeEnabled &&
               !self.isCrossfading &&
               self.duration > (self.crossfadeDuration * 2.0) &&
               time.seconds > triggerTime {
                self.startCrossfade()
            }
        }
        
        playerItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isCrossfading { return }
                
                if let t = self.currentTrack {
                    self.client.scrobble(id: t.id, submission: true)
                }
                
                switch self.repeatMode {
                case .one:
                    self.player?.seek(to: .zero)
                    self.player?.play()
                case .all, .off:
                    self.skipForward()
                }
            }
        }
    }
    
    private func fetchMetadata(for track: Track) {
        // Lyrics work offline (returns disk-cached lyrics)
        client.fetchLyrics(trackId: track.id, artist: track.artist ?? "", title: track.title) { lyrics in
            DispatchQueue.main.async {
                if self.currentTrack?.id == track.id {
                    if let lyrics = lyrics {
                        self.currentLyrics = lyrics
                        if lyrics.contains("[00:") || lyrics.contains("[01:") || lyrics.contains("[02:") {
                            self.currentSyncedLyrics = self.parseLRC(lyrics)
                        } else {
                            self.currentSyncedLyrics = nil
                        }
                    } else {
                        self.currentLyrics = nil
                        self.currentSyncedLyrics = nil
                    }
                }
            }
        }
        
        // Network-only: skip backdrop fetch when offline
        if NetworkMonitor.shared.isConnected {
            if let artistId = track.artistId {
                client.fetchArtistInfo(artistId: artistId) { _, mbid in
                    DispatchQueue.main.async {
                        FanartManager.shared.fetchBackdrop(for: track.artist ?? "", mbid: mbid)
                    }
                }
            } else {
                FanartManager.shared.fetchBackdrop(for: track.artist ?? "")
            }
        }
    }
    
}

extension UIColor {
    fileprivate func adjustColor(hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard self.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(
            hue:        (h + hue).truncatingRemainder(dividingBy: 1.0) < 0
                            ? (h + hue).truncatingRemainder(dividingBy: 1.0) + 1.0
                            : (h + hue).truncatingRemainder(dividingBy: 1.0),
            saturation: max(0, min(1, s + saturation)),
            brightness: max(0, min(1, b + brightness)),
            alpha:      max(0, min(1, a + alpha))
        )
    }
}

extension UIImage {
    func dominantColor() -> UIColor? {
        guard let inputImage = CIImage(image: self) else { return nil }
        let extentVector = CIVector(x: inputImage.extent.origin.x, y: inputImage.extent.origin.y, z: inputImage.extent.size.width, w: inputImage.extent.size.height)

        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]) else { return nil }
        guard let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        return UIColor(red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255, blue: CGFloat(bitmap[2]) / 255, alpha: CGFloat(bitmap[3]) / 255)
    }

    func extractPalette(count: Int = 5) -> [UIColor] {
        // 1. Resize image to 16x16 for performance
        let size = CGSize(width: 16, height: 16)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        self.draw(in: CGRect(origin: .zero, size: size))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let cgImage = resizedImage?.cgImage else { return [.black, .black, .black, .black, .black] }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return [.black, .black, .black, .black, .black] }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // 2. Count color frequencies using a quantization bucket (5 bits per channel)
        var colorCounts: [Int: (r: Int, g: Int, b: Int, count: Int)] = [:]
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = Int(rawData[offset])
                let g = Int(rawData[offset + 1])
                let b = Int(rawData[offset + 2])
                let a = Int(rawData[offset + 3])
                
                if a > 127 { // Only consider mostly opaque pixels
                    // Quantize to 32 levels per channel (15-bit color precision for bucketing)
                    let qr = r >> 3
                    let qg = g >> 3
                    let qb = b >> 3
                    let key = (qr << 10) | (qg << 5) | qb
                    
                    if let existing = colorCounts[key] {
                        colorCounts[key] = (existing.r + r, existing.g + g, existing.b + b, existing.count + 1)
                    } else {
                        colorCounts[key] = (r, g, b, 1)
                    }
                }
            }
        }
        
        // 3. Average the colors in each bucket and convert to UIColor, sorted by frequency
        let frequentColors = colorCounts.values.sorted { $0.count > $1.count }.map { bucket -> UIColor in
            return UIColor(
                red: CGFloat(bucket.r / bucket.count) / 255.0,
                green: CGFloat(bucket.g / bucket.count) / 255.0,
                blue: CGFloat(bucket.b / bucket.count) / 255.0,
                alpha: 1.0
            )
        }
        
        // Helper to compute color distance
        func distance(from c1: UIColor, to c2: UIColor) -> CGFloat {
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let dr = r1 - r2
            let dg = g1 - g2
            let db = b1 - b2
            return sqrt(dr*dr + dg*dg + db*db)
        }
        
        var distinctColors: [UIColor] = []
        for color in frequentColors {
            var brightness: CGFloat = 0
            color.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
            
            // Skip extremely dark/bright colors for gradient aesthetics, unless it's the only color left
            if (brightness < 0.1 || brightness > 0.9) && distinctColors.count > 0 { continue }
            
            // Ensure color is visually distinct from already selected colors
            let isDistinct = distinctColors.allSatisfy { distance(from: color, to: $0) > 0.20 }
            if isDistinct || distinctColors.isEmpty {
                distinctColors.append(color)
                if distinctColors.count >= count { break }
            }
        }
        
        // Fallback: fill remaining slots with the most frequent colors if we couldn't find enough distinct ones
        if distinctColors.count < count {
            for color in frequentColors {
                if !distinctColors.contains(color) {
                    distinctColors.append(color)
                    if distinctColors.count >= count { break }
                }
            }
        }
        
        // Final fallback if image was empty or pure transparent
        if distinctColors.isEmpty {
            if let firstDominant = dominantColor() {
                distinctColors.append(firstDominant)
            } else {
                distinctColors.append(.black)
            }
        }
        while distinctColors.count < count {
            let baseColor = distinctColors[0]
            
            // To pad the palette without introducing new color families,
            // we create analogous and monochromatic variations using tiny hue shifts
            // and alternating brightness/saturation adjustments. This is the 
            // golden standard approach used to preserve the album's tonal identity.
            let step = CGFloat(distinctColors.count)
            let isEven = distinctColors.count % 2 == 0
            
            // A micro-shift in hue (0.02 is ~7 degrees) creates natural "analogous" colors
            let hueShift = isEven ? 0.02 * step : -0.02 * step
            let saturationShift = isEven ? -0.05 * step : 0.05 * step
            let brightnessShift = isEven ? 0.08 * step : -0.08 * step
            
            distinctColors.append(baseColor.adjustColor(hue: hueShift, saturation: saturationShift, brightness: brightnessShift))
        }
        
        return distinctColors
    }
}
