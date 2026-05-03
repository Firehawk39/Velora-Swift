# Velora AI Studio — Development Log

> Living document tracking all architectural decisions, changes, and session history.
> Updated by Antigravity AI assistant across sessions.

---

## Project Overview

| Key | Value |
|---|---|
| **Project** | Velora AI Studio — Music streaming client |
| **Backend** | Navidrome (Subsonic REST API) |
| **Web Stack** | React + Vite + TypeScript |
| **Native Stack** | SwiftUI (iOS 15+) |
| **Target Devices** | iPad Pro M1 12.9", iPhone SE 1st Gen |
| **Server** | `http://192.168.1.13:4533` |
| **API User** | `tony` |

---

## Session History

### Session 1 — Performance Optimization (2026-04-23)
**Conversation:** `fe239c0d-62ef-45ea-abae-a070ff945cd9`

**Goal:** Maximize performance on iPhone SE (1st Gen) via the web app.

**Changes Made:**
- Purged GPU-heavy blur effects from non-essential views
- Replaced CSS blurs with lightweight vignette overlays
- Implemented lazy-loading for media assets (album art)
- Optimized DOM node management for scroll performance
- Stabilized Navidrome API data synchronization

**Key Decisions:**
- Gate high-GPU effects (blur, saturate) to specific viewport modes only
- iPhone SE (1st Gen) is the performance floor — all features must run smoothly on A9 / 2GB RAM
- Use `transform-gpu` CSS hints for compositor-layer promotion

---

### Session 2 — Navidrome Integration & UI Fixes (2026-04-25)
**Conversation:** `3f98037e-8515-4746-a8e3-b7a1d0bb2a3a`

**Goal:** Fix Library Overview, restore mobile portrait gradient, implement Albums view.

#### Changes Made:

##### 1. Library Overview Stats — `useLibraryStats` fix
**File:** `src/hooks/useNavidrome.ts` (lines 465-490)

**Problem:** The `useLibraryStats` hook was fetching `getAlbumList2` with `size: 1` and setting `songCount: 0` — meaning the Library Insights section always showed 0 tracks.

**Fix:** Changed to fetch with `size: 5000` and dynamically calculate total song count by summing `album.songCount` across all albums. Now accurately reports total tracks, albums, and artists.

```diff
- subsonic('getAlbumList2', { type: 'alphabeticalByName', size: 1 }),
+ subsonic('getAlbumList2', { type: 'newest', size: 5000 }),
```
```diff
- const albumCount = albumRes.albumList2?.album?.length ?? 0;
- setStats({ songCount: 0, albumCount, artistCount });
+ const albums = albumRes.albumList2?.album || [];
+ const albumCount = albums.length;
+ let songCount = 0;
+ for (const a of albums) { songCount += (a.songCount || 0); }
+ setStats({ songCount, albumCount, artistCount });
```

##### 2. Albums View — Full Implementation
**Files:** `src/hooks/useNavidrome.ts`, `src/components/LibraryView.tsx`

**Problem:** Clicking "Albums" in Library showed "Work in progress" placeholder.

**Fix:**
- Added `getAlbumTracks()` async function to `useNavidrome.ts` — fetches all songs for a given album ID
- Added `useAlbums` hook + `isPlayingAlbum` state to `LibraryView.tsx`
- Implemented full Albums grid UI with cover art, play-on-click, loading spinner
- Albums now play their full tracklist when clicked

##### 3. Mobile Portrait Dynamic Background — Architecture Change
**Files:** `src/App.tsx`, `src/components/NowPlayingView.tsx`

**Problem:** The mobile portrait dynamic gradient (blurred album art background) was previously moved INTO `NowPlayingView.tsx` for component encapsulation. But this caused it to be trapped inside the view's padding, not covering the header or bottom nav.

**Fix:**
- Removed the mobile portrait background from `NowPlayingView.tsx`
- Restored it in `App.tsx` inside the `AnimatePresence` block at z-index 0
- Now the gradient covers the ENTIRE screen (behind header and bottom nav) in mobile portrait mode
- Other modes (desktop, tablet, landscape) continue using the cinematic backdrop image

**Before (broken):**
```
App.tsx → mobile portrait → null (no background)
NowPlayingView.tsx → renders its own background (trapped in container padding)
```

