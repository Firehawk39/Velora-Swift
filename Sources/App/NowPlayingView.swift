import SwiftUI
import Foundation

@MainActor
struct NowPlayingView: View {
    @EnvironmentObject var playback: PlaybackManager
    @StateObject var fanart = FanartManager.shared
    @StateObject private var mb = MusicBrainzManager.shared
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass)   var vSizeClass
    @Binding var isQueueOpen: Bool
    @Binding var isIdle:      Bool

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
                .animation(.easeInOut(duration: 0.6), value: isIdle)
                .animation(.easeInOut(duration: 0.6), value: fanart.currentBackdrop)
                .allowsHitTesting(false)
                .drawingGroup()



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
                            .animation(.easeInOut(duration: 0.7), value: isIdle)
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
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 2.5)) {
                    self.isIdle = true
                }
            }
        }
    }

    private func resetIdleTimer() {
        if isIdle {
            withAnimation(.spring(response: animationResponse, dampingFraction: 0.8)) {
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
                    }
                    .padding(.horizontal, 24)
                }
                
                // Progress Bar
                progressBar
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, isSE ? 12 : (isIdle ? 60 : 32))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: playback.isLyricsMode)
        .animation(.spring(response: 1.0, dampingFraction: 0.85), value: isIdle)
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
                            
                            Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                .font(.system(size: tabletArtistSize, weight: .bold))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, isLargeCanvas ? 60 : 32)
                    .transition(.opacity)
                }
                
                // Progress Bar (Always visible below content)
                progressBar
                    .padding(.horizontal, isLargeCanvas ? 60 : 32)
                
                // Controls Section
                if !isIdle && !playback.isLyricsMode {
                    HStack(alignment: .center) {
                        // 1. Left Section (Empty now)
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
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }
            }
            .padding(.bottom, isIdle ? (isShortCanvas ? 40 : 60) : 32)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: playback.isLyricsMode)
        .animation(.spring(response: 1.0, dampingFraction: 0.85), value: isIdle)
    }

    @ViewBuilder
    private var playbackControls: some View {
        // Shuffle
        Button { playback.isShuffle.toggle(); resetIdleTimer() } label: {
            Image(systemName: "shuffle").font(.system(size: 16)).foregroundColor(playback.isShuffle ? Color(hex: "#60a5fa") : .white.opacity(0.5))
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
            AsyncImage(url: playback.currentTrack?.coverArtUrl) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color.white.opacity(0.1)
                }
            }
            .id(playback.currentTrack?.id) // Force refresh on track change
            
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
            } else {
                // When not idle, regular tap might do something else or nothing
                // For now, let's just make it do nothing to keep the "secret" feel
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
                        HStack(spacing: 24) {
                            artistImage
                                .frame(width: isSE ? 80 : 120, height: isSE ? 80 : 120)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                    .font(.system(size: isSE ? 20 : 28, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        
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
                        HStack(spacing: 24) {
                            artistImage
                                .frame(width: isSE ? 80 : 120, height: isSE ? 80 : 120)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                    .font(.system(size: isSE ? 20 : 28, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        
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
            if let artistId = playback.currentTrack?.artistId,
               let url = URL(string: playback.client.getCoverArtUrl(id: artistId)) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.white.opacity(0.1))
                }
            } else {
                Circle().fill(Color.white.opacity(0.1))
            }
        }
        .clipShape(Circle())
    }


    private var progressBar: some View {
        VStack(spacing: 8) {
            GeometryReader { barGeo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                    Capsule().fill(Color.white)
                        .frame(width: barGeo.size.width * CGFloat(progressFraction), height: 4)
                        .animation(isDragging ? nil : .linear(duration: 0.5), value: progressFraction)
                }
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
        .accessibilityLabel("Download")
    }

    private var inlineLyricsView: some View {
        let syncedLyrics = playback.currentSyncedLyrics ?? []
        let activeIndex = syncedLyrics.isEmpty ? 0 : (syncedLyrics.lastIndex(where: { playback.progress >= $0.time }) ?? 0)
        
        return ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if !syncedLyrics.isEmpty {
                        ForEach(Array(syncedLyrics.enumerated()), id: \.offset) { index, line in
                            renderLyricLine(line: line, index: index, activeIndex: activeIndex, syncedLyrics: syncedLyrics)
                                .id(index)
                        }
                    } else if let lyrics = playback.currentLyrics {
                        let lines = lyrics.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: isLargeCanvas ? 44 : 32, weight: .black))
                                .foregroundColor(.white)
                                .opacity(1.0)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Looking for lyrics...")
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

    private func renderLyricLine(line: LyricLine, index: Int, activeIndex: Int, syncedLyrics: [LyricLine]) -> Text {
        let baseFont = Font.system(size: isLargeCanvas ? 44 : 32, weight: .black)
        
        if index != activeIndex {
            return Text(line.text)
                .font(baseFont)
                .foregroundColor(.white.opacity(0.4))
        } else {
            if !line.words.isEmpty {
                // True Spotify-like exact word sync
                var concatenatedText = Text("")
                for (i, word) in line.words.enumerated() {
                    let isSpoken = playback.progress >= (word.time - 0.1)
                    let opacity = isSpoken ? 1.0 : 0.4
                    
                    let textSegment = Text(word.text + (i == line.words.count - 1 ? "" : " ")).foregroundColor(.white.opacity(opacity))
                    concatenatedText = concatenatedText + textSegment
                }
                return concatenatedText.font(baseFont)
            } else {
                // Fallback simulated word sync
                let duration = (index + 1 < syncedLyrics.count) ? (syncedLyrics[index + 1].time - line.time) : 5.0
                let elapsed = max(0, playback.progress - line.time)
                
                let words = line.text.split(separator: " ").map(String.init)
                let wordDuration = duration / Double(max(1, words.count))
                
                var concatenatedText = Text("")
                for (i, word) in words.enumerated() {
                    let wordStart = Double(i) * wordDuration
                    let isSpoken = elapsed >= (wordStart - 0.1)
                    let opacity = isSpoken ? 1.0 : 0.4
                    
                    let textSegment = Text(word + (i == words.count - 1 ? "" : " ")).foregroundColor(.white.opacity(opacity))
                    concatenatedText = concatenatedText + textSegment
                }
                
                return concatenatedText.font(baseFont)
            }
        }
    }
    private func refreshMetadata() {
        guard let track = playback.currentTrack else { return }
        
        let artistName = track.artist ?? "Unknown Artist"
        let albumName = track.album ?? "Unknown Album"
        
        self.artistBiography = nil
        
        // 1. Immediately trigger backdrop fetch (FanartManager will check cache instantly)
        // This prevents the "waiting for Navidrome response" flicker
        fanart.fetchBackdrop(for: artistName, mbid: nil)
        
        // 2. Fetch extended info from Navidrome (MBID + Bio)
        if let artistId = track.artistId {
            isFetchingArtistInfo = true
            playback.client.fetchArtistInfo(artistId: artistId) { bio, mbid in
                DispatchQueue.main.async {
                    self.artistBiography = bio
                    self.isFetchingArtistInfo = false
                    
                    // If we got a fresh MBID, update fanart too (though usually it's already there)
                    if let mbid = mbid {
                        fanart.fetchBackdrop(for: artistName, mbid: mbid)
                    }
                }
            }
        }
        
        // 3. Album info
        mb.fetchAboutAlbum(albumName: albumName, artistName: artistName, mbid: nil)
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
