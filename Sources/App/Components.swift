import SwiftUI
import Foundation

// MARK: - Screen Tier
public enum ScreenTier {
    case tiny, compact, regular, large, huge
    @MainActor public static var current: ScreenTier {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let minDim = min(w, h)
        let maxDim = max(w, h)

        if minDim <= 330 { return .tiny } // iPhone SE 1st Gen
        if minDim <= 395 { return .compact } // Standard iPhone / mini
        if minDim <= 440 { return .regular } // Plus/Max iPhones
        if maxDim < 1024 { return .large } // Standard iPads
        return .huge // iPad Pro 12.9"
    }
    @MainActor public static var isSE: Bool { current == .tiny }
    @MainActor public static var isSmall: Bool { min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) <= 375 }
    @MainActor public static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    @MainActor public static var isHuge: Bool { current == .huge }
    @MainActor public static var isCarDisplay: Bool {
        if UIDevice.current.userInterfaceIdiom == .carPlay { return true }
        if UIScreen.screens.count > 1 { return true }

        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let minDim = min(w, h)
        let maxDim = max(w, h)

        let nativeW = UIScreen.main.nativeBounds.width
        let nativeH = UIScreen.main.nativeBounds.height
        let minNative = min(nativeW, nativeH)
        let maxNative = max(nativeW, nativeH)

        // Direct check for 720p physical resolution (1280x720 or 720x1280)
        if minNative == 720 && maxNative == 1280 { return true }

        // Direct check for 720p logical bounds
        if minDim == 720 && maxDim == 1280 { return true }

        // Common car screen sizes in physical pixels
        if (minNative == 480 && maxNative == 800) ||   // 800x480
           (minNative == 480 && maxNative == 1280) ||  // 1280x480
           (minNative == 600 && maxNative == 1024) ||  // 1024x600
           (minNative == 800 && maxNative == 1280) {   // 1280x800
            return true
        }

        // Generic check: widescreen aspect ratio (>= 1.55 and <= 2.7) on non-phone devices (or mirrored/projected screens)
        // which distinguishes it from standard 4:3 or 16:10 iPads (iPad Pro 11 is 1.43, iPad 12.9 is 1.33)
        let aspect = Double(maxNative) / Double(minNative)
        if aspect >= 1.55 && aspect <= 2.7 && minNative >= 480 && minNative <= 900 {
            // Exclude standard phones to avoid false positives on standard devices, but keep CarPlay/AI boxes
            if UIDevice.current.userInterfaceIdiom != .phone {
                return true
            }
        }

        // Also keep standard iPhone landscape when it is large enough
        if UIDevice.current.userInterfaceIdiom == .phone && w > h && minDim > 375 { return true }

        return false
    }
}

// MARK: - Self-Healing Async Image
public struct SelfHealingAsyncImage<Content: View, Placeholder: View>: View {
    public let url: URL?
    @ViewBuilder public let content: (Image) -> Content
    @ViewBuilder public let placeholder: () -> Placeholder

    @State private var retryCount = 0
    @State private var reloadTrigger = UUID()

    public init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                content(image)
                    .onAppear { retryCount = 0 } // Reset on success
            } else if phase.error != nil {
                placeholder()
                    .onAppear {
                        scheduleRetry()
                    }
            } else {
                placeholder() // Loading state
            }
        }
        .id(reloadTrigger)
    }

    private func scheduleRetry() {
        guard retryCount < 5 else { return } // Max retries
        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount)), 30.0) // 2s, 4s, 8s, 16s, 30s

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            reloadTrigger = UUID()
        }
    }
}

