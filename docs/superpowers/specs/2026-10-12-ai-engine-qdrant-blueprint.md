# Velora AI Engine & Database Blueprint

**Status:** Draft / In Review  
**Date:** 2026-10-12  
**Target Systems:** Umbrel Home Server (`umbrelOS 2.0`, `192.168.1.9`) & Velora Swift Client (iOS/macOS)  

---

## 1. Intent & Overview

Velora is a native Swift music client connecting to self-hosted Navidrome / Subsonic music libraries. This project introduces a dedicated, high-performance **AI Engine and Vector Database** to transform Velora into an intelligent personal music system with:
- **Natural Language & Mood Retrieval:** "Play something melancholic and slow with acoustic guitar", "Energetic 90s alternative rock for working out".
- **Conversational DJ:** An in-app assistant that understands listening habits, explains recommendations with acoustic context, and issues playback commands (`[PLAY: <trackId>]`, `[QUEUE: <trackId>]`).
- **Telemetry & Listener Taste Memory:** Continuous tracking of skip/play habits to build a long-term taste profile.
- **Model Context Protocol (MCP) Bridge:** Native MCP server exposing vector search, playback state, and music diagnostics to coding and personal AI agents.

---

## 2. Infrastructure & Verified Hardware Profile

The AI Engine and database run on the user's dedicated Umbrel server alongside Navidrome:

- **Host Machine:** ASRock X570 Taichi Razer Edition, AMD Ryzen 5 3600 (6 Cores / 12 Threads), 48 GB DDR4 RAM.
- **Primary GPU (PCIe Slot 1, Gen 4 @ 8x):** NVIDIA GeForce RTX 3080 Ti (12 GB VRAM).
- **Secondary GPU (PCIe Slot 2, Gen 4 @ 8x):** NVIDIA GeForce RTX 3060 (12 GB VRAM).
- **Total Combined VRAM:** 24 GB discrete VRAM.
- **Host OS:** umbrelOS 2.0 (Debian 13 base) with native NVIDIA GPU container reservations.
- **Active Services on Host:**
  - Navidrome (Subsonic API on port `4533`, library mounted at `/Home/Downloads/music`).
  - Ollama (LLM server on port `11434`).
- **Music Library Location:** `/Home/Downloads/music` (~1.5 GB across ~65 artist directories).

---

## 3. Workload Lifecycle: One-Time Setup vs. Everyday Runtime

The heavy computational work is strictly one-time setup, keeping daily playback ultra-lean:

### Stage 1: One-Time Library Audio Ingestion (Initial Indexing)
- Scans `/Home/Downloads/music` once.
- PyTorch CLAP and Essentia extract acoustic features (BPM, key, danceability) and 512-dim audio embeddings.
- All points are committed permanently to Qdrant.
- **PyTorch shuts down completely after indexing.** GPU 1 VRAM is freed. Future scans are incremental only when new tracks are added.

### Stage 2: One-Time Offline Fine-Tuning (Full Dual-GPU Power)
- Dedicates **both GPUs simultaneously (24 GB combined VRAM)** to Unsloth.
- Runs QLoRA & GRPO to train the specialized `velora-dj` model.
- Converts weights to GGUF and imports into Ollama (`ollama create velora-dj`).
- **Training terminates completely.** 

### Stage 3: Everyday Music Playback (Ultra-Lightweight Operational Mode)
- **Zero background heavy ML jobs are running.**
- **Qdrant**: Runs as a lightweight vector database service in Docker (<150 MB RAM, millisecond search latency).
- **GPU 0 (RTX 3080 Ti 12 GB)**: Holds Ollama with the fine-tuned `velora-dj` model in standby, consuming compute only when answering user chat prompts in Velora.
- **GPU 1 (RTX 3060 12 GB)**: Completely free and idle during normal listening.

```
[ EVERYDAY RUNTIME ARCHITECTURE ]
+-------------------------------------------------------------------------+
|                              Umbrel Server                              |
|                                                                         |
|  [ GPU 0: RTX 3080 Ti ]                [ GPU 1: RTX 3060 ]              |
|  - Ollama (`velora-dj`)                 - 100% Free / Idle               |
|    (Active only during chat queries)     (No active heavy ML jobs)      |
|                                                                         |
|  [ CPU / RAM Layer ]                                                    |
|  - FastAPI AI Engine Orchestrator                                       |
|  - Qdrant Vector Store (<150 MB RAM, instant lookups)                   |
|  - Navidrome Music Server                                               |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                           Velora Client App                             |
|  - SwiftUI Conversational DJ UI (VeloraChatView.swift)                  |
|  - Telemetry Dispatcher (Play/Skip events)                              |
|  - Native Audio Playback Engine (PlaybackManager.swift)                 |
+-------------------------------------------------------------------------+
```

