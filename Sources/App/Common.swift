import Foundation
import CryptoKit

// MARK: - Offline Artwork Helper

/// Extracts the actual cover art ID from a server URL string.
/// Server URLs look like: https://server.com/rest/getCoverArt.view?id=al-123&u=user&...
/// Returns just "al-123" for local file lookups.
func extractArtId(from serverUrlOrId: String) -> String {
    var raw = serverUrlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }

    // 1. If it's a Navidrome getCoverArt URL, extract the 'id' query parameter
    if raw.contains("getCoverArt"),
       let url = URL(string: raw),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value,
       !idParam.isEmpty {
        raw = idParam
    }

    // 2. If it's a local file URL or file path (e.g. file:///.../CoverArt/al-123.jpg or /path/to/al-123.jpg)
    if raw.hasPrefix("file://") || raw.contains("/") {
        if let url = URL(string: raw), !url.lastPathComponent.isEmpty {
            raw = url.deletingPathExtension().lastPathComponent
        } else {
            let last = (raw as NSString).lastPathComponent
            raw = (last as NSString).deletingPathExtension
        }
    }

    // 3. If it still ends with an image extension (.jpg, .png, etc.), strip it
    for ext in [".jpg", ".jpeg", ".png", ".webp"] {
        if raw.lowercased().hasSuffix(ext) {
            raw = String(raw.dropLast(ext.count))
            break
        }
    }

    return raw
}

import UIKit
import AVFoundation

/// Extracts embedded front-cover artwork directly from the downloaded audio file in VeloraStorage.tracks.
/// Saves the extracted image to VeloraStorage.coverArt/<trackId>.jpg and mirrors to albumId/artId for seamless lookups.
@discardableResult
func extractEmbeddedArtwork(for trackId: String, albumId: String? = nil, artId: String? = nil) -> URL? {
    let fm = FileManager.default
    let coverDir = VeloraStorage.coverArt
    let localArtUrl = coverDir.appendingPathComponent("\(trackId).jpg")
    
    if fm.fileExists(atPath: localArtUrl.path),
       let attr = try? fm.attributesOfItem(atPath: localArtUrl.path),
       let size = attr[.size] as? Int64, size > 100 {
        return localArtUrl
    }
    
    let trackDir = VeloraStorage.tracks
    var audioUrl: URL? = nil
    
    let audioExtensions = ["flac", "mp3", "m4a", "alac", "wav", "aac", "ogg", "opus"]
    for ext in audioExtensions {
        let candidate = trackDir.appendingPathComponent("\(trackId).\(ext)")
        if fm.fileExists(atPath: candidate.path) {
            audioUrl = candidate
            break
        }
    }
    
    // Fallback: check raw trackId directly
    if audioUrl == nil && fm.fileExists(atPath: trackDir.appendingPathComponent(trackId).path) {
        audioUrl = trackDir.appendingPathComponent(trackId)
    }
    
    guard let audioUrl = audioUrl else { return nil }
    
    let asset = AVAsset(url: audioUrl)
    let artworkItems = AVMetadataItem.metadataItems(from: asset.commonMetadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common)
    for item in artworkItems {
        if let data = item.dataValue, !data.isEmpty, UIImage(data: data) != nil {
            try? data.write(to: localArtUrl)
            
            // Mirror to albumId and artId so all lookups succeed instantly
            if let aid = albumId, !aid.isEmpty {
                let cleanAid = extractArtId(from: aid)
                let albumUrl = coverDir.appendingPathComponent("\(cleanAid).jpg")
                if !fm.fileExists(atPath: albumUrl.path) {
                    try? data.write(to: albumUrl)
                }
            }
            if let art = artId, !art.isEmpty {
                let cleanArt = extractArtId(from: art)
                let artUrl = coverDir.appendingPathComponent("\(cleanArt).jpg")
                if !fm.fileExists(atPath: artUrl.path) {
                    try? data.write(to: artUrl)
                }
            }
            return localArtUrl
        }
    }
    return nil
}

