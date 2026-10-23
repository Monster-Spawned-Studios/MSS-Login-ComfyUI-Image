# Multi-stage Dockerfile for ComfyUI with MSS-Login
# Base: Ubuntu 24.04 LTS (Noble Numbat) with CUDA 12.8.0 Runtime (matches pyproject.toml cu128 index)
# Uses official Comfy-CLI via Astral UV for fast, reproducible ComfyUI deployment, GPU/CPU auto-detection, and updates.

FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH="/root/.cargo/bin:/root/.local/bin:$PATH"

# Install system dependencies (libsqlcipher-dev, graphics, media libraries)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    build-essential \
    libsqlcipher-dev \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install uv for fast Python packaging & tool management
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install hermetic Python 3.13 and official Comfy-CLI
RUN uv python install 3.13 \
    && uv tool install comfy-cli

WORKDIR /app

# Install latest stable ComfyUI using official Comfy-CLI with uv fast-deps & CUDA 12.8 (matches pyproject.toml)
RUN comfy --workspace /app/ComfyUI install --version latest --nvidia --cuda-version 12.8 --fast-deps

ENV VIRTUAL_ENV=/app/ComfyUI/.venv \
    PATH="/app/ComfyUI/.venv/bin:$PATH"

# Copy MSS-Login extension into custom_nodes
COPY . /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

WORKDIR /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

# Install MSS-Login extension in editable mode and provision headless Chromium
RUN uv pip install -e . \
    && playwright install --with-deps chromium || true

# Provide entrypoint (GPU/CPU auto-detection) and update script inside container
COPY deploy/entrypoint.sh /app/entrypoint.sh
COPY deploy/update.sh /app/update.sh
RUN chmod +x /app/entrypoint.sh /app/update.sh

WORKDIR /app/ComfyUI

EXPOSE 8188

ENV MSS_LOGIN_DATA_DIR=/data/mss-login \
    CPE_EMBEDDED_CONVERT=true

ENTRYPOINT ["/app/entrypoint.sh"]
