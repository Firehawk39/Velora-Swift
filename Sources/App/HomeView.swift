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
                Spacer().frame(height: ScreenTier.isSmall ? 110 : (isCompact ? 80 : 100))

                // ── Greeting ─────────────────────────────────────────
                Text(greeting)
                    .font(.system(size: UIScaler.scaleFont(isCompact ? 26.0 : 28.0), weight: .bold))
                    .foregroundColor(isDark ? .white : Color(hex: "#111827"))
                    .padding(.horizontal, hPad)
                    .padding(.bottom, ScreenTier.isPhone ? 24 : 32)

                // ── Recent Tracks ─────────────────────────────────────
                let offlineRecent = !network.isConnected ? playback.filterOffline(client.recentTracks) : client.recentTracks
                if !offlineRecent.isEmpty || network.isConnected {
                    SectionHeader(title: "Recent tracks", isDark: isDark, hPad: hPad)

                    if client.recentTracks.isEmpty {
                        SkeletonRow(count: 4, cardWidth: UIScaler.scaleW(isCompact ? 140.0 : 160.0), cardHeight: UIScaler.scaleW(isCompact ? 140.0 : 160.0), isDark: isDark)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: UIScaler.scaleW(isCompact ? 16.0 : 24.0)) {
                                ForEach(offlineRecent.prefix(isCompact ? 4 : 6)) { track in
                                    TrackCard(
                                        track: track,
                                        isDark: isDark,
                                        size: UIScaler.scaleW(isCompact ? 140.0 : 160.0),
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

                // ── Artists ───────────────────────────────────────────
                let offlineArtists = !network.isConnected ? client.artists.filter { artist in
                    client.allSongs.contains(where: { $0.artistId == artist.id && playback.isDownloaded($0.id) })
                } : client.artists

                if !offlineArtists.isEmpty || network.isConnected {
                    SectionHeader(title: "Artists", isDark: isDark, hPad: hPad)

                    if client.artists.isEmpty {
                        SkeletonRow(count: 5, cardWidth: UIScaler.scaleW(isCompact ? 75.0 : 90.0), cardHeight: UIScaler.scaleW(isCompact ? 75.0 : 90.0), isDark: isDark, circular: true)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: UIScaler.scaleW(isCompact ? 16.0 : 24.0)) {
                                ForEach(offlineArtists.prefix(isCompact ? 8 : 12)) { artist in
                                    ArtistCircle(artist: artist, isDark: isDark, size: UIScaler.scaleW(isCompact ? 75.0 : 90.0))
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
                let offlineAlbums = !network.isConnected ? client.albums.filter { album in
                    client.allSongs.contains(where: { $0.albumId == album.id && playback.isDownloaded($0.id) })
                } : client.albums

                if !offlineAlbums.isEmpty || network.isConnected {
                    SectionHeader(title: "Recently added albums", isDark: isDark, hPad: hPad)

                    if client.albums.isEmpty {
                        SkeletonRow(count: 3, cardWidth: UIScaler.scaleW(isCompact ? 160.0 : 200.0), cardHeight: UIScaler.scaleH(isCompact ? 100.0 : 130.0), isDark: isDark, rounded: 24)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: UIScaler.scaleW(isCompact ? 12.0 : 24.0)) {
                                ForEach(offlineAlbums.prefix(isCompact ? 6 : 8)) { album in
                                    AlbumCard(album: album, isDark: isDark, cardW: UIScaler.scaleW(isCompact ? 160.0 : 200.0), cardH: UIScaler.scaleH(isCompact ? 100.0 : 130.0))
                                        .onTapGesture {
                                            let pManager = playback
                                            client.fetchAlbumTracks(albumId: album.id) { tracks in
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
        .onAppear {
            if client.recentTracks.isEmpty {
                client.fetchRecentlyPlayed()
            }
        }
    }
}
}

private struct SectionHeader: View {
    let title: String
    let isDark: Bool
    let hPad: CGFloat
    @Environment(\.horizontalSizeClass) var hSizeClass
    var isCompact: Bool { hSizeClass == .compact }
    var isLargeCanvas: Bool { ScreenTier.current == .large }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: isCompact ? 16 : 18, weight: .bold))
                .foregroundColor(isDark ? .white : Color(hex: "#374151"))
            Spacer()
            if !isCompact {
                Text("See all")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isDark ? .white.opacity(0.6) : .blue)
            }
        }
        .padding(.horizontal, hPad)
        .padding(.bottom, isCompact ? 12 : 14)
    }
}
