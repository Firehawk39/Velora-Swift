from fastapi import APIRouter, BackgroundTasks, HTTPException
from pydantic import BaseModel
import os
from services.audio_processor import process_track

router = APIRouter()

class ScanRequest(BaseModel):
    track_id: str
    file_path: str

@router.post("/scan", status_code=202)
async def scan_track(request: ScanRequest, background_tasks: BackgroundTasks):
    """
    Trigger a background task to analyze a track's audio and save its embeddings.
    """
    # Basic validation (In production, this might be a URL to Navidrome instead of a local path)
    if not os.path.exists(request.file_path):
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")
        
    # Kick off the heavy ML task in the background
    background_tasks.add_task(process_track, request.track_id, request.file_path)
    
    return {
        "status": "accepted",
        "message": f"Track {request.track_id} added to processing queue.",
        "track_id": request.track_id
    }
