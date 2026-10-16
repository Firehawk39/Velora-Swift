# Velora AI Engine & Qdrant Database Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy a containerized AI Engine with Qdrant vector database on the Umbrel server, implement CLAP audio embeddings and Essentia acoustic feature extraction, connect a Conversational DJ powered by Ollama on the RTX 3080 Ti, and integrate the native SwiftUI chat and telemetry client into the Velora iOS/macOS app.

**Architecture:** A FastAPI service and Qdrant vector database containerized for Umbrel. Offline audio feature extraction embeds tracks from `/Home/Downloads/music` into Qdrant using CLAP (512-dim) on GPU 1 (RTX 3060). Everyday operational runtime uses GPU 0 (RTX 3080 Ti) for low-latency Ollama conversational inference (`qwen2.5:14b-instruct-q4_K_M`), with zero heavy background jobs running during playback. Velora on iOS/macOS streams chat responses and issues `[PLAY: <id>]` commands directly into `PlaybackManager.swift`.

**Tech Stack:** Qdrant (Rust vector database), Python 3.11, FastAPI, PyTorch (CLAP), Essentia, Ollama (CUDA), Swift / SwiftUI.

**Spec:** `docs/superpowers/specs/2026-10-12-ai-engine-qdrant-blueprint.md`

## Global Constraints

- **Music Directory:** `/Home/Downloads/music` mounted strictly read-only into Docker; raw audio files and Navidrome database must never be modified.
- **Hardware Profile:** Umbrel server (`192.168.1.9`, AMD Ryzen 5 3600, 48 GB RAM), GPU 0 (RTX 3080 Ti 12 GB) for Ollama, GPU 1 (RTX 3060 12 GB) for one-time audio extraction and Qdrant.
- **Vector Dimension:** 512-dimensional dense float vectors (CLAP cosine similarity).
- **Extensibility:** Storage calls must adhere to an abstract `MusicVectorStore` interface so future migration to HelixDB requires only swapping the adapter.

## Review Focus

1. **Missing / Corrupt Audio Metadata:** Tracks with invalid tags must still parse via Essentia without crashing the ingestion worker.
2. **Empty Vector Search Results:** When a prompt specifies mutually exclusive criteria, the DJ must gracefully apologize and suggest alternatives rather than erroring out.
3. **Ollama Timeout / Disconnection:** FastAPI must implement a 15-second timeout on LLM calls with clear error responses.
4. **Duplicate File Re-Scanning:** Subsequent ingestion runs must hash/diff track IDs and skip already indexed audio.
5. **Client Offline State:** `VeloraChatView` must display a clear server connection banner and retry button if the Umbrel engine is unreachable.

---

### Task 1: Qdrant Database & Vector Storage Abstraction Layer

**Files:**
- Create: `AI_Archive/AIEngine/database/vector_store.py`
- Create: `AI_Archive/AIEngine/database/qdrant_store.py`
- Create: `AI_Archive/AIEngine/tests/test_vector_store.py`

**Interfaces:**
- Produces: `MusicVectorStore` (ABC) and `QdrantVectorStore` with methods:
  - `init_collection() -> None`
  - `upsert_track(track_id: str, vector: list[float], payload: dict) -> None`
  - `search_similar(query_vector: list[float], filters: dict | None = None, limit: int = 10) -> list[dict]`
  - `update_telemetry(track_id: str, play_count_delta: int = 0, skip_count_delta: int = 0) -> None`

- [ ] **Step 1: Write the failing test for `QdrantVectorStore`**

```python
import pytest
from database.vector_store import MusicVectorStore
from database.qdrant_store import QdrantVectorStore

def test_qdrant_store_interface_and_mock():
    store = QdrantVectorStore(url="http://localhost:6333", in_memory=True)
    assert isinstance(store, MusicVectorStore)
    store.init_collection()
    sample_vector = [0.1] * 512
    payload = {"title": "Test Song", "artist": "Test Artist", "bpm": 120.0}
    store.upsert_track("tr-1", sample_vector, payload)
    results = store.search_similar(sample_vector, limit=1)
    assert len(results) == 1
    assert results[0]["id"] == "tr-1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_vector_store.py`  
