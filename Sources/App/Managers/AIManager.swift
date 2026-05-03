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
    
    private let navidrome = NavidromeClient.shared
    private let musicBrainz = MusicBrainzManager.shared
    
    // API Configuration
    private var geminiApiKey: String {
        return UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
    }
    
    private var discogsApiKey: String {
        return UserDefaults.standard.string(forKey: "discogs_api_key") ?? ""
    }
    
    private var discogsApiSecret: String {
        return UserDefaults.standard.string(forKey: "discogs_api_secret") ?? ""
    }
    
    private init() {}
    
    // MARK: - Library Auditing
    
    /// Scans the library for missing or "Unknown" metadata and prepares an enrichment plan.
    func runLibraryAudit() {
        self.isProcessing = true
        self.auditResults = []
        
        AppLogger.shared.log("[AI Engine] Starting Library Audit...", level: .info)
        
        navidrome.fetchAllTracks { tracks in
            let unknownGenreTracks = tracks.filter { 
                let g = $0.genre?.lowercased() ?? ""
                return g == "unknown" || g.isEmpty || g == "none"
            }
            let missingYearTracks = tracks.filter { $0.year == 0 || $0.year == nil }
            
            // Check for low-res or missing art
            let missingArtTracks = tracks.filter { $0.coverArt == nil || $0.coverArt?.isEmpty == true }
            
            DispatchQueue.main.async {
                if !unknownGenreTracks.isEmpty {
                    self.auditResults.append(AuditResult(
                        type: .missingGenre,
                        count: unknownGenreTracks.count,
                        description: "\(unknownGenreTracks.count) tracks missing genre classification."
                    ))
                }
                
                if !missingYearTracks.isEmpty {
                    self.auditResults.append(AuditResult(
                        type: .missingYear,
                        count: missingYearTracks.count,
                        description: "\(missingYearTracks.count) tracks missing release year."
                    ))
                }
                
                if !missingArtTracks.isEmpty {
                    self.auditResults.append(AuditResult(
                        type: .lowResArt,
                        count: missingArtTracks.count,
                        description: "\(missingArtTracks.count) tracks with missing or low-res artwork."
                    ))
                }
                
                self.isProcessing = false
                AppLogger.shared.log("[AI Engine] Audit complete. Found \(self.auditResults.count) issue categories.")
            }
        }
    }
    
    // MARK: - Metadata Enrichment
    
    /// Uses Gemini AI to predict and enrich metadata for a specific track.
    func enrichMetadata(for track: Track, completion: @escaping (EnrichedMetadata?) -> Void) {
        guard !geminiApiKey.isEmpty else {
            AppLogger.shared.log("[AI Engine] Gemini API Key missing. Skipping enrichment.", level: .warning)
            completion(nil)
            return
        }
        
        let prompt = """
        Analyze this music track and provide accurate metadata. 
        Focus on identifying the primary genre and the release year.
        
        Artist: \(track.artist ?? "Unknown")
        Title: \(track.title)
        Album: \(track.album ?? "Unknown")
        
        Return valid JSON only:
        {
          "genre": "string",
          "mood": "string",
          "release_year": number,
          "era": "string",
          "description": "string"
        }
        """
        
        callGemini(prompt: prompt) { response in
            guard let data = response?.data(using: .utf8) else {
                completion(nil)
                return
            }
            
            do {
                let enriched = try JSONDecoder().decode(EnrichedMetadata.self, from: data)
                completion(enriched)
            } catch {
                AppLogger.shared.log("[AI Engine] Failed to parse Gemini response: \(error)", level: .error)
                completion(nil)
            }
        }
    }
    
    // MARK: - AI Backdrop Generation
    
    /// Generates a cinematic prompt for image generation based on artist and genre.
    func generateBackdropPrompt(for artist: String, genre: String?) -> String {
        let basePrompt = "High-fidelity cinematic studio portrait of \(artist)"
        let genreContext = genre != nil ? " reflecting the atmospheric vibes of \(genre!) music" : ""
        return "\(basePrompt)\(genreContext), moody atmospheric lighting, professional color grading, sharp focus, 8k resolution, minimalist depth of field."
    }
    
    /// Fetches a high-quality backdrop using Discogs or Gemini-assisted search
    func fetchIntelligentBackdrop(for artist: String, album: String?, completion: @escaping (UIImage?) -> Void) {
        // 1. Try Discogs first if we have credentials
        if !discogsApiKey.isEmpty {
            searchDiscogsForImage(query: "\(artist) \(album ?? "")") { url in
                if let url = url {
                    self.downloadImage(from: url, completion: completion)
                } else {
                    // Fallback to Gemini backdrop strategy
                    self.fallbackToGeminiBackdrop(artist: artist, completion: completion)
                }
            }
        } else {
            // No Discogs, try Fanart or Gemini
            fallbackToGeminiBackdrop(artist: artist, completion: completion)
        }
    }
    
    private func fallbackToGeminiBackdrop(artist: String, completion: @escaping (UIImage?) -> Void) {
        AppLogger.shared.log("[AI Engine] Using Gemini to find backdrop context for \(artist)...")
        // Gemini can't "send" an image, but it can give us better search terms or a descriptive prompt
        // In Velora, we might use this prompt to hit a generative API or just return a placeholder for now
        completion(nil) 
    }
    
    // MARK: - API Calls
    
    private func callGemini(prompt: String, completion: @escaping (String?) -> Void) {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(geminiApiKey)"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "response_mime_type": "application/json"
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                AppLogger.shared.log("[AI Engine] Gemini error: \(error.localizedDescription)", level: .error)
                completion(nil); return
            }
            
            guard let data = data else { completion(nil); return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let first = candidates.first,
                   let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String {
                    completion(text)
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }.resume()
    }
    
    private func searchDiscogsForImage(query: String, completion: @escaping (URL?) -> Void) {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.discogs.com/database/search?q=\(encodedQuery)&type=master&key=\(discogsApiKey)&secret=\(discogsApiSecret)"
        
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue("VeloraAI/1.0", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let cover = first["cover_image"] as? String,
                  let imageUrl = URL(string: cover) else {
                completion(nil); return
            }
            completion(imageUrl)
        }.resume()
    }
    
    private func downloadImage(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                DispatchQueue.main.async { completion(image) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }
}

// MARK: - Models

struct AuditResult: Identifiable {
    let id = UUID()
    enum IssueType { case missingGenre, missingYear, lowResArt }
    let type: IssueType
    let count: Int
    let description: String
}

struct EnrichedMetadata: Codable {
    let genre: String
    let mood: String
    let release_year: Int
    let era: String
    let description: String
}
