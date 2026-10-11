# Navidrome Bulk Sync & Cloud Enrichment Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-architect Velora's sync pipelines into a clean two-tier model: (1) "Download All Music" becomes the comprehensive Navidrome LAN package (audio tracks, cover art, artist portraits, Picard tags, and local lyrics at unthrottled line-rate), and (2) "Download All Metadata" is stripped of Navidrome-specific fetches to focus exclusively on external cloud enrichment (Fanart.tv, TheAudioDB, MusicBrainz).

**Architecture:**
1. **Navidrome Pure Tier ("Download All Music"):** When triggered, `SyncManager.startMediaSync()` coordinates `PlaybackManager` to download all audio tracks, while concurrently pulling all album cover arts and artist portraits directly from Navidrome LAN unthrottled, including deduplicated artwork requests.
2. **Cloud Enrichment Tier ("Download All Metadata"):** Rename the button in `SettingsView.swift` to "Download All Metadata" and strip out `client.downloadArtistPortrait` and `client.downloadCoverArt` from `SyncManager.processArtistItem` / `processAlbumItem`, reserving this pass strictly for Fanart.tv backdrops & ClearLogos, TheAudioDB, and MusicBrainz bios.
3. **Download Engine Optimization:** Offload `extractEmbeddedArtwork` from `@MainActor` to a background detached task, add thread-safe in-flight deduplication to `NavidromeClient.downloadCoverArt`, and throttle `PlaybackManager.didWriteData` progress dispatching to 10Hz to eliminate UI micro-stutters.

**Tech Stack:** Swift 6 Concurrency (`async/await`, `withTaskGroup`, `@MainActor`), `URLSessionDownloadTask`, SwiftUI, Subsonic REST API.

**Spec:** User request to consolidate all Navidrome-related asset downloads (audio, portraits, covers) into "Download All Music", rename the first button to "Download All Metadata" with all Navidrome fetches stripped out, and maintain the 3-button layout in Settings.

## Global Constraints
- Keep all three buttons in `SettingsView.swift` (`Download All Metadata`, `Download All Lyrics`, `Download All Music`).
- Preserve all existing offline cache paths in `VeloraStorage` (`VeloraStorage.tracks`, `VeloraStorage.coverArt`, `VeloraStorage.artistPortraits`, `VeloraStorage.backdrops`, `VeloraStorage.clearLogos`).
- Do not block the MainActor during bulk downloads; ensure UI remains fluid at 60/120 FPS.
- Retain external API rate-limiting protections in `ThrottledNetworkManager` (1 req/sec for MusicBrainz, Fanart.tv, TheAudioDB).

## Review Focus
1. In-flight cover art download deduplication must safely execute all registered completion handlers upon completion or failure.
2. Background `extractEmbeddedArtwork` must not cause race conditions with NowPlaying updates if the currently playing track finishes downloading.
3. Bulk music sync must not stall if an individual portrait or cover art download fails on Navidrome.
4. "Download All Metadata" must skip artists that already have cloud backdrops and clear logos cached.
5. All three buttons in Settings must reflect accurate real-time completion state (`checkmark.circle.fill`).

---

### Task 1: Add In-Flight Deduplication and Background Artwork Extraction in Download Engine
**Files:**
- Modify: `Sources/App/NavidromeClient+API.swift:640-685`
- Modify: `Sources/App/PlaybackManager.swift:1148-1240`

**Interfaces:**
- Produces: Thread-safe in-flight request coalescing for `downloadCoverArt(id:completion:)`.
- Produces: Detached background execution for `extractEmbeddedArtwork` without MainActor blocking.
- Produces: 10Hz-throttled progress updates in `urlSession(_:downloadTask:didWriteData:...)`.

- [x] **Step 1: Implement `inFlightCovers` deduplication in `NavidromeClient+API.swift`**
  - Add thread-safe tracking (`NSLock` + `[String: [@Sendable (Bool) -> Void]]`) so concurrent calls for the same cover art share a single network task.
- [x] **Step 2: Throttle `didWriteData` in `PlaybackManager.swift`**
  - Track `lastProgressDispatch: [String: Date]` and only dispatch to `@MainActor` if >= 100ms has elapsed since the last update for that track, or if progress reaches 1.0.