// MARK: - App Header
struct AppHeader: View {
    @Binding var activeTab: String
    @Binding var showProfileMenu: Bool
    let isDarkMode: Bool
    let toggleDark: () -> Void
    var onAction: () -> Void
    var scrollOffset: CGFloat = 0

    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass) var vSizeClass
    var isCompact: Bool { hSizeClass == .compact }
    var isLandscape: Bool {
        if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return windowScene.coordinateSpace.bounds.width > windowScene.coordinateSpace.bounds.height
        }
        return UIScreen.main.bounds.width > UIScreen.main.bounds.height
    }

    var isPlayingTab: Bool { activeTab == "now-playing" }
    var headerFG: Color { isPlayingTab ? .white : (isDarkMode ? .white : .black) }

    // MARK: - Responsive Layout Configs
    private var themeToggleWidth: CGFloat {
        if isLandscape { return 84 }
        return 72
    }

    private var themeToggleHeight: CGFloat {
        if isLandscape { return 40 }
        return 36
    }

    private var themeToggleCircleSize: CGFloat {
        if isLandscape { return 32 }
        return 28
    }

    private var themeToggleOffset: CGFloat {
        if isLandscape { return 22 }
        return 18
    }

    private var themeToggleIconSize: CGFloat {
        if isLandscape { return 13 }
        return 11
    }

    private var themeToggleHStackWidth: CGFloat {
        if isLandscape { return 56 }
        return 48
    }

    private var profileButtonSize: CGFloat {
        if isLandscape { return 36 }
        return ScreenTier.isPhone ? 24 : 26
    }

    private var logoFontSize: CGFloat {
        if isLandscape { return 36 }
        return ScreenTier.isPhone ? (ScreenTier.isSmall ? 26 : 32) : 34
    }

    private var navigationPillScale: CGFloat {
        if isLandscape { return 1.10 }
        return ScreenTier.isPhone ? 0.85 : 0.9
    }

    private var navigationPillPadding: CGFloat {
        if isLandscape { return 10 }
        return ScreenTier.isSE ? 4 : 8
    }

    private var mainHeaderHorizontalPadding: CGFloat {
        if isLandscape { return 44.0 }
        return ScreenTier.isSmall ? 16.0 : (isCompact ? 24.0 : 48.0)
    }

    var body: some View {
        Group {
        ZStack {
            mainHeaderContent
            navigationPill
        }
        }
        .padding(.vertical, ScreenTier.isSmall ? 10.0 : 20.0)
    }

    private var mainHeaderContent: some View {
        HStack(alignment: .center, spacing: 0) {
            logoButton
            Spacer()
            headerActions
        }
        .padding(.horizontal, mainHeaderHorizontalPadding)
        .offset(y: min(0.0, scrollOffset))
        .opacity(max(0.0, 1.0 + (min(0.0, scrollOffset) / 50.0)))
    }

    private var logoButton: some View {
        Button(action: {
            onAction()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                activeTab = "home"
            }
        }) {
            Text("Velora.")
                .font(.custom("Stardom", size: logoFontSize).weight(.bold))
                .kerning(-1.2)
                .foregroundColor(headerFG)
        }
        .accessibilityLabel("Velora Home")
        .hoverEffect()
    }

    private var headerActions: some View {
        HStack(spacing: ScreenTier.isSmall ? 12.0 : 20.0) {
            if (isLandscape || ScreenTier.isHuge) && !isPlayingTab {
                themeToggle
            }
            profileButton
        }
    }

    private var themeToggle: some View {
        Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                toggleDark()
            }
        }) {
            ZStack {
                Capsule()
                    .fill(isDarkMode ? Color.white.opacity(0.2) : Color(hex: "#d1d5db"))
                    .frame(width: themeToggleWidth, height: themeToggleHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: themeToggleCircleSize, height: themeToggleCircleSize)
                    .offset(x: isDarkMode ? themeToggleOffset : -themeToggleOffset)

                HStack {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: themeToggleIconSize, weight: .bold))
                        .foregroundColor(isDarkMode ? .gray : .yellow)
                    Spacer()
                    Image(systemName: "moon.fill")
                        .font(.system(size: themeToggleIconSize, weight: .bold))
                        .foregroundColor(isDarkMode ? .blue : .gray)
                }
                .frame(width: themeToggleHStackWidth)
            }
        }
        .scaleEffect(ScreenTier.isCarDisplay && isLandscape ? 1.15 : 1.0)
        .accessibilityLabel("Toggle Dark Mode")
        .hoverEffect()
    }

    private var profileButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                showProfileMenu.toggle()
            }
        }) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: profileButtonSize))
                .foregroundColor(headerFG)
        }
        .accessibilityLabel("Profile and Settings")
        .hoverEffect()
    }

    private var navigationPill: some View {
        HStack(spacing: 0) {
            TabButton(id: "home", label: "Home", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
            TabButton(id: "library", label: "Library", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
            TabButton(id: "velora", label: "Velora", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
            TabButton(id: "search", label: "Search", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
            TabButton(id: "now-playing", label: "Playing", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
        }
        .padding(navigationPillPadding)
        .background(
            isPlayingTab ? AnyShapeStyle(Color.white.opacity(0.1)) :
            (isDarkMode ? AnyShapeStyle(Color(hex: "#1a1a1a")) : AnyShapeStyle(Color(hex: "#e5e7eb")))
        )
        .clipShape(Capsule())
        .scaleEffect(navigationPillScale)
    }
}

struct TabButton: View {
    let id: String
    let label: String
    var icon: String? = nil
    @Binding var activeTab: String
    let isDarkMode: Bool
    let isPlayingTab: Bool
    let onAction: () -> Void
    var isBottomNav: Bool = false

    @Environment(\.horizontalSizeClass) var hSizeClass
    var isCompact: Bool { hSizeClass == .compact }

    var isActive: Bool { activeTab == id }
    var isLandscape: Bool {
        UIScreen.main.bounds.width > UIScreen.main.bounds.height
    }

    private var iconName: String {
        if let icon = icon { return icon }
        switch id {
        case "home": return "house.fill"
        case "library": return "square.stack.fill"
        case "search": return "magnifyingglass"
        case "now-playing": return "play.circle.fill"
        default: return "circle"
        }
    }

    private var fontSize: CGFloat {
        if isLandscape {
            if ScreenTier.isSmall {
                return 14
            } else if ScreenTier.isPhone {
                return 14
            } else {
                return 16
            }
        } else {
            if ScreenTier.isSmall {
                return 13
            } else {
                return 16
            }
        }
    }

    private var horizontalPadding: CGFloat {
        if isLandscape {
            if ScreenTier.isSmall {
                return 15
            } else if ScreenTier.isPhone {
                return 18
            } else {
                return 16
            }
        } else {
            if ScreenTier.isSmall {
                return isActive ? 16 : 12
            } else {
                return 16
            }
        }
    }

    private var verticalPadding: CGFloat {
        if isLandscape {
            if ScreenTier.isSmall {
                return 8
            } else if ScreenTier.isPhone {
                return 8
            } else {
                return 8
            }
        } else {
            return 8
        }
    }

    var body: some View {
        Button(action: {
            onAction()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                activeTab = id
            }
        }) {
            VStack(spacing: 4) {
                if isBottomNav {
                    if id == "velora" {
                        Text("V")
                            .font(.custom("Stardom", size: 26).weight(.bold))
                            .offset(y: 1)
                    } else {
                        Image(systemName: iconName)
                            .font(.system(size: 22))
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                } else {
                    if id == "velora" {
                        Text("V")
                            .font(.custom("Stardom", size: fontSize + 4).weight(.bold))
                            .padding(.horizontal, horizontalPadding)
                            .padding(.vertical, verticalPadding)
                            .background(isActive ? (isPlayingTab || isDarkMode ? Color.white.opacity(0.15) : Color.white) : Color.clear)
                            .clipShape(Capsule())
                            .offset(y: 1) // optical alignment for Stardom
                    } else {
                        Text(label)
                            .font(.system(size: fontSize, weight: isActive ? .bold : .medium))
                            .padding(.horizontal, horizontalPadding)
                            .padding(.vertical, verticalPadding)
                            .background(isActive ? (isPlayingTab || isDarkMode ? Color.white.opacity(0.15) : Color.white) : Color.clear)
                            .clipShape(Capsule())
                    }
                }
            }
            .foregroundColor(isActive ? (isDarkMode ? .white : .black) : .gray)
            .frame(maxWidth: isBottomNav ? .infinity : nil)
            .padding(.vertical, isBottomNav ? 6 : 0)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Shared Components

struct TrackCard: View {
    let track: Track
    let isDark: Bool
    let size: CGFloat
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 12) {
                SelfHealingAsyncImage(url: track.coverArtUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                }
                .frame(width: size, height: size)
                .cornerRadius(12)
                .id(track.id)
                .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isDark ? .white : .black)
                        .lineLimit(1)
                    Text(track.artist ?? "Unknown")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                .frame(width: size, alignment: .leading)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .hoverEffect()
    }
}

struct ArtistCircle: View {
    let artist: Artist
    let isDark: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            SelfHealingAsyncImage(url: artist.coverArtUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            }
            .frame(width: size, height: size)
            .id(artist.id)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

            Text(artist.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isDark ? .white : .black)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(width: size)
    }
}

struct AlbumCard: View {
    let album: Album
    let isDark: Bool
    var cardW: CGFloat? = nil
    var cardH: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SelfHealingAsyncImage(url: album.coverArtUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            }
            .frame(width: cardW ?? 160, height: cardH ?? 160)
            .cornerRadius(16)
            .id(album.id)
            .clipped()
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(isDark ? .white : .black)
                    .lineLimit(1)
                Text(album.artist ?? "Unknown")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .frame(width: cardW ?? 160, alignment: .leading)
        }
    }
}

struct SkeletonRow: View {
    let count: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let isDark: Bool
    var circular: Bool = false
    var rounded: CGFloat = 12
    var hPad: CGFloat? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 12) {
                        if circular {
                            Circle()
                                .fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .frame(width: cardWidth, height: cardHeight)
                        } else {
                            RoundedRectangle(cornerRadius: rounded)
                                .fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .frame(width: cardWidth, height: cardHeight)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .frame(width: cardWidth * 0.7, height: 14)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .frame(width: cardWidth * 0.4, height: 10)
                        }
                    }
                }
            }
            .padding(.horizontal, hPad ?? (ScreenTier.isPhone ? 16 : 40))
        }
    }
}

