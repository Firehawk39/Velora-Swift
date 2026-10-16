# iOS 15–17 & iPhone SE Micro-Texture Mesh Engine & 1080p TheAudioDB Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the high-performance Micro-Texture Mesh Engine exclusively for iOS 15–17 and iPhone SE devices (leaving iPads and iOS 18+ high-tier devices completely untouched), integrate the strict 1080p TheAudioDB backdrop fallback in FanartManager, verify single-tap clear logo toggling, and audit the status of the Local Streaming Acceleration pipeline.

**Architecture:** 
- Exclusively upgrade low-tier/legacy devices (iOS 15–17 & iPhone SE) from flat `LinearGradient` to `MicroMeshGradientView` which generates 3×3 (portrait) or 4×3 (landscape) micro-bitmaps via `UIGraphicsImageRenderer` with an 8s breathing crossfade and zero continuous GPU math. Keep iOS 18+ and iPad devices on their existing native `AnimatedMeshGradientView` (`MeshGradient`).
- Enhance `FanartManager` with strict 1080p resolution verification (`minResolution: CGSize(width: 1920, height: 1080)`) and seamless fallback to TheAudioDB when Fanart.tv lacks high-resolution backdrops before applying negative caching.
- Verify clear logo gesture in `NowPlayingView` remains single tap.

**Tech Stack:** Swift, SwiftUI, UIKit (`UIGraphicsImageRenderer`), Core Animation, URLSession.

**Spec:** User request to:
1. Implement Micro-Texture Mesh Engine for iOS 15–17 & iPhone SE only (no iPads or high-tier iOS 18+ affected).
2. Implement 1080p TheAudioDB Backdrop Fallback.
3. Ensure single tap clear logo change.
4. Report on status of Local Streaming Acceleration & Artwork Pipeline Plan.

## Global Constraints
- **Vignette Invariance:** The existing `.overlay(...)` radial and linear vignettes in `NowPlayingView.swift` and `ArtistDetailView.swift` must remain completely untouched.
- **High-Tier / iPad Invariance:** iPads and iOS 18+ modern iPhones must continue using native `AnimatedMeshGradientView` without regression or altered styling.
- **Zero Thermal Throttling on SE:** Micro-mesh textures must be generated once on track/palette change and animated purely via hardware opacity compositing.
- **Strict 1080p Floor for TheAudioDB:** Reject any backdrop below 1920×1080 to prevent low-resolution or blurry imagery on larger displays.
- **Swift 6 Concurrency:** Ensure `MicroMeshTextureGenerator` is isolated to `@MainActor` to prevent Sendable data races.

## Review Focus
1. Confirm that iOS 18+ devices and iPads do not display the micro-texture mesh and continue using native `AnimatedMeshGradientView`.
2. Confirm that when Fanart lacks backdrops, TheAudioDB is queried and candidates below 1080p (e.g. 1280x720) are rejected while 1920x1080+ are accepted.
3. Confirm that single tap on clear logo cycles the logo smoothly with spring feedback.
4. Confirm iPhone SE landscape does not render a gradient under active Fanart backdrops to prevent color washout.

---

### Task 1: Implement `MicroMeshGradientView` for iOS 15–17 & iPhone SE

**Files:**
- Create: `Sources/App/MicroMeshGradientView.swift`

**Interfaces:**
- Produces: `@MainActor enum MicroMeshTextureGenerator` with `createMeshTexture(colors: [UIColor], columns: Int, rows: Int) -> UIImage`.
- Produces: `struct MicroMeshGradientView: View` accepting `colors: [UIColor]`, `isLandscape: Bool`.

- [x] **Step 1: Create `Sources/App/MicroMeshGradientView.swift`**
  Implement `MicroMeshTextureGenerator` isolated to `@MainActor` generating tiny bitmap textures via `UIGraphicsImageRenderer`.
  Implement `MicroMeshGradientView` with:
  - 4×3 grid in landscape (vibrant tones under album art on left, obsidian tones on right).
  - 3×3 grid in portrait matching Apple Music ambient mesh distribution.
  - Phase 1 and Phase 2 textures crossfading opacity over 8 seconds.
  - All-black palette fallback to deep ambient violet/plum defaults.

