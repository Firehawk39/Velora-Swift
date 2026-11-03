# Velora AI Studio — System Constitution
*(Derived from AGENTS.md and GitHub Spec Kit standards)*

Every feature, plan, and code change developed in this codebase must adhere strictly to these non-negotiable architectural invariants.

---

## 1. Golden Standard of Quality
Every solution, bugfix, and implementation in this codebase must be **world-class, production-ready, and architected to the standards of Spotify and Apple Music**:

### 1.1 0ms Main-Thread Render Guarantee
- **Zero synchronous disk reads, file-manager queries, or JSON deserialization** during SwiftUI view body rendering, layout passes, or animation frames.
- All view-facing assets must be pre-indexed into RAM caches (`SendableCanonicalIndex` or `NSCache`) ahead of time.

### 1.2 Strict Multi-Tier Caching Pipeline
Every asset (artwork, backdrop, clear logo, lyrics, metadata) must follow this exact hierarchy:
$$\text{L1 RAM } (\text{NSCache}) \longrightarrow \text{In-memory canonical index } (<0.001\text{ms}) \longrightarrow \text{L2 Local Disk } (\sim 1\text{ms}) \longrightarrow \text{Async Network}$$
- Network calls must be backgrounded and throttled (`URLSessionTask.lowPriority` or dedicated worker queues).
- Fast scrolling and rapid track skipping must hit L1 or instant in-memory indices without UI stutter.

### 1.3 Zero-Flicker Transitions
- Provide direct, seamless cross-fades between visual assets on track skips, queue changes, and orientation rotations.
- Never flash black, blank, or placeholder gradients if cached assets exist for the incoming entity.

### 1.4 Unified Single Source of Truth
- No duplicated candidate loops, file-path construction, or asset resolution logic scattered across views.
- Centralized managers (`FanartManager`, `PlaybackManager`, `MusicBrainzManager`, `SyncManager`) own the canonical resolution pipeline.

### 1.5 Universal Compatibility & ProMotion
- Universal support: iOS 15.0 through the latest iPadOS (Split View, Slide Over, Stage Manager, ProMotion 120Hz).
- Adaptive animation responses for ProMotion displays (e.g., 0.35s on large canvas vs 0.55s on standard devices).

---

## 2. Swift 6 Concurrency & Compilation Rigor

### 2.1 Concurrency Safety
- Full strict concurrency compliance (`Sendable`, `@MainActor`, `nonisolated`, zero data races).
- Multi-file cache structures must use locks (`os_unfair_lock_s` / `NSLock`) or `nonisolated` query methods.
- Provide explicit closure parameter types where Swift type inference could fail across concurrency boundaries or cause compiler constraint solver timeouts.

### 2.2 Zero Compile-Error & Symbol Rigor
- **Never hallucinate static singletons**: Verify type definitions before referencing (e.g., `NavidromeClient` has NO `.shared`; it is injected or accessed via `PlaybackManager.shared?.client` or SwiftUI environment).
- **Verify access levels**: Check `private` vs `internal`/`public` before calling cross-file symbols.
- **Zero warnings policy**: Eliminate compiler warnings completely (no unused bindings, no dead nil-coalescing, no deprecated API warnings).

---

## 3. Library Metadata Baseline (MusicBrainz Picard Standard)
- The user's music library is curated and tagged through **MusicBrainz Picard**.
- Audio tracks contain canonical MusicBrainz track titles, release albums, artist credits, exact track durations, and `musicBrainzId` (recording/track MBID) where available.
- All algorithms (lyrics fetching, artwork resolution, scrobbling) must treat Picard tags as the baseline canonical truth.
- External lookup strategies (LRCLIB, Fanart.tv, TheAudioDB) must support multi-tier matching:
  1. Exact Picard canonical metadata (`title`, `artist`, `album`, `duration`).
  2. Picard artist-credit normalization (resolving `feat.` / `featuring` / multi-artist collaborations to both full credit and primary artist).
  3. Resilient duration tolerance ($\pm 2\text{s}$ to $\pm 5\text{s}$) to bridge any CD-rip silence padding vs studio release duration.

---

## 4. Commit & Deployment Protocol
- **Atomic, Verified Commits**: Every change must compile cleanly with zero warnings and be verified against on-disk state.
- **Push Immediately**: In accordance with the project workflow, committing always includes pushing directly to GitHub (`git push origin <branch>`) so CI/CD (Codemagic, Bitrise) triggers automatically without delay.
