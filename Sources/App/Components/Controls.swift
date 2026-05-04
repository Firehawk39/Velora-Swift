import SwiftUI

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
