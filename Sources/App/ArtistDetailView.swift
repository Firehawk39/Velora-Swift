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
    @State private var mbid: String? = nil
    @State private var relatedArtists: [Artist] = []
    @State private var isLoading: Bool = true
    @State private var scrollOffset: CGFloat = 0

    var isLargeCanvas: Bool { UIScreen.main.bounds.width >= 1150 }
    var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        ZStack(alignment: .topLeading) {
            (isDarkMode ? Color(hex: "#000000") : Color(hex: "#fafafa"))
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                        .frame(maxWidth: .infinity)
                        .background(
                            ArtistBackdropView(artistId: artistId, artistName: artistName, mbid: mbid, isDarkMode: isDarkMode, client: client)
                                .ignoresSafeArea(edges: .top)
                        )

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
                    .padding(.bottom, 48)
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .global).minY)
                })
            }
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                Task { @MainActor in
                    self.scrollOffset = value
                }
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
            (isDarkMode ? Color(hex: "#000000") : Color(hex: "#fafafa"))
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
                    Spacer(minLength: 0)

                    VStack(spacing: 6) {
                        artistLabel
                        artistNameText(size: ScreenTier.isSE ? 24 : 28)
                    }

                    playAllButton
                        .scaleEffect(ScreenTier.isPhone ? 0.85 : 0.95)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: ScreenTier.isSE ? 280 : 340)
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 32) {
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

                    Spacer(minLength: 0)

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
                .frame(maxWidth: .infinity)
                .frame(minHeight: 460)
                .padding(.horizontal, 48)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isCompact ? 60 : 40)
        .padding(.bottom, 32)
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
            .multilineTextAlignment(.center)
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

    private var studioAlbums: [Album] {
        albums.filter { album in
            let types = album.releaseTypes?.map { $0.lowercased() } ?? []
            if types.isEmpty { return true }
            return types.contains("album") && !types.contains("compilation") && !types.contains("soundtrack") && !types.contains("remix")
        }
    }

    private var singlesAndEPs: [Album] {
        albums.filter { album in
            let types = album.releaseTypes?.map { $0.lowercased() } ?? []
            return types.contains("single") || types.contains("ep")
        }
    }

    private var otherReleases: [Album] {
        albums.filter { album in
            let types = album.releaseTypes?.map { $0.lowercased() } ?? []
            return types.contains("compilation") || types.contains("soundtrack") || types.contains("remix") || types.contains("mixtape/street") || types.contains("live")
        }
    }

    private var discographySection: some View {
        let hasCategorization = !singlesAndEPs.isEmpty && !studioAlbums.isEmpty

        return VStack(alignment: .leading, spacing: 28) {
            if hasCategorization {
                if !studioAlbums.isEmpty {
                    albumSection(title: "Albums", albumList: studioAlbums)
                }
                if !singlesAndEPs.isEmpty {
                    albumSection(title: "Singles & EPs", albumList: singlesAndEPs)
                }
                if !otherReleases.isEmpty {
                    albumSection(title: "Compilations & More", albumList: otherReleases)
                }
            } else {
                albumSection(title: "Discography", albumList: albums)
            }
        }
    }

    private func albumSection(title: String, albumList: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 18, weight: .black))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, isCompact ? 24 : 48)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(albumList) { album in
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
        .padding(.top, 60)
        .zIndex(110)
    }

    private func fetchArtistData() {
        isLoading = true
        client.fetchArtistData(artistId: artistId, artistName: artistName) { tracks, albums, bio, mbid in
            DispatchQueue.main.async {
                self.topSongs = tracks.sorted(by: { ($0.playCount ?? 0) > ($1.playCount ?? 0) })
                self.favoriteSongs = tracks.filter { $0.isStarred }
                self.albums = albums
                self.mbid = mbid

                // Check network bio first, fallback to MusicBrainz offline cache
                self.biography = bio ?? MusicBrainzManager.shared.getArtistBiography(for: self.artistName)
                self.isLoading = false

                client.fetchArtists { artists in
                    DispatchQueue.main.async {
                        self.relatedArtists = Array(artists.shuffled().prefix(6)).filter { $0.id != artistId }
                    }
                }
            }
        }
    }
}

