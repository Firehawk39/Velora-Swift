import SwiftUI
import Foundation

struct NowPlayingView: View {
    @EnvironmentObject var playback: PlaybackManager
    @StateObject var fanart = FanartManager.shared
    @StateObject private var mb = MusicBrainzManager.shared
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass)   var vSizeClass
    @Binding var isQueueOpen: Bool
    @Binding var isIdle:      Bool

    @State private var isDragging   = false
    @State private var dragProgress: Double = 0
    @State private var idleTimer: Timer? = nil
    @State private var showPlayPauseHint: Bool = false
    @State private var hintIcon: String = "play.fill"
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
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                            .opacity(isIdle ? 0.45 : 0.35)
                    } else if let track = playback.currentTrack, let url = track.coverArtUrl {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                                .blur(radius: 15) // Subtle blur for ambient feel when backdrop is missing
                                .opacity(isIdle ? 0.4 : 0.3)
                        } placeholder: {
                            Color.black
                        }
                    } else {
                        Color.black
                    }
                }
                .id("bg-\(playback.currentTrack?.id ?? "none")") // Force refresh on track change
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
                .ignoresSafeArea(.all)
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
                    .onTapGesture {
                        if isIdle { resetIdleTimer() }
                    }
                }
                .scrollDisabledIfAvailable(isIdle) // Lock scrolling when in idle state
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
            // Don't wake the UI on automatic track change; just restart the countdown
            startIdleTimer()
            refreshMetadata()
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
                        if mb.isLoading {
                            CircularProgressView(progress: mb.metadataProgress, size: 30, strokeWidth: 3, accentColor: .red)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            inlineLyricsView
                                .frame(maxWidth: .infinity, alignment: .leading)
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
        Button { 
            playback.toggleRepeatMode()
            resetIdleTimer() 
        } label: {
            Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                .font(.system(size: 14))
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
            
            // Hidden Secret Feedback Overlay
            if showPlayPauseHint {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.4))
                        .frame(width: 70, height: 70)
                        .blur(radius: 10)
                    
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
                    if mb.isLoading {
                        HStack {
                            Spacer()
                            CircularProgressView(progress: mb.metadataProgress, size: 40, strokeWidth: 4, accentColor: .red)
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
                                
                                if let info = mb.currentArtistInfo {
                                    Text([info.type, info.area, info.lifeSpan].compactMap { $0 }.joined(separator: " • "))
                                        .font(.system(size: isSE ? 12 : 14))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                        }
                        
                        if let bio = mb.currentArtistInfo?.biography {
                            Text(bio)
                                .font(.system(size: isSE ? 14 : 16))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(10)
                        } else {
                            Text("No further information found.")
                                .font(.system(size: isSE ? 14 : 16))
                                .foregroundColor(.white.opacity(0.4))
                                .italic()
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
            ZStack {
                if let progress = playback.downloadProgress[playback.currentTrack?.id ?? ""] {
                    CircularProgressView(progress: progress, size: 24, strokeWidth: 3, accentColor: .red)
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
        ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if let syncedLyrics = playback.currentSyncedLyrics, !syncedLyrics.isEmpty {
                        let activeIndex = syncedLyrics.lastIndex(where: { playback.progress >= $0.time }) ?? 0
                        
                        ForEach(Array(syncedLyrics.enumerated()), id: \.offset) { index, line in
                            renderLyricLine(line: line, index: index, activeIndex: activeIndex, syncedLyrics: syncedLyrics)
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

    private func renderLyricLine(line: LyricLine, index: Int, activeIndex: Int, syncedLyrics: [LyricLine]) -> Text {
        let baseFont = Font.system(size: isLargeCanvas ? 44 : 32, weight: .black)
        
        if index != activeIndex {
            return Text(line.text)
                .font(baseFont)
                .foregroundColor(.white.opacity(0.4))
        } else {
            let duration = (index + 1 < syncedLyrics.count) ? (syncedLyrics[index + 1].time - line.time) : 5.0
            let elapsed = max(0, playback.progress - line.time)
            
            let words = line.text.split(separator: " ").map(String.init)
            let wordDuration = duration / Double(max(1, words.count))
            
            var concatenatedText = Text("")
            for (i, word) in words.enumerated() {
                let wordStart = Double(i) * wordDuration
                // Add a small 0.1s buffer for smooth feeling
                let isSpoken = elapsed >= (wordStart - 0.1)
                let opacity = isSpoken ? 1.0 : 0.4
                
                let textSegment = Text(word + (i == words.count - 1 ? "" : " ")).foregroundColor(.white.opacity(opacity))
                concatenatedText = concatenatedText + textSegment
            }
            
            return concatenatedText.font(baseFont)
        }
    }
    private func refreshMetadata() {
        guard let track = playback.currentTrack else { return }
        
        let artistName = track.artist ?? "Unknown Artist"
        let albumName = track.album ?? "Unknown Album"
        
        // 0. Immediately clear the current backdrop to avoid stale artist images
        fanart.currentBackdrop = nil
        
        // 1. Immediately trigger backdrop fetch (FanartManager will check cache instantly)
        // This prevents the "waiting for Navidrome response" flicker
        fanart.fetchBackdrop(for: artistName, mbid: nil)
        
        // 2. Fetch extended info from Navidrome (MBID + Bio)
        if let artistId = track.artistId {
            playback.client.fetchArtistInfo(artistId: artistId) { bio, mbid in
                DispatchQueue.main.async {
                    // Update MB manager
                    mb.fetchAboutArtist(artistName: artistName, mbid: mbid)
                    
                    if let bio = bio {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            mb.currentArtistInfo?.biography = bio
                        }
                    }
                    
                    // If we got a fresh MBID, update fanart too (though usually it's already there)
                    if let mbid = mbid {
                        fanart.fetchBackdrop(for: artistName, mbid: mbid)
                    }
                }
            }
        } else {
            mb.fetchAboutArtist(artistName: artistName, mbid: nil)
        }
        
        // 3. Album info
        mb.fetchAboutAlbum(albumName: albumName, artistName: artistName, mbid: nil)
    }
}
