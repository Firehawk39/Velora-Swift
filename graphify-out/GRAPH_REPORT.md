# Graph Report - Velora AI Studio + Antigravity  (2026-04-28)

## Corpus Check
- 35 files · ~29,598 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 247 nodes · 393 edges · 12 communities detected
- Extraction: 82% EXTRACTED · 18% INFERRED · 0% AMBIGUOUS · INFERRED: 70 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 13|Community 13]]

## God Nodes (most connected - your core abstractions)
1. `NavidromeClient` - 18 edges
2. `PlaybackManager` - 13 edges
3. `Track` - 10 edges
4. `error` - 10 edges
5. `subsonic()` - 8 edges
6. `NavidromeClient` - 8 edges
7. `NowPlayingView` - 7 edges
8. `buildUrl()` - 6 edges
9. `ArtistDetailView` - 6 edges
10. `Album` - 6 edges

## Surprising Connections (you probably didn't know these)
- `getAlbumTracks()` --calls--> `error`  [INFERRED]
  src\hooks\useNavidrome.ts → Velora.swiftpm\Sources\App\SettingsView.swift
- `getPlaylistTracks()` --calls--> `error`  [INFERRED]
  src\hooks\useNavidrome.ts → Velora.swiftpm\Sources\App\SettingsView.swift
- `testFrequent()` --calls--> `error`  [INFERRED]
  scratch\test_frequent.js → Velora.swiftpm\Sources\App\SettingsView.swift
- `testHistory()` --calls--> `error`  [INFERRED]
  scratch\test_history.js → Velora.swiftpm\Sources\App\SettingsView.swift
- `testNP()` --calls--> `error`  [INFERRED]
  scratch\test_np.js → Velora.swiftpm\Sources\App\SettingsView.swift

## Communities

### Community 0 - "Community 0"
Cohesion: 0.08
Nodes (35): AppHeader, ProfileDropdown, QueuePanel, QueueRow, TabButton, ToggleButton, AlbumCard, ArtistCircle (+27 more)

### Community 1 - "Community 1"
Cohesion: 0.2
Nodes (8): Album, Artist, Color, Playlist, Track, NavidromeClient, Equatable, Identifiable

### Community 2 - "Community 2"
Cohesion: 0.11
Nodes (11): buildAuth(), buildUrl(), createPlaylist(), deletePlaylist(), getCoverUrl(), getNavidromeConfig(), getStreamUrl(), setRating() (+3 more)

### Community 3 - "Community 3"
Cohesion: 0.1
Nodes (8): SubsonicAuth, KeychainHelper, NowPlayingView, SettingsView, CodingKeys, subsonicResponse, CodingKey, String

### Community 4 - "Community 4"
Cohesion: 0.12
Nodes (16): error, getAlbumTracks(), getPlaylistTracks(), scrobble(), buildAuth(), testFrequent(), buildAuth(), testHistory() (+8 more)

### Community 5 - "Community 5"
Cohesion: 0.19
Nodes (19): AlbumList, ArtistIndexNode, ArtistsIndex, PlaylistsWrapper, PlaylistWrapper, RandomSongsWrapper, SearchResult3, SubsonicAlbum (+11 more)

### Community 6 - "Community 6"
Cohesion: 0.18
Nodes (4): ContentView, NavidromeClient, PlaybackManager, ObservableObject

### Community 7 - "Community 7"
Cohesion: 0.2
Nodes (2): handleEnded(), updateTime()

### Community 8 - "Community 8"
Cohesion: 0.18
Nodes (10): AppSettingsView, ConnStatus, connected, connecting, idle, FloatingLabelField, SettingsStep, client (+2 more)

### Community 9 - "Community 9"
Cohesion: 0.22
Nodes (3): ArtistDetailView, ScrollOffsetKey, PreferenceKey

### Community 10 - "Community 10"
Cohesion: 0.47
Nodes (2): App, VeloraApp

### Community 13 - "Community 13"
Cohesion: 0.5
Nodes (4): ScreenTier, compact, large, regular

## Knowledge Gaps
- **14 isolated node(s):** `compact`, `regular`, `large`, `grid`, `list` (+9 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 7`** (11 nodes): `.reportNowPlaying()`, `.scrobble()`, `checkLayout()`, `handleEnded()`, `if()`, `seek()`, `togglePlayback()`, `App.tsx`, `updateDuration()`, `updateTime()`, `main.tsx`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 10`** (6 nodes): `App`, `VeloraApp`, `.init()`, `.registerCustomFonts()`, `.setupURLCache()`, `App.swift`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `error` connect `Community 4` to `Community 8`?**
  _High betweenness centrality (0.289) - this node is a cross-community bridge._
- **Why does `ConnStatus` connect `Community 8` to `Community 4`?**
  _High betweenness centrality (0.288) - this node is a cross-community bridge._
- **Why does `SettingsView` connect `Community 3` to `Community 8`, `Community 0`?**
  _High betweenness centrality (0.225) - this node is a cross-community bridge._
- **Are the 6 inferred relationships involving `Track` (e.g. with `.fetchRecentlyPlayed()` and `.fetchAlbumTracks()`) actually correct?**
  _`Track` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `compact`, `regular`, `large` to the rest of the system?**
  _14 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.08 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.11 - nodes in this community are weakly interconnected._