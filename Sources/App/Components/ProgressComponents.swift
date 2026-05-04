import SwiftUI

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
