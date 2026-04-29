import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true

    @Environment(\.horizontalSizeClass) var hSizeClass
    @State private var activeCategory: String? = nil
    @State private var viewMode: ViewMode = .grid
    @State private var sortMode: SortMode = .alphabetical
    
    enum ViewMode { case grid, list }
    enum SortMode { case alphabetical, recent }
    
    var onArtistClick: ((String, String) -> Void)?

    var isCompact: Bool { hSizeClass == .compact }
    var hPad: CGFloat { isCompact ? 16 : 40 }

    let menuItems: [(id: String, label: String, icon: String)] = [
        ("playlists", "Playlists", "music.note.list"),
        ("artists",   "Artists",   "person.2"),
        ("albums",    "Albums",    "opticaldisc"),
        ("songs",     "Songs",     "music.note"),
    ]

    var body: some View {
        ZStack {
            Group {
                if let cat = activeCategory {
                    categoryDetailView(category: cat)
                } else {
                    LibraryMenuView(activeCategory: $activeCategory, menuItems: menuItems, isDarkMode: isDarkMode, isCompact: isCompact, hPad: hPad)
                }
            }
        }
        .background(Color.clear)
        .animation(.easeInOut(duration: 0.2), value: activeCategory)
        .task {
            if client.allSongs.isEmpty {
                client.fetchEverything()
            }
        }
    }

    @ViewBuilder
    private func categoryDetailView(category: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: isCompact ? 80 : 100)
            // Header
            HStack {
                Button(action: { activeCategory = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: isCompact ? 16 : 20, weight: .semibold))
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Library")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.red.opacity(0.6))
                                .textCase(.uppercase)
                            Text(menuItems.first(where: { $0.id == category })?.label ?? "")
                                .font(.system(size: isCompact ? 16 : 20, weight: .semibold))
                                .foregroundColor(.red)
                        }
                    }
                }
                Spacer()
                
                // View Mode & Sort Mode Controls
                HStack(spacing: isCompact ? 8 : 20) {
                    // View Toggle
                    Picker("View Mode", selection: $viewMode) {
                        Image(systemName: "square.grid.2x2.fill").tag(ViewMode.grid)
                        Image(systemName: "list.bullet").tag(ViewMode.list)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: isCompact ? 70 : 100)
                    .accessibilityLabel("Switch View Mode")

                    // Sort Toggle
                    Picker("Sort Mode", selection: $sortMode) {
                        Image(systemName: "textformat").tag(SortMode.alphabetical)
                        Image(systemName: "clock.fill").tag(SortMode.recent)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: isCompact ? 70 : 100)
                    .accessibilityLabel("Switch Sort Mode")
                }
            }
            .padding(.horizontal, hPad)
            .padding(.top, 8)
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                Group {
                    switch category {
                    case "playlists": PlaylistGridView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact)
                    case "artists":   ArtistGridView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact, onArtistClick: { id, name in
                        withAnimation {
                            onArtistClick?(id, name)
                        }
                    })
                    case "albums":    AlbumGridView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact)
                    case "songs":     SongListView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact)
                    default:          EmptyView()
                    }
                }
                .padding(.horizontal, hPad)
                Spacer(minLength: 120)
            }
        }
    }
}

// MARK: - Subviews

