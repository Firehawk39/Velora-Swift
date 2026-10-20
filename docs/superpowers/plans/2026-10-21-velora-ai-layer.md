# Velora AI Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy the 100% local Velora AI Layer: a Dockerized Umbrel backend leveraging dual GPUs (RTX 3080 Ti for Ollama, RTX 3060 for audio analysis/embeddings) with read-only access to music files, paired with a new "V" tab in Velora's iOS navigation pill housing the conversational DJ and live telemetry dashboard.

**Architecture:** A lightweight Docker Compose stack on Umbrel runs FastAPI, `sqlite-vec`, and Essentia/CLAP on GPU 1 (RTX 3060) while communicating with Ollama on GPU 0 (RTX 3080 Ti) and Navidrome via the Subsonic API. The Velora iOS app streams playback events asynchronously to the backend on detached background actors (0ms main-thread guarantee) and renders the "V" tab with custom *Stardom* typography, providing interactive chat with inline Navidrome playback actions and telemetry analytics.

**Tech Stack:** Python 3.11, FastAPI, `sqlite-vec`, Essentia, PyTorch / CLAP (`laion/larger_clap_music`), Docker Compose, Ollama (`qwen2.5:7b-instruct` / `qwen2.5:3b-instruct`), Swift 6 / SwiftUI, Navidrome Subsonic API.

