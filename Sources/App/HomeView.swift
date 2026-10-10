import SwiftUI

@MainActor
struct HomeView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    @ObservedObject var network = NetworkMonitor.shared
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    @Environment(\.horizontalSizeClass) var hSizeClass

    var isDark: Bool { isDarkMode }
    var isCompact: Bool { hSizeClass == .compact }
    var isSE: Bool { ScreenTier.isSE }
    var hPad: CGFloat { isCompact ? 24 : 48 }
    var onArtistClick: ((String, String) -> Void)? = nil
    var onSeeAll: (() -> Void)? = nil
    var onScroll: ((CGFloat) -> Void)? = nil

    @State private var isRefreshing = false

    // Greeting — matches the web's time-of-day logic
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let customName = UserDefaults.standard.string(forKey: "velora_display_name")
        let name = (customName != nil && !customName!.isEmpty)
            ? customName!
            : (client.username.isEmpty ? "there" : (client.username.prefix(1).uppercased() + client.username.dropFirst()))
        if h >= 12 && h < 17 { return "Good afternoon, \(name)" }
        if h >= 17 || h < 5  { return "Good evening, \(name)"   }
        return "Good morning, \(name)"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // Inject the low-threshold refresh control as the first child so it
                // attaches to this ScrollView's UIScrollView, not a nested one.
                LowThresholdRefreshControl(isRefreshing: $isRefreshing) {
                    client.fetchAlbums()
                    client.fetchArtists()
                    // Give the fetches a moment then hide the spinner
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        isRefreshing = false
                    }
                }

                Spacer().frame(height: ScreenTier.isSmall ? 110 : (isCompact ? 80 : 100))

                // ── Greeting ─────────────────────────────────────────
                Text(greeting)
                    .font(.system(size: ScreenTier.isPhone ? (ScreenTier.isSmall ? 22 : 28) : 28, weight: .bold))
                    .foregroundColor(isDark ? .white : Color(hex: "#111827"))
                    .padding(.horizontal, hPad)
                    .padding(.bottom, ScreenTier.isPhone ? 24 : 32)

                // ── Recent Tracks ─────────────────────────────────────
                let offlineRecent = !network.isConnected ? playback.filterOffline(client.recentTracks) : client.recentTracks
                if !offlineRecent.isEmpty || network.isConnected {
                    SectionHeader(title: "Recent tracks", isDark: isDark, hPad: hPad, onSeeAll: onSeeAll)

                    if client.recentTracks.isEmpty {
                        SkeletonRow(count: 4, cardWidth: ScreenTier.isPhone ? 140 : 150, cardHeight: ScreenTier.isPhone ? 140 : 150, isDark: isDark)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: ScreenTier.isPhone ? 16 : 32) {
                                ForEach(offlineRecent.prefix(isCompact ? 4 : 6)) { track in
                                    TrackCard(
                                        track: track,
                                        isDark: isDark,
                                        size: ScreenTier.isPhone ? 140 : 150,
                                        onPlay: { playback.playTrack(track, context: Array(offlineRecent)) }
                                    )
                                }
                            }
                            .padding(.horizontal, hPad)
                            .padding(.bottom, 8)
                        }
                    }

                    Spacer().frame(height: 32)
                }

                let (offlineArtists, offlineAlbums): ([Artist], [Album]) = {
                    if network.isConnected { return (client.artists, client.albums) }
                    let downloadedTrackIds = playback.downloadedTrackIds
                    let downloadedTracks = LibraryDataCache.shared.allTracks.filter { downloadedTrackIds.contains($0.id) }
                    
                    var downloadedAlbumIds = Set<String>()
                    var downloadedArtistIds = Set<String>()
                    var downloadedArtistNames = Set<String>()
                    var downloadedAlbumKeys = Set<String>()
                    
                    for track in downloadedTracks {
                        if let aid = track.albumId { downloadedAlbumIds.insert(aid) }
                        if let artId = track.artistId { downloadedArtistIds.insert(artId) }
                        if let aName = track.artist { downloadedArtistNames.insert(aName.lowercased()) }
                        let key = "\(track.artist ?? "")_\(track.album ?? "")".lowercased()
                        downloadedAlbumKeys.insert(key)
                    }
                    
                    var matchedArtists = client.artists.filter { 
                        downloadedArtistIds.contains($0.id) || downloadedArtistNames.contains($0.name.lowercased()) 
                    }
                    if matchedArtists.isEmpty && !downloadedTracks.isEmpty {
                        matchedArtists = LibraryDataCache.shared.synthesizeArtists(from: downloadedTracks)
                    }

                    var matchedAlbums = client.albums.filter { album in
                        downloadedAlbumIds.contains(album.id) || downloadedAlbumKeys.contains("\(album.artist ?? "")_\(album.name)".lowercased())
                    }
                    if matchedAlbums.isEmpty && !downloadedTracks.isEmpty {
                        matchedAlbums = LibraryDataCache.shared.synthesizeAlbums(from: downloadedTracks)
                    }

                    return (matchedArtists, matchedAlbums)
                }()

                if !offlineArtists.isEmpty || network.isConnected {
                    SectionHeader(title: "Artists", isDark: isDark, hPad: hPad, onSeeAll: onSeeAll)

                    if client.artists.isEmpty && network.isConnected {
                        SkeletonRow(count: 5, cardWidth: isCompact ? 75 : 90, cardHeight: isCompact ? 75 : 90, isDark: isDark, circular: true)
                    } else if !offlineArtists.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: isCompact ? 16 : 24) {
                                ForEach(offlineArtists.prefix(isCompact ? 8 : 12)) { artist in
                                    ArtistCircle(artist: artist, isDark: isDark, size: isCompact ? 75 : 90)
                                        .onTapGesture {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                onArtistClick?(artist.id, artist.name)
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, hPad)
                            .padding(.bottom, 8)
                        }
                    }

                    Spacer().frame(height: 32)
                }

                // ── Recently Added Albums ─────────────────────────────

                if !offlineAlbums.isEmpty || network.isConnected {
                    SectionHeader(title: "Recently added albums", isDark: isDark, hPad: hPad, onSeeAll: onSeeAll)

                    if client.albums.isEmpty && network.isConnected {
                        SkeletonRow(count: 3, cardWidth: ScreenTier.isPhone ? 160 : 200, cardHeight: ScreenTier.isPhone ? 100 : 130, isDark: isDark, rounded: 24)
                    } else if !offlineAlbums.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: ScreenTier.isPhone ? 12 : 24) {
                                ForEach(offlineAlbums.prefix(isCompact ? 6 : 8)) { album in
                                    AlbumCard(album: album, isDark: isDark, cardW: ScreenTier.isPhone ? 160 : 180, cardH: ScreenTier.isPhone ? 100 : 120)
                                        .onTapGesture {
                                            let pManager = playback
                                            client.fetchAlbumTracks(albumId: album.id, albumName: album.name) { tracks in
                                                if let first = tracks.first {
                                                    pManager.playTrack(first, context: tracks)
                                                }
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, hPad)
                            .padding(.bottom, 4)
                        }
                    }

                    Spacer().frame(height: 48)
                }
            }
            .padding(.top, 4)
            .background(
                ScrollViewOffsetTracker { value in
                    onScroll?(value)
                }
            )
        }
        .ignoresSafeArea(edges: .top)
        .onAppear {
            LibraryDataCache.shared.refresh()
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let isDark: Bool
    let hPad: CGFloat
    var onSeeAll: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) var hSizeClass
    var isCompact: Bool { hSizeClass == .compact }
    var isLargeCanvas: Bool { ScreenTier.current == .large }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: isCompact ? 16 : 18, weight: .bold))
                .foregroundColor(isDark ? .white : Color(hex: "#374151"))
            Spacer()
            Button(action: { onSeeAll?() }) {
                Text("See all")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isDark ? .white.opacity(0.6) : .blue)
                    .padding(.vertical, 8)
                    .padding(.leading, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, hPad)
        .padding(.bottom, isCompact ? 12 : 14)
    }
}
