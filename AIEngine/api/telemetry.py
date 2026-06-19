from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from typing import Optional
import json
from database.db import get_db_connection

router = APIRouter()

class TelemetryEvent(BaseModel):
    event_type: str  # e.g., "play", "pause", "skip"
    track_id: Optional[str] = None
    context: Optional[dict] = None  # Extra JSON data like position, volume, etc.

@router.post("/event", status_code=201)
async def record_event(event: TelemetryEvent):
    """
    Record a playback telemetry event from the Swift client.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    
    context_str = json.dumps(event.context) if event.context else None
    
    try:
        cursor.execute(
            "INSERT INTO telemetry (event_type, track_id, context) VALUES (?, ?, ?)",
            (event.event_type, event.track_id, context_str)
        )
        conn.commit()
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")
    finally:
        conn.close()
        
    return {"status": "success", "message": f"Event '{event.event_type}' recorded"}