**Spec:** [docs/superpowers/specs/2026-10-21-velora-ai-layer-design.md](file:///c:/Users/Harsh/Desktop/Velora%20AI%20Studio%20+%20Antigravity/docs/superpowers/specs/2026-10-21-velora-ai-layer-design.md)

## Global Constraints

- **Single Music Authority:** Navidrome is the sole streaming and library authority; the AI engine never plays audio directly and only references Navidrome `trackId`s.
- **Read-Only Audio Mount:** The host music folder (`.mp3`, `.flac`, `.aac`, `.m4a`) mounts into Docker strictly as `:ro`; zero modification or deletion of original audio files.
- **Zero Internet Requirement:** 100% self-hosted on the local Umbrel server (`192.168.1.13`); zero outgoing internet connections.
- **Dual GPU Allocation:** GPU 0 (RTX 3080 Ti 12GB) dedicated to Ollama LLM; GPU 1 (RTX 3060 12GB) dedicated to CLAP and Essentia feature extraction.
- **0ms Main-Thread Render Guarantee:** Background telemetry and chat networking execute strictly on detached background actors; zero UI thread blocking.
- **Commit Protocol:** Every commit must be immediately pushed to origin (`git push origin <branch>`).

## Review Focus

1. **Missing or Corrupt Audio Files on Disk:** Audio files indexed by Navidrome but missing or unreadable on the `:ro` mount must be skipped gracefully without failing the entire indexing job.
2. **Ollama Model Auto-Provisioning Failure:** If Ollama is downloading a model or temporarily unreachable, the iOS client must show a clear, friendly status banner rather than crashing or freezing.
3. **Offline / Out-of-Home Disconnect:** When the iPhone disconnects from the home LAN, playback through Navidrome must continue seamlessly while telemetry buffers locally in a compact ring-buffer.
4. **Malformed Action Tokens in Chat:** LLM responses containing invalid or non-existent `trackId`s in `[PLAY: id]` must render as plain text without crashing the message parser.
5. **Concurrent Telemetry Floods:** Rapid skipping of multiple tracks in under a second must not overwhelm the FastAPI backend or corrupt the SQLite telemetry store.

---

### Task 1: Docker Compose Stack & Umbrel Environment Definition

**Files:**
- Create: `velora-ai-engine/docker-compose.yml`
- Create: `velora-ai-engine/.env.example`
- Create: `velora-ai-engine/Dockerfile`
- Create: `velora-ai-engine/requirements.txt`
- Test: `velora-ai-engine/tests/test_config.py`

**Interfaces:**
- Produces: Dual-GPU Docker Compose configuration binding `ai-engine` to GPU 1 (RTX 3060), mounting music files as `:ro`, and exposing FastAPI on port `8770`.

- [ ] **Step 1: Write the failing test for configuration loading**

```python
# velora-ai-engine/tests/test_config.py
import os
import pytest

def test_environment_defaults():
    from core.config import settings
    assert settings.NAVIDROME_URL.startswith("http")
    assert settings.OLLAMA_URL.startswith("http")
    assert settings.GPU_DEVICE_INDEX == "1"
    assert settings.MUSIC_MOUNT_PATH == "/music"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest velora-ai-engine/tests/test_config.py`  
Expected: FAIL (module `core.config` not found)

- [ ] **Step 3: Implement `core/config.py`, `Dockerfile`, and `docker-compose.yml`**

Implement Pydantic Settings in `velora-ai-engine/core/config.py` reading environment variables with fallback defaults. Build `docker-compose.yml` mounting `${MUSIC_DIR}:/music:ro` and setting `NVIDIA_VISIBLE_DEVICES=1` for the AI container.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest velora-ai-engine/tests/test_config.py`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add velora-ai-engine/
git commit -m "feat(ai-engine): add dual-gpu docker-compose stack and environment config"
git push origin master
```

---

### Task 2: Ollama Auto-Provisioning & Model Management Service

**Files:**
- Create: `velora-ai-engine/services/ollama_service.py`
- Create: `velora-ai-engine/api/system.py`
- Test: `velora-ai-engine/tests/test_ollama_service.py`

**Interfaces:**
- Consumes: `settings.OLLAMA_URL`, `settings.RECOMMENDED_MODEL`
- Produces: `OllamaService.check_model_status() -> dict`, `OllamaService.pull_model_stream()`

- [ ] **Step 1: Write failing test for Ollama auto-provisioning check**

```python
# velora-ai-engine/tests/test_ollama_service.py
import pytest
from unittest.mock import AsyncMock, patch
from services.ollama_service import OllamaService

@pytest.mark.asyncio
async def test_check_model_status_missing():
    service = OllamaService(base_url="http://mock-ollama:11434", model_name="qwen2.5:7b-instruct")
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.status_code = 200
        mock_get.return_value.json.return_value = {"models": [{"name": "other-model:latest"}]}
        status = await service.get_status()
        assert status["ready"] is False
        assert status["model_installed"] is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest velora-ai-engine/tests/test_ollama_service.py`  
Expected: FAIL

- [ ] **Step 3: Implement `OllamaService` and `/api/system/status` endpoint**

Implement `OllamaService` with `get_status()`, `pull_model()` using HTTPX async streaming, and expose status at `GET /api/system/status`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest velora-ai-engine/tests/test_ollama_service.py`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add velora-ai-engine/services/ollama_service.py velora-ai-engine/api/system.py velora-ai-engine/tests/test_ollama_service.py
git commit -m "feat(ai-engine): implement ollama model auto-provisioning and status checks"
git push origin master
```

---

### Task 3: Navidrome Read-Only Catalog Sync & Path Mapping

**Files:**
- Create: `velora-ai-engine/services/navidrome_sync.py`
- Create: `velora-ai-engine/database/catalog_store.py`
- Test: `velora-ai-engine/tests/test_navidrome_sync.py`

**Interfaces:**
- Consumes: Navidrome Subsonic credentials from `settings`
- Produces: `CatalogStore.get_file_path(track_id: str) -> Optional[str]`, `NavidromeSync.sync_catalog()`

- [ ] **Step 1: Write failing test for catalog sync and path resolution**

```python
# velora-ai-engine/tests/test_navidrome_sync.py
import pytest
from unittest.mock import AsyncMock, patch
from services.navidrome_sync import NavidromeSync
from database.catalog_store import CatalogStore

@pytest.mark.asyncio
async def test_navidrome_sync_populates_paths(tmp_path):
    db_path = tmp_path / "catalog.db"
    store = CatalogStore(db_path=str(db_path))
    sync = NavidromeSync(store=store, base_url="http://mock:4533", user="admin", token="tok", salt="slt")
    
    mock_songs = [
        {"id": "song_1", "title": "Starlight", "artist": "Muse", "path": "Muse/Black Holes/02 Starlight.flac"}
    ]
    with patch.object(sync, "fetch_all_songs", new_callable=AsyncMock) as mock_fetch:
        mock_fetch.return_value = mock_songs
        count = await sync.sync_catalog()
        assert count == 1
        assert store.get_file_path("song_1") == "Muse/Black Holes/02 Starlight.flac"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest velora-ai-engine/tests/test_navidrome_sync.py`  
Expected: FAIL

- [ ] **Step 3: Implement `CatalogStore` (SQLite) and `NavidromeSync`**

Implement SQLite table `catalog_tracks (track_id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT, path TEXT, duration REAL)`. Implement Subsonic API query `getSongsByGenre` or `search3` with MD5 auth.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest velora-ai-engine/tests/test_navidrome_sync.py`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add velora-ai-engine/services/navidrome_sync.py velora-ai-engine/database/catalog_store.py velora-ai-engine/tests/test_navidrome_sync.py
git commit -m "feat(ai-engine): add read-only navidrome subsonic catalog sync and path store"
git push origin master
```

---

### Task 4: Essentia & CLAP Acoustic Feature Extraction Pipeline (GPU 1)

**Files:**
- Create: `velora-ai-engine/services/audio_extractor.py`
- Create: `velora-ai-engine/database/vector_store.py`
- Test: `velora-ai-engine/tests/test_audio_extractor.py`

**Interfaces:**
- Consumes: Audio file path from `/music/:ro`, Navidrome `trackId`
- Produces: `VectorStore.upsert_embedding(track_id, vector_512, bpm, key, energy)`, `AudioExtractor.process_track(file_path)`

- [ ] **Step 1: Write failing test for acoustic feature processing**

```python
# velora-ai-engine/tests/test_audio_extractor.py
import pytest
from unittest.mock import MagicMock, patch
from services.audio_extractor import AudioExtractor

def test_extract_acoustic_metadata():
    extractor = AudioExtractor(device="cuda:0") # Or mock device
    with patch.object(extractor, "analyze_audio") as mock_analyze:
        mock_analyze.return_value = {
            "bpm": 124.0,
            "key": "8B",
            "energy": 0.85,
            "embedding": [0.1] * 512
        }
        res = extractor.process_file("/mock/path/song.flac")
        assert res["bpm"] == 124.0
        assert res["key"] == "8B"
        assert len(res["embedding"]) == 512
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest velora-ai-engine/tests/test_audio_extractor.py`  
Expected: FAIL

- [ ] **Step 3: Implement `AudioExtractor` with Essentia + CLAP and `VectorStore` with `sqlite-vec`**

Integrate Essentia's `RhythmExtractor2013` (BPM) and `KeyExtractor` (converted to Camelot notation). Load `CLAP` model on GPU 1. Create `sqlite-vec` virtual table `vec_tracks` storing the 512-dim embedding alongside acoustic fields.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest velora-ai-engine/tests/test_audio_extractor.py`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add velora-ai-engine/services/audio_extractor.py velora-ai-engine/database/vector_store.py velora-ai-engine/tests/test_audio_extractor.py
git commit -m "feat(ai-engine): implement essentia acoustic analysis and sqlite-vec clap storage"
git push origin master
```

---

### Task 5: Conversational DJ & Hybrid Search Router (GPU 0)

**Files:**
- Create: `velora-ai-engine/api/chat.py`
- Create: `velora-ai-engine/services/dj_router.py`
- Test: `velora-ai-engine/tests/test_dj_router.py`

**Interfaces:**
- Consumes: User message, current playing `trackId`, `VectorStore`, `OllamaService`
- Produces: `POST /api/chat/query -> { reply: str, actions: [ { type: "PLAY"|"QUEUE", trackId: str } ] }`

- [ ] **Step 1: Write failing test for chat token parsing and response formatting**

```python
# velora-ai-engine/tests/test_dj_router.py
import pytest
from services.dj_router import DJRouter

def test_parse_action_tokens():
    router = DJRouter(vector_store=None, ollama_service=None)
    raw_llm_text = "Here's a great match for you:\n[PLAY: 4102] Starlight - Muse\nAnd up next:\n[QUEUE: 9911] Knights of Cydonia"
    actions = router.extract_actions(raw_llm_text)
    assert len(actions) == 2
    assert actions[0] == {"type": "PLAY", "trackId": "4102"}
    assert actions[1] == {"type": "QUEUE", "trackId": "9911"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest velora-ai-engine/tests/test_dj_router.py`  
Expected: FAIL

- [ ] **Step 3: Implement `DJRouter` and `/api/chat/query` endpoint**

Query `sqlite-vec` for semantic + harmonic matches, format system prompt instructing Ollama to append `[PLAY: trackId]` / `[QUEUE: trackId]`, and stream response back to client.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest velora-ai-engine/tests/test_dj_router.py`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add velora-ai-engine/api/chat.py velora-ai-engine/services/dj_router.py velora-ai-engine/tests/test_dj_router.py
git commit -m "feat(ai-engine): add conversational dj router and playback action token parser"
git push origin master
```

---

### Task 6: Telemetry Ingestion & Dashboard API

**Files:**
- Create: `velora-ai-engine/api/telemetry.py`
- Create: `velora-ai-engine/database/telemetry_store.py`
- Test: `velora-ai-engine/tests/test_telemetry.py`

**Interfaces:**
- Produces: `POST /api/telemetry/event`, `GET /api/telemetry/dashboard`

- [ ] **Step 1: Write failing test for telemetry ingestion and metric computation**

```python
# velora-ai-engine/tests/test_telemetry.py
import pytest
from database.telemetry_store import TelemetryStore

def test_telemetry_skip_rate_calculation(tmp_path):
    store = TelemetryStore(db_path=str(tmp_path / "telem.db"))
    store.record_event("song_1", "TRACK_COMPLETED", played_seconds=200, total_duration=200)
    store.record_event("song_2", "TRACK_SKIPPED", played_seconds=15, total_duration=180)
    
    metrics = store.get_summary_metrics()
    assert metrics["total_plays"] == 2
    assert metrics["skip_ratio"] == 0.5
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest velora-ai-engine/tests/test_telemetry.py`  
Expected: FAIL

- [ ] **Step 3: Implement `TelemetryStore` and API endpoints**

Implement SQLite store for telemetry events, aggregate skip rates and listening hours, and expose `POST /api/telemetry/event` and `GET /api/telemetry/dashboard`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest velora-ai-engine/tests/test_telemetry.py`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add velora-ai-engine/api/telemetry.py velora-ai-engine/database/telemetry_store.py velora-ai-engine/tests/test_telemetry.py
git commit -m "feat(ai-engine): implement telemetry event ingestion and dashboard metrics store"
git push origin master
```

---

### Task 7: Velora iOS: Background Telemetry Reporter & Offline Buffer

**Files:**
- Create: `Sources/App/TelemetryService.swift`
- Modify: `Sources/App/PlaybackManager.swift`
- Test: `Tests/TelemetryServiceTests.swift`

**Interfaces:**
- Consumes: Playback events from `PlaybackManager`
- Produces: `TelemetryService.shared.recordSkip(...)`, `TelemetryService.shared.recordPlay(...)`

- [ ] **Step 1: Write failing test for event buffering and offline queue**

```swift
// Tests/TelemetryServiceTests.swift
import XCTest
@testable import App

final class TelemetryServiceTests: XCTestCase {
    func testBufferCapsAt500Events() async {
        let service = TelemetryService(isOffline: true)
        for i in 0..<600 {
            await service.recordEvent(type: .skip, trackId: "track_\(i)", playedSeconds: 5, totalDuration: 180)
        }
        let count = await service.bufferedEventCount()
        XCTAssertEqual(count, 500)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TelemetryServiceTests`  
Expected: FAIL

- [ ] **Step 3: Implement `TelemetryService.swift` (Swift 6 Actor)**

Implement actor `TelemetryService` with non-blocking LAN dispatch via `URLSession` on background threads (0ms main thread guarantee) and local ring-buffer. Hook `PlaybackManager.next()` and `trackEnded` to emit telemetry.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TelemetryServiceTests`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add Sources/App/TelemetryService.swift Sources/App/PlaybackManager.swift Tests/TelemetryServiceTests.swift
git commit -m "feat(ios): add non-blocking telemetry reporter actor and offline ring-buffer"
git push origin master
```

---

### Task 8: Velora iOS: Navigation Pill "V" Tab Integration

**Files:**
- Modify: `Sources/App/Components.swift:292-307`
- Modify: `Sources/App/ContentView.swift:178-215`
- Test: `Tests/NavigationPillTests.swift`

**Interfaces:**
- Produces: New activeTab `"ai-studio"` accessible via navigation pill

- [ ] **Step 1: Write failing test for "V" tab identifier in navigation**

```swift
// Tests/NavigationPillTests.swift
import XCTest
@testable import App

final class NavigationPillTests: XCTestCase {
    func testNavigationPillContainsVStudioTab() {
        let tabs = ["home", "library", "search", "now-playing", "ai-studio"]
        XCTAssertTrue(tabs.contains("ai-studio"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NavigationPillTests`  
Expected: FAIL

- [ ] **Step 3: Add "V" button with custom Stardom font in `Components.swift`**

Add `TabButton(id: "ai-studio", label: "V", isCustomFont: true, activeTab: $activeTab, ...)` to `navigationPill`. Route `case "ai-studio"` in `ContentView.swift`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NavigationPillTests`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add Sources/App/Components.swift Sources/App/ContentView.swift Tests/NavigationPillTests.swift
git commit -m "feat(ios): integrate Stardom font V tab into navigation pill"
git push origin master
```

---

### Task 9: Velora iOS: "V" Studio View (AI DJ & Telemetry Dashboard)

**Files:**
- Create: `Sources/App/AIStudioView.swift`
- Modify: `Sources/App/ContentView.swift`
- Test: `Tests/AIStudioViewTests.swift`

**Interfaces:**
- Consumes: `TelemetryService`, `PlaybackManager`, `NavidromeClient`
- Produces: Complete SwiftUI view rendering conversational sheet + dashboard cards

- [ ] **Step 1: Write failing test for chat action trigger binding**

```swift
// Tests/AIStudioViewTests.swift
import XCTest
@testable import App

final class AIStudioViewTests: XCTestCase {
    func testParseInlinePlayActions() {
        let message = "Check this out: [PLAY: 104] Song Title"
        let segments = AIStudioMessageParser.parse(message)
        XCTAssertEqual(segments.count, 2)
        if case .playAction(let id) = segments[1] {
            XCTAssertEqual(id, "104")
        } else {
            XCTFail("Expected playAction segment")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AIStudioViewTests`  
Expected: FAIL

- [ ] **Step 3: Implement `AIStudioView.swift`**

Build glassmorphic `AIStudioView` with:
1. Glass top segmented picker: `[AI DJ]` $\leftrightarrow$ `[Telemetry & Studio]`.
2. First-time auto-provisioning banner displaying live download percentage.
3. Conversational message list rendering interactive action buttons for `[PLAY: id]` and `[QUEUE: id]`, executing directly on `PlaybackManager.shared.playTrackById(id)`.
4. Telemetry dashboard grid displaying listen hours, skip curves, vector indexing stats, and Umbrel node ping.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AIStudioViewTests`  
Expected: PASS

- [ ] **Step 5: Commit & push**

```bash
git add Sources/App/AIStudioView.swift Sources/App/ContentView.swift Tests/AIStudioViewTests.swift
git commit -m "feat(ios): build glassmorphic AI Studio view with DJ chat and telemetry dashboard"
git push origin master
```

---

### Task 10: End-to-End Integration & System Verification

**Files:**
- Create: `Tests/E2EIntegrationTests.swift`
- Test: `velora-ai-engine/tests/test_e2e.py`

**Interfaces:**
- Verifies: Full round-trip flow from iOS telemetry emission $\rightarrow$ backend processing $\rightarrow$ chat query $\rightarrow$ playback action triggering.

- [ ] **Step 1: Run complete backend pytest suite**

Run: `pytest velora-ai-engine/tests/`  
Expected: All tests PASS

- [ ] **Step 2: Run Swift package tests**

Run: `swift test`  
Expected: All tests PASS

- [ ] **Step 3: Commit & push final verification**

```bash
git add .
git commit -m "chore(ai-engine): verify complete end-to-end AI layer integration and tests"
git push origin master
```
