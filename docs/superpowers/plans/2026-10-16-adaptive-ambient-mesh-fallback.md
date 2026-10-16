# Adaptive Ambient Mesh Fallback (iPhone SE, Flagships & iPads) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the non-fanart fallback backdrop in `NowPlayingView` and `ArtistDetailView` across all device tiers (iPhone SE / low-power iOS 15–17, flagships, and iPads) to a fluid, widescreen-optimized ambient mesh gradient with zero runtime GPU overhead, while keeping the existing vignette overlay 100% untouched.

**Architecture:** 
- For iOS 15–17 (including iPhone SE): Replace the static `LinearGradient` fallback with a high-performance **Micro-Texture Mesh** (`4×3` in landscape, `3×3` in portrait). Generates two tiny offscreen pixel textures on track change and performs an 8-second breathing opacity crossfade via hardware compositing (0% continuous GPU math).
- For iOS 18+: Upgrade `AnimatedMeshGradientView` to adaptively use a `4×3` widescreen mesh in landscape (and `3×3` in portrait) for proper 16:9 aspect ratio geometry.
- Unify `NowPlayingView` and `ArtistDetailView` to route through `AlbumAmbientGradientView` across all device tiers, removing the legacy SE branch that locked small devices to plain vertical gradients.
- Keep the `.overlay` vignette (`RadialGradient` + `LinearGradient`) strictly intact.

**Tech Stack:** Swift, SwiftUI, UIKit (`UIGraphicsImageRenderer`), Core Animation.

**Spec:** User request to upgrade non-fanart fallback for both low-tier iPhones (iPhone SE) and high-tier iPhones/iPads, while never disturbing the existing vignette overlay.

## Global Constraints
- **Vignette Invariance:** The existing `.overlay(ZStack { RadialGradient(...); LinearGradient(...) })` in `NowPlayingView.swift` and `ArtistDetailView.swift` must remain completely untouched.
- **Platform Floors:** Must build and run cleanly on iOS 15.0+ without deprecation warnings or runtime crashes.
- **Zero Thermal Throttling on SE:** Background rendering below iOS 18 must use zero continuous shader math or moving gradient centers.
- **Orientation Awareness:** Landscape screens must use a `4×3` grid to match 16:9 widescreen geometry; portrait screens must use a `3×3` grid.

## Review Focus
1. Palette with all-black or near-black colors must gracefully fallback to deep ambient violet/plum defaults rather than rendering a blank black screen.
2. Rapid track skipping must not leak memory or queue stale texture renders.
3. Rotating between portrait and landscape must seamlessly adjust between `3×3` and `4×3` grid dimensions.
4. Existing controls, seekbar, lyrics, and auxiliary buttons must retain their exact current visibility, colors, and hit testing.
5. ArtistDetailView must share the identical ambient mesh styling without visual discrepancies.

---

### Task 1: Create the Micro-Texture Mesh Engine for iOS 15–17

**Files:**
- Create: `Sources/App/MicroMeshGradientView.swift`

**Interfaces:**
- Produces: `struct MicroMeshGradientView: View` accepting `colors: [UIColor]`, `isLandscape: Bool`.
- Produces: `enum MicroMeshTextureGenerator` with helper `func createMeshTexture(colors: [UIColor], columns: Int, rows: Int) -> UIImage`.

- [ ] **Step 1: Implement `MicroMeshTextureGenerator`**
Write a thread-safe helper using `UIGraphicsImageRenderer` to generate 4×3 and 3×3 pixel bitmaps from an array of colors:
```swift
enum MicroMeshTextureGenerator {
    static func createMeshTexture(colors: [UIColor], columns: Int, rows: Int) -> UIImage {
        let size = CGSize(width: columns, height: rows)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            for y in 0..<rows {
                for x in 0..<columns {
                    let index = (y * columns + x) % max(1, colors.count)
                    let color = colors.indices.contains(index) ? colors[index] : .black
                    color.setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }
}
```

