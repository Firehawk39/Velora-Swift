import os
from pathlib import Path
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    # Base paths
    BASE_DIR: Path = Path(__file__).resolve().parent.parent
    MEMORIES_DIR: Path = BASE_DIR / "Memories"
    
    # Database
    DATA_DIR: Path = BASE_DIR / "data"
    DATABASE_PATH: Path = DATA_DIR / "velora.db"
    
    # API Settings
    API_V1_STR: str = "/api/v1"
    PROJECT_NAME: str = "Velora AI Engine"

    class Config:
        env_file = ".env"
        extra = "ignore"

settings = Settings()
