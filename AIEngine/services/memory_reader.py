import logging
from pathlib import Path
from core.config import settings

logger = logging.getLogger(__name__)

def read_markdown_file(file_path: Path) -> str:
    """Read a markdown file and return its contents. Returns empty string if not found."""
    if not file_path.exists():
        logger.warning(f"Memory file not found: {file_path}")
        return ""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception as e:
        logger.error(f"Error reading memory file {file_path}: {e}")
        return ""

def build_system_prompt() -> str:
    """
    Construct the final system prompt for Ollama by reading the Obsidian
    memory files (AI_Directives and Listening_Preferences).
    """
    directives_path = settings.MEMORIES_DIR / "System" / "AI_Directives.md"
    preferences_path = settings.MEMORIES_DIR / "User" / "Listening_Preferences.md"
    
    directives = read_markdown_file(directives_path)
    preferences = read_markdown_file(preferences_path)
    
    # Base fallback if files are missing
    if not directives:
        directives = (
            "You are Velora, an advanced AI music companion and DJ built right into the user's personal music app. "
            "Your job is to discuss music, recommend songs from their library, and act as an intelligent audio concierge. "
            "You are friendly, witty, and highly knowledgeable about music history, genres, and theory. "
            "Keep your responses concise and conversational so they fit well in a mobile chat interface. "
            "Never refer to yourself as an AI language model—you are Velora, their personal DJ."
        )
        
    prompt = f"{directives}\n\n"
    
    if preferences:
        prompt += f"--- USER LISTENING PREFERENCES ---\n{preferences}\n\n"
        
    prompt += "Always use the above information to tailor your responses."
    
    return prompt
