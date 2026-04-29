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
        
        let queryFanart = { (resolvedMBID: String) in
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .background) { url in
                if let url = url {
                    self.downloadAndCache(from: url, to: fileUrl) { image in
                        DispatchQueue.main.async { self.currentBackdrop = image }
                    }
                } else {
                    DispatchQueue.main.async { self.currentBackdrop = nil }
                }
            }
        }
        
        // 2. Fetch from Fanart.tv
        guard let validMBID = mbid, !validMBID.isEmpty else {
            self.getMBID(for: artist) { resolved in
                if let resolved = resolved {
                    queryFanart(resolved)
                } else {
                    DispatchQueue.main.async { self.currentBackdrop = nil }
                }
            }
            return
        }
        
        let originalUrlString = "https://webservice.fanart.tv/v3/music/\(validMBID)?api_key=\(fanartApiKey)"
        self.fetchFromFanart(urlString: originalUrlString, type: .background) { url in
            if let url = url {
                self.downloadAndCache(from: url, to: fileUrl) { image in
                    DispatchQueue.main.async { self.currentBackdrop = image }
                }
            } else {
                self.getMBID(for: artist) { resolved in
                    if let resolved = resolved, resolved != validMBID {
                        queryFanart(resolved)
                    } else {
                        DispatchQueue.main.async { self.currentBackdrop = nil }
                    }
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
        
        let queryFanartPortrait = { (resolvedMBID: String) in
            let urlString = "https://webservice.fanart.tv/v3/music/\(resolvedMBID)?api_key=\(self.fanartApiKey)"
            self.fetchFromFanart(urlString: urlString, type: .portrait) { url in
                if let url = url {
                    self.downloadAndCache(from: url, to: fileUrl, completion: completion)
                } else {
                    completion(nil)
                }
            }
        }
        
        guard let validMBID = mbid, !validMBID.isEmpty else {
            self.getMBID(for: artist) { resolved in
                if let resolved = resolved {
                    queryFanartPortrait(resolved)
                } else {
                    completion(nil)
                }
            }
            return
        }
        
        let originalUrlString = "https://webservice.fanart.tv/v3/music/\(validMBID)?api_key=\(fanartApiKey)"
        self.fetchFromFanart(urlString: originalUrlString, type: .portrait) { url in
            if let url = url {
                self.downloadAndCache(from: url, to: fileUrl, completion: completion)
            } else {
                self.getMBID(for: artist) { resolved in
                    if let resolved = resolved, resolved != validMBID {
                        queryFanartPortrait(resolved)
                    } else {
                        completion(nil)
                    }
                }
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
    
    private func extractPrimaryArtist(_ name: String) -> String {
        let delimiters = [",", "&", "feat.", "ft.", " x ", " vs.", " and "]
        var primary = name
        for delimiter in delimiters {
            if let range = primary.range(of: delimiter, options: .caseInsensitive) {
                primary = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return primary.isEmpty ? name : primary
    }

    private func getMBID(for artistName: String, completion: @escaping (String?) -> Void) {
        let primary = extractPrimaryArtist(artistName)
        let encodedName = primary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=artist:\(encodedName)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue("VeloraApp/1.0", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let artists = json["artists"] as? [[String: Any]],
               let firstArtist = artists.first,
               let id = firstArtist["id"] as? String {
                completion(id)
            } else {
                completion(nil)
            }
        }.resume()
    }
}
