import XCTest

final class IntegrityTests: XCTestCase {

    struct DownloadIndex: Codable {
        var version: Int = 1
        var tracks: [String: TrackStatus] = [:]
    }

    struct TrackStatus: Codable {
        let id: String
        let fileName: String
        let fileSize: Int64
        let downloadDate: Date
    }

    struct VeloraCredentialsBundle: Codable {
        var serverUrl: String
        var onlineServerUrl: String
        var username: String
        var connectionMode: Int
    }

    func testDownloadIndexJSONRoundTrip() throws {
        var index = DownloadIndex()
        let status = TrackStatus(
            id: "trk-001",
            fileName: "song.flac",
            fileSize: 42_000_000,
            downloadDate: Date(timeIntervalSince1970: 1700000000)
        )
        index.tracks["trk-001"] = status

        let encoded = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(DownloadIndex.self, from: encoded)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.tracks.count, 1)
        XCTAssertEqual(decoded.tracks["trk-001"]?.id, "trk-001")
        XCTAssertEqual(decoded.tracks["trk-001"]?.fileName, "song.flac")
        XCTAssertEqual(decoded.tracks["trk-001"]?.fileSize, 42_000_000)
    }

    func testCredentialsBundleRoundTrip() throws {
        let bundle = VeloraCredentialsBundle(
            serverUrl: "http://home-server:4533",
            onlineServerUrl: "https://music.remote.com",
            username: "audio_fan",
            connectionMode: 1
        )

        let encoded = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(VeloraCredentialsBundle.self, from: encoded)

        XCTAssertEqual(decoded.serverUrl, "http://home-server:4533")
        XCTAssertEqual(decoded.onlineServerUrl, "https://music.remote.com")
        XCTAssertEqual(decoded.username, "audio_fan")
        XCTAssertEqual(decoded.connectionMode, 1)
    }

    struct VeloraBackup: Codable {
        var version: Int = 1
        var exportedAt: Date = Date()
        var serverUrl: String
        var onlineServerUrl: String
        var username: String
        var connectionMode: Int
        var fanartApiKey: String?
        var downloadIndex: DownloadIndex?
    }

    func testVeloraBackupRoundTripPreservesFanartKey() throws {
        let backup = VeloraBackup(
            version: 1,
            exportedAt: Date(timeIntervalSince1970: 1700000000),
            serverUrl: "http://192.168.1.100:4533",
            onlineServerUrl: "https://velora.mycloud.com",
            username: "hifi_user",
            connectionMode: 0,
            fanartApiKey: "custom_user_fanart_secret_key_123",
            downloadIndex: DownloadIndex()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VeloraBackup.self, from: data)

        XCTAssertEqual(decoded.serverUrl, "http://192.168.1.100:4533")
        XCTAssertEqual(decoded.fanartApiKey, "custom_user_fanart_secret_key_123")
        XCTAssertEqual(decoded.username, "hifi_user")
    }
}