func resolveCoverArtUrl(id: String, serverUrl: String?, albumId: String? = nil, trackId: String? = nil) -> URL? {
    let fm = FileManager.default
    let coverDir = VeloraStorage.coverArt
    
    // Comprehensive candidate key collection (resolves song ID, album ID, and server URL keys)
    var candidates = [String]()
    
    func addCandidate(_ raw: String?) {
        guard let raw = raw, !raw.isEmpty else { return }
        let clean = extractArtId(from: raw)
        guard !clean.isEmpty else { return }
        if !candidates.contains(clean) { candidates.append(clean) }
        let alt = clean.hasPrefix("al-") ? String(clean.dropFirst(3)) : ("al-" + clean)
        if !candidates.contains(alt) { candidates.append(alt) }
    }
    
    addCandidate(id)
    addCandidate(serverUrl)
    addCandidate(albumId)
    addCandidate(trackId)
    
    for candidate in candidates {
        for ext in ["jpg", "jpeg", "png"] {
            let localUrl = coverDir.appendingPathComponent("\(candidate).\(ext)")
            if fm.fileExists(atPath: localUrl.path) {
                if let attr = try? fm.attributesOfItem(atPath: localUrl.path),
                   let size = attr[.size] as? Int64, size > 100 {
                    return localUrl // Valid local image
                } else {
                    try? fm.removeItem(at: localUrl) // Purge corrupt 0-byte file
                }
            }
        }
    }
    
    // Offline safety net: if audio file exists locally, extract embedded front-cover artwork
    if let tid = trackId, let embeddedUrl = extractEmbeddedArtwork(for: tid, albumId: albumId, artId: id) {
        return embeddedUrl
    }
    let resolvedId = extractArtId(from: id)
    if let embeddedUrl = extractEmbeddedArtwork(for: resolvedId, albumId: albumId, artId: id) {
        return embeddedUrl
    }

    guard NetworkMonitor.shared.isConnected else { return nil }
    return serverUrl.flatMap { URL(string: $0) }
}

func resolveArtistPortraitUrl(id: String, serverUrl: String?) -> URL? {
    let fm = FileManager.default
    let portraitDir = VeloraStorage.artistPortraits
    let resolvedId = extractArtId(from: id)
    
    var candidates: [String] = [resolvedId]
    if resolvedId.hasPrefix("ar-") {
        candidates.append(String(resolvedId.dropFirst(3)))
    } else {
        candidates.append("ar-" + resolvedId)
    }
    if let sUrl = serverUrl {
        let extractedServerId = extractArtId(from: sUrl)
        if !candidates.contains(extractedServerId) {
            candidates.append(extractedServerId)
        }
    }

    for candidate in candidates {
        for ext in ["jpg", "jpeg", "png"] {
            let localUrl = portraitDir.appendingPathComponent("\(candidate).\(ext)")
            if fm.fileExists(atPath: localUrl.path) {
                if let attr = try? fm.attributesOfItem(atPath: localUrl.path),
                   let size = attr[.size] as? Int64, size > 100 {
                    return localUrl // Valid local image
                } else {
                    try? fm.removeItem(at: localUrl)
                }
            }
        }
    }

    guard NetworkMonitor.shared.isConnected else { return nil }
    return serverUrl.flatMap { URL(string: $0) }
}

// MARK: - Models

let knownBandNamesWithDelimiters: Set<String> = [
    "chase & status",
    "above & beyond",
    "simon & garfunkel",
    "earth, wind & fire",
    "earth wind & fire",
    "brooks & dunn",
    "hall & oates",
    "daryl hall & john oates",
    "mumford & sons",
    "crosby, stills, nash & young",
    "crosby stills nash & young",
    "tom petty and the heartbreakers",
    "florence + the machine",
    "kc & the sunshine band",
    "kool & the gang",
    "angus & julia stone",
    "bob marley & the wailers",
    "captain & tennille",
    "huey lewis & the news",
    "joan jett & the blackhearts",
    "sly & the family stone",
    "toots & the maytals",
    "katrina and the waves",
    "me first and the gimme gimmes",
    "echo & the bunnymen",
    "siouxsie and the banshees",
    "gladys knight & the pips",
    "ziggy marley & the melody makers",
    "frankie lymon & the teenagers",
    "junior walker & the all stars",
    "king gizzard & the lizard wizard",
    "iron & wine",
    "arms and sleepers",
    "blood, sweat & tears",
    "emerson, lake & palmer",
    "peter, paul and mary",
    "sultan + shepard"
]

