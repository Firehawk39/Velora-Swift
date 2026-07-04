import logging
import sqlite3
from pathlib import Path
from datetime import datetime
from database.db import get_db_connection
from core.config import settings

logger = logging.getLogger(__name__)

def get_recent_history(limit: int = 5) -> list[dict]:
    """
    Fetches the user's recent listening history from telemetry.
    Use this to understand what the user has been listening to lately or what they just skipped.
    
    Args:
        limit: Number of recent events to return.
        
    Returns:
        A list of dictionaries with event details (event_type, track_id, context, timestamp).
    """
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT event_type, track_id, context, timestamp 
            FROM telemetry 
            ORDER BY timestamp DESC 
            LIMIT ?
            """,
            (limit,)
        )
        rows = cursor.fetchall()
        return [dict(row) for row in rows]
    except Exception as e:
        logger.error(f"Error fetching telemetry history: {e}")
        return []
    finally:
        conn.close()

def search_library(query: str, limit: int = 5) -> list[dict]:
    """
    Searches the user's music library by artist name, track title, or tags.
    Use this when the user asks for a specific song, artist, or album (e.g. "Play Bohemian Rhapsody").
    
    Args:
        query: The search term (e.g., artist name or song title).
        limit: Maximum number of results to return.
        
    Returns:
        A list of track dictionaries including track_id and tags (which usually contains the filename/title).
    """
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        # Using a simple LIKE query on the tags column.
        search_term = f"%{query}%"
        cursor.execute(
            """
            SELECT track_id, tags, bpm, key, danceability 
            FROM tracks 
            WHERE tags LIKE ? 
            LIMIT ?
            """,
            (search_term, limit)
        )
        rows = cursor.fetchall()
        return [dict(row) for row in rows]
    except Exception as e:
        logger.error(f"Error searching library: {e}")
        return []
    finally:
        conn.close()

def update_memory(preference: str) -> str:
    """
    Saves a new user preference to the AI's long-term memory (Obsidian vault).
    Use this when the user explicitly states they like or dislike something, or want you to remember a fact.
    
    Args:
        preference: A clear, concise statement of the user's preference (e.g., "User strongly dislikes Country music").
        
    Returns:
        A confirmation string.
    """
    user_mem_dir = settings.MEMORIES_DIR / "User"
    user_mem_dir.mkdir(parents=True, exist_ok=True)
    
    prefs_file = user_mem_dir / "Listening_Preferences.md"
    
    try:
        with open(prefs_file, "a", encoding="utf-8") as f:
            f.write(f"- {preference} (Added {datetime.now().strftime('%Y-%m-%d')})\n")
        return f"Successfully saved preference: {preference}"
    except Exception as e:
        logger.error(f"Error updating memory: {e}")
        return f"Failed to save preference: {e}"
