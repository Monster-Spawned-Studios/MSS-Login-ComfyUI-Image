# ComfyUI MSS-Login image

Production image and Portainer stack for ComfyUI plus the [ComfyUI-MSS-Login](https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login) custom node.

The stack pulls `ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia`. It does not build during deploy. The `:nvidia` tag is published only by a manual GitHub Actions run.

## Publish

Workflow: `.github/workflows/publish-ghcr.yml`.

- Trigger: `workflow_dispatch` only. No push, tag, or schedule.
- Auth: the workflow `GITHUB_TOKEN` with `packages: write`. No other secrets.
- Target: Dockerfile stage `nvidia` (default CUDA channel `cu130`).
- Every run pushes `ghcr.io/monster-spawned-studios/comfyui-mss-login:sha-<commit>`.
- `push_nvidia_tag` also pushes `:nvidia`. Its default is **off**. Portainer re-pulls `:nvidia`, so leave this off until the image is ready to deploy.
- `:latest` is refused.
- ComfyUI-MSS-Login is fetched over HTTPS at build time. Default ref is `6f33be97315fa33997d98afc09f439b7a8fc4763` (`6f33be9`). The repo URL cannot contain credentials.

Build args:

| Arg | Default |
|---|---|
| `MSS_LOGIN_REPO` | `https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git` |
| `MSS_LOGIN_REF` | `6f33be97315fa33997d98afc09f439b7a8fc4763` |
| `CUDA_VERSION` | `cu130` on the nvidia stage (`cu128` is the other accepted value) |

`cpu`, `rocm`, and `auto` remain Dockerfile targets. Build them locally with `docker build --target cpu` (or `rocm` / `auto`). The workflow does not publish those tags.

```bash
docker build --target nvidia \
  --build-arg MSS_LOGIN_REF=6f33be97315fa33997d98afc09f439b7a8fc4763 \
  -t ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia .
```

## What the image contains

- ComfyUI under `/app/ComfyUI`, Python 3.13 via uv, user `comfy` (uid/gid 1000).
- ComfyUI-MSS-Login at `/opt/mss-login/ComfyUI-MSS-Login` (the image seed).
- `curl`, used by the healthcheck.
- NVIDIA stage: PyTorch CUDA wheels and `LD_LIBRARY_PATH` pointed at the venv cuDNN/CUDA libraries (`/app/ComfyUI/.venv/lib/python3.13/site-packages/...`). This replaces `user-scripts/00-setup-uv-venv.sh`, which targeted `/root/ComfyUI/.venv`. The script is still mounted and is not executed.
- `entrypoint.sh` copies the seed into `custom_nodes/ComfyUI-MSS-Login` only when that directory is missing or empty. An existing checkout is not modified.
- The container starts as root (`user: "0:0"`) so the entrypoint can `chown` root-owned volume data to uid 1000, then drops privileges with `setpriv`. A directory whose top-level owner is already 1000 is not walked again.

## Portainer

Compose path: `portainer-stack.yml`. Do not attach the `hwaccel.*.yml` files. GPU passthrough for both devices is already in the stack (`CUDA_VISIBLE_DEVICES` default `0,1`, NVIDIA device reservation `count: all`).

Runtime defaults: memory limit `20g`, memswap `24g`, CPU limit `8`, CPU reservation `4`, `--cache-lru 1`, `--disable-smart-memory`, `--reserve-vram` from `VRAM_RESERVE_GB` (default `1.5`).

Ports: `100.65.194.86:9008` and `127.0.0.1:9008`.

Watchtower labels default to `false`. That does not turn off Portainer's own re-pull of `:nvidia`.

Container name is `comfyui-server`. Stack 250 used `comfyui-cuda-laptop`. ServerOps must point the Cloudflare tunnel at the new name. The compose service DNS name is still `comfyui-server`, so `http://comfyui-server:9008` is the in-network target. The tunnel container name stays `comfyui-prod-tunnel`.

`extra_model_paths.yaml` and `.bashrc` must already be files on the host. Docker creates a directory if a file bind is missing. `extra_model_paths.yaml` is mounted read-only, so the entrypoint cannot change its owner. If it is mode `600` and owned by root, make it readable by uid 1000 on the host (`chmod a+r`).

