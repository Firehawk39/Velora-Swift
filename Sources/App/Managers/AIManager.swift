import Foundation
import SwiftUI
import Combine

/// Velora AI Engine
/// Responsible for metadata enrichment, intelligent library auditing, and AI-driven backdrop generation.
class AIManager: ObservableObject {
    static let shared = AIManager()
    
    @Published var isProcessing = false
    @Published var lastAIResponse: String? = nil
    @Published var auditResults: [AuditResult] = []
    @Published var auditStatus: String = ""
    @Published var fixProgress: Double = 0.0
    
    private let navidrome = NavidromeClient.shared
    private let musicBrainz = MusicBrainzManager.shared
    
    // API Configuration
    private var geminiApiKey: String {
        if let data = KeychainHelper.shared.read(service: "velora-ai", account: "gemini_api_key"),
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        return UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
    }
    
    private var discogsApiKey: String {
        if let data = KeychainHelper.shared.read(service: "velora-ai", account: "discogs_api_key"),
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        return UserDefaults.standard.string(forKey: "discogs_api_key") ?? ""
    }
    
    private var discogsApiSecret: String {
        if let data = KeychainHelper.shared.read(service: "velora-ai", account: "discogs_api_secret"),
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        return UserDefaults.standard.string(forKey: "discogs_api_secret") ?? ""
    }
    
    private var falApiKey: String {
        if let data = KeychainHelper.shared.read(service: "velora-ai", account: "fal_api_key"),
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        return UserDefaults.standard.string(forKey: "fal_api_key") ?? ""
    }
    
    private init() {}
    
    // MARK: - Library Auditing
    
    /// Scans the local persistence layer for missing or "Unknown" metadata.
    @MainActor
    func runLibraryAudit(forceRefresh: Bool = false) async {
        guard !isProcessing else { return }
        self.isProcessing = true
        self.auditResults = []
        
        AppLogger.shared.log("[AI Engine] Starting \(forceRefresh ? "Full" : "Optimized") Library Audit...", level: .info)
        
        if forceRefresh {
            auditStatus = "Syncing with Navidrome..."
            _ = await navidrome.fetchAllTracksAsync()
        }
        
        let tracks = LocalMetadataStore.shared.fetchAllTracks()
        let targets = LocalMetadataStore.shared.fetchAuditTargets()
        
        // 1. Missing Genre Classification
        let unknownGenre = tracks.filter { $0.aiGenrePrediction == nil }
        if !unknownGenre.isEmpty {
            self.auditResults.append(AuditResult(
                type: .missingGenre,
                count: unknownGenre.count,
                description: "\(unknownGenre.count) tracks need AI genre classification."
            ))
        }
        
        // 2. Generic "Unknown" Metadata
        let unknownMetadata = targets.filter { $0.artist == "Unknown" || $0.album == "Unknown" }
        if !unknownMetadata.isEmpty {
            self.auditResults.append(AuditResult(
                type: .missingMetadata,
                count: unknownMetadata.count,
                description: "\(unknownMetadata.count) tracks have 'Unknown' tags."
            ))
        }
        
        // 3. Missing Release Year
        let albums = LocalMetadataStore.shared.fetchAllAlbums()
        let missingYear = albums.filter { $0.releaseYear == 0 || $0.releaseYear == nil }
        if !missingYear.isEmpty {
            self.auditResults.append(AuditResult(
                type: .missingYear,
                count: missingYear.count,
                description: "\(missingYear.count) albums are missing release year information."
            ))
        }
        
        // 4. Low Resolution Artwork
        let lowResArt = tracks.filter { $0.coverArt != nil && !$0.coverArt!.contains("size=500") }
        if !lowResArt.isEmpty {
            self.auditResults.append(AuditResult(
                type: .lowResArt,
                count: lowResArt.count,
                description: "\(lowResArt.count) tracks have low-resolution artwork."
            ))
        }
        
        // 5. Deep Artist Integrity
        let artists = LocalMetadataStore.shared.fetchAllArtists()
        let missingArtistInfo = artists.filter { $0.biography == nil || $0.musicBrainzId == nil }
        if !missingArtistInfo.isEmpty {
            self.auditResults.append(AuditResult(
                type: .missingMetadata,
                count: missingArtistInfo.count,
                description: "\(missingArtistInfo.count) artists are missing professional biographies."
            ))
        }
        
        // 6. Missing Backdrops
        let missingBackdrops = tracks.filter { !$0.hasCustomBackdrop }
        if !missingBackdrops.isEmpty {
            self.auditResults.append(AuditResult(
                type: .missingBackdrop,
                count: missingBackdrops.count,
                description: "\(missingBackdrops.count) tracks missing AI backdrops."
            ))
        }
        
        self.isProcessing = false
        AppLogger.shared.log("[AI Engine] Audit complete. Found \(auditResults.count) issue types.")
    }
    
