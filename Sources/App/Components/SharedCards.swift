import SwiftUI

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
                .id(track.id)
                .clipped()
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: ScreenTier.isPhone ? 14 : 16, weight: .bold))
                        .foregroundColor(isDark ? .white : .black)
                        .lineLimit(1)
                    Text(track.artist ?? "Unknown")
                        .font(.system(size: ScreenTier.isPhone ? 12 : 14))
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
            AsyncImage(url: album.coverArtUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            }
            .frame(width: cardW ?? (ScreenTier.isPhone ? 160 : 200), height: cardH ?? (ScreenTier.isPhone ? 160 : 200))
            .cornerRadius(16)
            .id(album.id)
            .clipped()
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: ScreenTier.isPhone ? 15 : 18, weight: .bold))
                    .foregroundColor(isDark ? .white : .black)
                    .lineLimit(1)
                Text(album.artist ?? "Unknown")
                    .font(.system(size: ScreenTier.isPhone ? 13 : 15))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .frame(width: cardW ?? (ScreenTier.isPhone ? 160 : 200), alignment: .leading)
        }
    }
}
