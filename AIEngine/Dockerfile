# Use NVIDIA's official CUDA base image — the world-class standard for GPU-accelerated ML containers.
# CUDA and cuDNN are pre-installed at the OS level, so PyTorch installs in seconds
# instead of downloading its own 2.5GB bundled CUDA runtime.
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# Install Python 3.11 alongside CUDA
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-dev \
    python3-pip \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

# Set work directory
WORKDIR /app

# Install ONLY the audio system libraries not already in the NVIDIA base image
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libsndfile1 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Step 1: Upgrade pip
RUN pip install --no-cache-dir --upgrade pip

# Step 2: Install all general packages from PyPI
RUN pip install --no-cache-dir \
    fastapi>=0.109.0 \
    "uvicorn[standard]>=0.27.0" \
    "pydantic>=2.5.0" \
    "pydantic-settings>=2.1.0" \
    "python-dotenv>=1.0.0" \
    "httpx>=0.27.0" \
    "transformers>=4.38.0" \
    "essentia>=2.1b6.dev1110" \
    "librosa>=0.10.1" \
    "sqlite-vec>=0.1.1"

# Step 3: Install PyTorch from the official CUDA 12.1 slim wheel index.
# This installs the CUDA-aware wheel WITHOUT bundling a second copy of CUDA.
RUN pip install --no-cache-dir \
    --extra-index-url https://download.pytorch.org/whl/cu121 \
    "torch>=2.2.0" \
    "torchaudio>=2.2.0"

# Copy the entire project
COPY . .

# Expose the API port
EXPOSE 8000

# Run the FastAPI application
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
