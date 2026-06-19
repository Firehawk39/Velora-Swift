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

    init() {
        let clientInstance = NavidromeClient()
        let playbackInstance = PlaybackManager(client: clientInstance)
        _client = StateObject(wrappedValue: clientInstance)
        _playback = StateObject(wrappedValue: playbackInstance)
    }

    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        ZStack(alignment: .top) {
            // ── Layer 1: Global Canvas Background ──────────────────────────
            Color(hex: (isDarkMode || activeTab == "now-playing") ? "#000000" : "#f0f0f0")
                .ignoresSafeArea()

            // ── Layer 2: Seamless Main Layout ───────────────────────────────
            ZStack(alignment: .top) {
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 0)

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
                .zIndex(300) 
                
                artistDetailOverlay
                    .zIndex(400)
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
                            },
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
            withAnimation { 
                isIdle = false 
                selectedArtistId = nil
                selectedArtistName = nil
            }
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
            switch activeTab {
            case "home":
                HomeView(onArtistClick: { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedArtistId = id
                        selectedArtistName = name
                    }
                }, onSeeAll: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        activeTab = "library"
                    }
                })
            case "library":
                LibraryView(onArtistClick: { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedArtistId = id
                        selectedArtistName = name
                    }
                })
            case "settings":
                AppSettingsView()
            case "search":
                SearchView(onArtistClick: { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedArtistId = id
                        selectedArtistName = name
                    }
                })
            case "now-playing":
                NowPlayingView(isQueueOpen: $isQueueOpen, isIdle: $isIdle) { id, name in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedArtistId = id
                        selectedArtistName = name
                    }
                }
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
        if let id = selectedArtistId, let name = selectedArtistName {
            ArtistDetailView(
                artistId: id,
                artistName: name,
                onArtistClick: { nextId, nextName in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedArtistId = nextId
                        selectedArtistName = nextName
                        artistDetailOffset = 0
                    }
                },
                onPlay: { track, ctx in playback.playTrack(track, context: ctx) },
                onBack: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedArtistId = nil
                        selectedArtistName = nil
                        artistDetailOffset = 0
                    }
                }
            )
            .id(id)
            .background(isDarkMode ? Color.black : Color.white)
            .offset(x: artistDetailOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.width > 0 {
                            artistDetailOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        if value.translation.width > 100 || value.velocity.width > 300 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selectedArtistId = nil
                                selectedArtistName = nil
                                artistDetailOffset = 0
                            }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                artistDetailOffset = 0
                            }
                        }
                    }
            )
            .transition(.move(edge: .trailing))
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
        
        // If there are no saved credentials, do not log in automatically.
        // Instead, show the settings wizard (login screen) on fresh install.
        guard !savedUrl.isEmpty, !savedUser.isEmpty else {
            showSettings = true
            return
        }
        
        // Retrieve the password securely from Keychain
        if let passData = KeychainHelper.shared.read(service: "velora-password", account: savedUser),
           let savedPass = String(data: passData, encoding: .utf8) {
            
            let finalUrl = isOnline ? savedOnlineUrl : savedUrl
            client.configure(url: finalUrl, user: savedUser, pass: savedPass)
            client.loadOfflineMetadata()
            client.fetchEverything() // Self-gates on NetworkMonitor; no-ops when offline
            showSettings = false
        } else {
            // Fallback to showing settings if Keychain read fails
            showSettings = true
        }
    }
}
