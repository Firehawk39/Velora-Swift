from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from core.config import settings
from api import telemetry, chat

app = FastAPI(
    title=settings.PROJECT_NAME,
    description="Backend API and Orchestrator for the Velora AI Engine",
    version="0.1.0"
)

# Configure CORS so the Swift app (or web clients) can talk to it
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict this to the specific app domain/IP
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include Routers
app.include_router(
    telemetry.router,
    prefix=f"{settings.API_V1_STR}/telemetry",
    tags=["telemetry"]
)
app.include_router(
    chat.router,
    prefix=f"{settings.API_V1_STR}/chat",
    tags=["chat"]
)

@app.get("/")
async def root():
    return {"message": f"Welcome to the {settings.PROJECT_NAME} API"}
