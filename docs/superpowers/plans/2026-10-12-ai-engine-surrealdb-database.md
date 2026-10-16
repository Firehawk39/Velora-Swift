# Velora AI Engine & SurrealDB Database Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy a containerized AI Engine with SurrealDB multi-model database (Graph + Vector + Documents) on Umbrel, implement CLAP audio embeddings and Essentia acoustic feature extraction (Camelot keys), build a Conversational DJ with Ollama on the RTX 3080 Ti, enable predictive gapless prefetching, and integrate native Swift chat and offline auto-relay telemetry sync into the Velora iOS/macOS app.

**Architecture:** A FastAPI service and SurrealDB multi-model database containerized on Umbrel. Offline audio feature extraction embeds tracks from `/Home/Downloads/music` into SurrealDB using CLAP (512-dim HNSW vector index) and Essentia on GPU 1 (RTX 3060). Everyday operational runtime uses GPU 0 (RTX 3080 Ti) for low-latency Ollama conversational inference (`qwen2.5:14b-instruct-q4_K_M` or fine-tuned `velora-dj`), with zero heavy background jobs running during daily playback. Velora on iOS/macOS streams chat responses, triggers predictive 30s prefetching for gapless transitions, and queues offline telemetry in local SQLite, auto-flushing to SurrealDB upon reconnecting.

**Tech Stack:** SurrealDB (Rust multi-model database), SurrealQL, Python 3.11, FastAPI, PyTorch (CLAP), Essentia, Ollama (CUDA), Swift / SwiftUI.

**Spec:** `docs/superpowers/specs/2026-10-12-ai-engine-surrealdb-blueprint.md`

## Global Constraints

- **Music Directory:** `/Home/Downloads/music` mounted strictly read-only into Docker; raw audio files and Navidrome database must never be modified.
- **Hardware Profile:** Umbrel server (`192.168.1.9`, AMD Ryzen 5 3600, 48 GB RAM), GPU 0 (RTX 3080 Ti 12 GB) for Ollama, GPU 1 (RTX 3060 12 GB) for one-time audio extraction.
- **Vector Dimension:** 512-dimensional dense float vectors (CLAP cosine distance in SurrealDB HNSW index).
- **Scope Discipline:** No HUD clutter in Now Playing, no voice TTS synthesis, no lyrics embeddings—focused purely on audio waveform embeddings, harmonic Camelot mixing, structured chat, gapless prefetch, and offline auto-relay sync.

## Review Focus

1. **Missing / Corrupt Audio Metadata:** Tracks with invalid tags must still parse via Essentia without crashing the ingestion worker.
2. **SurrealQL Vector Index Readiness:** The HNSW vector index definition on the `embedding` field must be validated before upserting batches.
3. **Empty Retrieval Graceful Fallback:** When a prompt specifies mutually exclusive criteria, the DJ must gracefully apologize and suggest alternatives rather than erroring out.
4. **Offline Queue Reconnection Flush:** Telemetry queued while offline must cleanly batch-sync without duplicate records or dropped events upon network reconnect.
5. **Client Offline State:** `VeloraChatView` must display a clean connection status banner without freezing playback or UI when disconnected from the Umbrel server.

---

### Task 1: SurrealDB Store & Multi-Model Client Integration

**Files:**
- Create: `AI_Archive/AIEngine/database/surreal_store.py`
- Create: `AI_Archive/AIEngine/tests/test_surreal_store.py`

**Interfaces:**
- Produces: `SurrealMusicStore` with methods:
  - `init_schema() -> None` (defines track, artist, album tables, graph edges, and HNSW index)
  - `upsert_track(track_id: str, vector: list[float], payload: dict) -> None`
  - `create_collaboration(artist_a: str, artist_b: str, context: dict | None = None) -> None`
  - `search_hybrid(query_vector: list[float], acoustic_filter: dict | None = None, limit: int = 10) -> list[dict]`
  - `record_preference(user_id: str, action: str, track_id: str) -> None`
  - `batch_record_telemetry(events: list[dict]) -> int`

