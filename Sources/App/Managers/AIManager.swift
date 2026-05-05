import Foundation
import SwiftUI
import UIKit


/// Velora AI & Metadata Engine
/// Orchestrates library audits and intelligent metadata enrichment using Gemini, Discogs, MusicBrainz, and Fanart.tv.
@available(iOS 17.0, *)
@MainActor
class AIManager: ObservableObject {
    static let shared = AIManager()
    
    // Published State
    @Published var isProcessing = false
    @Published var lastAIResponse: String? = nil
    @Published var auditResults: [AuditResult] = []
    @Published var auditStatus: String = ""
    @Published var fixProgress: Double = 0.0
    @Published var lastAuditDate: Date? = nil

    // Per-Stage Progress (0.0–1.0 each, nil = not started)
    @Published var genreProgress: Double? = nil
    @Published var yearProgress: Double? = nil
    @Published var artistProgress: Double? = nil
    @Published var backdropProgress: Double? = nil
    @Published var artProgress: Double? = nil
    @Published var activeStageLabel: String = ""
    
    // Media State (Observing managers directly is preferred, but we keep wrappers for orchestration)
    // Removed redundant currentBackdrop, currentArtistInfo, currentAlbumInfo
    
    // Keys
    private var geminiKey: String? {
        KeychainHelper.shared.read(service: "velora-gemini-key", account: "default")
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    
    private var discogsToken: String? {
        KeychainHelper.shared.read(service: "velora-discogs-token", account: "default")
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    
    // Internal State
    private var currentArtistName: String?
    
    
    func stopProcessing() {
        isProcessing = false
        auditStatus = "Process stopped by user."
    }

    
    // MARK: - Core Workflows
    
    func runLibraryAudit(forceRefresh: Bool = false) async {
        guard !isProcessing else { return }
        isProcessing = true
        auditStatus = "Scanning library for gaps..."
        
        let localCount = LocalMetadataStore.shared.trackCount()
        if forceRefresh || localCount == 0 {
            auditStatus = "Syncing with Navidrome (full scan)..."
            await NavidromeClient.shared.syncLibrary()
            auditStatus = "Scanning library for gaps..."
        }
        
        let missingGenreCount = LocalMetadataStore.shared.countTracksMissingGenre()
        let missingYearCount = LocalMetadataStore.shared.countAlbumsMissingYear()
        let lowResArtCount = LocalMetadataStore.shared.countTracksWithLowResArt()
        let missingBackdropCount = LocalMetadataStore.shared.countTracksMissingBackdrop()
        let missingMetadataCount = LocalMetadataStore.shared.countArtistsMissingInfo()
        let unknownMetaCount = LocalMetadataStore.shared.countTracksWithUnknownMetadata()
        
        var results: [AuditResult] = []
        if missingGenreCount > 0 { results.append(AuditResult(type: .missingGenre, count: missingGenreCount, description: "\(missingGenreCount) tracks missing genre prediction")) }
        if missingYearCount > 0 { results.append(AuditResult(type: .missingYear, count: missingYearCount, description: "\(missingYearCount) albums missing release year")) }
        if lowResArtCount > 0 { results.append(AuditResult(type: .lowResArt, count: lowResArtCount, description: "\(lowResArtCount) tracks have low-resolution art")) }
        if missingBackdropCount > 0 { results.append(AuditResult(type: .missingBackdrop, count: missingBackdropCount, description: "\(missingBackdropCount) tracks missing immersive backdrops")) }
        if missingMetadataCount > 0 { results.append(AuditResult(type: .missingMetadata, count: missingMetadataCount, description: "\(missingMetadataCount) artists missing biography or MBID")) }
        if unknownMetaCount > 0 { results.append(AuditResult(type: .unknownMetadata, count: unknownMetaCount, description: "\(unknownMetaCount) tracks with 'Unknown' tags")) }
        
        self.auditResults = results
        self.lastAuditDate = Date()
        isProcessing = false
        auditStatus = results.isEmpty ? "Library is healthy." : "Audit complete. Found \(results.count) issue types."
    }
    
    func fixLibraryIssues(stages: Set<IssueType>? = nil) async {
        guard !isProcessing else { return }
        isProcessing = true
        fixProgress = 0.0
        // Reset per-stage progress
        genreProgress = nil; yearProgress = nil; artistProgress = nil
        backdropProgress = nil; artProgress = nil
        activeStageLabel = ""
        
        let activeStages = stages ?? Set(IssueType.allCases)
        
        // Fetch IDs for memory efficiency
        let genreTargetIds = activeStages.contains(.missingGenre) ? LocalMetadataStore.shared.fetchTracksMissingGenreIds() : []
        let yearTargetIds = activeStages.contains(.missingYear) ? LocalMetadataStore.shared.fetchAlbumsMissingYearIds() : []
        let metaTargetIds = activeStages.contains(.missingMetadata) ? LocalMetadataStore.shared.fetchArtistsMissingInfoIds() : []
        let backdropTargetIds = activeStages.contains(.missingBackdrop) ? LocalMetadataStore.shared.fetchTracksMissingBackdropIds() : []
        let artTargetIds = activeStages.contains(.lowResArt) ? LocalMetadataStore.shared.fetchTracksWithLowResArtIds() : []
        let unknownTargetIds = activeStages.contains(.unknownMetadata) ? LocalMetadataStore.shared.fetchTracksWithUnknownMetadataIds() : []
        
        let totalItems = genreTargetIds.count + yearTargetIds.count + metaTargetIds.count + backdropTargetIds.count + artTargetIds.count + unknownTargetIds.count
        
        guard totalItems > 0 else {
            isProcessing = false
            fixProgress = 1.0
            auditStatus = "Library is already optimized."
            return
        }
        
        var itemsProcessed = 0
        
        if !genreTargetIds.isEmpty {
            genreProgress = 0.0
            activeStageLabel = "Genre Prediction"
            await enrichGenres(targetIds: genreTargetIds, totalItems: totalItems, processed: &itemsProcessed)
            genreProgress = 1.0
        }
        if !yearTargetIds.isEmpty {
            yearProgress = 0.0
            activeStageLabel = "Album Year"
            await enrichAlbumMetadata(targetIds: yearTargetIds, totalItems: totalItems, processed: &itemsProcessed)
            yearProgress = 1.0
        }
        if !metaTargetIds.isEmpty {
            artistProgress = 0.0
            activeStageLabel = "Artist Metadata"
            await enrichArtistMetadata(targetIds: metaTargetIds, totalItems: totalItems, processed: &itemsProcessed)
            artistProgress = 1.0
        }
        if !backdropTargetIds.isEmpty {
            backdropProgress = 0.0
            activeStageLabel = "Backdrop Fetch"
            await enrichBackdrops(targetIds: backdropTargetIds, totalItems: totalItems, processed: &itemsProcessed)
            backdropProgress = 1.0
        }
        if !artTargetIds.isEmpty {
            artProgress = 0.0
            activeStageLabel = "Cover Art Upgrade"
            await fixLowResArt(targetIds: artTargetIds, totalItems: totalItems, processed: &itemsProcessed)
            artProgress = 1.0
        }
        if !unknownTargetIds.isEmpty {
            activeStageLabel = "Unknown Metadata"
            await fixUnknownMetadata(targetIds: unknownTargetIds, totalItems: totalItems, processed: &itemsProcessed)
        }
        
        isProcessing = false
        fixProgress = 1.0
        activeStageLabel = ""
        auditStatus = "Optimization complete."
        AppLogger.shared.log("AIManager: Library optimization cycle finished.", level: .info)
    }
    
    // MARK: - AI Enrichment (Gemini)
    
    private func enrichGenres(targetIds: [String], totalItems: Int, processed: inout Int) async {
        guard let key = geminiKey else { 
            AppLogger.shared.log("AIManager: Gemini API key missing.", level: .error)
            return 
        }
        guard !targetIds.isEmpty else { return }
        
        let batchSize = 15 // Smaller batches for better reliability
        for i in stride(from: 0, to: targetIds.count, by: batchSize) {
            if !isProcessing { break }
            let end = min(i + batchSize, targetIds.count)
            let batchIds = Array(targetIds[i..<end])
            let batch = LocalMetadataStore.shared.fetchTracksByIds(batchIds)
            
            let currentTrack = batch.first?.title ?? "Tracks"
            auditStatus = "AI Prediction: \(currentTrack) (+ \(batch.count - 1) others)"
            
            if let results = await self.enrichBatchWithGemini(tracks: batch, apiKey: key) {
                LocalMetadataStore.shared.updateAIMetadataBatch(results: results)
            } else {
                AppLogger.shared.log("AIManager: Batch enrichment failed, continuing...", level: .warning)
            }
            
            processed += batch.count
            fixProgress = Double(processed) / Double(totalItems)
            genreProgress = Double(i + batch.count) / Double(targetIds.count)
            
            // Throttling is now handled by enrichBatchWithGeminiInternal via exponential backoff
            await Task.yield() // Keep UI responsive
        }
    }
    
    // MARK: - Album Metadata (Discogs)
    
    private func enrichAlbumMetadata(targetIds: [String], totalItems: Int, processed: inout Int) async {
        guard !targetIds.isEmpty else { return }
        let stageCount = targetIds.count
        var stageProcessed = 0
        
        for albumId in targetIds {
            if !isProcessing { break }
            guard let pAlbum = LocalMetadataStore.shared.fetchAlbumById(id: albumId) else {
                processed += 1
                stageProcessed += 1
                continue
            }
            
            auditStatus = "Discogs Year: \(pAlbum.name)"
            
            // Try Discogs for year first (already exists)
            var yearFound: Int?
            if let discogs = await DiscogsManager.shared.searchAlbum(artist: pAlbum.artist ?? "", album: pAlbum.name) {
                if let yearStr = discogs.year, let year = Int(yearStr) {
                    yearFound = year
                }
            }
            
            // Then MusicBrainz for granular info
            var label: String?
            var releaseDate: String?
            
            if let mbid = await MusicBrainzManager.shared.resolveAlbumMBIDAsync(album: pAlbum.name, artist: pAlbum.artist ?? "") {
                let details = await MusicBrainzManager.shared.fetchReleaseDetailsAsync(mbid: mbid)
                label = details.label
                releaseDate = details.releaseDate
            }
            
            if yearFound != nil || label != nil || releaseDate != nil {
                LocalMetadataStore.shared.updateAlbumYear(for: pAlbum.id, year: yearFound, label: label, firstReleaseDate: releaseDate)
            }
            
            processed += 1
            stageProcessed += 1
            fixProgress = Double(processed) / Double(totalItems)
            yearProgress = Double(stageProcessed) / Double(stageCount)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
    
    // MARK: - Artist Metadata (MusicBrainz)
    
    private func enrichArtistMetadata(targetIds: [String], totalItems: Int, processed: inout Int) async {
        guard !targetIds.isEmpty else { return }
        let stageCount = targetIds.count
        var stageProcessed = 0
        
        for artistId in targetIds {
            if !isProcessing { break }
            guard let pArtist = LocalMetadataStore.shared.fetchArtistById(id: artistId) else {
                processed += 1
                stageProcessed += 1
                continue
            }
            
            auditStatus = "Researching: \(pArtist.name)"
            
            let mbid: String?
            if let existing = pArtist.musicBrainzId {
                mbid = existing
            } else {
                mbid = await MusicBrainzManager.shared.resolveMBIDAsync(for: pArtist.name)
            }
            let (bio, fetchedMbid) = await NavidromeClient.shared.fetchArtistInfoAsync(artistId: pArtist.id)
            let finalMbid = fetchedMbid ?? mbid
            
            var type: String?
            var area: String?
            var lifeSpan: String?
            
            if let mbidToUse = finalMbid {
                let details = await MusicBrainzManager.shared.fetchArtistDetailsAsync(mbid: mbidToUse)
                type = details.type
                area = details.area
                lifeSpan = details.lifeSpan
            }
            
            if bio != nil || finalMbid != nil || type != nil || area != nil || lifeSpan != nil {
                LocalMetadataStore.shared.updateArtistInfo(for: pArtist.id, bio: bio, mbid: finalMbid, area: area, type: type, lifeSpan: lifeSpan)
            }
            
            processed += 1
            stageProcessed += 1
            fixProgress = Double(processed) / Double(totalItems)
            artistProgress = Double(stageProcessed) / Double(stageCount)
            await Task.yield()
        }
    }
    
    // MARK: - Media Assets (Fanart.tv)
    
    private func enrichBackdrops(targetIds: [String], totalItems: Int, processed: inout Int) async {
        guard !targetIds.isEmpty else { return }
        
        let targets = LocalMetadataStore.shared.fetchTracksByIds(targetIds)
        let artistNames = Array(Set(targets.compactMap { $0.artist }))
        let stageCount = artistNames.count
        var stageProcessed = 0
        
        for artist in artistNames {
            if !isProcessing { break }
            auditStatus = "Backdrop: \(artist)"
            
            let tracksForArtist = targets.filter { $0.artist == artist }
            let pArtist = LocalMetadataStore.shared.fetchArtist(name: artist)
            let mbid = pArtist?.musicBrainzId
            
            if let _ = await FanartManager.shared.fetchBackdropAsync(for: artist, mbid: mbid) {
                LocalMetadataStore.shared.updateBackdropStatus(for: artist, hasBackdrop: true)
            }
            
            processed += tracksForArtist.count
            stageProcessed += 1
            fixProgress = Double(processed) / Double(totalItems)
            backdropProgress = Double(stageProcessed) / Double(stageCount)
        }
    }
    
    private func fixLowResArt(targetIds: [String], totalItems: Int, processed: inout Int) async {
        guard !targetIds.isEmpty else { return }
        
        let targets = LocalMetadataStore.shared.fetchTracksByIds(targetIds)
        let albums = Dictionary(grouping: targets, by: { track -> String in
            if let aid = track.albumId { return aid }
            return "\(track.artist ?? "Unknown")|\(track.album ?? "Unknown")"
        })
        
        var batchArtUpdates: [(trackIds: [String], albumId: String?, url: String)] = []
        let stageCount = albums.count
        var stageProcessed = 0
        
        for (_, tracks) in albums {
            if !isProcessing { break }
            let firstTrack = tracks.first!
            auditStatus = "Upgrading Art: \(firstTrack.album ?? "Album")"
            
            if let discogs = await DiscogsManager.shared.searchAlbum(artist: firstTrack.artist ?? "", album: firstTrack.album ?? "") {
                // Validate the URL is reachable before storing it
                if let highResUrl = discogs.cover_image, await isUrlReachable(highResUrl) {
                    batchArtUpdates.append((trackIds: tracks.map { $0.id }, albumId: firstTrack.albumId, url: highResUrl))
                }
            }
            
            if batchArtUpdates.count >= 5 {
                LocalMetadataStore.shared.updateCustomArtBatch(results: batchArtUpdates)
                batchArtUpdates.removeAll()
            }
            
            processed += tracks.count
            stageProcessed += 1
            fixProgress = Double(processed) / Double(totalItems)
            artProgress = Double(stageProcessed) / Double(stageCount)
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }
        if !batchArtUpdates.isEmpty { LocalMetadataStore.shared.updateCustomArtBatch(results: batchArtUpdates) }
    }
    
    /// Performs a lightweight HEAD request to verify an image URL is actually reachable.
    private func isUrlReachable(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
        } catch {
            AppLogger.shared.log("AIManager: Art URL unreachable (\(urlString)): \(error.localizedDescription)", level: .warning)
        }
        return false
    }
    
    private func fixUnknownMetadata(targetIds: [String], totalItems: Int, processed: inout Int) async {
        guard !targetIds.isEmpty else { return }
        
        for trackId in targetIds {
            if !isProcessing { break }
            guard let track = LocalMetadataStore.shared.fetchTrack(id: trackId) else {
                processed += 1
                continue
            }
            
            auditStatus = "Fixing Metadata: \(track.title)"
            
            // For 'Unknown' tracks, we try MusicBrainz resolution first
            // We search by title since artist/album are 'Unknown'
            if let mbid = await MusicBrainzManager.shared.resolveAlbumMBIDAsync(album: "", artist: "", query: track.title) {
                let details = await MusicBrainzManager.shared.fetchReleaseDetailsAsync(mbid: mbid)
                
                if let title = details.title, let artist = details.artist {
                    LocalMetadataStore.shared.updateTrackMetadata(for: track.id, title: title, artist: artist, album: details.album)
                    AppLogger.shared.log("AIManager: Resolved 'Unknown' metadata for \(track.id) -> \(artist) - \(title)", level: .info)
                }
            }
            
            processed += 1
            fixProgress = Double(processed) / Double(totalItems)
            await Task.yield()
            // Respect rate limits for MusicBrainz
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }
    }
}


// MARK: - MusicBrainz & Fanart Integration

extension AIManager {
    
    func fetchAboutArtist(artistName: String, mbid: String? = nil) async {
        await MusicBrainzManager.shared.fetchAboutArtistAsync(artistName: artistName, mbid: mbid)
    }
    
    func resolveMBIDAsync(for artist: String) async -> String? {
        await MusicBrainzManager.shared.resolveMBIDAsync(for: artist)
    }
    
    func fetchBackdrop(for artist: String, mbid: String? = nil) async {
        // We use the async version but we still want it to update the Published property in FanartManager
        // So we call the non-async version which has the Task/MainActor logic, but we don't await the completion 
        // since it's a side-effect. Actually, better to have a dedicated 'load' method.
        _ = await FanartManager.shared.fetchBackdropAsync(for: artist, mbid: mbid)
    }
}

// MARK: - Gemini & Discogs Helpers

extension AIManager {
    // Updated signature to support retry
    private func enrichBatchWithGemini(tracks: [PersistentTrack], apiKey: String, isRetry: Bool = false) async -> [EnrichedMetadata]? {
        if isRetry {
            // Simplified prompt for retry
            return await enrichBatchWithGeminiInternal(tracks: tracks, apiKey: apiKey, promptModifier: "Return ONLY the raw JSON array. No markdown, no additional text or conversational fillers.")
        } else {
            return await enrichBatchWithGeminiInternal(tracks: tracks, apiKey: apiKey)
        }
    }
    
    private func enrichBatchWithGeminiInternal(tracks: [PersistentTrack], apiKey: String, promptModifier: String = "") async -> [EnrichedMetadata]? {
        var trackInfo = ""
        for (index, t) in tracks.enumerated() {
            AppLogger.shared.log("Gemini Request: Preparing metadata for \(t.title)", level: .debug)
            trackInfo += "\(index + 1). ID: \(t.id), Artist: \(t.artist ?? "Unknown"), Album: \(t.album ?? "Unknown"), Title: \(t.title)\n"
        }

        let prompt = """
        Predict the musical genre and mood for these tracks.
        \(promptModifier)
        Return ONLY a JSON array of objects in this exact format:
        [
          {
            "id": "string",
            "genre": "string",
            "mood": "string",
            "style": "string",
            "release_year": "number",
            "description": "string (one-sentence summary of the track's sound)"
          }
        ]
        
        Tracks:
        \(trackInfo)
        """
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)") else { return nil }
        
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "response_mime_type": "application/json",
                "temperature": 0.1
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        var retryCount = 0
        let maxRetries = 3
        
        while retryCount <= maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let http = response as? HTTPURLResponse {
                    let statusCode = http.statusCode
                    
                    if statusCode == 200 {
                        // Success - break the loop and process data below
                        retryCount = maxRetries + 1 
                        
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let firstCandidate = candidates.first,
                              let content = firstCandidate["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]],
                              let rawJson = parts.first?["text"] as? String else {
                            AppLogger.shared.log("AIManager: Gemini response format invalid.", level: .error)
                            return nil
                        }
                        
                        let cleaned = self.extractJsonArray(from: rawJson)
                        guard let jsonData = cleaned.data(using: .utf8) else { return nil }
                        
                        do {
                            let results = try JSONDecoder().decode([EnrichedMetadata].self, from: jsonData)
                            AppLogger.shared.log("AIManager: Successfully decoded \(results.count) predictions.", level: .info)
                            return results
                        } catch {
                            if promptModifier.isEmpty { // Only retry once with stricter prompt
                                AppLogger.shared.log("AIManager: JSON decoding failed. Retrying with stricter prompt...", level: .warning)
                                return await self.enrichBatchWithGemini(tracks: tracks, apiKey: apiKey, isRetry: true)
                            } else {
                                AppLogger.shared.log("AIManager: JSON decoding failed after retry. Giving up on this batch.", level: .error)
                                return nil
                            }
                        }
                    } else if [429, 500, 502, 503, 504].contains(statusCode) {
                        retryCount += 1
                        if retryCount > maxRetries {
                            AppLogger.shared.log("AIManager: Max retries exceeded for status \(statusCode).", level: .error)
                            return nil
                        }
                        let sleepTime = pow(2.0, Double(retryCount)) * 2.0 // 4s, 8s, 16s...
                        AppLogger.shared.log("AIManager: Transient error (\(statusCode)). Retrying in \(Int(sleepTime))s...", level: .warning)
                        try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
                        continue
                    } else {
                        AppLogger.shared.log("AIManager: Gemini API returned persistent error \(statusCode)", level: .error)
                        return nil
                    }
                }
            } catch {
                retryCount += 1
                if retryCount > maxRetries {
                    AppLogger.shared.log("AIManager: Gemini network error: \(error.localizedDescription)", level: .error)
                    return nil
                }
                let sleepTime = pow(2.0, Double(retryCount)) * 2.0
                AppLogger.shared.log("AIManager: Network error. Retrying in \(Int(sleepTime))s...", level: .warning)
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }
        return nil
    }

    
    private func extractJsonArray(from text: String) -> String {
        // 1. Remove markdown blocks and language identifiers
        var result = text.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "```", with: "")
        
        // 2. Locate the first '[' and last ']' to isolate the JSON array
        if let start = result.range(of: "["), let end = result.range(of: "]", options: .backwards) {
            result = String(result[start.lowerBound...end.lowerBound])
        }
        
        // 3. Scrub common LLM formatting errors
        // Remove trailing commas before closing brackets/braces
        result = result.replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)
        result = result.replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)
        
        // Remove any escaped quotes that might confuse the decoder if they are double-escaped
        result = result.replacingOccurrences(of: "\\\"", with: "\"")
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

