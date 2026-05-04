import SwiftUI

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
