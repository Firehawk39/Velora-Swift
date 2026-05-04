import SwiftUI

// MARK: - App Header
struct AppHeader: View {
    @Binding var activeTab: String
    @Binding var showProfileMenu: Bool
    let isDarkMode: Bool
    let toggleDark: () -> Void
    let subtitle: String?
    let onAction: () -> Void
    
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
            HStack(spacing: 0) {
                Text("Velora.")
                    .font(.custom("Stardom", size: ScreenTier.isPhone ? (ScreenTier.isSE ? 22 : 32) : 42.0).weight(.bold))
                    .kerning(ScreenTier.isSE ? -0.8 : -1.2)
                    .foregroundColor(headerFG)
                
                if let subtitle = subtitle {
                    Text("/")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.gray)
                    Text(subtitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(headerFG)
                }
            }
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
                .font(.system(size: ScreenTier.isPhone ? 24 : 32))
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
        .padding(ScreenTier.isSE ? 4 : (ScreenTier.isPhone ? 6 : 8))
        .background(
            isPlayingTab ? AnyShapeStyle(Color.white.opacity(0.1)) :
            (isDarkMode ? AnyShapeStyle(Material.ultraThinMaterial.opacity(0.5)) : AnyShapeStyle(Color(hex: "#e5e7eb")))
        )
        .clipShape(Capsule())
        .scaleEffect(ScreenTier.isSE ? 0.85 : (ScreenTier.isPhone ? 0.9 : 0.95)) // Even smaller on SE
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
                .font(.system(size: ScreenTier.isSE ? 13 : (ScreenTier.isPhone ? 15 : 16), weight: isActive ? .bold : .medium))
                .foregroundColor(isActive ? (activeTab == "now-playing" || isDarkMode ? .white : .black) : (activeTab == "now-playing" ? .white.opacity(0.6) : .gray))
                .padding(.horizontal, ScreenTier.isSE ? 10 : 16)
                .padding(.vertical, ScreenTier.isSE ? 6 : 8)
                .background(
                    isActive ? (isPlayingTab || isDarkMode ? Color.white.opacity(0.15) : Color.white) : Color.clear
                )
                .clipShape(Capsule())
                .shadow(color: isActive && !isDarkMode && !isPlayingTab ? Color.black.opacity(0.05) : Color.clear, radius: 2, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