`input` and `user` are new host binds. Stack 250 kept those inside the `comfyui-laptop-data` volume (`/root/ComfyUI/input` and `/root/ComfyUI/user`). Copy them to `/mnt/tmd-secure/Data/Docker/ComfyUI/input` and `.../user` if they should follow this stack. Models, nodes, output, and mss-data stay on the same host directories as stack 250.

Before redeploy, clear any Portainer values that are still the old named-volume placeholders (`comfyui_models`, `comfyui_custom_nodes`, and the rest). A non-blank value replaces the `/mnt/tmd-secure/Data/Docker/ComfyUI/...` default. Also clear `COMFYUI_HOST` if it is `127.0.0.1`; the process must listen on `0.0.0.0` for the published ports, including the host watchdog on `127.0.0.1:9008`. `MODELS_DIR` and `NODES_DIR` in the stack environment are ignored. This image always uses `/app/ComfyUI/models` and `/app/ComfyUI/custom_nodes`.

Check the rendered stack with a blank env file:

```bash
docker compose --env-file .env.example -f portainer-stack.yml config
```

## Variables the compose file reads

Blank means the default. `.env.example` lists the same names with blank values. Paste real values into Portainer, not into git.

| Stack variable | Default when blank | Container variable |
|---|---|---|
| `COMFYUI_IMAGE` | `ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia` | image reference, not an env var |
| `COMFYUI_BIND_TAILSCALE` | `100.65.194.86` | published address |
| `COMFYUI_HOST` | `0.0.0.0` | inside `CLI_ARGS` (`--listen`) |
| `COMFYUI_PORT` | `9008` | inside `CLI_ARGS` and the healthcheck |
| `SHM_SIZE` | `4g` | shm size |
| `MEM_LIMIT` | `20g` | mem limit and deploy memory limit |
| `MEMSWAP_LIMIT` | `24g` | memswap limit |
| `CPUS_LIMIT` | `8` | CPU limit |
| `CPUS` | `4` | CPU reservation |
| `MEMORY` | `8G` | memory reservation |
| `AUTO_UPDATE` | `false` | Watchtower label on both services |
| `CUDA_VISIBLE_DEVICES` | `0,1` | `CUDA_VISIBLE_DEVICES` |
| `NVIDIA_VISIBLE_DEVICES` | `all` | `NVIDIA_VISIBLE_DEVICES` |
| `NVIDIA_DRIVER_CAPABILITIES` | `compute,utility` | `NVIDIA_DRIVER_CAPABILITIES` |
| `DEVICE_TYPE` | `cuda` | `DEVICE_TYPE` |
| `USE_CPU` | `0` | `USE_CPU` |
| `FORCE_REINSTALL_TORCH` | `0` | `FORCE_REINSTALL_TORCH` |
| `CORS` | `*` | inside `CLI_ARGS` |
| `VRAM_RESERVE_GB` | `1.5` | inside `CLI_ARGS` (`--reserve-vram`) |
| `FRONTEND_VERSION` | `latest` | inside `CLI_ARGS` (`--front-end-version`) |
| `EXTRA_CLI_ARGS` | empty | appended to `CLI_ARGS` |
| `PYTORCH_CUDA_ALLOC_CONF` | `expandable_segments:True` | `PYTORCH_CUDA_ALLOC_CONF` |
| `TZ` | `America/Boise` | `TZ` and `TIME_ZONE` |
| `CIVITAI_TOKEN` | empty | `CIVITAI_TOKEN` |
| `LOGIN_DEBUG_MODE` | `false` | `DEBUG_MODE` |
| `SECRET_KEY` | empty | `SECRET_KEY` |
| `NTFY_AUTH_TOKEN` | empty | `NTFY_API_KEY` |
| `HOST_BASE_URL` | `http://127.0.0.1:9008` | `HOST_BASE_URL` |
| `PREFER_OPENAI_AGENTS` | `1` | `COMFYUI_COPILOT_PREFER_OPENAI_AGENTS` |
| `MSS_DATA_DIR` | `/data/mss-login` | `MSS_LOGIN_DATA_DIR` and the mss-data mount target |
| `POST_HOST` | empty | `POSTGRES_HOST` |
| `POST_PORT` | empty | `POSTGRES_PORT` |
| `POST_DB` | empty | `POSTGRES_DATABASE` |
| `POST_USER` | empty | `POSTGRES_USER` |
| `POST_PASS` | empty | `POSTGRES_PASSWORD` |
| `CPE_EMBEDDED_CONVERT` | `true` | `CPE_EMBEDDED_CONVERT` |
| `EXPERIMENTAL_LOGIN_BACKGROUND` | `true` | `EXPERIMENTAL_LOGIN_BACKGROUND` |
| `WEBAUTHN_RP_ID` | empty | `WEBAUTHN_RP_ID` |
| `WEBAUTHN_RP_NAME` | `ComfyUI MSS-Login` | `WEBAUTHN_RP_NAME` |
| `WEBAUTHN_ORIGINS` | empty | `WEBAUTHN_ORIGINS` |
| `PYTHONUNBUFFERED` | `1` | `PYTHONUNBUFFERED` |
| `COMFYUI_USER_SCRIPTS_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/user-scripts` | host path mounted at `/home/comfy/user-scripts` |
| `COMFYUI_MODELS_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/models` | host path mounted at `/app/ComfyUI/models` |
| `COMFYUI_CUSTOM_NODES_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/nodes` | host path. The container value of this name is always `/app/ComfyUI/custom_nodes` |
| `COMFYUI_OUTPUT_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/output` | host path mounted at `/app/ComfyUI/output` |
| `COMFYUI_INPUT_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/input` | host path mounted at `/app/ComfyUI/input` |
| `COMFYUI_USER_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/user` | host path mounted at `/app/ComfyUI/user` |
| `COMFYUI_MSS_DATA_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/mss-data` | host path. Mounted at `MSS_DATA_DIR` |
| `COMFYUI_EXTRA_MODEL_PATHS` | `/mnt/tmd-secure/Data/Docker/ComfyUI/extra_model_paths.yaml` | host file mounted read-only at `/app/ComfyUI/extra_model_paths.yaml` |
| `COMFYUI_BASHRC` | `/mnt/tmd-secure/Data/Docker/ComfyUI/.bashrc` | host file mounted at `/home/comfy/.bashrc` |
| `COMFYUI_HF_CACHE_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/hf-cache` | host path mounted at `/home/comfy/.cache/huggingface/hub` |
| `COMFYUI_TORCH_CACHE_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/torch-cache` | host path mounted at `/home/comfy/.cache/torch/hub` |
| `COMFY_TUNNEL_TOKEN` | empty | `TUNNEL_TOKEN` on `comfyui-prod-tunnel` |

