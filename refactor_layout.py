import sys

with open('Sources/App/NowPlayingView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

old_layout = '''    private func portraitLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if !playback.isLyricsMode {
                Spacer()
            }
            
            VStack(spacing: isSE ? 8 : (isSmallDevice ? 16 : 32)) {
                if playback.isLyricsMode {
                    inlineLyricsView
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height - headerHeight - (isSE ? 100 : 120))
                        .padding(.horizontal, 24)
                } else {
                    // Album Art
                    artworkSection(size: ScreenTier.isPhone ? min(proxy.size.width * (isSE ? 0.42 : (isSmallDevice ? 0.55 : 0.7)), 280) : tabletArtworkSize)
                        .padding(.bottom, isSE ? 0 : (isSmallDevice ? 6 : 12))
                    
                    // Centered Metadata
                    VStack(alignment: .center, spacing: isSE ? 2 : 6) {
                        Text(playback.currentTrack?.title ?? "Not Playing")
                            .font(.system(size: isSE ? 17 : (isSmallDevice ? 20 : 26), weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        
                        Text(playback.currentTrack?.artist ?? "Unknown Artist")
                            .font(.system(size: isSE ? 12 : (isSmallDevice ? 14 : 16), weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                }
                
                // Progress Bar
                progressBar
                    .padding(.horizontal, 24)
                
                if !isIdle && !playback.isLyricsMode {
                    // Controls Section for Portrait
                    VStack(spacing: isSE ? 8 : (isSmallDevice ? 16 : 24)) {
                        HStack(spacing: isSE ? 20 : (isSmallDevice ? 28 : 36)) {
                            playbackControls
                        }
                        .padding(.horizontal, isSE ? 16 : (isSmallDevice ? 24 : 32))
                        .padding(.vertical, isSE ? 8 : (isSmallDevice ? 12 : 16))
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        
                        HStack(spacing: 12) {
                            auxiliaryControls
                        }
                        .scaleEffect(isSE ? 0.75 : (isSmallDevice ? 0.85 : 0.9))
                    }
                } else if !playback.isLyricsMode {
                    Spacer().frame(height: 120)
                }
            }
            .padding(.bottom, isSE ? 12 : (isIdle ? 60 : 32))
            
            if !playback.isLyricsMode {
                Spacer()
            }
        }
    }'''

new_layout = '''    private func portraitLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if !playback.isLyricsMode {
                Spacer()
            }
            
            VStack(spacing: UIScaler.scaleH(24)) {
                if playback.isLyricsMode {
                    inlineLyricsView
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height - headerHeight - UIScaler.scaleH(110))
                        .padding(.horizontal, UIScaler.scaleW(24))
                } else {
                    // Album Art
                    artworkSection(size: ScreenTier.isPhone ? min(proxy.size.width * 0.75, UIScaler.scaleW(320)) : tabletArtworkSize)
                        .padding(.bottom, UIScaler.scaleH(8))
                    
                    // Centered Metadata
                    VStack(alignment: .center, spacing: UIScaler.scaleH(4)) {
                        Text(playback.currentTrack?.title ?? "Not Playing")
                            .font(.system(size: UIScaler.scaleFont(24), weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.center)
                        
                        Text(playback.currentTrack?.artist ?? "Unknown Artist")
                            .font(.system(size: UIScaler.scaleFont(16), weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, UIScaler.scaleW(24))
                }
                
                // Progress Bar
                progressBar
                    .padding(.horizontal, UIScaler.scaleW(24))
                
                if !isIdle && !playback.isLyricsMode {
                    // Controls Section for Portrait
                    VStack(spacing: UIScaler.scaleH(20)) {
                        HStack(spacing: UIScaler.scaleW(32)) {
                            playbackControls
                        }
                        .padding(.horizontal, UIScaler.scaleW(28))
                        .padding(.vertical, UIScaler.scaleH(14))
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        
                        HStack(spacing: UIScaler.scaleW(12)) {
                            auxiliaryControls
                        }
                        .scaleEffect(ScreenTier.isPhone ? 0.9 : 1.0)
                    }
                } else if !playback.isLyricsMode {
                    Spacer().frame(height: UIScaler.scaleH(120))
                }
            }
            .padding(.bottom, UIScaler.scaleH(isIdle ? 60 : 32))
            
            if !playback.isLyricsMode {
                Spacer()
            }
        }
    }'''

if old_layout in content:
    content = content.replace(old_layout, new_layout)
    with open('Sources/App/NowPlayingView.swift', 'w', encoding='utf-8') as f:
        f.write(content)
    print("Successfully replaced layout!")
else:
    print("Could not find the target layout block. Something might be slightly different.")

