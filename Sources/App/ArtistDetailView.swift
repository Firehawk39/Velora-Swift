import SwiftUI
import Foundation

struct ArtistDetailView: View {
    let artistId: String
    let artistName: String
    let onArtistClick: (String, String) -> Void
    let onPlay: (Track, [Track]) -> Void
    let onBack: () -> Void
    
    @EnvironmentObject var client: NavidromeClient
    @Environment(\.horizontalSizeClass) var hSizeClass
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    
    @State private var topSongs: [Track] = []
    @State private var favoriteSongs: [Track] = []
    @State private var albums: [Album] = []
    @State private var biography: String? = nil
    @State private var relatedArtists: [Artist] = []
    @State private var isLoading: Bool = true
    @State private var scrollOffset: CGFloat = 0
    @State private var artistPortrait: UIImage? = nil
    
    var isLargeCanvas: Bool { UIScreen.main.bounds.width >= 1150 }
    var isCompact: Bool { hSizeClass == .compact }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            (isDarkMode ? Color(hex: "#121212") : Color(hex: "#fafafa"))
                .ignoresSafeArea()
            
            // Radiated background glow behind the artist image
            RadialGradient(
                gradient: Gradient(colors: [Color(hex: "#FFCCD5").opacity(isDarkMode ? 0.12 : 0.22), .clear]),
                center: .top,
                startRadius: 0,
                endRadius: isCompact ? 250 : 450
            )
            .frame(height: isCompact ? 400 : 600)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    
                    VStack(alignment: .leading, spacing: 48) {
                        // Main Two-Column Section
                        if isCompact {
                            VStack(alignment: .leading, spacing: 48) {
                                mostFavoriteSection
                                songsByArtistSection
                            }
                            .padding(.horizontal, 24)
                        } else {
                            HStack(alignment: .top, spacing: 64) {
                                mostFavoriteSection
                                    .frame(maxWidth: 350)
                                
                                songsByArtistSection
                            }
                            .padding(.horizontal, 48)
                        }
                        
                        discographySection
                        aboutSection
                        
                        if !relatedArtists.isEmpty {
                            fansAlsoLikeSection
                        }
                    }
                    .padding(.top, 48)
                    .padding(.bottom, 120)
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .global).minY)
                })
            }
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                self.scrollOffset = value
            }
            .coordinateSpace(name: "scroll")
            
            // Header
            headerOverlay
            
            // Back
            if isCompact {
                backButton
            }
        }
        .onAppear {
            fetchArtistData()
        }
    }
    
    private var headerOverlay: some View {
        let opacity = min(1, max(0, (-scrollOffset - 300) / 50))
        return HStack {
            Text(artistName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(isDarkMode ? .white : .black)
                .opacity(Double(opacity))
            Spacer()
        }
        .padding(.horizontal, isCompact ? 24 : 48)
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(
            (isDarkMode ? Color(hex: "#121212") : Color(hex: "#fafafa"))
                .opacity(Double(opacity))
        )
        .zIndex(100)
    }
    
    private var heroNameSize: CGFloat { 
        if isLargeCanvas { return 20.0 }
        if ScreenTier.isPhone { return ScreenTier.isSE ? 18 : 24 }
        return 16.0
    }
    
    private var heroSection: some View {
        Group {
            if isCompact {
                VStack(spacing: ScreenTier.isSE ? 16 : 24) {
                    artistLogo(size: ScreenTier.isSE ? 120 : 140)
                    
                    VStack(spacing: 6) {
                        artistLabel
                        artistNameText(size: ScreenTier.isSE ? 24 : 28)
                    }
                    
                    playAllButton
                        .scaleEffect(ScreenTier.isPhone ? 0.85 : 0.95)
                }
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 32) {
                    ZStack(alignment: .topLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(isDarkMode ? .white : .black)
                                .frame(width: 36, height: 36)
                                .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                                .clipShape(Circle())
                        }
                        .padding(.leading, 0)
                        .padding(.top, 20)
                        
                        HStack {
                            Spacer()
                            artistLogo(size: 220)
                            Spacer()
                        }
                    }
                    
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            artistLabel
                            artistNameText(size: 36)
                        }
                        
                        Spacer()
                        
                        playAllButton
                            .padding(.bottom, 8)
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 48)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isCompact ? 60 : 160)
        .padding(.bottom, 32)
    }
    
    private func artistLogo(size: CGFloat) -> some View {
        Group {
            if let portrait = artistPortrait {
                Image(uiImage: portrait)
                    .resizable()
                    .scaledToFill()
            } else {
                AsyncImage(url: URL(string: client.getCoverArtUrl(id: artistId))) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: .black.opacity(isDarkMode ? 0.3 : 0.15), radius: 30, x: 0, y: 15)
    }
    
    private var artistLabel: some View {
        Text("ARTIST")
            .kerning(2)
            .font(.system(size: 12, weight: .black))
            .foregroundColor(.gray)
    }
    
    private func artistNameText(size: CGFloat) -> some View {
        Text(artistName)
            .kerning(-2)
            .font(.system(size: size, weight: .black))
            .foregroundColor(isDarkMode ? .white : .black)
            .multilineTextAlignment(.leading)
    }
    
    private var playAllButton: some View {
        Button(action: {
            if !topSongs.isEmpty {
                onPlay(topSongs[0], topSongs)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                Text("Play All")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(isDarkMode ? .black : .white)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(isDarkMode ? Color.white : Color.black)
            .clipShape(Capsule())
        }
    }
    
    private var mostFavoriteSection: some View {
        VStack(alignment: .leading, spacing: ScreenTier.isPhone ? 12 : 16) {
            Text("Most Favourite")
                .font(.system(size: 14, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
            
            if let track = favoriteSongs.first ?? topSongs.first {
                Button(action: { onPlay(track, topSongs) }) {
                    VStack(alignment: .leading, spacing: 12) {
                        AsyncImage(url: track.coverArtUrl) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Color.gray.opacity(0.1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: isCompact ? 200 : 240)
                        .cornerRadius(16)
                        .clipped()
                        .shadow(color: .black.opacity(isDarkMode ? 0.25 : 0.1), radius: 15, x: 0, y: 8)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(isDarkMode ? .white : .black)
                                .lineLimit(1)
                            
                            Text(track.album ?? "Unknown Album")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private var songsByArtistSection: some View {
        VStack(alignment: .leading, spacing: ScreenTier.isPhone ? 12 : 16) {
            Text("Songs by \(artistName)")
                .font(.system(size: ScreenTier.isPhone ? 14 : 16, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
            
            if isCompact {
                VStack(spacing: 10) {
                    ForEach(topSongs.prefix(5)) { track in
                        trackRow(track)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(topSongs.prefix(8)) { track in
                        trackRow(track)
                    }
                }
            }
        }
    }
    
    private func trackRow(_ track: Track) -> some View {
        Button(action: { onPlay(track, topSongs) }) {
            HStack(spacing: 16) {
                AsyncImage(url: track.coverArtUrl) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
                .frame(width: 56, height: 56)
                .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isDarkMode ? .white : .black)
                        .lineLimit(1)
                    
                    Text(track.album ?? "Unknown Album")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text(track.durationFormatted)
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
            .padding(8)
            .background(isDarkMode ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var discographySection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Discography")
                .font(.system(size: 18, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, isCompact ? 24 : 48)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(albums) { album in
                        AlbumCard(album: album, isDark: isDarkMode)
                            .frame(width: isCompact ? 160 : 200)
                    }
                }
                .padding(.horizontal, isCompact ? 24 : 48)
            }
        }
    }
    
    private var fansAlsoLikeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Fans also like")
                .font(.system(size: 18, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, isCompact ? 24 : 48)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(relatedArtists) { artist in
                        Button(action: { onArtistClick(artist.id, artist.name) }) {
                            ArtistCircle(artist: artist, isDark: isDarkMode, size: isCompact ? 120 : 160)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, isCompact ? 24 : 48)
            }
        }
    }
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("About")
                .font(.system(size: 18, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, isCompact ? 24 : 48)
            
            if let bio = biography {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .padding(.horizontal, isCompact ? 24 : 48)
            }
        }
    }
    
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(isDarkMode ? .white : .black)
                .frame(width: 36, height: 36)
                .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                .clipShape(Circle())
        }
        .padding(.leading, 24)
        .padding(.top, 100)
        .zIndex(110)
    }
    
    private func fetchArtistData() {
        isLoading = true
        
        // 1. Fetch high-quality portrait and bio from ArtistDataManager
        ArtistDataManager.shared.getPortrait(for: artistName) { image in
            self.artistPortrait = image
        }
        
        ArtistDataManager.shared.getBio(for: artistName) { bio in
            if bio != nil {
                self.biography = bio
            }
        }
        
        // 2. Fetch standard data from Navidrome
        client.fetchArtistData(artistId: artistId) { tracks, albums, bio in
            self.topSongs = tracks.sorted(by: { ($0.playCount ?? 0) > ($1.playCount ?? 0) })
            self.favoriteSongs = tracks.filter { $0.isStarred }
            self.albums = albums
            // Only update bio if we don't have a high-quality one yet
            if self.biography == nil {
                self.biography = bio
            }
            self.isLoading = false
            
            client.fetchArtists { artists in
                self.relatedArtists = Array(artists.shuffled().prefix(6)).filter { $0.id != artistId }
            }
        }
    }
}



// MARK: - Preference Keys
struct ScrollOffsetKey: PreferenceKey {
    typealias Value = CGFloat
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
