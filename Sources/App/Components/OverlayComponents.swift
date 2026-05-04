import SwiftUI

// MARK: - Overlay Components

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
