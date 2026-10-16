import XCTest

final class ModelTests: XCTestCase {

    func extractArtId(from serverUrlOrId: String) -> String {
        let trimmed = serverUrlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains("getCoverArt"),
           let url = URL(string: trimmed),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value,
           !idParam.isEmpty {
            return extractArtId(from: idParam)
        }

        if trimmed.hasPrefix("file://") || trimmed.contains("/") || trimmed.contains("\\") {
            let lastComponent: String
            if let url = URL(string: trimmed), url.isFileURL || trimmed.hasPrefix("file://") {
                lastComponent = url.lastPathComponent
            } else {
                lastComponent = (trimmed as NSString).lastPathComponent
            }
            let clean = (lastComponent as NSString).deletingPathExtension
            let decoded = clean.removingPercentEncoding ?? clean
            return decoded
        }

        let ext = (trimmed as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp"].contains(ext) {
            return (trimmed as NSString).deletingPathExtension
        }

        return trimmed
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

    func testExtractArtIdFromFileUrl() {
        let fileUrlString = "file:///var/mobile/Containers/Data/Application/A451EA35-EC4D-4489-B437-61AAC3961B1C/Library/Application%20Support/VeloraData/CoverArt/al-1YKjT5LRaMRazRggzvz1Da_d524f0cf798afd50.jpg"
        XCTAssertEqual(extractArtId(from: fileUrlString), "al-1YKjT5LRaMRazRggzvz1Da_d524f0cf798afd50")
    }

    func testExtractArtIdFromLocalPath() {
        let pathString = "/var/mobile/Containers/Data/Application/A451EA35-EC4D-4489-B437-61AAC3961B1C/Library/Application Support/VeloraData/CoverArt/al-1YKjT5LRaMRazRggzvz1Da_d524f0cf798afd50.jpg"
        XCTAssertEqual(extractArtId(from: pathString), "al-1YKjT5LRaMRazRggzvz1Da_d524f0cf798afd50")
    }

    func testExtractArtIdFromFilenameWithExtension() {
        let filename = "al-1YKjT5LRaMRazRggzvz1Da_d524f0cf798afd50.jpg"
        XCTAssertEqual(extractArtId(from: filename), "al-1YKjT5LRaMRazRggzvz1Da_d524f0cf798afd50")
    }

    func testExtractArtIdFromNestedQueryParam() {
        let nestedUrl = "https://navidrome.example.com/rest/getCoverArt.view?id=file%3A%2F%2F%2Fvar%2Fmobile%2FContainers%2FData%2FApplication%2F...%2Fal-999.jpg&size=500"
        XCTAssertEqual(extractArtId(from: nestedUrl), "al-999")
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