- [ ] **Step 1: Write the failing test for `SurrealMusicStore`**

```python
import pytest
from database.surreal_store import SurrealMusicStore

@pytest.mark.asyncio
async def test_surreal_store_schema_and_upsert():
    store = SurrealMusicStore(url="ws://localhost:8000/rpc", mock_mode=True)
    await store.init_schema()
    sample_vector = [0.05] * 512
    payload = {"title": "Clocks", "artist": "Coldplay", "bpm": 130.0, "key": "Eb major", "camelot_key": "8B"}
    await store.upsert_track("tr-coldplay-clocks", sample_vector, payload)
    results = await store.search_hybrid(sample_vector, limit=1)
    assert len(results) == 1
    assert results[0]["title"] == "Clocks"
    assert results[0]["camelot_key"] == "8B"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_surreal_store.py`  
Expected: FAIL with `ModuleNotFoundError` or `ImportError`.

- [ ] **Step 3: Implement `SurrealMusicStore` in `database/surreal_store.py`**

Implement `SurrealMusicStore` using `surrealdb` async Python client. Connect to SurrealDB (`ws://surrealdb:8000/rpc`), initialize namespace `velora` and database `music`, execute schema definition DDL (tables, fields, HNSW index), and implement hybrid SurrealQL queries.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_surreal_store.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/database/surreal_store.py AI_Archive/AIEngine/tests/test_surreal_store.py
git commit -m "feat(ai-engine): implement SurrealMusicStore with Graph and HNSW Vector schema"
```

---

### Task 2: Audio Ingestion Worker with Essentia Camelot Keys & CLAP

**Files:**
- Modify: `AI_Archive/AIEngine/services/audio_processor.py`
- Create: `AI_Archive/AIEngine/tests/test_audio_processor.py`

**Interfaces:**
- Consumes: `SurrealMusicStore.upsert_track(track_id, vector, payload)`
- Produces: `AudioProcessor` with methods:
  - `extract_features(file_path: str) -> dict` (returns `{bpm, key, camelot_key, danceability, energy, valence}`)
  - `generate_audio_embedding(file_path: str) -> list[float]` (returns 512-dim float vector)
  - `process_directory(directory_path: str, store: SurrealMusicStore) -> int`

- [ ] **Step 1: Write the failing test for `AudioProcessor` Camelot extraction**

```python
import pytest
from services.audio_processor import AudioProcessor, to_camelot

def test_camelot_key_conversion():
    assert to_camelot("C", "major") == "8B"
    assert to_camelot("A", "minor") == "8A"
    assert to_camelot("G", "major") == "9B"
    assert to_camelot("E", "minor") == "9A"

def test_audio_processor_mock_extraction(tmp_path):
    processor = AudioProcessor(use_gpu=False, mock_mode=True)
    fake_audio = tmp_path / "sample.mp3"
    fake_audio.write_bytes(b"mock audio bytes")
    features = processor.extract_features(str(fake_audio))
    assert "bpm" in features
    assert "camelot_key" in features
    embedding = processor.generate_audio_embedding(str(fake_audio))
    assert len(embedding) == 512
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_audio_processor.py`  
Expected: FAIL.

- [ ] **Step 3: Implement `AudioProcessor` in `services/audio_processor.py`**

Wire Essentia acoustic feature extraction (BPM, Key, Scale -> Camelot mapping, Danceability) and PyTorch CLAP model (`laion/larger_clap_music`) on GPU 1 (RTX 3060). Traverse `/Home/Downloads/music` and commit tracks, artists, and graph relations to `SurrealMusicStore`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_audio_processor.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/services/audio_processor.py AI_Archive/AIEngine/tests/test_audio_processor.py
git commit -m "feat(ai-engine): implement AudioProcessor with Camelot keys and CLAP extraction"
```

---

### Task 3: Conversational DJ & Predictive Prefetch Endpoints