Set in the container and not read from the stack environment:

| Container variable | Value |
|---|---|
| `HOME` | `/home/comfy` |
| `MODELS_DIR` | `/app/ComfyUI/models` |
| `NODES_DIR` | `/app/ComfyUI/custom_nodes` |
| `COMFYUI_CUSTOM_NODES_DIR` | `/app/ComfyUI/custom_nodes` |
| `CLI_ARGS` | assembled from the listen, port, CORS, cross-attention, reserve-vram, frontend, `--disable-smart-memory`, and `--cache-lru 1` flags |
| `LD_LIBRARY_PATH` | venv `torch/lib` and `nvidia/{cu13,cudnn,cusparselt,nccl,nvshmem}/lib` |
| `HF_HOME` | `/home/comfy/.cache/huggingface` |
| `HUGGINGFACE_HUB_CACHE` | `/home/comfy/.cache/huggingface/hub` |
| `TORCH_HOME` | `/home/comfy/.cache/torch` |

`NTFY_AUTH_TOKEN` and `POST_HOST` / `POST_PORT` / `POST_DB` / `POST_USER` / `POST_PASS` keep the stack 250 names. The container still sees `NTFY_API_KEY` and `POSTGRES_*`.

## Updates inside a running container

`docker exec -u 1000 comfyui-server /app/update.sh` updates ComfyUI and PyTorch. It does not replace the MSS-Login checkout. Change that pin by publishing a new image.
