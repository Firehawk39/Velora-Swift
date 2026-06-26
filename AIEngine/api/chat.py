from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional
import json

from services.agent import agent

router = APIRouter()

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    messages: list[ChatMessage]
    context: Optional[str] = None

async def stream_agent_response(prompt: str, message_history: list):
    async with agent.run_stream(prompt, message_history=message_history) as result:
        async for chunk in result.stream_text(delta=True):
            yield f"data: {json.dumps({'content': chunk})}\n\n"
        yield "data: [DONE]\n\n"

@router.post("/message")
async def send_chat_message(request: ChatRequest):
    """
    Sends a message to the AI DJ via Pydantic AI agent.
    """
    if not request.messages:
        raise HTTPException(status_code=400, detail="Messages array cannot be empty.")

    current_msg = request.messages[-1].content
    if request.context:
        current_msg += f"\n\n[Context: {request.context}]"

    # Build conversation history using pydantic-ai's message format.
    # We import lazily here to avoid hard dependency on internal API changes.
    from pydantic_ai.messages import ModelRequest, ModelResponse, UserPromptPart, TextPart
    history = []
    for msg in request.messages[:-1]:
        if msg.role == "user":
            history.append(ModelRequest(parts=[UserPromptPart(content=msg.content)]))
        elif msg.role in ("assistant", "model"):
            history.append(ModelResponse(parts=[TextPart(content=msg.content)]))

    return StreamingResponse(
        stream_agent_response(current_msg, history),
        media_type="text/event-stream"
    )