- [ ] **Step 2: Implement `MicroMeshGradientView` in `Sources/App/MicroMeshGradientView.swift`**
Create the SwiftUI component that:
1. Detects `isLandscape` (columns: 4, rows: 3 for landscape; columns: 3, rows: 3 for portrait).
2. Generates Phase 1 and Phase 2 color maps:
   - Phase 1 distributes primary colors on the left (columns 0–1 in landscape), ambient bridge in center, and deep dark stops on the right.
   - Phase 2 shifts colors gently for the breathing effect.
3. Renders two stretched, blurred `Image` views in a `ZStack` and crossfades `opacity` between 0 and 1 over an 8-second repeating animation.

- [ ] **Step 3: Verification**
Verify syntax and compile safety for Swift 5 / Swift 6 and iOS 15.0 compatibility.

---

### Task 2: Upgrade `AnimatedMeshGradientView` for iOS 18+ to Support Widescreen 4×3

**Files:**
- Modify: `Sources/App/NowPlayingView.swift:1210-1246`

**Interfaces:**
- Consumes: `isLandscape: Bool`, `colors: [UIColor]`.
- Produces: Upgraded `AnimatedMeshGradientView` supporting 4×3 geometry in landscape and 3×3 in portrait.

- [ ] **Step 1: Add Landscape 4×3 Point Grid to `AnimatedMeshGradientView`**
In `Sources/App/NowPlayingView.swift`, update `AnimatedMeshGradientView` to take `isLandscape: Bool`:
- When `isLandscape` is true:
  - Width: 4, Height: 3 (12 points): `(0, 0), (0.33, 0), (0.66, 0), (1, 0), ...`
  - Colors are clustered with vibrant album tones on the left under the artwork and dark obsidian tones on the right under controls.
- When `isLandscape` is false:
  - Width: 3, Height: 3 (9 points) preserving standard portrait mesh.

- [ ] **Step 2: Update `AlbumAmbientGradientView` Dispatch**
In `AlbumAmbientGradientView`:
- If `#available(iOS 18.0, *)`: render `AnimatedMeshGradientView(colors: activeColors, isLandscape: isLandscape)`.
- Else (iOS 15–17, including iPhone SE): render `MicroMeshGradientView(colors: activeColors, isLandscape: isLandscape)`.

---

### Task 3: Unify Device Tier Routing in `NowPlayingView` and `ArtistDetailView`

**Files:**
- Modify: `Sources/App/NowPlayingView.swift:80-118`
- Modify: `Sources/App/ArtistDetailView.swift:608-624`

**Interfaces:**
- Consumes: `AlbumAmbientGradientView` across all device tiers.

- [ ] **Step 1: Update `NowPlayingView.swift` Portrait & Landscape Ambient Routing**
In `NowPlayingView.swift:82-98`, remove the legacy `if ScreenTier.isSE` branch that locked small devices to static `LinearGradient`. Route all non-fanart portrait backgrounds to `AlbumAmbientGradientView(colors: playback.currentPalette, isLandscape: false)`.
In `NowPlayingView.swift:104`, pass `isLandscape: isLandscape` to the base layer `AlbumAmbientGradientView`.
Confirm the `.overlay(...)` vignette remains completely untouched.

- [ ] **Step 2: Update `ArtistDetailView.swift` Fallback Gradient**
In `ArtistDetailView.swift:608-624`, replace the `if ScreenTier.isSE` branch with `AlbumAmbientGradientView(colors: artistPalette, isLandscape: isLandscape)`.
Confirm the `.overlay(...)` vignette remains completely untouched.

- [ ] **Step 3: Verification & Integrity Check**
Run git diff inspection to guarantee:
1. Vignette overlay code has zero line modifications.
2. Controls, sliders, and typography are untouched.
3. Low-tier devices (iPhone SE) receive the smooth MicroMeshGradient instead of raw linear gradients.
