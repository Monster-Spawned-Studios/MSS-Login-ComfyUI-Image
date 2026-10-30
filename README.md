# ComfyUI MSS-Login Docker Deployment

This directory contains the production Docker deployment stack for **ComfyUI** running with the **MSS-Login** extension, RBAC, WebAuthn MFA, and model isolation.

It is designed to compile, deploy, and run cleanly out of the box across **macOS (Apple Silicon & Intel)**, **Linux (NVIDIA, AMD ROCm, Intel Arc, and CPU)**, and **Windows 11 Pro (WSL2)**.

## Architecture & Sub-Image Targets

The multi-stage `deploy/Dockerfile` provides specialized sub-image targets while retaining dynamic runtime hardware detection:

| Sub-Image Target | Docker Target | Pre-built Image Tag | Best For |
|---|---|---|---|
| **Universal (Auto)** | `auto` (default) | `monster-spawned-studios/comfyui-mss-login:latest` | Universal auto-detection on boot across any host |
| **NVIDIA CUDA** | `nvidia` | `monster-spawned-studios/comfyui-mss-login:nvidia` | Linux & Windows 11 WSL2 with NVIDIA GPUs (CUDA cu128/cu130) |
| **AMD ROCm** | `rocm` | `monster-spawned-studios/comfyui-mss-login:rocm` | Linux with AMD Radeon / Instinct GPUs (ROCm 6.2.4) |
| **CPU Mode** | `cpu` | `monster-spawned-studios/comfyui-mss-login:cpu` | macOS (Docker Desktop), CPU-only servers, CI/CD |

## Hardware Backend Selection (GitOps & Portainer Ready)

Hardware acceleration is configured **entirely through environment variables** using Docker Compose profiles. **You do not need to edit or uncomment sections in YAML files**, making this 100% compatible with Portainer EE's GitOps repository deployment.

Set the `COMPOSE_PROFILES` environment variable in Portainer's **Environment variables** tab (or in your `.env` file):

| `COMPOSE_PROFILES` | Target Hardware | Image Tag | Docker Passthrough Activated |
|---|---|---|---|
| `auto` (or unset) | Universal Auto-Detect | `:latest` / `:auto` | Runtime hardware auto-detection on boot |
| `cuda` (or `nvidia`) | NVIDIA CUDA GPU | `:nvidia` | NVIDIA GPU driver passthrough (`driver: nvidia, capabilities: [gpu]`) |
| `rocm` (or `amd`) | AMD ROCm GPU | `:rocm` | AMD device passthrough (`/dev/kfd`, `/dev/dri`, `video`/`render` groups) |
| `cpu` | CPU Execution Mode | `:cpu` | CPU flags enabled (`--cpu`), zero GPU driver dependencies |

> [!TIP]
> **Combining Profiles**: To enable the optional Cloudflare Tunnel alongside hardware acceleration, separate profiles with a comma, for example: `COMPOSE_PROFILES=cuda,tunnel`.

## User Scripts & Custom Node Auto-Downloader

Before ComfyUI launches, `entrypoint.sh` executes the user-scripts hook (`user-scripts/pre-start.sh`). This enables automatic cloning of custom nodes from Git repositories, batch model downloads, and dependency installation on startup.

The `user-scripts/` directory contains:
- **`pre-start.sh`**: Main boot orchestrator running the scripts below in order.
- **`01-download-models.sh`**: Downloads models listed in `models-to-download.txt` into their corresponding folders (checkpoints, loras, vae, etc.) with checksum validation.
- **`02-download-nodes.sh`**: Clones and updates custom node Git repositories listed in `custom-nodes.txt` (including branch/tag `@ref` support).
- **`03-install-node-deps.sh`**: Automatically detects and installs Python dependencies for newly cloned nodes using fast `uv`.
- **`04-set-permissions.sh`**: Sets volume permissions so non-root containers and the host user can access output and models cleanly.
- **`custom-nodes.txt`**: One Git URL per line (e.g. `https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login`).
- **`models-to-download.txt`**: Model download URLs and target folder classifications.

You can customize these scripts by binding a host directory to `/app/user-scripts` via `COMFYUI_USER_SCRIPTS_DIR=./user-scripts` in your `.env`.

## Caching (Hugging Face & PyTorch)

To avoid redownloading models and transformer weights on restart or rebuild, dedicated persistent caching directories are mapped:
- **Hugging Face Cache**: `${COMFYUI_CACHE_DIR:-comfyui_cache}/huggingface` (`HF_HOME=/data/cache/huggingface`)
- **PyTorch Cache**: `${COMFYUI_CACHE_DIR:-comfyui_cache}/torch` (`TORCH_HOME=/data/cache/torch`)
- **General Cache**: `${COMFYUI_CACHE_DIR:-comfyui_cache}` (`XDG_CACHE_HOME=/data/cache`)

## Portainer Deployment & GitOps Automation

You can deploy this stack in **Portainer CE/EE** via direct Web UI editor paste, manual Git repository polling, or fully automated GitOps deployment (polling and webhooks).

### Option A: Web UI Stack Editor (Direct Paste)

