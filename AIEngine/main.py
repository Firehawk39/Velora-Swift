from fastapi import FastAPI, Depends, HTTPException, Security
from fastapi.security.api_key import APIKeyHeader
from fastapi.middleware.cors import CORSMiddleware
from core.config import settings
from api import telemetry, chat, ingestion

app = FastAPI(
    title=settings.PROJECT_NAME,
    description="Backend API and Orchestrator for the Velora AI Engine",
    version="0.1.0"
)

# API Key Security
api_key_header = APIKeyHeader(name="Authorization", auto_error=False)

async def verify_api_key(api_key: str = Security(api_key_header)):
    if api_key != settings.API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API Key")
    return api_key

# Configure CORS so the Swift app (or web clients) can talk to it
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict this to the specific app domain/IP
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include Routers with Security Dependency
app.include_router(
    telemetry.router,
    prefix=f"{settings.API_V1_STR}/telemetry",
    tags=["telemetry"],
    dependencies=[Depends(verify_api_key)]
)
app.include_router(
    chat.router,
    prefix=f"{settings.API_V1_STR}/chat",
    tags=["chat"],
    dependencies=[Depends(verify_api_key)]
)
app.include_router(
    ingestion.router,
    prefix=f"{settings.API_V1_STR}/ingestion",
    tags=["ingestion"],
    dependencies=[Depends(verify_api_key)]
)

@app.get("/")
async def root():
    return {"message": f"Welcome to the {settings.PROJECT_NAME} API"}
