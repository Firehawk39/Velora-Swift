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
    
    func isDownloaded(_ trackId: String) -> Bool {
        return downloadedTrackIds.contains(trackId)
    }
    
    /// Checks the file system directly for the existence of the track file
    func checkFileSystemForTrack(_ trackId: String) -> Bool {
        let fileManager = FileManager.default
        let downloadsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mp3Path = downloadsDir.appendingPathComponent("\(trackId).mp3").path
        let flacPath = downloadsDir.appendingPathComponent("\(trackId).flac").path
        let m4aPath = downloadsDir.appendingPathComponent("\(trackId).m4a").path
        
        var isDir: ObjCBool = false
        for path in [mp3Path, flacPath, m4aPath] {
            if fileManager.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue {
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
    private var isDownloadingAll = false
    private var downloadTasks: [Int: String] = [:] // Task ID to Track ID
    
    private var player: AVPlayer?
    private var secondaryPlayer: AVPlayer?
    private var isCrossfading = false
    private var timeObserver: Any?
    private var playerItemObserver: Any?
    private var currentArtworkTrackId: String? = nil
    var client: NavidromeClient
    
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.velora.downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    } ()
    
    init(client: NavidromeClient) {
        self.client = client
        super.init()
        PlaybackManager.shared = self
        configureAudioSession()
        setupRemoteCommandCenter() // Activate steering wheel and lock screen controls
        loadDownloadedTracks()
        
        // Listen for app termination to clear now playing info
        NotificationCenter.default.addObserver(self, selector: #selector(handleTerminate), name: UIApplication.willTerminateNotification, object: nil)
    }
    
    @objc private func handleTerminate() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player?.pause()
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
        if !context.isEmpty {
            self.queue = context
            self.queueIndex = context.firstIndex(where: { $0.id == track.id }) ?? 0
        } else {
            self.queue = [track]
            self.queueIndex = 0
        }
        
        loadAndPlay(track: track)
    }
    
    private func loadAndPlay(track: Track) {
        // Cancel crossfade if active
        if isCrossfading {
            isCrossfading = false
            secondaryPlayer?.pause()
            secondaryPlayer = nil
            player?.volume = 1.0
        }

        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localUrl = documentsDirectory.appendingPathComponent("\(track.id).mp3")
        
        let urlToPlay: URL
        if FileManager.default.fileExists(atPath: localUrl.path) {
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
        self.progress = 0
        self.duration = 0
        self.currentLyrics = nil
        self.currentSyncedLyrics = nil
        
        // Fetch lyrics
        client.fetchLyrics(artist: track.artist ?? "", title: track.title) { lyrics in
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
        
        // Fetch Backdrop (Fanart/Discogs)
        if let artistId = track.artistId {
            client.fetchArtistInfo(artistId: artistId) { _, mbid in
                FanartManager.shared.fetchBackdrop(for: track.artist ?? "", mbid: mbid)
            }
        } else {
            FanartManager.shared.fetchBackdrop(for: track.artist ?? "")
        }
        
        player?.play()
        self.isPlaying = true
        
        // Track progress
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self,
                  let item = self.player?.currentItem,
                  item.duration.isNumeric else { return }
            
            self.progress = time.seconds
            self.duration = item.duration.seconds
            self.updateNowPlayingInfo()
            
            // Crossfade check
            if self.isCrossfadeEnabled && !self.isCrossfading && self.duration > 0 && time.seconds > (self.duration - self.crossfadeDuration) {
                self.startCrossfade()
            }
        }
        
        // Auto-advance to next track when done
        playerItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isCrossfading { return }
            
            if let track = self.currentTrack {
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
        
        // Mark as "Now Playing" on server
        client.scrobble(id: track.id, submission: false)
        
        updateNowPlayingInfo()
        prefetchNextTracks()
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
        let nextIndex: Int
        if isShuffle {
            var rand = Int.random(in: 0..<queue.count)
            if rand == queueIndex && queue.count > 1 { rand = (rand + 1) % queue.count }
            nextIndex = rand
        } else {
            nextIndex = (queueIndex + 1) % queue.count
        }
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
        // If more than 3 seconds in, restart. Otherwise go to previous.
        if progress > 3 {
            player?.seek(to: .zero)
        } else {
            let prevIndex = queueIndex - 1
            guard prevIndex >= 0 else { return }
            queueIndex = prevIndex
            loadAndPlay(track: queue[queueIndex])
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
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
            }
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
        
        // Asynchronously load artwork for the Control Center only once per track
        if currentArtworkTrackId != track.id {
            currentArtworkTrackId = track.id
            if let artworkUrl = track.coverArtUrl {
                URLSession.shared.dataTask(with: artworkUrl) { data, _, _ in
                    if let data = data, let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        DispatchQueue.main.async {
                            // Check if we are still playing the same track
                            if self.currentTrack?.id == track.id {
                                var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
                                updatedInfo[MPMediaItemPropertyArtwork] = artwork
                                MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                            }
                        }
                    }
                }.resume()
            }
        }
    }
    
    private func parseLRC(_ lyrics: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let lines = lyrics.components(separatedBy: .newlines)
        for line in lines {
            guard line.hasPrefix("["), let bracketEnd = line.firstIndex(of: "]") else { continue }
            let timeString = String(line[line.index(after: line.startIndex)..<bracketEnd])
            let text = String(line[line.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)
            let parts = timeString.components(separatedBy: ":")
            guard parts.count >= 2, let min = Double(parts[0]), let sec = Double(parts[1]) else { continue }
            let time = min * 60 + sec
            if !text.isEmpty {
                result.append(LyricLine(time: time, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
    
    // MARK: - Offline Downloads Management
    
    

    
    func loadDownloadedTracks() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            let ids = fileURLs
                .filter { ["mp3", "flac", "m4a"].contains($0.pathExtension.lowercased()) }
                .map { $0.deletingPathExtension().lastPathComponent }
            DispatchQueue.main.async {
                self.downloadedTrackIds = Set(ids)
                self.objectWillChange.send()
            }
        } catch {
            print("Error loading downloaded tracks: \(error)")
        }
    }
    
    func refreshDownloadedTracks() {
        loadDownloadedTracks()
    }
    
    func downloadTrack(_ track: Track) {
        print("DEBUG: downloadTrack requested for \(track.id) - \(track.title)")
        if checkFileSystemForTrack(track.id) {
            print("DEBUG: Track \(track.id) already exists on disk.")
            // Already there, but maybe the set is stale
            if !downloadedTrackIds.contains(track.id) {
                DispatchQueue.main.async {
                    self.downloadedTrackIds.insert(track.id)
                    self.objectWillChange.send()
                }
            }
            return 
        }
        
        // Add to queue if not already there or active
        if downloadProgress[track.id] != nil { 
            print("DEBUG: Track \(track.id) is already in download progress map.")
            return 
        }
        
        // Mark as queued immediately to prevent duplicate entries
        DispatchQueue.main.async {
            self.downloadProgress[track.id] = 0.0
        }
        
        print("DEBUG: Appending \(track.id) to downloadQueue. Current queue size: \(downloadQueue.count)")
        downloadQueue.append(track)
        processQueue()
    }
    
    private func processQueue() {
        print("DEBUG: processQueue() called. Active: \(activeDownloadCount)/\(maxConcurrentDownloads), Queue: \(downloadQueue.count)")
        guard activeDownloadCount < maxConcurrentDownloads, !downloadQueue.isEmpty else { return }
        
        let track = downloadQueue.removeFirst()
        activeDownloadCount += 1
        
        let streamUrl = client.getStreamUrl(id: track.id)
        
        guard let url = streamUrl else { 
            print("ERROR: Could not get stream URL for track \(track.id)")
            activeDownloadCount -= 1
            processQueue() // Try next
            return 
        }
        
        print("DEBUG: Starting download task for \(track.id) from \(url.absoluteString)")
        let task = downloadSession.downloadTask(with: url)
        downloadTasks[task.taskIdentifier] = track.id
        downloadStartTimes[track.id] = Date()
        task.resume()
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
        print("DEBUG: didFinishDownloadingTo called for task \(downloadTask.taskIdentifier)")
        
        guard let trackId = downloadTasks[downloadTask.taskIdentifier] else { 
            print("DEBUG: No trackId found for task \(downloadTask.taskIdentifier)")
            return 
        }
        
        // Use track's suffix if available, fallback to mp3
        var suffix = "mp3"
        if let track = client.allSongs.first(where: { $0.id == trackId }), let s = track.suffix {
            suffix = s.lowercased()
        } else if let track = queue.first(where: { $0.id == trackId }), let s = track.suffix {
            suffix = s.lowercased()
        }
        
        let downloadsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationUrl = downloadsDir.appendingPathComponent("\(trackId).\(suffix)")
        
        do {
            if FileManager.default.fileExists(atPath: destinationUrl.path) {
                try FileManager.default.removeItem(at: destinationUrl)
            }
            try FileManager.default.moveItem(at: location, to: destinationUrl)
            
            DispatchQueue.main.async {
                self.downloadedTrackIds.insert(trackId)
                self.downloadProgress.removeValue(forKey: trackId)
                self.downloadETAs.removeValue(forKey: trackId)
                self.downloadStartTimes.removeValue(forKey: trackId)
                self.objectWillChange.send()
            }
            print("SUCCESS: Saved track \(trackId) to \(destinationUrl.path)")
        } catch {
            print("ERROR: Failed to save track \(trackId): \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.downloadProgress.removeValue(forKey: trackId)
            }
        }
        downloadTasks.removeValue(forKey: downloadTask.taskIdentifier)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("DEBUG: didCompleteWithError called for task \(task.taskIdentifier)")
        if let error = error {
            print("ERROR: Download task \(task.taskIdentifier) failed: \(error.localizedDescription)")
            if let trackId = downloadTasks[task.taskIdentifier] {
                DispatchQueue.main.async {
                    self.failedDownloadIds.insert(trackId)
                    self.downloadProgress.removeValue(forKey: trackId)
                    self.downloadETAs.removeValue(forKey: trackId)
                }
            }
        } else {
            print("DEBUG: Download task \(task.taskIdentifier) completed without error.")
        }
        downloadTasks.removeValue(forKey: task.taskIdentifier)
        activeDownloadCount -= 1
        processQueue()
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            PlaybackManager.sharedBackgroundCompletion?()
            PlaybackManager.sharedBackgroundCompletion = nil
        }
    }
    
    func downloadAll(tracks: [Track]) {
        for track in tracks {
            downloadTrack(track)
        }
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
        
        // Prepare secondary player
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localUrl = documentsDirectory.appendingPathComponent("\(nextTrack.id).mp3")
        let urlToPlay: URL = FileManager.default.fileExists(atPath: localUrl.path) ? localUrl : (client.getStreamUrl(id: nextTrack.id) ?? URL(string: "about:blank")!)
        
        let playerItem = AVPlayerItem(url: urlToPlay)
        secondaryPlayer = AVPlayer(playerItem: playerItem)
        secondaryPlayer?.volume = 0
        secondaryPlayer?.play()
        
        // Volume transition
        let duration = crossfadeDuration
        let steps = 50
        let interval = duration / Double(steps)
        
        var step = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            guard self.isCrossfading else {
                timer.invalidate()
                return
            }
            step += 1
            let factor = Float(step) / Float(steps)
            
            DispatchQueue.main.async {
                self.player?.volume = 1.0 - factor
                self.secondaryPlayer?.volume = factor
                
                if step >= steps {
                    timer.invalidate()
                    self.completeCrossfade(nextTrack: nextTrack, nextItem: playerItem)
                }
            }
        }
    }
    
    private func completeCrossfade(nextTrack: Track, nextItem: AVPlayerItem) {
        // Scrobble previous
        if let track = self.currentTrack {
            self.client.scrobble(id: track.id, submission: true)
        }
        
        // Cleanup old player
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let itemObserver = playerItemObserver {
            NotificationCenter.default.removeObserver(itemObserver)
            playerItemObserver = nil
        }
        player?.pause()
        
        // Switch to new player
        player = secondaryPlayer
        secondaryPlayer = nil
        currentTrack = nextTrack
        queueIndex = (queueIndex + 1) % queue.count
        isCrossfading = false
        player?.volume = 1.0
        
        // Setup observers for new track
        setupObservers(for: nextItem, track: nextTrack)
        
        // Fetch new lyrics/backdrop
        fetchMetadata(for: nextTrack)
    }
    
    private func setupObservers(for item: AVPlayerItem, track: Track) {
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self,
                  let currentItem = self.player?.currentItem,
                  currentItem.duration.isNumeric else { return }
            
            self.progress = time.seconds
            self.duration = currentItem.duration.seconds
            self.updateNowPlayingInfo()
            
            if self.isCrossfadeEnabled && !self.isCrossfading && self.duration > 0 && time.seconds > (self.duration - self.crossfadeDuration) {
                self.startCrossfade()
            }
        }
        
        playerItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
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
    
    private func fetchMetadata(for track: Track) {
        client.fetchLyrics(artist: track.artist ?? "", title: track.title) { lyrics in
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
        
        if let artistId = track.artistId {
            client.fetchArtistInfo(artistId: artistId) { _, mbid in
                FanartManager.shared.fetchBackdrop(for: track.artist ?? "", mbid: mbid)
            }
        } else {
            FanartManager.shared.fetchBackdrop(for: track.artist ?? "")
        }
    }
    
}
