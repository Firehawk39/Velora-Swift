import SwiftUI
import Foundation

class ArtistDataManager: ObservableObject {
    static let shared = ArtistDataManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // API Keys (Placeholders)
    private let fanartApiKey = "53406560946a364a51e608034d67394c"
    private let lastfmApiKey = "71a815a5196328319f6645a2789196b0"
    
    init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDirectory = docs.appendingPathComponent("ArtistData", isDirectory: true)
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Create subdirectories
        let subs = ["Backdrops", "Portraits", "Bios"]
        for sub in subs {
            let subUrl = cacheDirectory.appendingPathComponent(sub)
            if !fileManager.fileExists(atPath: subUrl.path) {
                try? fileManager.createDirectory(at: subUrl, withIntermediateDirectories: true, attributes: nil)
            }
        }
    }
    
    // MARK: - Public API
    
    func getBackdrop(for artist: String, completion: @escaping (UIImage?) -> Void) {
        fetchImage(for: artist, type: "Backdrops", completion: completion)
    }
    
    func getPortrait(for artist: String, completion: @escaping (UIImage?) -> Void) {
        fetchImage(for: artist, type: "Portraits", completion: completion)
    }
    
    func getBio(for artist: String, completion: @escaping (String?) -> Void) {
        let fileName = sanitize(artist) + ".txt"
        let fileUrl = cacheDirectory.appendingPathComponent("Bios").appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path) {
            if let bio = try? String(contentsOf: fileUrl) {
                completion(bio)
                return
            }
        }
        
        // Fetch from Last.fm
        let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://ws.audioscrobbler.com/2.0/?method=artist.getinfo&artist=\(encodedArtist)&api_key=\(lastfmApiKey)&format=json"
        
        URLSession.shared.dataTask(with: URL(string: urlString)!) { data, _, _ in
            guard let data = data else {
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let artistJson = json["artist"] as? [String: Any],
                   let bioJson = artistJson["bio"] as? [String: Any],
                   let content = bioJson["content"] as? String {
                    
                    let cleanBio = content.components(separatedBy: " <a href=").first ?? content
                    try? cleanBio.write(to: fileUrl, atomically: true, encoding: .utf8)
                    
                    DispatchQueue.main.async {
                        completion(cleanBio)
                    }
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }.resume()
    }
    
    // MARK: - Helpers
    
    private func fetchImage(for artist: String, type: String, completion: @escaping (UIImage?) -> Void) {
        let fileName = sanitize(artist) + ".jpg"
        let fileUrl = cacheDirectory.appendingPathComponent(type).appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path) {
            if let data = try? Data(contentsOf: fileUrl), let image = UIImage(data: data) {
                completion(image)
                return
            }
        }
        
        // Fetch logic placeholder
        // In a real app, this would hit Fanart.tv API
        // For this demo, we'll use a high-quality search proxy or placeholder
        let searchUrl = (type == "Backdrops") 
            ? "https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=2000"
            : "https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?q=80&w=1000"
        
        URLSession.shared.dataTask(with: URL(string: searchUrl)!) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                try? data.write(to: fileUrl)
                DispatchQueue.main.async {
                    completion(image)
                }
            } else {
                completion(nil)
            }
        }.resume()
    }
    
    private func sanitize(_ name: String) -> String {
        return name.lowercased().replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "")
    }
}
