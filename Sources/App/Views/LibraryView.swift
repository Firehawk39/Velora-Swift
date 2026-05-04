import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var aiManager: AIManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true

    @Environment(\.horizontalSizeClass) var hSizeClass
    @State private var activeCategory: String? = nil
    @State private var viewMode: ViewMode = .grid
    @State private var sortMode: SortMode = .alphabetical
    @State private var showSortDropdown: Bool = false
    @State private var selectedPlaylist: Playlist? = nil
    @State private var playlistTracks: [Track] = []
    @State private var isLoadingPlaylist: Bool = false
    
    enum ViewMode { case grid, list }
    enum SortMode { case alphabetical, recent, topPlayed }
    
    var onArtistClick: ((String, String) -> Void)?

    var isCompact: Bool { hSizeClass == .compact }
    var hPad: CGFloat { isCompact ? 24 : 48 }
    private let menuItems = [
        ("playlists", "Playlists", "music.note.list"),
        ("artists",   "Artists",   "person.2"),
        ("albums",    "Albums",    "opticaldisc"),
        ("songs",     "Songs",     "music.note"),
    ]

    var body: some View {
        ZStack {
            Group {
                if let playlist = selectedPlaylist {
                    PlaylistDetailView(playlist: playlist, tracks: $playlistTracks, isLoading: $isLoadingPlaylist, isDarkMode: isDarkMode, isCompact: isCompact, hPad: hPad) {
                        selectedPlaylist = nil
                        playlistTracks = []
                    }
                } else if let cat = activeCategory {
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
    private func categoryDetailView(category: String, forceOffline: Bool = false) -> some View {
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
                            Text(forceOffline ? "Downloaded" : (menuItems.first(where: { $0.0 == category })?.1 ?? ""))
                                .font(.system(size: isCompact ? 16 : 20, weight: .semibold))
                                .foregroundColor(.red)
                        }
                    }
                }
                Spacer()
                
                // View Mode & Sort Mode Controls
                HStack(spacing: isCompact ? 12 : 20) {
                    // View Mode Menu
                    Menu {
                        Button(action: { viewMode = .grid }) {
                            Label("Grid View", systemImage: "square.grid.2x2.fill")
                        }
                        Button(action: { viewMode = .list }) {
                            Label("List View", systemImage: "list.bullet")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: viewMode == .grid ? "square.grid.2x2.fill" : "list.bullet")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                        .foregroundColor(isDarkMode ? .white : .black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
                    }
                    .accessibilityLabel("View Options")
                    
                    // Offline Only Toggle
                    Button(action: { playback.showOfflineOnly.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: playback.showOfflineOnly ? "checkmark.icloud.fill" : "icloud")
                            if !isCompact {
                                Text("Offline")
                            }
                        }
                        .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                        .foregroundColor(playback.showOfflineOnly ? .red : (isDarkMode ? .white : .black))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(playback.showOfflineOnly ? Color.red.opacity(0.1) : (isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))))
                    }
                    .accessibilityLabel("Offline Only Filter")
                    
                    // Sort Mode Menu
                    Menu {
                        Button(action: { sortMode = .alphabetical }) {
                            Label("Alphabetical", systemImage: "textformat")
                        }
                        Button(action: { sortMode = .recent }) {
                            Label("Recently Added", systemImage: "clock.fill")
                        }
                        Button(action: { sortMode = .topPlayed }) {
                            Label("Top Played", systemImage: "play.circle.fill")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sortMode == .alphabetical ? "textformat" : (sortMode == .recent ? "clock.fill" : "play.circle.fill"))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                        .foregroundColor(isDarkMode ? .white : .black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
                    }
                    .accessibilityLabel("Sort Options")
                    
                    // Shuffle & Download All for Songs
                    if category == "songs" {
                        HStack(spacing: 8) {
                            Button(action: {
                                playback.shufflePlay(tracks: client.allSongs)
                            }) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel("Shuffle Play All")
                            
                            HStack(spacing: 6) {
                                if sync.isSyncing && sync.syncType == .media && !sync.etaString.isEmpty {
                                    Text(sync.etaString)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.red)
                                }
                                
                                Button(action: {
                                     if sync.isSyncing && sync.syncType == .media {
                                         sync.stopSync()
                                     } else {
                                         sync.startMediaSync()
                                     }
                                 }) {
                                     ZStack {
                                         if sync.isSyncing && sync.syncType == .media {
                                             CircularProgressView(progress: sync.syncProgress, size: 24, strokeWidth: 2.5, accentColor: .red)
                                         } else {
                                             Image(systemName: "icloud.and.arrow.down.fill")
                                                 .font(.system(size: 14, weight: .bold))
                                                 .foregroundColor(.white)
                                         }
                                     }
                                     .frame(width: 36, height: 36)
                                     .background(sync.isSyncing && sync.syncType == .media ? Color.red.opacity(0.1) : (isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
                                     .clipShape(Circle())
                                 }
                                 .accessibilityLabel("Sync All Library")
                             }
                        }
                    }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.top, 8)
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                Group {
                    switch category {
                    case "playlists": PlaylistGridView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact, showOfflineOnly: playback.showOfflineOnly || forceOffline) { p in
                        selectedPlaylist = p
                        isLoadingPlaylist = true
                        client.fetchPlaylistTracks(playlistId: p.id) { t in
                            self.playlistTracks = t
                            self.isLoadingPlaylist = false
                        }
                    }
                    case "artists":   ArtistGridView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact, showOfflineOnly: playback.showOfflineOnly || forceOffline, onArtistClick: { id, name in
                        withAnimation {
                            onArtistClick?(id, name)
                        }
                    })
                    case "albums":    AlbumGridView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact, showOfflineOnly: playback.showOfflineOnly || forceOffline)
                    case "songs":     SongListView(viewMode: viewMode, sortMode: sortMode, isDarkMode: isDarkMode, isCompact: isCompact, showOfflineOnly: playback.showOfflineOnly || forceOffline)
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
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 140 : 240), spacing: 16)], spacing: 16) {
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

                // MARK: - AI Audit & Enrichment
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundColor(.red).font(.system(size: isCompact ? 18 : 20))
                        Text("AI Studio").font(.system(size: isCompact ? 22 : 24, weight: .bold))
                        Spacer()
                        if aiManager.isProcessing {
                            LoadingCircle(size: 20, strokeWidth: 2.5, accentColor: .red)
                        }
                    }
                    .padding(.horizontal, hPad)

                    VStack(alignment: .leading, spacing: 20) {
                        if !aiManager.auditStatus.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(aiManager.auditStatus)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.red)
                                
                                if aiManager.isProcessing && aiManager.fixProgress > 0 {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.red.opacity(0.1))
                                            Capsule().fill(Color.red)
                                                .frame(width: geo.size.width * CGFloat(aiManager.fixProgress))
                                        }
                                    }
                                    .frame(height: 6)
                                }
                            }
                            .padding(.horizontal, hPad)
                        }

                        if !aiManager.auditResults.isEmpty && !aiManager.isProcessing {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(aiManager.auditResults) { result in
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Image(systemName: iconForIssue(result.type))
                                                    .foregroundColor(.red)
                                                Text("\(result.count)")
                                                    .font(.system(size: 16, weight: .bold))
                                            }
                                            Text(result.type.rawValue)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.gray)
                                        }
                                        .padding(12)
                                        .frame(width: 110, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 16).fill(isDarkMode ? Color.white.opacity(0.05) : Color.white))
                                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.1), lineWidth: 1))
                                    }
                                }
                                .padding(.horizontal, hPad)
                            }
                        }

                        HStack(spacing: 12) {
                            Button(action: {
                                Task { await aiManager.runLibraryAudit() }
                            }) {
                                Text(aiManager.auditResults.isEmpty ? "Audit Library" : "Re-Audit")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(isDarkMode ? .white : .black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Capsule().fill(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
                            }
                            .disabled(aiManager.isProcessing)

                            if !aiManager.auditResults.isEmpty || aiManager.isProcessing {
                                Button(action: {
                                    Task { await aiManager.fixLibraryIssues() }
                                }) {
                                    HStack(spacing: 8) {
                                        if !aiManager.isProcessing {
                                            Image(systemName: "wand.and.stars")
                                        }
                                        Text(aiManager.isProcessing ? "Optimizing..." : "Enrich All")
                                    }
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(aiManager.isProcessing ? Color.gray : Color.red)
                                    .clipShape(Capsule())
                                }
                                .disabled(aiManager.isProcessing)
                            }
                        }
                        .padding(.horizontal, hPad)
                    }
                    .padding(.vertical, 24)
                    .background(RoundedRectangle(cornerRadius: 24).fill(isDarkMode ? Color.white.opacity(0.02) : Color.black.opacity(0.02)))
                    .padding(.horizontal, hPad)
                }
                .padding(.top, 20)
            }
        }
    }

    private func iconForIssue(_ type: IssueType) -> String {
        switch type {
        case .missingGenre: return "tag.fill"
        case .missingYear: return "calendar"
        case .lowResArt: return "photo.fill"
        case .missingMetadata: return "person.text.rectangle.fill"
        case .missingBackdrop: return "panorama.fill"
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
    let showOfflineOnly: Bool
    var onPlaylistClick: (Playlist) -> Void
    
    @State private var showCreateAlert = false
    @State private var newPlaylistName = ""

    var body: some View {
        let base = client.playlists
        let filtered = showOfflineOnly ? playback.filterOffline(base, allSongs: client.allSongs) : base
        
        let sorted = filtered.sorted { a, b in
            if sortMode == .alphabetical { return a.name < b.name }
            if sortMode == .topPlayed { return false } // Playlists don't have play counts
            return (a.created ?? "") > (b.created ?? "")
        }
        Group {
            if viewMode == .grid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isCompact ? 12 : 20), count: isCompact ? 3 : 6), spacing: isCompact ? 16 : 24) {
                    // Create New Button
                    Button(action: { showCreateAlert = true }) {
                        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
                            RoundedRectangle(cornerRadius: isCompact ? 8 : 12)
                                .stroke(Color.red.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5]))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(Image(systemName: "plus").foregroundColor(.red).font(.system(size: isCompact ? 24 : 32)))
                            
                            Text("New Playlist")
                                .font(.system(size: isCompact ? 14 : 16, weight: .bold))
                                .foregroundColor(.red)
                            Spacer().frame(height: 14)
                        }
                    }
                    
                    ForEach(sorted) { p in
                        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
                            Rectangle().fill(Color.gray.opacity(0.1)).aspectRatio(1, contentMode: .fit).cornerRadius(isCompact ? 8 : 12)
                                .overlay(Image(systemName: "music.note.list").foregroundColor(.gray).font(.system(size: isCompact ? 20 : 28)))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .font(.system(size: isCompact ? 14 : 16, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                Text("\(p.songCount ?? 0) tracks")
                                    .font(.system(size: isCompact ? 11 : 13))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                        .onTapGesture { onPlaylistClick(p) }
                        .contextMenu {
                            Button(role: .destructive, action: {
                                client.deletePlaylist(id: p.id) { _ in }
                            }) {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    // Create New Row
                    Button(action: { showCreateAlert = true }) {
                        HStack(spacing: 16) {
                            Image(systemName: "plus.circle.fill").foregroundColor(.red).font(.system(size: isCompact ? 24 : 28))
                            Text("Create New Playlist").font(.system(size: isCompact ? 16 : 18, weight: .bold)).foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    }
                    Divider().opacity(0.1)

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
                        .onTapGesture { onPlaylistClick(p) }
                        .contextMenu {
                            Button(role: .destructive, action: {
                                client.deletePlaylist(id: p.id) { _ in }
                            }) {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                         Divider().opacity(0.1)
                    }
                }
            }
        }
        .alert("New Playlist", isPresented: $showCreateAlert) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                if !newPlaylistName.isEmpty {
                    client.createPlaylist(name: newPlaylistName, songIds: []) { _ in
                        newPlaylistName = ""
                    }
                }
            }
        } message: {
            Text("Enter a name for your new playlist.")
        }
    }
}