- [x] **Step 2: Verification**
  Ensure clean compilation and strict actor isolation.

---

### Task 2: Wire Micro-Mesh Exclusively for iOS 15–17 & iPhone SE

**Files:**
- Modify: `Sources/App/NowPlayingView.swift`
- Modify: `Sources/App/ArtistDetailView.swift`

**Interfaces:**
- Consumes: `MicroMeshGradientView(colors:isLandscape:)`.

- [x] **Step 1: Update `AlbumAmbientGradientView` in `NowPlayingView.swift`**
  Add `var isLandscape: Bool = false` to `AlbumAmbientGradientView`.
  On iOS 18+, retain `AnimatedMeshGradientView(colors: activeColors)`.
  On iOS 15–17, replace static `LinearGradient` with `MicroMeshGradientView(colors: activeColors, isLandscape: isLandscape)`.

- [x] **Step 2: Update iPhone SE Portrait and Landscape in `NowPlayingView.swift`**
  In portrait (`NowPlayingView.swift:84-95`):
  - When `ScreenTier.isSE`, render `MicroMeshGradientView(colors: playback.currentPalette, isLandscape: false)` when artwork is loaded, else `Color.black`.
  In landscape (`NowPlayingView.swift:100-118`):
  - On iPhone SE: do not render gradient under active fanart; when no fanart exists, render `MicroMeshGradientView(colors: playback.currentPalette, isLandscape: true)`.
  - On iPads & modern iPhones: keep existing `AlbumAmbientGradientView` behavior untouched.

- [x] **Step 3: Update `ArtistDetailView.swift` Fallback Gradient**
  In `fallbackGradient(size:)`:
  - When `ScreenTier.isSE`, render `MicroMeshGradientView(colors: artistPalette, isLandscape: isLandscape)`.
  - When non-SE, keep existing `AlbumAmbientGradientView(colors: artistPalette, isLandscape: isLandscape)`.

---

### Task 3: Implement 1080p TheAudioDB Backdrop Fallback in `FanartManager.swift`

**Files:**
- Modify: `Sources/App/FanartManager.swift`

**Interfaces:**
- Consumes: `fetchFromTheAudioDB(artistName:mbid:priority:completion:)`.
- Produces: `tryDownloadTadb1080pBackdrop(...)`.

- [x] **Step 1: Add `minResolution` Parameter to `downloadAndCache`**
  In `downloadAndCache(from:to:primaryArtistName:cacheKey:mbid:minResolution:priority:completion:)`, check `image.size.width >= minRes.width && image.size.height >= minRes.height`. If not met, reject the image, log warning, and return nil.

- [x] **Step 2: Implement `tryDownloadTadb1080pBackdrop`**
  Recursively check backdrop candidates from TheAudioDB with `minResolution: CGSize(width: 1920, height: 1080)`. On success, cache to disk and return true.

- [x] **Step 3: Integrate into `executeFanartQuery` and `downloadBackdropSilently`**
  When Fanart.tv has no backdrop (or Fanart API key is missing), call `fetchFromTheAudioDB` and attempt downloading verified 1080p backdrops before negative caching.

---

### Task 4: Verify Single-Tap Clear Logo Gesture

**Files:**
- Inspect: `Sources/App/NowPlayingView.swift:458-463` and `949-954`

- [x] **Step 1: Verify Single-Tap Gesture**
  Ensure `.onTapGesture { cycleClearLogoAction() }` has no `count: 2` and uses single-tap toggle.

---

### Task 5: Document and Report Local Streaming Acceleration Pipeline Status

- [x] **Step 1: Assess and explain git history**
  Clarify that Local Streaming Acceleration was developed and tested yesterday in commits `e441ef3` / `0d026c1`, but rolled back during commit `30e42ad`. Present the option to restore it.