// MARK: - Dedicated Subviews to prevent flickering

struct ArtistPortraitView: View {
    let artistId: String
    let size: CGFloat
    let client: NavidromeClient
    let isDarkMode: Bool

    var body: some View {
        let fallbackUrl = client.getCoverArtUrl(id: artistId)
        let resolvedUrl = resolveArtistPortraitUrl(id: artistId, serverUrl: fallbackUrl)

        SelfHealingAsyncImage(url: resolvedUrl) { img in
            img.resizable()
                .scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.1)
        }
        .id(artistId)
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct SongArtworkView: View {
    let track: Track
    let isDarkMode: Bool
    var size: CGFloat? = nil
    var height: CGFloat? = nil

    var body: some View {
        if size == nil && height == nil {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    SelfHealingAsyncImage(url: track.coverArtUrl) { img in
                        img.resizable()
                            .scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.1)
                    }
                )
                .clipped()
                .cornerRadius(12)
                .id(track.id)
        } else {
            SelfHealingAsyncImage(url: track.coverArtUrl) { img in
                img.resizable()
                    .scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.1)
            }
            .id(track.id)
            .frame(width: size, height: height ?? size)
            .clipped()
            .cornerRadius((size == 56 || size == 48) ? 8 : 16)
        }
    }
}

