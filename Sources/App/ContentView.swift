import SwiftUI

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
    var isCompact: Bool { hSizeClass == .compact }

    var isLargeCanvas: Bool { 
        if UIDevice.current.userInterfaceIdiom == .pad { return true }
        return UIScreen.main.bounds.width >= 1024.0 
    }
    var isSmallDevice: Bool { 
        if UIDevice.current.userInterfaceIdiom == .pad { return false }
        return UIScreen.main.bounds.width <= 393 
    }

    var headerHeight: CGFloat { UIScreen.main.bounds.width < 768 ? 72 : 80 }

    @AppStorage("velora_username") var username: String = ""

    init() {
        let clientInstance = NavidromeClient()
        clientInstance.loadMetadataFromDisk()
        let playbackInstance = PlaybackManager(client: clientInstance)
        _client = StateObject(wrappedValue: clientInstance)
        _playback = StateObject(wrappedValue: playbackInstance)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ── Layer 1: Global Canvas Background ──────────────────────────
            Color(hex: (isDarkMode || activeTab == "now-playing") ? "#000000" : "#f0f0f0")
                .ignoresSafeArea()

            // ── Layer 2: Seamless Main Layout ───────────────────────────────
            ZStack(alignment: .top) {
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                AppHeader(
                    activeTab: $activeTab,
                    showProfileMenu: $showProfileMenu,
                    isDarkMode: isDarkMode,
                    toggleDark: { isDarkMode.toggle() },
                    onAction: {
                        withAnimation {
                            selectedArtistId = nil
                            selectedArtistName = nil
                        }
                    }
                )
                .padding(.top, 14)
                .opacity(((isIdle && activeTab == "now-playing") || (activeTab == "now-playing" && playback.isLyricsMode)) ? 0 : 1)
                .offset(y: ((isIdle && activeTab == "now-playing") || (activeTab == "now-playing" && playback.isLyricsMode)) ? -100 : 0)
                .allowsHitTesting(!((isIdle && activeTab == "now-playing") || (activeTab == "now-playing" && playback.isLyricsMode)))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isIdle)
                .zIndex(300) // Ensure header is ALWAYS on top, above ArtistDetailView (200)
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
                                onLogout: {
                                    showProfileMenu = false
                                    client.logout()
                                    showSettings = true
                                }
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
            // Screen diagnostics - helps debug iPad scaling
            let screen = UIScreen.main
            let bounds = screen.bounds
            let nativeBounds = screen.nativeBounds
            let scale = screen.scale
            let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            AppLogger.shared.log("Screen: \(idiom) bounds=\(Int(bounds.width))x\(Int(bounds.height)) native=\(Int(nativeBounds.width))x\(Int(nativeBounds.height)) scale=\(scale)x tier=\(ScreenTier.current)", level: .info)
            
            SyncManager.shared.configure(client: client, playback: playback)
            
            // Immediately load from disk if available for offline speed
            client.loadMetadataFromDisk()
            
            // Then attempt to connect to server
            autoLogin()
        }
        .onChange(of: activeTab) { tab in
            withAnimation { 
                isIdle = false 
                selectedArtistId = nil
                selectedArtistName = nil
            }
            UIApplication.shared.isIdleTimerDisabled = (tab == "now-playing")
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(showSettings: $showSettings)
                .environmentObject(client)
        }
    }

    @State private var selectedArtistId: String? = nil
    @State private var selectedArtistName: String? = nil

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            HomeView(onArtistClick: { id, name in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    selectedArtistId = id
                    selectedArtistName = name
                }
            })
            .opacity(activeTab == "home" ? 1 : 0)
            .allowsHitTesting(activeTab == "home")

            LibraryView(onArtistClick: { id, name in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    selectedArtistId = id
                    selectedArtistName = name
                }
            })
            .opacity(activeTab == "library" ? 1 : 0)
            .allowsHitTesting(activeTab == "library")

            AppSettingsView()
                .opacity(activeTab == "settings" ? 1 : 0)
                .allowsHitTesting(activeTab == "settings")

            SearchView(onArtistClick: { id, name in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    selectedArtistId = id
                    selectedArtistName = name
                }
            })
            .opacity(activeTab == "search" ? 1 : 0)
            .allowsHitTesting(activeTab == "search")

            NowPlayingView(isQueueOpen: $isQueueOpen, isIdle: $isIdle, isActive: activeTab == "now-playing")
                .opacity(activeTab == "now-playing" ? 1 : 0)
                .allowsHitTesting(activeTab == "now-playing")

            if let id = selectedArtistId, let name = selectedArtistName {
                ArtistDetailView(
                    artistId: id,
                    artistName: name,
                    onArtistClick: { nextId, nextName in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedArtistId = nextId
                            selectedArtistName = nextName
                        }
                    },
                    onPlay: { track, ctx in playback.playTrack(track, context: ctx) },
                    onBack: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedArtistId = nil
                            selectedArtistName = nil
                        }
                    }
                )
                .id(id)
                .background(isDarkMode ? Color.black : Color.white)
                .transition(.move(edge: .trailing))
                .zIndex(200)
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

    private func autoLogin() {
        AppLogger.shared.log("App: autoLogin started. baseUrl='\(client.baseUrl)'", level: .info)
        
        guard !client.baseUrl.isEmpty else {
            AppLogger.shared.log("App: No server configured. Showing setup.", level: .warning)
            return
        }
        
        // Ping first to verify connectivity, then sync
        AppLogger.shared.log("App: Pinging server at \(client.baseUrl)...", level: .info)
        client.ping { success, errorMsg in
            DispatchQueue.main.async {
                if success {
                    AppLogger.shared.log("App: Ping OK! Starting full sync.", level: .info)
                    self.client.fetchEverything()
                } else {
                    AppLogger.shared.log("App: Ping FAILED: \(errorMsg ?? "unknown"). Trying sync anyway...", level: .warning)
                    // Still try to fetch - maybe the ping endpoint is restricted but data works
                    self.client.fetchEverything()
                    
                    // Retry after 5 seconds in case of initial local network permission delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        if self.client.artists.isEmpty && self.client.allSongs.isEmpty {
                            AppLogger.shared.log("App: Retry sync after 5s delay (local network permission?)...", level: .info)
                            self.client.fetchEverything()
                        }
                    }
                }
            }
        }
    }
}