**Files:**
- Modify: `AI_Archive/AIEngine/services/rag_engine.py`
- Create: `AI_Archive/AIEngine/api/chat.py`
- Create: `AI_Archive/AIEngine/api/recommend.py`
- Create: `AI_Archive/AIEngine/tests/test_rag_engine.py`

**Interfaces:**
- Consumes: `SurrealMusicStore.search_hybrid(...)`
- Produces: 
  - `GET /api/v1/chat/stream`: SSE / JSON event stream emitting `{type: "text" | "action", ...}`
  - `GET /api/v1/recommend/next?current_track_id=...`: Returns harmonically compatible next track for prefetch.

- [ ] **Step 1: Write the failing test for structured action events**

```python
import pytest
from services.rag_engine import ConversationalDJ

def test_structured_action_generation():
    dj = ConversationalDJ(ollama_url="http://localhost:11434", mock_mode=True)
    events = list(dj.generate_structured_response("Play some Coldplay"))
    actions = [e for e in events if e.get("type") == "action"]
    assert len(actions) > 0
    assert "command" in actions[0]
    assert "track_id" in actions[0]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_rag_engine.py`  
Expected: FAIL.

- [ ] **Step 3: Implement `ConversationalDJ` and `/api/v1/recommend/next`**

Implement CLAP text encoding for user query prompts, hybrid vector retrieval against SurrealDB, Ollama streaming with structured JSON event outputs (no fragile regex), and harmonic next-track recommendation (`/api/v1/recommend/next`).

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_rag_engine.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/services/rag_engine.py AI_Archive/AIEngine/api/chat.py AI_Archive/AIEngine/api/recommend.py AI_Archive/AIEngine/tests/test_rag_engine.py
git commit -m "feat(ai-engine): add ConversationalDJ structured events and predictive prefetch endpoint"
```

---

### Task 4: Telemetry & Offline Auto-Relay Sync Endpoint

**Files:**
- Create: `AI_Archive/AIEngine/api/telemetry.py`
- Create: `AI_Archive/AIEngine/tests/test_telemetry.py`

**Interfaces:**
- Consumes: `SurrealMusicStore.record_preference(...)`, `SurrealMusicStore.batch_record_telemetry(...)`
- Produces:
  - `POST /api/v1/telemetry/event` (single event)
  - `POST /api/v1/telemetry/batch` (batch flush from offline client queue)

- [ ] **Step 1: Write the failing test for batch telemetry sync**

```python
import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_telemetry_batch_endpoint():
    response = client.post("/api/v1/telemetry/batch", json={
        "events": [
            {"event_type": "play", "track_id": "tr-1", "timestamp": "2026-10-13T00:00:00Z"},
            {"event_type": "skip", "track_id": "tr-2", "timestamp": "2026-10-13T00:03:00Z"}
        ]
    })
    assert response.status_code == 200
    assert response.json()["synced_count"] == 2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_telemetry.py`  
Expected: FAIL.

- [ ] **Step 3: Implement batch and single telemetry endpoints**

Implement `POST /api/v1/telemetry/event` and `POST /api/v1/telemetry/batch` in `api/telemetry.py` updating track counters and creating SurrealDB graph edges.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_telemetry.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/api/telemetry.py AI_Archive/AIEngine/tests/test_telemetry.py
git commit -m "feat(ai-engine): implement single and batch telemetry endpoints for offline relay"
```

---

### Task 5: Docker Compose Stack for Umbrel (SurrealDB + FastAPI)

**Files:**
- Modify: `AI_Archive/AIEngine/docker-compose.yml`
- Modify: `AI_Archive/AIEngine/Dockerfile`

**Interfaces:**
- Produces: Docker Compose configuration defining:
  - `surrealdb`: Official `surrealdb/surrealdb:latest` with data volume `surreal_data:/data` on port `8001`.
  - `ai-engine`: FastAPI service on port `8000`, volume mount `host_music:/music:ro` pointing to `/Home/Downloads/music`, environment pointing to host Ollama (`http://umbrel.local:11434`).