Expected: FAIL with `ModuleNotFoundError` or `ImportError`.

- [ ] **Step 3: Implement `MusicVectorStore` and `QdrantVectorStore`**

Implement `MusicVectorStore` in `AI_Archive/AIEngine/database/vector_store.py` using Python's `abc.ABC`.  
Implement `QdrantVectorStore` in `AI_Archive/AIEngine/database/qdrant_store.py` using `qdrant_client`. Support both in-memory testing (`QdrantClient(":memory:")`) and production remote connection (`http://qdrant:6333`).

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_vector_store.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/database/vector_store.py AI_Archive/AIEngine/database/qdrant_store.py AI_Archive/AIEngine/tests/test_vector_store.py
git commit -m "feat(ai-engine): add QdrantVectorStore with MusicVectorStore abstraction"
```

---

### Task 2: Audio Ingestion & Feature Extraction Worker

**Files:**
- Modify: `AI_Archive/AIEngine/services/audio_processor.py`
- Create: `AI_Archive/AIEngine/tests/test_audio_processor.py`

**Interfaces:**
- Consumes: `QdrantVectorStore.upsert_track(track_id, vector, payload)`
- Produces: `AudioProcessor` with methods:
  - `extract_features(file_path: str) -> dict` (returns `{bpm, key, danceability, energy}`)
  - `generate_audio_embedding(file_path: str) -> list[float]` (returns 512-dim float vector)
  - `process_directory(directory_path: str, vector_store: MusicVectorStore) -> int` (returns number of indexed tracks)

- [ ] **Step 1: Write the failing test for `AudioProcessor`**

```python
import pytest
from services.audio_processor import AudioProcessor
from database.qdrant_store import QdrantVectorStore

def test_audio_processor_mock_extraction(tmp_path):
    processor = AudioProcessor(use_gpu=False, mock_mode=True)
    fake_audio = tmp_path / "sample.mp3"
    fake_audio.write_bytes(b"mock audio bytes")
    features = processor.extract_features(str(fake_audio))
    assert "bpm" in features
    assert "key" in features
    assert "danceability" in features
    embedding = processor.generate_audio_embedding(str(fake_audio))
    assert len(embedding) == 512
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_audio_processor.py`  
Expected: FAIL.

- [ ] **Step 3: Implement `AudioProcessor` in `services/audio_processor.py`**

Wire Essentia feature extractor (RhythmExtractor2013, KeyExtractor, Danceability) with fallback defaults for corrupt tags, and CLAP audio model (`laion/larger_clap_music`) on GPU 1 with a CPU fallback for testing. Support directory scanning of `/Home/Downloads/music` with `.mp3`, `.flac`, `.m4a` extensions.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_audio_processor.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/services/audio_processor.py AI_Archive/AIEngine/tests/test_audio_processor.py
git commit -m "feat(ai-engine): implement AudioProcessor with Essentia and CLAP extraction"
```

---

### Task 3: Conversational DJ RAG Router & Ollama Integration

**Files:**
- Modify: `AI_Archive/AIEngine/services/rag_engine.py`
- Modify: `AI_Archive/AIEngine/api/chat.py`
- Create: `AI_Archive/AIEngine/tests/test_rag_engine.py`

**Interfaces:**
- Consumes: `QdrantVectorStore.search_similar(...)`
- Produces: `ConversationalDJ` with:
  - `generate_query_embedding(prompt: str) -> list[float]`
  - `chat_stream(prompt: str, history: list[dict]) -> AsyncGenerator[str, None]`
  - `parse_action_tokens(text: str) -> list[tuple[str, str]]` (extracts `("PLAY", trackId)`)

- [ ] **Step 1: Write the failing test for RAG prompt and action token parsing**

