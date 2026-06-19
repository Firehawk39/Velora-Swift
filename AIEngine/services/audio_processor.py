import logging
import json
import struct
import librosa
from pathlib import Path
from database.db import get_db_connection

# Conditional imports for heavy ML libraries to prevent crashes if they aren't installed yet
try:
    import essentia.standard as es
    import torch
    import torchaudio
    from transformers import AutoProcessor, ClapModel
    ML_AVAILABLE = True
except ImportError:
    ML_AVAILABLE = False
    logging.warning("Heavy ML dependencies (torch, transformers, essentia) are not fully installed.")

logger = logging.getLogger(__name__)

class AudioProcessor:
    def __init__(self):
        self.model = None
        self.processor = None
        self._load_models()

    def _load_models(self):
        """Lazy load the heavy CLAP model into VRAM."""
        if not ML_AVAILABLE:
            logger.warning("Skipping model load due to missing dependencies.")
            return

        try:
            # We use laion/clap-htsat-unfused as the default CLAP model
            model_id = "laion/clap-htsat-unfused"
            self.processor = AutoProcessor.from_pretrained(model_id)
            self.model = ClapModel.from_pretrained(model_id)
            
            # Move to GPU if available
            self.device = "cuda" if torch.cuda.is_available() else "cpu"
            self.model.to(self.device)
            logger.info(f"CLAP model loaded on {self.device}")
        except Exception as e:
            logger.error(f"Failed to load CLAP model: {e}")

    def extract_features(self, file_path: str):
        """Extract BPM and Key using Essentia."""
        if not ML_AVAILABLE:
            return 120.0, "C"

        try:
            # Load audio
            audio = es.MonoLoader(filename=file_path)()
            
            # Extract BPM
            rhythm_extractor = es.RhythmExtractor2013(method="multifeature")
            bpm, _, _, _, _ = rhythm_extractor(audio)
            
            # Extract Key
            key_extractor = es.KeyExtractor()
            key, scale, strength = key_extractor(audio)
            
            return bpm, f"{key} {scale}"
        except Exception as e:
            logger.error(f"Essentia extraction failed: {e}")
            return 0.0, "Unknown"

    def generate_embedding(self, file_path: str) -> list:
        """Generate a 512-dimensional CLAP embedding for the track."""
        if not ML_AVAILABLE or not self.model:
            return [0.0] * 512

        try:
            # Load audio using librosa (CLAP expects 48kHz)
            y, sr = librosa.load(file_path, sr=48000)
            
            # Process inputs
            inputs = self.processor(audios=y, sampling_rate=sr, return_tensors="pt")
            inputs = {k: v.to(self.device) for k, v in inputs.items()}
            
            # Generate embedding
            with torch.no_grad():
                outputs = self.model.get_audio_features(**inputs)
                
            # Normalize and convert to list for SQLite storage
            embedding = torch.nn.functional.normalize(outputs, p=2, dim=1)
            return embedding[0].cpu().tolist()
        except Exception as e:
            logger.error(f"Embedding generation failed: {e}")
            return [0.0] * 512

def process_track(track_id: str, file_path: str):
    """
    Background worker function to process a track and save it to the database.
    """
    logger.info(f"Starting analysis for track: {track_id}")
    
    processor = AudioProcessor()
    
    bpm, key = processor.extract_features(file_path)
    embedding = processor.generate_embedding(file_path)
    
    # Save to database
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # Serialize the 512D float array into a binary BLOB for sqlite-vec
        embedding_bytes = struct.pack(f"{len(embedding)}f", *embedding)
        
        # 1. Update standard tracks table
        cursor.execute(
            """
            INSERT INTO tracks (track_id, bpm, key, embedding)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                bpm=excluded.bpm,
                key=excluded.key,
                embedding=excluded.embedding
            """,
            (track_id, bpm, key, embedding_bytes)
        )
        
        # 2. Update vec_tracks virtual table for vector search
        try:
            # Remove old vector if it exists to avoid conflicts
            cursor.execute("DELETE FROM vec_tracks WHERE track_id = ?", (track_id,))
            cursor.execute(
                """
                INSERT INTO vec_tracks (track_id, embedding)
                VALUES (?, ?)
                """,
                (track_id, embedding_bytes)
            )
        except Exception as e:
            logger.error(f"Failed to insert into vec_tracks (is sqlite-vec active?): {e}")
            
        conn.commit()
        logger.info(f"Track {track_id} successfully processed and saved.")
    except Exception as e:
        conn.rollback()
        logger.error(f"Failed to save track {track_id} to database: {e}")
    finally:
        conn.close()
