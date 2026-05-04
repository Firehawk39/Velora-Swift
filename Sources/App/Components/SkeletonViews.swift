import SwiftUI

// MARK: - Skeleton Views

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
