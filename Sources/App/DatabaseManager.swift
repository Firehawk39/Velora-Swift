import Foundation
import SQLite3
import os.log

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.velora.db", qos: .userInitiated)
    private let logger = OSLog(subsystem: "com.velora", category: "DatabaseManager")

    private init() {
        setupDatabase()
    }

    private func setupDatabase() {
        let fileManager = FileManager.default
        let documentsUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbUrl = documentsUrl.appendingPathComponent("velora.sqlite")

        if sqlite3_open(dbUrl.path, &db) != SQLITE_OK {
            os_log("Error opening database", log: logger, type: .error)
            return
        }

        let createTableString = """
        CREATE TABLE IF NOT EXISTS Tracks(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            album TEXT,
            artist TEXT,
            duration INTEGER,
            coverArt TEXT,
            artistId TEXT,
            albumId TEXT,
            created TEXT,
            isStarred INTEGER,
            playCount INTEGER,
            suffix TEXT,
            track INTEGER,
            discNumber INTEGER
        );
        """

        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                os_log("Tracks table created.", log: logger, type: .info)
            } else {
                os_log("Tracks table could not be created.", log: logger, type: .error)
            }
        } else {
            os_log("CREATE TABLE statement could not be prepared.", log: logger, type: .error)
        }
        sqlite3_finalize(createTableStatement)
    }

    func insertOrUpdateTracks(_ tracks: [Track]) {
        queue.async {
            guard let db = self.db else { return }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            let insertStatementString = """
            INSERT INTO Tracks (id, title, album, artist, duration, coverArt, artistId, albumId, created, isStarred, playCount, suffix, track, discNumber)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, album=excluded.album, artist=excluded.artist, duration=excluded.duration, coverArt=excluded.coverArt, artistId=excluded.artistId, albumId=excluded.albumId, created=excluded.created, isStarred=excluded.isStarred, playCount=excluded.playCount, suffix=excluded.suffix, track=excluded.track, discNumber=excluded.discNumber;
            """

            var insertStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
                for track in tracks {
                    sqlite3_bind_text(insertStatement, 1, (track.id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(insertStatement, 2, (track.title as NSString).utf8String, -1, nil)
                    
                    if let album = track.album { sqlite3_bind_text(insertStatement, 3, (album as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(insertStatement, 3) }
                    if let artist = track.artist { sqlite3_bind_text(insertStatement, 4, (artist as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(insertStatement, 4) }
                    if let duration = track.duration { sqlite3_bind_int(insertStatement, 5, Int32(duration)) } else { sqlite3_bind_null(insertStatement, 5) }
                    if let coverArt = track.coverArt { sqlite3_bind_text(insertStatement, 6, (coverArt as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(insertStatement, 6) }
                    if let artistId = track.artistId { sqlite3_bind_text(insertStatement, 7, (artistId as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(insertStatement, 7) }
                    if let albumId = track.albumId { sqlite3_bind_text(insertStatement, 8, (albumId as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(insertStatement, 8) }
                    if let created = track.created { sqlite3_bind_text(insertStatement, 9, (created as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(insertStatement, 9) }
                    
                    sqlite3_bind_int(insertStatement, 10, track.isStarred ? 1 : 0)
                    if let playCount = track.playCount { sqlite3_bind_int(insertStatement, 11, Int32(playCount)) } else { sqlite3_bind_null(insertStatement, 11) }
                    
                    if let suffix = track.suffix { sqlite3_bind_text(insertStatement, 12, (suffix as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(insertStatement, 12) }
                    if let trackNum = track.track { sqlite3_bind_int(insertStatement, 13, Int32(trackNum)) } else { sqlite3_bind_null(insertStatement, 13) }
                    if let discNumber = track.discNumber { sqlite3_bind_int(insertStatement, 14, Int32(discNumber)) } else { sqlite3_bind_null(insertStatement, 14) }

                    if sqlite3_step(insertStatement) != SQLITE_DONE {
                        os_log("Could not insert row.", log: self.logger, type: .error)
                    }
                    sqlite3_reset(insertStatement)
                }
            } else {
                os_log("INSERT statement could not be prepared.", log: self.logger, type: .error)
            }
            sqlite3_finalize(insertStatement)

            sqlite3_exec(db, "COMMIT TRANSACTION", nil, nil, nil)
        }
    }

    func clearTracks() {
        queue.async {
            guard let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM Tracks", nil, nil, nil)
        }
    }

    func getTrack(id: String) -> Track? {
        return queue.sync {
            guard let db = self.db else { return nil }
            let query = "SELECT * FROM Tracks WHERE id = ? LIMIT 1;"
            var statement: OpaquePointer?
            var result: Track?

            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) == SQLITE_ROW {
                    result = parseTrack(statement)
                }
            }
            sqlite3_finalize(statement)
            return result
        }
    }

    func getTracks(albumId: String) -> [Track] {
        return queue.sync {
            guard let db = self.db else { return [] }
            let query = "SELECT * FROM Tracks WHERE albumId = ? ORDER BY discNumber ASC, track ASC;"
            var statement: OpaquePointer?
            var results: [Track] = []

            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (albumId as NSString).utf8String, -1, nil)
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let track = parseTrack(statement) { results.append(track) }
                }
            }
            sqlite3_finalize(statement)
            return results
        }
    }

    func getTracks(artistId: String) -> [Track] {
        return queue.sync {
            guard let db = self.db else { return [] }
            let query = "SELECT * FROM Tracks WHERE artistId = ?;"
            var statement: OpaquePointer?
            var results: [Track] = []

            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (artistId as NSString).utf8String, -1, nil)
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let track = parseTrack(statement) { results.append(track) }
                }
            }
            sqlite3_finalize(statement)
            return results
        }
    }

    func getTrackCount() -> Int {
        return queue.sync {
            guard let db = self.db else { return 0 }
            let query = "SELECT COUNT(*) FROM Tracks;"
            var statement: OpaquePointer?
            var count = 0

            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            return count
        }
    }

    func getAllTracks() -> [Track] {
        return queue.sync {
            guard let db = self.db else { return [] }
            let query = "SELECT * FROM Tracks;"
            var statement: OpaquePointer?
            var results: [Track] = []

            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let track = parseTrack(statement) { results.append(track) }
                }
            }
            sqlite3_finalize(statement)
            return results
        }
    }

    func searchTracks(query text: String) -> [Track] {
        return queue.sync {
            guard let db = self.db else { return [] }
            let query = "SELECT * FROM Tracks WHERE title LIKE ? OR artist LIKE ? OR album LIKE ? LIMIT 50;"
            var statement: OpaquePointer?
            var results: [Track] = []

            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                let searchString = "%\(text)%"
                sqlite3_bind_text(statement, 1, (searchString as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (searchString as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (searchString as NSString).utf8String, -1, nil)

                while sqlite3_step(statement) == SQLITE_ROW {
                    if let track = parseTrack(statement) { results.append(track) }
                }
            }
            sqlite3_finalize(statement)
            return results
        }
    }

    private func parseTrack(_ statement: OpaquePointer?) -> Track? {
        guard let statement = statement else { return nil }

        let id = String(cString: sqlite3_column_text(statement, 0))
        let title = String(cString: sqlite3_column_text(statement, 1))
        
        let album = sqlite3_column_type(statement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 2)) : nil
        let artist = sqlite3_column_type(statement, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 3)) : nil
        let duration = sqlite3_column_type(statement, 4) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 4)) : nil
        let coverArt = sqlite3_column_type(statement, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 5)) : nil
        let artistId = sqlite3_column_type(statement, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 6)) : nil
        let albumId = sqlite3_column_type(statement, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 7)) : nil
        let created = sqlite3_column_type(statement, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 8)) : nil
        
        let isStarred = sqlite3_column_int(statement, 9) != 0
        let playCount = sqlite3_column_type(statement, 10) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 10)) : nil
        let suffix = sqlite3_column_type(statement, 11) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 11)) : nil
        let trackNum = sqlite3_column_type(statement, 12) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 12)) : nil
        let discNumber = sqlite3_column_type(statement, 13) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 13)) : nil

        return Track(id: id, title: title, album: album, artist: artist, duration: duration, coverArt: coverArt, artistId: artistId, albumId: albumId, created: created, isStarred: isStarred, playCount: playCount, suffix: suffix, track: trackNum, discNumber: discNumber)
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
}