---

## 4. Database Architecture: Qdrant with HelixDB-Ready Abstraction

### A. Why Qdrant Now:
- Battle-tested open-source Rust vector engine.
- Official Docker container (`qdrant/qdrant`) with GPU/AVX acceleration.
- Official MCP support (`mcp-server-qdrant`).
- Millisecond-latency hybrid search (vectors + payload boolean filters).

### B. Future HelixDB Migration Path:
The storage layer implements a generic `MusicVectorStore` interface (`add_track`, `search_similar`, `filter_by_attributes`, `update_telemetry`). When HelixDB's ecosystem and tooling mature, swapping Qdrant for HelixDB requires only a new `HelixDBAdapter` without modifying ingestion or conversational code.

### C. Qdrant Collection Schema: `velora_tracks`
- **Vector Dimension:** 512 floats (CLAP audio embeddings, cosine distance).
- **Payload Attributes:**
  - `track_id` (String, matches Navidrome / SQLite track ID)
  - `title`, `artist`, `album`, `artist_id`, `album_id`, `year`
  - `bpm` (Float)
  - `musical_key` (String, e.g., "C minor", "F# major")
  - `danceability` (Float 0.0 - 1.0)
  - `energy` (Float 0.0 - 1.0)
  - `valence` (Float 0.0 - 1.0, musical positivity/mood)
  - `play_count` (Integer)
  - `skip_count` (Integer)
  - `last_played` (ISO8601 Timestamp)

---

## 5. Component Architecture

### 1. Ingestion Worker (`audio_processor.py`)
- Reads `/Home/Downloads/music` directly (read-only mount).
- Computes acoustic features via **Essentia** (BPM, key, danceability, spectral energy).
- Chunks and embeds audio waveforms via **CLAP** model on GPU 1 (RTX 3060).
- Upserts points into Qdrant collection `velora_tracks`.
- Shuts down upon completion; strictly read-only on music files.

### 2. Conversational RAG Engine (`rag_engine.py`)
- User prompt in Velora: *"Put on upbeat electronic songs with a driving beat for coding."*
- Generates text query embedding via CLAP text encoder.
- Queries Qdrant for nearest audio embeddings with payload filter (`danceability > 0.6`, `bpm > 115`).
- Pulls listener profile and historical favorites from `Memories/` markdown store.
- Assembles system prompt with top-k candidates and sends to Ollama on GPU 0 (RTX 3080 Ti).
- Returns natural language DJ monologue with embedded actionable commands (`[PLAY: track-xyz]`, `[QUEUE: track-abc]`).

### 3. Telemetry Ingestion API (`telemetry.py`)
- Endpoints hit by Velora:
  - `POST /api/telemetry/event` (track started, completed, skipped within <15s).
- Updates skip/play statistics directly on Qdrant points.
- Refines user preference memory markdown files.

### 4. Client Integration: `VeloraChatView.swift`
- Integrated into Velora's navigation / sidebar / tab bar.
- Streams responses from AI Engine WebSocket / REST endpoint.
- Parses `[PLAY: id]` and `[QUEUE: id]` tokens and forwards them directly to `PlaybackManager.shared.playTrack(...)`.

---

## 6. Goals, Non-Goals & Anti-Goals

### Goals:
1. Fast conversational DJ responses (<1.5s time-to-first-token on RTX 3080 Ti).
2. Deep acoustic retrieval without relying on manual tag perfection.
3. Fully local and private execution on Umbrel.
4. Seamless integration with existing `PlaybackManager.swift` and `DatabaseManager.swift`.

### Non-Goals:
1. Keeping heavy PyTorch audio extraction or training processes continuously active in daily runtime.
2. Cloud-only API dependency (must run self-hosted on Umbrel).
3. Direct writes or schema alterations to Navidrome's database or raw audio files.

### Anti-Goals:
1. Monolithic single-GPU scheduling that causes OOM crashes or freezes chat during library scans.
2. Inflexible database queries that bind the code tightly to Qdrant syntax, preventing future adoption of HelixDB.
