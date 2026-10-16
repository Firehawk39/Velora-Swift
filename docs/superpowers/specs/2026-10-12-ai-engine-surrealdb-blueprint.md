# Velora AI Engine & SurrealDB Blueprint

**Status:** Approved  
**Date:** 2026-10-13  
**Target Systems:** Umbrel Home Server (`umbrelOS 2.0`, `192.168.1.9`) & Velora Swift Client (iOS/macOS)  

---

## 1. Intent & Overview

Velora is a native Swift music client connecting to self-hosted Navidrome / Subsonic music libraries. This project introduces a dedicated, high-performance **AI Engine and SurrealDB Multi-Model Database** on Umbrel to deliver an intelligent personal music system with:
- **Unified Multi-Model Intelligence:** Combining Document metadata, Native Graph relationships (`artist->collaborated->artist`, `track->belongs_to->album`), and HNSW Vector Embeddings (512-dim CLAP audio sound vectors) in a single Rust database engine.
- **Harmonic Music Theory & Camelot Mixing:** Essentia-extracted BPM and musical keys enabling seamless harmonic transitions and smooth energy curves.
- **Conversational DJ:** An in-app assistant that understands listening habits, explains recommendations with musical context, and issues playback commands (`[PLAY: <trackId>]`, `[QUEUE: <trackId>]`).
- **Predictive Gapless Prefetch:** Pre-buffers upcoming AI-selected tracks 30 seconds before the current track finishes for zero-latency, seamless playback.
- **Offline Travel Mode & Auto-Relay Sync:** When disconnected from the Umbrel server, Velora falls back to local cached playback and queues telemetry events in local SQLite (`DatabaseManager.swift`). Upon reconnecting to Umbrel, the sync queue automatically relays all queued events to SurrealDB.
- **Native Model Context Protocol (`SurrealMCP`):** First-party embedded MCP server exposing the unified graph, vector search, and library diagnostics directly to AI agents.

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
- PyTorch CLAP and Essentia extract acoustic features (BPM, key, danceability, Camelot scale) and 512-dim audio embeddings.
- Ingests tracks, artists, and graph relations permanently into **SurrealDB**.
- **PyTorch shuts down completely after indexing.** GPU 1 VRAM is freed. Future scans are incremental only when new tracks are added.

### Stage 2: One-Time Offline Fine-Tuning (Full Dual-GPU Power)
- Dedicates **both GPUs simultaneously (24 GB combined VRAM)** to Unsloth.
- Runs QLoRA & GRPO to train the specialized `velora-dj` model.
- Converts weights to GGUF and imports into Ollama (`ollama create velora-dj`).
- **Training terminates completely.** Both GPUs are freed.

### Stage 3: Everyday Music Playback (Ultra-Lightweight Operational Mode)
- **Zero background heavy ML jobs are running.**
- **SurrealDB**: Runs as a lightweight multi-model database service in Docker (<100 MB RAM, millisecond search latency).
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
|  - SurrealDB Multi-Model Store (<100 MB RAM, Instant Lookups)           |
|  - Navidrome Music Server                                               |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                           Velora Client App                             |
|  - SwiftUI Conversational DJ UI (VeloraChatView.swift)                  |
|  - Predictive Gapless Prefetch Engine (PlaybackManager.swift)           |
|  - Offline SQLite Cache & Auto-Relay Sync Queue (DatabaseManager.swift) |
+-------------------------------------------------------------------------+
```

---

## 4. Database Architecture: SurrealDB Schema

SurrealDB unifies Document metadata, Graph relationships, and HNSW Vector indexes:

### A. Core Tables & Schemas:

```surrealql
-- Tracks Table with 512-dim CLAP HNSW Index
DEFINE TABLE track SCHEMAFULL;
DEFINE FIELD id ON track TYPE record<track>;
DEFINE FIELD title ON track TYPE string;
DEFINE FIELD artist ON track TYPE string;
DEFINE FIELD album ON track TYPE string;
DEFINE FIELD bpm ON track TYPE float;
DEFINE FIELD musical_key ON track TYPE string;
DEFINE FIELD camelot_key ON track TYPE string;  -- e.g. "8A", "8B", "9A"
DEFINE FIELD danceability ON track TYPE float;
DEFINE FIELD energy ON track TYPE float;
DEFINE FIELD valence ON track TYPE float;
DEFINE FIELD play_count ON track TYPE int DEFAULT 0;
DEFINE FIELD skip_count ON track TYPE int DEFAULT 0;
DEFINE FIELD embedding ON track TYPE array<float>;

