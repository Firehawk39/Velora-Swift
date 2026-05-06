import Foundation

struct FileHelper {
    /// Sanitizes a string for use as a filename by removing punctuation and replacing spaces with underscores.
    static func sanitize(_ name: String) -> String {
        return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
            .components(separatedBy: .whitespaces).joined(separator: "_")
            .lowercased()
    }
    
    /// Generates a standardized base filename for album metadata (without extension).
    static func albumMetadataBaseName(albumName: String, artistName: String) -> String {
        let safeAlbum = sanitize(albumName)
        let safeArtist = sanitize(artistName)
        return "album_\(safeArtist)_\(safeAlbum)"
    }
    
    /// Generates a standardized filename for album metadata (with .json extension).
    static func albumMetadataFilename(albumName: String, artistName: String) -> String {
        return albumMetadataBaseName(albumName: albumName, artistName: artistName) + ".json"
    }
    
    /// Generates a standardized base filename for artist metadata (without extension).
    static func artistMetadataBaseName(mbid: String) -> String {
        return "artist_\(mbid)"
    }
    
    /// Generates a standardized filename for artist metadata (with .json extension).
    static func artistMetadataFilename(mbid: String) -> String {
        return artistMetadataBaseName(mbid: mbid) + ".json"
    }
    
    /// Generates a standardized filename for artist backdrops (with .jpg extension).
    static func artistBackdropFilename(artistName: String) -> String {
        return sanitize(artistName) + ".jpg"
    }
    
    /// Generates a standardized filename for artist portraits (with .jpg extension).
    static func artistPortraitFilename(artistName: String) -> String {
        return sanitize(artistName) + ".jpg"
    }
    /// List of supported audio extensions for track files.
    static let supportedAudioExtensions = ["flac", "mp3", "m4a", "wav"]
    
    /// Finds the existing local URL for a track ID by checking supported extensions in the documents directory.
    static func getTrackLocalURL(for trackId: String) -> URL? {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        
        for ext in supportedAudioExtensions {
            let url = docs.appendingPathComponent("\(trackId).\(ext)")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Generates the destination URL for a track file with a specific extension.
    static func getTrackDestinationURL(for trackId: String, extension ext: String) -> URL? {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent("\(trackId).\(ext)")
    }

    /// Checks if the given extension is supported for audio tracks.
    static func isSupportedAudioExtension(_ ext: String) -> Bool {
        return supportedAudioExtensions.contains(ext.lowercased())
    }
}
