import Foundation

struct EnrichedMetadata: Codable {
    let id: String?
    let genre: String
    let mood: String
    let release_year: Int
    let style: String?
    let description: String?
}

enum IssueType: String, Hashable, CaseIterable {
    case missingGenre = "Missing Genre"
    case missingYear = "Missing Year"
    case lowResArt = "Low-Res Art"
    case missingMetadata = "Missing Metadata"
    case missingBackdrop = "Missing Backdrop"
}

struct AuditResult: Identifiable {
    let id = UUID()
    let type: IssueType
    let count: Int
    let description: String
}

struct ArtistInfo {
    let name: String
    var biography: String
    var genres: [String] = []
    var mbid: String? = nil
    var type: String? = nil
    var area: String? = nil
    var lifeSpan: String? = nil
}

struct AlbumInfo {
    let name: String
    var genres: [String] = []
    var mbid: String? = nil
    var label: String? = nil
    var firstReleaseDate: String? = nil
    var annotation: String? = nil
}
