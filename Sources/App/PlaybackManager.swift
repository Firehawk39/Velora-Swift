import Foundation
import AVFoundation
import MediaPlayer
import UIKit

nonisolated(unsafe) private var playerItemAssociatedTrackKey: UInt8 = 0
extension AVPlayerItem {
    var associatedTrack: Track? {
        get { objc_getAssociatedObject(self, &playerItemAssociatedTrackKey) as? Track }
        set { objc_setAssociatedObject(self, &playerItemAssociatedTrackKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

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
final class PlaybackManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
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
    private var unshuffledQueue: [Track] = []
    @Published var isShuffle: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var downloadedTrackIds = Set<String>()
    @Published var failedDownloadIds = Set<String>()
    @Published var activeDownloadCount = 0

    // Playback History for correct 'Previous' behavior
    private var playbackHistory: [Int] = []
    private var isNavigatingHistory = false

    // Scrobble tracking
    @Published var hasScrobbledCurrentTrack: Bool = false

    private var integrityManager = IntegrityManager.shared
    private var integrityCancellable: Any?

    func isDownloaded(_ trackId: String) -> Bool {
        return downloadedTrackIds.contains(trackId)
    }

    func clearDownloadState() {
        downloadedTrackIds.removeAll()
        activeDownloadTasksByTrackId.removeAll()
        downloadProgress.removeAll()
        pausedDownloadIds.removeAll()
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
    /// Concurrent download slots.
    /// Normal/playback: 10 (conservative — doesn’t compete with audio streaming).
    /// Bulk “Download All Music”: bumped via setBulkDownloadMode(true) to 50.
    private var maxConcurrentDownloads: Int = 10
    private var isDownloadingAll = false
    private var downloadTasks: [Int: String] = [:] // Task ID to Track ID
    private var downloadRetryCount: [String: Int] = [:] // trackId -> retry count
    private let maxRetries = 3

    private var player: AVQueuePlayer?
    private var artworkRetryCount = 0
    private var nextArtworkRetryTime: Date? = nil

    private var timeObserver: Any?
    private var currentItemObserver: NSKeyValueObservation?
    @Published var currentArtworkTrackId: String? = nil
    private var artworkDownloadTask: URLSessionDataTask? = nil
    private var downloadingArtworkTrackId: String? = nil
    private var seekTimer: Timer?

    var client: NavidromeClient

    private lazy var downloadSession: URLSession = {
        let serverUrl = UserDefaults.standard.string(forKey: "velora_server_url") ?? ""
        let isLocalNetwork = serverUrl.contains("192.168.") || serverUrl.contains("10.") || serverUrl.contains("172.") || serverUrl.contains(".local") || serverUrl.contains("localhost") || serverUrl.contains("127.0.0.1")

        let configuration: URLSessionConfiguration
        if isLocalNetwork {
            // iOS 15 Background Daemon is blocked from accessing Local Network IPs.
            // Fall back to a standard foreground session to allow local downloads.
            configuration = URLSessionConfiguration.default
        } else {
            configuration = URLSessionConfiguration.background(withIdentifier: "com.velora.downloads")
        }

        // Maximize connections to the same host for faster concurrent downloads
        configuration.httpMaximumConnectionsPerHost = maxConcurrentDownloads
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

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
        Task { @MainActor in
            self.downloadProgress.removeAll()
            self.pausedDownloadIds.removeAll()
            self.activeDownloadCount = 0
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        #if os(iOS)
        do {
            #if os(macOS) || targetEnvironment(macCatalyst)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            #else
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            #endif
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
            AppLogger.shared.log("Failed to configure audio session: \(error)", level: .error)
        }
        #endif
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
            Task { @MainActor in
                self.isPlaying = false
                self.player?.pause()
                self.updateNowPlayingInfo()
            }
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    Task { @MainActor in
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
            Task { @MainActor in
                self.isPlaying = false
                self.player?.pause()
                self.updateNowPlayingInfo()
            }
        default: break
        }
    }

    // MARK: - Playback Controls

    private func fireAITelemetry(for track: Track) {
        guard let serverStr = UserDefaults.standard.string(forKey: "velora_server_url"),
              var components = URLComponents(string: serverStr) else { return }
        components.port = 8000
        components.path = "/api/v1/telemetry/event"
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let contextStr = "\(track.title) by \(track.artist ?? "Unknown Artist")"
        let body: [String: Any] = [
            "event_type": "play",
            "track_id": track.id,
            "context": contextStr
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Play a single track, optionally with a full queue context
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
        guard isDownloaded(trackId) else { return nil }
        
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
        // Cleanup previous observers
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        currentItemObserver?.invalidate()
        currentItemObserver = nil

        guard let firstItem = createPlayerItem(for: track) else { return }

        if player == nil {
            self.player = AVQueuePlayer(playerItem: firstItem)
        } else {
            self.player?.removeAllItems()
            if self.player?.canInsert(firstItem, after: nil) == true {
                self.player?.insert(firstItem, after: nil)
            }
        }
        
        self.handleTrackTransition(to: track)

        // Set up KVO for gapless transitions
        currentItemObserver = player?.observe(\.currentItem, options: [.new]) { [weak self] player, change in
            Task { @MainActor in
                guard let self = self else { return }
                
                // If queue runs out (last track finished)
                guard let item = player.currentItem, let nextTrack = item.associatedTrack else {
                    if player.currentItem == nil {
                        if let current = self.currentTrack, !self.hasScrobbledCurrentTrack, NetworkMonitor.shared.isConnected {
                            self.hasScrobbledCurrentTrack = true
                            self.client.scrobble(track: current, submission: true)
                        }
                        self.isPlaying = false
                        self.player?.pause()
                    }
                    return 
                }
                
                if self.currentTrack?.id != nextTrack.id {
                    // Scrobble previous track if not already scrobbled
                    if let previousTrack = self.currentTrack, !self.hasScrobbledCurrentTrack, NetworkMonitor.shared.isConnected {
                        self.hasScrobbledCurrentTrack = true
                        self.client.scrobble(track: previousTrack, submission: true)
                    }
                    self.handleTrackTransition(to: nextTrack)
                }
            }
        }

        player?.play()
        self.isPlaying = true

        // Track progress — capture player instance to prevent stale-observer race condition
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
                        if let t = self.currentTrack {
                            self.client.scrobble(track: t, submission: true)
                        }
                    }
                }
            }
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
        // Prewarming and crossfading have been removed per user request.
    }

    private func createPlayerItem(for track: Track) -> AVPlayerItem? {
        let urlToPlay: URL
        if let localUrl = getLocalAudioUrl(for: track.id) {
            urlToPlay = localUrl
        } else {
            guard let streamUrl = client.getStreamUrl(id: track.id) else { return nil }
            urlToPlay = streamUrl
        }
        let item = AVPlayerItem(url: urlToPlay)
        item.associatedTrack = track
        return item
    }

    private func enqueueNextTrack() {
        guard !queue.isEmpty, let player = player else { return }

        // We only queue one track ahead to keep memory low. 
        // If we are at the end of the queue:
        if queueIndex >= queue.count - 1 {
            if repeatMode == .all {
                if let item = createPlayerItem(for: queue[0]) {
                    player.insert(item, after: nil)
                }
            } else if repeatMode == .one {
                if let item = createPlayerItem(for: queue[queueIndex]) {
                    player.insert(item, after: nil)
                }
            }
        } else {
            // Enqueue the next track
            if repeatMode == .one {
                if let item = createPlayerItem(for: queue[queueIndex]) {
                    player.insert(item, after: nil)
                }
            } else {
                if let item = createPlayerItem(for: queue[queueIndex + 1]) {
                    player.insert(item, after: nil)
                }
            }
        }
    }

    private func handleTrackTransition(to track: Track) {
        // Find new queue index (unless we are on repeat one)
        if repeatMode != .one {
            if let idx = queue.firstIndex(where: { $0.id == track.id }) {
                // If moving forward, save history
                if idx > queueIndex && !isNavigatingHistory {
                    playbackHistory.append(queueIndex)
                    if playbackHistory.count > 100 { playbackHistory.removeFirst() }
                }
                queueIndex = idx
                isNavigatingHistory = false
            }
        }

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

        self.currentArtworkTrackId = nil
        FanartManager.shared.currentBackdrop = nil
        FanartManager.shared.currentClearLogo = nil

        client.fetchLyrics(
            trackId: track.id,
            artist: track.artist ?? "",
            title: track.title,
            duration: Double(track.duration ?? 0),
            priority: URLSessionTask.highPriority
        ) { [weak self] lyrics in
            Task { @MainActor in self?.applyLyrics(lyrics, for: track) }
        }

        FanartManager.shared.fetchBackdrop(for: track.allArtists, artistId: track.artistId)

        if NetworkMonitor.shared.isConnected {
            client.scrobble(track: track, submission: false)
            prefetchNextTracks()
            boostCurrentContextDownloads()
        }

        updateNowPlayingInfo()
        
        // Ensure there is always a track queued up after this one
        if player?.items().count == 1 {
            enqueueNextTrack()
        }
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
        
        // Re-evaluate gapless queue based on new mode
        guard let player = player else { return }
        let items = player.items()
        if items.count > 1 {
            for i in 1..<items.count {
                player.remove(items[i])
            }
        }
        enqueueNextTrack()
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

        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] event in
            guard let self = self, let seekEvent = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                if seekEvent.type == .beginSeeking {
                    self.startContinuousSeek(forward: true)
                } else if seekEvent.type == .endSeeking {
                    self.stopContinuousSeek()
                }
            }
            return .success
        }

        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            guard let self = self, let seekEvent = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                if seekEvent.type == .beginSeeking {
                    self.startContinuousSeek(forward: false)
                } else if seekEvent.type == .endSeeking {
                    self.stopContinuousSeek()
                }
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.preferredIntervals = [10.0]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self.seek(to: self.progress + event.interval) }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.preferredIntervals = [10.0]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self.seek(to: self.progress - event.interval) }
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

            let artworkUrl = track.coverArtUrl

            if let url = artworkUrl {
                if !url.isFileURL && !NetworkMonitor.shared.isConnected {
                    return
                }
            } else if !NetworkMonitor.shared.isConnected {
                return
            }

            // Cancel the previous download task if it is still in flight
            artworkDownloadTask?.cancel()
            artworkDownloadTask = nil

            if let artworkUrl = artworkUrl {
                downloadingArtworkTrackId = track.id

                let task = URLSession.shared.dataTask(with: artworkUrl) { [weak self] data, _, error in
                    guard let self = self else { return }

                    // On failure, clear downloadingArtworkTrackId so the next tick can retry
                    if error != nil || data == nil {
                        Task { @MainActor in
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
                        Task { @MainActor in
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

                    Task { @MainActor in
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

    // Compiled once — applied in parseLRC and applyLyrics
    private static let lrcTimestampRegex = try! NSRegularExpression(pattern: #"\[\d+:\d+\.\d+\]"#)
    private static let wordTagRegex = try! NSRegularExpression(pattern: "<(\\d+):(\\d+\\.\\d+)>\\s*([^<]+)")

    /// Single source of truth for applying a lyrics payload to the current track.
    @MainActor
    private func applyLyrics(_ lyrics: String?, for track: Track) {
        guard currentTrack?.id == track.id else { return }
        if let lyrics = lyrics {
            currentLyrics = lyrics
            let range = NSRange(lyrics.startIndex..<lyrics.endIndex, in: lyrics)
            currentSyncedLyrics = Self.lrcTimestampRegex.firstMatch(in: lyrics, range: range) != nil
                ? parseLRC(lyrics)
                : nil
        } else {
            currentLyrics = nil
            currentSyncedLyrics = nil
        }
    }

    private func parseLRC(_ lyrics: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let lines = lyrics.components(separatedBy: .newlines)

        let wordTagRegex = Self.wordTagRegex

        for line in lines {
            guard line.hasPrefix("["), let bracketEnd = line.firstIndex(of: "]") else { continue }
            let timeString = String(line[line.index(after: line.startIndex)..<bracketEnd])
            let rawText = String(line[line.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)
            let parts = timeString.components(separatedBy: ":")
            guard parts.count >= 2, let min = Double(parts[0]), let sec = Double(parts[1]) else { continue }
            let time = min * 60 + sec

            var lyricWords: [LyricWord] = []

            if rawText.contains("<") {
                let nsRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
                let matches = wordTagRegex.matches(in: rawText, range: nsRange)

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
        Task {
            do {
                // Perform the directory contents scanning on a background thread to prevent UI freezing
                let fileURLs = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil)
                }.value

                // Rebuild the index asynchronously on a background context
                await integrityManager.rebuildIndex(from: fileURLs)

                self.downloadedTrackIds = self.integrityManager.downloadedIds
                self.objectWillChange.send()
            } catch {
                AppLogger.shared.log("Error loading downloaded tracks: \(error)", level: .error)
            }
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
        let tracks = DatabaseManager.shared.getTracks(albumId: albumId)
        for track in tracks {
            if isDownloaded(track.id) { deleteDownload(trackId: track.id) }
        }
    }

    func deleteArtistDownloads(artistId: String) {
        let tracks = DatabaseManager.shared.getTracks(artistId: artistId)
        for track in tracks {
            if isDownloaded(track.id) { deleteDownload(trackId: track.id) }
        }
    }

    /// Returns (downloaded, total) count for an album
    func albumDownloadStatus(albumId: String) -> (downloaded: Int, total: Int) {
        let tracks = DatabaseManager.shared.getTracks(albumId: albumId)
        let downloaded = tracks.filter { isDownloaded($0.id) }.count
        return (downloaded, tracks.count)
    }

    /// Returns (downloaded, total) for a list of tracks (e.g., playlist tracks)
    func tracksDownloadStatus(_ tracks: [Track]) -> (downloaded: Int, total: Int) {
        let downloaded = tracks.filter { isDownloaded($0.id) }.count
        return (downloaded, tracks.count)
    }

    func downloadAlbum(albumId: String) {
        let tracks = DatabaseManager.shared.getTracks(albumId: albumId)
        for track in tracks {
            downloadTrack(track)
        }
    }

    func downloadPlaylist(playlistId: String) {
        client.fetchPlaylistTracks(playlistId: playlistId) { tracks in
            Task { @MainActor in
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
                Task { @MainActor in self.pausedDownloadIds.remove(track.id) }
            } else {
                AppLogger.shared.log("Pausing download for \(track.id)", level: .info)
                existingTask.suspend()
                Task { @MainActor in self.pausedDownloadIds.insert(track.id) }
            }
            return
        }

        // 3. Add to queue if not already there
        if downloadProgress[track.id] != nil {
            return
        }

        // Mark as queued immediately
        Task { @MainActor in
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
            Task { @MainActor in
                self.failedDownloadIds.insert(track.id)
                self.downloadProgress.removeValue(forKey: track.id)
                self.activeDownloadCount -= 1
                self.processQueue()
            }
            return
        }

        AppLogger.shared.log("Starting download task for \(track.id) from \(url.absoluteString)", level: .info)
        let task = downloadSession.downloadTask(with: url)
        task.taskDescription = "\(track.id)|\(track.suffix?.lowercased() ?? "mp3")"
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

        // Trigger lyrics fetch alongside the track for offline use
        client.fetchLyrics(trackId: track.id, artist: track.artist ?? "", title: track.title, duration: Double(track.duration ?? 0)) { _ in }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let desc = downloadTask.taskDescription, let separatorIdx = desc.firstIndex(of: "|") else { return }
        let trackId = String(desc[..<separatorIdx])
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        let now = Date()

        Task { @MainActor in
            self.downloadProgress[trackId] = progress

            if let start = self.downloadStartTimes[trackId] {
                let elapsed = now.timeIntervalSince(start)
                if elapsed > 1.0 && progress > 0.05 {
                    let speed = Double(totalBytesWritten) / elapsed // bytes/sec
                    let remainingBytes = Double(totalBytesExpectedToWrite - totalBytesWritten)
                    let remainingTime = remainingBytes / speed

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
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription, let separatorIdx = desc.firstIndex(of: "|") else { return }
        let trackId = String(desc[..<separatorIdx])
        let suffix = String(desc[desc.index(after: separatorIdx)...])

        let downloadsDir = VeloraStorage.tracks
        let destinationUrl = downloadsDir.appendingPathComponent("\(trackId).\(suffix)")

        do {
            if FileManager.default.fileExists(atPath: destinationUrl.path) {
                try FileManager.default.removeItem(at: destinationUrl)
            }

            // iOS 15 Sandbox Fix: Copy the file instead of moving it to avoid "Operation not permitted"
            // when modifying the system-owned temporary directory.
            do {
                try FileManager.default.copyItem(at: location, to: destinationUrl)
            } catch {
                // Absolute fallback: Read into memory and write to disk
                let data = try Data(contentsOf: location)
                try data.write(to: destinationUrl)
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: destinationUrl.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            Task { @MainActor in
                if fileSize < 1024 {
                     AppLogger.shared.log("FAILURE: Downloaded file for \(trackId) is corrupted. Retrying.", level: .error)
                     try? FileManager.default.removeItem(at: destinationUrl)
                     let retries = self.downloadRetryCount[trackId, default: 0]
                     if retries < self.maxRetries {
                         self.downloadRetryCount[trackId] = retries + 1
                         let delay = pow(2.0, Double(retries))
                         Task {
                             try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                             if let track = DatabaseManager.shared.getTrack(id: trackId) ?? self.queue.first(where: { $0.id == trackId }) {
                                 self.downloadProgress[trackId] = nil
                                 self.downloadTrack(track)
                             }
                         }
                     } else {
                         self.failedDownloadIds.insert(trackId)
                         self.downloadProgress.removeValue(forKey: trackId)
                         self.activeDownloadTasksByTrackId.removeValue(forKey: trackId)
                     }
                } else {
                     IntegrityManager.shared.registerDownload(trackId: trackId, fileName: destinationUrl.lastPathComponent, size: fileSize)
                     self.downloadedTrackIds.insert(trackId)
                     self.downloadProgress.removeValue(forKey: trackId)
                     self.downloadETAs.removeValue(forKey: trackId)
                     self.downloadStartTimes.removeValue(forKey: trackId)
                     self.activeDownloadTasksByTrackId.removeValue(forKey: trackId)
                     self.objectWillChange.send()
                }
            }
        } catch {
            AppLogger.shared.log("Failed to move downloaded file: \(error.localizedDescription)", level: .error)
            Task { @MainActor in
                self.failedDownloadIds.insert(trackId)
                self.downloadProgress.removeValue(forKey: trackId)
                self.activeDownloadTasksByTrackId.removeValue(forKey: trackId)
            }
        }
        // Removed: downloadTasks.removeValue(forKey: downloadTask.taskIdentifier)
        // We now only remove in didCompleteWithError to ensure the ID is available there.
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription, let separatorIdx = desc.firstIndex(of: "|") else { return }
        let trackId = String(desc[..<separatorIdx])

        Task { @MainActor in
            self.activeDownloadTasksByTrackId.removeValue(forKey: trackId)

            if let error = error {
                let nsError = error as NSError
                if nsError.code != NSURLErrorCancelled {
                    let retries = self.downloadRetryCount[trackId, default: 0]
                    if retries < self.maxRetries {
                        self.downloadRetryCount[trackId] = retries + 1
                        let delay = pow(2.0, Double(retries))
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            if let track = DatabaseManager.shared.getTrack(id: trackId) ?? self.queue.first(where: { $0.id == trackId }) {
                                self.downloadProgress[trackId] = nil
                                self.downloadTrack(track)
                            }
                        }
                    } else {
                        self.failedDownloadIds.insert(trackId)
                        self.downloadProgress.removeValue(forKey: trackId)
                        self.downloadETAs.removeValue(forKey: trackId)
                        self.downloadStartTimes.removeValue(forKey: trackId)
                        self.downloadRetryCount.removeValue(forKey: trackId)
                    }
                }
            }
            self.downloadTasks.removeValue(forKey: task.taskIdentifier)
            self.activeDownloadCount -= 1
            self.processQueue()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            PlaybackManager.sharedBackgroundCompletion?()
            PlaybackManager.sharedBackgroundCompletion = nil
            IntegrityManager.shared.saveIndex()
        }
    }

    func downloadAll(tracks: [Track]) {
        for track in tracks {
            downloadTrack(track)
        }
    }

    /// Call with `true` when starting a bulk "Download All Music" operation and
    /// `false` when it finishes. Raises/lowers the concurrency slot count so the
    /// extra parallelism is ONLY active during the mass-download, not during
    /// normal playback or single-track downloads.
    func setBulkDownloadMode(_ enabled: Bool) {
        if enabled {
            // User requested maximum concurrency for Navidrome server downloads (no limits).
            maxConcurrentDownloads = 50
        } else {
            // Back to the safe default that won’t compete with audio playback.
            maxConcurrentDownloads = 10
        }
        AppLogger.shared.log(
            "[Download] Bulk mode \(enabled ? "ON" : "OFF") — maxConcurrent=\(maxConcurrentDownloads)",
            level: .info
        )
        // Kick the queue in case slots just opened up
        if enabled { processQueue() }
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

    func toggleShuffle() {
        isShuffle.toggle()
        if isShuffle {
            applyShuffle()
        } else {
            restoreUnshuffledQueue()
        }
    }

    private func applyShuffle() {
        guard !queue.isEmpty else { return }
        let current = queue[queueIndex]
        unshuffledQueue = queue
        var newQueue = distributedShuffle(tracks: queue)
        if let idx = newQueue.firstIndex(where: { $0.id == current.id }) {
            newQueue.swapAt(0, idx)
        }
        queue = newQueue
        queueIndex = 0
    }

    private func restoreUnshuffledQueue() {
        guard !unshuffledQueue.isEmpty else { return }
        let current = queue[queueIndex]
        queue = unshuffledQueue
        queueIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
    }

    func shufflePlay(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        isShuffle = true
        let shuffled = distributedShuffle(tracks: tracks)
        if let first = shuffled.first {
            playTrack(first, context: shuffled)
        }
    }

    private func distributedShuffle(tracks: [Track]) -> [Track] {
        guard tracks.count > 1 else { return tracks }

        // 1. Group tracks by artist
        var grouped: [String: [Track]] = [:]
        for track in tracks {
            let key = track.artist ?? "Unknown Artist"
            grouped[key, default: []].append(track)
        }

        var scoredTracks: [(track: Track, score: Double)] = []

        // 2. Assign spaced-out scores to each track
        for (_, group) in grouped {
            let shuffledGroup = group.shuffled()
            let increment = 1.0 / Double(shuffledGroup.count)

            for (index, track) in shuffledGroup.enumerated() {
                // Perfect spacing + random jitter
                let baseScore = Double(index) * increment
                let jitter = Double.random(in: 0..<increment)
                let finalScore = baseScore + jitter
                scoredTracks.append((track: track, score: finalScore))
            }
        }

        // 3. Sort by score
        return scoredTracks.sorted { $0.score < $1.score }.map { $0.track }
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
