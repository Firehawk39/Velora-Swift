import SwiftUI

struct ArtistDetailView: View {
    let artistId: String
    let artistName: String
    let onPlay: (Track, [Track]) -> Void
    let onBack: () -> Void
    
    @EnvironmentObject var client: NavidromeClient
    @Environment(\.horizontalSizeClass) var hSizeClass
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    
    @State private var topSongs: [Track] = []
    @State private var favoriteSongs: [Track] = []
    @State private var albums: [Album] = []
    @State private var biography: String? = nil
    @State private var relatedArtists: [SubsonicArtist] = []
    @State private var isLoading: Bool = true
    @State private var scrollOffset: CGFloat = 0
    
    var isCompact: Bool { hSizeClass == .compact }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            (isDarkMode ? Color(hex: "#121212") : Color(hex: "#fafafa"))
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
                                    .frame(maxWidth: 400)
                                
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
            backButton
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
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(
            (isDarkMode ? Color(hex: "#121212") : Color(hex: "#fafafa"))
                .opacity(Double(opacity))
        )
        .zIndex(100)
    }
    
    private var heroSection: some View {
        VStack(spacing: 32) {
            // Artist Logo
            AsyncImage(url: URL(string: client.getCoverArtUrl(id: artistId))) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.1)
                }
            }
            .frame(width: isCompact ? 180 : 280, height: isCompact ? 180 : 280)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(.top, 100)
            
            VStack(spacing: 12) {
                Text("ARTIST")
                    .font(.system(size: 12, weight: .black))
                    .kerning(2)
                    .foregroundColor(.gray)
                
                Text(artistName)
                    .font(.system(size: isCompact ? 48 : 72, weight: .black))
                    .foregroundColor(isDarkMode ? .white : .black)
                    .multilineTextAlignment(.center)
            }
            
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
        .frame(maxWidth: .infinity)
        .padding(.bottom, 48)
    }
    
    private var mostFavoriteSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Most Favourite")
                .font(.system(size: 20, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
            
            if let track = favoriteSongs.first {
                Button(action: { onPlay(track, favoriteSongs) }) {
                    VStack(alignment: .leading, spacing: 16) {
                        AsyncImage(url: track.coverArtUrl) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Color.gray.opacity(0.1)
                            }
                        }
                        .aspectRatio(1, contentMode: .fill)
                        .cornerRadius(12)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(isDarkMode ? .white : .black)
                            
                            Text("\(track.playCount ?? 0) plays")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            } else if let track = topSongs.first {
                // Fallback to top song if no stars
                Button(action: { onPlay(track, topSongs) }) {
                    VStack(alignment: .leading, spacing: 16) {
                        AsyncImage(url: track.coverArtUrl) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Color.gray.opacity(0.1)
                            }
                        }
                        .aspectRatio(1, contentMode: .fill)
                        .cornerRadius(12)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(isDarkMode ? .white : .black)
                            
                            Text("\(track.playCount ?? 0) plays")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private var songsByArtistSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Songs by \(artistName)")
                .font(.system(size: 20, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
            
            VStack(spacing: 12) {
                ForEach(topSongs.prefix(5)) { track in
                    Button(action: { onPlay(track, topSongs) }) {
                        HStack(spacing: 16) {
                            AsyncImage(url: track.coverArtUrl) { phase in
                                if let img = phase.image {
                                    img.resizable().scaledToFill()
                                } else {
                                    Color.gray.opacity(0.1)
                                }
                            }
                            .frame(width: 48, height: 48)
                            .cornerRadius(8)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(isDarkMode ? .white : .black)
                                    .lineLimit(1)
                                
                                Text(track.album ?? "Unknown Album")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Text(track.durationFormatted)
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }
    
    private var discographySection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Discography")
                .font(.system(size: 20, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, isCompact ? 24 : 48)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(albums) { album in
                        AlbumCard(album: album, isDarkMode: isDarkMode, isCompact: isCompact)
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
                .font(.system(size: 20, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, isCompact ? 24 : 48)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(relatedArtists, id: \.id) { artist in
                        VStack(spacing: 12) {
                            AsyncImage(url: URL(string: client.getCoverArtUrl(id: artist.id))) { phase in
                                if let img = phase.image {
                                    img.resizable().scaledToFill()
                                } else {
                                    Color.gray.opacity(0.1)
                                }
                            }
                            .frame(width: isCompact ? 120 : 160, height: isCompact ? 120 : 160)
                            .clipShape(Circle())
                            
                            Text(artist.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(isDarkMode ? .white : .black)
                                .lineLimit(1)
                        }
                        .frame(width: isCompact ? 120 : 160)
                    }
                }
                .padding(.horizontal, isCompact ? 24 : 48)
            }
        }
    }
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("About")
                .font(.system(size: 20, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, isCompact ? 24 : 48)
            
            if let bio = biography {
                Text(bio)
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .padding(.horizontal, isCompact ? 24 : 48)
            }
        }
    }
    
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(isDarkMode ? .white : .black)
                .frame(width: 40, height: 40)
        }
        .padding(.leading, 24)
        .padding(.top, 60)
        .zIndex(110)
    }
    
    private func fetchArtistData() {
        isLoading = true
        client.fetchArtistData(artistId: artistId) { tracks, albums, bio in
            self.topSongs = tracks.sorted(by: { ($0.playCount ?? 0) > ($1.playCount ?? 0) })
            self.favoriteSongs = tracks.filter { $0.isStarred }
            self.albums = albums
            self.biography = bio
            self.isLoading = false
            
            client.fetchArtists { artists in
                self.relatedArtists = Array(artists.shuffled().prefix(6)).filter { $0.id != artistId }
            }
        }
    }
}

fileprivate struct AlbumCard: View {
    let album: Album
    let isDarkMode: Bool
    let isCompact: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: album.coverArtUrl) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.1)
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .cornerRadius(12)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isDarkMode ? .white : .black)
                    .lineLimit(1)
                
                Text("Album")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
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
