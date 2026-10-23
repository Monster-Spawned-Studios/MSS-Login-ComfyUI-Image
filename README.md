# ComfyUI MSS-Login Docker Deployment

This repository contains the production Docker deployment stack for **ComfyUI** running with the **MSS-Login** extension, RBAC, WebAuthn MFA, and model isolation.

## Architecture

- **Base Image**: `nvidia/cuda:12.8.0-runtime-ubuntu24.04` (Ubuntu 24.04 LTS Noble Numbat + CUDA 12.8).
- **Python Runtime**: Hermetic Python 3.13 provisioned via Astral `uv`.
- **ComfyUI Core**: Installed and managed using official `comfy-cli` (`--cuda-version 12.8 --fast-deps`), aligning directly with `pyproject.toml`'s `pytorch-cuda-128` wheel index.
- **Hardware Auto-Detection**:
  - Container entrypoint (`entrypoint.sh`) dynamically tests for NVIDIA GPU access via `nvidia-smi`.
  - If GPU is present: boots with full CUDA 12.8 hardware acceleration.
  - If GPU is absent (CPU host, cloud VM, or NAS without NVIDIA runtime): automatically enables `--cpu` execution without crashing.
- **Maintenance**: Built-in `update.sh` allows running `comfy --workspace /app/ComfyUI update comfy` and updating MSS-Login dependencies cleanly.

## Quick Start (Docker Compose)

```bash
# Build and run
docker compose up -d

# Check logs
docker compose logs -f
```

## Quick Start (Portainer)

1. Navigate to **Stacks** in Portainer.
2. Add a new stack and paste the contents of `portainer-stack.yml`.
3. Set your `HOST_BASE_URL` and `SECRET_KEY`.
4. Deploy the stack.

## Maintenance & Updates

To update ComfyUI core and MSS-Login inside a running container:

```bash
docker exec -it comfyui-mss-login /app/update.sh
```
