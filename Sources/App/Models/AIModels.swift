import Foundation

struct EnrichedMetadata: Codable {
    let id: String?
    let genre: String
    let mood: String
    let release_year: Int
    let style: String?
    let description: String?
}
