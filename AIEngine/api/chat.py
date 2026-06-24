from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional
from services.memory_reader import build_system_prompt
from services.rag_engine import perform_rag_and_generate

router = APIRouter()

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    messages: list[ChatMessage]
    context: Optional[str] = None

@router.post("/message")
async def send_chat_message(request: ChatRequest):
    """
    Sends a message to the AI DJ. 
    It reads the Obsidian memory files to construct the system prompt,
    then streams the response back from the local Ollama instance.
    """
    if not request.messages:
        raise HTTPException(status_code=400, detail="Messages array cannot be empty.")
        
    system_prompt = build_system_prompt()
    
    # Convert Pydantic models to dicts before passing to RAG engine
    messages_dicts = [{"role": msg.role, "content": msg.content} for msg in request.messages]
    
    # Perform RAG to find similar songs and stream the response back in SSE format
    return StreamingResponse(
        perform_rag_and_generate(messages_dicts, request.context, system_prompt),
        media_type="text/event-stream"
    )
