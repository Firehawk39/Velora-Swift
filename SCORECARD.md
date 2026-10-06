# 🎵 Velora AI Studio — Judges' Scorecard

> A deep technical audit across every layer of the project.

---

## 🏆 Overall Verdict

| Layer | Score | Grade |
|---|---|---|
| iOS App Architecture | 87 / 100 | **A−** |
| AI Engine Backend | 74 / 100 | **B** |
| Integration & Glue | 61 / 100 | **C+** |
| Training Pipeline | 70 / 100 | **B−** |
| DevOps / Infra | 65 / 100 | **C+** |
| **COMPOSITE** | **71 / 100** | **B** |

---

## 📱 Card 1 — iOS App (SwiftUI)

### Strengths ✅

- **Architecture is genuinely clean.** The split across `PlaybackManager`, `NavidromeClient`, `SyncManager`, `DatabaseManager`, `FanartManager` is textbook single-responsibility. Each manager handles exactly one domain.
- **Swift 6 concurrency adopted early.** The project is already on `@MainActor`, structured `Task` blocks, and strict concurrency — most iOS projects are still migrating. This is impressive.
- **`VeloraChatView` is production-quality.** SSE streaming with real-time delta appending, `[PLAY: id]` / `[QUEUE: id]` regex parsing into `MessageSegment` enum, `TrackChipView` resolving track metadata from local DB, and keyboard dismissal — all wired correctly.
- **`PlaybackManager` is the crown jewel.** At 65KB it's dense but purposeful — background audio, lock screen controls (MPNowPlayingInfoCenter), steering wheel inputs (MPRemoteCommandCenter), offline queue, and playback history. That's the hard stuff done right.
- **Download manager** with file integrity checking signals serious engineering intent.

### Issues ⚠️

- **`engineBaseUrl` in `VeloraChatViewModel` has a hardcoded override.**
  ```swift
  // VeloraChatView.swift:82
  components.port = 8000
  components.path = "/api/v1"
  ```
  The user sets the server URL in Settings, but the port and path are clobberred unconditionally. If someone runs the backend on port 443 or a different API prefix, this breaks silently.

- **Missing telemetry fire-and-forget.** `VeloraChatView` sends context with messages, but `PlaybackManager` never calls `/api/v1/telemetry/event` for play/skip events. The AI engine has a perfectly functional telemetry endpoint sitting idle — the Swift side just never uses it.

