import Foundation

struct SubsonicResponse: Codable {
    let subsonicResponse: SubsonicBody?
    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SubsonicBody: Codable {
    let status: String
    let version: String
    let error: SubsonicError?
    let albumList: AlbumList?
    let albumList2: AlbumList?
    let artists: ArtistsIndex?
    let album: SubsonicAlbumDetail?
    let song: SubsonicSong?
    let searchResult3: SearchResult3?
    let playlists: PlaylistsWrapper?
    let playlist: PlaylistWrapper?
    let randomSongs: RandomSongsWrapper?
    let randomSongs2: RandomSongsWrapper?
    let recentlyPlayed: RecentlyPlayedWrapper?
    let lyrics: SubsonicLyrics?
    let artist: SubsonicArtistDetail?
    let artistInfo: SubsonicArtistInfo?
    let artistInfo2: SubsonicArtistInfo?
}

struct RecentlyPlayedWrapper: Codable {
    let song: [SubsonicSong]?
}

struct SubsonicAlbumDetail: Codable {
    let id: String
    let name: String?
    let song: [SubsonicSong]?
}

struct SubsonicSong: Codable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Int?
    let coverArt: String?
    let artistId: String?
    let albumId: String?
    let starred: String?
    let playCount: Int?
}

struct SubsonicError: Codable {
    let code: Int
    let message: String
}

struct AlbumList: Codable {
    let album: [SubsonicAlbum]?
}

struct SubsonicAlbum: Codable {
    let id: String
    let name: String?
    let title: String?
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
}

struct ArtistsIndex: Codable {
    let index: [ArtistIndexNode]?
}

struct ArtistIndexNode: Codable {
    let name: String
    let artist: [SubsonicArtist]?
}

struct SubsonicArtist: Codable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
}

struct SubsonicArtistDetail: Codable {
    let id: String
    let name: String
    let album: [SubsonicAlbum]?
}

struct SubsonicLyrics: Codable {
    let artist: String?
    let title: String?
    let value: String?
}

struct PlaylistsWrapper: Codable {
    let playlist: [SubsonicPlaylist]?
}

struct SubsonicPlaylist: Codable {
    let id: String
    let name: String
    let owner: String?
    let songCount: Int?
    let duration: Int?
}

struct PlaylistWrapper: Codable {
    let id: String
    let name: String
    let songCount: Int?
    let entry: [SubsonicSong]?
}

struct RandomSongsWrapper: Codable {
    let song: [SubsonicSong]?
}

struct SearchResult3: Codable {
    let artist: [SubsonicArtist]?
    let album: [SubsonicAlbum]?
    let song: [SubsonicSong]?
}

struct SubsonicArtistInfo: Codable {
    let biography: String?
    let musicBrainzId: String?
    let lastFmUrl: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
}
