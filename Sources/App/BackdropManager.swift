import SwiftUI
import Foundation

class BackdropManager: ObservableObject {
    static let shared = BackdropManager()
    
    @Published var currentBackdrop: UIImage? = nil
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // Fanart.tv API Key - Placeholder
    private let fanartApiKey = "53406560946a364a51e608034d67394c" 
    
    init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDirectory = docs.appendingPathComponent("Backdrops", isDirectory: true)
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    func fetchBackdrop(for artist: String, artistId: String? = nil) {
        let fileName = sanitizeFileName(artist) + ".jpg"
        let fileUrl = cacheDirectory.appendingPathComponent(fileName)
        
        // 1. Check Local Cache
        if fileManager.fileExists(atPath: fileUrl.path) {
            if let data = try? Data(contentsOf: fileUrl), let image = UIImage(data: data) {
                DispatchQueue.main.async {
                    self.currentBackdrop = image
                }
                return
            }
        }
        
        // 2. Fetch from Internet (Fanart.tv)
        // Note: Fanart.tv API ideally needs MusicBrainz Artist ID (MBID). 
        // We'll attempt a name-based search or fallback to a simple search if MBID is unavailable.
        // For this implementation, we'll use a placeholder logic that would ideally fetch from a service.
        
        // Placeholder: Since we don't have MBIDs easily, we'll try a search-based approach or 
        // use a high-quality placeholder for now to demonstrate the caching.
        
        // Real implementation would hit: https://webservice.fanart.tv/v3/music/\(mbid)?api_key=\(fanartApiKey)
        
        // For demonstration of "Permanent Cache", I'll implement the download logic.
        // I will use a high-quality search service or just a placeholder for now.
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }
    
    func saveImage(_ image: UIImage, for artist: String) {
        let fileName = sanitizeFileName(artist) + ".jpg"
        let fileUrl = cacheDirectory.appendingPathComponent(fileName)
        
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: fileUrl)
        }
    }
}
