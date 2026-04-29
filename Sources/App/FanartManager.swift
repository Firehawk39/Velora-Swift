import SwiftUI
import Foundation

class FanartManager: ObservableObject {
    static let shared = FanartManager()
    
    @Published var currentBackdrop: UIImage? = nil
    @Published var cachedArtistImages: [String: UIImage] = [:]
    
    private let fileManager = FileManager.default
    private let backdropDir: URL
    private let portraitDir: URL
    
    // Fanart.tv API Key
    private let fanartApiKey = "53406560946a364a51e608034d67394c" 
    
    init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        backdropDir = docs.appendingPathComponent("Backdrops", isDirectory: true)
        portraitDir = docs.appendingPathComponent("ArtistPortraits", isDirectory: true)
        
        [backdropDir, portraitDir].forEach { dir in
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            }
        }
    }
    
    // MARK: - Backdrops
    
    func fetchBackdrop(for artist: String) {
        let fileName = sanitizeFileName(artist) + ".jpg"
        let fileUrl = backdropDir.appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            DispatchQueue.main.async { self.currentBackdrop = image }
            return
        }
        
        // Fallback placeholder logic (in a real app, this hits Fanart.tv API)
        downloadAndCache(from: "https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=2000",
                         to: fileUrl) { image in
            DispatchQueue.main.async { self.currentBackdrop = image }
        }
    }
    
    // MARK: - Artist Portraits
    
    func fetchArtistPortrait(for artist: String, completion: @escaping (UIImage?) -> Void) {
        let fileName = sanitizeFileName(artist) + ".jpg"
        let fileUrl = portraitDir.appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            completion(image)
            return
        }
        
        // Fetch from Fanart.tv / high-quality source
        // Using a high-quality artist-related search placeholder for demo
        let searchUrl = "https://images.unsplash.com/photo-1511735111819-9a3f7709049c?q=80&w=1000"
        
        downloadAndCache(from: searchUrl, to: fileUrl, completion: completion)
    }
    
    // MARK: - Helpers
    
    private func downloadAndCache(from urlString: String, to localUrl: URL, completion: @escaping (UIImage?) -> Void) {
        guard let url = URL(string: urlString) else { return }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                try? data.write(to: localUrl)
                DispatchQueue.main.async { completion(image) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }
}
