# Velora AI Studio — Engineering Operating System

## Golden Standard of Quality
Every solution, bugfix, and implementation in this codebase must be **world-class, production-ready, and architected to the standards of Spotify and Apple Music**:
- **0ms Main-Thread Render Guarantee**: Zero synchronous disk reads or JSON parsing during SwiftUI view rendering or layout passes.
- **Strict Multi-Tier Caching**: L1 RAM (`NSCache`) $\rightarrow$ In-memory canonical index $\rightarrow$ L2 Disk $\rightarrow$ Async Network.
- **Zero-Flicker Transitions**: Direct seamless cross-fades between visual assets on track skips and orientation changes.
- **Unified Single Source of Truth**: No duplicated candidate loops or asset resolution logic across views.
- **Universal Compatibility**: Support iOS 15.0 through the latest iPadOS (Split View, Stage Manager, ProMotion 120Hz).
- **Swift 6 Concurrency**: Full strict concurrency safety (`Sendable`, `@MainActor`, zero data races).
- **Zero Compile-Error & Symbol Rigor Protocol**:
  - Never hallucinate or assume static singletons (e.g. `NavidromeClient` has NO `.shared`; it is injected or accessed via `PlaybackManager.shared?.client` or SwiftUI environment). Always inspect type definitions before writing callers.
  - Never breach access levels: verify `private` vs `internal`/`public` before referencing across files. Multi-file cache structures must be `nonisolated let` or expose nonisolated query methods.
  - Eliminate compiler warnings completely (e.g. do not bind unused variables like `let self = self`; use `self != nil`).
  - Provide explicit closure parameter types where Swift type inference could fail across concurrency boundaries.
- **Commit Protocol**: "Commit" always means commit and immediately push to GitHub (`git push origin <branch>`) so CI/CD (Codemagic, Bitrise) triggers instantly.