1. Navigate to **Stacks** in Portainer and click **Add stack**.
2. Select the **Web editor** build method.
3. Name your stack (e.g., `comfyui-mss-server`).
4. Paste the contents of `portainer-stack.yml` into the editor.
5. In the **Environment variables** section below the editor:
   - Click **Load variables from .env file** and upload your `.env` (derived from `.env.example`), OR click **Add environment variable** to manually set `HOST_BASE_URL` and `SECRET_KEY`.
6. To enable hardware acceleration, uncomment the `extends` block in the YAML:
   ```yaml
   extends:
     file: hwaccel.ml.yml
     service: cuda    # or rocm, cpu
   ```
7. Click **Deploy the stack**.

---

### Option B: Portainer EE GitOps Deployment (Git Repository Pull / Push Webhooks)

Portainer Enterprise Edition (EE) and Business Edition provide native **GitOps** capabilities to keep your running stack continuously synchronized with your Git repository.

#### 1. Configure the Git Repository Stack in Portainer

1. Navigate to **Stacks** -> **Add stack**.
2. Select the **Repository** build method.
3. Configure repository settings:
   - **Repository URL**: `https://git.monsterspawned.studio/Monster-Spawned-Studios/comfyui-mss-login-docker.git` (or your repository/fork URL).
   - **Repository reference**: `refs/heads/production` (primary deployment branch).
   - **Authentication**: Enable and supply your Git credentials / Personal Access Token (PAT) if the repository is private.
   - **Compose path**: `portainer-stack.yml`
   - **Additional paths (Multi-File Compose)**: If you prefer using companion overlays instead of editing YAML `extends`, click **Add file** under *Additional paths* and enter the matching overlay (e.g. `hwaccel.nvidia.yml`, `hwaccel.rocm.yml`, or `hwaccel.cpu.yml`). Portainer merges these files in order just like `docker compose -f ... -f ...`.
4. Supply your environment variables:
   - In the **Environment variables** section, define your configuration variables or click **Load variables from .env file** to upload your configured `.env` (derived from `.env.example`).
   - Portainer injects these variables during Compose substitution and generates a container-accessible `stack.env`.

#### 2. Automatic Pull Mechanism (Polling)
- In the stack configuration under **Automatic updates**:
  - Toggle **Automatic updates** to **ON**.
  - Select **Mechanism**: **Polling**.
  - Set the **Fetch interval** (e.g., `5m` or `1h`).
  - Portainer will periodically query the Git remote, compare the latest remote commit SHA against the currently deployed SHA, pull new code, and redeploy the stack seamlessly.

#### 3. Automatic Push Mechanism (GitOps Webhook)
For instantaneous zero-delay deployments when code or configurations are pushed to Git:
- Under **Automatic updates**:
  - Select **Mechanism**: **Webhook**.
  - Portainer will generate a dedicated **Webhook URL** (e.g., `https://portainer.example.com/api/stacks/webhooks/...`).
  - Copy this Webhook URL.
- In your Git platform (Gitea, GitHub, or GitLab):
  - Go to **Repository Settings** -> **Webhooks** -> **Add Webhook**.
  - Paste the Portainer Webhook URL into the **Target URL / Payload URL**.
  - Set Content Type to `application/json`.
  - Trigger on **Push Events**.
  - Save the webhook.
- Whenever a commit is pushed to the target branch, your Git server sends a POST request to Portainer, triggering an immediate SHA comparison, repository pull, and stack redeployment.

#### 4. Force Redeployment & Image Pull Policy
- **Image Pull Policy (`PULL_POLICY`)**: By default, `PULL_POLICY` is set to `build` (`pull_policy: ${PULL_POLICY:-build}`), instructing Docker Compose to build the container from `deploy/Dockerfile` and skip trying to pull an unauthenticated/nonexistent image from Docker Hub during Portainer's pre-deploy compose pull step. If using pre-built images from a container registry (e.g., Docker Hub or GitHub Packages `ghcr.io`), set `PULL_POLICY=always` (or `missing`) and configure your image path in `COMFYUI_IMAGE`.
- **Re-pull image**: Enable this toggle in Portainer if you configure pre-built images (`PULL_POLICY=always`) so that newer container images (such as floating tags like `:latest` or `:nvidia`) are automatically pulled during every GitOps trigger.
- **Force redeployment**: When enabled, Portainer redeploys the stack on every trigger, ensuring local environment state does not drift from Git source-of-truth.
- If Watchtower is also deployed, image auto-updates will honor the container label:
  `com.centurylinklabs.watchtower.enable=true`.

## Security & Vulnerability Scanning (Trivy)

The Dockerfile and container configurations are hardened and scanned with **Trivy**:
- Non-root user `comfy` (UID 1000) execution.
- Security options: `no-new-privileges:true`.
- Built-in container healthcheck instruction.
- Zero high/critical misconfigurations.

To scan locally:
```bash
docker run --rm -v $(pwd):/src aquasec/trivy:latest config /src/deploy/Dockerfile
```

## Maintenance & Updates

To update ComfyUI core and MSS-Login inside a running container:

```bash
docker exec -it comfyui-server /app/update.sh
```
