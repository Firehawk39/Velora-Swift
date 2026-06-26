import logging
import struct
from database.db import get_db_connection, VEC_AVAILABLE

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
            
            # Depending on transformers version, this might return a tensor, or a BaseModelOutput
            if hasattr(text_features, "text_embeds") and text_features.text_embeds is not None:
                text_features = text_features.text_embeds
            elif hasattr(text_features, "pooler_output") and text_features.pooler_output is not None:
                text_features = text_features.pooler_output
            elif isinstance(text_features, tuple):
                text_features = text_features[0]
                
            # If it hasn't been projected yet (e.g. shape is 768 instead of 512)
            if hasattr(processor.model, "text_projection") and text_features.shape[-1] != 512:
                text_features = processor.model.text_projection(text_features)
            
        embedding = torch.nn.functional.normalize(text_features, p=2, dim=1)
        return embedding[0].cpu().tolist()
    except Exception as e:
        logger.error(f"Text embedding generation failed: {e}")
        return [0.0] * 512

def perform_vector_search(query: str, limit: int = 3) -> list:
    """
    Searches the user's music library for tracks that sound similar to the text query.
    Use this tool when the user asks for music recommendations, specific genres, or vibes.
    
    Args:
        query: A descriptive string of the music the user wants (e.g. "upbeat electronic").
        limit: The number of tracks to return. Defaults to 3.
        
    Returns:
        A list of dictionaries containing the best matching tracks, including track_id, bpm, and key.
        When recommending these tracks, you can seamlessly include them in your conversation.
        If you want to play a track, output [PLAY: track_id] exactly.
    """
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
            WHERE embedding MATCH ? AND k = ?
            ORDER BY distance
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