private struct LibraryMenuView: View {
    @EnvironmentObject var client: NavidromeClient
    @Binding var activeCategory: String?
    let menuItems: [(id: String, label: String, icon: String)]
    let isDarkMode: Bool
    let isCompact: Bool
    let hPad: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: isCompact ? 90 : 130)
                ForEach(menuItems, id: \.id) { item in
                    Button(action: { activeCategory = item.id }) {
                        HStack(spacing: 20) {
                            Image(systemName: item.icon).foregroundColor(.red).font(.system(size: isCompact ? 18 : 20)).frame(width: isCompact ? 28 : 32)
                            Text(item.label).font(.system(size: isCompact ? 18 : 20, weight: .medium))
                                .foregroundColor(isDarkMode ? .white : .black)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.gray).font(.system(size: isCompact ? 18 : 24))
                        }
                        .padding(.vertical, isCompact ? 16 : 22)
                        .padding(.horizontal, hPad)
                    }
                    Divider().padding(.horizontal, hPad).opacity(0.1)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.bar.fill").foregroundColor(.red).font(.system(size: isCompact ? 18 : 20))
                        Text("Insights").font(.system(size: isCompact ? 22 : 24, weight: .bold))
                    }
                    .padding(.horizontal, hPad)
                    let stats = [
                        ("Tracks", "\(client.allSongs.count)", "music.note", Color.blue),
                        ("Playlists", "\(client.playlists.count)", "music.note.list", Color.green),
                        ("Albums", "\(client.albums.count)", "opticaldisc", Color.orange),
                        ("Artists", "\(client.artists.count)", "person.2", Color.teal)
                    ]
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 140 : 200), spacing: 16)], spacing: 16) {
                        ForEach(stats, id: \.0) { stat in
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: stat.2).foregroundColor(stat.3).font(.system(size: isCompact ? 20 : 24))
                                Text(stat.0).font(.system(size: isCompact ? 12 : 14, weight: .medium)).foregroundColor(.gray).textCase(.uppercase)
                                Text(stat.1).font(.system(size: isCompact ? 22 : 24, weight: .bold))
                            }
                            .padding(isCompact ? 16 : 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 20).fill(isDarkMode ? Color.white.opacity(0.05) : Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.gray.opacity(0.1), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, hPad)
                }
                .padding(.top, 30)
            }
        }
    }
}

private struct PlaylistGridView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    let viewMode: LibraryView.ViewMode
    let sortMode: LibraryView.SortMode
    let isDarkMode: Bool
    let isCompact: Bool

    var body: some View {
        let sorted = client.playlists.sorted { a, b in
            sortMode == .alphabetical ? a.name < b.name : (a.created ?? "") > (b.created ?? "")
        }
        if viewMode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 140 : 160), spacing: 16)], spacing: 24) {
                ForEach(sorted) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(Color.gray.opacity(0.1)).aspectRatio(1, contentMode: .fit).cornerRadius(12)
                            .overlay(Image(systemName: "music.note.list").foregroundColor(.gray).font(.system(size: isCompact ? 24 : 32)))
                        Text(p.name).font(.system(size: isCompact ? 16 : 18, weight: .bold)).lineLimit(1)
                        Text("\(p.songCount ?? 0) tracks").font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray)
                    }
                    .onTapGesture { client.fetchPlaylistTracks(playlistId: p.id) { t in if !t.isEmpty { playback.playTrack(t[0], context: t) } } }
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sorted) { p in
                    HStack(spacing: 16) {
                        Image(systemName: "music.note.list").padding(10).background(Color.gray.opacity(0.1)).cornerRadius(10)
                            .font(.system(size: isCompact ? 16 : 20))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(.system(size: isCompact ? 16 : 18, weight: .bold))
                            Text("\(p.songCount ?? 0) tracks").font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.gray.opacity(0.5))
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { client.fetchPlaylistTracks(playlistId: p.id) { t in if !t.isEmpty { playback.playTrack(t[0], context: t) } } }
                    Divider().opacity(0.1)
                }
            }
        }
    }
}

private struct ArtistGridView: View {
    @EnvironmentObject var client: NavidromeClient
    let viewMode: LibraryView.ViewMode
    let sortMode: LibraryView.SortMode
    let isDarkMode: Bool
    let isCompact: Bool
    var onArtistClick: ((String, String) -> Void)?

    var body: some View {
        let sorted = client.artists.sorted { a, b in
            sortMode == .alphabetical ? a.name < b.name : (a.created ?? "") > (b.created ?? "")
        }
        if viewMode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 120 : 150), spacing: 16)], spacing: 24) {
                ForEach(sorted) { a in
                    VStack(spacing: 10) {
                        AsyncImage(url: a.coverArtUrl) { img in img.resizable().scaledToFill() } placeholder: { Circle().fill(Color.gray.opacity(0.1)) }
                            .frame(width: isCompact ? 120 : 150, height: isCompact ? 120 : 150).clipShape(Circle())
                        Text(a.name).font(.system(size: isCompact ? 15 : 20, weight: .bold)).lineLimit(1).multilineTextAlignment(.center)
                    }
                    .onTapGesture { onArtistClick?(a.id, a.name) }
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sorted) { a in
                    HStack(spacing: 16) {
                        AsyncImage(url: a.coverArtUrl) { img in img.resizable().scaledToFill() } placeholder: { Circle().fill(Color.gray.opacity(0.1)) }
                            .frame(width: isCompact ? 50 : 60, height: isCompact ? 50 : 60).clipShape(Circle())
                        Text(a.name).font(.system(size: isCompact ? 16 : 18, weight: .bold))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.gray.opacity(0.5))
                    }
                    .padding(.vertical, 10)
                    .onTapGesture { onArtistClick?(a.id, a.name) }
                    Divider().opacity(0.1)
                }
            }
        }
    }
}

