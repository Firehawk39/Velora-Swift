import Foundation
import SwiftUI

// MARK: - Core Application Models

struct Artist: Identifiable, Codable {
    let id: String
    let name: String
    var albumCount: Int?
    var coverArt: String?
    var created: String?
    
    // Enriched Metadata
    var area: String?
    var type: String?
    var lifeSpan: String?
    
    // Convenience computed URL
    var coverArtUrl: URL? { coverArt.flatMap { URL(string: $0) } }
}

struct Album: Identifiable, Codable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    var created: String?
    
    // Enriched Metadata
    var recordLabel: String?
    var firstReleaseDate: String?
    
    var coverArtUrl: URL? { coverArt.flatMap { URL(string: $0) } }
}

struct Track: Identifiable, Codable, Equatable {
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
    
    var coverArtUrl: URL? { coverArt.flatMap { URL(string: $0) } }
    
    var durationFormatted: String {
        guard let duration = duration else { return "0:00" }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct Playlist: Identifiable, Codable {
    let id: String
    let name: String
    let owner: String?
    let songCount: Int?
    let duration: Int?
    var created: String?
}


// Models.swift remains for high-level app models. Subsonic and AI specific models are in their respective files.