    /// Processes specific library issues or the entire collection if no stages are provided.
    @MainActor
    func fixLibraryIssues(stages: Set<IssueType>? = nil) async {
        guard !isProcessing else { return }
        self.isProcessing = true
        self.fixProgress = 0.0
        
        let store = LocalMetadataStore.shared
        let stagesToRun = stages ?? Set([.missingGenre, .missingMetadata, .missingYear, .lowResArt, .missingBackdrop])
        
        // Fetch targets based on stages
        var missingGenre: [TrackMetadata] = []
        var unknownMeta: [TrackMetadata] = []
        var missingYear: [AlbumMetadata] = []
        var lowResArt: [TrackMetadata] = []
        var missingArtistInfo: [ArtistMetadata] = []
        var missingBackdrops: [TrackMetadata] = []
        
        if stagesToRun.contains(.missingGenre) { missingGenre = store.fetchTracksMissingGenre() }
        if stagesToRun.contains(.missingMetadata) { 
            unknownMeta = store.fetchTracksWithUnknownMetadata()
            missingArtistInfo = store.fetchArtistsMissingInfo()
        }
        if stagesToRun.contains(.missingYear) { missingYear = store.fetchAlbumsMissingYear() }
        if stagesToRun.contains(.lowResArt) { lowResArt = store.fetchTracksWithLowResArt() }
        if stagesToRun.contains(.missingBackdrop) { missingBackdrops = store.fetchTracksMissingBackdrop() }
        
        let totalIssues = missingGenre.count + unknownMeta.count + missingYear.count + lowResArt.count + missingArtistInfo.count + missingBackdrops.count
        var solvedCount = 0
        
        AppLogger.shared.log("[AI Engine] Starting targeted fix for \(totalIssues) items in stages: \(stagesToRun.map { "\($0)" }.joined(separator: ", "))", level: .info)
        
        if totalIssues == 0 {
            self.isProcessing = false
            self.auditStatus = "No issues found for selected stages."
            return
        }

        // --- STAGE 1: Genre & Metadata Enrichment (Gemini) ---
        if stagesToRun.contains(.missingGenre) || stagesToRun.contains(.missingMetadata) {
            let enrichmentTargets = Array(Set(missingGenre + unknownMeta))
            if !enrichmentTargets.isEmpty {
                self.auditStatus = "Enriching Genres & Metadata..."
                for chunk in enrichmentTargets.chunked(into: 5) {
                    await withTaskGroup(of: Void.self) { group in
                        for track in chunk {
                            group.addTask {
                                let trackObj = Track(id: track.id, title: track.title, album: track.album ?? "", artist: track.artist ?? "")
                                if let enriched = await self.enrichMetadata(for: trackObj) {
                                    await store.updateAIMetadata(for: track.id, genre: enriched.genre, atmosphere: enriched.mood)
                                }
                            }
                        }
                    }
                    solvedCount += chunk.count
                    self.fixProgress = Double(solvedCount) / Double(totalIssues)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        
        // --- STAGE 2: Release Years ---
        if stagesToRun.contains(.missingYear) && !missingYear.isEmpty {
            self.auditStatus = "Finding Release Years..."
            for chunk in missingYear.chunked(into: 5) {
                await withTaskGroup(of: Void.self) { group in
                    for album in chunk {
                        group.addTask {
                            let prompt = "Identify the original release year for the album '\(album.name)' by '\(album.artist ?? "Unknown")'. Output JSON only: { \"year\": number }"
                            if let response = await self.callGemini(prompt: prompt, retryCount: 2),
                               let json = await self.parseJSON(response),
                               let year = json["year"] as? Int {
                                await store.updateAlbumYear(for: album.id, year: year)
                            }
                        }
                    }
                }
                solvedCount += chunk.count
                self.fixProgress = Double(solvedCount) / Double(totalIssues)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        
        // --- STAGE 3: Artwork Quality ---
        if stagesToRun.contains(.lowResArt) && !lowResArt.isEmpty {
            self.auditStatus = "Upgrading Artwork Quality..."
            for track in lowResArt {
                if let url = await self.searchDiscogsForImage(query: "\(track.artist ?? "") \(track.album ?? "")") {
                    track.coverArt = url.absoluteString
                }
                solvedCount += 1
                self.fixProgress = Double(solvedCount) / Double(totalIssues)
                if solvedCount % 3 == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            try? store.context?.save()
        }
        
        // --- STAGE 4: Artist Bios ---
        if stagesToRun.contains(.missingMetadata) && !missingArtistInfo.isEmpty {
            self.auditStatus = "Writing Artist Biographies..."
            for artist in missingArtistInfo {
                if artist.musicBrainzId == nil {
                    artist.musicBrainzId = await musicBrainz.resolveMBIDAsync(for: artist.name)
                }
                
                let prompt = "Write a compelling 2-paragraph biography for '\(artist.name)'. Return JSON: { \"bio\": \"string\" }"
                if let response = await self.callGemini(prompt: prompt, retryCount: 1),
                   let json = await self.parseJSON(response),
                   let bio = json["bio"] as? String {
                    artist.biography = bio
                }
                
                solvedCount += 1
                self.fixProgress = Double(solvedCount) / Double(totalIssues)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? store.context?.save()
        }
        
        // --- STAGE 5: AI Backdrops ---
        if stagesToRun.contains(.missingBackdrop) && !missingBackdrops.isEmpty && !falApiKey.isEmpty {
            self.auditStatus = "Generating Cinematic Backdrops..."
            for track in missingBackdrops {
                guard let artistName = track.artist else { continue }
                
                // Try Fanart first
                if let _ = await FanartManager.shared.fetchBackdropAsync(for: artistName, mbid: track.artistId) {
                    // Success
                } else {
                    // Fallback to AI
                    if let image = await self.generateAIBackdrop(for: artistName, genre: track.aiGenrePrediction) {
                        let fileUrl = FanartManager.shared.getBackdropUrl(for: artistName)
                        if let data = image.jpegData(compressionQuality: 0.8) {
                            try? data.write(to: fileUrl)
                        }
                    }
                }
                
                track.hasCustomBackdrop = true
                solvedCount += 1
                self.fixProgress = Double(solvedCount) / Double(totalIssues)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? store.context?.save()
        }
        
        self.isProcessing = false
        self.auditStatus = "Stage Enrichment Complete"
        self.fixProgress = 1.0
        await runLibraryAudit()
    }
    
    // MARK: - Core AI Logic
    
    func enrichMetadata(for track: Track) async -> EnrichedMetadata? {
        guard !geminiApiKey.isEmpty else { return nil }
        
        let prompt = """
        Music Metadata Expert: Analyze '\(track.title)' by '\(track.artist ?? "Unknown")' from album '\(track.album ?? "Unknown")'.
        Provide precise genre classification and emotional atmosphere.
        
        Format output as JSON:
        {
          "genre": "Primary Genre (e.g. Progressive House, Neo-Soul)",
          "mood": "Emotional Vibe (e.g. Melancholic, Ethereal, Aggressive)",
          "release_year": YYYY,
          "style": "Sub-genre or Style",
          "description": "One sentence summary"
        }
        """
        
        if let response = await callGemini(prompt: prompt, retryCount: 2),
           let data = await parseJSONData(response) {
            return try? JSONDecoder().decode(EnrichedMetadata.self, from: data)
        }
        return nil
    }
    
    func generateAIBackdrop(for artist: String, genre: String?) async -> UIImage? {
        guard !falApiKey.isEmpty else { return nil }
        
        let genreDesc = genre != nil ? " inspired by \(genre!) aesthetics" : ""
        let prompt = "Ultra-realistic 8k cinematic studio portrait of the music artist \(artist)\(genreDesc). Moody lighting, sharp focus on subject, dark minimalist background, professional photography, anamorphic lens flare, shallow depth of field."
        
        let url = URL(string: "https://queue.fal.run/fal-ai/fast-lightning-sdxl")!
        let body: [String: Any] = [
            "prompt": prompt,
            "image_size": "landscape_16_9",
            "num_inference_steps": 4,
            "seed": Int.random(in: 1...1000000)
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(falApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let imageUrlString = json["url"] as? String,
               let imageUrl = URL(string: imageUrlString) {
                return await downloadImage(from: imageUrl)
            }
        } catch {
            AppLogger.shared.log("[AI Engine] fal.ai failure: \(error.localizedDescription)", level: .error)
        }
        return nil
    }
    
    // MARK: - Networking Helpers
    
    private func callGemini(prompt: String, retryCount: Int = 0) async -> String? {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(geminiApiKey)")!
        
        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["response_mime_type": "application/json"]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        for attempt in 0...retryCount {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = json["candidates"] as? [[String: Any]],
                       let text = candidates.first?["content"] as? [String: Any],
                       let parts = text["parts"] as? [[String: Any]],
                       let result = parts.first?["text"] as? String {
                        return result
                    }
                } else {
                    AppLogger.shared.log("[AI Engine] Gemini API error (Attempt \(attempt+1))", level: .warning)
                }
            } catch {
                AppLogger.shared.log("[AI Engine] Network error: \(error.localizedDescription)", level: .error)
            }
            if attempt < retryCount { try? await Task.sleep(nanoseconds: 1_000_000_000 * UInt64(attempt + 1)) }
        }
        return nil
    }
    
    private func searchDiscogsForImage(query: String) async -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "https://api.discogs.com/database/search?q=\(encoded)&type=master&key=\(discogsApiKey)&secret=\(discogsApiSecret)")!
        
        var request = URLRequest(url: url)
        request.setValue("VeloraApp/1.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let first = results.first(where: { ($0["cover_image"] as? String)?.isEmpty == false }),
               let cover = first["cover_image"] as? String {
                return URL(string: cover)
            }
        } catch { }
        return nil
    }
    
    private func downloadImage(from url: URL) async -> UIImage? {
        try? await URLSession.shared.data(from: url).0.flatMap { UIImage(data: $0) }
    }
    
    private func parseJSON(_ text: String) async -> [String: Any]? {
        guard let data = await parseJSONData(text) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    
    private func parseJSONData(_ text: String) async -> Data? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.contains("```") {
            let parts = cleaned.components(separatedBy: "```")
            for part in parts {
                let p = part.replacingOccurrences(of: "json", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if p.hasPrefix("{") { cleaned = p; break }
            }
        }
        
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }
        
        return cleaned.data(using: .utf8)
    }
}

// MARK: - Helpers

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Optional where Wrapped == Data {
    func flatMap<T>(_ transform: (Wrapped) -> T?) -> T? {
        self.flatMap(transform)
    }
}

// MARK: - Models

struct AuditResult: Identifiable {
    let id = UUID()
    enum IssueType { 
        case missingGenre, missingYear, lowResArt, missingMetadata, missingBackdrop
    }
    let type: IssueType
    let count: Int
    let description: String
}

struct EnrichedMetadata: Codable {
    let genre: String
    let mood: String
    let release_year: Int
    let style: String?
    let description: String?
}
