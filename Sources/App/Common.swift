import Foundation
import CryptoKit

// MARK: - Offline Artwork Helper

/// Extracts the actual cover art ID from a server URL string.
/// Server URLs look like: https://server.com/rest/getCoverArt.view?id=al-123&u=user&...
/// Returns just "al-123" for local file lookups.
private func extractArtId(from serverUrlOrId: String) -> String {
    // If it looks like a URL (contains "getCoverArt"), extract the 'id' query parameter
    if serverUrlOrId.contains("getCoverArt"),
       let url = URL(string: serverUrlOrId),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value {
        return idParam
    }
    // Already a plain ID, or unrecognized format — return as-is
    return serverUrlOrId
}

func resolveCoverArtUrl(id: String, serverUrl: String?) -> URL? {
    // Try extracting the real ID from a server URL for local lookup
    let resolvedId = extractArtId(from: id)
    let localUrl = VeloraStorage.coverArt.appendingPathComponent("\(resolvedId).jpg")
    if FileManager.default.fileExists(atPath: localUrl.path) {
        return localUrl
    }
    return serverUrl.flatMap { URL(string: $0) }
}

// MARK: - Models

struct Artist: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    var albumCount: Int?
    var coverArt: String?
    var created: String?
    
    // Convenience computed URL
    var coverArtUrl: URL? { resolveCoverArtUrl(id: id, serverUrl: coverArt) }
}

struct Album: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    var created: String?
    
    var coverArtUrl: URL? { resolveCoverArtUrl(id: coverArt ?? id, serverUrl: coverArt) }
}

struct Track: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let album: String?
    let artist: String?
    let duration: Int?
    let coverArt: String?
    let artistId: String?
    let albumId: String?
    var created: String?
    var isStarred: Bool = false
    var playCount: Int? = 0
    let suffix: String?
    
    var coverArtUrl: URL? { 
        let artId = coverArt ?? albumId ?? id.components(separatedBy: ".").first ?? id
        return resolveCoverArtUrl(id: artId, serverUrl: coverArt)
    }
    
    var durationFormatted: String {
        guard let duration = duration else { return "0:00" }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct Playlist: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let owner: String?
    let songCount: Int?
    let duration: Int?
    var created: String?
}


// MARK: - Authentication Helpers

struct SubsonicAuth {
    static func generateToken(password: String, salt: String) -> String {
        let combined = password + salt
        let data = Data(combined.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    static func generateSalt() -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<10).map { _ in characters.randomElement()! })
    }
}
// MARK: - Extensions

import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
extension View {
    @ViewBuilder
    func hidePersistentSystemOverlays() -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }
}
