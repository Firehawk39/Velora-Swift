from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional
from services.memory_reader import build_system_prompt
from services.rag_engine import perform_rag_and_generate

router = APIRouter()

class ChatRequest(BaseModel):
    message: str
    context: Optional[str] = None

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
    
    # Perform RAG to find similar songs and stream the response back in SSE format
    return StreamingResponse(
        perform_rag_and_generate(request.message, request.context, system_prompt),
        media_type="text/event-stream"
    )
