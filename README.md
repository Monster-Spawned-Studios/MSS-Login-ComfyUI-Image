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

## Immich-Style Hardware Acceleration Companion Scripts

Following the companion configuration architecture popularized by Immich (see [Immich v3.3.5](https://github.com/immich-app/immich/releases/tag/v3.3.5) with `hwaccel.ml.yml`), hardware-specific configurations are split into companion sub-compose scripts so the main stack remains clean and portable:

- **`hwaccel.ml.yml`**: Unified companion configuration with `cuda`, `rocm`, and `cpu` services.
- **`hwaccel.nvidia.yml`**: Dedicated overlay for NVIDIA CUDA GPU devices and drivers.
- **`hwaccel.rocm.yml`**: Dedicated overlay for AMD ROCm (`/dev/kfd` and `/dev/dri`).
- **`hwaccel.cpu.yml`**: Dedicated overlay for lightweight CPU execution.

### Usage with `extends` (Portainer Web UI or Docker Compose)

In `portainer-stack.yml` or `docker-compose.yml`, uncomment the companion `extends` block:

```yaml
services:
  comfyui-server:
    extends:
      file: hwaccel.ml.yml
      service: cuda    # Options: [cuda, rocm, cpu]
```

### Usage with Docker Compose Multi-File Overlays (CLI)

```bash
# NVIDIA CUDA (Linux / Windows 11 WSL2)
docker compose -f portainer-stack.yml -f hwaccel.nvidia.yml up -d

# AMD ROCm (Linux)
docker compose -f portainer-stack.yml -f hwaccel.rocm.yml up -d

# CPU Mode (macOS / CPU-only)
docker compose -f portainer-stack.yml -f hwaccel.cpu.yml up -d
```

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
   - **Repository reference**: `refs/heads/main` (or your target branch/tag).
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

#### 4. Force Redeployment & Re-pulling Images
- **Re-pull image**: Enable this toggle in Portainer so that during every GitOps redeployment, newer container images (such as floating tags like `:latest` or `:nvidia`) are automatically pulled from the registry even if the compose text itself did not change.
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