// MARK: - Profile Dropdown
struct ProfileDropdown: View {
    let isDarkMode: Bool
    let toggleDark: () -> Void
    let onSettings: () -> Void
    var isLandscape: Bool = false
    var isPlayingTab: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !(isLandscape || ScreenTier.isHuge) || isPlayingTab {
                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        toggleDark()
                    }
                }) {
                    HStack {
                        Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                            .foregroundColor(isDarkMode ? .yellow : .blue)
                        Text(isDarkMode ? "Light Mode" : "Dark Mode")
                        Spacer()
                    }
                    .padding()
                    .foregroundColor(isDarkMode ? .white : .black)
                }
                Divider().background(Color.white.opacity(0.1))
            }
            Button(action: onSettings) {
                HStack {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                    Spacer()
                }
                .padding()
            }
        }
        .frame(width: 220)
        .background(isDarkMode ? Color(hex: "#1f1f1f") : Color.white)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05), lineWidth: 1))
    }
}

// MARK: - Queue Panel
struct QueuePanel: View {
    @EnvironmentObject var playback: PlaybackManager
    let isDarkMode: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(playback.queue) { track in
                        QueueRow(
                            track: track,
                            isCurrent: playback.currentTrack?.id == track.id,
                            isDarkMode: isDarkMode
                        ) {
                            playback.playTrack(track, context: playback.queue)
                        }
                    }
                }
                .padding(.horizontal, ScreenTier.isSE ? 10 : 16)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 380)
        .background(backgroundView)
        .overlay(sideBorder, alignment: .leading)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(isDarkMode ? .white : .black)
                Text("\(playback.queue.count) tracks in queue")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.gray)
                    .padding(12)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    private var backgroundView: some View {
        ZStack {
            // Performance-optimized solid background with subtle gradient
            (isDarkMode ? Color(hex: "#121212") : Color(hex: "#fafafa"))
                .ignoresSafeArea()

            LinearGradient(
                gradient: Gradient(colors: [
                    isDarkMode ? Color.white.opacity(0.03) : Color.black.opacity(0.02),
                    .clear
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Glass material (Thin for performance)
            if isDarkMode {
                Color.black.opacity(0.4)
            } else {
                Color.white.opacity(0.4)
            }
        }
    }

    private var sideBorder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(width: 1)
            .padding(.vertical)
    }
}

struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    let isDarkMode: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                SelfHealingAsyncImage(url: track.coverArtUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.05)
                }
                .frame(width: 56, height: 56)
                .cornerRadius(8)

                if isCurrent {
                    Color.black.opacity(0.4)
                        .cornerRadius(8)
                    Image(systemName: "waveform")
                        .foregroundColor(.white)
                        .font(.system(size: 18, weight: .bold))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 16, weight: isCurrent ? .bold : .medium))
                    .foregroundColor(isCurrent ? Color(hex: "#60a5fa") : (isDarkMode ? .white : .black))
                    .lineLimit(1)
                Text(track.artist ?? "Unknown Artist")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()

            Text(track.durationFormatted)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            isCurrent ? (isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)) : Color.clear
        )
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Circular Progress Components

