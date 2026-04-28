import SwiftUI

struct HomeView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    @Environment(\.horizontalSizeClass) var hSizeClass

    var isDark: Bool { isDarkMode }
    var isCompact: Bool { hSizeClass == .compact }
    var isSE: Bool { UIScreen.main.bounds.width <= 320 }
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
                    .font(.system(size: isSE ? 28 : (isCompact ? 32 : 34), weight: .bold))
                    .foregroundColor(isDark ? .white : Color(hex: "#111827"))
                    .padding(.horizontal, hPad)
                    .padding(.bottom, isCompact ? 32 : 48)

                // ── Recent Tracks ─────────────────────────────────────
                SectionHeader(title: "Recent tracks", isDark: isDark)

                if client.recentTracks.isEmpty {
                    SkeletonRow(count: 4, cardWidth: isCompact ? 160 : 180, cardHeight: isCompact ? 160 : 180, isDark: isDark)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: isCompact ? 20 : 32) {
                            ForEach(client.recentTracks.prefix(isCompact ? 4 : 6)) { track in
                                TrackCard(
                                    track: track,
                                    isDark: isDark,
                                    size: isCompact ? 160 : 180,
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
                SectionHeader(title: "Artists", isDark: isDark)

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
                SectionHeader(title: "Recently added albums", isDark: isDark)

                if client.albums.isEmpty {
                    SkeletonRow(count: 3, cardWidth: isCompact ? 240 : 280, cardHeight: isCompact ? 140 : 160, isDark: isDark, rounded: 24)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: isCompact ? 16 : 24) {
                            ForEach(client.albums.prefix(isCompact ? 6 : 8)) { album in
                                AlbumCard(album: album, isDark: isDark, cardW: isCompact ? 240 : 280, cardH: isCompact ? 140 : 160)
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
    @Environment(\.horizontalSizeClass) var hSizeClass
    var isCompact: Bool { hSizeClass == .compact }
    var isSE: Bool { UIScreen.main.bounds.width <= 320 }
    var body: some View {
        Text(title)
            .font(.system(size: isSE ? 24 : (isCompact ? 28 : 42), weight: .bold))
            .foregroundColor(isDark ? .white : Color(hex: "#111827"))
            .padding(.horizontal, isSE ? 14 : (isCompact ? 16 : 40))
            .padding(.bottom, isCompact ? 16 : 24)
    }
}

// MARK: - Track Card  (square art + title + artist)

struct TrackCard: View {
    let track: Track
    let isDark: Bool
    var size: CGFloat = 140
    var onPlay: (() -> Void)? = nil
    @State private var isPressed = false
    var body: some View {
        Button(action: { onPlay?() }) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .center) {
                    AsyncImage(url: track.coverArtUrl) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(isDark ? Color.white.opacity(0.08) : Color(hex: "#e5e7eb"))
                            .overlay(MusicNoteIcon(isDark: isDark))
                    }
                    .frame(width: size, height: size)
                    .clipped()
                    .cornerRadius(size > 160 ? 16 : 12)

                    if isPressed {
                        Color.black.opacity(0.25).cornerRadius(size > 160 ? 16 : 12)
                        Circle().fill(Color.white).frame(width: 44, height: 44)
                            .overlay(Image(systemName: "play.fill").foregroundColor(.black).font(.system(size: 17)))
                    }
                }
                .frame(width: size, height: size)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: size > 170 ? 22 : 16, weight: .bold))
                        .foregroundColor(isDark ? .white : Color(hex: "#111827"))
                        .lineLimit(1)
                    
                    Text(track.artist ?? "Unknown Artist")
                        .font(.system(size: size > 170 ? 18 : 14))
                        .foregroundColor(isDark ? Color(hex: "#9ca3af") : Color(hex: "#6b7280"))
                        .lineLimit(1)
                }
                .frame(width: size, alignment: .leading)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: size)
    }
}

// MARK: - Artist Circle

struct ArtistCircle: View {
    let artist: Artist
    let isDark: Bool
    var size: CGFloat = 88

    var body: some View {
        VStack(spacing: 8) {
            AsyncImage(url: artist.coverArtUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(isDark ? Color.white.opacity(0.08) : Color(hex: "#e5e7eb"))
                    .overlay(MusicNoteIcon(isDark: isDark))
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

            Text(artist.name)
                .font(.system(size: size > 120 ? 18 : 14, weight: .bold))
                .foregroundColor(isDark ? .white : Color(hex: "#111827"))
                .lineLimit(1)
                .frame(width: size, alignment: .center)
        }
        .frame(width: size)
    }
}

// MARK: - Album Card  (16:9 with overlay)

struct AlbumCard: View {
    let album: Album
    let isDark: Bool
    var cardW: CGFloat = 220
    var cardH: CGFloat = 124

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: album.coverArtUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(isDark ? Color.white.opacity(0.08) : Color(hex: "#e5e7eb"))
            }
            .frame(width: cardW, height: cardH)
            .clipped()

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: cardW > 300 ? 24 : 18, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(album.artist ?? "")
                    .font(.system(size: cardW > 300 ? 16 : 13))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Color.clear
                .overlay(
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 44, height: 44)
                        Image(systemName: "play.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 18))
                            .offset(x: 1)
                    }
                )
        }
        .frame(width: cardW, height: cardH)
        .cornerRadius(20)
    }
}

// MARK: - Skeleton loader

private struct SkeletonRow: View {
    let count: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let isDark: Bool
    var circular: Bool = false
    var rounded: CGFloat = 12

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(spacing: 8) {
                        Rectangle()
                            .fill(isDark ? Color.white.opacity(0.06) : Color(hex: "#e5e7eb"))
                            .frame(width: cardWidth, height: cardHeight)
                            .cornerRadius(circular ? cardWidth / 2 : rounded)
                            .shimmer()
                        Rectangle()
                            .fill(isDark ? Color.white.opacity(0.06) : Color(hex: "#e5e7eb"))
                            .frame(width: cardWidth * 0.75, height: 10)
                            .cornerRadius(5)
                            .shimmer()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Music note placeholder icon

struct MusicNoteIcon: View {
    let isDark: Bool
    var body: some View {
        Image(systemName: "music.note")
            .font(.system(size: 24))
            .foregroundColor(isDark ? .white.opacity(0.2) : Color(hex: "#d1d5db"))
    }
}

// MARK: - Shimmer modifier

extension View {
    func shimmer() -> some View {
        self.opacity(0.7)
    }
}
