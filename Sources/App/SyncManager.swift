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

    /// Syncs Artist/Album info and images, but NO media files.
    /// Loops until every item is confirmed complete — one tap always finishes the job.
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

            if artists.isEmpty && albums.isEmpty {
                finalizeMetadataSync("No items found.")
                return
            }

            let fa = FanartManager.shared
            let mb = MusicBrainzManager.shared
            let maxConcurrent = 50 // Massive concurrency for Navidrome; ThrottledNetworkManager handles external limits safely
            let startTime = Date()

            // Keep looping until all artists are confirmed complete (handles partial failures in one go)
            var passCount = 0
            repeat {
                passCount += 1
                metadataStatus = passCount == 1 ? "Analyzing library..." : "Retrying incomplete items (pass \(passCount))..."
                await Task.yield()

                // Re-scan on every pass so we only work on what's still missing
                var missingArtists = [Artist]()
                for (index, artist) in artists.enumerated() {
                    let localPortraitUrl = VeloraStorage.artistPortraits.appendingPathComponent("\(artist.id).jpg")
                    let backdropKey = fa.getCacheKey(artistName: artist.primaryName, artistId: artist.id)
                    let localBackdropUrl = VeloraStorage.backdrops.appendingPathComponent(backdropKey + ".jpg")
                    let hasLocalPortrait = isValidImageFile(at: localPortraitUrl)
                    let hasBackdrop = isValidImageFile(at: localBackdropUrl)
                    let hasArtist = mb.hasArtistMetadata(for: artist.primaryName)
                    if !(hasLocalPortrait && hasArtist && hasBackdrop) {
                        missingArtists.append(artist)
                    }
                    if index % 100 == 0 { await Task.yield() }
                }

                var missingAlbums = [Album]()
                for (index, album) in albums.enumerated() {
                    let artistName = album.artist ?? "Unknown Artist"
                    if !mb.hasAlbumMetadata(albumName: album.name, artistName: artistName) {
                        missingAlbums.append(album)
                    }
                    if index % 100 == 0 { await Task.yield() }
                }

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
                                let hasBackdrop = await fa.hasBackdrop(for: artist.primaryName)
                                let hasClearLogo = await fa.hasClearLogo(for: artist.primaryName)
                                if !(hasArtist && hasBackdrop && hasClearLogo && hasLocalPortrait) {
                                    let mbid: String? = await withCheckedContinuation { continuation in
                                        Task { @MainActor in
                                            client.fetchArtistInfo(artistId: artist.id) { _, fetchedMbid in
                                                continuation.resume(returning: fetchedMbid)
                                            }
                                        }
                                    }
                                    await fa.downloadBackdropSilently(for: artist.allNames, artistId: artist.id, mbid: mbid)
                                    await fa.downloadClearLogoSilently(for: artist.primaryName, mbid: mbid)
                                    await withCheckedContinuation { cont in
                                        Task { @MainActor in
                                            client.fetchArtist(id: artist.id) { _ in cont.resume() }
                                        }
                                    }
                                    await mb.downloadMetadataSilently(for: artist.primaryName, mbid: mbid)
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

                // Phase B: Album Metadata
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

        Task {
            let tracks: [Track]
            if client.allSongs.isEmpty {
                lyricsStatus = "Fetching song list..."
                tracks = await withCheckedContinuation { continuation in
                    client.fetchAllSongs { songs in continuation.resume(returning: songs) }
                }
            } else {
                tracks = client.allSongs
            }
            if tracks.isEmpty {
                finalizeLyricsSync("No tracks found in library.")
                return
            }

            let lyricsDir = VeloraStorage.lyrics
            // Slower, safer concurrency — 5 parallel requests with 300ms stagger avoids 429s
            let maxConcurrent = 5
            let staggerNs: UInt64 = 300_000_000
            let totalTasks = Double(tracks.count)
            let startTime = Date()

            // First pass: build the list of truly missing songs
            var missingSongs = tracks.filter { song in
                let cacheFile = lyricsDir.appendingPathComponent("\(song.id).txt")
                guard FileManager.default.fileExists(atPath: cacheFile.path) else { return true }
                // Also retry empty files — not NO_LYRICS, just blank
                let size = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.size]) as? Int64 ?? 0
                return size == 0
            }
            let skippedCount = tracks.count - missingSongs.count
            var tasksCompleted = Double(skippedCount)
            lyricsProgress = tasksCompleted / totalTasks

            if missingSongs.isEmpty {
                finalizeLyricsSync("All \(Int(totalTasks)) tracks already have lyrics.")
                return
            }

            var passCount = 0
            // Retry loop: on each pass, only the songs still missing (no cache file) are attempted
            while !missingSongs.isEmpty && isSyncingLyrics && passCount < 5 {
                passCount += 1
                var failedThisPass: [Track] = []

                var startIndex = 0
                while startIndex < missingSongs.count && isSyncingLyrics {
                    let endIndex = min(startIndex + maxConcurrent, missingSongs.count)
                    let batch = Array(missingSongs[startIndex..<endIndex])

                    let attemptedSoFar = Int(tasksCompleted) - skippedCount
                    lyricsStatus = passCount == 1
                        ? "Syncing Lyrics: \(attemptedSoFar)/\(missingSongs.count) songs"
                        : "Retrying \(missingSongs.count) songs (pass \(passCount))"

                    // Exponential back-off between passes: 0, 5s, 10s, 20s, 40s
                    if passCount > 1 && startIndex == 0 {
                        let backoffSeconds = UInt64(5 * (1 << (passCount - 2)))
                        lyricsStatus = "Rate limited — waiting \(backoffSeconds)s before retry..."
                        try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                    }

                    // Track which songs in this batch succeeded so we can re-queue failures
                    let results = await withTaskGroup(of: (Track, Bool).self) { group -> [(Track, Bool)] in
                        for (index, song) in batch.enumerated() {
                            group.addTask {
                                try? await Task.sleep(nanoseconds: UInt64(index) * staggerNs)
                                let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                                    Task { @MainActor in
                                        client.fetchLyrics(
                                            trackId: song.id,
                                            artist: song.primaryArtist,
                                            title: song.title,
                                            duration: Double(song.duration ?? 0)
                                        ) { result in
                                            // Success = non-nil lyrics written; failure = nil (rate limited/error)
                                            continuation.resume(returning: result != nil)
                                        }
                                    }
                                }
                                return (song, succeeded)
                            }
                        }
                        var out: [(Track, Bool)] = []
                        for await pair in group { out.append(pair) }
                        return out
                    }

                    for (song, succeeded) in results {
                        if !succeeded {
                            // Only re-queue if we still have no cache file (not even NO_LYRICS)
                            let cacheFile = lyricsDir.appendingPathComponent("\(song.id).txt")
                            if !FileManager.default.fileExists(atPath: cacheFile.path) {
                                failedThisPass.append(song)
                            }
                        }
                    }

                    tasksCompleted += Double(batch.count)
                    lyricsProgress = min(tasksCompleted / totalTasks, 0.99)
                    startIndex += maxConcurrent

                    let nowProcessed = tasksCompleted - Double(skippedCount)
                    if nowProcessed > 0 {
                        let elapsed = Date().timeIntervalSince(startTime)
                        if elapsed >= 2.0 {
                            let rate = nowProcessed / elapsed
                            let rem = Int(Double(missingSongs.count) - nowProcessed < 0 ? 0 : (Double(missingSongs.count) - nowProcessed) / max(rate, 0.01))
                            lyricsEta = rem > 3600 ? "\(rem/3600)h remaining" : rem > 60 ? "\(rem/60)m remaining" : "\(rem)s remaining"
                        }
                    }
                }

                // Only retry songs that truly still have no file
                missingSongs = failedThisPass
                if !missingSongs.isEmpty {
                    AppLogger.shared.log("[LyricsSync] Pass \(passCount) done. \(missingSongs.count) songs still need retry.", level: .warning)
                }
            }

            let finalFailed = missingSongs.count
            if finalFailed > 0 {
                finalizeLyricsSync("Lyrics Sync done. \(skippedCount) skipped, \(finalFailed) unavailable after retries.")
            } else {
                finalizeLyricsSync("Lyrics Sync Complete (\(skippedCount) already cached)")
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

        Task {
            // Unlock maximum download concurrency for the bulk operation.
            // This is reset back to the conservative default in finalizeMediaSync.
            playback?.setBulkDownloadMode(true)
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
        playback?.setBulkDownloadMode(false)
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
                let artFile = VeloraStorage.coverArt.appendingPathComponent("\(artId).jpg")
                if !isValidImageFile(at: artFile) {
                    // Delete corrupt/poison file if it exists so repair can overwrite it
                    try? fileManager.removeItem(at: artFile)
                    missingCoverArtIds.insert(artId)
                }

                // 2. Check Artist Portrait
                let artistId = track.artistId ?? track.primaryArtist
                let portraitFile = VeloraStorage.artistPortraits.appendingPathComponent("\(artistId).jpg")
                if !isValidImageFile(at: portraitFile) {
                    try? fileManager.removeItem(at: portraitFile)
                    missingArtistPortraitIds.insert(artistId)
                }

                // 3. Check Lyrics
                let lyricsPath = VeloraStorage.lyrics.appendingPathComponent("\(track.id).txt").path
                if fileManager.fileExists(atPath: lyricsPath) {
                    if let size = (try? fileManager.attributesOfItem(atPath: lyricsPath)[.size]) as? Int64 {
                        if size == 0 {
                            try? fileManager.removeItem(atPath: lyricsPath)
                            missingLyricsIds.append((id: track.id, artist: track.primaryArtist, title: track.title, duration: Double(track.duration ?? 0)))
                        } else if size == 9 {
                            if let content = try? String(contentsOfFile: lyricsPath, encoding: .utf8), content == "NO_LYRICS" {
                                try? fileManager.removeItem(atPath: lyricsPath)
                                missingLyricsIds.append((id: track.id, artist: track.primaryArtist, title: track.title, duration: Double(track.duration ?? 0)))
                            }
                        }
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
                                            client.fetchLyrics(trackId: req.id, artist: req.artist, title: req.title, duration: req.duration) { result in
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
                }
            }

            let failedNote = missingLyricsIds.isEmpty ? "" : ", \(missingLyricsIds.count - repairedCount + (missingCoverArtIds.count - repairedCount < 0 ? 0 : 0)) unavailable"
            finalizeRepairSync("Repair complete. Fixed \(repairedCount) items.\(failedNote)")
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
        self.playback?.setBulkDownloadMode(false)   // restore normal concurrency
        self.playback?.refreshDownloadedTracks()
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