**After (fixed):**
```
App.tsx → mobile portrait → blurred album art + gradient overlay (full screen)
NowPlayingView.tsx → no background (transparent, inherits from App.tsx)
```

##### 4. Credentials Verification
**File:** `src/hooks/useNavidrome.ts` (lines 5-7)

Confirmed credentials are unchanged and correct:
- Server: `http://192.168.1.13:4533` (with `localStorage` override support)
- Username: `tony` (via `VITE_NAVIDROME_USER` or fallback)
- Password: `u4vTyG7BcBxR-9-` (via `VITE_NAVIDROME_PASS` or fallback)

No changes were made to credentials in this session.

##### 5. Library Item Count Limits
**File:** `src/components/LibraryView.tsx` (lines 30, 33)

**Problem:** The "Songs" and "Albums" views in the Library were limited to fetching only 50 items. This made larger libraries look incomplete compared to the server dashboard.

**Fix:** Increased limits in `useAllSongs(50)` and `useAlbums(..., 50)` to `5000`.

*   **Navigation & Overlays**: The "Menu Pill" (in `ContentView` / `AppHeader`) still requires styling attention for light mode parity. The user specifically requested a background-fill/subtle treatment similar to the provided reference image.

#### 4. UI Refinement Session (Latest Updates)
*   **Tablet Landscape Layout (`NowPlayingView`)**: Refactored the `tabletLayout` from a centered vertical stack to a proper side-by-side layout (artwork on the left, metadata and controls on the right). This aligns with the provided reference and standard car infotainment interfaces.
*   **Menu Pill Light Mode (`Components.swift`)**: Updated the global `navigationPill` background to use a solid `#e5e7eb` grey fill in light mode, and active tabs to pure white with a subtle shadow for accurate contrast parity.
*   **Queue & Lyrics Dark Mode**: Forced `QueuePanel` and `lyricsView` backgrounds to always evaluate to `.dark` color palettes regardless of the app's global theme preference.
*   **Artist Detail Spacing**: Increased the top padding in `ArtistDetailView` to comfortably clear the floating menu pill.

---

## SwiftUI Native Port — Planning (2026-04-25)

