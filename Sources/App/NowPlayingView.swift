import SwiftUI
import Foundation

struct NowPlayingView: View {
    @EnvironmentObject var playback: PlaybackManager
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass)   var vSizeClass
    @Binding var isQueueOpen: Bool
    @Binding var isIdle:      Bool

    @State private var isLyricsMode = false
    @State private var isDragging   = false
    @State private var dragProgress: Double = 0
    @State private var idleTimer: Timer? = nil
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true

    // Header height to avoid overlap
    var headerHeight: CGFloat { UIScreen.main.bounds.width < 768 ? 72 : 96 }

    var isCompact:     Bool { hSizeClass == .compact }
    var isLandscape:   Bool { vSizeClass == .compact }
    var isLargeCanvas: Bool { UIScreen.main.bounds.width >= 1000 }
    var isShortCanvas: Bool { UIScreen.main.bounds.height < 800 }
    var isSmallDevice: Bool { UIScreen.main.bounds.width <= 375 } 
    var isSE:          Bool { ScreenTier.isSE }
    
    // Layout Constants
    private var tabletArtworkSize: CGFloat { 
        if isLargeCanvas {
            if ScreenTier.isHuge { return isShortCanvas ? 220.0 : 280.0 }
            return isShortCanvas ? 180.0 : 220.0
        }
        if !isCompact { // 10.25" screens / Regular iPad
            return isShortCanvas ? 160.0 : 200.0
        }
        return isSE ? 100.0 : 140.0
    }
    private var tabletTitleSize:   CGFloat { 
        if isLargeCanvas { return isShortCanvas ? 24.0 : 26.0 }
        if !isCompact { return isShortCanvas ? 20.0 : 24.0 }
        return isSE ? 18.0 : 22.0
    }
    private var tabletArtistSize:  CGFloat { 
        if isLargeCanvas { return isShortCanvas ? 16.0 : 18.0 }
        if !isCompact { return isShortCanvas ? 14.0 : 16.0 }
        return isSE ? 14.0 : 16.0
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
                ZStack {
                    if let track = playback.currentTrack, let url = track.coverArtUrl {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .opacity(isIdle ? 0.45 : 0.35)
                                .overlay(
                                    // Combined Vignette: Dark edges + Vertical fade
                                    ZStack {
                                        RadialGradient(
                                            gradient: Gradient(colors: [.clear, .black.opacity(isIdle ? 0.4 : 0.8)]),
                                            center: .center,
                                            startRadius: 200,
                                            endRadius: proxy.size.width * 0.8
                                        )
                                        LinearGradient(
                                            gradient: Gradient(colors: [.black.opacity(isIdle ? 0.2 : 0.5), .clear, .black.opacity(isIdle ? 0.4 : 0.8)]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    }
                                )
                                .animation(.easeInOut(duration: 1.2), value: isIdle)
                        } placeholder: {
                            Color.black
                        }
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .drawingGroup() // Flattens the gradients into a single GPU texture for smoother performance



                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if isCompact && !isLandscape {
                                portraitLayout(proxy: proxy)
                            } else {
                                tabletLayout(proxy: proxy)
                            }
                        }
                        .frame(height: proxy.size.height - (isIdle ? 0 : (headerHeight + 20)))
                        
                        metadataCards
                            .padding(.horizontal, isCompact && !isLandscape ? 24 : (isLargeCanvas ? 120 : 40))
                            .padding(.top, 40)
                            .padding(.bottom, 100)
                            .opacity(isIdle ? 0.0 : 1.0)
                            .offset(y: isIdle ? 20 : 0)
                            .allowsHitTesting(!isIdle)
                            .animation(.easeInOut(duration: 0.7), value: isIdle)
                    }
                    .padding(.top, isIdle ? 0 : headerHeight + 20)
                    .padding(.bottom, 50) // Extra bottom clearance
                    .contentShape(Rectangle()) // Ensures the entire area is scroll-reactive
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .simultaneousGesture(
                DragGesture(minimumDistance: 30) // Increased threshold to avoid blocking ScrollView gestures
                    .onChanged { _ in
                        resetIdleTimer()
                    }
            )
            .overlay {
                // Tap-to-wake overlay: Only active when idle to catch any touch
                if isIdle {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            resetIdleTimer()
                        }
                }
            }
        }
        .onAppear { 
            isIdle = false // Ensure we don't start in idle state
            startIdleTimer() 
        }
        .onDisappear { stopIdleTimer() }
        .onChange(of: isQueueOpen) { isOpen in
            if isOpen { stopIdleTimer() } else { resetIdleTimer() }
        }
        .onChange(of: isLyricsMode) { isMode in
            if isMode { stopIdleTimer() } else { resetIdleTimer() }
        }
        .overlay {
            if isLyricsMode {
                lyricsView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(500)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func startIdleTimer() {
        stopIdleTimer()
        guard !isQueueOpen && !isLyricsMode else { return }
        
        idleTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 2.5)) {
                isIdle = true
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
            if !isSE { Spacer() }
            
            // Album Art
            artworkSection(size: ScreenTier.isPhone ? min(proxy.size.width * (isSE ? 0.65 : 0.72), 280) : tabletArtworkSize)
                .scaleEffect(isIdle ? 1.08 : 1.0)
                .animation(.spring(response: animationResponse, dampingFraction: 0.8), value: isIdle)
                .padding(.top, isSE ? 20 : 0)
                .padding(.bottom, isIdle ? (isSE ? 16 : 32) : (isSE ? 16 : 24))
                .offset(y: isIdle ? -10 : 0)

            // Centered Metadata
            VStack(alignment: .center, spacing: isSE ? 2 : 8) {
                Text(playback.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: ScreenTier.isPhone ? (isSE ? 22 : 28) : (ScreenTier.isHuge ? 52 : 38), weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                Text(playback.currentTrack?.artist ?? "Select a track")
                    .font(.system(size: ScreenTier.isPhone ? (isSE ? 16 : 20) : (ScreenTier.isHuge ? 32 : 25), weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isSE ? 20 : 32)
            .padding(.bottom, isIdle ? (isSE ? 40 : 60) : (isSE ? 24 : 40))

            // Progress Bar
            progressBar
                .padding(.horizontal, isSE ? 20 : 32)
                .padding(.bottom, isIdle ? (isSE ? 30 : 40) : (isSE ? 12 : 20))

            if !isIdle {
                auxiliaryButtons
                    .scaleEffect(isSE ? 0.9 : 1.0)
                    .padding(.bottom, isSE ? 24 : 32)
            }

            // Controls
            VStack(spacing: 0) {
                if !isIdle {
                    compactControls
                        .scaleEffect(ScreenTier.isPhone ? (isSE ? 0.8 : 0.95) : 1.0)
                        .padding(.horizontal, isSE ? 12 : 32)
                        .padding(.bottom, ScreenTier.isPhone ? (isSE ? 20 : 32) : 48)
                }
            }
            .opacity(isIdle ? 0.0 : 1.0)
            .frame(maxHeight: isIdle ? 0 : nil)
            .allowsHitTesting(!isIdle)
            .animation(.easeInOut(duration: 0.7), value: isIdle)
        }
    }

    // ── TABLET / LANDSCAPE ────────────────────────────────────────────
    private func tabletLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer() // Push everything to the absolute bottom
            
            VStack(spacing: isIdle ? 24 : 32) {
                // 1. Artwork & Metadata Section
                HStack(alignment: .bottom, spacing: isLargeCanvas ? 40 : 24) {
                    artworkSection(size: tabletArtworkSize)
                        .scaleEffect(isIdle ? 0.95 : 1.0)
                    
                    VStack(alignment: .leading, spacing: isShortCanvas ? 4 : 8) {
                        Text(playback.currentTrack?.title ?? "Not Playing")
                            .font(.system(size: tabletTitleSize, weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        
                        Text(playback.currentTrack?.artist ?? "Unknown Artist")
                            .font(.system(size: tabletArtistSize, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, isLargeCanvas ? 60 : 24)
                .offset(y: isIdle ? 70 : 0)
                
                // 2. Progress Bar
                progressBar
                    .padding(.horizontal, isLargeCanvas ? 60 : 24)
                    .offset(y: isIdle ? 70 : 0)
                
                // 3. Controls (Visible in Normal State)
                if !isIdle {
                    VStack(spacing: 0) {
                        HStack(alignment: .center) {
                            // Empty spacer to maintain symmetrical centering on the left
                            Color.clear.frame(width: 280)
                            
                            Spacer()
                            
                            // Playback Controls
                            HStack(spacing: isLargeCanvas ? 32 : 20) {
                                playbackControls
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1.5))
                            
                            Spacer()
                            
                            // Auxiliary controls (Lyrics, Queue, Download) on the right
                            HStack(spacing: isLargeCanvas ? 20 : 12) {
                                auxiliaryButtons
                            }
                            .frame(width: 280, alignment: .trailing)
                        }
                        .padding(.horizontal, isLargeCanvas ? 60 : 24)
                    }
                    .padding(.bottom, isShortCanvas ? 20 : 40)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }
            }
            .padding(.bottom, isIdle ? 40 : 0)
        }
        .animation(.spring(response: 0.85, dampingFraction: 0.85), value: isIdle)
    }

    @ViewBuilder
    private var playbackControls: some View {
        // Shuffle
        Button { playback.isShuffle.toggle(); resetIdleTimer() } label: {
            Image(systemName: "shuffle").font(.system(size: 14)).foregroundColor(playback.isShuffle ? Color(hex: "#60a5fa") : .white.opacity(0.5))
        }
        .accessibilityLabel("Shuffle")
        .hoverEffect()

        // Previous
        Button { playback.skipBackward(); resetIdleTimer() } label: {
            Image(systemName: "backward.fill").font(.system(size: 20)).foregroundColor(.white)
        }
        .accessibilityLabel("Previous Track")
        .hoverEffect()

        // Play/Pause
        Button { playback.togglePlayPause(); resetIdleTimer() } label: {
            ZStack {
                Circle().fill(Color.white).frame(width: 48, height: 48)
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18)).foregroundColor(.black)
            }
        }
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
        .hoverEffect()

        // Next
        Button { playback.skipForward(); resetIdleTimer() } label: {
            Image(systemName: "forward.fill").font(.system(size: 20)).foregroundColor(.white)
        }
        .accessibilityLabel("Next Track")
        .hoverEffect()

        // Repeat
        Button { resetIdleTimer() } label: {
            Image(systemName: "repeat").font(.system(size: 14)).foregroundColor(.white.opacity(0.5))
        }
        .accessibilityLabel("Repeat")
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
        }
        .frame(width: size, height: size)
        .cornerRadius(24)
        .shadow(color: .black.opacity(0.35), radius: 25, x: 0, y: 15) // Premium shadow
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var metadataCards: some View {
        VStack(alignment: .leading, spacing: 40) {
            // About Artist
            VStack(alignment: .leading, spacing: isSE ? 16 : 24) {
                Text("About the Artist")
                    .font(.system(size: isSE ? 28 : 32, weight: .bold))
                    .foregroundColor(.white)
                
                Group {
                    if isSE {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 16) {
                                artistImage
                                    .frame(width: 80, height: 80)
                                Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            Text("Playing now on Velora. Discover more tracks and albums from this artist.")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(3)
                        }
                    } else {
                        HStack(spacing: 24) {
                            artistImage
                                .frame(width: 140, height: 140)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text(playback.currentTrack?.artist ?? "Unknown Artist")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.white)
                                Text("Playing now on Velora. Discover more tracks and albums from this artist in your library.")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(3)
                            }
                        }
                    }
                }
                .padding(isSE ? 20 : 32)
                .background(Color.white.opacity(0.05))
                .cornerRadius(isSE ? 20 : 32)
            }
        }
    }

    private var artistImage: some View {
        AsyncImage(url: playback.currentTrack?.coverArtUrl) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Color.white.opacity(0.1))
        }
        .clipShape(Circle())
    }

    private var compactControls: some View {
        HStack(spacing: 0) {
            // Shuffle
            Button { playback.isShuffle.toggle(); resetIdleTimer() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16))
                    .foregroundColor(playback.isShuffle ? Color(hex: "#60a5fa") : .white.opacity(0.5))
                    .frame(width: 40, height: 40)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Shuffle")
            
            Button { playback.skipBackward(); resetIdleTimer() } label: {
                Image(systemName: "backward.fill").font(.system(size: 26)).foregroundColor(.white)
                    .frame(width: 56, height: 56)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Previous Track")
            
            Button(action: { playback.togglePlayPause(); resetIdleTimer() }) {
                ZStack {
                    Circle().fill(Color.white).frame(width: 64, height: 64)
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24)).foregroundColor(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            
            Button { playback.skipForward(); resetIdleTimer() } label: {
                Image(systemName: "forward.fill").font(.system(size: 26)).foregroundColor(.white)
                    .frame(width: 56, height: 56)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Next Track")
            
            // Repeat
            Button { resetIdleTimer() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 40, height: 40)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Repeat")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.4))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var progressBar: some View {
        VStack(spacing: 12) {
            GeometryReader { barGeo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 6)
                    Capsule().fill(Color.white)
                        .frame(width: barGeo.size.width * CGFloat(progressFraction), height: 6)
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
            .frame(height: 20)

            HStack {
                Text(formatTime(displayProgress))
                Spacer()
                Text(formatTime(playback.duration))
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
            .opacity(isIdle ? 0 : 1)
        }
    }
    private var auxiliaryButtons: some View {
        HStack(spacing: isLargeCanvas ? 24 : 16) {
            // Lyrics
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isLyricsMode.toggle()
                    if isLyricsMode { isQueueOpen = false }
                }
                resetIdleTimer()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                    if isLargeCanvas {
                        Text("Lyrics")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .padding(.horizontal, isLargeCanvas ? 16 : 12)
                .padding(.vertical, 10)
                .background(isLyricsMode ? Color.white : Color.white.opacity(0.1))
                .foregroundColor(isLyricsMode ? .black : .white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }
            .accessibilityLabel("Lyrics Toggle")
            
            // Queue
            Button {
                withAnimation(.spring(response: animationResponse, dampingFraction: 0.8)) {
                    isQueueOpen.toggle()
                    if isQueueOpen { isLyricsMode = false }
                }
                resetIdleTimer()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 16, weight: .bold))
                    if isLargeCanvas {
                        Text("Queue")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .padding(.horizontal, isLargeCanvas ? 16 : 12)
                .padding(.vertical, 10)
                .background(isQueueOpen ? Color.white : Color.white.opacity(0.1))
                .foregroundColor(isQueueOpen ? .black : .white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }
            .accessibilityLabel("Queue Toggle")

            // Download
            Button {
                resetIdleTimer()
                if let track = playback.currentTrack {
                    playback.downloadTrack(track)
                }
            } label: {
                let isDownloaded = playback.downloadedTrackIds.contains(playback.currentTrack?.id ?? "")
                Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.to.line.compact")
                    .font(.system(size: 18, weight: .bold))
                    .padding(10)
                    .frame(width: 44, height: 44)
                    .background(isDownloaded ? Color.green.opacity(0.3) : Color.white.opacity(0.1))
                    .foregroundColor(isDownloaded ? .green : .white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(isDownloaded ? Color.green.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1))
            }
            .accessibilityLabel("Download")
        }
    }

    private func formatTime(_ t: Double) -> String {
        guard !t.isNaN, !t.isInfinite else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private var lyricsView: some View {
        ZStack {
            // ── Background: Performance-Optimized Vignette (Non-GPU Heavy) ──
            (isDarkMode ? Color(hex: "#0a0a0a") : Color(hex: "#f5f5f5"))
                .ignoresSafeArea()
            
            // Subtle accent gradient instead of blur
            LinearGradient(
                gradient: Gradient(colors: [
                    (isDarkMode ? Color.blue.opacity(0.15) : Color.blue.opacity(0.05)),
                    .clear
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // ── Header ────────────────────────────────────────────────
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playback.currentTrack?.title ?? "Lyrics")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                        Text(playback.currentTrack?.artist ?? "")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: animationResponse, dampingFraction: 0.8)) {
                            isLyricsMode = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 60)
                .padding(.bottom, 32)
                
                // ── Lyrics Content ────────────────────────────────────────
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 32) {
                        if let lyrics = playback.currentLyrics {
                            let lines = lyrics.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                            
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: isLargeCanvas ? 48 : 34, weight: .black))
                                    .foregroundColor(.white)
                                    .opacity(0.9)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                            }
                        } else {
                            VStack(spacing: 24) {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(1.5)
                                Text("Fetching lyrics...")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 120)
                }
            }
        }
    }
}
