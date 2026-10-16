# Local Streaming Acceleration & Artwork Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide an instantaneous, offline-grade local streaming experience without requiring full audio file downloads, eliminating album art loading lag and preventing network contention on track skip.

**Architecture:** Introduce a unified, thread-safe `CoverArtManager` combining an in-memory `NSCache`, request deduplication, and automatic disk persistence in `VeloraStorage.coverArt`. Hook into `PlaybackManager` to look ahead and pre-cache cover art thumbnails for the next 5 queued tracks, and briefly yield heavy background audio prefetching for 1.5s when a new stream starts.

**Tech Stack:** Swift, SwiftUI, Foundation, URLSession, NSCache, Combine.

---

## Global Constraints

- Never break or modify offline playback storage (`VeloraStorage.tracks` and `VeloraStorage.coverArt`).
- Never cancel background downloads; only yield audio prefetching temporarily during active track transitions.
- Maintain zero-lag UI responsiveness on low-tier devices (iPhone SE).
- Preserve existing vignette overlays and backdrop fallbacks without regressions.

---

## Tasks

### Task 1: Create Unified `CoverArtManager`

**Files:**
- Create: `Sources/App/CoverArtManager.swift`

- [ ] **Step 1: Define `CoverArtManager` actor/singleton**
  Implement an in-memory `NSCache<NSString, UIImage>` with count limit (100) and cost limit (50MB).
  Implement in-flight task deduplication (`[String: Task<UIImage?, Never>]`).

- [ ] **Step 2: Implement `loadArtwork(url:artId:)`**
  1. Check in-memory `NSCache` (0ms return).
  2. Check local disk `VeloraStorage.coverArt/\(artId).jpg` (0ms return, populate memory cache).
  3. If not cached, fetch via dedicated `URLSession` data task with `.userInteractive` priority.
  4. Write successfully fetched image data atomically to `VeloraStorage.coverArt/\(artId).jpg`.
  5. Store in memory cache and return.

- [ ] **Step 3: Implement Queue Lookahead `preloadArtwork(for:count:)`**
  Takes an array of `Track` objects (e.g. queue), slices the next 5 items, and asynchronously fetches their 500px cover art thumbnails in the background if not already cached.

---

### Task 2: Integrate `CoverArtManager` into `SelfHealingAsyncImage`

**Files:**
- Modify: `Sources/App/Components.swift:68-120`

- [ ] **Step 1: Update `SelfHealingAsyncImage`**
  Check `CoverArtManager.shared` before falling back to network `AsyncImage`.
  If memory or disk cache hits, render immediately with `Image(uiImage:)` in 0ms without showing placeholders.
  On network fetch completion, ensure the image is cached to disk so future renders are instantaneous.

---

### Task 3: Queue Lookahead & Bandwidth Prioritization in `PlaybackManager`

**Files:**
- Modify: `Sources/App/PlaybackManager.swift`

- [ ] **Step 1: Hook Queue Lookahead Prefetching**
  When `playTrack(at:in:)` or `queue` updates, call `CoverArtManager.shared.preloadArtwork(for: upcomingTracks)`.

- [ ] **Step 2: Yield Background Audio Prefetching on Stream Start**
  In `playTrack`, delay `prefetchNextTracks()` by 1.5 seconds using a cancellable task so the active stream and cover art receive 100% of local server connection bandwidth.

- [ ] **Step 3: Use `CoverArtManager` in `applyArtwork`**
  In `updateNowPlayingInfo()`, use `CoverArtManager` to resolve artwork instead of running a duplicate uncoordinated `URLSession.shared.dataTask`.

---

### Task 4: Verification and CI Build

- [ ] **Step 1: Verify git status and stage changes**
- [ ] **Step 2: Commit and push to master**
- [ ] **Step 3: Monitor Bitrise CI build to ensure green status**
- [ ] **Step 4: Verify live status and logs via Velora MCP on iPhone SE**
