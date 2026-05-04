import Foundation
import SwiftUI
import UIKit


/// Velora AI & Metadata Engine
/// Orchestrates library audits and intelligent metadata enrichment using Gemini, Discogs, MusicBrainz, and Fanart.tv.
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
    
    // Media State (from former FanartManager)
    @Published var currentBackdrop: UIImage? = nil
    @Published var currentArtistInfo: ArtistInfo? = nil
    @Published var currentAlbumInfo: AlbumInfo? = nil
    
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
        
        let localCount = LocalMetadataStore.shared.fetchAllTracks().count
        if forceRefresh || localCount == 0 {
            auditStatus = "Syncing with Navidrome (full scan)..."
            await NavidromeClient.shared.syncLibrary()
            auditStatus = "Scanning library for gaps..."
        }
        
        let missingGenre = LocalMetadataStore.shared.fetchTracksMissingGenre()
        let missingYear = LocalMetadataStore.shared.fetchAlbumsMissingYear()
        let lowResArt = LocalMetadataStore.shared.fetchTracksWithLowResArt()
        let missingBackdrop = LocalMetadataStore.shared.fetchTracksMissingBackdrop()
        let missingMetadata = LocalMetadataStore.shared.fetchArtistsMissingInfo()
        
        var results: [AuditResult] = []
        if !missingGenre.isEmpty { results.append(AuditResult(type: .missingGenre, count: missingGenre.count, description: "\(missingGenre.count) tracks missing genre prediction")) }
        if !missingYear.isEmpty { results.append(AuditResult(type: .missingYear, count: missingYear.count, description: "\(missingYear.count) albums missing release year")) }
        if !lowResArt.isEmpty { results.append(AuditResult(type: .lowResArt, count: lowResArt.count, description: "\(lowResArt.count) tracks have low-resolution art")) }
        if !missingBackdrop.isEmpty { results.append(AuditResult(type: .missingBackdrop, count: missingBackdrop.count, description: "\(missingBackdrop.count) tracks missing immersive backdrops")) }
        if !missingMetadata.isEmpty { results.append(AuditResult(type: .missingMetadata, count: missingMetadata.count, description: "\(missingMetadata.count) artists missing biography or MBID")) }
        
        self.auditResults = results
        self.lastAuditDate = Date()
        isProcessing = false
        auditStatus = results.isEmpty ? "Library is healthy." : "Audit complete. Found \(results.count) issue types."
    }
    
    func fixLibraryIssues(stages: Set<IssueType>? = nil) async {
        guard !isProcessing else { return }
        isProcessing = true
        fixProgress = 0.0
        
        let activeStages = stages ?? Set(IssueType.allCases)
        
        if activeStages.contains(.missingGenre) { await enrichGenres() }
        if activeStages.contains(.missingYear) { await enrichAlbumMetadata() }
        if activeStages.contains(.missingMetadata) { await enrichArtistMetadata() }
        if activeStages.contains(.missingBackdrop) { await enrichBackdrops() }
        if activeStages.contains(.lowResArt) { await fixLowResArt() }
        
        isProcessing = false
        auditStatus = "Optimization complete."
        AppLogger.shared.log("AIManager: Library optimization cycle finished.", level: .info)
    }
    
    // MARK: - AI Enrichment (Gemini)
    
    private func enrichGenres() async {
        guard let key = geminiKey else { 
            AppLogger.shared.log("AIManager: Gemini API key missing.", level: .error)
            return 
        }
        let targets = LocalMetadataStore.shared.fetchTracksMissingGenre()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        let batchSize = 15 // Smaller batches for better reliability
        for i in stride(from: 0, to: targets.count, by: batchSize) {
            if !isProcessing { break }
            let end = min(i + batchSize, targets.count)
            let batch = Array(targets[i..<end])
            
            // Fixed: Use descriptive auditStatus
            let currentTrack = batch.first?.title ?? "Tracks"
            auditStatus = "AI Prediction: \(currentTrack) (+ \(batch.count - 1) others)"
            
            if let results = await self.enrichBatchWithGemini(tracks: batch, apiKey: key) {
                LocalMetadataStore.shared.updateAIMetadataBatch(results: results)
                fixed += results.count
            }
            fixProgress = Double(fixed) / Double(targets.count)
            
            // Increased throttle for Gemini Free Tier (5s)
            try? await Task.sleep(nanoseconds: 5_000_000_000) 
        }
    }
    
    // MARK: - Album Metadata (Discogs)
    
    private func enrichAlbumMetadata() async {
        let targets = LocalMetadataStore.shared.fetchAlbumsMissingYear()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        for pAlbum in targets {
            if !isProcessing { break }
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
                LocalMetadataStore.shared.updateAlbumYearBatch(for: pAlbum.id, year: yearFound, label: label, releaseDate: releaseDate)
                fixed += 1
            }
            
            fixProgress = Double(fixed) / Double(targets.count)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
    
    // MARK: - Artist Metadata (MusicBrainz)
    
    private func enrichArtistMetadata() async {
        let targets = LocalMetadataStore.shared.fetchArtistsMissingInfo()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        for pArtist in targets {
            if !isProcessing { break }
            auditStatus = "Researching: \(pArtist.name)"
            
            let mbid = pArtist.musicBrainzId ?? (await MusicBrainzManager.shared.resolveMBIDAsync(for: pArtist.name))
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
                fixed += 1
            }
            fixProgress = Double(fixed) / Double(targets.count)
            await Task.yield()
        }
    }
    
    // MARK: - Media Assets (Fanart.tv)
    
    private func enrichBackdrops() async {
        let targets = LocalMetadataStore.shared.fetchTracksMissingBackdrop()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        let artistNames = Array(Set(targets.compactMap { $0.artist }))
        for artist in artistNames {
            if !isProcessing { break }
            auditStatus = "Backdrop: \(artist)"
            let pArtist = LocalMetadataStore.shared.fetchArtist(name: artist)
            let mbid = pArtist?.musicBrainzId
            
            FanartManager.shared.downloadBackdropSilently(for: artist, mbid: mbid)
            fixed += 1
            fixProgress = Double(fixed) / Double(artistNames.count)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
    
    private func fixLowResArt() async {
        let targets = LocalMetadataStore.shared.fetchTracksWithLowResArt()
        guard !targets.isEmpty else { return }
        
        let albums = Dictionary(grouping: targets, by: { track -> String in
            if let aid = track.albumId { return aid }
            return "\(track.artist ?? "Unknown")|\(track.album ?? "Unknown")"
        })
        
        var fixed = 0
        var batchArtUpdates: [(trackIds: [String], albumId: String?, url: String)] = []
        
        for (albumKey, tracks) in albums {
            if !isProcessing { break }
            let firstTrack = tracks.first!
            auditStatus = "Upgrading Art: \(firstTrack.album ?? "Album")"
            
            if let discogs = await DiscogsManager.shared.searchAlbum(artist: firstTrack.artist ?? "", album: firstTrack.album ?? "") {
                if let highResUrl = discogs.cover_image {
                    batchArtUpdates.append((trackIds: tracks.map { $0.id }, albumId: firstTrack.albumId, url: highResUrl))
                    fixed += 1
                }
            }
            
            if batchArtUpdates.count >= 5 {
                LocalMetadataStore.shared.updateCustomArtBatch(results: batchArtUpdates)
                batchArtUpdates.removeAll()
            }
            fixProgress = Double(fixed) / Double(albums.count)
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }
        if !batchArtUpdates.isEmpty { LocalMetadataStore.shared.updateCustomArtBatch(results: batchArtUpdates) }
    }
}


// MARK: - MusicBrainz & Fanart Integration

extension AIManager {
    
    func fetchAboutArtist(artistName: String, mbid: String? = nil) async {
        MusicBrainzManager.shared.fetchAboutArtist(artistName: artistName, mbid: mbid)
    }
    
    func resolveMBIDAsync(for artist: String) async -> String? {
        await MusicBrainzManager.shared.resolveMBIDAsync(for: artist)
    }
    
    func fetchBackdrop(for artist: String, mbid: String? = nil) async {
        FanartManager.shared.fetchBackdrop(for: artist, mbid: mbid)
    }
}

// MARK: - Gemini & Discogs Helpers

extension AIManager {
    private func enrichBatchWithGemini(tracks: [PersistentTrack], apiKey: String) async -> [EnrichedMetadata]? {
        var trackInfo = ""
        for (index, t) in tracks.enumerated() {
            // Fixed: Standardizing on 'title' for logging if needed, though 't.title' is correct here.
            // Adding a debug log for each track being sent.
            AppLogger.shared.log("Gemini Request: Preparing metadata for \(t.title)", level: .debug)
            trackInfo += "\(index + 1). ID: \(t.id), Artist: \(t.artist ?? "Unknown"), Album: \(t.album ?? "Unknown"), Title: \(t.title)\n"
        }

        let prompt = """
        Predict the musical genre and mood for these tracks.
        Return ONLY a JSON array of objects in this exact format:
        [
          {
            "id": "string",
            "genre": "string",
            "mood": "string"
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
                "temperature": 0.1 // Lower temperature for more stable JSON
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                AppLogger.shared.log("AIManager: Gemini API returned status \(http.statusCode)", level: .error)
                return nil
            }
            
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
                AppLogger.shared.log("AIManager: JSON decoding failed: \(error.localizedDescription). Raw: \(cleaned.prefix(100))...", level: .error)
                return nil
            }
        } catch {
            AppLogger.shared.log("AIManager: Gemini network error: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
    
    private func extractJsonArray(from text: String) -> String {
        var result = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        
        if let start = result.firstIndex(of: "["), let end = result.lastIndex(of: "]") {
            result = String(result[start...end])
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

