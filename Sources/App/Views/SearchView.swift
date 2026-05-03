import SwiftUI

struct SearchView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    
    @State private var query: String = ""
    @State private var tracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var isLoading: Bool = false
    
    @Environment(\.horizontalSizeClass) var hSizeClass
    var isCompact: Bool { hSizeClass == .compact }
    var hPad: CGFloat { isCompact ? 16 : 40 }
    var onArtistClick: ((String, String) -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: isCompact ? 80 : 100)
            SearchSearchBar(query: $query, isDarkMode: isDarkMode, hPad: hPad, isCompact: isCompact, onSearch: performSearch)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 36) {
                    if isLoading {
                        HStack {
                            Spacer()
                            LoadingCircle(size: 40, strokeWidth: 4, accentColor: .red)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else if query.isEmpty {
                        SearchEmptyState(isDarkMode: isDarkMode, icon: "magnifyingglass", text: "Search your Navidrome library")
                    } else if tracks.isEmpty && albums.isEmpty && artists.isEmpty {
                        SearchEmptyState(isDarkMode: isDarkMode, icon: "exclamationmark.circle", text: "No results found for \"\(query)\"")
                    } else {
                        SearchResultsView(tracks: tracks, albums: albums, artists: artists, isDarkMode: isDarkMode, hPad: hPad, playback: playback, onArtistClick: onArtistClick)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .background(Color.clear)
    }
    
    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.tracks = []; self.albums = []; self.artists = []
            return
        }
        
        // 1. Instant Local Search
        let localTracks = LocalMetadataStore.shared.searchTracks(query: trimmed).map { pt in
            Track(id: pt.id, title: pt.title, album: pt.album, artist: pt.artist, 
                  duration: pt.duration ?? 0, coverArt: pt.coverArt, 
                  artistId: pt.artistId, albumId: pt.albumId, suffix: pt.suffix)
        }
        
        if !localTracks.isEmpty {
            self.tracks = localTracks
            // We don't set isLoading = false yet because we still want remote results for albums/artists
        }
        
        isLoading = true
        client.search(query: trimmed) { foundTracks, foundAlbums, foundArtists in
            DispatchQueue.main.async {
                // Merge results, prioritizing remote but keeping local enriched data if needed
                // For now, we'll just replace with remote as it's the "source of truth" for the current server state
                self.tracks = foundTracks
                self.albums = foundAlbums
                self.artists = foundArtists
                self.isLoading = false
            }
        }
    }
}

// MARK: - Subviews

private struct SearchSearchBar: View {
    @Binding var query: String
    let isDarkMode: Bool
    let hPad: CGFloat
    let isCompact: Bool
    let onSearch: (String) -> Void

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                .font(.system(size: isCompact ? 16 : 20))
                .padding(.leading, 16)
            
            TextField("Artists, songs, or podcasts", text: $query)
                .font(.system(size: isCompact ? 16 : 18))
                .foregroundColor(isDarkMode ? .white : .black)
                .submitLabel(.search)
                .onChange(of: query) { newValue in onSearch(newValue) }
            
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                        .font(.system(size: isCompact ? 18 : 24))
                }
                .padding(.trailing, 16)
            }
        }
        .frame(height: isCompact ? 50 : 60)
        .background(isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
        .cornerRadius(isCompact ? 12 : 16)
        .padding(.horizontal, hPad)
        .padding(.vertical, isCompact ? 16 : 24)
    }
}

private struct SearchEmptyState: View {
    let isDarkMode: Bool
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40))
                .foregroundColor(isDarkMode ? .white.opacity(0.15) : .black.opacity(0.15))
            Text(text).font(.system(size: 14))
                .foregroundColor(isDarkMode ? .white.opacity(0.3) : .black.opacity(0.3))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

private struct SearchResultsView: View {
    let tracks: [Track]
    let albums: [Album]
    let artists: [Artist]
    let isDarkMode: Bool
    let hPad: CGFloat
    let playback: PlaybackManager
    let onArtistClick: ((String, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SearchSectionHeader(title: "Songs", isDark: isDarkMode).padding(.horizontal, hPad)
                    VStack(spacing: 8) {
                        ForEach(tracks.prefix(5)) { track in
                            SearchSongRow(track: track, isDarkMode: isDarkMode, hPad: hPad) {
                                playback.playTrack(track, context: tracks)
                            }
                        }
                    }
                }
            }
            
            if !albums.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SearchSectionHeader(title: "Albums", isDark: isDarkMode).padding(.horizontal, hPad)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(albums.prefix(4)) { album in
                                SearchAlbumCard(album: album, isDark: isDarkMode)
                            }
                        }
                        .padding(.horizontal, hPad)
                    }
                }
            }
            
            if !artists.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SearchSectionHeader(title: "Artists", isDark: isDarkMode).padding(.horizontal, hPad)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(artists.prefix(4)) { artist in
                                SearchArtistCircle(artist: artist, isDark: isDarkMode)
                                    .onTapGesture {
                                        onArtistClick?(artist.id, artist.name)
                                    }
                            }
                        }
                        .padding(.horizontal, hPad)
                    }
                }
            }
        }
    }
}

private struct SearchSectionHeader: View {
    let title: String
    let isDark: Bool
    var body: some View {
        Text(title).font(.system(size: 26, weight: .bold))
            .foregroundColor(isDark ? .white : Color(hex: "#111827"))
    }
}

private struct SearchSongRow: View {
    let track: Track
    let isDarkMode: Bool
    let hPad: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                AsyncImage(url: track.coverArtUrl) { img in img.resizable().scaledToFill() }
                placeholder: { Rectangle().fill(isDarkMode ? Color.white.opacity(0.08) : Color(hex: "#e5e7eb")) }
                .frame(width: 54, height: 54).cornerRadius(8).clipped()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.system(size: 16, weight: .bold))
                        .foregroundColor(isDarkMode ? .white : .black).lineLimit(1)
                    Text(track.artist ?? "Unknown").font(.system(size: 14))
                        .foregroundColor(isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5)).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isDarkMode ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, hPad)
    }
}

private struct SearchAlbumCard: View {
    let album: Album
    let isDark: Bool
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: album.coverArtUrl) { img in img.resizable().scaledToFill() }
            placeholder: { Rectangle().fill(isDark ? Color.white.opacity(0.08) : Color(hex: "#e5e7eb")) }
            .frame(width: 180, height: 110).clipped()
            LinearGradient(colors: [.clear, Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name).font(.system(size: 16, weight: .bold)).foregroundColor(.white).lineLimit(1)
                Text(album.artist ?? "").font(.system(size: 12)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: 180, height: 110).cornerRadius(12)
    }
}

private struct SearchArtistCircle: View {
    let artist: Artist
    let isDark: Bool
    var body: some View {
        VStack(spacing: 8) {
            AsyncImage(url: artist.coverArtUrl) { img in img.resizable().scaledToFill() }
            placeholder: { Circle().fill(isDark ? Color.white.opacity(0.08) : Color(hex: "#e5e7eb")) }
            .frame(width: 80, height: 80).clipShape(Circle())
            Text(artist.name).font(.system(size: 12, weight: .bold))
                .foregroundColor(isDark ? .white : Color(hex: "#111827")).lineLimit(1).frame(width: 80, alignment: .center)
        }
        .frame(width: 80)
    }
}