- [x] **Step 3: Move `extractEmbeddedArtwork` to `Task.detached` in `PlaybackManager.swift`**
  - Offload AVAsset container parsing and image decoding to `.utility` QoS, with an immediate MainActor callback to `updateNowPlayingInfo()` if `currentTrack?.id == trackId`.

---

### Task 2: Consolidate Navidrome LAN Media, Covers, and Portraits into "Download All Music"
**Files:**
- Modify: `Sources/App/SyncManager.swift:530-610`

**Interfaces:**
- Consumes: `client.downloadCoverArt`, `client.downloadArtistPortrait`, `playback.downloadTrack`
- Produces: Unified Navidrome LAN download batch in `SyncManager.startMediaSync()` that caches audio tracks, all unique album covers, and all artist portraits concurrently.

- [x] **Step 1: Enqueue all unique album cover arts and artist portraits during `startMediaSync`**
  - Before starting the monitor loop, extract unique album cover IDs and artist IDs from `tracksToDownload`.
  - Concurrently trigger `client.downloadCoverArt(id:)` and `client.downloadArtistPortrait(id:)` for any missing covers/portraits.
- [x] **Step 2: Update status message to reflect unified download package**
  - Set status to `"Downloading music & local media..."` during active transfers, and `"All tracks, covers & portraits offline"` on completion.

---

### Task 3: Strip Navidrome Fetches from Metadata Sync and Restructure for Cloud Enrichment
**Files:**
- Modify: `Sources/App/SyncManager.swift:180-230`
- Modify: `Sources/App/SyncManager.swift:1040-1082`

**Interfaces:**
- Consumes: `FanartManager.downloadBackdropSilently`, `FanartManager.downloadClearLogoSilently`, `MusicBrainzManager.downloadMetadataSilently`
- Produces: Cloud-only metadata sync pipeline that skips local Navidrome portrait/cover fetches and focuses strictly on external backdrops, clear logos, and web biographies.

- [x] **Step 1: Strip `client.downloadArtistPortrait` from `processArtistItem` in `SyncManager.swift`**
  - Remove portrait download from metadata sync since it is now owned by Tier 1.
- [x] **Step 2: Strip `client.downloadCoverArt` from `processAlbumItem` in `SyncManager.swift`**
  - Remove cover art check and download from metadata sync since it is now owned by Tier 1.
- [x] **Step 3: Adjust `metadataStatus` copy**
  - Update progress descriptions to `"Enriching Cloud Fanart: X/Y artists"` and completion to `"Cloud Fanart & Web Metadata Complete"`.

---

### Task 4: Update Settings UI Labels and Descriptions
**Files:**
- Modify: `Sources/App/SettingsView.swift:648-698`
- Modify: `Sources/App/SettingsView.swift:753-800`

**Interfaces:**
- Produces: Renamed button "Download All Metadata" with description "Cloud backdrops, logos, and web bios (Fanart.tv / TheAudioDB)".
- Produces: Updated "Download All Music" button description "Save all tracks, covers, and portraits offline (Navidrome)".

- [x] **Step 1: Rename "Download Library Metadata" to "Download All Metadata"**
  - Update button title in `SettingsView.swift:666`.
  - Update subtitle to `"Cloud backdrops, clear logos, and web bios"` in `SettingsView.swift:670`.
- [x] **Step 2: Update "Download All Music" subtitle in `SettingsView.swift`**
  - Update subtitle to `"Save all tracks, covers, and portraits offline (Navidrome)"` in `SettingsView.swift:775`.

---

### Task 5: Verification & End-to-End Validation
**Files:**
- Verify: `Sources/App/PlaybackManager.swift`
- Verify: `Sources/App/SyncManager.swift`
- Verify: `Sources/App/SettingsView.swift`
- Verify: `Sources/App/NavidromeClient+API.swift`

- [x] **Step 1: Run Swift compilation check / build verification**
- [x] **Step 2: Verify MCP server endpoints and status response from live app**
- [x] **Step 3: Validate that no actor isolation errors or compiler warnings are introduced**
