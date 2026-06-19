import httpx
import json
import logging
from typing import AsyncGenerator

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = "http://localhost:11434/api"
DEFAULT_MODEL = "gemma:2b" # Placeholder until we run the heavy QAT model

async def generate_chat_stream(prompt: str, system_prompt: str) -> AsyncGenerator[str, None]:
    """
    Sends a request to the local Ollama instance and yields the streaming response.
    """
    url = f"{OLLAMA_BASE_URL}/generate"
    
    payload = {
        "model": DEFAULT_MODEL,
        "prompt": prompt,
        "system": system_prompt,
        "stream": True
    }
    
    try:
        async with httpx.AsyncClient() as client:
            async with client.stream("POST", url, json=payload, timeout=60.0) as response:
                response.raise_for_status()
                async for chunk in response.aiter_lines():
                    if chunk:
                        data = json.loads(chunk)
                        if "response" in data:
                            yield data["response"]
    except Exception as e:
        logger.error(f"Ollama connection error: {e}")
        yield "I'm having trouble connecting to my local language model right now. Please check if Ollama is running."
