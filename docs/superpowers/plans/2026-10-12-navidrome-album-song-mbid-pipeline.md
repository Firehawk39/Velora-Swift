# Navidrome Album & Song Picard MBID Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fully utilize Navidrome's Subsonic API payload by decoding Picard-tagged MusicBrainz IDs (`musicBrainzId`), release types (`releaseTypes`), genres, and years for both Albums and Tracks, eliminating all remaining MusicBrainz release search queries and structuring discography display.

**Architecture:** 
1. Decode Navidrome's native `musicBrainzId`, `year`, `genre`, and `releaseTypes` on `SubsonicAlbum`, `SubsonicAlbumDetail`, and `SubsonicSong`.
2. Propagate these Picard fields into core `Album` and `Track` domain models across all `NavidromeClient` API endpoints (`getAlbumList2`, `getAlbum`, `getArtist`, `search3`).
3. Pass album Picard MBID directly into `MusicBrainzManager.downloadAlbumMetadataSilently` and `fetchAboutAlbum`, eliminating the rate-limited `musicbrainz.org/ws/2/release/?query=...` search bottleneck.
4. Categorize artist discography sections (Studio Albums, Singles & EPs, Compilations) using Picard's authoritative `releaseTypes`.

**Tech Stack:** Swift 6 Concurrency (`async/await`, `@MainActor`), SwiftUI, Subsonic REST API (v1.16.1+ OpenSubsonic).

## Global Constraints
- Preserve all existing initializers and compatibility defaults for `Album` and `Track`.
- Keep offline fallback caching functional in `DatabaseManager` and `LibraryDataCache`.
- Strictly avoid rate-limiting web queries when Picard MBIDs are present in Navidrome payloads.

---

### Task 1: Extend Subsonic Models and Domain Models with Picard Metadata
**Files:**
- Modify: `Sources/App/SubsonicModels.swift:68-147`
- Modify: `Sources/App/Common.swift:243-275`

**Interfaces:**
- Produces: `SubsonicAlbum.musicBrainzId`, `SubsonicAlbum.year`, `SubsonicAlbum.genre`, `SubsonicAlbum.releaseTypes`
- Produces: `SubsonicSong.musicBrainzId`, `SubsonicSong.year`, `SubsonicSong.genre`
- Produces: `Album.musicBrainzId`, `Album.year`, `Album.genre`, `Album.releaseTypes`
- Produces: `Track.musicBrainzId`, `Track.year`, `Track.genre`

- [x] **Step 1: Add Picard fields to `SubsonicAlbum`, `SubsonicAlbumDetail`, and `SubsonicSong` in `SubsonicModels.swift`**
- [x] **Step 2: Add Picard fields to `Album` and `Track` in `Common.swift` with default `nil` values**
- [x] **Step 3: Verify model decoding compatibility**

---

### Task 2: Map Picard Metadata Across All NavidromeClient Endpoints
**Files:**
- Modify: `Sources/App/NavidromeClient+API.swift:65-78` (`fetchAlbums`)
- Modify: `Sources/App/NavidromeClient+API.swift:170-185` (`fetchAlbumTracks`)
- Modify: `Sources/App/NavidromeClient+API.swift:234-247` (`fetchArtistData`)
- Modify: `Sources/App/NavidromeClient+API.swift:540-575` (`search3` paging)

**Interfaces:**
- Consumes: `SubsonicAlbum` and `SubsonicSong` fields from Task 1
- Produces: Populated `Album` and `Track` instances with Picard MBIDs, release types, and years

- [x] **Step 1: Map Picard metadata in `fetchAlbums` (getAlbumList)**
- [x] **Step 2: Map Picard metadata in `fetchAlbumTracks` (getAlbum)**
- [x] **Step 3: Map Picard metadata in `fetchArtistData` (getArtist)**
- [x] **Step 4: Map Picard metadata in search & pagination methods**

---

### Task 3: Upgrade Album Metadata Fetching to Direct Picard MBID
**Files:**
- Modify: `Sources/App/MusicBrainzManager.swift:314-350` (`fetchAboutAlbum`)
- Modify: `Sources/App/MusicBrainzManager.swift:590-630` (`downloadAlbumMetadataSilently`)
- Modify: `Sources/App/SyncManager.swift:1075-1085` (`processArtistItem`)
- Modify: `Sources/App/NowPlayingView.swift:965-970` (`loadArtistInfo`)

**Interfaces:**
- Consumes: `Album.musicBrainzId`
- Produces: Direct MBID query `https://musicbrainz.org/ws/2/release/<mbid>`, bypassing `resolveAlbumMBIDAsync`

- [x] **Step 1: Update `downloadAlbumMetadataSilently` in `MusicBrainzManager.swift` to accept `mbid: String? = nil`**
- [x] **Step 2: Pass `album.musicBrainzId` in `SyncManager.swift` when processing album metadata**
- [x] **Step 3: Resolve current track's album MBID in `NowPlayingView.swift` and pass to `fetchAboutAlbum`**

---

### Task 4: Categorize Artist Discography by Picard Release Types in UI
**Files:**
- Modify: `Sources/App/ArtistDetailView.swift:200-245`

**Interfaces:**
- Consumes: `Album.releaseTypes` and `Album.year`
- Produces: Clean discography grouping (Albums, EPs & Singles, Other Releases)

- [x] **Step 1: Add categorized discography computed sections in `ArtistDetailView.swift`**
- [x] **Step 2: Render sectioned headers if multiple release types are present**
