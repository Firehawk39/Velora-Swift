# Technical Architecture Plan: [Feature Name]

**Spec Reference**: `spec.md`  
**Status**: Proposed | In Progress | Completed  
**Author**: [Author / Agent]  
**Date**: [YYYY-MM-DD]  

---

## 1. Architectural Overview & Blueprint

```
[Layer 1: SwiftUI Presentation]
           │ 0ms Reactive Bindings (@Published / Observation)
           ▼
[Layer 2: Domain Managers & Coordinators]
           │ Thread-Safe Memory Cache / SendableCanonicalIndex
           ▼
[Layer 3: Local Storage / L2 Disk Cache]
           │ Background Asynchronous I/O
           ▼
[Layer 4: Network & Remote Clients]
```

- High-level design summary and structural flow.
- Responsibilities of modified or introduced components.

---

## 2. Data Models & API Contracts

```swift
// Example data contracts (must be Sendable & Equatable)
struct NewModel: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    // Explicit non-optional fields or documented fallbacks
}
```

- Serialization format & migration considerations.
- Persistence mechanisms (SQLite `DatabaseManager`, JSON sidecars, `VeloraStorage`).

---

## 3. Threading, Concurrency & State Management
- **Actor Boundaries**: Which components run on `@MainActor` vs background cooperative task pools?
- **Lock Invariants**: If non-actor shared memory is required, which lock is used (`os_unfair_lock_s`, `NSLock`)?
- **Type-Check Safety**: Ensure expressions avoid complex nested closures or unbounded nil-coalescing that trigger Swift type-checker timeouts.

---

## 4. Multi-Tier Caching & Invalidation Strategy
- **L1 RAM**: Key naming conventions, cache size bounds, eviction triggers.
- **In-Memory Canonical Index**: Fast O(1) RAM lookup keys (`SendableCanonicalIndex`).
- **L2 Disk**: Canonical file directory, file naming sanitization (`sanitizeFileName`), file extension handling.
- **Negative Caching**: TTL and invalidation rules (ensuring permanent negative marks are only written after true retries).

---

## 5. File Impact Matrix

| File Path | Action | Description of Changes |
|-----------|--------|------------------------|
| `Sources/App/...` | Modify | Add method X, decouple Y |
| `Sources/App/...` | Create | New controller/view component |

---

## 6. Verification & Verification Plan
- **Type-Checking & Build Command**: `xcodebuild` or local syntax/structure audit.
- **Static Analysis**: Verify zero warnings (`-warnings-as-errors` rigor).
- **Physical Disk Audit**: File existence and size checks (> 100 bytes for images, > 0 bytes for lyrics).
- **Live MCP Tooling**: If on device, verify via Velora MCP server tools (`velora_get_status`, etc.).
