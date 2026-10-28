# Hardware-agnostic multi-stage Dockerfile for ComfyUI with MSS-Login
# Base: Ubuntu 24.04 LTS (Noble Numbat) — does NOT assume a specific GPU backend.
# Supports NVIDIA CUDA (cu130 / cu128), AMD ROCm, Intel Arc/XPU, Apple Silicon Metal (M-Series), and CPU.
# Uses official Comfy-CLI and Astral UV for reproducible ComfyUI deployment and automatic runtime PyTorch provisioning.

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE} AS base

ARG ACCELERATOR=auto
ARG CUDA_VERSION=auto

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

# Install latest stable ComfyUI core.
# When ACCELERATOR=auto (default), install ComfyUI core without assuming a GPU backend;
# entrypoint.sh detects the host GPU at runtime and installs the matching PyTorch wheels.
RUN if [ "$ACCELERATOR" = "m-series" ] || [ "$ACCELERATOR" = "metal" ]; then \
        comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI install --version latest --m-series --fast-deps; \
    elif [ "$ACCELERATOR" = "nvidia" ] || [ "$ACCELERATOR" = "cuda" ]; then \
        if [ "$CUDA_VERSION" != "auto" ] && [ -n "$CUDA_VERSION" ]; then \
            comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI install --version latest --nvidia --cuda-version ${CUDA_VERSION} --fast-deps; \
        else \
            comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI install --version latest --nvidia --fast-deps; \
        fi; \
    elif [ "$ACCELERATOR" = "amd" ] || [ "$ACCELERATOR" = "rocm" ]; then \
        comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI install --version latest --amd --fast-deps; \
    else \
        comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI install --version latest --cpu --fast-deps; \
    fi

ENV VIRTUAL_ENV=/app/ComfyUI/.venv \
    PATH="/app/ComfyUI/.venv/bin:$PATH"

# Copy MSS-Login extension into custom_nodes
COPY . /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

WORKDIR /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

# Install non-backend-specific extension dependencies; PyTorch backend is reconciled by entrypoint.sh
RUN uv pip install -r requirements.txt \
    && (playwright install --with-deps chromium || true)

# Provide entrypoint (runtime GPU auto-detection & PyTorch installer) and update script inside container
COPY deploy/entrypoint.sh /app/entrypoint.sh
COPY deploy/update.sh /app/update.sh
RUN chmod +x /app/entrypoint.sh /app/update.sh

WORKDIR /app/ComfyUI

EXPOSE 8188

ENV MSS_LOGIN_DATA_DIR=/data/mss-login \
    CPE_EMBEDDED_CONVERT=true \
    DEVICE_TYPE=auto

ENTRYPOINT ["/app/entrypoint.sh"]
