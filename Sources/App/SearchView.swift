import SwiftUI

@MainActor
struct SearchView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true

    @State private var query: String = ""
    @State private var tracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var isLoading: Bool = false

    // MARK: - Search Race Condition Guards
    /// Cancels any in-flight debounce sleep task when a new keystroke arrives.
    @State private var searchTask: Task<Void, Never>?
    /// Monotonically-increasing counter. Each new search increments it.
    /// Completion callbacks compare against this to discard stale responses.
    @State private var searchGeneration: Int = 0

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
                .padding(.bottom, 32)
            }
        }
        .background(Color.clear)
    }

    private func performSearch(query: String) {
        // ── Step 1: Cancel the previous debounce sleep (if still pending) ──────
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.tracks = []; self.albums = []; self.artists = []
            self.isLoading = false
            return
        }

        // ── Step 2: Mint a new generation token for this search attempt ────────
        searchGeneration &+= 1          // wrapping increment, never overflows
        let myGeneration = searchGeneration

        isLoading = true

        // ── Step 3: Debounce — sleep 300 ms, cancel if another keystroke arrives
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                // Task was cancelled (new keystroke arrived) — bail out silently
                return
            }

            // ── Step 4: Fire the network request or local search ─────────────────────────────
            if NetworkMonitor.shared.isConnected {
                client.search(query: trimmed) { foundTracks, foundAlbums, foundArtists in
                    // ── Step 5: Generation guard — discard stale responses ────────
                    guard self.searchGeneration == myGeneration else { return }
                    self.tracks = foundTracks
                    self.albums = foundAlbums
                    self.artists = foundArtists
                    self.isLoading = false
                }
            } else {
                // Offline Local Search
                let lowerQuery = trimmed.lowercased()

                // Tracks
                let foundTracks = DatabaseManager.shared.searchTracks(query: searchText).filter {
                    $0.title.lowercased().contains(lowerQuery) ||
                    ($0.artist?.lowercased().contains(lowerQuery) ?? false) ||
                    ($0.album?.lowercased().contains(lowerQuery) ?? false)
                }.filter { self.playback.isDownloaded($0.id) }

                // Albums
                let foundAlbums = self.client.albums.filter {
                    $0.name.lowercased().contains(lowerQuery) ||
                    ($0.artist?.lowercased().contains(lowerQuery) ?? false)
                }.filter { album in
                    DatabaseManager.shared.getTracks(albumId: album.id).contains { self.playback.isDownloaded($0.id) }
                }

                // Artists
                let foundArtists = self.client.artists.filter {
                    $0.name.lowercased().contains(lowerQuery)
                }.filter { artist in
                    DatabaseManager.shared.getTracks(artistId: artist.id).contains { self.playback.isDownloaded($0.id) }
                }

                Task { @MainActor in
                    guard self.searchGeneration == myGeneration else { return }
                    self.tracks = Array(foundTracks.prefix(20))
                    self.albums = Array(foundAlbums.prefix(10))
                    self.artists = Array(foundArtists.prefix(10))
                    self.isLoading = false
                }
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
                SelfHealingAsyncImage(url: track.coverArtUrl) { img in img.resizable().scaledToFill() }
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
            SelfHealingAsyncImage(url: album.coverArtUrl) { img in img.resizable().scaledToFill() }
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
            SelfHealingAsyncImage(url: artist.coverArtUrl) { img in img.resizable().scaledToFill() }
            placeholder: { Circle().fill(isDark ? Color.white.opacity(0.08) : Color(hex: "#e5e7eb")) }
            .frame(width: 80, height: 80).clipShape(Circle())
            Text(artist.name).font(.system(size: 12, weight: .bold))
                .foregroundColor(isDark ? .white : Color(hex: "#111827")).lineLimit(1).frame(width: 80, alignment: .center)
        }
        .frame(width: 80)
    }
}
