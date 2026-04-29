import SwiftUI
import Foundation

// MARK: - Screen Tier
public enum ScreenTier {
    case tiny, compact, regular, large, huge
    public static var current: ScreenTier {
        let w = UIScreen.main.bounds.width
        if w <= 320 { return .tiny } // iPhone SE 1st Gen
        if w < 414 { return .compact } // Standard iPhone / mini
        if w < 768 { return .regular } // Plus/Max iPhones
        if w < 1024 { return .large } // 10.25" Displays / standard iPads
        return .huge // iPad Pro 12.9"
    }
    public static var isSE: Bool { current == .tiny }
    public static var isPhone: Bool { UIScreen.main.bounds.width < 768 }
    public static var isHuge: Bool { current == .huge }
}

// MARK: - App Header
struct AppHeader: View {
    @Binding var activeTab: String
    @Binding var showProfileMenu: Bool
    let isDarkMode: Bool
    let toggleDark: () -> Void
    var onAction: () -> Void

    @Environment(\.horizontalSizeClass) var hSizeClass
    var isCompact: Bool { hSizeClass == .compact }

    var isPlayingTab: Bool { activeTab == "now-playing" }
    var headerFG: Color { isPlayingTab ? .white : (isDarkMode ? .white : .black) }

    var body: some View {
        ZStack {
            mainHeaderContent
            navigationPill
        }
        .padding(.vertical, ScreenTier.isSE ? 12.0 : 20.0)
    }
    
    private var mainHeaderContent: some View {
        HStack(alignment: .center, spacing: 0) {
            logoButton
            Spacer()
            headerActions
        }
        .padding(.horizontal, isCompact ? 24.0 : 48.0)
    }
    
    private var logoButton: some View {
        Button(action: { 
            onAction()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { 
                activeTab = "home" 
            } 
        }) {
            Text("Velora.")
                .font(.custom("Stardom", size: ScreenTier.isPhone ? (ScreenTier.isSE ? 28 : 32) : 34.0).weight(.bold))
                .kerning(-1.2)
                .foregroundColor(headerFG)
        }
        .accessibilityLabel("Velora Home")
        .hoverEffect()
    }
    
    private var headerActions: some View {
        HStack(spacing: ScreenTier.isSE ? 16.0 : 20.0) {
            if !isPlayingTab {
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
                    .frame(width: 72, height: 36)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .offset(x: isDarkMode ? 18 : -18)
                
                HStack {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isDarkMode ? .gray : .yellow)
                    Spacer()
                    Image(systemName: "moon.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isDarkMode ? .blue : .gray)
                }
                .frame(width: 48)
            }
        }
        .accessibilityLabel("Toggle Dark Mode")
        .hoverEffect()
        .opacity(isPlayingTab ? 0 : 1)
        .disabled(isPlayingTab)
    }
    
    private var profileButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                showProfileMenu.toggle()
            }
        }) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: ScreenTier.isPhone ? 24 : 26))
                .foregroundColor(headerFG)
        }
        .accessibilityLabel("Profile and Settings")
        .hoverEffect()
    }
    
    private var navigationPill: some View {
        HStack(spacing: 0) {
            TabButton(id: "home", label: "Home", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
            TabButton(id: "library", label: "Library", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
            TabButton(id: "search", label: "Search", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
            TabButton(id: "now-playing", label: "Playing", activeTab: $activeTab, isDarkMode: isDarkMode, isPlayingTab: isPlayingTab, onAction: onAction)
        }
        .padding(ScreenTier.isPhone ? 6 : 8)
        .background(
            isPlayingTab ? AnyShapeStyle(Color.white.opacity(0.1)) :
            (isDarkMode ? AnyShapeStyle(Material.ultraThinMaterial.opacity(0.5)) : AnyShapeStyle(Color(hex: "#e5e7eb")))
        )
        .clipShape(Capsule())
        .scaleEffect(ScreenTier.isPhone ? 0.9 : 0.95) // Slightly smaller on everything
    }
}

private struct TabButton: View {
    let id: String
    let label: String
    @Binding var activeTab: String
    let isDarkMode: Bool
    let isPlayingTab: Bool
    let onAction: () -> Void
    @Environment(\.horizontalSizeClass) var hSizeClass
    var isCompact: Bool { hSizeClass == .compact }

    var isActive: Bool { activeTab == id }

    var body: some View {
        Button(action: { 
            onAction()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { 
                activeTab = id 
            } 
        }) {
            Text(label)
                .font(.system(size: ScreenTier.isPhone ? 15 : 14, weight: isActive ? .bold : .medium))
                .foregroundColor(isActive ? (activeTab == "now-playing" || isDarkMode ? .white : .black) : (activeTab == "now-playing" ? .white.opacity(0.6) : .gray))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    isActive ? (isPlayingTab || isDarkMode ? Color.white.opacity(0.15) : Color.white) : Color.clear
                )
                .clipShape(Capsule())
                .shadow(color: isActive && !isDarkMode && !isPlayingTab ? Color.black.opacity(0.05) : Color.clear, radius: 2, y: 1)
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
                AsyncImage(url: track.coverArtUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                }
                .frame(width: size, height: size)
                .cornerRadius(12)
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
            AsyncImage(url: artist.coverArtUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            }
            .frame(width: size, height: size)
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
            AsyncImage(url: album.coverArtUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            }
            .frame(width: cardW ?? 160, height: cardH ?? 160)
            .cornerRadius(16)
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
    let onLogout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSettings) {
                HStack {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                    Spacer()
                }
                .padding()
            }
            Divider().background(Color.white.opacity(0.1))
            Button(action: onLogout) {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Logout")
                    Spacer()
                }
                .padding()
                .foregroundColor(.red)
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
                VStack(spacing: 12) {
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
                .padding(.horizontal, 8)
                .padding(.bottom, 100)
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
                AsyncImage(url: track.coverArtUrl) { img in
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
                    .font(.system(size: 14, weight: .bold))
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