struct CircularProgressView: View {
    let progress: Double
    var size: CGFloat = 24
    var strokeWidth: CGFloat = 3
    var accentColor: Color = .red

    var body: some View {
        ZStack {
            // Background circle (Track)
            Circle()
                .stroke(accentColor.opacity(0.15), lineWidth: strokeWidth)

            // Foreground circle (Progress)
            Circle()
                .trim(from: 0, to: max(0.01, progress))
                .stroke(accentColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: progress)
    }
}

struct LoadingCircle: View {
    var size: CGFloat = 24
    var strokeWidth: CGFloat = 3
    var accentColor: Color = .red

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(accentColor.opacity(0.15), lineWidth: strokeWidth)

            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(accentColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(Animation.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
        }
        .frame(width: size, height: size)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Toggle Button
public struct ToggleButton: View {
    public let icon: String
    public let label: String
    public let isActive: Bool
    public let action: () -> Void

    public init(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                Text(label)
                    .font(.system(size: ScreenTier.isSE ? 12 : 14, weight: .bold))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(isActive ? Color.white.opacity(0.2) : Color.clear)
            .foregroundColor(.white)
            .cornerRadius(100)
            .overlay(
                RoundedRectangle(cornerRadius: 100)
                    .stroke(Color.white.opacity(isActive ? 0.5 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
// MARK: - Bottom Navigation Bar
public struct BottomNavigationBar: View {
    @Binding var activeTab: String
    let isDarkMode: Bool
    let isPlayingTab: Bool
    let onAction: () -> Void
    
    public init(activeTab: Binding<String>, isDarkMode: Bool, isPlayingTab: Bool, onAction: @escaping () -> Void) {
        self._activeTab = activeTab
        self.isDarkMode = isDarkMode
        self.isPlayingTab = isPlayingTab
        self.onAction = onAction
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            TabButton(id: "home", label: "Home", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction, isBottomNav: true)
            TabButton(id: "library", label: "Library", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction, isBottomNav: true)
            TabButton(id: "velora", label: "Velora", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction, isBottomNav: true)
            TabButton(id: "search", label: "Search", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction, isBottomNav: true)
            TabButton(id: "now-playing", label: "Playing", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction, isBottomNav: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
