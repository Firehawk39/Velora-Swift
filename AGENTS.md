# Velora AI Studio — Engineering Operating System

## Golden Standard of Quality
Every solution, bugfix, and implementation in this codebase must be **world-class, production-ready, and architected to the standards of Spotify and Apple Music**:
- **0ms Main-Thread Render Guarantee**: Zero synchronous disk reads or JSON parsing during SwiftUI view rendering or layout passes.
- **Strict Multi-Tier Caching**: L1 RAM (`NSCache`) $\rightarrow$ In-memory canonical index $\rightarrow$ L2 Disk $\rightarrow$ Async Network.
- **Zero-Flicker Transitions**: Direct seamless cross-fades between visual assets on track skips and orientation changes.
- **Unified Single Source of Truth**: No duplicated candidate loops or asset resolution logic across views.
- **Universal Compatibility**: Support iOS 15.0 through the latest iPadOS (Split View, Stage Manager, ProMotion 120Hz).
- **Swift 6 Concurrency**: Full strict concurrency safety (`Sendable`, `@MainActor`, zero data races).
