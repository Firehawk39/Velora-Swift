from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from services.memory_reader import build_system_prompt
from services.ollama_client import generate_chat_stream

router = APIRouter()

class ChatRequest(BaseModel):
    message: str

@router.post("/message")
async def send_chat_message(request: ChatRequest):
    """
    Sends a message to the AI DJ. 
    It reads the Obsidian memory files to construct the system prompt,
    then streams the response back from the local Ollama instance.
    """
    if not request.message.strip():
        raise HTTPException(status_code=400, detail="Message cannot be empty.")
        
    system_prompt = build_system_prompt()
    
    # We use FastAPI's StreamingResponse to stream the generation back to the client
    # as Server-Sent Events (SSE) or a raw stream.
    return StreamingResponse(
        generate_chat_stream(request.message, system_prompt),
        media_type="text/plain"
    )
