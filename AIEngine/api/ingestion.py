from fastapi import APIRouter, BackgroundTasks, HTTPException
from pydantic import BaseModel
import os
import hashlib
from services.audio_processor import process_track
from database.db import get_db_connection

router = APIRouter()

class ScanRequest(BaseModel):
    track_id: str
    file_path: str

MUSIC_DIR = "/music"

@router.post("/scan", status_code=202)
async def scan_track(request: ScanRequest, background_tasks: BackgroundTasks):
    """
    Trigger a background task to analyze a single track's audio.
    """
    if not os.path.exists(request.file_path):
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")
        
    tags = getattr(request, 'tags', "")
    background_tasks.add_task(process_track, request.track_id, request.file_path, tags)
    
    return {
        "status": "accepted",
        "message": f"Track {request.track_id} added to processing queue.",
        "track_id": request.track_id
    }

@router.post("/scan_all", status_code=202)
async def scan_all_tracks(background_tasks: BackgroundTasks):
    """
    Scan the entire /music folder, find unprocessed tracks, and queue them.
    """
    if not os.path.exists(MUSIC_DIR):
        raise HTTPException(status_code=404, detail=f"Music directory not found: {MUSIC_DIR}")
        
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT track_id FROM tracks")
    existing_ids = set(row[0] for row in cursor.fetchall())
    conn.close()
    
    queued_count = 0
    supported_exts = {'.mp3', '.flac', '.wav', '.m4a', '.ogg'}
    
    for root, _, files in os.walk(MUSIC_DIR):
        for file in files:
            ext = os.path.splitext(file)[1].lower()
            if ext in supported_exts:
                file_path = os.path.join(root, file)
                
                # Generate a stable pseudo-track-id based on the path
                track_id = hashlib.md5(file_path.encode('utf-8')).hexdigest()[:16]
                
                if track_id not in existing_ids:
                    # Use filename as fallback tags so AI knows the song name
                    tags = os.path.basename(file_path)
                    background_tasks.add_task(process_track, track_id, file_path, tags)
                    queued_count += 1
                    
    return {
        "status": "accepted",
        "message": f"Queued {queued_count} new tracks for processing."
    }

@router.get("/status")
async def get_ingestion_status():
    """
    Return the count of processed tracks vs total audio files found on disk.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT COUNT(*) FROM tracks")
    processed_count = cursor.fetchone()[0]
    conn.close()
    
    total_count = 0
    supported_exts = {'.mp3', '.flac', '.wav', '.m4a', '.ogg'}
    if os.path.exists(MUSIC_DIR):
        for root, _, files in os.walk(MUSIC_DIR):
            for file in files:
                ext = os.path.splitext(file)[1].lower()
                if ext in supported_exts:
                    total_count += 1
                    
    return {
        "processed_tracks": processed_count,
        "total_tracks": total_count,
        "is_syncing": processed_count < total_count
    }