### Decision: Target Devices
- **iPad Pro M1 12.9"** — primary large-screen target
- **iPhone SE 1st Gen** — minimum viable device (4" screen, A9, 2GB RAM, iOS 15 max)

### Decision: Minimum iOS Version → iOS 15
The iPhone SE 1st Gen maxes out at iOS 15.8. This constrains all API choices:

| Allowed (iOS 15) | Blocked (iOS 16+) |
|---|---|
| `NavigationView` | ~~`NavigationStack`~~ |
| `@ObservableObject` / `@StateObject` | ~~`@Observable` macro~~ |
| `AsyncImage` | ~~`ContentUnavailableView`~~ |
| `.task {}` modifier | ~~`.scrollTargetBehavior`~~ |
| `Combine` publishers | ~~`@Bindable`~~ |

### Decision: Responsive Layout Strategy
| Context | Width | Layout |
|---|---|---|
| iPhone SE Portrait | 320pt | `TabView` bottom tabs, single-column, 2-col grids |
| iPhone SE Landscape | 568pt | `TabView`, two-column where possible |
| iPad Pro Portrait | 1024pt | Top nav pills (React desktop style), 4-5 col grids |
| iPad Pro Landscape | 1366pt | Full cinematic layout, sidebar possible |

Detection: `@Environment(\.horizontalSizeClass)` — `.compact` = iPhone, `.regular` = iPad.

### Existing SwiftUI Scaffold (7 files)
Located in `SwiftProject/`. Status as of 2026-04-25:

| File | Lines | Status |
|---|---|---|
| `Common.swift` | 54 | ✅ Models + auth helpers. Missing Playlist/SearchResult types |
| `NavidromeClient.swift` | 93 | ⚠️ Returns hardcoded dummy data, no real API decoding |
| `PlaybackManager.swift` | 100 | ⚠️ Basic AVPlayer, no queue/seek/scrobble/background audio |
| `ContentView.swift` | 170 | ⚠️ Forces landscape only, creates 2 separate NavidromeClient instances (bug) |
| `HomeView.swift` | 203 | ⚠️ Hardcoded spotlight ("Actual Life 3"), placeholder data |
| `LibraryView.swift` | 136 | ⚠️ Album grid only, no categories/stats/songs/artists/playlists |
| `NowPlayingView.swift` | 224 | ⚠️ Static progress "1:24 / 3:58", no seek, no real wiring |

### Planned New Files
| File | Purpose |
|---|---|
| `VeloraApp.swift` | `@main` entry, AVAudioSession config, environment injection |
| `SettingsView.swift` | Server URL/credentials, connection test |
| `SearchView.swift` | Debounced search with grouped results |
| `ArtistDetailView.swift` | Artist bio + top songs + albums |

### Identified Polish Items (Phase 6)
Items acknowledged but deferred to after core functionality works:

1. **Image Caching** — `AsyncImage` has no disk cache. Need `NSCache` + `FileManager` wrapper to avoid memory pressure on iPhone SE
2. **Offline Resilience** — Error states, retry logic, cached-last-known-data when server unreachable
3. **Accessibility** — VoiceOver labels, Dynamic Type, reduced motion
4. **Haptic Feedback** — `UIImpactFeedbackGenerator` on play/pause/skip
5. **Combine/Reactive Layer** — Publishers for auto-refetching data
6. **Testability** — `protocol SubsonicService` abstraction for mocking
7. **Performance Tier Detection** — `ProcessInfo.processInfo.physicalMemory` to gate effects
8. **`ViewState<T>` Enum** — `case loading, loaded(T), error(Error)` for all data views

---

## Architecture Reference

### React App File Map
```
src/
├── App.tsx                    — Root shell, playback state, routing, viewport management
├── hooks/
│   └── useNavidrome.ts        — All Subsonic API hooks + helpers (697 lines)
└── components/
    ├── Header.tsx             — Nav pills, dark mode toggle, profile menu
    ├── HomeView.tsx           — Recently played, starred, spotlight
    ├── LibraryView.tsx        — Category menu + 4 sub-views + stats
    ├── SearchView.tsx         — Search bar + grouped results
    ├── NowPlayingView.tsx     — Full player with lyrics/queue modes
    ├── ArtistDetailView.tsx   — Artist bio, top songs, albums
    └── SettingsView.tsx       — Server connection, settings sections
```

### Subsonic API Endpoints Used
| Endpoint | React Hook/Function | Purpose |
|---|---|---|
| `getAlbumList2` | `useAlbums`, `useRecentSongs`, `useLibraryStats` | Album lists |
| `getAlbum` | `useAlbumSongs`, `getAlbumTracks` | Album tracks |
| `getArtists` | `useArtists`, `useLibraryStats` | Artist index |
| `getArtistInfo2` | `useTrackDetails`, `useArtistDetail` | Artist bio/image |
| `getTopSongs` | `useArtistTopSongs` | Artist top tracks |
| `getAlbumInfo` | `useTrackDetails` | Album notes |
| `getRandomSongs` | `useAllSongs` | Random tracks |
| `getStarred` | `useStarredSongs` | Starred content |
| `getPlaylists` | `usePlaylists`, `getPlaylists` | Playlist list |
| `getPlaylist` | `getPlaylistTracks` | Playlist tracks |
| `search3` | `useSearch` | Global search |
| `stream` | `getStreamUrl` | Audio streaming |
| `getCoverArt` | `getCoverUrl` | Album/track art |
| `scrobble` | `scrobble()` | Play tracking |
| `star` / `unstar` | `toggleStar()` | Favorites |
| `setRating` | `setRating()` | Track rating |

---

### Session 3 — UI Polish & API Resilience (2026-04-29)
**Conversation:** `9fd00c07-37ea-4454-bb99-e54d8314d453`

**Goal:** Refactor Artist Detail layout constraints, fix overlapping overlays, scale typography for iPad screens, restore ambient hero glow, and automate global default connections.

**Changes Made:**
- Handled geometry collisions in `ArtistDetailView.swift` (iPad top bounds moved down).
- Reintroduced card grids for the "Most Favourite" track modules.
- Mapped radial color masks behind hero image slots.
- Configured active `.env` proxies.

---

## Conventions

- **This file is updated every session** with changes made
- Each session gets a dated header with conversation ID
- Architectural decisions are documented with rationale
- Breaking changes are called out explicitly
- File paths are relative to project root unless noted