-- HNSW Vector Index for Cosine Similarity
DEFINE INDEX track_embedding ON track FIELDS embedding HNSW DIMENSION 512 DIST COSINE;

-- Artists & Albums
DEFINE TABLE artist SCHEMAFULL;
DEFINE FIELD name ON artist TYPE string;
DEFINE TABLE album SCHEMAFULL;
DEFINE FIELD title ON album TYPE string;

-- Native Graph Edges
DEFINE TABLE belongs_to SCHEMALESS;         -- track->belongs_to->album
DEFINE TABLE performed_by SCHEMALESS;        -- track->performed_by->artist
DEFINE TABLE collaborated_with SCHEMALESS;    -- artist->collaborated_with->artist
DEFINE TABLE listener_preference SCHEMALESS;  -- user->loves->genre / user->skipped->track
```

### B. Hybrid Retrieval Query Example:
A single SurrealQL query resolves acoustic vector similarity while navigating collaborator relationships and harmonic key constraints:

```surrealql
LET $query_vec = $prompt_embedding;

SELECT 
    id, title, artist, bpm, musical_key, camelot_key,
    vector::similarity::cosine(embedding, $query_vec) AS similarity,
    <-performed_by<-artist->collaborated_with->artist.name AS network
FROM track
WHERE vector::similarity::cosine(embedding, $query_vec) > 0.70
ORDER BY similarity DESC
LIMIT 10;
```

---

## 5. Component Architecture

### 1. Ingestion Worker (`audio_processor.py`)
- Reads `/Home/Downloads/music` directly (read-only mount).
- Computes acoustic features via **Essentia** (BPM, key, scale, Camelot code, danceability).
- Chunks and embeds audio waveforms via **CLAP** model (`laion/larger_clap_music`) on GPU 1 (RTX 3060).
- Commits track documents, graph edges, and vector points into SurrealDB.
- Shuts down upon completion; strictly read-only on music files.

### 2. Conversational RAG Engine (`rag_engine.py`)
- User prompt in Velora: *"Put on upbeat electronic songs with a driving beat for coding."*
- Generates text query embedding via CLAP text encoder.
- Queries SurrealDB for nearest audio embeddings with harmonic constraints.
- Pulls listener profile and historical favorites from SurrealDB graph edges.
- Assembles system prompt with top-k candidates and sends to Ollama on GPU 0 (RTX 3080 Ti).
- Returns natural language DJ text with structured action events (`play`, `queue`).

### 3. Predictive Prefetch & Gapless Transition Engine
- Velora client monitors playback position. At `duration - 30s`, calls `GET /api/v1/recommend/next?current_track_id=...`.
- Pre-buffers the next track audio stream in background.
- At track boundary, performs smooth gapless crossfade.

### 4. Telemetry & Offline Auto-Relay Sync
- In online mode: Client dispatches `POST /api/v1/telemetry/event` immediately.
- In offline mode: Client saves play/skip events to local SQLite `OfflineTelemetryQueue`.
- When connection to Umbrel restores: Background task flushes the queue via batch `POST /api/v1/telemetry/batch` to SurrealDB.

---

## 6. Goals, Non-Goals & Anti-Goals

### Goals:
1. Fast conversational DJ responses (<1.5s time-to-first-token on RTX 3080 Ti).
2. Clean, focused playback UI without noisy or cluttered HUD graphs.
3. Fully gapless playback with 30s predictive prefetch.
4. Robust offline playback with automatic telemetry relay upon reconnection.
5. True multi-model intelligence: Graph + Vector + Document in one Rust engine.

### Non-Goals:
1. Lyrical text embedding pipelines (kept clean and audio-centric via CLAP).
2. Local neural TTS voice synthesis (Kokoro-82M dropped; conversational DJ remains text-driven with direct playback actions).
3. Overcomplicated "Now Playing" HUD graphs (Now Playing stays sleek and uncluttered).

### Anti-Goals:
1. Audio playback gap or buffering delays between AI-recommended songs.
2. Lost listening telemetry when operating offline away from home server.
3. Monolithic single-GPU scheduling that causes OOM crashes or freezes chat during library scans.
