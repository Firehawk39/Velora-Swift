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
# We now use the singleton from audio_processor

def get_text_embedding(text: str) -> list:
    if not ML_AVAILABLE:
        return [0.0] * 512
        
    try:
        from services.audio_processor import get_audio_processor
        processor = get_audio_processor()
    except Exception as e:
        logger.error(f"Failed to load audio processor: {e}")
        return [0.0] * 512
        
    if not processor.model:
        return [0.0] * 512
        
    try:
        inputs = processor.processor(text=text, return_tensors="pt", padding=True)
        inputs = {k: v.to(processor.device) for k, v in inputs.items()}
        
        with torch.no_grad():
            text_features = processor.model.get_text_features(**inputs)
            
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
        # Fetch more candidates to rerank
        cursor.execute(
            """
            SELECT track_id, distance
            FROM vec_tracks
            WHERE embedding MATCH ?
            ORDER BY distance
            LIMIT ?
            """,
            (embedding_bytes, limit * 5)
        )
        
        vec_results = cursor.fetchall()
        
        # Hydrate with metadata and perform 60/40 Hybrid Weighting
        candidates = []
        for row in vec_results:
            track_id = row['track_id']
            distance = row['distance']
            
            cursor.execute("SELECT bpm, key, tags FROM tracks WHERE track_id = ?", (track_id,))
            meta = cursor.fetchone()
            
            if meta:
                tags = meta['tags'] or ""
                
                # Basic text matching for the 40% manual tag score
                tag_score = 0.0
                query_words = query.lower().split()
                tags_lower = tags.lower()
                
                matches = sum(1 for w in query_words if len(w) > 3 and w in tags_lower)
                if matches > 0:
                    tag_score = min(1.0, matches * 0.5)
                    
                # Normalize vector distance (0 to 2 for cosine/L2 typically) into a 0 to 1 score where 1 is best
                vector_score = max(0.0, 1.0 - (distance / 2.0))
                
                # 60/40 Hybrid Weighting formula
                final_score = (0.6 * vector_score) + (0.4 * tag_score)
                
                candidates.append({
                    "track_id": track_id,
                    "bpm": meta['bpm'],
                    "key": meta['key'],
                    "tags": tags,
                    "distance": distance,  # raw vector distance for debug/context
                    "final_score": final_score
                })
        
        # Sort by final hybrid score descending
        candidates.sort(key=lambda x: x['final_score'], reverse=True)
        return candidates[:limit]
    except Exception as e:
        logger.error(f"Vector search failed: {e}")
        return []
    finally:
        conn.close()

async def perform_rag_and_generate(messages: list[dict], context: str | None, system_prompt: str) -> AsyncGenerator[str, None]:
    """
    1. Embeds the user's latest prompt (and context).
    2. Searches sqlite-vec for similar tracks.
    3. Injects the results into the system prompt.
    4. Calls Ollama with the full conversation history.
    """
    
    # Extract the latest user message for vector search
    latest_user_msg = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            latest_user_msg = msg.get("content", "")
            break
            
    search_query = latest_user_msg
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
    
    async for chunk in generate_chat_stream(messages, augmented_system_prompt):
        yield chunk
