import SwiftUI
import UIKit

// MARK: - Micro-Mesh Texture Generator (iOS 15-17 Performance Engine)
// Produces 4x3 (landscape) or 3x3 (portrait) micro-textures that replicate
// iOS 18+ MeshGradient with zero continuous GPU compute.
@MainActor
public enum MicroMeshTextureGenerator {
    public static func createMeshTexture(colors: [UIColor], columns: Int, rows: Int) -> UIImage {
        let size = CGSize(width: columns, height: rows)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            for y in 0..<rows {
                for x in 0..<columns {
                    let index = y * columns + x
                    let color = colors.indices.contains(index) ? colors[index] : .black
                    color.setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }
}

// MARK: - Micro-Mesh Gradient View
// Provides a fluid, organic ambient mesh on iOS 15–17 devices (and iPhone SE)
// with zero runtime GPU overhead by animating opacity across pre-computed micro-textures.
public struct MicroMeshGradientView: View {
    public let colors: [UIColor]
    public let isLandscape: Bool

    @State private var phase = false
    @State private var phase1Texture: UIImage?
    @State private var phase2Texture: UIImage?

    public init(colors: [UIColor], isLandscape: Bool = false) {
        self.colors = colors
        self.isLandscape = isLandscape
    }

    private var resolvedColors: [UIColor] {
        let isAllBlack = colors.isEmpty || colors.allSatisfy {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            $0.getRed(&r, green: &g, blue: &b, alpha: &a)
            return r < 0.05 && g < 0.05 && b < 0.05
        }
        if isAllBlack {
            return [
                UIColor(red: 0.14, green: 0.10, blue: 0.24, alpha: 1.0),
                UIColor(red: 0.18, green: 0.08, blue: 0.22, alpha: 1.0),
                UIColor(red: 0.08, green: 0.14, blue: 0.24, alpha: 1.0),
                UIColor(red: 0.10, green: 0.08, blue: 0.16, alpha: 1.0),
                UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
            ]
        }
        return colors
    }

    private func generateGridColors(isPhaseTwo: Bool) -> [UIColor] {
        let cols = resolvedColors
        let a = cols.indices.contains(0) ? cols[0] : .black
        let b = cols.indices.contains(1) ? cols[1] : .black
        let c = cols.indices.contains(2) ? cols[2] : .black
        let d = cols.indices.contains(3) ? cols[3] : .black
        let e = cols.indices.contains(4) ? cols[4] : .black
        let dark = UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)

        if isLandscape {
            // 4x3 Widescreen Landscape Grid (12 points)
            // Left columns (0, 1) bloom beneath artwork; Right columns (2, 3) fade into dark obsidian
            return isPhaseTwo
                ? [b, a, e, dark,
                   a, e, c, dark,
                   dark, d, b, dark]
                : [a, b, c, dark,
                   b, a, e, dark,
                   dark, c, d, dark]
        } else {
            // 3x3 Portrait Grid (9 points) - exact parity with Apple Music ambient mesh look
            return isPhaseTwo
                ? [b, a, e,
                   dark, d, c,
                   dark, b, dark]
                : [a, b, dark,
                   c, e, d,
                   dark, d, dark]
        }
    }

    private func updateTextures() {
        let columns = isLandscape ? 4 : 3
        let rows = 3
        let grid1 = generateGridColors(isPhaseTwo: false)
        let grid2 = generateGridColors(isPhaseTwo: true)
        self.phase1Texture = MicroMeshTextureGenerator.createMeshTexture(colors: grid1, columns: columns, rows: rows)
        self.phase2Texture = MicroMeshTextureGenerator.createMeshTexture(colors: grid2, columns: columns, rows: rows)
    }

    public var body: some View {
        ZStack {
            if let tex1 = phase1Texture {
                Image(uiImage: tex1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: isLandscape ? 48 : 40)
                    .opacity(phase ? 0.0 : 1.0)
            }

            if let tex2 = phase2Texture {
                Image(uiImage: tex2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: isLandscape ? 48 : 40)
                    .opacity(phase ? 1.0 : 0.0)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            updateTextures()
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
        .onChange(of: colors) { _ in
            updateTextures()
        }
        .onChange(of: isLandscape) { _ in
            updateTextures()
        }
    }
}
