import SwiftUI
import Foundation

class FanartManager: ObservableObject {
    static let shared = FanartManager()
    
    @Published var currentBackdrop: UIImage? = nil
    @Published var cachedArtistImages: [String: UIImage] = [:]
    
    private let fileManager = FileManager.default
    private let backdropDir: URL
    private let portraitDir: URL
    
    // Fanart.tv API Key - Provided by user
    private let fanartApiKey = "faceb56eac838d3e1c2a3ed15bf65a80" 
    
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
    
    func fetchBackdrop(for artist: String, mbid: String? = nil) {
        let fileName = sanitizeFileName(artist) + ".jpg"
        let fileUrl = backdropDir.appendingPathComponent(fileName)
        
        // 1. Check Cache
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            DispatchQueue.main.async { self.currentBackdrop = image }
            return
        }
        
        // 2. Fetch from Fanart.tv if we have an MBID
        guard let mbid = mbid, !mbid.isEmpty else {
            // Fallback placeholder logic if no MBID
            downloadAndCache(from: "https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=2000",
                             to: fileUrl) { image in
                DispatchQueue.main.async { self.currentBackdrop = image }
            }
            return
        }
        
        let urlString = "https://webservice.fanart.tv/v3/music/\(mbid)?api_key=\(fanartApiKey)"
        fetchFromFanart(urlString: urlString, type: .background) { url in
            if let url = url {
                self.downloadAndCache(from: url, to: fileUrl) { image in
                    DispatchQueue.main.async { self.currentBackdrop = image }
                }
            }
        }
    }
    
    // MARK: - Artist Portraits
    
    func fetchArtistPortrait(for artist: String, mbid: String? = nil, completion: @escaping (UIImage?) -> Void) {
        let fileName = sanitizeFileName(artist) + ".jpg"
        let fileUrl = portraitDir.appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = UIImage(data: data) {
            completion(image)
            return
        }
        
        guard let mbid = mbid, !mbid.isEmpty else {
            let searchUrl = "https://images.unsplash.com/photo-1511735111819-9a3f7709049c?q=80&w=1000"
            downloadAndCache(from: searchUrl, to: fileUrl, completion: completion)
            return
        }
        
        let urlString = "https://webservice.fanart.tv/v3/music/\(mbid)?api_key=\(fanartApiKey)"
        fetchFromFanart(urlString: urlString, type: .portrait) { url in
            if let url = url {
                self.downloadAndCache(from: url, to: fileUrl, completion: completion)
            } else {
                completion(nil)
            }
        }
    }
    
    // MARK: - API Helpers
    
    private enum FanartType { case background, portrait }
    
    private func fetchFromFanart(urlString: String, type: FanartType, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data else { completion(nil); return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if type == .background {
                        if let bgs = json["artistbackground"] as? [[String: Any]], 
                           let selected = bgs.randomElement()?["url"] as? String {
                            completion(selected); return
                        }
                    } else {
                        if let thumbs = json["artistthumb"] as? [[String: Any]], 
                           let first = thumbs.first?["url"] as? String {
                            completion(first); return
                        }
                    }
                }
            } catch { print("Fanart JSON error: \(error)") }
            completion(nil)
        }.resume()
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
