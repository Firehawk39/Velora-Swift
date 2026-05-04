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

    var isLargeCanvas: Bool { UIScreen.main.bounds.width >= 1150.0 } // Increased threshold to avoid overflow on 10.25" screens
    var isSmallDevice: Bool { UIScreen.main.bounds.width <= 375 } // iPhone SE, Mini, etc.

    var headerHeight: CGFloat { UIScreen.main.bounds.width < 768 ? 72 : 80 }

    @AppStorage("velora_username") var username: String = ""

    init() {
        let clientInstance = NavidromeClient()
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
                    subtitle: selectedArtistName,
                    onAction: {
                        withAnimation {
                            selectedArtistId = nil
                            selectedArtistName = nil
                        }
                    }
                )
                .padding(.top, ScreenTier.isPhone ? 14 : 22)
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
        .environmentObject(AIManager.shared)
        .preferredColorScheme((isDarkMode || activeTab == "now-playing") ? .dark : .light)
        .statusBarHidden(true)
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
                NowPlayingView(isQueueOpen: $isQueueOpen, isIdle: $isIdle)
            default:
                HomeView()
            }

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
        let savedUrl = UserDefaults.standard.string(forKey: "velora_server_url") ?? ""
        let savedUser = UserDefaults.standard.string(forKey: "velora_username") ?? ""
        let isOnline = UserDefaults.standard.bool(forKey: "velora_is_online_mode")
        
        let localUrl = savedUrl.isEmpty ? "http://192.168.1.13:4533" : savedUrl
        let finalUrl = isOnline ? "https://sopranosnavi.share.zrok.io" : localUrl
        
        let finalUser = savedUser.isEmpty ? "Harsh" : savedUser
        let finalPass = "u4vTyG7BcBxR-9-"
        
        client.configure(url: finalUrl, user: finalUser, pass: finalPass)
        client.fetchEverything()
        showSettings = false
    }
}
