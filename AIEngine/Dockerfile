# Use NVIDIA's official CUDA base image — the world-class standard for GPU-accelerated ML containers.
# CUDA and cuDNN are pre-installed at the OS level, so PyTorch installs in seconds
# instead of downloading its own 2.5GB bundled CUDA runtime.
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# Set environment variables early so apt doesn't prompt during installs
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

# Install Python 3.11 and bootstrap pip for Python 3.11 specifically.
# NOTE: python3-pip on Ubuntu 22.04 installs pip for Python 3.10 (OS default).
# We use python3.11 -m ensurepip to guarantee pip targets Python 3.11.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-dev \
    python3.11-venv \
    python3-pip \
    ffmpeg \
    libsndfile1 \
    build-essential \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python \
    && python3.11 -m ensurepip --upgrade \
    && python3.11 -m pip install --upgrade pip \
    && rm -rf /var/lib/apt/lists/*

# Set work directory
WORKDIR /app

# Step 1: Install all general packages into Python 3.11 explicitly
RUN python3.11 -m pip install --no-cache-dir \
    "fastapi>=0.109.0" \
    "uvicorn[standard]>=0.27.0" \
    "pydantic>=2.5.0" \
    "pydantic-settings>=2.1.0" \
    "python-dotenv>=1.0.0" \
    "httpx>=0.27.0" \
    "transformers>=4.38.0" \
    "essentia>=2.1b6.dev1110" \
    "librosa>=0.10.1" \
    "sqlite-vec>=0.1.1"

# Step 2: Install PyTorch CUDA 12.1 slim wheels into Python 3.11 explicitly.
# --extra-index-url adds the PyTorch server alongside PyPI (not instead of it).
RUN python3.11 -m pip install --no-cache-dir \
    --extra-index-url https://download.pytorch.org/whl/cu121 \
    "torch>=2.2.0" \
    "torchaudio>=2.2.0"

# Copy the entire project
COPY . .

# Expose the API port
EXPOSE 8000

# Run using python3.11 explicitly so there is no ambiguity
CMD ["python3.11", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
