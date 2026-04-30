import SwiftUI
import Foundation

struct MBArtistInfo {
    let mbid: String
    let country: String?
    let type: String?
    let lifeSpan: String?
    let area: String?
    let disambiguation: String?
    let annotation: String?
}

struct MBAlbumInfo {
    let mbid: String
    let firstReleaseDate: String?
    let label: String?
    let barcode: String?
    let annotation: String?
}

class MusicBrainzManager: ObservableObject {
    static let shared = MusicBrainzManager()
    
    @Published var currentArtistInfo: MBArtistInfo? = nil
    @Published var currentAlbumInfo: MBAlbumInfo? = nil
    @Published var isLoading = false
    @Published var metadataProgress: Double = 0.0
    
    private let fileManager = FileManager.default
    private let metadataDir: URL
    private let userAgent = "VeloraApp/1.0 ( https://github.com/Firehawk39/Velora-Swift )"
    
    init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        metadataDir = docs.appendingPathComponent("Metadata", isDirectory: true)
        
        if !fileManager.fileExists(atPath: metadataDir.path) {
            try? fileManager.createDirectory(at: metadataDir, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    func fetchAboutArtist(artistName: String, mbid: String? = nil) {
        DispatchQueue.main.async { 
            self.isLoading = true
            self.metadataProgress = 0.1
        }
        
        let fetchDetails = { (resolvedMBID: String) in
            DispatchQueue.main.async { self.metadataProgress = 0.4 }
            let fileName = "artist_" + (resolvedMBID) + ".json"
            let fileUrl = self.metadataDir.appendingPathComponent(fileName)
            
            // Check disk cache
            if self.fileManager.fileExists(atPath: fileUrl.path),
               let data = try? Data(contentsOf: fileUrl),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                let life = json["life-span"] as? [String: Any]
                let begin = life?["begin"] as? String
                let end = life?["end"] as? String
                let lifeStr = begin != nil ? "\(begin!)\(end != nil ? " to \(end!)" : " — Present")" : nil
                
                let info = MBArtistInfo(
                    mbid: resolvedMBID,
                    country: json["country"] as? String,
                    type: json["type"] as? String,
                    lifeSpan: lifeStr,
                    area: (json["area"] as? [String: Any])?["name"] as? String,
                    disambiguation: json["disambiguation"] as? String,
                    annotation: json["annotation"] as? String
                )
                DispatchQueue.main.async { 
                    self.currentArtistInfo = info
                    self.metadataProgress = 1.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.isLoading = false
                    }
                }
                return
            }

            let urlString = "https://musicbrainz.org/ws/2/artist/\(resolvedMBID)?fmt=json&inc=aliases+tags"
            guard let url = URL(string: urlString) else { return }
            
            var request = URLRequest(url: url)
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
            
            URLSession.shared.dataTask(with: request) { data, _, _ in
                DispatchQueue.main.async { self.metadataProgress = 0.7 }
                guard let data = data,
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { 
                    DispatchQueue.main.async { self.isLoading = false }
                    return 
                }
                
                let life = json["life-span"] as? [String: Any]
                let begin = life?["begin"] as? String
                let end = life?["end"] as? String
                let lifeStr = begin != nil ? "\(begin!)\(end != nil ? " to \(end!)" : " — Present")" : nil
                
                self.fetchAnnotation(entityMBID: resolvedMBID) { annotation in
                    json["annotation"] = annotation
                    // Save to disk
                    if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                        try? savedData.write(to: fileUrl)
                    }

                    let info = MBArtistInfo(
                        mbid: resolvedMBID,
                        country: json["country"] as? String,
                        type: json["type"] as? String,
                        lifeSpan: lifeStr,
                        area: (json["area"] as? [String: Any])?["name"] as? String,
                        disambiguation: json["disambiguation"] as? String,
                        annotation: annotation
                    )
                    
                    DispatchQueue.main.async { 
                        self.currentArtistInfo = info
                        self.metadataProgress = 1.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.isLoading = false
                        }
                    }
                }
            }.resume()
        }
        
        if let mbid = mbid, !mbid.isEmpty {
            fetchDetails(mbid)
        } else {
            resolveMBID(for: artistName) { resolved in
                if let resolved = resolved {
                    fetchDetails(resolved)
                } else {
                    DispatchQueue.main.async { self.isLoading = false }
                }
            }
        }
    }
    
    func fetchAboutAlbum(albumName: String, artistName: String, mbid: String? = nil) {
        self.isLoading = true
        
        let fetchDetails = { (resolvedMBID: String) in
            let fileName = "album_" + (resolvedMBID) + ".json"
            let fileUrl = self.metadataDir.appendingPathComponent(fileName)
            
            if self.fileManager.fileExists(atPath: fileUrl.path),
               let data = try? Data(contentsOf: fileUrl),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                let labels = json["label-info"] as? [[String: Any]]
                let labelName = (labels?.first?["label"] as? [String: Any])?["name"] as? String
                
                let info = MBAlbumInfo(
                    mbid: resolvedMBID,
                    firstReleaseDate: json["date"] as? String,
                    label: labelName,
                    barcode: json["barcode"] as? String,
                    annotation: json["annotation"] as? String
                )
                DispatchQueue.main.async { 
                    self.currentAlbumInfo = info
                    self.isLoading = false
                }
                return
            }

            let urlString = "https://musicbrainz.org/ws/2/release/\(resolvedMBID)?fmt=json&inc=labels+recordings"
            guard let url = URL(string: urlString) else { return }
            
            var request = URLRequest(url: url)
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
            
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    DispatchQueue.main.async { self.isLoading = false }
                    return
                }
                
                let labels = json["label-info"] as? [[String: Any]]
                let labelName = (labels?.first?["label"] as? [String: Any])?["name"] as? String
                
                self.fetchAnnotation(entityMBID: resolvedMBID) { annotation in
                    json["annotation"] = annotation
                    // Save to disk
                    if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                        try? savedData.write(to: fileUrl)
                    }

                    let info = MBAlbumInfo(
                        mbid: resolvedMBID,
                        firstReleaseDate: json["date"] as? String,
                        label: labelName,
                        barcode: json["barcode"] as? String,
                        annotation: annotation
                    )
                    
                    DispatchQueue.main.async { 
                        self.currentAlbumInfo = info
                        self.isLoading = false
                    }
                }
            }.resume()
        }
        
        if let mbid = mbid, !mbid.isEmpty {
            fetchDetails(mbid)
        } else {
            resolveAlbumMBID(album: albumName, artist: artistName) { resolved in
                if let resolved = resolved {
                    fetchDetails(resolved)
                } else {
                    DispatchQueue.main.async { self.isLoading = false }
                }
            }
        }
    }
    
    private func resolveMBID(for artist: String, completion: @escaping (String?) -> Void) {
        let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=artist:\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let artists = json["artists"] as? [[String: Any]],
               let first = artists.first {
                completion(first["id"] as? String)
            } else {
                completion(nil)
            }
        }.resume()
    }
    
    private func resolveAlbumMBID(album: String, artist: String, completion: @escaping (String?) -> Void) {
        let query = "release:\(album) AND artist:\(artist)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let releases = json["releases"] as? [[String: Any]],
               let first = releases.first {
                completion(first["id"] as? String)
            } else {
                completion(nil)
            }
        }.resume()
    }
    
    private func fetchAnnotation(entityMBID: String, completion: @escaping (String?) -> Void) {
        let urlString = "https://musicbrainz.org/ws/2/annotation/?query=entity:\(entityMBID)&fmt=json"
        guard let url = URL(string: urlString) else { completion(nil); return }
        
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let annotations = json["annotations"] as? [[String: Any]],
               let first = annotations.first {
                completion(first["text"] as? String)
            } else {
                completion(nil)
            }
        }.resume()
    }

    // MARK: - Silent Bulk Fetchers

    func downloadMetadataSilently(for artistName: String) async {
        let resolved = await resolveMBIDAsync(for: artistName)
        guard let mbid = resolved else { return }
        
        let fileName = "artist_" + (mbid) + ".json"
        let fileUrl = self.metadataDir.appendingPathComponent(fileName)
        
        if self.fileManager.fileExists(atPath: fileUrl.path) { return }

        let urlString = "https://musicbrainz.org/ws/2/artist/\(mbid)?fmt=json&inc=aliases+tags"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            let annotation = await fetchAnnotationAsync(entityMBID: mbid)
            json["annotation"] = annotation
            if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                try? savedData.write(to: fileUrl)
            }
        } catch { }
    }

    func downloadAlbumMetadataSilently(albumName: String, artistName: String) async {
        let resolved = await resolveAlbumMBIDAsync(album: albumName, artist: artistName)
        guard let mbid = resolved else { return }
        
        let fileName = "album_" + (mbid) + ".json"
        let fileUrl = self.metadataDir.appendingPathComponent(fileName)
        
        if self.fileManager.fileExists(atPath: fileUrl.path) { return }

        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?fmt=json&inc=labels+recordings"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            let annotation = await fetchAnnotationAsync(entityMBID: mbid)
            json["annotation"] = annotation
            if let savedData = try? JSONSerialization.data(withJSONObject: json) {
                try? savedData.write(to: fileUrl)
            }
        } catch { }
    }
    
    private func resolveMBIDAsync(for artist: String) async -> String? {
        let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/artist/?query=artist:\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let artists = json?["artists"] as? [[String: Any]]
            return artists?.first?["id"] as? String
        } catch { return nil }
    }
    
    private func resolveAlbumMBIDAsync(album: String, artist: String) async -> String? {
        let query = "release:\(album) AND artist:\(artist)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let releases = json?["releases"] as? [[String: Any]]
            return releases?.first?["id"] as? String
        } catch { return nil }
    }
    
    private func fetchAnnotationAsync(entityMBID: String) async -> String? {
        let urlString = "https://musicbrainz.org/ws/2/annotation/?query=entity:\(entityMBID)&fmt=json"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let annotations = json?["annotations"] as? [[String: Any]]
            return annotations?.first?["text"] as? String
        } catch { return nil }
    }
}
