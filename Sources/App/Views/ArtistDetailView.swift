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
    @State private var artistArea: String? = nil
    @State private var artistType: String? = nil
    @State private var artistLifeSpan: String? = nil
    @State private var relatedArtists: [Artist] = []
    @State private var isLoading: Bool = true
    
    var isLargeCanvas: Bool { UIScreen.main.bounds.width >= 1150 }
    var isCompact: Bool { hSizeClass == .compact }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            (isDarkMode ? Color(hex: "#0A0A0A") : Color(hex: "#FFFFFF"))
            
            ScrollView {
                VStack(spacing: 0) {
                    // Spacer to account for global header height (approx 100px)
                    Spacer().frame(height: isCompact ? 80 : 110)
                    
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
            }
            .coordinateSpace(name: "scroll")
            
            // Back
            if isCompact {
                backButton
            }
        }
        .onAppear {
            fetchArtistData()
        }
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
                        artistNameText(size: ScreenTier.isSE ? 32 : 40)
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
                            artistNameText(size: 72)
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
        .padding(.top, isCompact ? 40 : 120)
        .padding(.bottom, 32)
    }
    
    private func artistLogo(size: CGFloat) -> some View {
        ZStack {
            // Radiating "Aura" behind portrait - Even softer and more subtle
            Circle()
                .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                .frame(width: size * 1.8, height: size * 1.8)
                .blur(radius: 60)
            
            ArtistPortraitView(artistId: artistId, artistName: artistName, size: size, client: client, isDarkMode: isDarkMode)
                .id("portrait-\(artistId)")
                .shadow(color: .black.opacity(isDarkMode ? 0.4 : 0.15), radius: 30, x: 0, y: 15)
        }
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
                        SongArtworkView(track: track, isDarkMode: isDarkMode, height: isCompact ? 200 : 240)
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
                SongArtworkView(track: track, isDarkMode: isDarkMode, size: 56)
                
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
            
            // Enriched Metadata Badges
            if artistArea != nil || artistType != nil || artistLifeSpan != nil {
                HStack(spacing: 16) {
                    if let area = artistArea {
                        metadataBadge(label: "Origin", value: area)
                    }
                    if let type = artistType {
                        metadataBadge(label: "Type", value: type)
                    }
                    if let life = artistLifeSpan {
                        metadataBadge(label: "Active", value: life)
                    }
                }
                .padding(.horizontal, isCompact ? 24 : 48)
                .padding(.top, 8)
            }
        }
    }
    
    private func metadataBadge(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .black))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isDarkMode ? .white : .black)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isDarkMode ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .cornerRadius(12)
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
        
        // 1. Try local data first for instant response
        if let localArtist = LocalMetadataStore.shared.fetchArtistById(id: artistId) {
            self.biography = localArtist.biography
            self.artistArea = localArtist.area
            self.artistType = localArtist.type
            self.artistLifeSpan = localArtist.lifeSpan
        }
        
        client.fetchArtistData(artistId: artistId) { tracks, albums, bio, mbid in
            self.topSongs = tracks.sorted(by: { ($0.playCount ?? 0) > ($1.playCount ?? 0) })
            self.favoriteSongs = tracks.filter { $0.isStarred }
            self.albums = albums
            
            // Only update bio if not already set or if it's nil
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



// MARK: - Dedicated Subviews to prevent flickering

struct ArtistPortraitView: View {
    let artistId: String
    let artistName: String
    let size: CGFloat
    let client: NavidromeClient
    let isDarkMode: Bool
    
    @StateObject private var fanart = FanartManager.shared
    @State private var portraitImage: UIImage? = nil
    
    var body: some View {
        Group {
            if let img = portraitImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                AsyncImage(url: URL(string: client.getCoverArtUrl(id: artistId))) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear {
            fanart.fetchArtistPortrait(for: artistName) { img in
                if let img = img {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.portraitImage = img
                    }
                }
            }
        }
    }
}

struct SongArtworkView: View {
    let track: Track
    let isDarkMode: Bool
    var size: CGFloat? = nil
    var height: CGFloat? = nil
    
    var body: some View {
        AsyncImage(url: track.coverArtUrl) { phase in
            if let img = phase.image {
                img.resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .id(track.id)
        .frame(width: size, height: height ?? size)
        .cornerRadius(size == 56 ? 8 : 16)
        .clipped()
    }
}

    