```python
import pytest
from services.rag_engine import ConversationalDJ

def test_parse_action_tokens():
    dj = ConversationalDJ(ollama_url="http://localhost:11434", mock_mode=True)
    sample_response = "Here is a classic for you! [PLAY: tr-456] And up next: [QUEUE: tr-789]"
    tokens = dj.parse_action_tokens(sample_response)
    assert tokens == [("PLAY", "tr-456"), ("QUEUE", "tr-789")]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_rag_engine.py`  
Expected: FAIL.

- [ ] **Step 3: Implement `ConversationalDJ` in `services/rag_engine.py`**

Implement CLAP text encoding for user query prompts, hybrid vector retrieval against Qdrant, listener preference injection from `Memories/`, and streaming chat queries to Ollama targeting `qwen2.5:14b-instruct-q4_K_M` on GPU 0 with strict system instructions for radio DJ narration and `[PLAY: <id>]` tokens.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_rag_engine.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/services/rag_engine.py AI_Archive/AIEngine/api/chat.py AI_Archive/AIEngine/tests/test_rag_engine.py
git commit -m "feat(ai-engine): add ConversationalDJ RAG engine with Ollama streaming"
```

---

### Task 4: Telemetry Ingestion & Listener Memory Store

**Files:**
- Create: `AI_Archive/AIEngine/api/telemetry.py`
- Modify: `AI_Archive/AIEngine/services/memory_reader.py`
- Create: `AI_Archive/AIEngine/tests/test_telemetry.py`

**Interfaces:**
- Consumes: `QdrantVectorStore.update_telemetry(...)`
- Produces: 
  - `POST /api/telemetry/event` handling `{event_type: "play" | "skip" | "finish", track_id: str, duration_played: float}`
  - `MemoryManager.update_taste_profile(event: dict) -> None`

- [ ] **Step 1: Write the failing test for telemetry ingestion**

```python
import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_telemetry_event_endpoint():
    response = client.post("/api/telemetry/event", json={
        "event_type": "skip",
        "track_id": "tr-100",
        "duration_played": 8.5
    })
    assert response.status_code == 200
    assert response.json()["status"] == "recorded"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest AI_Archive/AIEngine/tests/test_telemetry.py`  
Expected: FAIL with 404 Not Found.

- [ ] **Step 3: Implement Telemetry endpoint and `MemoryManager`**

Implement `POST /api/telemetry/event` in `api/telemetry.py` that increments skip/play counts in Qdrant and writes significant preferences into `Memories/listener_profile.md`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest AI_Archive/AIEngine/tests/test_telemetry.py`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AI_Archive/AIEngine/api/telemetry.py AI_Archive/AIEngine/services/memory_reader.py AI_Archive/AIEngine/tests/test_telemetry.py
git commit -m "feat(ai-engine): implement telemetry ingestion and listener memory store"
```

---

### Task 5: Docker Compose Stack for Umbrel Deployment

**Files:**
- Modify: `AI_Archive/AIEngine/docker-compose.yml`
- Modify: `AI_Archive/AIEngine/Dockerfile`
- Create: `AI_Archive/AIEngine/.env.example`

**Interfaces:**
- Produces: Docker Compose configuration defining:
  - `qdrant`: Official `qdrant/qdrant:latest` with volume `qdrant_data:/qdrant/storage` on port `6333`.
  - `ai-engine`: FastAPI service on port `8000`, volume mount `host_music:/music:ro` pointing to `/Home/Downloads/music`, environment pointing to host Ollama (`http://umbrel.local:11434`).

- [ ] **Step 1: Validate docker-compose file syntax**

```bash
docker compose -f AI_Archive/AIEngine/docker-compose.yml config
```
Expected: Valid compose config output without YAML syntax errors.

- [ ] **Step 2: Configure GPU device reservations in `docker-compose.yml`**

Bind `ai-engine` to GPU 1 (RTX 3060) for audio processing, expose port `8000`, and set `qdrant` as a dependency.

- [ ] **Step 3: Commit**