private struct AlbumGridView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    let viewMode: LibraryView.ViewMode
    let sortMode: LibraryView.SortMode
    let isDarkMode: Bool
    let isCompact: Bool

    var body: some View {
        let sorted = client.albums.sorted { a, b in
            sortMode == .alphabetical ? a.name < b.name : (a.created ?? "") > (b.created ?? "")
        }
        if viewMode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 140 : 160), spacing: 16)], spacing: 24) {
                ForEach(sorted) { a in
                    VStack(alignment: .leading, spacing: 8) {
                        AsyncImage(url: a.coverArtUrl) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(Color.gray.opacity(0.1)) }
                            .aspectRatio(1, contentMode: .fit).cornerRadius(12)
                        Text(a.name).font(.system(size: isCompact ? 16 : 18, weight: .bold)).lineLimit(1)
                        Text(a.artist ?? "").font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray).lineLimit(1)
                    }
                    .onTapGesture { client.fetchAlbumTracks(albumId: a.id) { t in if !t.isEmpty { playback.playTrack(t[0], context: t) } } }
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sorted) { a in
                    HStack(spacing: 16) {
                        AsyncImage(url: a.coverArtUrl) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(Color.gray.opacity(0.1)) }
                            .frame(width: isCompact ? 50 : 60, height: isCompact ? 50 : 60).cornerRadius(8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.name).font(.system(size: isCompact ? 16 : 18, weight: .bold)).lineLimit(1)
                            Text(a.artist ?? "").font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.gray.opacity(0.5))
                    }
                    .padding(.vertical, 10)
                    .onTapGesture { client.fetchAlbumTracks(albumId: a.id) { t in if !t.isEmpty { playback.playTrack(t[0], context: t) } } }
                    Divider().opacity(0.1)
                }
            }
        }
    }
}

private struct SongListView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    let viewMode: LibraryView.ViewMode
    let sortMode: LibraryView.SortMode
    let isDarkMode: Bool
    let isCompact: Bool

    var body: some View {
        let sorted = client.allSongs.sorted { a, b in
            sortMode == .alphabetical ? a.title < b.title : (a.created ?? "") > (b.created ?? "")
        }
        
        if viewMode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 180 : 220), spacing: 16)], spacing: 24) {
                ForEach(sorted) { t in
                    VStack(alignment: .leading, spacing: 8) {
                        AsyncImage(url: t.coverArtUrl) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(Color.gray.opacity(0.1)) }
                            .aspectRatio(1, contentMode: .fit).cornerRadius(16)
                        Text(t.title).font(.system(size: isCompact ? 18 : 24, weight: .bold)).lineLimit(1)
                        Text(t.artist ?? "").font(.system(size: isCompact ? 14 : 18)).foregroundColor(.gray).lineLimit(1)
                    }
                    .onTapGesture { playback.playTrack(t, context: sorted) }
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sorted) { t in
                    HStack(spacing: 16) {
                        AsyncImage(url: t.coverArtUrl) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(Color.gray.opacity(0.1)) }
                            .frame(width: isCompact ? 48 : 56, height: isCompact ? 48 : 56).cornerRadius(8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.title).font(.system(size: isCompact ? 16 : 18, weight: .bold)).lineLimit(1)
                            Text(t.artist ?? "").font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray).lineLimit(1)
                        }
                        Spacer()
                        Text(t.durationFormatted).font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { playback.playTrack(t, context: sorted) }
                    Divider().opacity(0.1)
                }
            }
        }
    }
}