- **`ollama_client.py` is orphaned.** The direct Ollama httpx client (`ollama_client.py`) was the old approach. The new `agent.py` uses pydantic-ai. Both exist. The old file has a stale default model (`gemma2:9b` vs the blueprint's `gemma4:e4b`). Dead code is a maintenance hazard.

- **No loading state for `TrackChipView`.** If `DatabaseManager.shared.getTrack(id:)` returns `nil` (track not in local SQLite — which is guaranteed until the ingestion worker runs), the view just shows `[Track Not Found]` in red. There's no skeleton shimmer or retry logic.

- **`VeloraChatViewModel.engineBaseUrl` is computed fresh on every `send()` call** — reads `UserDefaults` on the hot path. Minor but worth caching.

**Score: 87/100**

---

## 🤖 Card 2 — AI Engine Backend (Python/FastAPI)

### Strengths ✅

- **Pydantic-AI agent pattern is exactly right.** Using `@agent.system_prompt` as a dynamic decorator means every single request re-reads the Obsidian markdown files — user preferences are always current without any cache-invalidation complexity. Smart.
- **60/40 hybrid reranker is implemented correctly.** The `perform_vector_search` in `rag_engine.py` fetches `limit * 5` ANN candidates, hydrates each with relational metadata, scores them with `(0.6 × vector_score) + (0.4 × tag_score)`, and re-sorts. This is the right approach.
- **Graceful degradation everywhere.** Every heavy import (torch, essentia, sqlite_vec) is wrapped in a `try/except ImportError` with a `ML_AVAILABLE` flag. The service boots and serves chat even if ML deps aren't installed yet.
- **The `init_db()` call at module import** ensures the schema always exists before any endpoint fires. Safe and correct.
- **`update_memory` tool** lets the LLM write new preferences into the markdown vault mid-conversation. Closing the learning loop in real-time is a genuinely elegant design.

### Issues ⚠️

- **`ollama_client.py` is a ghost.** It is never imported by `main.py`, `chat.py`, or any router. `agent.py` does all LLM calls via pydantic-ai's `OpenAIModel`. This file is dead weight and confuses the architecture.

- **`ingestion.py` track ID scheme is fragile.**
  ```python
  track_id = hashlib.md5(file_path.encode('utf-8')).hexdigest()[:16]
  ```
  The Navidrome Subsonic API already provides stable, persistent track IDs (integer or UUID depending on version). Using an MD5 of the local file path means: (a) the AI engine track IDs are completely different from Navidrome track IDs, and (b) the `[PLAY: track_id]` tokens the LLM outputs can never actually resolve in the Swift app's `DatabaseManager`, which stores Navidrome IDs. **This is a full end-to-end integration break.**

- **`ScanRequest` ignores the `tags` field it declares.**
  ```python
  tags = getattr(request, 'tags', "")  # always ""
  ```
  `ScanRequest` only has `track_id` and `file_path`. `tags` was meant to be a field but was never added to the Pydantic model.

- **No auth on any endpoint.** The blueprint specifies "Token-based API keys to prevent unauthorized client requests." None of the routers implement even a basic `APIKey` header check. Anyone who can reach port 8000 can read your telemetry, trigger full library scans, and chat with your AI.

- **`scan_all` is a thundering herd.** It queues every unprocessed track as independent `BackgroundTasks` in a single request handler loop. For a library of 10,000 tracks this would spawn 10,000 background coroutines simultaneously, likely OOM-killing the server. Needs a `asyncio.Semaphore` or a proper task queue.

- **CORS is wide open** (`allow_origins=["*"]`). The comment says to fix this in production, but it should at least be configurable via `settings`.

**Score: 74/100**

---

## 🔗 Card 3 — Integration & Glue (iOS ↔ Backend)

### The Big Break ⛔

The track ID mismatch between the AI Engine and Navidrome is the single largest defect in the project. The data flow is:

```
Navidrome DB  ──[Subsonic API]──▶  Swift app  ──[stores]──▶  DatabaseManager.shared
                                                                        ↑
                                                            Uses Navidrome track IDs

AI Engine  ──[md5(filepath)]──▶  SQLite vec_tracks
                                        ↑
                              Uses path-hash track IDs

LLM output: [PLAY: <path-hash-id>]
Swift app:  DatabaseManager.shared.getTrack(id: <path-hash-id>)  →  nil  →  "Track Not Found" 🔴
```

Until the ingestion API is changed to accept and store Navidrome track IDs instead of generating path-hash IDs, **the AI DJ can never play a song.**

### Other Integration Gaps ⚠️

- **Telemetry is never called from Swift.** `PlaybackManager` fires events internally but never POSTs to `/api/v1/telemetry/event`. The "Taste Graph" and behavioral personalization features are impossible without this data.
- **No Swift-side ingestion trigger.** The app doesn't call `/api/v1/ingestion/scan_all` after a library sync. The AI engine's knowledge of the library is stuck at "manually triggered via curl."
- **`context` field in chat messages sends the track title string**, but `perform_vector_search` needs a *descriptive query*, not a bare title. The LLM could theoretically do this itself, but there's no instruction in the system prompt telling it to translate context into a search query.

**Score: 61/100**

---

## 🧠 Card 4 — Training Pipeline (GRPO / Unsloth)

### Strengths ✅

- **Three-reward architecture is well-reasoned:** `format_reward` (reasoning tags), `dj_explanation_reward` (DJ vocabulary), `relevance_reward` (exact `[PLAY: id]` match). The signal hierarchy matches the blueprint spec exactly.
- **`relevance_reward_func` returns `2.0`** for a correct `[PLAY:]` tag — treating track recommendation accuracy as the primary reward signal (2x weight vs the others at 1.0 max). Smart weighting.
- **Unsloth QLoRA config is appropriate** for the RTX 3060 target: `load_in_4bit=True`, `gpu_memory_utilization=0.6`, gradient checkpointing, `optim="adamw_8bit"`. Should comfortably run under 9GB VRAM.

### Issues ⚠️

- **Synthetic dataset is basically empty.**
  ```
  synthetic_data.jsonl  ─  881 bytes
  ```
  That's maybe 3–5 training examples. GRPO needs hundreds to thousands of diverse prompt/completion pairs to converge meaningfully. The model trained on this would learn almost nothing.

- **`relevance_reward_func` requires `expected_track_id`** as a kwarg, but the JSONL examples almost certainly don't have this field — the function will silently fail or crash at training time.

- **`max_steps = 50`** with a comment "Very short run for testing" — if this is the production training config, the fine-tuned model will be far from useful. But it's likely intentional as a scaffold.

- **No validation split.** GRPO training has no eval dataset defined — you won't know if the model is improving or overfitting.

**Score: 70/100**

---

## 🐳 Card 5 — DevOps / Infra

### Strengths ✅
- **Codemagic CI/CD** is configured for automated iOS builds — that's professional-grade iOS deployment.
- **`docker-compose.yml`** correctly wires the two-container philosophy (FastAPI + Ollama).
- **Conditional ML imports** mean the Docker image can build and start without downloading multi-GB models first.

### Issues ⚠️
- **`requirements.txt` pins Unsloth via a git URL** — not a stable version pin. CI will fail if the unsloth repo changes its API (which it does frequently).
- **Training dependencies are in the same `requirements.txt` as the serving dependencies.** The inference Docker container doesn't need `unsloth`, `trl`, `peft`, `accelerate`, or `bitsandbytes`. These bloat the image by several GB. Should be split: `requirements.txt` (serving) and `requirements-train.txt` (training only).
- **No `.env.example` file.** The `core/config.py` reads from `.env` but there's no template showing what keys are expected (e.g., `OLLAMA_BASE_URL`, `VELORA_MODEL`).
- **`MUSIC_DIR = "/music"` is hardcoded** in `ingestion.py`. Should be in `config.py` / env variable.

**Score: 65/100**

---

## 🎯 Priority Fix List

Ranked by impact:

| Priority | Fix | Impact |
|---|---|---|
| 🔴 **P0** | Fix track ID mismatch — ingestion API must use Navidrome IDs | End-to-end AI DJ is broken without this |
| 🔴 **P0** | Add telemetry calls in `PlaybackManager` for play/skip/complete events | Personalization is impossible without behavioral data |
| 🟠 **P1** | Add `tags` field to `ScanRequest` Pydantic model | Currently always ingests tracks with no tags |
| 🟠 **P1** | Delete `ollama_client.py` (dead code) | Architectural confusion |
| 🟠 **P1** | Fix `engineBaseUrl` port/path override in `VeloraChatViewModel` | Settings page is currently ignored |
| 🟡 **P2** | Add API key auth to FastAPI endpoints | Security |
| 🟡 **P2** | Split `requirements.txt` into serving + training | Docker image bloat |
| 🟡 **P2** | Replace `scan_all` unbounded task fan-out with a semaphore | Stability on large libraries |
| 🟢 **P3** | Expand synthetic training dataset | GRPO model quality |
| 🟢 **P3** | Add `.env.example` | Onboarding DX |
| 🟢 **P3** | Add skeleton/loading state to `TrackChipView` | UX polish |

---

## 💬 Bottom Line

The **vision and architecture are excellent** — the blueprint is coherent, the tech stack choices are well-reasoned (pydantic-ai, sqlite-vec, CLAP, GRPO), and the iOS app is genuinely impressive engineering. The chat UI with streaming, segment parsing, and playback chips is ready for production.

The **AI Engine is a solid scaffold** but has a critical seam where the iOS world and the Python world use incompatible track ID systems. Fix that one thing and the whole loop — ingest → embed → recommend → play → telemetry → learn — can actually close.

The project is ~60% done. The foundation is strong. The remaining work is mostly about **connecting the pipes**.