```bash
git add AI_Archive/AIEngine/docker-compose.yml AI_Archive/AIEngine/Dockerfile AI_Archive/AIEngine/.env.example
git commit -m "chore(ai-engine): configure Docker Compose with Qdrant and Umbrel mounts"
```

---

### Task 6: Velora Swift Client Chat & Playback Integration

**Files:**
- Move: `AI_Archive/VeloraChatView.swift` -> `Sources/App/VeloraChatView.swift`
- Modify: `Sources/App/ContentView.swift`
- Modify: `Sources/App/PlaybackManager.swift`
- Modify: `Sources/App/SettingsView.swift`

**Interfaces:**
- Consumes: FastAPI endpoints (`GET /api/chat`, `POST /api/telemetry/event`)
- Produces:
  - Dedicated AI Chat Tab / Navigation Item in `ContentView.swift`
  - Playback dispatch: `PlaybackManager.shared.playTrack(id: trackId)`
  - Skip / completion telemetry dispatch from `PlaybackManager.swift`

- [ ] **Step 1: Move and compile `VeloraChatView.swift` in `Sources/App/`**

Move `AI_Archive/VeloraChatView.swift` into `Sources/App/VeloraChatView.swift`. Add configurable `aiEngineUrl` reading from `UserDefaults` (default `http://192.168.1.9:8000`).

- [ ] **Step 2: Wire action execution to `PlaybackManager.swift`**

In `VeloraChatView.swift`, when parsing `MessageSegment.playAction(trackId)`:
Fetch track from `DatabaseManager.shared.getTrack(id: trackId)` and trigger `PlaybackManager.shared.playTrack(track)`. For `queueAction`, append track to the current playback queue.

- [ ] **Step 3: Wire telemetry events into `PlaybackManager.swift`**

In `PlaybackManager.swift`, dispatch background async POST requests to `http://<aiEngineUrl>/api/telemetry/event` whenever a track is skipped (if elapsed < 15s) or successfully finishes playing.

- [ ] **Step 4: Integrate `VeloraChatView` into `ContentView.swift`**

Add an AI Studio / Conversational DJ navigation destination in `ContentView.swift`.

- [ ] **Step 5: Verify Swift compilation**

Run: `swift build` (or verify in Xcode/Bitrise).  
Expected: Build succeeds with 0 errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/VeloraChatView.swift Sources/App/ContentView.swift Sources/App/PlaybackManager.swift Sources/App/SettingsView.swift
git commit -m "feat(app): integrate VeloraChatView Conversational DJ and telemetry hooks"
```

---

### Task 7: Offline Dual-GPU Unsloth Fine-Tuning Pipeline (`velora-dj`)

**Files:**
- Create: `AI_Archive/AIEngine/training/train_grpo.py`
- Create: `AI_Archive/AIEngine/training/export_gguf.sh`
- Create: `AI_Archive/AIEngine/training/Modelfile`

**Interfaces:**
- Produces: Standalone training script leveraging combined dual-GPUs (RTX 3080 Ti + RTX 3060, 24 GB VRAM) to fine-tune `qwen2.5:14b` with Unsloth GRPO, and export `velora-dj.gguf` for Ollama.

- [ ] **Step 1: Write `train_grpo.py` using Unsloth**

Configure distributed QLoRA across both CUDA devices (`cuda:0` and `cuda:1`), setting format reward for `[PLAY: <id>]` tokens and acoustic explanation rewards.

- [ ] **Step 2: Write GGUF export and Modelfile script**

Configure `ollama create velora-dj -f Modelfile` with system prompts tailored for the music DJ persona.

- [ ] **Step 3: Commit**

```bash
git add AI_Archive/AIEngine/training/train_grpo.py AI_Archive/AIEngine/training/export_gguf.sh AI_Archive/AIEngine/training/Modelfile
git commit -m "feat(ai-engine): add dual-GPU Unsloth GRPO fine-tuning pipeline for velora-dj"
```
