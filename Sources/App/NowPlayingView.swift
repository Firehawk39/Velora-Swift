import SwiftUI
import Foundation

struct NowPlayingView: View {
    @EnvironmentObject var playback: PlaybackManager
    @StateObject var fanart = FanartManager.shared
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass)   var vSizeClass
    @Binding var isQueueOpen: Bool
    @Binding var isIdle:      Bool

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
        if isLargeCanvas { return 220 }
        if !isCompact { return 160 }
        return isSE ? 130.0 : 120.0
    }
    private var tabletTitleSize:   CGFloat { 
        if isLargeCanvas { return 32 }
        if !isCompact { return 26 }
        return isSE ? 18.0 : 20.0
    }
    private var tabletArtistSize:  CGFloat { 
        if isLargeCanvas { return 18 }
        if !isCompact { return 16 }
        return isSE ? 14.0 : 14.0
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
                    if let backdrop = fanart.currentBackdrop {
                        Image(uiImage: backdrop)
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
                    } else if let track = playback.currentTrack, let url = track.coverArtUrl {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .opacity(isIdle ? 0.45 : 0.35)
                                .overlay(
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
                        } placeholder: {
                            Color.black
                        }
                    } else {
                        Color.black
                    }
                }
                .animation(.easeInOut(duration: 0.6), value: isIdle)
                .animation(.easeInOut(duration: 0.6), value: fanart.currentBackdrop)
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
                DragGesture(minimumDistance: 40)
                    .onChanged { _ in
                        if !isIdle { resetIdleTimer() }
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
                        } else {
                            resetIdleTimer()
                        }
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
        }
        .preferredColorScheme(.dark)
    }

    private func startIdleTimer() {
        stopIdleTimer()
        guard !isQueueOpen && !playback.isLyricsMode else { return }
        
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
            Spacer()
            
            VStack(spacing: isSE ? 24 : 32) {
                if playback.isLyricsMode {
                    inlineLyricsView
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                } else {
                    // Album Art
                    artworkSection(size: ScreenTier.isPhone ? min(proxy.size.width * (isSE ? 0.55 : 0.65), 260) : tabletArtworkSize)
                        .padding(.bottom, isSE ? 8 : 12)
                    
                    // Centered Metadata
                    VStack(alignment: .center, spacing: 8) {
                        Text(playback.currentTrack?.title ?? "Not Playing")
                            .font(.system(size: isSE ? 20 : 26, weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        
                        Text(playback.currentTrack?.artist ?? "Unknown Artist")
                            .font(.system(size: isSE ? 14 : 16, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                }
                
                // Progress Bar
                progressBar
                    .padding(.horizontal, 24)
                
                if !isIdle {
                    // Controls Section for Portrait
                    VStack(spacing: 24) {
                        HStack(spacing: 24) {
                            playbackControls
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        
                        HStack(spacing: 12) {
                            lyricsButton
                            queueButton
                            downloadButton
                        }
                        .scaleEffect(0.9)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, isIdle ? 60 : 32)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: playback.isLyricsMode)
        .animation(.spring(response: 1.0, dampingFraction: 0.85), value: isIdle)
    }

    // ── TABLET / LANDSCAPE ────────────────────────────────────────────
    private func tabletLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer() // Push everything to bottom
            
            VStack(spacing: isShortCanvas ? 20 : 32) {
                if playback.isLyricsMode {
                    // Inline Lyrics State
                    HStack {
                        inlineLyricsView
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                if !isIdle {
                    HStack(alignment: .center) {
                        // 1. Left Section (Empty now)
                        HStack {
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        
                        // 2. Center Section: Playback Controls Pill
                        HStack(spacing: isLargeCanvas ? 32 : 24) {
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
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
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
            
            // Album Info
            VStack(alignment: .leading, spacing: isSE ? 16 : 24) {
                Text("From the Album")
                    .font(.system(size: isSE ? 28 : 32, weight: .bold))
                    .foregroundColor(.white)
                
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playback.currentTrack?.album ?? "Unknown Album")
                            .font(.system(size: isSE ? 24 : 28, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("Album • \(playback.currentTrack?.artist ?? "Unknown")")
                            .font(.system(size: isSE ? 14 : 16))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.title3).foregroundColor(.white.opacity(0.3))
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
            let isDownloaded = playback.downloadedTrackIds.contains(playback.currentTrack?.id ?? "")
            Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.to.line.compact")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.5))
                .foregroundColor(isDownloaded ? .green : .white)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .accessibilityLabel("Download")
    }

    private var inlineLyricsView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if let syncedLyrics = playback.currentSyncedLyrics, !syncedLyrics.isEmpty {
                        let activeIndex = syncedLyrics.lastIndex(where: { playback.progress >= $0.time }) ?? 0
                        
                        ForEach(Array(syncedLyrics.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .font(.system(size: isLargeCanvas ? 44 : 32, weight: .black))
                                .foregroundColor(.white)
                                .opacity(index == activeIndex ? 1.0 : 0.4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(index)
                        }
                        .onChange(of: activeIndex) { newIndex in
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                scrollProxy.scrollTo(newIndex, anchor: .center)
                            }
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
                .padding(.vertical, 40)
            }
        }
    }

    private func formatTime(_ t: Double) -> String {
        guard !t.isNaN, !t.isInfinite else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

}