private struct ArtistGridView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    let viewMode: LibraryView.ViewMode
    let sortMode: LibraryView.SortMode
    let isDarkMode: Bool
    let isCompact: Bool
    let showOfflineOnly: Bool
    var onArtistClick: ((String, String) -> Void)?

    var body: some View {
        let base = client.artists
        let filtered = showOfflineOnly ? playback.filterOffline(base, allSongs: client.allSongs) : base
        
        let sorted = filtered.sorted { a, b in
            if sortMode == .alphabetical { return a.name < b.name }
            if sortMode == .topPlayed { return false } // Artists don't have direct play counts in this model yet
            return (a.created ?? "") > (b.created ?? "")
        }
        if viewMode == .grid {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isCompact ? 12 : 20), count: isCompact ? 3 : 6), spacing: isCompact ? 16 : 24) {
                ForEach(sorted) { a in
                    VStack(spacing: isCompact ? 6 : 8) {
                        ArtistPortraitView(artistId: a.id, artistName: a.name, size: isCompact ? 100 : 180, client: client, isDarkMode: isDarkMode)
                            .id("artist-grid-\(a.id)")
                        
                        Text(a.name)
                            .font(.system(size: isCompact ? 14 : 16, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .multilineTextAlignment(.center)
                    }
                    .onTapGesture { onArtistClick?(a.id, a.name) }
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sorted) { a in
                    HStack(spacing: 16) {
                    ArtistPortraitView(artistId: a.id, artistName: a.name, size: isCompact ? 40 : 50, client: client, isDarkMode: isDarkMode)
                            .id("artist-list-\(a.id)")
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
    let showOfflineOnly: Bool

    var body: some View {
        let base = client.albums
        let filtered = showOfflineOnly ? playback.filterOffline(base, allSongs: client.allSongs) : base
        
        let sorted = filtered.sorted { a, b in
            if sortMode == .alphabetical { return a.name < b.name }
            if sortMode == .topPlayed { return false } // Albums don't have direct play counts in this model yet
            return (a.created ?? "") > (b.created ?? "")
        }
        if viewMode == .grid {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isCompact ? 12 : 20), count: isCompact ? 3 : 6), spacing: isCompact ? 16 : 24) {
                ForEach(sorted) { a in
                    VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
                        AsyncImage(url: a.coverArtUrl) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(Color.gray.opacity(0.1)) }
                            .aspectRatio(1, contentMode: .fit).cornerRadius(isCompact ? 8 : 12)
                            .id("album-grid-\(a.id)")
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name)
                                .font(.system(size: isCompact ? 14 : 16, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text(a.artist ?? "")
                                .font(.system(size: isCompact ? 11 : 13))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
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
                            .id("album-list-\(a.id)")
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
    let showOfflineOnly: Bool

    var body: some View {
        let base = client.allSongs
        let filtered = showOfflineOnly ? playback.filterOffline(base) : base
        
        let sorted = filtered.sorted { a, b in
            if sortMode == .alphabetical { return a.title < b.title }
            if sortMode == .topPlayed { return (a.playCount ?? 0) > (b.playCount ?? 0) }
            return (a.created ?? "") > (b.created ?? "")
        }
        
        if viewMode == .grid {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isCompact ? 12 : 20), count: isCompact ? 3 : 6), spacing: isCompact ? 16 : 24) {
                ForEach(sorted) { t in
                    VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
                        SongArtworkView(track: t, isDarkMode: isDarkMode)
                            .id("song-grid-\(t.id)")
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.title)
                                    .font(.system(size: isCompact ? 14 : 16, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                
                                if let progress = playback.downloadProgress[t.id] {
                                    Spacer()
                                    HStack(spacing: 4) {
                                        if let eta = playback.downloadETAs[t.id] {
                                            Text(eta)
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundColor(.gray)
                                        }
                                        CircularProgressView(progress: progress, size: 12, strokeWidth: 1.5, accentColor: .red)
                                    }
                                }
                            }
                            Text(t.artist ?? "")
                                .font(.system(size: isCompact ? 11 : 13))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .onTapGesture { playback.playTrack(t, context: sorted) }
                    .contextMenu {
                        Menu("Add to Playlist...") {
                            ForEach(client.playlists) { p in
                                Button(action: {
                                    client.updatePlaylist(id: p.id, songIdsToAdd: [t.id]) { _ in }
                                }) {
                                    Label(p.name, systemImage: "music.note.list")
                                }
                            }
                        }
                        Button(action: {
                            playback.downloadTrack(t)
                        }) {
                            Label(playback.isDownloaded(t.id) ? "Downloaded" : "Download", systemImage: playback.isDownloaded(t.id) ? "checkmark.circle.fill" : "arrow.down.circle")
                        }
                        .disabled(playback.isDownloaded(t.id))
                    }
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sorted) { t in
                    HStack(spacing: 16) {
                        SongArtworkView(track: t, isDarkMode: isDarkMode, size: isCompact ? 48 : 56)
                            .id("song-list-\(t.id)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.title).font(.system(size: isCompact ? 16 : 18, weight: .bold)).lineLimit(1)
                            Text(t.artist ?? "").font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray).lineLimit(1)
                        }
                        Spacer()
                        if let progress = playback.downloadProgress[t.id] {
                            HStack(spacing: 8) {
                                if let eta = playback.downloadETAs[t.id] {
                                    Text(eta)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.gray)
                                }
                                CircularProgressView(progress: progress, size: 18, strokeWidth: 2, accentColor: .red)
                            }
                        } else {
                            Text(t.durationFormatted).font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { playback.playTrack(t, context: sorted) }
                    .contextMenu {
                        Menu("Add to Playlist...") {
                            ForEach(client.playlists) { p in
                                Button(action: {
                                    client.updatePlaylist(id: p.id, songIdsToAdd: [t.id]) { _ in }
                                }) {
                                    Label(p.name, systemImage: "music.note.list")
                                }
                            }
                        }
                        
                        Button(action: {
                            playback.downloadTrack(t)
                        }) {
                            Label(playback.isDownloaded(t.id) ? "Downloaded" : "Download", systemImage: playback.isDownloaded(t.id) ? "checkmark.circle.fill" : "arrow.down.circle")
                        }
                        .disabled(playback.isDownloaded(t.id))
                    }
                    Divider().opacity(0.1)
                }
            }
        }
    }
}

// MARK: - Playlist Detail View

private struct PlaylistDetailView: View {
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var playback: PlaybackManager
    let playlist: Playlist
    @Binding var tracks: [Track]
    @Binding var isLoading: Bool
    let isDarkMode: Bool
    let isCompact: Bool
    let hPad: CGFloat
    var onBack: () -> Void
    
    @State private var viewMode: LibraryView.ViewMode = .list
    @State private var sortMode: LibraryView.SortMode = .alphabetical

    var body: some View {
        let filtered = playback.showOfflineOnly ? playback.filterOffline(tracks) : tracks
        let sorted = filtered.sorted { a, b in
            if sortMode == .alphabetical { return a.title < b.title }
            if sortMode == .topPlayed { return (a.playCount ?? 0) > (b.playCount ?? 0) }
            if sortMode == .recent { return (a.created ?? "") > (b.created ?? "") }
            return a.title < b.title
        }

        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: isCompact ? 80 : 100)
            
            // Header with Filters & Toggles
            HStack(alignment: .center, spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: isCompact ? 16 : 20, weight: .semibold))
                        Text("Back")
                            .font(.system(size: isCompact ? 16 : 20, weight: .semibold))
                    }
                    .foregroundColor(.red)
                }
                
                Spacer()
                
                // View Mode Menu (Matching Songs style)
                Menu {
                    Button(action: { viewMode = .grid }) {
                        Label("Grid", systemImage: "square.grid.2x2.fill")
                    }
                    Button(action: { viewMode = .list }) {
                        Label("List", systemImage: "list.bullet")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewMode == .grid ? "square.grid.2x2.fill" : "list.bullet")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                    .foregroundColor(isDarkMode ? .white : .black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
                }
                
                // Offline Only Toggle (Matching Songs style)
                Button(action: { playback.showOfflineOnly.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: playback.showOfflineOnly ? "checkmark.icloud.fill" : "icloud")
                        if !isCompact {
                            Text("Offline")
                        }
                    }
                    .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                    .foregroundColor(playback.showOfflineOnly ? .red : (isDarkMode ? .white : .black))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(playback.showOfflineOnly ? Color.red.opacity(0.1) : (isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))))
                }
                
                // Sort Mode Menu (Matching Songs style)
                Menu {
                    Button(action: { sortMode = .alphabetical }) {
                        Label("Alphabetical", systemImage: "textformat")
                    }
                    Button(action: { sortMode = .recent }) {
                        Label("Recently Added", systemImage: "clock.fill")
                    }
                    Button(action: { sortMode = .topPlayed }) {
                        Label("Top Played", systemImage: "play.circle.fill")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sortMode == .alphabetical ? "textformat" : (sortMode == .recent ? "clock.fill" : "play.circle.fill"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                    .foregroundColor(isDarkMode ? .white : .black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
                }

                Button(action: { playback.shufflePlay(tracks: sorted) }) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .disabled(sorted.isEmpty)
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: isCompact ? 28 : 36, weight: .bold))
                    .foregroundColor(isDarkMode ? .white : .black)
                Text("\(sorted.count) tracks • \(playlist.owner ?? "Unknown")")
                    .font(.system(size: isCompact ? 14 : 16))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, 30)

            if isLoading {
                VStack {
                    Spacer()
                    LoadingCircle(size: 40, strokeWidth: 4, accentColor: .red)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if sorted.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "music.note.list").font(.system(size: 40)).foregroundColor(.gray.opacity(0.3))
                    Text(playback.showOfflineOnly ? "No offline tracks in this playlist" : "No tracks in this playlist").foregroundColor(.gray)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    Group {
                        if viewMode == .list {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, track in
                                    playlistTrackRow(track: track, index: index, allTracks: sorted)
                                    Divider().opacity(0.1)
                                }
                            }
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isCompact ? 12 : 20), count: isCompact ? 3 : 6), spacing: isCompact ? 16 : 24) {
                                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, track in
                                    playlistTrackGridItem(track: track, index: index, allTracks: sorted)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, hPad)
                    Spacer(minLength: 120)
                }
            }
        }
    }

    @ViewBuilder
    private func playlistTrackRow(track: Track, index: Int, allTracks: [Track]) -> some View {
        HStack(spacing: 16) {
            SongArtworkView(track: track, isDarkMode: isDarkMode, size: isCompact ? 48 : 56)
                .id("playlist-row-\(track.id)")
            
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.system(size: isCompact ? 16 : 18, weight: .bold)).lineLimit(1)
                Text(track.artist ?? "").font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
            if let progress = playback.downloadProgress[track.id] {
                HStack(spacing: 8) {
                    if let eta = playback.downloadETAs[track.id] {
                        Text(eta)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    CircularProgressView(progress: progress, size: 18, strokeWidth: 2, accentColor: .red)
                }
            } else {
                Text(track.durationFormatted).font(.system(size: isCompact ? 12 : 14)).foregroundColor(.gray)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { playback.playTrack(track, context: allTracks) }
        .contextMenu {
            playlistContextMenu(track: track, index: index)
        }
    }

    @ViewBuilder
    private func playlistTrackGridItem(track: Track, index: Int, allTracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            ZStack(alignment: .topTrailing) {
                SongArtworkView(track: track, isDarkMode: isDarkMode)
                    .id("playlist-grid-\(track.id)")
                
                if let progress = playback.downloadProgress[track.id] {
                    CircularProgressView(progress: progress, size: 16, strokeWidth: 2, accentColor: .red)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .padding(4)
                } else if playback.isDownloaded(track.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.3)))
                        .padding(4)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: isCompact ? 14 : 16, weight: .bold))
                    .lineLimit(1)
                Text(track.artist ?? "")
                    .font(.system(size: isCompact ? 11 : 13))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .onTapGesture { playback.playTrack(track, context: allTracks) }
        .contextMenu {
            playlistContextMenu(track: track, index: index)
        }
    }

    @ViewBuilder
    private func playlistContextMenu(track: Track, index: Int) -> some View {
        Button(role: .destructive, action: {
            client.updatePlaylist(id: playlist.id, songIndicesToRemove: [index]) { success in
                if success {
                    client.fetchPlaylistTracks(playlistId: playlist.id) { updated in
                        self.tracks = updated
                    }
                }
            }
        }) {
            Label("Remove from Playlist", systemImage: "minus.circle")
        }
        
        Button(action: {
            playback.downloadTrack(track)
        }) {
            Label(playback.isDownloaded(track.id) ? "Downloaded" : "Download", systemImage: playback.isDownloaded(track.id) ? "checkmark.circle.fill" : "arrow.down.circle")
        }
        .disabled(playback.isDownloaded(track.id))
    }
}
