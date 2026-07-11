import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var client: NavidromeClient
    @StateObject private var playback: PlaybackManager

    @State private var activeTab: String = "home"
    @State private var showSettings: Bool = false
    @State private var showProfileMenu: Bool = false
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    @State private var isQueueOpen: Bool = false
    @State private var isIdle: Bool = false

    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass) var vSizeClass
    var isCompact: Bool { hSizeClass == .compact }

    var isLargeCanvas: Bool { UIScreen.main.bounds.width >= 1150.0 } // Increased threshold to avoid overflow on 10.25" screens
    var isSmallDevice: Bool { UIScreen.main.bounds.width <= 375 } // iPhone SE, Mini, etc.
    var isLandscape: Bool {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return UIScreen.main.bounds.width > UIScreen.main.bounds.height
        }
        return vSizeClass == .compact
    }

    var headerHeight: CGFloat {
        if ScreenTier.isSmall && !isLandscape {
            return 70
        }
        return UIScreen.main.bounds.width < 768 ? 72 : 80
    }

    @AppStorage("velora_username") var username: String = ""

    private var isHeaderHidden: Bool {
        (isIdle && activeTab == "now-playing") ||
        (activeTab == "now-playing" && playback.isLyricsMode) ||
        !artistStack.isEmpty
    }

    init() {
        let clientInstance = NavidromeClient()
        let playbackInstance = PlaybackManager(client: clientInstance)
        _client = StateObject(wrappedValue: clientInstance)
        _playback = StateObject(wrappedValue: playbackInstance)
    }

    @ObservedObject private var network = NetworkMonitor.shared
    @State private var tabScrollOffset: CGFloat = 0
    @State private var rawScrollOffset: CGFloat = 0




    var body: some View {
        GeometryReader { outerGeo in
            ZStack(alignment: .top) {
            // ── Layer 1: Global Canvas Background ──────────────────────────
            Color(hex: (isDarkMode || activeTab == "now-playing") ? "#000000" : "#f0f0f0")
                .ignoresSafeArea()

            // ── Layer 2: Seamless Main Layout ───────────────────────────────
            ZStack(alignment: .top) {
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, (ScreenTier.isPhone && !isLandscape) ? 75 : 0)

                AppHeader(
                    activeTab: $activeTab,
                    showProfileMenu: $showProfileMenu,
                    isDarkMode: isDarkMode,
                    toggleDark: { isDarkMode.toggle() },
                    onAction: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            artistStack.removeAll()
                            artistDetailOffset = 0
                        }
                    },
                    scrollOffset: rawScrollOffset
                )
                .padding(.top, 14)
                .opacity(isHeaderHidden ? 0 : 1)
                .offset(y: isHeaderHidden ? -100 : 0)
                .allowsHitTesting(!isHeaderHidden)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isHeaderHidden)
                .zIndex(300)

                artistDetailOverlay
                    .zIndex(200)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            // ── Layer 5: Profile menu dropdown ──────────────────────
            if showProfileMenu {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.2)) { showProfileMenu = false } }
                    .zIndex(900)

                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        ProfileDropdown(
                            isDarkMode: isDarkMode,
                            toggleDark: { isDarkMode.toggle() },
                            onSettings: { showProfileMenu = false; activeTab = "settings" },
                            isLandscape: isLandscape,
                            isPlayingTab: activeTab == "now-playing"
                        )
                        .padding(.trailing, isCompact ? 24.0 : 48.0)
                        .padding(.top, headerHeight + 8)
                    }
                    Spacer()
                }
                .zIndex(950)
            }

            // ── Layer 6: Queue panel ───────────────────────────────
            if isQueueOpen {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { isQueueOpen = false } }
                    .zIndex(300)

                HStack {
                    Spacer()
                    QueuePanel(isDarkMode: true, onClose: { withAnimation { isQueueOpen = false } })
                }
                .ignoresSafeArea()
                .zIndex(350)
            }


        }
        .environmentObject(client)
        .environmentObject(playback)
        .environmentObject(SyncManager.shared)
        .preferredColorScheme((isDarkMode || activeTab == "now-playing") ? .dark : .light)
        .statusBarHidden(true)
        .hidePersistentSystemOverlays()
        .onAppear {
            SyncManager.shared.configure(client: client, playback: playback)
            autoLogin()
        }
        .onChange(of: activeTab) { _ in
            rawScrollOffset = 0
            
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isIdle = false
                artistDetailOffset = UIScreen.main.bounds.width
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                artistStack.removeAll()
                artistDetailOffset = 0
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(showSettings: $showSettings)
                .environmentObject(client)
        }
        }
    }

    // MARK: — Artist navigation back-stack
    // Each entry is a (id, name) pair. The overlay always shows the last element.
    @State private var artistStack: [(id: String, name: String)] = []

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            switch activeTab {
            case "home":
                HomeView(onArtistClick: { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        artistStack.append((id: id, name: name))
                    }
                }, onSeeAll: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        activeTab = "library"
                    }
                }, onScroll: { val in rawScrollOffset = val })
            case "library":
                LibraryView(onArtistClick: { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        artistStack.append((id: id, name: name))
                    }
                }, onScroll: { val in rawScrollOffset = val })
            case "settings":
                AppSettingsView()
            case "search":
                SearchView(onArtistClick: { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        artistStack.append((id: id, name: name))
                    }
                })
            case "velora":
                VeloraChatView()
            case "now-playing":
                NowPlayingView(isQueueOpen: $isQueueOpen, isIdle: $isIdle, onArtistClick: { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        artistStack.append((id: id, name: name))
                    }
                }, onScroll: { val in rawScrollOffset = val })
            default:
                HomeView()
            }
        }
        .onChange(of: isIdle) { newValue in
            if newValue {
                withAnimation(.spring(response: 0.3)) {
                    showProfileMenu = false
                    isQueueOpen = false
                }
            }
        }
    }

    @State private var artistDetailOffset: CGFloat = 0

    @ViewBuilder
    private var artistDetailOverlay: some View {
        if let entry = artistStack.last {
            ArtistDetailView(
                artistId: entry.id,
                artistName: entry.name,
                onArtistClick: { nextId, nextName in
                    // Push onto back-stack — preserves full history
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        artistStack.append((id: nextId, name: nextName))
                        artistDetailOffset = 0
                    }
                },
                onPlay: { track, ctx in playback.playTrack(track, context: ctx) },
                onBack: {
                    // Pop back to previous artist in stack
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if artistStack.count > 1 {
                            artistStack.removeLast()
                        } else {
                            artistStack.removeAll()
                        }
                        artistDetailOffset = 0
                    }
                }
            )
            .id(entry.id)
            .background(isDarkMode ? Color.black : Color.white)
            .offset(x: artistDetailOffset)
            // Edge-only swipe-to-dismiss: only fires when drag starts within 30pt of
            // the left edge, matching iOS native back-swipe zone. This prevents
            // conflicts with horizontal ScrollViews inside ArtistDetailView.
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        let startX = value.startLocation.x
                        let isEdgeSwipe = startX < 30
                        let isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                        if isEdgeSwipe && isHorizontalDrag && value.translation.width > 0 {
                            artistDetailOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        let startX = value.startLocation.x
                        let isEdgeSwipe = startX < 30
                        let isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                        if isEdgeSwipe && isHorizontalDrag &&
                           (value.translation.width > 100 || value.velocity.width > 300) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                if artistStack.count > 1 {
                                    artistStack.removeLast()
                                } else {
                                    artistStack.removeAll()
                                }
                                artistDetailOffset = 0
                            }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                artistDetailOffset = 0
                            }
                        }
                    }
            )
        }
    }

    private func autoLogin() {
        var savedUrl = UserDefaults.standard.string(forKey: "velora_server_url") ?? ""
        var savedOnlineUrl = UserDefaults.standard.string(forKey: "velora_online_server_url") ?? ""
        var savedUser = UserDefaults.standard.string(forKey: "velora_username") ?? ""
        var connMode = UserDefaults.standard.integer(forKey: "velora_connection_mode")

        // Keychain Fallback for app reinstalls (UserDefaults wiped, but Keychain survives)
        if savedUrl.isEmpty || savedUser.isEmpty {
            if let data = KeychainHelper.shared.read(service: "velora-credentials", account: "default"),
               let bundle = try? JSONDecoder().decode(VeloraCredentialsBundle.self, from: data) {

                savedUrl = bundle.serverUrl
                savedOnlineUrl = bundle.onlineServerUrl
                savedUser = bundle.username
                connMode = bundle.connectionMode

                // Restore to UserDefaults seamlessly
                UserDefaults.standard.set(bundle.serverUrl, forKey: "velora_server_url")
                UserDefaults.standard.set(bundle.onlineServerUrl, forKey: "velora_online_server_url")
                UserDefaults.standard.set(bundle.username, forKey: "velora_username")
                UserDefaults.standard.set(bundle.connectionMode, forKey: "velora_connection_mode")
            }
        }

        let isOnline = (connMode == 1)

        if !savedUser.isEmpty, !savedUrl.isEmpty {
            let activeUrl = isOnline && !savedOnlineUrl.isEmpty ? savedOnlineUrl : savedUrl
            if let savedPassData = KeychainHelper.shared.read(service: "velora-password", account: savedUser),
               let savedPass = String(data: savedPassData, encoding: .utf8) {
                client.configure(url: activeUrl, user: savedUser, pass: savedPass)
                client.loadOfflineMetadata()
                client.fetchEverything()
                showSettings = false
            } else {
                showSettings = true
            }
        } else {
            showSettings = true
        }
    }
}
