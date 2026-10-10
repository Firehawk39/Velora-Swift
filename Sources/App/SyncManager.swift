import SwiftUI
import Foundation

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    // Metadata Sync State
    @Published var isSyncingMetadata: Bool = false
    @Published var metadataProgress: Double = 0.0
    @Published var metadataStatus: String = UserDefaults.standard.string(forKey: "velora_last_metadata_status") ?? ""
    @Published var metadataEta: String = ""

    // Lyrics Sync State
    @Published var isSyncingLyrics: Bool = false
    @Published var lyricsProgress: Double = 0.0
    @Published var lyricsStatus: String = UserDefaults.standard.string(forKey: "velora_last_lyrics_status") ?? ""
    @Published var lyricsEta: String = ""

    // Media Sync State
    @Published var isSyncingMedia: Bool = false
    @Published var mediaProgress: Double = 0.0
    @Published var mediaStatus: String = UserDefaults.standard.string(forKey: "velora_last_media_status") ?? ""
    @Published var mediaEta: String = ""

    // Repair Sync State
    @Published var isRepairing: Bool = false
    @Published var repairProgress: Double = 0.0
    @Published var repairStatus: String = UserDefaults.standard.string(forKey: "velora_last_repair_status") ?? ""

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
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundExecution(name: String) {
        if backgroundTaskId == .invalid {
            backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.endBackgroundExecution()
            }
        }
    }

    private func endBackgroundExecution() {
        if backgroundTaskId != .invalid {
            let id = backgroundTaskId
            backgroundTaskId = .invalid
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    func configure(client: NavidromeClient, playback: PlaybackManager) {
        self.client = client
        self.playback = playback
    }

    /// Syncs Artist/Album info and images, but NO media files.
    /// Loops until every item is confirmed complete — one tap always finishes the job.
    func startMetadataSync() {
        guard let client = client, !isSyncingMetadata else { return }

        isSyncingMetadata = true
        metadataProgress = 0.0
        metadataEta = ""
        metadataStatus = "Starting metadata sync..."
        beginBackgroundExecution(name: "VeloraMetadataSync")

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

            if artists.isEmpty && albums.isEmpty {
                finalizeMetadataSync("No items found.")
                return
            }

            let fa = FanartManager.shared
            let mb = MusicBrainzManager.shared
            let activeCores = ProcessInfo.processInfo.activeProcessorCount
            let physicalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
            // Scale dynamically based on RAM and CPU cores. iPhone SE (2GB) -> ~20-30, iPad M1 (8GB) -> ~150+
            let maxConcurrent = min(200, max(25, Int(physicalMemoryGB * Double(activeCores) * 3)))
            let startTime = Date()

            // Pre-flight check: determine what's truly missing
            var initialMissingArtists = [Artist]()
            for (index, artist) in artists.enumerated() {
                let localPortraitUrl = VeloraStorage.artistPortraits.appendingPathComponent("\(artist.id).jpg")
                let hasLocalPortrait = isValidImageFile(at: localPortraitUrl) || AssetRegistry.shared.isPortraitUnavailable(artistId: artist.id)
                let hasBackdrop = fa.hasCheckedBackdrop(for: artist.primaryName, artistId: artist.id)
                let hasLogo = fa.hasCheckedClearLogo(for: artist.primaryName)
                let hasArtist = mb.hasArtistMetadata(for: artist.primaryName) || AssetRegistry.shared.isArtistUnavailable(artistName: artist.primaryName)
                if !(hasLocalPortrait && hasBackdrop && hasLogo && hasArtist) {
                    initialMissingArtists.append(artist)
                }
                if index % 100 == 0 { await Task.yield() }
            }

            var initialMissingAlbums = [Album]()
            for (index, album) in albums.enumerated() {
                let artistName = album.artist ?? "Unknown Artist"
                let albumKey = "\(artistName)_\(album.name)"
                let rawArtId = album.coverArt ?? album.id
                let cleanArtId = extractArtId(from: rawArtId)
                let localArtUrl = VeloraStorage.coverArt.appendingPathComponent("\(cleanArtId).jpg")
                let hasCover = isValidImageFile(at: localArtUrl)
                let hasMeta = mb.hasAlbumMetadata(albumName: album.name, artistName: artistName) || AssetRegistry.shared.isAlbumUnavailable(albumKey: albumKey)
                if !(hasCover && hasMeta) {
                    initialMissingAlbums.append(album)
                }
                if index % 100 == 0 { await Task.yield() }
            }

            if initialMissingArtists.isEmpty && initialMissingAlbums.isEmpty {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                finalizeMetadataSync("All metadata cached • Up to date")
                return
            }

            var missingArtists = initialMissingArtists
            var missingAlbums = initialMissingAlbums

            // Keep looping until all artists are confirmed complete (handles partial failures in one go)
            var passCount = 0
            repeat {
                passCount += 1
                metadataStatus = passCount == 1 ? "Analyzing library..." : "Retrying incomplete items (pass \(passCount))..."
                await Task.yield()

                // Reset dedup guards so artists that failed due to stuck keys can be retried
                fa.resetActiveFetches()

                // Re-scan on every pass so we only work on what's still missing
                var missingArtistsThisPass = [Artist]()
                for (index, artist) in missingArtists.enumerated() {
                    let localPortraitUrl = VeloraStorage.artistPortraits.appendingPathComponent("\(artist.id).jpg")
                    let hasLocalPortrait = isValidImageFile(at: localPortraitUrl) || AssetRegistry.shared.isPortraitUnavailable(artistId: artist.id)
                    let hasBackdrop = fa.hasCheckedBackdrop(for: artist.primaryName, artistId: artist.id)
                    let hasLogo = fa.hasCheckedClearLogo(for: artist.primaryName)
                    let hasArtist = mb.hasArtistMetadata(for: artist.primaryName) || AssetRegistry.shared.isArtistUnavailable(artistName: artist.primaryName)
                    if !(hasLocalPortrait && hasBackdrop && hasLogo && hasArtist) {
                        missingArtistsThisPass.append(artist)
                    }
                    if index % 100 == 0 { await Task.yield() }
                }

                var missingAlbumsThisPass = [Album]()
                for (index, album) in missingAlbums.enumerated() {
                    let artistName = album.artist ?? "Unknown Artist"
                    let albumKey = "\(artistName)_\(album.name)"
                    let rawArtId = album.coverArt ?? album.id
                    let cleanArtId = extractArtId(from: rawArtId)
                    let localArtUrl = VeloraStorage.coverArt.appendingPathComponent("\(cleanArtId).jpg")
                    let hasCover = isValidImageFile(at: localArtUrl)
                    let hasMeta = mb.hasAlbumMetadata(albumName: album.name, artistName: artistName) || AssetRegistry.shared.isAlbumUnavailable(albumKey: albumKey)
                    if !(hasCover && hasMeta) {
                        missingAlbumsThisPass.append(album)
                    }
                    if index % 100 == 0 { await Task.yield() }
                }

                missingArtists = missingArtistsThisPass
                missingAlbums = missingAlbumsThisPass

                let totalMissing = Double(missingArtists.count + missingAlbums.count)
                let totalAll = Double(artists.count + albums.count)
                let alreadyDone = totalAll - totalMissing

                if totalMissing == 0 { break }

                var tasksCompleted = alreadyDone

                // Phase A: Artist Metadata & Images
                var artistStartIndex = 0
                while artistStartIndex < missingArtists.count && isSyncingMetadata {
                    let endIndex = min(artistStartIndex + maxConcurrent, missingArtists.count)
                    let batch = Array(missingArtists[artistStartIndex..<endIndex])
                    metadataStatus = "Syncing Artists: \(artistStartIndex)/\(missingArtists.count) (pass \(passCount))"

                    await withTaskGroup(of: Void.self) { group in
                        for (_, artist) in batch.enumerated() {
                            group.addTask {
                                let mb = await MusicBrainzManager.shared
                                let fa = await FanartManager.shared
                                let localPortraitUrl = VeloraStorage.artistPortraits.appendingPathComponent("\(artist.id).jpg")
                                let hasLocalPortrait = FileManager.default.fileExists(atPath: localPortraitUrl.path)
                                let hasArtist = await mb.hasArtistMetadata(for: artist.primaryName)
                                let hasBackdrop = await fa.hasCheckedBackdrop(for: artist.primaryName, artistId: artist.id)
                                let hasClearLogo = await fa.hasCheckedClearLogo(for: artist.primaryName)
                                if !(hasArtist && hasBackdrop && hasClearLogo && hasLocalPortrait) {
                                    let info: SubsonicArtistInfo? = await withCheckedContinuation { continuation in
                                        Task { @MainActor in
                                            client.fetchArtistInfo(artistId: artist.id) { info in
                                                continuation.resume(returning: info)
                                            }
                                        }
                                    }
                                    // Use Navidrome's MBID for robust matching, but protect against Last.fm's "Zimmer" -> "Hans Zimmer" aliasing bug.
                                    let safeMbid = (artist.primaryName.lowercased() == "zimmer") ? nil : info?.musicBrainzId
                                    await fa.downloadBackdropSilently(for: artist.allNames, artistId: artist.id, mbid: safeMbid)
                                    await fa.downloadClearLogoSilently(for: artist.primaryName, mbid: safeMbid)
                                    
                                    let hasImage = (info?.mediumImageUrl != nil && info?.mediumImageUrl?.isEmpty == false) || (info?.largeImageUrl != nil && info?.largeImageUrl?.isEmpty == false)
                                    if !hasImage {
                                        await fa.downloadArtistPortraitSilently(for: artist.primaryName, artistId: artist.id, mbid: safeMbid)
                                    } else {
                                        await client.downloadArtistPortrait(id: artist.id)
                                    }

                                    await withCheckedContinuation { cont in
                                        Task { @MainActor in
                                            client.fetchArtist(id: artist.id) { _ in cont.resume() }
                                        }
                                    }
                                    await mb.downloadMetadataSilently(for: artist.primaryName, mbid: safeMbid)
                                }
                            }
                        }
                    }

                    tasksCompleted += Double(batch.count)
                    artistStartIndex += maxConcurrent
                    metadataProgress = min(tasksCompleted / totalAll, 0.99)
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed >= 2.0 && tasksCompleted > alreadyDone {
                        let rate = (tasksCompleted - alreadyDone) / elapsed
                        let rem = Int((totalAll - tasksCompleted) / max(rate, 0.01))
                        metadataEta = rem > 3600 ? "\(rem/3600)h remaining" : rem > 60 ? "\(rem/60)m remaining" : "\(rem)s remaining"
                    }
                }

                // Phase B: Album Metadata & Cover Art
                var albumStartIndex = 0
                while albumStartIndex < missingAlbums.count && isSyncingMetadata {
                    let endIndex = min(albumStartIndex + maxConcurrent, missingAlbums.count)
                    let batch = Array(missingAlbums[albumStartIndex..<endIndex])
                    metadataStatus = "Syncing Albums: \(albumStartIndex)/\(missingAlbums.count) (pass \(passCount))"

                    await withTaskGroup(of: Void.self) { group in
                        for (_, album) in batch.enumerated() {
                            group.addTask {
                                let artistName = album.artist ?? "Unknown Artist"
                                let mb = await MusicBrainzManager.shared
                                if !(await mb.hasAlbumMetadata(albumName: album.name, artistName: artistName)) {
                                    await mb.downloadAlbumMetadataSilently(albumName: album.name, artistName: artistName)
                                }
                                let rawArtId = album.coverArt ?? album.id
                                let cleanArtId = extractArtId(from: rawArtId)
                                let localArtUrl = VeloraStorage.coverArt.appendingPathComponent("\(cleanArtId).jpg")
                                if !isValidImageFile(at: localArtUrl) {
                                    await client.downloadCoverArt(id: cleanArtId)
                                }
                            }
                        }
                    }

                    tasksCompleted += Double(batch.count)
                    albumStartIndex += maxConcurrent
                    metadataProgress = min(tasksCompleted / totalAll, 0.99)
                }

                // Brief pause before re-scanning to allow disk writes to flush
                if isSyncingMetadata { try? await Task.sleep(nanoseconds: 2_000_000_000) }

            } while isSyncingMetadata && passCount < 5
            // Cap at 5 passes — if something still fails after that, it's a permanent API gap.

            // Register permanently unavailable items so subsequent sync taps complete in milliseconds
            for artist in missingArtists {
                let backdropKey = fa.getCacheKey(artistName: artist.primaryName, artistId: artist.id)
                if !fa.hasCheckedBackdrop(for: artist.primaryName, artistId: artist.id) {
                    AssetRegistry.shared.markBackdropUnavailable(key: backdropKey)
                }
                if !fa.hasCheckedClearLogo(for: artist.primaryName) {
                    let logoKey = "logo_" + fa.sanitizeFileName(artist.primaryName)
                    AssetRegistry.shared.markLogoUnavailable(key: logoKey)
                }
                let localPortraitUrl = VeloraStorage.artistPortraits.appendingPathComponent("\(artist.id).jpg")
                if !isValidImageFile(at: localPortraitUrl) {
                    AssetRegistry.shared.markPortraitUnavailable(artistId: artist.id)
                }
                if !mb.hasArtistMetadata(for: artist.primaryName) {
                    AssetRegistry.shared.markArtistUnavailable(artistName: artist.primaryName)
                }
            }
            for album in missingAlbums {
                let artistName = album.artist ?? "Unknown Artist"
                let albumKey = "\(artistName)_\(album.name)"
                if !mb.hasAlbumMetadata(albumName: album.name, artistName: artistName) {
                    AssetRegistry.shared.markAlbumUnavailable(albumKey: albumKey)
                }
            }

            client.saveOfflineMetadata()
            LibraryDataCache.shared.refresh()

            let skippedCount = (artists.count + albums.count)
            finalizeMetadataSync("Metadata Sync Complete — \(skippedCount) items confirmed")
        }
    }

    /// Downloads all missing lyrics from LRCLIB.
    /// Retries rate-limited songs with exponential back-off — one tap always finishes.
    func startLyricsSync() {
        guard let client = client, !isSyncingLyrics else { return }

        isSyncingLyrics = true
        lyricsProgress = 0.0
        lyricsEta = ""
        lyricsStatus = "Starting lyrics sync..."
        beginBackgroundExecution(name: "VeloraLyricsSync")

        Task {
            let tracks: [Track]
            let allTracks = await DatabaseManager.shared.getAllTracks()
            if allTracks.isEmpty {
                lyricsStatus = "Fetching song list..."
                tracks = await withCheckedContinuation { continuation in
                    client.fetchAllSongs { songs in continuation.resume(returning: songs) }
                }
            } else {
                tracks = allTracks
            }
            if tracks.isEmpty {
                finalizeLyricsSync("No tracks found in library.")
                return
            }

            let lyricsDir = VeloraStorage.lyrics
            // ThrottledNetworkManager handles the pacing and circuit breaking globally.
            // We dispatch in large batches to keep the pipeline full without overloading memory.
            let activeCores = ProcessInfo.processInfo.activeProcessorCount
            let physicalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
            let maxConcurrent = min(200, max(25, Int(physicalMemoryGB * Double(activeCores) * 3)))
            let totalTasks = Double(tracks.count)
            let startTime = Date()

            // First pass: build the list of truly missing songs
            var missingSongs = tracks.filter { song in
                let cacheFile = lyricsDir.appendingPathComponent("\(song.id).txt")
                if FileManager.default.fileExists(atPath: cacheFile.path) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.size]) as? Int64 ?? 0
                    if size > 0 { return false } // Already has lyrics or "NO_LYRICS"
                }
                return !AssetRegistry.shared.isLyricsUnavailable(trackId: song.id)
            }
            let skippedCount = tracks.count - missingSongs.count
            var tasksCompleted = Double(skippedCount)
            lyricsProgress = tasksCompleted / totalTasks

            if missingSongs.isEmpty {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                finalizeLyricsSync("All \(Int(totalTasks)) tracks have lyrics cached • Up to date")
                return
            }

            var passCount = 0
            // Retry loop: on each pass, only the songs still missing (no cache file) are attempted
            while !missingSongs.isEmpty && isSyncingLyrics && passCount < 5 {
                passCount += 1
                var failedThisPass: [Track] = []

                let attemptedSoFar = Int(tasksCompleted) - skippedCount
                lyricsStatus = passCount == 1
                    ? "Syncing Lyrics: \(attemptedSoFar)/\(missingSongs.count) songs"
                    : "Retrying \(missingSongs.count) songs (pass \(passCount))"

                // Exponential back-off between passes: 0, 5s, 10s, 20s, 40s
                if passCount > 1 {
                    let backoffSeconds = UInt64(5 * (1 << (passCount - 2)))
                    lyricsStatus = "Rate limited — waiting \(backoffSeconds)s before retry..."
                    try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                }

                // Continuous bounded task group (Worker Pool Pattern)
                // Keeps exactly `maxConcurrent` tasks in flight at all times without batch stalls.
                let results = await withTaskGroup(of: (Track, Bool).self) { group -> [(Track, Bool)] in
                    var out: [(Track, Bool)] = []
                    var enqueueIndex = 0
                    let totalToQueue = missingSongs.count

                    // 1. Seed the initial pool
                    while enqueueIndex < min(maxConcurrent, totalToQueue) && isSyncingLyrics {
                        let song = missingSongs[enqueueIndex]
                        group.addTask {
                            let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                                Task { @MainActor in
                                    client.fetchLyrics(trackId: song.id, artist: song.primaryArtist, title: song.title, duration: Double(song.duration ?? 0), priority: URLSessionTask.lowPriority) { result in
                                        continuation.resume(returning: result != nil)
                                    }
                                }
                            }
                            return (song, succeeded)
                        }
                        enqueueIndex += 1
                    }

                    // 2. As each task finishes, queue a new one immediately
                    for await pair in group {
                        out.append(pair)
                        
                        // Update progress precisely after every single track completes
                        tasksCompleted += 1.0
                        lyricsProgress = min(tasksCompleted / totalTasks, 0.99)
                        
                        let nowProcessed = tasksCompleted - Double(skippedCount)
                        if nowProcessed > 0 {
                            let elapsed = Date().timeIntervalSince(startTime)
                            if elapsed >= 2.0 {
                                let rate = nowProcessed / elapsed
                                let rem = Int(Double(totalToQueue) - nowProcessed < 0 ? 0 : (Double(totalToQueue) - nowProcessed) / max(rate, 0.01))
                                lyricsEta = rem > 3600 ? "\(rem/3600)h remaining" : rem > 60 ? "\(rem/60)m remaining" : "\(rem)s remaining"
                            }
                        }

                        // Add next task to keep pipeline full
                        if enqueueIndex < totalToQueue && isSyncingLyrics {
                            let nextSong = missingSongs[enqueueIndex]
                            group.addTask {
                                let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                                    Task { @MainActor in
                                        client.fetchLyrics(trackId: nextSong.id, artist: nextSong.primaryArtist, title: nextSong.title, duration: Double(nextSong.duration ?? 0), priority: URLSessionTask.lowPriority) { result in
                                            continuation.resume(returning: result != nil)
                                        }
                                    }
                                }
                                return (nextSong, succeeded)
                            }
                            enqueueIndex += 1
                        }
                    }
                    return out
                }

                for (song, succeeded) in results {
                    if !succeeded {
                        let cacheFile = lyricsDir.appendingPathComponent("\(song.id).txt")
                        if !FileManager.default.fileExists(atPath: cacheFile.path) {
                            failedThisPass.append(song)
                        }
                    }
                }

                // Only retry songs that truly still have no file
                missingSongs = failedThisPass
                if !missingSongs.isEmpty {
                    AppLogger.shared.log("[LyricsSync] Pass \(passCount) done. \(missingSongs.count) songs still need retry.", level: .warning)
                }
            }

            for song in missingSongs {
                let cacheFile = lyricsDir.appendingPathComponent("\(song.id).txt")
                if !FileManager.default.fileExists(atPath: cacheFile.path) {
                    try? "NO_LYRICS".write(to: cacheFile, atomically: true, encoding: .utf8)
                }
                AssetRegistry.shared.markLyricsUnavailable(trackId: song.id)
            }

            let finalFailed = missingSongs.count
            if finalFailed > 0 {
                finalizeLyricsSync("Lyrics Sync Complete — \(tracks.count - finalFailed) cached, \(finalFailed) instrumental/unlisted")
            } else {
                finalizeLyricsSync("Lyrics Sync Complete — All \(tracks.count) tracks cached")
            }
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
        beginBackgroundExecution(name: "VeloraMediaSync")

        Task {
            // Unlock maximum download concurrency for the bulk operation.
            // This is reset back to the conservative default in finalizeMediaSync.
            playback?.setBulkDownloadMode(true)
            playback?.resetDownloadState()

            // 1. Ensure we actually have the songs list
            let tracks: [Track]
            let allTracks = await DatabaseManager.shared.getAllTracks()
            if allTracks.isEmpty {
                mediaStatus = "Fetching song list..."
                tracks = await withCheckedContinuation { continuation in
                    client.fetchAllSongs { songs in
                        continuation.resume(returning: songs)
                    }
                }
            } else {
                tracks = allTracks
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
            let trackIdSet = Set(tracksToDownload.map { $0.id })
            while isSyncingMedia {
                let downloadedIds = playback?.downloadedTrackIds ?? []
                let failedIds = playback?.failedDownloadIds ?? []
                let currentlyDownloaded = downloadedIds.intersection(trackIdSet).count
                let currentlyFailed = failedIds.intersection(trackIdSet).count
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
                let downloadedIds = playback?.downloadedTrackIds ?? []
                let failedIds = playback?.failedDownloadIds ?? []
                let successCount = downloadedIds.intersection(trackIdSet).count
                let failCount = failedIds.intersection(trackIdSet).count

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
        if !isSyncing && !isRepairing { endBackgroundExecution() }
    }

    func stopLyricsSync() {
        isSyncingLyrics = false
        lyricsStatus = "Sync Stopped"
        if !isSyncing && !isRepairing { endBackgroundExecution() }
    }

    func stopMediaSync() {
        isSyncingMedia = false
        mediaStatus = "Sync Stopped"
        playback?.setBulkDownloadMode(false)
        if !isSyncing && !isRepairing { endBackgroundExecution() }
    }

    func stopSync() {
        stopMetadataSync()
        stopLyricsSync()
        stopMediaSync()
        stopRepairSync()
        endBackgroundExecution()
    }

    func stopRepairSync() {
        isRepairing = false
        repairStatus = "Repair Stopped"
        if !isSyncing && !isRepairing { endBackgroundExecution() }
    }

    // MARK: - Repair Tools

    func startRepairSync() {
        guard let client = client, !isRepairing else { return }
        isRepairing = true
        repairProgress = 0.0
        repairStatus = "Scanning library for missing assets..."
        beginBackgroundExecution(name: "VeloraRepairSync")

        Task {
            let fileManager = FileManager.default

            // Wait for client to have songs loaded
            var allTracks = await DatabaseManager.shared.getAllTracks()
            if allTracks.isEmpty {
                repairStatus = "Fetching track list..."
                allTracks = await withCheckedContinuation { continuation in
                    client.fetchAllSongs { songs in continuation.resume(returning: songs) }
                }
            }

            // Only care about tracks we actually have downloaded
            let downloadedTrackIds = IntegrityManager.shared.downloadedIds
            let localTracks = allTracks.filter { downloadedTrackIds.contains($0.id) }

            if localTracks.isEmpty {
                finalizeRepairSync("No offline tracks found. Nothing to repair.")
                return
            }

            var missingCoverArtIds: Set<String> = []
            var missingArtistPortraitIds: Set<String> = []
            var missingLyricsIds: [(id: String, artist: String, title: String, duration: Double)] = []

            repairStatus = "Auditing library integrity..."

            for (index, track) in localTracks.enumerated() {
                // 0. Verify audio file on disk
                if !(playback?.checkFileSystemForTrack(track.id) ?? false) {
                    playback?.downloadTrack(track)
                }

                // 1. Check Cover Art
                let rawArtId = track.coverArt ?? track.albumId ?? track.id.components(separatedBy: ".").first ?? track.id
                let artId = extractArtId(from: rawArtId)
                let artFile = VeloraStorage.coverArt.appendingPathComponent("\(artId).jpg")
                if !isValidImageFile(at: artFile) {
                    // Delete corrupt file if it exists so repair can overwrite it
                    try? fileManager.removeItem(at: artFile)
                    missingCoverArtIds.insert(artId)
                }

                // 2. Check Artist Portrait
                let artistId = track.artistId ?? track.primaryArtist
                let portraitFile = VeloraStorage.artistPortraits.appendingPathComponent("\(artistId).jpg")
                if !isValidImageFile(at: portraitFile) && !AssetRegistry.shared.isPortraitUnavailable(artistId: artistId) {
                    try? fileManager.removeItem(at: portraitFile)
                    missingArtistPortraitIds.insert(artistId)
                }

                // 3. Check Lyrics
                let lyricsPath = VeloraStorage.lyrics.appendingPathComponent("\(track.id).txt").path
                if fileManager.fileExists(atPath: lyricsPath) {
                    if let size = (try? fileManager.attributesOfItem(atPath: lyricsPath)[.size]) as? Int64, size == 0 {
                        try? fileManager.removeItem(atPath: lyricsPath)
                        missingLyricsIds.append((id: track.id, artist: track.primaryArtist, title: track.title, duration: Double(track.duration ?? 0)))
                    }
                } else if !AssetRegistry.shared.isLyricsUnavailable(trackId: track.id) {
                    missingLyricsIds.append((id: track.id, artist: track.primaryArtist, title: track.title, duration: Double(track.duration ?? 0)))
                }

                if index % 50 == 0 { await Task.yield() }
            }

            let totalTasks = missingCoverArtIds.count + missingArtistPortraitIds.count + missingLyricsIds.count
            if totalTasks == 0 {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                finalizeRepairSync("Library is 100% healthy. All \(localTracks.count) offline tracks verified.")
                return
            }

            var tasksCompleted = 0.0
            var repairedCount = 0

            repairStatus = "Found \(totalTasks) missing items. Repairing..."

            let repairBatchSize = 15

            // Repair Cover Arts
            if !missingCoverArtIds.isEmpty && isRepairing {
                let items = Array(missingCoverArtIds)
                var startIndex = 0
                while startIndex < items.count && isRepairing {
                    let endIndex = min(startIndex + repairBatchSize, items.count)
                    let batch = Array(items[startIndex..<endIndex])
                    await withTaskGroup(of: Void.self) { group in
                        for (index, id) in batch.enumerated() {
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
                    tasksCompleted += Double(batch.count)
                    repairedCount += batch.count
                    repairProgress = tasksCompleted / Double(totalTasks)
                    startIndex += repairBatchSize
                }
            }

            // Repair Artist Portraits
            if !missingArtistPortraitIds.isEmpty && isRepairing {
                let items = Array(missingArtistPortraitIds)
                var startIndex = 0
                while startIndex < items.count && isRepairing {
                    let endIndex = min(startIndex + repairBatchSize, items.count)
                    let batch = Array(items[startIndex..<endIndex])
                    await withTaskGroup(of: Void.self) { group in
                        for (index, id) in batch.enumerated() {
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
                    tasksCompleted += Double(batch.count)
                    repairedCount += batch.count
                    repairProgress = tasksCompleted / Double(totalTasks)
                    startIndex += repairBatchSize
                }
            }

            // Repair Lyrics — with retry and accurate success/failure counts
            if !missingLyricsIds.isEmpty && isRepairing {
                var pendingLyrics = missingLyricsIds
                var lyricPassCount = 0
                var lyricsFixed = 0
                var lyricsFailed = 0

                // Safer concurrency: 5 at a time with 300ms stagger prevents 429 rate limits
                let lyricsBatchSize = 5
                let lyricsStaggerNs: UInt64 = 300_000_000

                while !pendingLyrics.isEmpty && isRepairing && lyricPassCount < 5 {
                    lyricPassCount += 1
                    var stillFailing: [(id: String, artist: String, title: String, duration: Double)] = []

                    if lyricPassCount > 1 {
                        let backoffSeconds = UInt64(5 * (1 << (lyricPassCount - 2)))
                        repairStatus = "Rate limited — waiting \(backoffSeconds)s before retry (pass \(lyricPassCount))..."
                        AppLogger.shared.log("[RepairSync] Lyrics rate limited. Waiting \(backoffSeconds)s before pass \(lyricPassCount).", level: .warning)
                        try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                    }

                    var startIndex = 0
                    while startIndex < pendingLyrics.count && isRepairing {
                        let endIndex = min(startIndex + lyricsBatchSize, pendingLyrics.count)
                        let batch = Array(pendingLyrics[startIndex..<endIndex])
                        repairStatus = "Repairing lyrics: \(lyricsFixed)/\(missingLyricsIds.count) fixed" + (lyricPassCount > 1 ? " (pass \(lyricPassCount))" : "")

                        let results = await withTaskGroup(of: (String, Bool).self) { group -> [(String, Bool)] in
                            for (index, req) in batch.enumerated() {
                                group.addTask {
                                    try? await Task.sleep(nanoseconds: UInt64(index) * lyricsStaggerNs)
                                    let succeeded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                                        Task { @MainActor in
                                            client.fetchLyrics(trackId: req.id, artist: req.artist, title: req.title, duration: req.duration, priority: URLSessionTask.lowPriority) { result in
                                                cont.resume(returning: result != nil)
                                            }
                                        }
                                    }
                                    return (req.id, succeeded)
                                }
                            }
                            var out: [(String, Bool)] = []
                            for await pair in group { out.append(pair) }
                            return out
                        }

                        for (id, succeeded) in results {
                            if succeeded {
                                lyricsFixed += 1
                                repairedCount += 1
                            } else {
                                // Only re-queue if still no file on disk (true failure, not NO_LYRICS)
                                let cacheFile = VeloraStorage.lyrics.appendingPathComponent("\(id).txt")
                                if !FileManager.default.fileExists(atPath: cacheFile.path),
                                   let req = pendingLyrics.first(where: { $0.id == id }) {
                                    stillFailing.append(req)
                                }
                            }
                        }

                        tasksCompleted += Double(batch.count)
                        repairProgress = tasksCompleted / Double(totalTasks)
                        startIndex += lyricsBatchSize
                    }

                    pendingLyrics = stillFailing
                }

                lyricsFailed = pendingLyrics.count
                if lyricsFailed > 0 {
                    AppLogger.shared.log("[RepairSync] \(lyricsFailed) songs unavailable after all retries (likely not in LRCLIB).", level: .warning)
                    for req in pendingLyrics {
                        let cacheFile = VeloraStorage.lyrics.appendingPathComponent("\(req.id).txt")
                        if !FileManager.default.fileExists(atPath: cacheFile.path) {
                            try? "NO_LYRICS".write(to: cacheFile, atomically: true, encoding: .utf8)
                        }
                        AssetRegistry.shared.markLyricsUnavailable(trackId: req.id)
                    }
                }
            }

            // If any portraits still failed after repair, record in AssetRegistry
            for id in missingArtistPortraitIds {
                let portraitFile = VeloraStorage.artistPortraits.appendingPathComponent("\(id).jpg")
                if !isValidImageFile(at: portraitFile) {
                    AssetRegistry.shared.markPortraitUnavailable(artistId: id)
                }
            }

            let failedNote = (lyricsFailed > 0) ? ", \(lyricsFailed) unlisted" : ""
            finalizeRepairSync("Repair complete. Fixed \(repairedCount) items\(failedNote).")
        }
    }

    private func finalizeRepairSync(_ status: String) {
        self.isRepairing = false
        self.repairStatus = status
        self.repairProgress = 1.0
        self.client?.saveOfflineMetadata()
        LibraryDataCache.shared.refresh()
        UserDefaults.standard.set(status, forKey: "velora_last_repair_status")
        if !isSyncing { endBackgroundExecution() }
    }

    private func finalizeMetadataSync(_ status: String) {
        self.isSyncingMetadata = false
        self.metadataStatus = status
        self.metadataProgress = 1.0
        self.metadataEta = ""
        self.client?.saveOfflineMetadata()
        LibraryDataCache.shared.refresh()
        UserDefaults.standard.set(status, forKey: "velora_last_metadata_status")
        if !isSyncing && !isRepairing { endBackgroundExecution() }
    }

    private func finalizeLyricsSync(_ status: String) {
        self.isSyncingLyrics = false
        self.lyricsStatus = status
        self.lyricsProgress = 1.0
        self.lyricsEta = ""
        LibraryDataCache.shared.refresh()
        UserDefaults.standard.set(status, forKey: "velora_last_lyrics_status")
        if !isSyncing && !isRepairing { endBackgroundExecution() }
    }

    private func finalizeMediaSync(_ status: String) {
        self.isSyncingMedia = false
        self.mediaStatus = status
        self.mediaProgress = 1.0
        self.mediaEta = ""
        self.playback?.setBulkDownloadMode(false)   // restore normal concurrency
        self.playback?.refreshDownloadedTracks()
        self.client?.saveOfflineMetadata()
        LibraryDataCache.shared.refresh()
        UserDefaults.standard.set(status, forKey: "velora_last_media_status")
        if !isSyncing && !isRepairing { endBackgroundExecution() }
    }

    /// Returns true only if a file exists AND is large enough to be a real image.
    /// A minimum of 100 bytes filters out the old "NA" poison markers (2 bytes)
    /// that previous versions wrote on download failure.
    private func isValidImageFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 100
    }
}
