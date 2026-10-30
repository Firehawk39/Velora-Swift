# Lyrics Time-Sync and Picard-Aware Resolution Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix lyrics time-synchronization and resolve missing lyrics in Velora without altering the existing UI/UX.

**Architecture:** 
1. A standard-compliant, universal LRC parser supporting all timestamp variants, multi-timestamp lines, and instrumental gaps.
2. A Picard-aware multi-tier network engine (Navidrome OpenSubsonic $\to$ Exact Picard LRCLIB $\to$ Decomposed Collaboration LRCLIB $\to$ NetEase Fallback) with strict cache poisoning protection.
3. Audio clock hardening in `PlaybackManager` to ensure streaming progress never stalls and timestamps never bleed across tracks.

**Tech Stack:** Swift 6, AVFoundation, OpenSubsonic / Navidrome, LRCLIB REST API, NetEase Public Lyric API.

## Global Constraints

- **STRICT UI/UX PRESERVATION:** Zero modifications to the visual design, view hierarchy, fonts, layout, or animations of `NowPlayingView.swift` / `LyricLineView`.
- **MusicBrainz Picard Standard:** Treat Picard metadata tags as canonical truth while normalizing collaboration syntax (`feat.`, `featuring`, `&`) for community databases.
- **0ms Main-Thread Guarantee:** Zero synchronous disk reads or network calls during layout passes.
- **Swift 6 Strict Concurrency:** Full concurrency safety (`Sendable`, `@MainActor`, zero data races).
- **Commit Protocol:** Commit and push to `origin/master` upon verification.

## Review Focus

1. **Timestamp format variation:** Files using `[mm:ss]` or `[mm:ss:xx]` must not be rejected as plain text.
2. **Stream buffer stalls:** HTTP audio streams where `AVPlayerItem.duration` is indefinite during warmup must continue updating `playback.progress` using `track.duration`.
3. **Transient network errors:** HTTP 503 or 429 from LRCLIB must never write `NO_LYRICS` or plain-text fallbacks to disk.
4. **Song intro silence:** Active index before the first timestamp ($t < t_{\text{first}}$) must not highlight line 0.
5. **Track transitions:** `currentSyncedLyrics` must be cleared immediately when a new track is queued.

---

### Task 1: Standard-Compliant Universal LRC Parser

**Files:**
- Modify: `Sources/App/PlaybackManager.swift:1060-1123`

- [ ] **Step 1.1: Replace strict regex with universal timestamp parser**
  Update `lrcTimestampRegex` and parsing logic to accept:
  - `\[\d+:\d+\.\d+\]` (standard `[mm:ss.xx]`)
  - `\[\d+:\d+:\d+\]` (colon hundredths `[mm:ss:xx]`)
  - `\[\d+:\d+\]` (integer seconds `[mm:ss]`)
- [ ] **Step 1.2: Support multi-timestamp repeating lines**
  Parse lines with multiple timestamp brackets (e.g. `[00:15.20][01:25.40] Chorus`) so all instances are registered at their respective times.
- [ ] **Step 1.3: Support instrumental cues**
  Allow empty timestamped lines (e.g. `[02:15.00]`) to clear or advance the active lyric during extended solos rather than freezing on the previous line.
- [ ] **Step 1.4: Support global `[offset:±ms]` header**
  If present, apply the millisecond offset across all parsed line timestamps.

---

### Task 2: Picard-Aware Multi-Tier Resolver & Cache Protection

**Files:**
- Modify: `Sources/App/NavidromeClient+API.swift:817-1000`

- [ ] **Step 2.1: Pass `album` parameter into lyrics lookup**
  Update `fetchLyrics(...)` and `performLRCLIBRequest(...)` to accept and send `track.album` as `album_name` in `/api/get` requests.
- [ ] **Step 2.2: Implement Picard collaboration decomposition**
  If exact Picard query fails:
  - Extract primary artist (e.g. `Chase & Status feat. Takura` $\to$ `Chase & Status`).
  - Strip release modifiers from title (e.g. `(Robin Schulz edit)` $\to$ `A Sky Full of Stars`).
  - Query LRCLIB with decomposed artist and cleaned title.
- [ ] **Step 2.3: Implement duration-tolerant candidate search**
  If `/api/get` 404s, query `/api/search` and select the candidate within $\pm 4.0\text{s}$ of the local track duration (rejecting candidates outside this window).
- [ ] **Step 2.4: Integrate NetEase secondary fallback**
  If LRCLIB returns `503 Server Overloaded` or has no match, query NetEase’s public lyrics endpoint (`https://music.163.com/api/search/get` and `https://music.163.com/api/song/lyric`) using canonical Picard title and primary artist.
- [ ] **Step 2.5: Prevent cache poisoning & handle verified instrumentals**
  - Never write `"NO_LYRICS"` or unsynced Navidrome text to disk on `503`, `429`, or timeouts.
  - Keep unsynced lyrics in memory for the current session only.
  - When LRCLIB returns `"instrumental": true`, write `"INSTRUMENTAL"` to disk.
  - If cached lyrics contain `"INSTRUMENTAL"`, render `• • •` in `NowPlayingView.swift` (matching existing font and placement).
  - Add self-healing check: if cached file contains old `"NO_LYRICS"` or plain text, trigger background re-check.

---

### Task 3: Playback Clock & Observer Hardening

**Files:**
- Modify: `Sources/App/PlaybackManager.swift:475-500`
- Modify: `Sources/App/PlaybackManager.swift:590-605`
- Modify: `Sources/App/NowPlayingView.swift:948-950`

- [ ] **Step 3.1: Fix indefinite duration guard in time observer**
  In `timeObserver` (`PlaybackManager.swift`), fallback to `Double(self.currentTrack?.duration ?? 0)` if `item.duration.isNumeric` is false, ensuring `self.progress` advances during HTTP stream playback.
- [ ] **Step 3.2: Immediate state reset on track change**
  In `playTrack()`, immediately set `self.currentSyncedLyrics = nil` alongside `self.currentLyrics = nil` so old timestamps never render against new audio.
- [ ] **Step 3.3: Pre-vocal intro protection**
  In `NowPlayingView.swift#L949`, update `activeIndex` calculation: if `playback.progress` is less than the first line's timestamp, set `activeIndex = -1` (no line active), eliminating the premature line 0 highlight.

---

### Task 4: Verification & Git Push

- [ ] **Step 4.1: Run local Swift build / verification check**
  Ensure zero compiler warnings and zero errors under Swift 6 strict concurrency.
- [ ] **Step 4.2: Verify against live Navidrome tracks**
  Test both embedded synced tracks (`Charli xcx - Girl, so confusing`) and unsynced/LRCLIB tracks (`Coldplay`, `Chase & Status`).
- [ ] **Step 4.3: Commit and push to origin/master**

