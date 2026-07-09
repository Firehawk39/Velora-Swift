import SwiftUI
import Foundation

@MainActor
struct NowPlayingView: View {
    @EnvironmentObject var playback: PlaybackManager
    @ObservedObject var fanart = FanartManager.shared
    @ObservedObject private var mb = MusicBrainzManager.shared
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass)   var vSizeClass
    @Binding var isQueueOpen: Bool
    @Binding var isIdle:      Bool
    var onArtistClick: ((String, String) -> Void)? = nil

    @State private var isDragging   = false
    @State private var artistBiography: String? = nil
    @State private var isFetchingArtistInfo: Bool = false
    @State private var dragProgress: Double = 0
    @State private var idleTimer: Timer? = nil
    @State private var showPlayPauseHint: Bool = false
    @State private var hintIcon: String = "play.fill"
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true

    // Header height to avoid overlap
    var headerHeight: CGFloat {
        if isSmallDevice && !isLandscape { return 64 }
        return UIScreen.main.bounds.width < 768 ? 72 : 96
    }

    var isCompact:     Bool { hSizeClass == .compact }
    var isLandscape: Bool {
        UIScreen.main.bounds.width > UIScreen.main.bounds.height
    }
    var isLargeCanvas: Bool { UIScreen.main.bounds.width >= 1000 }
    var isShortCanvas: Bool { UIScreen.main.bounds.height < 800 }
    var isSmallDevice: Bool { UIScreen.main.bounds.width <= 375 }
    var isSE:          Bool { ScreenTier.isSE }

    // Layout Constants
    private var tabletArtworkSize: CGFloat {
        let base: CGFloat = isLargeCanvas ? 220 : (!isCompact ? 160 : (isSE ? 130.0 : 120.0))
        return isLandscape ? base * 1.25 : base // 25% increase in landscape
    }
    private var tabletTitleSize: CGFloat {
        let base: CGFloat = isLargeCanvas ? 32 : (!isCompact ? 26 : (isSE ? 18.0 : 20.0))
        return isLandscape ? base * 1.2 : base // 20% increase in landscape
    }
    private var tabletArtistSize: CGFloat {
        let base: CGFloat = isLargeCanvas ? 18 : (!isCompact ? 16 : 14.0)
        return isLandscape ? base * 1.2 : base // 20% increase in landscape
    }

    var displayProgress: Double {
        isDragging ? dragProgress : playback.progress
    }
    var progressFraction: Double {
        guard playback.duration > 0 else { return 0 }
        return displayProgress / playback.duration
    }

    // 120Hz Optimized Response: Faster on ProMotion iPads, standard on iPhones
    var animationResponse: Double {
        (ScreenTier.current == .large || ScreenTier.current == .huge) ? 0.35 : 0.55
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Dynamic Ambient Background
                Group {
                    if isCompact && !isLandscape {
                        // PORTRAIT IPHONE: Use Dynamic Gradient (No Blur)
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(playback.currentPrimaryColor).opacity(0.8),
                                Color(playback.currentPrimaryColor).opacity(0.4),
                                .black
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        // LANDSCAPE OR IPAD: Use High-Fidelity Backdrop
                        if let backdrop = fanart.currentBackdrop {
                            Image(uiImage: backdrop)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                                .clipped()
                                .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                                .opacity(isIdle ? 0.45 : 0.35)
                        } else {
                            // No fanart — Apple Music-style ambient gradient from album color
                            // Black while artwork loads, transitions to real color once extracted
                            AlbumAmbientGradientView(colors: playback.currentPalette)
                        }
                    }
                }
                .overlay(
                    // Combined Vignette: Dark edges + Vertical fade
                    ZStack {
                        // Edge darkness (Radial)
                        RadialGradient(
                            gradient: Gradient(colors: [.clear, .black.opacity(isIdle ? 0.5 : 0.85)]),
                            center: .center,
                            startRadius: 50,
                            endRadius: proxy.size.width * 1.2
                        )

                        // Top and Bottom protection (Linear)
                        LinearGradient(
                            gradient: Gradient(colors: [
                                .black.opacity(isIdle ? 0.3 : 0.6),
                                .clear,
                                .black.opacity(isIdle ? 0.5 : 0.9)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                .ignoresSafeArea()
                // Stagger layer 2 of 3: background lightens AFTER controls exit (0.15s delay),
                // and re-darkens immediately when waking (no delay — sets the stage first).
                .animation(
                    isIdle
                        ? .spring(response: 1.4, dampingFraction: 0.95, blendDuration: 0.5).delay(0.15)
                        : .spring(response: 0.6, dampingFraction: 0.82, blendDuration: 0.3),
                    value: isIdle
                )
                .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if isCompact && !isLandscape {
                                portraitLayout(proxy: proxy)
                            } else {
                                tabletLayout(proxy: proxy)
                            }
                        }
                        .frame(minHeight: proxy.size.height - (isIdle ? 0 : (headerHeight + 20)))

                        metadataCards
                            .padding(.horizontal, isCompact && !isLandscape ? 24 : (isLargeCanvas ? 120 : 40))
                            .padding(.top, 40)
                            .padding(.bottom, 20)
                            .opacity(isIdle ? 0.0 : 1.0)
                            .offset(y: isIdle ? 20 : 0)
                            .allowsHitTesting(!isIdle)
                            // Stagger layer 3 of 3: metadata trails last (0.25s delay going idle),
                            // but appears immediately on wake so content is ready when controls arrive.
                            .animation(
                                isIdle
                                    ? .spring(response: 1.4, dampingFraction: 0.95, blendDuration: 0.5).delay(0.25)
                                    : .spring(response: 0.6, dampingFraction: 0.82, blendDuration: 0.3),
                                value: isIdle
                            )
                    }
                    .padding(.top, isIdle ? 0 : headerHeight + 20)
                    .padding(.bottom, 20)
                    .contentShape(Rectangle()) // Ensures the entire area is scroll-reactive
                    .onTapGesture {
                        if playback.isLyricsMode {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                playback.isLyricsMode = false
                            }
                            resetIdleTimer()
                        } else if isIdle {
                            resetIdleTimer()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .highPriorityGesture(
                DragGesture(minimumDistance: 40)
                    .onChanged { _ in
                        // Nothing needed on change
                    }
                    .onEnded { value in
                        if isIdle {
                            let horizontal = value.translation.width
                            let vertical = value.translation.height

                            if abs(horizontal) > abs(vertical) && abs(horizontal) > 50 {
                                if horizontal < 0 {
                                    playback.skipForward()
                                } else {
                                    playback.skipBackward()
                                }
                            }
                            resetIdleTimer()
                        }
                    }
            )
        }
        .onAppear {
            isIdle = false // Ensure we don't start in idle state
            startIdleTimer()
            refreshMetadata()
        }
        .onDisappear {
            stopIdleTimer()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: isIdle) { idle in
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        .onChange(of: isQueueOpen) { isOpen in
            if isOpen { stopIdleTimer() } else { resetIdleTimer() }
        }
        .onChange(of: playback.isLyricsMode) { isMode in
            if isMode { stopIdleTimer() } else { resetIdleTimer() }
        }
        .onChange(of: playback.currentTrack?.id) { _ in
            resetIdleTimer()
            refreshMetadata()
        }
        .preferredColorScheme(.dark)
    }

    private func startIdleTimer() {
        stopIdleTimer()
        guard !isQueueOpen && !playback.isLyricsMode else { return }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in
            Task { @MainActor in
                // Golden standard: ONE animation context drives the entire view tree.
                // blendDuration: if the user taps during this dissolve, the reverse
                // animation blends in smoothly instead of snapping.
                // High dampingFraction → no overshoot on a slow cinematic transition.
                withAnimation(.spring(response: 1.4, dampingFraction: 0.95, blendDuration: 0.5)) {
                    self.isIdle = true
                }
            }
        }
    }

    private func resetIdleTimer() {
        if isIdle {
            // Snappier spring for waking up — feels alive and responsive.
            // blendDuration handles the case where idle fires again mid-wakeup.
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82, blendDuration: 0.3)) {
                isIdle = false
            }
        }
        startIdleTimer()
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // ── PORTRAIT ──────────────────────────────────────────────────────
    private func portraitLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if !playback.isLyricsMode {
                Spacer()
            }

            VStack(spacing: isSE ? 8 : (isSmallDevice ? 16 : 32)) {
                if playback.isLyricsMode {
                    inlineLyricsView
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height - headerHeight - (isSE ? 100 : 120))
                        .padding(.horizontal, 24)
                } else {
                    // Album Art
                    artworkSection(size: ScreenTier.isPhone ? min(proxy.size.width * (isSE ? 0.42 : (isSmallDevice ? 0.55 : 0.7)), 280) : tabletArtworkSize)
                        .padding(.bottom, isSE ? 0 : (isSmallDevice ? 6 : 12))

                    // Centered Metadata
                    VStack(alignment: .center, spacing: isSE ? 2 : 6) {
                        Text(playback.currentTrack?.title ?? "Not Playing")
                            .font(.system(size: isSE ? 17 : (isSmallDevice ? 20 : 26), weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Text(playback.currentTrack?.artist ?? "Unknown Artist")
                            .font(.system(size: isSE ? 12 : (isSmallDevice ? 14 : 16), weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            
                        if playback.currentTrack?.suffix?.lowercased() == "flac" {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform")
                                Text("Lossless")
                            }
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // Progress Bar — wrapped in ZStack so the clearlogo sits above it on the right
                ZStack(alignment: .bottomTrailing) {
                    progressBar

                    // Artist clearlogo: right-aligned above seekbar
                    if let logo = fanart.currentClearLogo {
                        Image(uiImage: logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: isSmallDevice ? 110 : 140, maxHeight: isSE ? 36 : 44)
                            .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                            .offset(y: isSE ? -28 : -34)
                            .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                    }
                }
                .padding(.horizontal, 24)

                if !isIdle && !playback.isLyricsMode {
                    // Controls Section for Portrait
                    VStack(spacing: isSE ? 8 : (isSmallDevice ? 16 : 24)) {
                        HStack(spacing: isSE ? 20 : (isSmallDevice ? 28 : 36)) {
                            playbackControls
                        }
                        .padding(.horizontal, isSE ? 16 : (isSmallDevice ? 24 : 32))
                        .padding(.vertical, isSE ? 8 : (isSmallDevice ? 12 : 16))
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))

                        HStack(spacing: 12) {
                            lyricsButton
                            queueButton
                            downloadButton
                        }
                        .scaleEffect(isSE ? 0.75 : (isSmallDevice ? 0.85 : 0.9))
                    }
                    // Stagger layer 1 of 3: controls exit FIRST (no delay) and are the LAST
                    // to reappear on wake (0.2s delay) — mirrors Apple Music's cinematic mode.
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.spring(response: 0.6, dampingFraction: 0.82, blendDuration: 0.3).delay(0.2)),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.spring(response: 1.4, dampingFraction: 0.95, blendDuration: 0.5))
                    ))
                }
            }
            .padding(.bottom, isSE ? 12 : (isIdle ? 60 : 32))
        }
        // isLyricsMode still gets its own local animation — it's a separate interaction,
        // not part of the idle transition context.
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: playback.isLyricsMode)
    }

    // ── TABLET / LANDSCAPE ────────────────────────────────────────────
    private func tabletLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if !playback.isLyricsMode {
                Spacer() // Push everything to bottom
            }

            VStack(spacing: isShortCanvas ? 20 : 32) {
                if playback.isLyricsMode {
                    // Inline Lyrics State
                    HStack {
                        if mb.isLoading {
                            CircularProgressView(progress: mb.metadataProgress, size: 30, strokeWidth: 3, accentColor: .red)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            inlineLyricsView
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: proxy.size.height - headerHeight - (isShortCanvas ? 100 : 130))
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, isLargeCanvas ? 60 : 32)
                    .transition(.opacity)
                } else {
                    // Artwork & Metadata side-by-side
                    HStack(alignment: .bottom, spacing: isLargeCanvas ? 40 : 24) {
                        artworkSection(size: tabletArtworkSize)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(playback.currentTrack?.title ?? "Not Playing")
                                .font(.system(size: tabletTitleSize, weight: .black))
                                .foregroundColor(.white)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                    .font(.system(size: tabletArtistSize, weight: .bold))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(1)
                                    
                                if playback.currentTrack?.suffix?.lowercased() == "flac" {
                                    HStack(spacing: 4) {
                                        Image(systemName: "waveform")
                                        Text("Lossless")
                                    }
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(4)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, isLargeCanvas ? 60 : 32)
                    .transition(.opacity)
                }

                // Progress Bar (Always visible below content)
                ZStack(alignment: .bottomTrailing) {
                    progressBar

                    // Artist clearlogo: right-aligned above seekbar
                    if let logo = fanart.currentClearLogo {
                        Image(uiImage: logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: isLargeCanvas ? 160 : 130, maxHeight: isShortCanvas ? 36 : 48)
                            .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                            .offset(y: isShortCanvas ? -28 : -36)
                            .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                    }
                }
                .padding(.horizontal, isLargeCanvas ? 60 : 32)

                // Controls Section
                if !isIdle && !playback.isLyricsMode {
                    HStack(alignment: .center) {
                        // 1. Left Section
                        HStack {
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)

                        // 2. Center Section: Playback Controls Pill
                        HStack(spacing: isLargeCanvas ? 48 : 36) {
                            playbackControls
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1.5))

                        // 3. Right Section: Lyrics, Queue & Download
                        HStack {
                            Spacer()
                            HStack(spacing: 12) {
                                lyricsButton
                                queueButton
                                downloadButton
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, isLargeCanvas ? 60 : 32)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.spring(response: 0.6, dampingFraction: 0.82, blendDuration: 0.3).delay(0.2)),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.spring(response: 1.4, dampingFraction: 0.95, blendDuration: 0.5))
                    ))
                }
            }
            .padding(.bottom, isIdle ? (isShortCanvas ? 40 : 60) : 32)
        }
        // isLyricsMode still gets its own local animation — separate interaction context.
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: playback.isLyricsMode)
    }

    @ViewBuilder
    private var playbackControls: some View {
        // Shuffle
        Button { playback.toggleShuffle(); resetIdleTimer() } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 16))
                .foregroundColor(playback.isShuffle ? Color(hex: "#60a5fa") : .white.opacity(0.5))
        }
        .accessibilityLabel("Shuffle")
        .hoverEffect()

        // Previous
        Button { playback.skipBackward(); resetIdleTimer() } label: {
            Image(systemName: "backward.fill").font(.system(size: 28)).foregroundColor(.white)
        }
        .accessibilityLabel("Previous Track")
        .hoverEffect()

        // Play/Pause
        Button { playback.togglePlayPause(); resetIdleTimer() } label: {
            ZStack {
                Circle().fill(Color.white).frame(width: 58, height: 58)
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24)).foregroundColor(.black)
            }
        }
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
        .hoverEffect()

        // Next
        Button { playback.skipForward(); resetIdleTimer() } label: {
            Image(systemName: "forward.fill").font(.system(size: 28)).foregroundColor(.white)
        }
        .accessibilityLabel("Next Track")
        .hoverEffect()

        // Repeat
        Button {
            playback.toggleRepeatMode()
            resetIdleTimer()
        } label: {
            Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                .font(.system(size: 16))
                .foregroundColor(playback.repeatMode == .off ? .white.opacity(0.5) : .accentColor)
        }
        .accessibilityLabel("Repeat Mode")
        .hoverEffect()
    }


    private func artworkSection(size: CGFloat) -> some View {
        ZStack {
            SelfHealingAsyncImage(url: playback.currentTrack?.coverArtUrl) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .id(playback.playbackSessionId) // Force refresh on track change or manual replay

            // Hidden Secret Feedback Overlay
            if showPlayPauseHint {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.4))
                        .frame(width: 70, height: 70)

                    Image(systemName: hintIcon)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
        // Apple Music-style: artwork subtly expands 3% during idle, making it the
        // visual anchor as everything else retreats. Driven by withAnimation context.
        .scaleEffect(isIdle ? 1.03 : 1.0)
        .onTapGesture {
            if isIdle {
                // Secret Toggle: No resetIdleTimer() called here
                hintIcon = playback.isPlaying ? "pause.fill" : "play.fill"
                playback.togglePlayPause()

                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    showPlayPauseHint = true
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showPlayPauseHint = false
                    }
                }
            }
        }
    }

    private var metadataCards: some View {
        VStack(alignment: .leading, spacing: 40) {
            // About Artist
            VStack(alignment: .leading, spacing: isSE ? 16 : 24) {
                Text("About the Artist")
                    .font(.system(size: isSE ? 28 : 32, weight: .bold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 20) {
                    if let bio = artistBiography {
                        Button {
                            if let id = playback.currentTrack?.artistId, let name = playback.currentTrack?.artist {
                                onArtistClick?(id, name)
                            }
                        } label: {
                            HStack(spacing: 24) {
                                artistImage
                                    .frame(width: isSE ? 80 : 120, height: isSE ? 80 : 120)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                        .font(.system(size: isSE ? 20 : 28, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())

                        Text(bio)
                            .font(.system(size: isSE ? 14 : 16))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(10)
                    } else if isFetchingArtistInfo {
                        HStack {
                            Spacer()
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .red))
                                .scaleEffect(1.5)
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else {
                        Button {
                            if let id = playback.currentTrack?.artistId, let name = playback.currentTrack?.artist {
                                onArtistClick?(id, name)
                            }
                        } label: {
                            HStack(spacing: 24) {
                                artistImage
                                    .frame(width: isSE ? 80 : 120, height: isSE ? 80 : 120)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                        .font(.system(size: isSE ? 20 : 28, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())

                        Text("No further information found.")
                            .font(.system(size: isSE ? 14 : 16))
                            .foregroundColor(.white.opacity(0.4))
                            .italic()
                    }
                }
                .padding(isSE ? 20 : 32)
                .background(Color.white.opacity(0.05))
                .cornerRadius(isSE ? 20 : 32)
            }

            // Album Info
            VStack(alignment: .leading, spacing: isSE ? 16 : 24) {
                Text("From the Album")
                    .font(.system(size: isSE ? 28 : 32, weight: .bold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playback.currentTrack?.album ?? "Unknown Album")
                                .font(.system(size: isSE ? 22 : 26, weight: .bold))
                                .foregroundColor(.white)

                            if let info = mb.currentAlbumInfo {
                                Text([info.label, info.firstReleaseDate].compactMap { $0 }.joined(separator: " • "))
                                    .font(.system(size: isSE ? 14 : 16))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        Spacer()
                    }

                    if let annotation = mb.currentAlbumInfo?.annotation {
                        Text(annotation)
                            .font(.system(size: isSE ? 14 : 16))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(6)
                    }
                }
                .padding(isSE ? 20 : 32)
                .background(Color.white.opacity(0.05))
                .cornerRadius(isSE ? 20 : 32)
            }
        }
    }

    private var artistImage: some View {
        Group {
            if let artistId = playback.currentTrack?.artistId {
                // FIX #4: Look in artistPortraits (where SyncManager saves Fanart.tv portraits),
                // not coverArt (which stores album art). Wrong dir caused a cache miss every time.
                let localUrl = VeloraStorage.artistPortraits.appendingPathComponent("\(artistId).jpg")
                let imageUrl: URL? = FileManager.default.fileExists(atPath: localUrl.path)
                    ? localUrl
                    : URL(string: playback.client.getCoverArtUrl(id: artistId))
                SelfHealingAsyncImage(url: imageUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.white.opacity(0.1))
                }
                .id(playback.currentTrack?.artistId ?? "")
            } else {
                Circle().fill(Color.white.opacity(0.1))
            }
        }
        .clipShape(Circle())
    }

    private var progressBar: some View {
        IsolatedProgressBarView(isIdle: $isIdle, resetIdleTimer: resetIdleTimer)
    }
    private var lyricsButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                playback.isLyricsMode.toggle()
                if playback.isLyricsMode { isQueueOpen = false }
            }
            resetIdleTimer()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .background(playback.isLyricsMode ? Color.white : Color.black.opacity(0.5))
                .foregroundColor(playback.isLyricsMode ? .black : .white)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .accessibilityLabel("Lyrics Toggle")
    }

    private var queueButton: some View {
        Button {
            withAnimation(.spring(response: animationResponse, dampingFraction: 0.8)) {
                isQueueOpen.toggle()
                if isQueueOpen { playback.isLyricsMode = false }
            }
            resetIdleTimer()
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .background(isQueueOpen ? Color.white : Color.black.opacity(0.5))
                .foregroundColor(isQueueOpen ? .black : .white)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .accessibilityLabel("Queue Toggle")
    }

    private var downloadButton: some View {
        Button {
            resetIdleTimer()
            if let track = playback.currentTrack {
                playback.downloadTrack(track)
            }
        } label: {
            let trackId = playback.currentTrack?.id ?? ""
            let isDownloaded = playback.downloadedTrackIds.contains(trackId)
            let isPaused = playback.pausedDownloadIds.contains(trackId)

            ZStack {
                if let progress = playback.downloadProgress[trackId] {
                    ZStack {
                        CircularProgressView(progress: progress, size: 28, strokeWidth: 3, accentColor: .red)
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(.red)
                    }
                } else {
                    Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.to.line.compact")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(isDownloaded ? .green : .white)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.black.opacity(0.5))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .contextMenu {
            if let trackId = playback.currentTrack?.id, playback.downloadedTrackIds.contains(trackId) {
                Button(role: .destructive) {
                    playback.deleteDownload(trackId: trackId)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("Download")
    }

    private var inlineLyricsView: some View {
        let syncedLyrics = playback.currentSyncedLyrics ?? []
        let activeIndex = syncedLyrics.isEmpty ? 0 : (syncedLyrics.lastIndex(where: { playback.progress >= $0.time }) ?? 0)

        return ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !syncedLyrics.isEmpty {
                        ForEach(Array(syncedLyrics.enumerated()), id: \.offset) { index, line in
                            LyricLineView(
                                line: line,
                                index: index,
                                activeIndex: activeIndex,
                                syncedLyrics: syncedLyrics,
                                progress: playback.progress,
                                fontSize: isLargeCanvas ? 44 : 32
                            )
                            .id(index)
                        }
                    } else if let lyrics = playback.currentLyrics {
                        let lines = lyrics.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: isLargeCanvas ? 44 : 32, weight: .black))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        // Fetch finished, nothing found
                        Text("No Lyrics Available")
                            .font(.system(size: 32, weight: .black))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        playback.isLyricsMode = false
                    }
                    resetIdleTimer()
                }
                .onChange(of: activeIndex) { newIndex in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollProxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }
        }
    }

    private func formatTime(_ t: Double) -> String {
        guard !t.isNaN, !t.isInfinite else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }


    private func refreshMetadata() {
        guard let track = playback.currentTrack else { return }

        let artistName = track.artist ?? "Unknown Artist"
        let albumName = track.album ?? "Unknown Album"

        self.artistBiography = nil

        // 1. Immediately trigger backdrop fetch (FanartManager will check cache instantly)
        // This prevents the "waiting for Navidrome response" flicker
        fanart.fetchBackdrop(for: track.allArtists, artistId: track.artistId, mbid: nil, allowNetwork: false)

        // 1b. Trigger clearlogo fetch (cache-first, non-blocking)
        fanart.fetchClearLogo(for: track.artist ?? "Unknown Artist")

        // 2. Fetch extended info from Navidrome (MBID + Bio)
        if let artistId = track.artistId {
            isFetchingArtistInfo = true
            playback.client.fetchArtistInfo(artistId: artistId) { bio, mbid in
                Task { @MainActor in
                    // Check if we haven't skipped to another track in the meantime
                    guard self.playback.currentTrack?.id == track.id else { return }

                    self.artistBiography = bio
                    self.isFetchingArtistInfo = false

                    // If we got a fresh MBID, update fanart too (though usually it's already there)
                    if let mbid = mbid {
                        fanart.fetchBackdrop(for: track.allArtists, artistId: track.artistId, mbid: mbid, allowNetwork: true)
                        // Re-fetch logo with known MBID for higher accuracy
                        fanart.fetchClearLogo(for: track.artist ?? "Unknown Artist", mbid: mbid)
                    }
                }
            }
        }

        // 3. Album info
        mb.fetchAboutAlbum(albumName: albumName, artistName: artistName, mbid: nil)
    }
}

// MARK: - LyricLineView (LazyVStack-compatible, replaces old renderLyricLine Text func)
@MainActor
struct LyricLineView: View {
    let line: LyricLine
    let index: Int
    let activeIndex: Int
    let syncedLyrics: [LyricLine]
    let progress: Double
    let fontSize: CGFloat

    var body: some View {
        let baseFont = Font.system(size: fontSize, weight: .black)

        if index != activeIndex {
            Text(line.text)
                .font(baseFont)
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if !line.words.isEmpty {
            buildWordSyncedText(words: line.words, font: baseFont)
        } else {
            buildSimulatedWordText(font: baseFont)
        }
    }

    private func buildWordSyncedText(words: [LyricWord], font: Font) -> Text {
        var result = Text("")
        for (i, word) in words.enumerated() {
            let isSpoken = progress >= (word.time - 0.1)
            let suffix = (i == words.count - 1) ? "" : " "
            result = result + Text(word.text + suffix).foregroundColor(.white.opacity(isSpoken ? 1.0 : 0.4))
        }
        return result.font(font)
    }

    private func buildSimulatedWordText(font: Font) -> Text {
        let duration = (index + 1 < syncedLyrics.count)
            ? (syncedLyrics[index + 1].time - line.time)
            : 5.0
        let elapsed = max(0, progress - line.time)
        let words = line.text.split(separator: " ").map(String.init)
        let wordDuration = duration / Double(max(1, words.count))

        var result = Text("")
        for (i, word) in words.enumerated() {
            let isSpoken = elapsed >= (Double(i) * wordDuration - 0.1)
            let suffix = (i == words.count - 1) ? "" : " "
            result = result + Text(word + suffix).foregroundColor(.white.opacity(isSpoken ? 1.0 : 0.4))
        }
        return result.font(font)
    }
}

// MARK: - UIColor HSB Adjust Helper
extension UIColor {
    func adjust(hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard self.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(
            hue:        (h + hue).truncatingRemainder(dividingBy: 1.0) < 0
                            ? (h + hue).truncatingRemainder(dividingBy: 1.0) + 1.0
                            : (h + hue).truncatingRemainder(dividingBy: 1.0),
            saturation: max(0, min(1, s + saturation)),
            brightness: max(0, min(1, b + brightness)),
            alpha:      max(0, min(1, a + alpha))
        )
    }
}

// MARK: - Album Ambient Gradient (Apple Music style)
// Dispatches to MeshGradient on iOS 18+ or animated radial blobs on iOS 15–17.
// Both start from .black while artwork is loading and animate to real album colors.
struct AlbumAmbientGradientView: View {
    let colors: [UIColor]

    var body: some View {
        if #available(iOS 18.0, *) {
            AnimatedMeshGradientView(colors: colors)
        } else {
            DynamicFluidGradientView(colors: colors)
        }
    }
}

// MARK: - iOS 18+ MeshGradient (native Apple Music look)
@available(iOS 18.0, *)
struct AnimatedMeshGradientView: View {
    let colors: [UIColor]
    @State private var phase = false

    private func meshColors(phase: Bool) -> [Color] {
        let a = colors.indices.contains(0) ? Color(colors[0]) : Color.black
        let b = colors.indices.contains(1) ? Color(colors[1]) : Color.black
        let c = colors.indices.contains(2) ? Color(colors[2]) : Color.black
        let d = colors.indices.contains(3) ? Color(colors[3]) : Color.black
        let e = colors.indices.contains(4) ? Color(colors[4]) : Color.black
        let dark = Color.black

        return phase
            ? [a, b, dark, c, e, d, dark, d, dark]
            : [b, a, e, dark, d, c, dark, b, dark]
    }

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1)
            ],
            colors: meshColors(phase: phase)
        )
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}

// MARK: - iOS 15-17 Animated Radial Blobs (pre-MeshGradient Apple Music equivalent)
struct DynamicFluidGradientView: View {
    let colors: [UIColor]
    @State private var animate = false

    var body: some View {
        let base   = colors.indices.contains(0) ? Color(colors[0]) : Color.black
        let colorA = colors.indices.contains(1) ? Color(colors[1]) : Color.black
        let colorB = colors.indices.contains(2) ? Color(colors[2]) : Color.black
        let colorC = colors.indices.contains(3) ? Color(colors[3]) : Color.black
        let colorD = colors.indices.contains(4) ? Color(colors[4]) : Color.black

        GeometryReader { geo in
            ZStack {
                base.opacity(0.6).ignoresSafeArea()

                RadialGradient(
                    colors: [colorA.opacity(0.85), .clear],
                    center: animate ? UnitPoint(x: 0.1, y: 0.4) : UnitPoint(x: 0.3, y: 0.2),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.85
                )
                RadialGradient(
                    colors: [colorB.opacity(0.80), .clear],
                    center: animate ? UnitPoint(x: 0.9, y: 0.15) : UnitPoint(x: 0.7, y: 0.35),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.80
                )
                RadialGradient(
                    colors: [colorC.opacity(0.75), .clear],
                    center: animate ? UnitPoint(x: 0.25, y: 0.75) : UnitPoint(x: 0.15, y: 0.90),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.75
                )
                RadialGradient(
                    colors: [colorD.opacity(0.85), .clear],
                    center: animate ? UnitPoint(x: 0.8, y: 0.85) : UnitPoint(x: 0.9, y: 0.65),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.70
                )
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
        }
    }
}

// MARK: - Extracted Performance Views
@MainActor
struct IsolatedProgressBarView: View {
    @EnvironmentObject var playback: PlaybackManager
    @Binding var isIdle: Bool
    var resetIdleTimer: () -> Void

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    var displayProgress: Double {
        isDragging ? dragProgress : playback.progress
    }

    var progressFraction: Double {
        guard playback.duration > 0 else { return 0 }
        return displayProgress / playback.duration
    }

    private func formatTime(_ t: Double) -> String {
        guard !t.isNaN, !t.isInfinite else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { barGeo in
                ZStack(alignment: .leading) {
                    // Visual Bar (4pt height, centered vertically)
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.2)

                        Color.white
                            .scaleEffect(x: CGFloat(progressFraction), y: 1.0, anchor: .leading)
                            .animation(isDragging ? nil : .linear(duration: 0.1), value: progressFraction)
                    }
                    .frame(height: 4)
                    .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            isDragging = true
                            dragProgress = max(0, min(1, v.location.x / barGeo.size.width)) * playback.duration
                            resetIdleTimer()
                        }
                        .onEnded { v in
                            isDragging = false
                            let p = Double(v.location.x / barGeo.size.width) * playback.duration
                            playback.seek(to: max(0, min(playback.duration, p)))
                            resetIdleTimer()
                        }
                )
            }
            .frame(height: 12)

            if !playback.isLyricsMode {
                HStack {
                    Text(formatTime(displayProgress))
                    Spacer()
                    Text(formatTime(playback.duration))
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .opacity(isIdle ? 0 : 1)
            }
        }
    }
}