- [ ] **Step 1: Validate docker-compose syntax**

```bash
docker compose -f AI_Archive/AIEngine/docker-compose.yml config
```
Expected: Valid compose config output without YAML syntax errors.

- [ ] **Step 2: Commit**

```bash
git add AI_Archive/AIEngine/docker-compose.yml AI_Archive/AIEngine/Dockerfile
git commit -m "chore(ai-engine): configure Docker Compose with SurrealDB and Umbrel mounts"
```

---

### Task 6: Velora Swift Client Integration (Prefetch, Offline Queue, Clean UI)

**Files:**
- Move: `AI_Archive/VeloraChatView.swift` -> `Sources/App/VeloraChatView.swift`
- Modify: `Sources/App/ContentView.swift`
- Modify: `Sources/App/PlaybackManager.swift`
- Modify: `Sources/App/DatabaseManager.swift`
- Modify: `Sources/App/SettingsView.swift`

**Interfaces:**
- Consumes: FastAPI endpoints (`/api/v1/chat/stream`, `/api/v1/recommend/next`, `/api/v1/telemetry/batch`)
- Produces:
  - Clean Conversational DJ view in `ContentView.swift` (no cluttered HUD graphs).
  - Predictive 30s audio prefetch and gapless crossfade in `PlaybackManager.swift`.
  - Offline telemetry queue table in `DatabaseManager.swift` with auto-sync on network reconnect.

- [ ] **Step 1: Move and update `VeloraChatView.swift` in `Sources/App/`**

Support structured streaming events (`delta`, `action`) from the AI engine with clean message rendering.

- [ ] **Step 2: Add offline telemetry queue to `DatabaseManager.swift`**

Add table `OfflineTelemetryQueue (id INTEGER PRIMARY KEY, eventType TEXT, trackId TEXT, timestamp TEXT, durationPlayed REAL)`. Add `queueOfflineEvent(...)` and `flushOfflineEvents(to url: URL)`.

- [ ] **Step 3: Wire predictive prefetch & beat crossfade into `PlaybackManager.swift`**

At track progress `duration - 30.0`:
Call `/api/v1/recommend/next?current_track_id=\(current.id)` in background and prefetch audio data into buffer.

- [ ] **Step 4: Verify Swift project compilation**

Run: `swift build` (or verify in Xcode/SPM).  
Expected: Build succeeds with 0 errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/VeloraChatView.swift Sources/App/ContentView.swift Sources/App/PlaybackManager.swift Sources/App/DatabaseManager.swift Sources/App/SettingsView.swift
git commit -m "feat(app): integrate clean Conversational DJ, 30s prefetch, and offline auto-relay queue"
```

---

### Task 7: Offline Dual-GPU Unsloth Fine-Tuning Pipeline (`velora-dj`)

**Files:**
- Create: `AI_Archive/AIEngine/training/train_grpo.py`
- Create: `AI_Archive/AIEngine/training/export_gguf.sh`
- Create: `AI_Archive/AIEngine/training/Modelfile`

**Interfaces:**
- Produces: Standalone training script leveraging combined dual GPUs (RTX 3080 Ti + RTX 3060, 24 GB VRAM) to fine-tune `qwen2.5:14b` with Unsloth GRPO, and export `velora-dj.gguf` for Ollama.

- [ ] **Step 1: Write `train_grpo.py` using Unsloth**

Configure distributed QLoRA across both CUDA devices (`cuda:0` and `cuda:1`), setting format reward for structured actions and acoustic explanation rewards.

- [ ] **Step 2: Write GGUF export and Modelfile script**

Configure `ollama create velora-dj -f Modelfile` with system prompts tailored for the music DJ persona.

- [ ] **Step 3: Commit**

```bash
git add AI_Archive/AIEngine/training/train_grpo.py AI_Archive/AIEngine/training/export_gguf.sh AI_Archive/AIEngine/training/Modelfile
git commit -m "feat(ai-engine): add dual-GPU Unsloth GRPO fine-tuning pipeline for velora-dj"
```
