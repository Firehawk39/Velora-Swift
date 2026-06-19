import logging
import struct
from typing import AsyncGenerator
from database.db import get_db_connection, VEC_AVAILABLE
from services.ollama_client import generate_chat_stream

try:
    from services.audio_processor import AudioProcessor, ML_AVAILABLE
    import torch
except ImportError:
    ML_AVAILABLE = False

logger = logging.getLogger(__name__)

# Global processor instance so we don't reload the 2GB model on every chat
_processor = None

def get_text_embedding(text: str) -> list:
    global _processor
    if not ML_AVAILABLE:
        return [0.0] * 512
        
    if _processor is None:
        _processor = AudioProcessor()
        
    if not _processor.model:
        return [0.0] * 512
        
    try:
        inputs = _processor.processor(text=text, return_tensors="pt", padding=True)
        inputs = {k: v.to(_processor.device) for k, v in inputs.items()}
        
        with torch.no_grad():
            text_features = _processor.model.get_text_features(**inputs)
            
        embedding = torch.nn.functional.normalize(text_features, p=2, dim=1)
        return embedding[0].cpu().tolist()
    except Exception as e:
        logger.error(f"Text embedding generation failed: {e}")
        return [0.0] * 512

def perform_vector_search(query: str, limit: int = 3) -> list:
    if not VEC_AVAILABLE:
        return []
        
    embedding = get_text_embedding(query)
    embedding_bytes = struct.pack(f"{len(embedding)}f", *embedding)
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        cursor.execute(
            """
            SELECT track_id, distance
            FROM vec_tracks
            WHERE embedding MATCH ?
            ORDER BY distance
            LIMIT ?
            """,
            (embedding_bytes, limit)
        )
        
        results = cursor.fetchall()
        
        # Hydrate with metadata from the standard tracks table
        hydrated_results = []
        for row in results:
            track_id = row['track_id']
            distance = row['distance']
            
            cursor.execute("SELECT bpm, key FROM tracks WHERE track_id = ?", (track_id,))
            meta = cursor.fetchone()
            
            if meta:
                hydrated_results.append({
                    "track_id": track_id,
                    "bpm": meta['bpm'],
                    "key": meta['key'],
                    "distance": distance
                })
        
        return hydrated_results
    except Exception as e:
        logger.error(f"Vector search failed: {e}")
        return []
    finally:
        conn.close()

async def perform_rag_and_generate(prompt: str, context: str | None, system_prompt: str) -> AsyncGenerator[str, None]:
    """
    1. Embeds the user's prompt (and context).
    2. Searches sqlite-vec for similar tracks.
    3. Injects the results into the system prompt.
    4. Calls Ollama.
    """
    
    search_query = prompt
    if context:
        search_query += f" (Context: {context})"
        
    logger.info(f"Performing vector RAG for query: {search_query}")
    results = perform_vector_search(search_query)
    
    rag_context = ""
    if results:
        rag_context = "\n\n[SYSTEM VECTOR DB RESULTS]\nHere are the closest matching tracks in the user's library right now:\n"
        for r in results:
            rag_context += f"- Track ID: {r['track_id']} | BPM: {r['bpm']:.1f} | Key: {r['key']} (Distance: {r['distance']:.4f})\n"
        
        rag_context += "\nYou can seamlessly recommend these tracks in your conversation based on the user's request. Do not expose the raw Track ID or Distance numbers to the user; just mention the songs casually."
        
    augmented_system_prompt = system_prompt + rag_context
    
    async for chunk in generate_chat_stream(prompt, augmented_system_prompt):
        yield chunk
