# ComfyUI MSS-Login Docker Deployment

This directory contains the hardware-agnostic production Docker deployment stack for **ComfyUI** running with the **MSS-Login** extension, RBAC, WebAuthn MFA, and model isolation.

## Architecture

- **Base Image**: `ubuntu:24.04` (Ubuntu 24.04 LTS Noble Numbat — backend-neutral).
- **Python Runtime**: Hermetic Python 3.13 provisioned via Astral `uv`.
- **Automatic Hardware & PyTorch Backend Detection (`entrypoint.sh` & `utils/install_deps.py`)**:
  - Does **not** assume a GPU vendor at build or compose time.
  - On startup, `entrypoint.sh` inspects `DEVICE_TYPE` (`auto` by default, or `cuda`, `rocm`, `xpu`, `metal`, `cpu`) and probes the container's exposed hardware:
    - **NVIDIA CUDA**: Detects driver version via `libcuda.so.1` / `nvidia-smi` and installs `cu130` (CUDA 13+) or `cu128` (CUDA 11/12) PyTorch wheels.
    - **AMD ROCm**: Detects `/dev/kfd` or `amd-smi` / `rocm-smi` / `rocminfo` and installs ROCm PyTorch wheels (`rocm6.2.4`).
    - **Intel Arc / XPU**: Detects `libze_intel_gpu.so.1` or `xpu-smi` / `sycl-ls` and installs Intel XPU PyTorch wheels (`xpu`).
    - **Apple Silicon Metal (MPS)**: Detects `Darwin` `arm64` and installs Metal-enabled PyPI wheels.
    - **CPU Fallback**: Installs CPU-only PyTorch wheels and appends `--cpu` to `CLI_ARGS`.
  - Records the reconciled backend in `/app/ComfyUI/.venv/.mss_torch_backend` (persisted in the `comfy_venv` volume) so subsequent restarts boot immediately without re-downloading wheels unless hardware changes.
- **Maintenance**: Built-in `update.sh` updates ComfyUI core and refreshes PyTorch + MSS-Login dependencies for the active hardware backend.

## Quick Start (Docker Compose)

```bash
# Build and run (auto-detects GPU/CPU backend on start)
docker compose up -d

# Check logs
docker compose logs -f
```

### Passing GPU Hardware to the Container

- **NVIDIA GPU**: Pass `--gpus all` or add `gpus: all` to `docker-compose.yml`.
- **AMD ROCm**: Map devices `/dev/kfd` and `/dev/dri` into the container.
- **Intel Arc / XPU**: Map `/dev/dri` into the container.

## Quick Start (Portainer)

1. Navigate to **Stacks** in Portainer.
2. Add a new stack and paste the contents of `portainer-stack.yml`.
3. Set your `HOST_BASE_URL` and `SECRET_KEY` (and enable GPU access in Portainer if applicable).
4. Deploy the stack.

## Maintenance & Updates

To update ComfyUI core and MSS-Login inside a running container:

```bash
docker exec -it comfyui-mss-login /app/update.sh
```