struct ArtistBackdropView: View {
    let artistId: String
    let artistName: String
    let mbid: String?
    let isDarkMode: Bool
    let client: NavidromeClient
    
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass) var vSizeClass
    
    @State private var artistPalette: [UIColor] = [.black, .black, .black, .black, .black]
    @State private var artistPrimaryColor: UIColor = .black
    @State private var backdropImage: UIImage? = nil
    @State private var backdropUrl: URL? = nil
    
    var isCompact: Bool { hSizeClass == .compact }
    var isLandscape: Bool {
        if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return windowScene.coordinateSpace.bounds.width > windowScene.coordinateSpace.bounds.height
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            return UIScreen.main.bounds.width > UIScreen.main.bounds.height
        }
        return vSizeClass == .compact
    }

    private func resolveBackdropImage() -> UIImage? {
        let resolvedMbid = mbid ?? MusicBrainzManager.shared.getCachedMBID(for: artistName)
        if let img = FanartManager.shared.getCachedBackdrop(for: artistName, artistId: artistId, mbid: resolvedMbid) {
            return img
        }
        let primary = extractPrimaryArtist(artistName)
        if primary != artistName, let img = FanartManager.shared.getCachedBackdrop(for: primary, artistId: artistId, mbid: resolvedMbid) {
            return img
        }
        return nil
    }

    private func resolveBackdropUrl() -> URL? {
        let primary = extractPrimaryArtist(artistName)
        let resolvedMbid = mbid ?? MusicBrainzManager.shared.getCachedMBID(for: artistName)
        var candidates: [String] = []
        if let m = resolvedMbid, !m.isEmpty { candidates.append(m) }
        if !artistId.isEmpty { candidates.append(artistId) }
        let k1 = FanartManager.shared.getCacheKey(artistName: artistName, artistId: artistId)
        if !candidates.contains(k1) { candidates.append(k1) }
        let s1 = FanartManager.shared.sanitizeFileName(artistName)
        if !candidates.contains(s1) { candidates.append(s1) }
        let s2 = FanartManager.shared.sanitizeFileName(primary)
        if !candidates.contains(s2) { candidates.append(s2) }
        
        let sidecarUrl = VeloraStorage.backdrops.appendingPathComponent(k1 + ".mbid")
        if let data = try? Data(contentsOf: sidecarUrl),
           let cachedMbid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cachedMbid.isEmpty, !candidates.contains(cachedMbid) {
            candidates.append(cachedMbid)
        }

        for c in candidates {
            let file = VeloraStorage.backdrops.appendingPathComponent("\(c).jpg")
            if FileManager.default.fileExists(atPath: file.path),
               let attr = try? FileManager.default.attributesOfItem(atPath: file.path),
               (attr[.size] as? Int64 ?? 0) > 100 {
                return file
            }
        }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let activeImage = backdropImage ?? (resolveBackdropImage() ?? (backdropUrl ?? resolveBackdropUrl()).flatMap { (try? Data(contentsOf: $0)).flatMap { UIImage(data: $0) } })
            
            ZStack {
                // Plain background color fallback
                (isDarkMode ? Color(hex: "#000000") : Color(hex: "#fafafa"))
                    .ignoresSafeArea()
                    
                // High-Fidelity Fanart Backdrop with fallback gradient (portrait & landscape)
                if let image = activeImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .clipped()
                        .transition(.opacity.animation(.easeInOut(duration: 0.6)))
                } else {
                    fallbackGradient
                }
            }
            .overlay(
                // Combined Vignette: Dark edges + Vertical fade
                ZStack {
                    // Edge darkness (Radial)
                    RadialGradient(
                        gradient: Gradient(colors: [.clear, (isDarkMode ? Color.black : Color.white).opacity(0.85)]),
                        center: .center,
                        startRadius: 50,
                        endRadius: proxy.size.width * 1.2
                    )
                    .blendMode(isDarkMode ? .multiply : .normal)

                    // Vertical fade (Linear) fades to pure background at the bottom
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, (isDarkMode ? Color(hex: "#000000") : Color(hex: "#fafafa")).opacity(1.0)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            )
        }
        .onAppear {
            self.backdropImage = resolveBackdropImage()
            self.backdropUrl = resolveBackdropUrl()
            fetchColors()
            triggerBackdropFetch()
        }
        .onChange(of: mbid) { _ in
            self.backdropImage = resolveBackdropImage()
            self.backdropUrl = resolveBackdropUrl()
            triggerBackdropFetch()
        }
    }
    
    private func triggerBackdropFetch() {
        if let current = resolveBackdropImage() {
            self.backdropImage = current
            self.backdropUrl = resolveBackdropUrl()
            return
        }
        Task {
            await FanartManager.shared.downloadBackdropSilently(for: [artistName], artistId: artistId, mbid: mbid)
            await MainActor.run {
                if let resolved = resolveBackdropImage() {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        self.backdropImage = resolved
                        self.backdropUrl = resolveBackdropUrl()
                    }
                }
            }
        }
    }
    
    private var artistPaletteKey: String {
        artistPalette.map { c in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return "\(Int(r*255)),\(Int(g*255)),\(Int(b*255))"
        }.joined(separator: "-")
    }

    @ViewBuilder
    private var fallbackGradient: some View {
        AlbumAmbientGradientView(colors: artistPalette, isLandscape: isLandscape)
            .id(artistPaletteKey)
            .animation(.easeInOut(duration: 0.6), value: artistPaletteKey)
            .transition(.opacity.animation(.easeInOut(duration: 0.6)))
    }
    
    private func fetchColors() {
        let cachedBackdropImg = resolveBackdropImage()
        let cachedBackdropUrl = resolveBackdropUrl()
        let fallbackUrl = client.getCoverArtUrl(id: artistId, size: 600)
        let portraitUrl = resolveArtistPortraitUrl(id: artistId, serverUrl: fallbackUrl)

        Task.detached {
            var targetImg: UIImage? = cachedBackdropImg
            if targetImg == nil, let backdrop = cachedBackdropUrl, backdrop.isFileURL,
               let data = try? Data(contentsOf: backdrop) {
                targetImg = UIImage(data: data)
            } else if targetImg == nil, let url = portraitUrl {
                if url.isFileURL, let data = try? Data(contentsOf: url) {
                    targetImg = UIImage(data: data)
                } else if let data = try? await URLSession.shared.data(from: url).0 {
                    targetImg = UIImage(data: data)
                }
            }

            if let img = targetImg {
                let primary = img.dominantColor() ?? .black
                let palette = img.extractPalette(count: 5)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        self.artistPrimaryColor = primary
                        self.artistPalette = palette
                    }
                }
            }
        }
    }
}


