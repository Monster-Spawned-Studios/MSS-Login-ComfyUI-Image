# Multi-stage Dockerfile for ComfyUI with MSS-Login
# Base: Ubuntu 24.04 LTS (Noble Numbat) with CUDA 12.8.0 Runtime (matches pyproject.toml cu128 index)
# Supports NVIDIA CUDA, Apple Silicon Metal (M-Series), and Intel/CPU hardware targets.
# Uses official Comfy-CLI via Astral UV for fast, reproducible ComfyUI deployment, GPU/CPU auto-detection, and updates.

ARG BASE_IMAGE=nvidia/cuda:12.8.0-runtime-ubuntu24.04
FROM ${BASE_IMAGE} AS base

ARG ACCELERATOR=nvidia
ARG CUDA_VERSION=12.8

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

# Install latest stable ComfyUI using official Comfy-CLI tailored to target accelerator:
# - nvidia: --nvidia --cuda-version ${CUDA_VERSION}
# - m-series: --m-series (Apple Silicon Metal)
# - cpu: --cpu (Intel Mac or generic CPU hosts)
RUN if [ "$ACCELERATOR" = "m-series" ]; then \
        comfy --workspace /app/ComfyUI install --version latest --m-series --fast-deps; \
    elif [ "$ACCELERATOR" = "cpu" ]; then \
        comfy --workspace /app/ComfyUI install --version latest --cpu --fast-deps; \
    else \
        comfy --workspace /app/ComfyUI install --version latest --nvidia --cuda-version ${CUDA_VERSION} --fast-deps; \
    fi

ENV VIRTUAL_ENV=/app/ComfyUI/.venv \
    PATH="/app/ComfyUI/.venv/bin:$PATH"

# Copy MSS-Login extension into custom_nodes
COPY . /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

WORKDIR /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

# Install platform-specific dependencies and extension in editable mode
RUN if [ "$ACCELERATOR" = "m-series" ] && [ -f requirements_metal.txt ]; then \
        uv pip install -r requirements_metal.txt; \
    elif [ "$ACCELERATOR" = "cpu" ] && [ -f requirements_cpu.txt ]; then \
        uv pip install -r requirements_cpu.txt; \
    fi \
    && uv pip install -e . \
    && (playwright install --with-deps chromium || true)

# Provide entrypoint (GPU/MPS/CPU auto-detection) and update script inside container
COPY deploy/entrypoint.sh /app/entrypoint.sh
COPY deploy/update.sh /app/update.sh
RUN chmod +x /app/entrypoint.sh /app/update.sh

WORKDIR /app/ComfyUI

EXPOSE 8188

ENV MSS_LOGIN_DATA_DIR=/data/mss-login \
    CPE_EMBEDDED_CONVERT=true

ENTRYPOINT ["/app/entrypoint.sh"]
