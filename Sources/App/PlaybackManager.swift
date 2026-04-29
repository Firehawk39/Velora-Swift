import Foundation
import AVFoundation
import MediaPlayer

class PlaybackManager: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var currentLyrics: String? = nil
    @Published var isLyricsMode: Bool = false
    
    // Queue support
    @Published var queue: [Track] = []
    @Published var queueIndex: Int = 0
    @Published var isShuffle: Bool = false
    @Published var downloadedTrackIds: Set<String> = []
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    var client: NavidromeClient
    
    init(client: NavidromeClient) {
        self.client = client
        configureAudioSession()
        setupRemoteCommandCenter() // Activate steering wheel and lock screen controls
        loadDownloadedTracks()
    }
    
    // MARK: - Audio Session
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
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
        
        let playerItem = AVPlayerItem(url: urlToPlay)
        self.player = AVPlayer(playerItem: playerItem)
        self.currentTrack = track
        self.progress = 0
        self.duration = 0
        self.currentLyrics = nil
        
        // Fetch lyrics
        client.fetchLyrics(artist: track.artist ?? "", title: track.title) { lyrics in
            DispatchQueue.main.async {
                if self.currentTrack?.id == track.id {
                    self.currentLyrics = lyrics
                }
            }
        }
        
        // Fetch Backdrop (Fanart/Discogs)
        FanartManager.shared.fetchBackdrop(for: track.artist ?? "")
        
        player?.play()
        self.isPlaying = true
        
        // Track progress
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self,
                  let item = self.player?.currentItem,
                  item.duration.isNumeric else { return }
            
            self.progress = time.seconds
            self.duration = item.duration.seconds
            self.updateNowPlayingInfo()
        }
        
        // Auto-advance to next track when done
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            if let track = self?.currentTrack {
                self?.client.scrobble(id: track.id, submission: true)
            }
            self?.skipForward()
        }
        
        // Mark as "Now Playing" on server
        client.scrobble(id: track.id, submission: false)
        
        updateNowPlayingInfo()
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
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artist ?? ""
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = track.album ?? ""
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // Asynchronously load artwork for the Control Center
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
    
    // MARK: - Offline Downloads Management
    
    func isTrackDownloaded(_ trackId: String) -> Bool {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileUrl = documentsDirectory.appendingPathComponent("\(trackId).mp3")
        return FileManager.default.fileExists(atPath: fileUrl.path)
    }
    
    func loadDownloadedTracks() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            let ids = fileURLs
                .filter { $0.pathExtension == "mp3" }
                .map { $0.deletingPathExtension().lastPathComponent }
            DispatchQueue.main.async {
                self.downloadedTrackIds = Set(ids)
            }
        } catch {
            print("Error loading downloaded tracks: \(error)")
        }
    }
    
    func downloadTrack(_ track: Track) {
        guard let url = client.getStreamUrl(id: track.id) else { return }
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationUrl = documentsDirectory.appendingPathComponent("\(track.id).mp3")
        
        if FileManager.default.fileExists(atPath: destinationUrl.path) {
            print("Track already downloaded.")
            return
        }
        
        URLSession.shared.downloadTask(with: url) { tempLocalUrl, response, error in
            guard let tempLocalUrl = tempLocalUrl, error == nil else {
                print("Download error: \(String(describing: error))")
                return
            }
            
            do {
                // Create directory if missing
                try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true, attributes: nil)
                // Copy item
                try FileManager.default.copyItem(at: tempLocalUrl, to: destinationUrl)
                DispatchQueue.main.async {
                    self.downloadedTrackIds.insert(track.id)
                }
                print("Downloaded track: \(track.title) successfully.")
            } catch {
                print("Error saving downloaded file: \(error)")
            }
        }.resume()
    }
    
    }
}
