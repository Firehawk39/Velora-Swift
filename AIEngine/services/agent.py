import os
import logging
from pydantic_ai import Agent
from pydantic_ai.models.openai import OpenAIModel
from services.memory_reader import build_system_prompt

logger = logging.getLogger(__name__)

# Ollama provides an OpenAI-compatible API at /v1
# We map the OLLAMA_BASE_URL from /api to /v1
ollama_base = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434/api")
if ollama_base.endswith("/api"):
    ollama_base = ollama_base[:-4] + "/v1"
elif not ollama_base.endswith("/v1"):
    ollama_base = ollama_base.rstrip("/") + "/v1"

model_name = os.getenv("VELORA_MODEL", "gemma4:e4b")

# We use the OpenAIModel adapter because Ollama's OpenAI compatibility
# layer handles function calling (tools) extremely well.
model = OpenAIModel(
    model_name=model_name,
    base_url=ollama_base,
    api_key="ollama"  # Ollama doesn't require an API key, but OpenAI client needs something
)

# Create the Pydantic AI agent — no static system_prompt here;
# the dynamic decorator below will provide it on every request.
agent = Agent(model=model)

@agent.system_prompt
def add_dynamic_prompt() -> str:
    """
    Reads the Obsidian memory files on every request and injects them
    into the system prompt so Velora's personality and user preferences
    are always current.
    """
    return build_system_prompt()

# Register tools here after agent is created to avoid circular imports.
from services.rag_engine import perform_vector_search
from services.tools import get_recent_history, search_library, update_memory

agent.tool(perform_vector_search)
agent.tool(get_recent_history)
agent.tool(search_library)
agent.tool(update_memory)
