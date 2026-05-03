import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct LyricLine: Hashable {
    let time: Double
    let text: String
}

class PlaybackManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static var shared: PlaybackManager?
    static var sharedBackgroundCompletion: (() -> Void)?
    
    @Published var currentTrack: Track?
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var currentLyrics: String? = nil
    @Published var currentSyncedLyrics: [LyricLine]? = nil
    @Published var isLyricsMode: Bool = false
    
    // Queue support
    @Published var queue: [Track] = []
    @Published var queueIndex: Int = 0
    @Published var isShuffle: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var downloadedTrackIds = Set<String>()
    @Published var failedDownloadIds = Set<String>()
    @Published var activeDownloadCount = 0
    private var playbackHistory: [Int] = []
    
    enum RepeatMode {
        case off, one, all
    }
    
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadETAs: [String: String] = [:]
    
    private var downloadQueue: [Track] = []
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
    
    // Playback Engines
    private var player: AVPlayer?
    private var secondaryPlayer: AVPlayer?
    
    // Advanced Audio Buffering (The Last 3%)
    private var hiFiRenderer: AVSampleBufferAudioRenderer?
    private var hiFiSynchronizer: AVSampleBufferRenderSynchronizer?
    private var assetReader: AVAssetReader?
    private var assetReaderOutput: AVAssetReaderTrackOutput?
    
    // Gapless Look-ahead
    private var nextAssetReader: AVAssetReader?
    private var nextAssetReaderOutput: AVAssetReaderTrackOutput?
    
    private var isCrossfading = false
    private var timeObserver: Any?
    private var playerItemObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var currentArtworkTrackId: String? = nil
    var client: NavidromeClient
    
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConcurrentDownloads
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    } ()
    
    init(client: NavidromeClient) {
        self.client = client
        super.init()
        PlaybackManager.shared = self
        configureAudioSession()
        setupRemoteCommandCenter()
        loadDownloadedTracks()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleTerminate), name: UIApplication.willTerminateNotification, object: nil)
    }
    
    @objc private func handleTerminate() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player?.pause()
        stopHiFiRenderer()
    }
    
    // MARK: - Audio Session
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            
            NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
            NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        } catch {
            AppLogger.shared.log("Failed to configure audio session: \(error)", level: .error)
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .began {
            pause()
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) { play() }
            }
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        if reason == .oldDeviceUnavailable {
            pause()
        }
    }
    
    // MARK: - Playback Core
    
    func playTrack(_ track: Track, context: [Track] = []) {
        if !context.isEmpty {
            self.queue = context
            self.queueIndex = context.firstIndex(where: { $0.id == track.id }) ?? 0
        }
        loadAndPlay(track: track)
    }
    
    private func loadAndPlay(track: Track) {
        stopHiFiRenderer()
        cleanupObservers()
        
        self.currentTrack = track
        self.progress = 0
        self.duration = track.duration
        
        let url = getEffectiveUrl(for: track)
        
        // Strategy: Use AVSampleBufferAudioRenderer for FLAC or Hi-Fi preference
        let useHiFi = track.suffix?.lowercased() == "flac" || UserDefaults.standard.bool(forKey: "velora_force_hifi")
        
        if useHiFi && url.isFileURL {
            setupHiFiRenderer(for: url)
        } else {
            let playerItem = AVPlayerItem(url: url)
            self.player = AVPlayer(playerItem: playerItem)
            setupObservers(for: player!, track: track)
            player?.play()
        }
        
        self.isPlaying = true
        fetchMetadata(for: track)
        updateNowPlayingInfo()
    }
    
    private func getEffectiveUrl(for track: Track) -> URL {
        // Persistence Layer Optimization: Check local store first
        if let persistent = LocalMetadataStore.shared.fetchTrack(id: track.id),
           persistent.isDownloaded,
           let path = persistent.localFilePath {
            return URL(fileURLWithPath: path)
        }
        
        // Fallback to dynamic lookup if store is stale
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let extensions = ["flac", "mp3", "m4a", "wav"]
        for ext in extensions {
            let url = docs.appendingPathComponent("\(track.id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { 
                LocalMetadataStore.shared.updateDownloadStatus(for: track.id, isDownloaded: true, localPath: url.path)
                return url 
            }
        }
        return client.getStreamUrl(id: track.id) ?? URL(string: "about:blank")!
    }
    
    // MARK: - Advanced Audio Buffering (The Last 3%)
    
    private func setupHiFiRenderer(for url: URL) {
        let asset = AVAsset(url: url)
        do {
            assetReader = try AVAssetReader(asset: asset)
            guard let audioTrack = asset.tracks(withMediaType: .audio).first else { 
                fallbackToStandardPlayer(url: url)
                return 
            }
            
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            assetReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            assetReader?.add(assetReaderOutput!)
            assetReader?.startReading()
            
            hiFiRenderer = AVSampleBufferAudioRenderer()
            hiFiSynchronizer = AVSampleBufferRenderSynchronizer()
            hiFiSynchronizer?.addRenderer(hiFiRenderer!)
            
            requestDataFromAssetReader()
            hiFiSynchronizer?.setRate(1.0, time: .zero)
            
            // Progress observer for Hi-Fi
            setupHiFiTimeObserver()
            
            AppLogger.shared.log("Hi-Fi Bit-Perfect Renderer active for: \(currentTrack?.title ?? "Unknown")", level: .info)
        } catch {
            fallbackToStandardPlayer(url: url)
        }
    }
    
    private func requestDataFromAssetReader() {
        guard let renderer = hiFiRenderer, let output = assetReaderOutput else { return }
        renderer.requestMediaDataWhenReady(on: .global(qos: .userInteractive)) { [weak self] in
            guard let self = self else { return }
            while renderer.isReadyForMoreMediaData {
                if let sampleBuffer = output.copyNextSampleBuffer() {
                    renderer.enqueue(sampleBuffer)
                } else {
                    renderer.stopRequestingData()
                    break
                }
            }
        }
    }
    
    private func setupHiFiTimeObserver() {
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self, let sync = self.hiFiSynchronizer, self.isPlaying else { 
                if self?.hiFiSynchronizer == nil { timer.invalidate() }
                return 
            }
            let currentTime = CMTimeGetSeconds(sync.currentTime())
            DispatchQueue.main.async {
                self.progress = currentTime
                
                // Gapless Transition Trigger (The Last 3%)
                if self.duration > 0 && currentTime >= self.duration - 0.1 {
                    self.executeGaplessTransition()
                    timer.invalidate()
                    return
                }
                
                // Pre-fetch next track for gapless (at 5s remaining)
                if self.duration > 0 && currentTime >= self.duration - 5.0 && self.nextAssetReader == nil {
                    self.prepareNextTrackForGapless()
                }
            }
        }
    }
    
    private func executeGaplessTransition() {
        guard queueIndex + 1 < queue.count else {
            isPlaying = false
            currentTrack = nil
            return
        }
        
        if let reader = nextAssetReader, let output = nextAssetReaderOutput {
            // Hot-swap: Use pre-loaded asset reader
            AppLogger.shared.log("[Hi-Fi] Executing Gapless Transition...", level: .info)
            self.assetReader = reader
            self.assetReaderOutput = output
            self.nextAssetReader = nil
            self.nextAssetReaderOutput = nil
            
            self.queueIndex += 1
            self.currentTrack = queue[queueIndex]
            self.duration = currentTrack?.duration ?? 0
            self.progress = 0
            
            // Re-configure renderer for new stream
            self.requestDataFromAssetReader()
            self.hiFiSynchronizer?.setRate(1.0, time: .zero)
            self.setupHiFiTimeObserver()
            self.updateNowPlayingInfo()
        } else {
            // Fallback to standard transition
            self.nextTrack()
        }
    }
    
    private func prepareNextTrackForGapless() {
        guard nextAssetReader == nil, queueIndex + 1 < queue.count else { return }
        let nextTrack = queue[queueIndex + 1]
        let url = getEffectiveUrl(for: nextTrack)
        guard url.isFileURL else { return } // Gapless look-ahead only for local files
        
        let asset = AVAsset(url: url)
        do {
            nextAssetReader = try AVAssetReader(asset: asset)
            guard let audioTrack = asset.tracks(withMediaType: .audio).first else { return }
            nextAssetReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            nextAssetReader?.add(nextAssetReaderOutput!)
            nextAssetReader?.startReading()
            AppLogger.shared.log("Gapless look-ahead prepared for: \(nextTrack.title)", level: .info)
        } catch { }
    }
    
    private func fallbackToStandardPlayer(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: playerItem)
        if let track = currentTrack { setupObservers(for: player!, track: track) }
        player?.play()
    }
    
    private func stopHiFiRenderer() {
        hiFiRenderer?.stopRequestingData()
        hiFiRenderer = nil
        hiFiSynchronizer = nil
        assetReader?.cancelReading()
        assetReader = nil
        assetReaderOutput = nil
        nextAssetReader?.cancelReading()
        nextAssetReader = nil
        nextAssetReaderOutput = nil
    }
    
    // MARK: - Standard AVPlayer Logic
    
    private func setupObservers(for player: AVPlayer, track: Track) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = CMTimeGetSeconds(time)
            self.progress = seconds
            self.duration = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
            
            // Gapless/Crossfade trigger
            if self.duration > 0 && seconds >= self.duration - self.crossfadeDuration && !self.isCrossfading && self.isCrossfadeEnabled {
                self.startCrossfade()
            }
        }
        
        playerItemObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            self?.nextTrack()
        }
        
        statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                AppLogger.shared.log("Playback failed for \(track.title)", level: .error)
                self?.nextTrack()
            }
        }
    }
    
    private func cleanupObservers() {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        if let itemObserver = playerItemObserver { NotificationCenter.default.removeObserver(itemObserver) }
        statusObserver?.invalidate()
        timeObserver = nil
        playerItemObserver = nil
        statusObserver = nil
    }
    
    // MARK: - Crossfade
    
    private func startCrossfade() {
        guard !isCrossfading, queueIndex + 1 < queue.count else { return }
        isCrossfading = true
        
        let nextTrack = queue[queueIndex + 1]
        let url = getEffectiveUrl(for: nextTrack)
        let nextItem = AVPlayerItem(url: url)
        secondaryPlayer = AVPlayer(playerItem: nextItem)
        secondaryPlayer?.volume = 0
        secondaryPlayer?.play()
        
        // Fade out current, fade in next
        let steps = 20
        let interval = crossfadeDuration / Double(steps)
        var currentStep = 0
        
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            currentStep += 1
            let ratio = Double(currentStep) / Double(steps)
            self.player?.volume = Float(1.0 - ratio)
            self.secondaryPlayer?.volume = Float(ratio)
            
            if currentStep >= steps {
                timer.invalidate()
                self.completeCrossfade(with: nextTrack)
            }
        }
    }
    
    private func completeCrossfade(with track: Track) {
        player?.pause()
        player = secondaryPlayer
        secondaryPlayer = nil
        player?.volume = 1.0
        queueIndex += 1
        currentTrack = track
        isCrossfading = false
        cleanupObservers()
        setupObservers(for: player!, track: track)
        updateNowPlayingInfo()
    }
    
    // MARK: - Controls
    
    func play() {
        if hiFiSynchronizer != nil {
            hiFiSynchronizer?.setRate(1.0, time: hiFiSynchronizer!.currentTime())
        } else {
            player?.play()
        }
        isPlaying = true
        updateNowPlayingInfo()
    }
    
    func pause() {
        if hiFiSynchronizer != nil {
            hiFiSynchronizer?.setRate(0, time: hiFiSynchronizer!.currentTime())
        } else {
            player?.pause()
        }
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func nextTrack() {
        if repeatMode == .one {
            if let current = currentTrack { loadAndPlay(track: current) }
            return
        }
        
        if queueIndex + 1 < queue.count {
            queueIndex += 1
            loadAndPlay(track: queue[queueIndex])
        } else if repeatMode == .all && !queue.isEmpty {
            queueIndex = 0
            loadAndPlay(track: queue[0])
        } else {
            isPlaying = false
            currentTrack = nil
        }
    }
    
    func prevTrack() {
        if progress > 3.0 {
            seek(to: 0)
            return
        }
        if queueIndex > 0 {
            queueIndex -= 1
            loadAndPlay(track: queue[queueIndex])
        }
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        if let sync = hiFiSynchronizer {
            sync.setRate(isPlaying ? 1.0 : 0, time: cmTime)
        } else {
            player?.seek(to: cmTime)
        }
    }
    
    // MARK: - Metadata & Lyrics
    
    private func fetchMetadata(for track: Track) {
        client.fetchLyrics(artist: track.artist ?? "", title: track.title) { lyrics in
            DispatchQueue.main.async {
                guard self.currentTrack?.id == track.id else { return }
                self.currentLyrics = lyrics
                self.currentSyncedLyrics = lyrics.map { self.parseLRC($0) }
            }
        }
        
        FanartManager.shared.fetchBackdrop(for: track.artist ?? "")
    }
    
    private func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = "\\[(\\d+):(\\d+)\\.(\\d+)\\](.*)"
        let regex = try? NSRegularExpression(pattern: pattern)
        let nsString = lrc as NSString
        
        lrc.enumerateLines { line, _ in
            if let match = regex?.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) {
                let min = Double(nsString.substring(with: match.range(at: 1))) ?? 0
                let sec = Double(nsString.substring(with: match.range(at: 2))) ?? 0
                let ms = Double(nsString.substring(with: match.range(at: 3))) ?? 0
                let text = nsString.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                let time = min * 60 + sec + ms / 100.0
                lines.append(LyricLine(time: time, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
    
    // MARK: - Now Playing Info
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { 
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return 
        }
        
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist ?? "Unknown Artist",
            MPMediaItemPropertyAlbumTitle: track.album ?? "Unknown Album",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        
        if let coverUrl = URL(string: track.coverArt ?? "") {
            URLSession.shared.dataTask(with: coverUrl) { data, _, _ in
                if let data = data, let image = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    DispatchQueue.main.async {
                        info[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    }
                }
            }.resume()
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in self.play(); return .success }
        center.pauseCommand.addTarget { _ in self.pause(); return .success }
        center.nextTrackCommand.addTarget { _ in self.nextTrack(); return .success }
        center.previousTrackCommand.addTarget { _ in self.prevTrack(); return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            if let ev = event as? MPChangePlaybackPositionCommandEvent {
                self.seek(to: ev.positionTime)
                return .success
            }
            return .commandFailed
        }
    }
    
    // MARK: - Download Management
    
    func downloadTrack(_ track: Track) {
        guard !isDownloaded(track.id), !downloadTasks.values.contains(track.id) else { return }
        guard let url = client.getDownloadUrl(id: track.id) else { return }
        
        let task = downloadSession.downloadTask(with: url)
        downloadTasks[task.taskIdentifier] = track.id
        downloadStartTimes[track.id] = Date()
        activeDownloadCount += 1
        task.resume()
    }
    
    func isDownloaded(_ trackId: String) -> Bool {
        if downloadedTrackIds.contains(trackId) { return true }
        let exists = IntegrityManager.shared.isTrackValid(id: trackId)
        if exists { downloadedTrackIds.insert(trackId) }
        return exists
    }
    
    func checkFileSystemForTrack(_ trackId: String) -> Bool {
        return IntegrityManager.shared.isTrackValid(id: trackId)
    }
    
    func refreshDownloadedTracks() {
        loadDownloadedTracks()
    }
    
    private func loadDownloadedTracks() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let contents = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            let ids = contents.compactMap { url -> String? in
                let name = url.deletingPathExtension().lastPathComponent
                return IntegrityManager.shared.isTrackValid(id: name) ? name : nil
            }
            downloadedTrackIds = Set(ids)
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let trackId = downloadTasks[downloadTask.taskIdentifier] else { return }
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let suffix = "mp3" // Default
        let dest = docs.appendingPathComponent("\(trackId).\(suffix)")
        
        try? FileManager.default.removeItem(at: dest)
        do {
            try? FileManager.default.moveItem(at: location, to: dest)
            downloadedTrackIds.insert(trackId)
            LocalMetadataStore.shared.updateDownloadStatus(for: trackId, isDownloaded: true, localPath: dest.path)
            AppLogger.shared.log("Downloaded: \(trackId)", level: .info)
        } catch {
            failedDownloadIds.insert(trackId)
        }
        
        downloadTasks.removeValue(forKey: downloadTask.taskIdentifier)
        activeDownloadCount -= 1
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let trackId = downloadTasks[downloadTask.taskIdentifier] else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        downloadProgress[trackId] = progress
    }
}
