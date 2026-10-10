import XCTest

final class ModelTests: XCTestCase {

    func extractArtId(from serverUrlOrId: String) -> String {
        if serverUrlOrId.contains("getCoverArt"),
           let url = URL(string: serverUrlOrId),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value {
            return idParam
        }
        return serverUrlOrId
    }

    func formatDuration(_ duration: Int?) -> String {
        guard let duration = duration else { return "0:00" }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func extractArtists(from artistString: String?) -> [String] {
        guard let artist = artistString else { return ["Unknown Artist"] }
        var temp = artist
        let textDelimiters = [" feat.", " ft.", " featuring ", " x ", " vs."]
        for delim in textDelimiters {
            temp = temp.replacingOccurrences(of: delim, with: "|||", options: .caseInsensitive)
        }
        let list = temp.components(separatedBy: "|||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return list.isEmpty ? [artist] : list
    }

    func testExtractArtIdFromRawId() {
        let rawId = "al-4821"
        XCTAssertEqual(extractArtId(from: rawId), "al-4821")
    }

    func testExtractArtIdFromServerUrl() {
        let urlString = "https://navidrome.example.com/rest/getCoverArt.view?id=al-4821&u=test&t=abc&s=123&size=500"
        XCTAssertEqual(extractArtId(from: urlString), "al-4821")
    }

    func testDurationFormatting() {
        XCTAssertEqual(formatDuration(nil), "0:00")
        XCTAssertEqual(formatDuration(0), "0:00")
        XCTAssertEqual(formatDuration(45), "0:45")
        XCTAssertEqual(formatDuration(60), "1:00")
        XCTAssertEqual(formatDuration(214), "3:34")
        XCTAssertEqual(formatDuration(3605), "60:05")
    }

    func testArtistSplittingWithFeatures() {
        let artists = extractArtists(from: "Daft Punk feat. Pharrell Williams x Nile Rodgers")
        XCTAssertEqual(artists, ["Daft Punk", "Pharrell Williams", "Nile Rodgers"])
    }

    func testArtistSplittingSingleArtist() {
        let artists = extractArtists(from: "The Weeknd")
        XCTAssertEqual(artists, ["The Weeknd"])
    }

    func testArtistSplittingNilArtist() {
        let artists = extractArtists(from: nil)
        XCTAssertEqual(artists, ["Unknown Artist"])
    }
}
