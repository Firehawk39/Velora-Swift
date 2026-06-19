import SwiftUI
import Foundation

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    // Metadata Sync State
    @Published var isSyncingMetadata: Bool = false
    @Published var metadataProgress: Double = 0.0
    @Published var metadataStatus: String = ""
    @Published var metadataEta: String = ""
    
    // Lyrics Sync State
    @Published var isSyncingLyrics: Bool = false
    @Published var lyricsProgress: Double = 0.0
    @Published var lyricsStatus: String = ""
    @Published var lyricsEta: String = ""
    
    // Media Sync State
    @Published var isSyncingMedia: Bool = false
    @Published var mediaProgress: Double = 0.0
    @Published var mediaStatus: String = ""
    @Published var mediaEta: String = ""
    
    // Repair Sync State
    @Published var isRepairing: Bool = false
    @Published var repairProgress: Double = 0.0
    @Published var repairStatus: String = ""
    
    enum SyncType {
        case none
        case metadata
        case media
        case lyrics
        case full
    }
    
    // Legacy support for backward compatibility:
    var isSyncing: Bool {
        isSyncingMetadata || isSyncingLyrics || isSyncingMedia
    }
    
    var syncProgress: Double {
        if isSyncingMedia { return mediaProgress }
        if isSyncingLyrics { return lyricsProgress }
        if isSyncingMetadata { return metadataProgress }
        return 0.0
    }
    
    var currentStatus: String {
        if isSyncingMedia { return mediaStatus }
        if isSyncingLyrics { return lyricsStatus }
        if isSyncingMetadata { return metadataStatus }
        return ""
    }
    
    var syncType: SyncType {
        if isSyncingMedia { return .media }
        if isSyncingLyrics { return .lyrics }
        if isSyncingMetadata { return .metadata }
        return .none
    }
    
    var etaString: String {
        if isSyncingMedia { return mediaEta }
        if isSyncingLyrics { return lyricsEta }
        if isSyncingMetadata { return metadataEta }
        return ""
    }
    
    private var client: NavidromeClient?
    private var playback: PlaybackManager?
    
    func configure(client: NavidromeClient, playback: PlaybackManager) {
        self.client = client
        self.playback = playback
    }
    
    /// Syncs Artist/Album info and images, but NO media files
    func startMetadataSync() {
        guard let client = client, !isSyncingMetadata else { return }
        
        isSyncingMetadata = true
        metadataProgress = 0.0
        metadataEta = ""
        
        Task {
            // 1. Ensure artists are loaded
            if client.artists.isEmpty {
                metadataStatus = "Fetching artist list..."
                client.fetchArtists()
                for _ in 0..<30 {
                    if !client.artists.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            
            // 2. Ensure albums are loaded
            if client.albums.isEmpty {
                metadataStatus = "Fetching album list..."
                client.fetchAlbums()
                for _ in 0..<30 {
                    if !client.albums.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            
            let artists = client.artists
            let albums = client.albums
            let songs = client.allSongs
            
            if artists.isEmpty && albums.isEmpty && songs.isEmpty {
                finalizeMetadataSync("No items found.")
                return
            }
            
            metadataStatus = "Analyzing library..."
            await Task.yield()
            
            var missingArtists = [Artist]()
            let fa = FanartManager.shared
            let mb = MusicBrainzManager.shared
            
            for (index, artist) in artists.enumerated() {
                let localPortraitUrl = VeloraStorage.coverArt.appendingPathComponent("\(artist.id).jpg")
                let hasLocalPortrait = FileManager.default.fileExists(atPath: localPortraitUrl.path)
                let hasArtist = mb.hasArtistMetadata(for: artist.primaryName)
                let hasBackdrop = fa.hasBackdrop(for: artist.primaryName)
                
                if hasLocalPortrait && hasArtist && hasBackdrop {
                    // skipped
                } else {
                    missingArtists.append(artist)
                }
                if index % 100 == 0 { await Task.yield() }
            }
            
            var missingAlbums = [Album]()
            for (index, album) in albums.enumerated() {
                let artistName = album.artist ?? "Unknown Artist"
                if mb.hasAlbumMetadata(albumName: album.name, artistName: artistName) {
                    // skipped
                } else {
                    missingAlbums.append(album)
                }
                if index % 100 == 0 { await Task.yield() }
            }
            
            let skippedCount = (artists.count - missingArtists.count) + (albums.count - missingAlbums.count)
            let totalTasks = Double(missingArtists.count + missingAlbums.count)
            var tasksCompleted = 0.0
            
            if totalTasks == 0 {
                finalizeMetadataSync("All metadata already synced.")
                return
            }
            
            // Phase 1: Artist Metadata & Images
            let maxConcurrentMetadata = 8
            var artistStartIndex = 0
            let startTime = Date()
            
            while artistStartIndex < missingArtists.count && isSyncingMetadata {
                let endIndex = min(artistStartIndex + maxConcurrentMetadata, missingArtists.count)
                let batch = Array(missingArtists[artistStartIndex..<endIndex])
                
                let processed = tasksCompleted
                metadataStatus = "Syncing Artists: \(Int(processed))/\(Int(totalTasks))"
                
                await withTaskGroup(of: Void.self) { group in
                    for (index, artist) in batch.enumerated() {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(index) * 250_000_000)
                            
                            let mb = await MusicBrainzManager.shared
                            let fa = await FanartManager.shared
                            
                            let localPortraitUrl = VeloraStorage.coverArt.appendingPathComponent("\(artist.id).jpg")
                            let hasLocalPortrait = FileManager.default.fileExists(atPath: localPortraitUrl.path)
                            
                            let hasArtist = await mb.hasArtistMetadata(for: artist.primaryName)
                            let hasBackdrop = await fa.hasBackdrop(for: artist.primaryName)
                            let hasAll = hasArtist && hasBackdrop && hasLocalPortrait
                            
                            if !hasAll {
                                let mbid: String? = await withCheckedContinuation { continuation in
                                    Task { @MainActor in
                                        client.fetchArtistInfo(artistId: artist.id) { _, fetchedMbid in
                                            continuation.resume(returning: fetchedMbid)
                                        }
                                    }
                                }
                                await fa.downloadBackdropSilently(for: artist.allNames, mbid: mbid)
                                await client.downloadCoverArt(id: artist.id)
                                await mb.downloadMetadataSilently(for: artist.primaryName, mbid: mbid)
                            }
                        }
                    }
                }
                
                tasksCompleted += Double(batch.count)
                artistStartIndex += maxConcurrentMetadata
                metadataProgress = tasksCompleted / totalTasks
                
                // ETA — wait at least 2s before showing
                if tasksCompleted > 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed >= 2.0 {
                        let tracksPerSecond = tasksCompleted / elapsed
                        let remaining = totalTasks - tasksCompleted
                        let remainingSeconds = Int(remaining / max(tracksPerSecond, 0.01))
                        if remainingSeconds > 3600 {
                            self.metadataEta = "\(remainingSeconds / 3600)h remaining"
                        } else if remainingSeconds > 60 {
                            self.metadataEta = "\(remainingSeconds / 60)m remaining"
                        } else {
                            self.metadataEta = "\(remainingSeconds)s remaining"
                        }
                    }
                }
            }
            
            // Phase 2: Album Metadata
            var albumStartIndex = 0
            while albumStartIndex < missingAlbums.count && isSyncingMetadata {
                let endIndex = min(albumStartIndex + maxConcurrentMetadata, missingAlbums.count)
                let batch = Array(missingAlbums[albumStartIndex..<endIndex])
                
                let processed = tasksCompleted
                metadataStatus = "Syncing Albums: \(Int(processed))/\(Int(totalTasks))"
                
                await withTaskGroup(of: Void.self) { group in
                    for (index, album) in batch.enumerated() {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(index) * 250_000_000)
                            
                            let artistName = album.artist ?? "Unknown Artist"
                            let mb = await MusicBrainzManager.shared
                            
                            let hasMeta = await mb.hasAlbumMetadata(albumName: album.name, artistName: artistName)
                            
                            if !hasMeta {
                                await mb.downloadAlbumMetadataSilently(albumName: album.name, artistName: artistName)
                            }
                        }
                    }
                }
                
                tasksCompleted += Double(batch.count)
                albumStartIndex += maxConcurrentMetadata
                metadataProgress = tasksCompleted / totalTasks
                
                // ETA — wait at least 2s before showing
                if tasksCompleted > 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed >= 2.0 {
                        let tracksPerSecond = tasksCompleted / elapsed
                        let remaining = totalTasks - tasksCompleted
                        let remainingSeconds = Int(remaining / max(tracksPerSecond, 0.01))
                        if remainingSeconds > 3600 {
                            self.metadataEta = "\(remainingSeconds / 3600)h remaining"
                        } else if remainingSeconds > 60 {
                            self.metadataEta = "\(remainingSeconds / 60)m remaining"
                        } else {
                            self.metadataEta = "\(remainingSeconds)s remaining"
                        }
                    }
                }
            }
            
            finalizeMetadataSync("Metadata Sync Complete (\(skippedCount) items skipped)")
        }
    }
    
    /// Downloads all missing lyrics from LRCLIB
    func startLyricsSync() {
        guard let client = client, !isSyncingLyrics else { return }
        
        isSyncingLyrics = true
        lyricsProgress = 0.0
        lyricsEta = ""
        
        Task {
            // 1. Ensure we actually have the songs list
            let tracks: [Track]
            if client.allSongs.isEmpty {
                lyricsStatus = "Fetching song list..."
                tracks = await withCheckedContinuation { continuation in
                    client.fetchAllSongs { songs in
                        continuation.resume(returning: songs)
                    }
                }
            } else {
                tracks = client.allSongs
            }
            if tracks.isEmpty {
                finalizeLyricsSync("No tracks found in library.")
                return
            }

            let lyricsDir = VeloraStorage.lyrics
            let maxConcurrentLyricsRequests = 15
            var skippedCount = 0
            var tasksCompleted = 0.0
            let totalTasks = Double(tracks.count)
            
            // Filter out songs that already have local cached lyrics first so we skip them instantly
            let missingSongs = tracks.filter { song in
                let cacheFile = lyricsDir.appendingPathComponent("\(song.id).txt")
                if FileManager.default.fileExists(atPath: cacheFile.path) {
                    skippedCount += 1
                    tasksCompleted += 1
                    return false
                }
                return true
            }
            
            lyricsProgress = tasksCompleted / totalTasks
            
            if missingSongs.isEmpty {
                finalizeLyricsSync("All \(Int(totalTasks)) tracks already have lyrics.")
                return
            }
            
            if !missingSongs.isEmpty {
                var startIndex = 0
                let startTime = Date()

                while startIndex < missingSongs.count && isSyncingLyrics {
                    let endIndex = min(startIndex + maxConcurrentLyricsRequests, missingSongs.count)
                    let batch = Array(missingSongs[startIndex..<endIndex])
                    
                    let processed = tasksCompleted - Double(skippedCount)
                    lyricsStatus = "Syncing Lyrics: \(Int(processed))/\(missingSongs.count) songs"
                    
                    // Download this batch in parallel with a slight stagger
                    await withTaskGroup(of: Void.self) { group in
                        for (index, song) in batch.enumerated() {
                            group.addTask {
                                // 100ms stagger between concurrent lyric requests
                                try? await Task.sleep(nanoseconds: UInt64(index) * 100_000_000)
                                await withCheckedContinuation { continuation in
                                    Task { @MainActor in
                                        client.fetchLyrics(trackId: song.id, artist: song.primaryArtist, title: song.title, duration: Double(song.duration ?? 0)) { _ in
                                            continuation.resume()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // Update progress on the MainActor for the entire batch
                    tasksCompleted += Double(batch.count)
                    lyricsProgress = tasksCompleted / totalTasks

                    // ETA Calculation — wait at least 2s before showing (avoids ∞ on first batch)
                    let nowProcessed = tasksCompleted - Double(skippedCount)
                    if nowProcessed > 0 {
                        let elapsed = Date().timeIntervalSince(startTime)
                        if elapsed >= 2.0 {
                            let tracksPerSecond = nowProcessed / elapsed
                            let remainingTracks = Double(missingSongs.count) - nowProcessed
                            let remainingSeconds = Int(remainingTracks / max(tracksPerSecond, 0.01))
                            
                            if remainingSeconds > 3600 {
                                self.lyricsEta = "\(remainingSeconds / 3600)h remaining"
                            } else if remainingSeconds > 60 {
                                self.lyricsEta = "\(remainingSeconds / 60)m remaining"
                            } else {
                                self.lyricsEta = "\(remainingSeconds)s remaining"
                            }
                        }
                    }
                    
                    startIndex += maxConcurrentLyricsRequests
                }
            }
            
            finalizeLyricsSync("Lyrics Sync Complete (\(skippedCount) items skipped)")
        }
    }
    
    /// Downloads all tracks in the library
    func startMediaSync() {
        AppLogger.shared.log("startMediaSync() triggered. isSyncingMedia: \(isSyncingMedia), client: \(client != nil ? "present" : "nil")", level: .info)
        guard let client = client, !isSyncingMedia else { 
            AppLogger.shared.log("startMediaSync() aborted: guard failed.", level: .error)
            return 
        }
        
        isSyncingMedia = true
        mediaProgress = 0.0
        mediaStatus = "Analyzing library..."
        mediaEta = ""
        
        Task {
            playback?.resetDownloadState()
            
            // 1. Ensure we actually have the songs list
            let tracks: [Track]
            if client.allSongs.isEmpty {
                mediaStatus = "Fetching song list..."
                tracks = await withCheckedContinuation { continuation in
                    client.fetchAllSongs { songs in
                        continuation.resume(returning: songs)
                    }
                }
            } else {
                tracks = client.allSongs
            }
            if tracks.isEmpty {
                AppLogger.shared.log("Songs list still empty after polling. Aborting.", level: .error)
                finalizeMediaSync("No tracks found in library.")
                return
            }
            
            AppLogger.shared.log("Total tracks in library: \(tracks.count). Checking which need download.", level: .debug)
            
            var tracksToDownload: [Track] = []
            for (index, track) in tracks.enumerated() {
                if !(playback?.checkFileSystemForTrack(track.id) ?? false) {
                    tracksToDownload.append(track)
                }
                // Yield the main thread every 100 tracks to keep the UI perfectly responsive
                if index % 100 == 0 { await Task.yield() }
            }
            
            let totalTracks = Double(tracks.count)
            let totalToDownload = tracksToDownload.count
            let alreadyDownloadedCount = Int(totalTracks) - totalToDownload
            
            if totalToDownload == 0 {
                finalizeMediaSync("All \(Int(totalTracks)) tracks already offline.")
                return
            }
            
            mediaStatus = "Queueing \(totalToDownload) tracks..."
            AppLogger.shared.log("Queueing \(totalToDownload) tracks.", level: .info)
            for track in tracksToDownload {
                if !isSyncingMedia { break }
                playback?.downloadTrack(track)
                // Small yield to keep UI responsive during mass queueing
                await Task.yield()
            }
            AppLogger.shared.log("Finished queueing. Starting monitor loop.", level: .debug)
            
            // Phase 2: Monitor progress with a timeout safety
            var lastDownloadedCount = -1
            var stallCounter = 0
            
            let startTime = Date()
            while isSyncingMedia {
                let currentlyDownloaded = tracksToDownload.filter { playback?.isDownloaded($0.id) ?? false }.count
                let currentlyFailed = tracksToDownload.filter { playback?.failedDownloadIds.contains($0.id) ?? false }.count
                let totalCompleted = Double(alreadyDownloadedCount + currentlyDownloaded + currentlyFailed)
                
                if currentlyDownloaded + currentlyFailed == 0 {
                    AppLogger.shared.log("Sync loop heartbeat: 0/\(totalToDownload) processed. isSyncingMedia: \(isSyncingMedia)", level: .debug)
                }
                
                mediaProgress = totalCompleted / totalTracks
                mediaStatus = "Downloading: \(currentlyDownloaded)/\(totalToDownload) (\(alreadyDownloadedCount) skipped, \(currentlyFailed) failed)"
                
                // ETA Calculation
                let processedInThisBatch = currentlyDownloaded + currentlyFailed
                if processedInThisBatch > 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let tracksPerSecond = Double(processedInThisBatch) / elapsed
                    let remainingTracks = Double(totalToDownload - processedInThisBatch)
                    let remainingSeconds = Int(remainingTracks / tracksPerSecond)
                    
                    if remainingSeconds > 3600 {
                        self.mediaEta = "\(remainingSeconds / 3600)h remaining"
                    } else if remainingSeconds > 60 {
                        self.mediaEta = "\(remainingSeconds / 60)m remaining"
                    } else {
                        self.mediaEta = "\(remainingSeconds)s remaining"
                    }
                } else {
                    self.mediaEta = "Calculating..."
                }

                if (currentlyDownloaded + currentlyFailed) >= totalToDownload {
                    break
                }
                
                if (currentlyDownloaded + currentlyFailed) == lastDownloadedCount {
                    stallCounter += 1
                    if stallCounter > 300 { // 5 minutes stall
                        finalizeMediaSync("Sync Stalled. Check your connection.")
                        return
                    }
                } else {
                    stallCounter = 0
                    lastDownloadedCount = currentlyDownloaded + currentlyFailed
                }
                
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
            if isSyncingMedia {
                let successCount = tracksToDownload.filter { playback?.isDownloaded($0.id) ?? false }.count
                let failCount = tracksToDownload.filter { playback?.failedDownloadIds.contains($0.id) ?? false }.count
                
                if failCount > 0 {
                    finalizeMediaSync("Sync Finished with \(failCount) errors. (\(successCount) saved)")
                } else {
                    finalizeMediaSync("Media Sync Complete (\(alreadyDownloadedCount) skipped, \(successCount) downloaded)")
                }
            }
        }
    }
    
    func stopMetadataSync() {
        isSyncingMetadata = false
        metadataStatus = "Sync Stopped"
    }
    
    func stopLyricsSync() {
        isSyncingLyrics = false
        lyricsStatus = "Sync Stopped"
    }
    
    func stopMediaSync() {
        isSyncingMedia = false
        mediaStatus = "Sync Stopped"
    }
    
    func stopSync() {
        stopMetadataSync()
        stopLyricsSync()
        stopMediaSync()
        stopRepairSync()
    }
    
    func stopRepairSync() {
        isRepairing = false
        repairStatus = "Repair Stopped"
    }
    
    // MARK: - Repair Tools
    
    func startRepairSync() {
        guard let client = client, !isRepairing else { return }
        isRepairing = true
        repairProgress = 0.0
        repairStatus = "Scanning library for missing assets..."
        
        Task {
            let fileManager = FileManager.default
            
            // Wait for client to have songs loaded
            if client.allSongs.isEmpty {
                repairStatus = "Fetching track list..."
                await withCheckedContinuation { continuation in
                    client.fetchAllSongs { _ in continuation.resume() }
                }
            }
            
            // Only care about tracks we actually have downloaded
            let downloadedTrackIds = IntegrityManager.shared.downloadedIds
            let localTracks = client.allSongs.filter { downloadedTrackIds.contains($0.id) }
            
            if localTracks.isEmpty {
                finalizeRepairSync("No offline tracks found. Nothing to repair.")
                return
            }
            
            var missingCoverArtIds: Set<String> = []
            var missingArtistPortraitIds: Set<String> = []
            var missingLyricsIds: [(id: String, artist: String, title: String, duration: Double)] = []
            
            repairStatus = "Scanning \(localTracks.count) local tracks..."
            
            for (index, track) in localTracks.enumerated() {
                // 1. Check Cover Art
                let rawArtId = track.coverArt ?? track.albumId ?? track.id.components(separatedBy: ".").first ?? track.id
                let artId = extractArtId(from: rawArtId)
                let artPath = VeloraStorage.coverArt.appendingPathComponent("\(artId).jpg").path
                if fileManager.fileExists(atPath: artPath) {
                    if let size = (try? fileManager.attributesOfItem(atPath: artPath)[.size]) as? Int64, size == 0 {
                        try? fileManager.removeItem(atPath: artPath)
                        missingCoverArtIds.insert(artId)
                    }
                } else {
                    missingCoverArtIds.insert(artId)
                }
                
                // 2. Check Artist Portrait
                let artistId = track.artistId ?? track.primaryArtist
                let portraitPath = VeloraStorage.artistPortraits.appendingPathComponent("\(artistId).jpg").path
                if fileManager.fileExists(atPath: portraitPath) {
                    if let size = (try? fileManager.attributesOfItem(atPath: portraitPath)[.size]) as? Int64, size == 0 {
                        try? fileManager.removeItem(atPath: portraitPath)
                        missingArtistPortraitIds.insert(artistId)
                    }
                } else {
                    missingArtistPortraitIds.insert(artistId)
                }
                
                // 3. Check Lyrics
                let lyricsPath = VeloraStorage.lyrics.appendingPathComponent("\(track.id).json").path
                if fileManager.fileExists(atPath: lyricsPath) {
                    if let size = (try? fileManager.attributesOfItem(atPath: lyricsPath)[.size]) as? Int64, size == 0 {
                        try? fileManager.removeItem(atPath: lyricsPath)
                        missingLyricsIds.append((id: track.id, artist: track.primaryArtist, title: track.title, duration: Double(track.duration ?? 0)))
                    }
                } else {
                    missingLyricsIds.append((id: track.id, artist: track.primaryArtist, title: track.title, duration: Double(track.duration ?? 0)))
                }
                
                if index % 50 == 0 { await Task.yield() }
            }
            
            let totalTasks = missingCoverArtIds.count + missingArtistPortraitIds.count + missingLyricsIds.count
            if totalTasks == 0 {
                finalizeRepairSync("Library is perfectly healthy. No repairs needed.")
                return
            }
            
            var tasksCompleted = 0.0
            var repairedCount = 0
            
            repairStatus = "Found \(totalTasks) missing items. Repairing..."
            
            // Repair Cover Arts
            if !missingCoverArtIds.isEmpty && isRepairing {
                await withTaskGroup(of: Void.self) { group in
                    for (index, id) in Array(missingCoverArtIds).enumerated() {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(index) * 100_000_000)
                            await withCheckedContinuation { cont in
                                Task { @MainActor in
                                    client.fetchCoverArt(id: id, size: 500) { _ in cont.resume() }
                                }
                            }
                        }
                    }
                }
                tasksCompleted += Double(missingCoverArtIds.count)
                repairedCount += missingCoverArtIds.count
                repairProgress = tasksCompleted / Double(totalTasks)
            }
            
            // Repair Artist Portraits
            if !missingArtistPortraitIds.isEmpty && isRepairing {
                await withTaskGroup(of: Void.self) { group in
                    for (index, id) in Array(missingArtistPortraitIds).enumerated() {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(index) * 100_000_000)
                            await withCheckedContinuation { cont in
                                Task { @MainActor in
                                    client.fetchArtist(id: id) { _ in cont.resume() }
                                }
                            }
                        }
                    }
                }
                tasksCompleted += Double(missingArtistPortraitIds.count)
                repairedCount += missingArtistPortraitIds.count
                repairProgress = tasksCompleted / Double(totalTasks)
            }
            
            // Repair Lyrics
            if !missingLyricsIds.isEmpty && isRepairing {
                await withTaskGroup(of: Void.self) { group in
                    for (index, lyricReq) in missingLyricsIds.enumerated() {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(index) * 100_000_000)
                            await withCheckedContinuation { cont in
                                Task { @MainActor in
                                    client.fetchLyrics(trackId: lyricReq.id, artist: lyricReq.artist, title: lyricReq.title, duration: lyricReq.duration) { _ in cont.resume() }
                                }
                            }
                        }
                    }
                }
                tasksCompleted += Double(missingLyricsIds.count)
                repairedCount += missingLyricsIds.count
                repairProgress = tasksCompleted / Double(totalTasks)
            }
            
            finalizeRepairSync("Repair complete. Fixed \(repairedCount) items.")
        }
    }
    
    private func finalizeRepairSync(_ status: String) {
        self.isRepairing = false
        self.repairStatus = status
        self.repairProgress = 1.0
    }
    
    private func finalizeMetadataSync(_ status: String) {
        self.isSyncingMetadata = false
        self.metadataStatus = status
        self.metadataProgress = 1.0
        self.metadataEta = ""
    }
    
    private func finalizeLyricsSync(_ status: String) {
        self.isSyncingLyrics = false
        self.lyricsStatus = status
        self.lyricsProgress = 1.0
        self.lyricsEta = ""
    }
    
    private func finalizeMediaSync(_ status: String) {
        self.isSyncingMedia = false
        self.mediaStatus = status
        self.mediaProgress = 1.0
        self.mediaEta = ""
        self.playback?.refreshDownloadedTracks()
    }
}
