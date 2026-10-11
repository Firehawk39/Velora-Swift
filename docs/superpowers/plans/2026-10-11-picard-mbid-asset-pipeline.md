# Picard MBID Asset Pipeline & TheAudioDB Backdrop Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify ClearLogo and Backdrop resolution across Fanart.tv and TheAudioDB using Picard-tagged MusicBrainz IDs directly from Navidrome, eliminating rate-limited MusicBrainz search calls, providing TheAudioDB backdrop fallbacks, and deterministically storing assets by MBID.

**Architecture:** 
1. Use Navidrome's `musicBrainzId` (guaranteed by Picard tagging) as the primary canonical key.
2. Structure TheAudioDB response parser to extract both `strArtistLogo` (ClearLogo) and `strArtistFanart` (Backdrop) in a single request.
3. Query Fanart.tv by MBID for curated backdrops; if unavailable or unconfigured, seamlessly fallback to TheAudioDB's fanart.
4. Cache assets deterministically under `{mbid}.jpg` and `logo_{mbid}.png` alongside sanitized name fallbacks.

**Tech Stack:** Swift 6 Concurrency (`async/await`, `@MainActor`, `URLSessionTask`), SwiftUI (`AsyncImage`, `@State`), Subsonic REST API.

---

### Task 1: Enhance TheAudioDB Fetcher to Return Both ClearLogo and Backdrops
- [x] Modify `fetchFromTheAudioDB` in `FanartManager.swift` to return a structured tuple: `(logoUrl: String?, backdropUrls: [String], resolvedMbid: String?, isTrueNotFound: Bool)`.
- [x] Parse `strArtistFanart`, `strArtistFanart2`, and `strArtistFanart3` from TheAudioDB JSON response.
- [x] Query `artist-mb.php?i=<mbid>` directly when MBID is present.

### Task 2: Implement TheAudioDB Backdrop Fallback in FanartManager
- [x] In `fetchBackdropRecursive` / `executeFanartQuery`, when Fanart.tv has no backdrop or Fanart is not configured, fallback to TheAudioDB's backdrop URLs.
- [x] In `downloadBackdropSilently`, check for TheAudioDB backdrop if Fanart returns empty or is not configured.
- [x] Save backdrops to `{mbid}.jpg` and `{key}.jpg`.

### Task 3: Unify ClearLogo & Backdrop MBID Caching and Deduplication
- [x] When TheAudioDB returns data, if a backdrop URL is found and no local backdrop exists, download it to `{mbid}.jpg`.
- [x] Ensure `hasCheckedBackdrop` and `hasBackdrop` check TheAudioDB negative cache markers as well.
- [x] Remove obsolete MusicBrainz search web service fallback (`musicbrainz.org/ws/2/artist`) when an authoritative Picard MBID is available.

### Task 4: Align SyncManager and NowPlayingView with Picard MBID
- [x] In `SyncManager.swift` (`processArtistItem`), ensure `safeMbid` from Navidrome is prioritized and passed to backdrop and clear logo silent downloads.
- [x] In `NowPlayingView.swift`, pass `safeMbid` to `fanart.fetchBackdrop` and `fanart.fetchClearLogo`.
- [x] Verify that `ArtistDetailView.swift` continues to resolve `{mbid}.jpg` with reactive state animation.