/// Extracts the clean primary artist name while protecting bands that have delimiters in their name (e.g. "Chase & Status")
/// and properly splitting featuring/collaboration delimiters (e.g. "; ", " feat.", " ft.", " x ", etc.)
func extractPrimaryArtist(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return name }
    let lower = trimmed.lowercased()

    // 1. Direct match with known band
    if knownBandNamesWithDelimiters.contains(lower) {
        return trimmed
    }

    // 2. Check if name starts with any known band followed by a delimiter/space
    for known in knownBandNamesWithDelimiters {
        if lower.hasPrefix(known) {
            let remainder = lower.dropFirst(known.count)
            if remainder.isEmpty || remainder.hasPrefix(" ") || remainder.hasPrefix(";") || remainder.hasPrefix(",") || remainder.hasPrefix("/") || remainder.hasPrefix("•") {
                let index = trimmed.index(trimmed.startIndex, offsetBy: known.count)
                return String(trimmed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // 3. Priority delimiters: Features and guest appearances
    let featureDelimiters = [" feat. ", " feat.", " feat ", " ft. ", " ft.", " ft ", " featuring ", " with "]
    var primary = trimmed
    for delim in featureDelimiters {
        if let range = primary.range(of: delim, options: .caseInsensitive) {
            let candidate = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if knownBandNamesWithDelimiters.contains(candidate.lowercased()) {
                return candidate
            }
            primary = candidate
        }
    }

    // 4. Secondary delimiters: Semicolons (Navidrome multi-artist standard), bullets, slashes, commas, vs, x
    let secondaryDelimiters = ["; ", ";", " • ", "•", "・", " / ", " /", "/ ", "/", ", ", " x ", " vs. ", " vs "]
    for delim in secondaryDelimiters {
        if let range = primary.range(of: delim, options: .caseInsensitive) {
            let candidate = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if knownBandNamesWithDelimiters.contains(candidate.lowercased()) {
                return candidate
            }
            primary = candidate
        }
    }

    // 5. Conjunction delimiters: " & ", " and " (ONLY if not a known band)
    let conjunctionDelimiters = [" & ", " and "]
    for delim in conjunctionDelimiters {
        if let range = primary.range(of: delim, options: .caseInsensitive) {
            let candidate = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if knownBandNamesWithDelimiters.contains(candidate.lowercased()) {
                return candidate
            }
            primary = candidate
        }
    }

    return primary.isEmpty ? trimmed : primary
}

/// Parses all artists from a composite string (including featured artists, co-artists, and Navidrome semicolons)
func parseAllArtistNames(_ name: String) -> [String] {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ["Unknown Artist"] }
    let lower = trimmed.lowercased()

    if knownBandNamesWithDelimiters.contains(lower) {
        return [trimmed]
    }

    // 1. Check known band prefix first (e.g. "Chase & Status feat. Takura")
    for known in knownBandNamesWithDelimiters {
        if lower.hasPrefix(known) {
            let remainder = lower.dropFirst(known.count)
            if remainder.isEmpty || remainder.hasPrefix(" ") || remainder.hasPrefix(";") || remainder.hasPrefix(",") || remainder.hasPrefix("/") || remainder.hasPrefix("•") {
                let bandIndex = trimmed.index(trimmed.startIndex, offsetBy: known.count)
                let bandName = String(trimmed[..<bandIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                var list = [bandName]
                let rest = String(trimmed[bandIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    var tempRest = rest
                    let allDelims = [
                        " feat. ", " feat.", " feat ", " ft. ", " ft.", " ft ", " featuring ", " with ",
                        "; ", ";", " • ", "•", "・", " / ", " /", "/ ", "/", ", ", " x ", " vs. ", " vs ",
                        " & ", " and "
                    ]
                    for d in allDelims {
                        tempRest = tempRest.replacingOccurrences(of: d, with: "|||", options: .caseInsensitive)
                    }
                    let extraParts = tempRest.components(separatedBy: "|||")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    for p in extraParts {
                        if !list.contains(p) { list.append(p) }
                    }
                }
                if !list.contains(trimmed) { list.append(trimmed) }
                return list
            }
        }
    }

    // 2. Standard multi-artist extraction
    var list: [String] = []
    let primary = extractPrimaryArtist(trimmed)
    if !primary.isEmpty {
        list.append(primary)
    }

    var temp = trimmed
    let textDelimiters = [
        " feat. ", " feat.", " feat ", " ft. ", " ft.", " ft ", " featuring ", " with ",
        "; ", ";", " • ", "•", "・", " / ", " /", "/ ", "/", ", ", " x ", " vs. ", " vs ",
        " & ", " and "
    ]
    for delim in textDelimiters {
        temp = temp.replacingOccurrences(of: delim, with: "|||", options: .caseInsensitive)
    }
    let parts = temp.components(separatedBy: "|||")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    for part in parts {
        if !list.contains(part) {
            list.append(part)
        }
    }
    if !list.contains(trimmed) {
        list.append(trimmed)
    }
    return list.isEmpty ? [trimmed] : list
}

struct Artist: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    var albumCount: Int?
    var coverArt: String?
    var created: String?

    // Convenience computed URL
    var coverArtUrl: URL? { resolveArtistPortraitUrl(id: id, serverUrl: coverArt) }

    var allNames: [String] {
        return parseAllArtistNames(name)
    }

    var primaryName: String {
        return extractPrimaryArtist(name)
    }
}

/// Sanitizes a string (such as an artist or album name) for safe filesystem cache keys and file paths.
func sanitizeFileName(_ name: String) -> String {
    return name.components(separatedBy: .punctuationCharacters).joined(separator: "_")
        .components(separatedBy: .whitespaces).joined(separator: "_")
        .lowercased()
}


struct Album: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let duration: Int?
    var coverArt: String?
    var created: String?
    var year: Int?
    var genre: String?
    var musicBrainzId: String?
    var releaseTypes: [String]?

    init(
        id: String,
        name: String,
        artist: String? = nil,
        artistId: String? = nil,
        songCount: Int? = nil,
        duration: Int? = nil,
        coverArt: String? = nil,
        created: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        musicBrainzId: String? = nil,
        releaseTypes: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
        self.created = created
        self.year = year
        self.genre = genre
        self.musicBrainzId = musicBrainzId
        self.releaseTypes = releaseTypes
    }

    var primaryReleaseType: String {
        return releaseTypes?.first?.lowercased() ?? "album"
    }

    var coverArtUrl: URL? { resolveCoverArtUrl(id: coverArt ?? id, serverUrl: coverArt, albumId: id) }
}

struct Track: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let album: String?
    let artist: String?
    let duration: Int?
    var coverArt: String?
    let artistId: String?
    let albumId: String?
    var created: String?
    var isStarred: Bool = false
    var playCount: Int? = 0
    let suffix: String?
    let track: Int?
    let discNumber: Int?
    var year: Int?
    var genre: String?
    var musicBrainzId: String?

    init(
        id: String,
        title: String,
        album: String? = nil,
        artist: String? = nil,
        duration: Int? = nil,
        coverArt: String? = nil,
        artistId: String? = nil,
        albumId: String? = nil,
        created: String? = nil,
        isStarred: Bool = false,
        playCount: Int? = 0,
        suffix: String? = nil,
        track: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        musicBrainzId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.duration = duration
        self.coverArt = coverArt
        self.artistId = artistId
        self.albumId = albumId
        self.created = created
        self.isStarred = isStarred
        self.playCount = playCount
        self.suffix = suffix
        self.track = track
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.musicBrainzId = musicBrainzId
    }

    var coverArtUrl: URL? {
        let artId = coverArt ?? albumId ?? id.components(separatedBy: ".").first ?? id
        return resolveCoverArtUrl(id: artId, serverUrl: coverArt, albumId: albumId, trackId: id)
    }

    var durationFormatted: String {
        guard let duration = duration else { return "0:00" }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var allArtists: [String] {
        guard let artist = artist, !artist.isEmpty else { return ["Unknown Artist"] }
        return parseAllArtistNames(artist)
    }

    var primaryArtist: String {
        guard let artist = artist, !artist.isEmpty else { return "Unknown Artist" }
        return extractPrimaryArtist(artist)
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

// MARK: - Preference Keys
public struct ScrollOffsetKey: PreferenceKey {
    public typealias Value = CGFloat
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - UIKit Scroll Tracker
public struct ScrollViewOffsetTracker: UIViewRepresentable {
    public var onScroll: (CGFloat) -> Void
    
    public func makeUIView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onScroll = onScroll
        return view
    }
    
    public func updateUIView(_ uiView: TrackerView, context: Context) {
        uiView.onScroll = onScroll
    }
    
    public class TrackerView: UIView {
        var onScroll: ((CGFloat) -> Void)?
        private var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            guard self.window != nil else { return }
            findScrollView()
        }
        
        private func findScrollView() {
            var current: UIView? = self
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    self.scrollView = scrollView
                    observation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scrollView, _ in
                        MainActor.assumeIsolated {
                            let base = scrollView.adjustedContentInset.top
                            let offset = -(scrollView.contentOffset.y + base)
                            self?.onScroll?(offset)
                        }
                    }
                    return
                }
                current = view.superview
            }
        }
        
        deinit {
            observation?.invalidate()
        }
    }
}
