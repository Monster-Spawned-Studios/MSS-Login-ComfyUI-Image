# Multi-stage hardware-optimized Dockerfile for ComfyUI with MSS-Login
# Base: Ubuntu 24.04 LTS (Noble Numbat)
#
# Dedicated Sub-Image Targets:
#   - cpu:    Pre-baked with PyTorch CPU wheels (macOS, CPU-only servers, CI/CD)
#   - nvidia: Pre-baked with PyTorch NVIDIA CUDA wheels (cu128 / cu130)
#   - rocm:   Pre-baked with PyTorch AMD ROCm wheels (rocm6.2.4)
#   - auto:   Universal hardware auto-detecting image (default)

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE} AS base

ARG ACCELERATOR=auto
ARG CUDA_VERSION=auto

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    UV_INSTALL_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    PATH="/app/ComfyUI/.venv/bin:/root/.local/bin:/usr/local/bin:$PATH"

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
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install hermetic Python 3.13 and official Comfy-CLI
RUN uv python install 3.13 \
    && uv tool install comfy-cli

WORKDIR /app

# Install ComfyUI core
RUN comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI install --version latest --cpu --fast-deps

ENV VIRTUAL_ENV=/app/ComfyUI/.venv \
    PATH="/app/ComfyUI/.venv/bin:$PATH"

# Auto-download MSS-Login extension into custom_nodes from repository
ARG MSS_LOGIN_REPO=https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git
ARG MSS_LOGIN_BRANCH=production
RUN git clone --depth 1 --branch ${MSS_LOGIN_BRANCH} ${MSS_LOGIN_REPO} /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

WORKDIR /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

# Install non-backend-specific extension dependencies
RUN uv pip install -r requirements.txt \
    && (playwright install --with-deps chromium || true)

# Provide entrypoint, update script, and default user-scripts inside container
COPY entrypoint.sh /app/entrypoint.sh
COPY update.sh /app/update.sh
COPY user-scripts/ /app/user-scripts/
RUN chmod +x /app/entrypoint.sh /app/update.sh /app/user-scripts/*.sh 2>/dev/null || true

# Create dedicated non-root user 'comfy', data directory, user-scripts, and cache directories with proper ownership
RUN mkdir -p /data/mss-login /data/cache/huggingface /data/cache/torch /app/user-scripts \
    && (groupadd -r -g 1000 comfy || true) \
    && (useradd -m -u 1000 -g 1000 -s /bin/bash comfy || true) \
    && (groupadd -r render 2>/dev/null || true) \
    && (usermod -aG video,render comfy 2>/dev/null || usermod -aG video comfy 2>/dev/null || true) \
    && (chown -R 1000:1000 /app /data/mss-login /data/cache /opt/uv-python 2>/dev/null || true)

USER comfy

WORKDIR /app/ComfyUI

EXPOSE 8188

ENV MSS_LOGIN_DATA_DIR=/data/mss-login \
    HF_HOME=/data/cache/huggingface \
    TORCH_HOME=/data/cache/torch \
    XDG_CACHE_HOME=/data/cache \
    COMFYUI_USER_SCRIPTS_DIR=/app/user-scripts \
    CPE_EMBEDDED_CONVERT=true \
    DEVICE_TYPE=auto

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
    CMD ["curl", "-f", "http://127.0.0.1:8188/mss-login/login"]

ENTRYPOINT ["/app/entrypoint.sh"]

# ------------------------------------------------------------------------------
# Sub-Image Target: CPU (macOS, CPU-only servers, CI/CD testing)
# ------------------------------------------------------------------------------
FROM base AS cpu
ENV DEVICE_TYPE=cpu \
    USE_CPU=1
RUN uv pip install --python /app/ComfyUI/.venv/bin/python \
        --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
        --index-url https://download.pytorch.org/whl/cpu \
        torch torchvision torchaudio \
    && echo "cpu" > /app/ComfyUI/.venv/.mss_torch_backend

# ------------------------------------------------------------------------------
# Sub-Image Target: NVIDIA (Linux & Windows 11 WSL2 with NVIDIA CUDA GPU)
# ------------------------------------------------------------------------------
FROM base AS nvidia
ARG CUDA_VERSION=cu128
ENV DEVICE_TYPE=cuda \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility
RUN uv pip install --python /app/ComfyUI/.venv/bin/python \
        --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
        --index-url https://download.pytorch.org/whl/${CUDA_VERSION} \
        torch torchvision torchaudio \
    && echo "cuda" > /app/ComfyUI/.venv/.mss_torch_backend

# ------------------------------------------------------------------------------
# Sub-Image Target: ROCM (Linux with AMD ROCm GPU)
# ------------------------------------------------------------------------------
FROM base AS rocm
ARG ROCM_VERSION=rocm6.2.4
ENV DEVICE_TYPE=rocm
RUN uv pip install --python /app/ComfyUI/.venv/bin/python \
        --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
        --index-url https://download.pytorch.org/whl/${ROCM_VERSION} \
        torch torchvision torchaudio \
    && echo "rocm" > /app/ComfyUI/.venv/.mss_torch_backend

# ------------------------------------------------------------------------------
# Sub-Image Target: AUTO (Universal hardware auto-detecting image - Default)
# ------------------------------------------------------------------------------
FROM base AS auto
ENV DEVICE_TYPE=auto
