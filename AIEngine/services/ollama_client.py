import httpx
import json
import logging
import os
from typing import AsyncGenerator

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434/api")
DEFAULT_MODEL = os.getenv("VELORA_MODEL", "gemma2:9b")

async def generate_chat_stream(messages: list[dict], system_prompt: str) -> AsyncGenerator[str, None]:
    """
    Sends a request to the local Ollama instance using the chat API to retain context,
    and yields the streaming response.
    """
    url = f"{OLLAMA_BASE_URL}/chat"
    
    # Prepend the system prompt so Ollama gets its instructions first
    full_messages = [{"role": "system", "content": system_prompt}] + messages
    
    payload = {
        "model": DEFAULT_MODEL,
        "messages": full_messages,
        "stream": True
    }
    
    try:
        async with httpx.AsyncClient() as client:
            async with client.stream("POST", url, json=payload, timeout=60.0) as response:
                response.raise_for_status()
                async for chunk in response.aiter_lines():
                    if chunk:
                        data = json.loads(chunk)
                        if "message" in data and "content" in data["message"]:
                            yield f"data: {json.dumps({'content': data['message']['content']})}\n\n"
                yield "data: [DONE]\n\n"
    except Exception as e:
        logger.error(f"Ollama connection error: {e}")
        error_msg = "I'm having trouble connecting to my local language model right now. Please check if Ollama is running."
        yield f"data: {json.dumps({'content': error_msg})}\n\n"
        yield "data: [DONE]\n\n"
