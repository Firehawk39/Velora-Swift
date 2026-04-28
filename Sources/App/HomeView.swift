import SwiftUI

struct HomeView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    @Environment(\.horizontalSizeClass) var hSizeClass

    var isDark: Bool { isDarkMode }
    var isCompact: Bool { hSizeClass == .compact }
    var isSE: Bool { ScreenTier.isSE }
    var hPad: CGFloat { isSE ? 14 : (isCompact ? 16 : 40) }
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
                Spacer().frame(height: isCompact ? 80 : 100)

                // ── Greeting ─────────────────────────────────────────
                Text(greeting)
                    .font(.system(size: ScreenTier.isPhone ? (ScreenTier.isSE ? 24 : 28) : 34, weight: .bold))
                    .foregroundColor(isDark ? .white : Color(hex: "#111827"))
                    .padding(.horizontal, hPad)
                    .padding(.bottom, ScreenTier.isPhone ? 24 : 48)

                // ── Recent Tracks ─────────────────────────────────────
                SectionHeader(title: "Recent tracks", isDark: isDark, hPad: hPad)

                if client.recentTracks.isEmpty {
                    SkeletonRow(count: 4, cardWidth: ScreenTier.isPhone ? 140 : 180, cardHeight: ScreenTier.isPhone ? 140 : 180, isDark: isDark)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ScreenTier.isPhone ? 16 : 32) {
                            ForEach(client.recentTracks.prefix(isCompact ? 4 : 6)) { track in
                                TrackCard(
                                    track: track,
                                    isDark: isDark,
                                    size: ScreenTier.isPhone ? 140 : 180,
                                    onPlay: { playback.playTrack(track, context: Array(client.recentTracks)) }
                                )
                            }
                        }
                        .padding(.horizontal, hPad)
                        .padding(.bottom, 8)
                    }
                }

                Spacer().frame(height: 32)

                // ── Artists ───────────────────────────────────────────
                SectionHeader(title: "Artists", isDark: isDark, hPad: hPad)

                if client.artists.isEmpty {
                    SkeletonRow(count: 5, cardWidth: isCompact ? 88 : 110, cardHeight: isCompact ? 88 : 110, isDark: isDark, circular: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: isCompact ? 16 : 24) {
                            ForEach(client.artists.prefix(isCompact ? 8 : 12)) { artist in
                                ArtistCircle(artist: artist, isDark: isDark, size: isCompact ? 88 : 120)
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

                // ── Recently Added Albums ─────────────────────────────
                SectionHeader(title: "Recently added albums", isDark: isDark, hPad: hPad)

                if client.albums.isEmpty {
                    SkeletonRow(count: 3, cardWidth: ScreenTier.isPhone ? 200 : 280, cardHeight: ScreenTier.isPhone ? 120 : 160, isDark: isDark, rounded: 24)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ScreenTier.isPhone ? 12 : 24) {
                            ForEach(client.albums.prefix(isCompact ? 6 : 8)) { album in
                                AlbumCard(album: album, isDark: isDark, cardW: ScreenTier.isPhone ? 200 : 280, cardH: ScreenTier.isPhone ? 120 : 160)
                                    .onTapGesture {
                                        client.fetchAlbumTracks(albumId: album.id) { tracks in
                                            if let first = tracks.first {
                                                playback.playTrack(first, context: tracks)
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
            .padding(.top, 4)
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
                .font(.system(size: isCompact ? 18 : 22, weight: .bold))
                .foregroundColor(isDark ? .white : Color(hex: "#374151"))
            Spacer()
            if !isCompact {
                Text("See all")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isDark ? .white.opacity(0.6) : .blue)
            }
        }
        .padding(.horizontal, hPad)
        .padding(.bottom, isCompact ? 12 : 16)
    }
}
