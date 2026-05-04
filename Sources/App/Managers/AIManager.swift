import Foundation
import SwiftUI

// MARK: - Models

enum IssueType: String, Hashable, CaseIterable {
    case missingGenre = "Missing Genre"
    case missingYear = "Missing Year"
    case lowResArt = "Low-Res Art"
    case missingMetadata = "Missing Metadata"
    case missingBackdrop = "Missing Backdrop"
}

struct AuditResult: Identifiable {
    let id = UUID()
    let type: IssueType
    let count: Int
    let description: String
}

/// Velora AI Engine
/// Orchestrates library audits and intelligent metadata enrichment using Gemini and Discogs.
@MainActor
class AIManager: ObservableObject {
    static let shared = AIManager()
    
    @Published var isProcessing = false
    @Published var lastAIResponse: String? = nil
    @Published var auditResults: [AuditResult] = []
    @Published var auditStatus: String = ""
    @Published var fixProgress: Double = 0.0
    
    private init() {}
    
    private var geminiKey: String? {
        KeychainHelper.shared.read(service: "velora-gemini-key", account: "default")
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    
    private var discogsToken: String? {
        KeychainHelper.shared.read(service: "velora-discogs-token", account: "default")
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    
    func runLibraryAudit(forceRefresh: Bool = false) async {
        guard !isProcessing else { return }
        isProcessing = true
        auditStatus = "Scanning library for gaps..."
        
        // Ensure local store is populated
        let localCount = LocalMetadataStore.shared.fetchAllTracks().count
        if forceRefresh || localCount == 0 {
            auditStatus = "Syncing with Navidrome (full scan)..."
            let _ = await NavidromeClient.shared.fetchAllTracksAsync()
            auditStatus = "Scanning library for gaps..."
        }
        
        // Use LocalMetadataStore for fast analysis
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
        isProcessing = false
        auditStatus = results.isEmpty ? "Library is healthy." : "Audit complete. Found \(results.count) issue types."
    }
    
    func fixLibraryIssues(stages: Set<IssueType>? = nil) async {
        guard !isProcessing else { return }
        isProcessing = true
        fixProgress = 0.0
        
        let activeStages = stages ?? Set(IssueType.allCases)
        
        if activeStages.contains(.missingGenre) {
            await enrichGenres()
        }
        
        if activeStages.contains(.missingYear) {
            await enrichAlbumMetadata()
        }

        if activeStages.contains(.missingMetadata) {
            await enrichArtistMetadata()
        }

        if activeStages.contains(.missingBackdrop) {
            await enrichBackdrops()
        }

        if activeStages.contains(.lowResArt) {
            await fixLowResArt()
        }
        
        isProcessing = false
        auditStatus = "Optimization complete."
        AppLogger.shared.log("AIManager: Library optimization cycle finished.", level: .info)
    }
    
    private func enrichGenres() async {
        guard let key = geminiKey else { 
            AppLogger.shared.log("AIManager: Gemini API key missing.", level: .error)
            return 
        }
        let targets = LocalMetadataStore.shared.fetchTracksMissingGenre()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        AppLogger.shared.log("AIManager: Starting genre enrichment for \(targets.count) tracks.", level: .info)
        
        // We use a controlled concurrency approach to stay within free tier limits
        // but still gain some speed over pure sequential
        // We use a controlled concurrency approach to stay within free tier limits (approx 15 RPM)
        // Batch tracks to optimize Gemini throughput (20 tracks per request)
        let batchSize = 20 
        for i in stride(from: 0, to: targets.count, by: batchSize) {
            if !isProcessing { break }
            
            let end = min(i + batchSize, targets.count)
            let batch = Array(targets[i..<end])
            
            auditStatus = "AI Batch: \(i + 1) to \(end) of \(targets.count)"
            
            if let results = await self.enrichBatchWithGemini(tracks: batch, apiKey: key) {
                LocalMetadataStore.shared.updateAIMetadataBatch(results: results)
                fixed += results.count
            }
            
            fixProgress = Double(fixed) / Double(targets.count)
            
            // Adaptive throttling: 4 seconds between batches (approx 15 requests per minute)
            try? await Task.sleep(nanoseconds: 4_000_000_000) 
        }
        
        AppLogger.shared.log("AIManager: Genre enrichment complete. Fixed \(fixed) tracks.", level: .info)
    }
    
    private func enrichAlbumMetadata() async {
        let targets = LocalMetadataStore.shared.fetchAlbumsMissingYear()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        AppLogger.shared.log("AIManager: Starting album year enrichment for \(targets.count) albums.", level: .info)
        
        for pAlbum in targets {
            if !isProcessing { break }
            auditStatus = "Discogs Year: \(pAlbum.name)"
            
            if let discogs = await DiscogsManager.shared.searchAlbum(artist: pAlbum.artist ?? "", album: pAlbum.name) {
                if let yearStr = discogs.year, let year = Int(yearStr) {
                    LocalMetadataStore.shared.updateAlbumYear(for: pAlbum.id, year: year)
                    fixed += 1
                }
            }
            
            fixProgress = Double(fixed) / Double(targets.count)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // Discogs is strict
        }
    }

    private func enrichArtistMetadata() async {
        let targets = LocalMetadataStore.shared.fetchArtistsMissingInfo()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        AppLogger.shared.log("AIManager: Starting artist info enrichment for \(targets.count) artists.", level: .info)
        
        for pArtist in targets {
            if !isProcessing { break }
            auditStatus = "Researching: \(pArtist.name)"
            
            // Try to find MBID if missing
            let mbid = pArtist.musicBrainzId ?? (await MusicBrainzManager.shared.resolveMBIDAsync(for: pArtist.name))

            // Fetch bio from Navidrome or fallback
            let (bio, fetchedMbid) = await NavidromeClient.shared.fetchArtistInfoAsync(artistId: pArtist.id)
            let finalMbid = fetchedMbid ?? mbid
            
            if bio != nil || finalMbid != nil {
                LocalMetadataStore.shared.updateArtistInfo(for: pArtist.id, bio: bio, mbid: finalMbid)
                fixed += 1
            }
            
            fixProgress = Double(fixed) / Double(targets.count)
            await Task.yield()
        }
    }

    private func enrichBackdrops() async {
        let targets = LocalMetadataStore.shared.fetchTracksMissingBackdrop()
        guard !targets.isEmpty else { return }
        
        var fixed = 0
        // Group by artist to avoid redundant calls
        let artistNames = Array(Set(targets.compactMap { $0.artist }))
        AppLogger.shared.log("AIManager: Starting backdrop enrichment for \(artistNames.count) artists.", level: .info)
        
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
        
        // Group by reliable album identity to avoid redundant calls
        let albums = Dictionary(grouping: targets, by: { track -> String in
            if let aid = track.albumId { return aid }
            return "\(track.artist ?? "Unknown")|\(track.album ?? "Unknown")"
        })
        
        var fixed = 0
        AppLogger.shared.log("AIManager: Attempting to upgrade covers for \(albums.count) albums.", level: .info)
        
        var batchArtUpdates: [(trackIds: [String], albumId: String?, url: String)] = []
        
        for (albumKey, tracks) in albums {
            if !isProcessing { break }
            let firstTrack = tracks.first!
            auditStatus = "Upgrading Art: \(firstTrack.album ?? "Album")"
            
            if let discogs = await DiscogsManager.shared.searchAlbum(artist: firstTrack.artist ?? "", album: firstTrack.album ?? "") {
                if let highResUrl = discogs.cover_image {
                    let albumId = firstTrack.albumId // Use actual ID if available
                    batchArtUpdates.append((trackIds: tracks.map { $0.id }, albumId: albumId, url: highResUrl))
                    fixed += 1
                }
            }
            
            // Apply updates in small batches to keep UI responsive and save periodically
            if batchArtUpdates.count >= 5 {
                LocalMetadataStore.shared.updateCustomArtBatch(results: batchArtUpdates)
                batchArtUpdates.removeAll()
            }
            
            fixProgress = Double(fixed) / Double(albums.count)
            try? await Task.sleep(nanoseconds: 1_100_000_000) // Discogs rate limit (1 sec + safety)
        }
        
        // Final cleanup
        if !batchArtUpdates.isEmpty {
            LocalMetadataStore.shared.updateCustomArtBatch(results: batchArtUpdates)
        }
    }
    
    /// Leverages Gemini 1.5 Flash to predict genre and atmosphere for a batch of tracks.
    private func enrichBatchWithGemini(tracks: [PersistentTrack], apiKey: String) async -> [EnrichedMetadata]? {
        var trackInfo = ""
        for (index, t) in tracks.enumerated() {
            trackInfo += "\(index + 1). ID: \(t.id), Artist: \(t.artist ?? "Unknown"), Album: \(t.album ?? "Unknown"), Title: \(t.title)\n"
        }

        let prompt = """
        Predict the musical genre and mood for these tracks.
        Return ONLY a JSON array of objects in this exact format:
        [
          {
            "id": "string (matching the ID provided)",
            "genre": "string",
            "mood": "string",
            "release_year": int,
            "style": "string",
            "description": "short description"
          }
        ]
        
        Tracks:
        \(trackInfo)
        """
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)") else { return nil }
        
        let body: [String: Any] = [
            "contents": [[
                "parts": [["text": prompt]]
            ]],
            "generationConfig": [
                "response_mime_type": "application/json"
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                AppLogger.shared.log("Gemini API Error: \(httpResponse.statusCode)", level: .error)
                return nil
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                
                let cleanJson = text.replacingOccurrences(of: "```json", with: "")
                                    .replacingOccurrences(of: "```", with: "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let data = cleanJson.data(using: .utf8) {
                    do {
                        return try JSONDecoder().decode([EnrichedMetadata].self, from: data)
                    } catch {
                        AppLogger.shared.log("Gemini: Decoding failed for batch: \(error)", level: .error)
                        return nil
                    }
                }
            } else {
                AppLogger.shared.log("Gemini: Unexpected response format for batch", level: .warning)
            }
        } catch {
            AppLogger.shared.log("Gemini: Network or Parsing error: \(error.localizedDescription)", level: .error)
        }
        return nil
    }
}
