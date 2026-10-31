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
- ComfyUI-MSS-Login is fetched over HTTPS at build time. The single pin is `MSS_LOGIN_REF`, default `1d9acbcee661088145e0adb38ab1dc829393108f` (development). The repo URL cannot contain credentials. A direct sha fetch is tried first; if that fails, the build fetches `development` and checks out that exact sha.

Build args:

| Arg | Default |
|---|---|
| `MSS_LOGIN_REPO` | `https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git` |
| `MSS_LOGIN_REF` | `1d9acbcee661088145e0adb38ab1dc829393108f` |
| `CUDA_VERSION` | `cu130` on the nvidia stage (`cu128` is the other accepted value) |

`cpu`, `rocm`, and `auto` remain Dockerfile targets. Build them locally with `docker build --target cpu` (or `rocm` / `auto`). The workflow does not publish those tags.

```bash
docker build --target nvidia \
  --build-arg MSS_LOGIN_REF=1d9acbcee661088145e0adb38ab1dc829393108f \
  -t ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia .
```

## What the image contains

- ComfyUI under `/app/ComfyUI`, Python 3.13 via uv, user `comfy` (uid/gid 1000).
- ComfyUI-MSS-Login at `/opt/mss-login/ComfyUI-MSS-Login` (the image seed).
- `curl`, used by the healthcheck.
- NVIDIA stage: PyTorch CUDA wheels and `LD_LIBRARY_PATH` pointed at the venv cuDNN/CUDA libraries (`/app/ComfyUI/.venv/lib/python3.13/site-packages/...`). This replaces `user-scripts/00-setup-uv-venv.sh`, which targeted `/root/ComfyUI/.venv`. The script is still mounted and is not executed.
- `entrypoint.sh` seeds MSS-Login into `custom_nodes/MSS-Login` only when no copy of the package is already mounted. Detection uses the pyproject name `MSS-Login` or `mss_login.py` (`create_mss_login_middleware`), not the folder name and not the git remote. One existing copy is reused. Two copies refuse to start. The checkout HEAD must equal `/opt/mss-login/REVISION`.
- NVIDIA stage also installs `onnxruntime-gpu==1.31.1` (CUDA 13 wheels), `insightface==2.1`, `onnx==1.23.2`, `gguf==0.19.0`, and `opencv-python-headless==5.0.0.93`, constrained to the baked torch/CUDA pins.
- The container starts as root (`user: "0:0"`) so the entrypoint can `chown` root-owned volume data to uid 1000, then drops privileges with `setpriv`. A directory whose top-level owner is already 1000 is not walked again.

## Portainer

Compose path: `portainer-stack.yml`. Do not attach the `hwaccel.*.yml` files. GPU passthrough for both devices is already in the stack (`CUDA_VISIBLE_DEVICES` default `0,1`, NVIDIA device reservation `count: all`).

Runtime defaults: memory limit `20g`, memswap `24g`, CPU limit `8`, CPU reservation `4`, `--cache-lru 1`, `--disable-smart-memory`, `--reserve-vram` from `VRAM_RESERVE_GB` (default `1.5`).

Ports: `100.65.194.86:9008` and `127.0.0.1:9008`.

Watchtower labels default to `false`. That does not turn off Portainer's own re-pull of `:nvidia`.

Container name is `comfyui-server`. Stack 250 used `comfyui-cuda-laptop`. ServerOps must point the Cloudflare tunnel at `http://comfyui-server:9008`. The tunnel container name stays `comfyui-prod-tunnel`, and it does not start unless the `tunnel` profile is enabled.

## Cloudflare tunnel

`cloudflared` is pinned to `2026.10.7` with digest `sha256:4955524aeaa379e154023d5a027c250f7b35041a2e7e950cf13f144bc9b9c5ba` and is behind `profiles: [tunnel]`.

In Portainer, open the stack environment variables and set `COMPOSE_PROFILES` to `tunnel`, then redeploy. From a shell:

```bash
COMPOSE_PROFILES=tunnel docker compose -f portainer-stack.yml up -d
```

Leave `COMPOSE_PROFILES` unset to keep the tunnel off.

## MSS-Login pin

The image revision is the full `MSS_LOGIN_REF` sha written to `/opt/mss-login/REVISION`. Startup accepts a host copy only when all of these hold:

- `diff -rq --exclude=.git --no-dereference` against `/opt/mss-login/ComfyUI-MSS-Login` is empty. `__pycache__`, `.pyc`, and `.pyo` are part of that comparison.
- the host tree contains no `__pycache__` directory and no `.pyc` or `.pyo` file
- `git rev-parse --show-toplevel` is that directory, not a parent repo
- `git cat-file -e <revision>^{commit}` succeeds and `HEAD` is that commit
- `git status --porcelain --untracked-files=all --ignored` is empty, so a gitignored file cannot hide

A dirty file, an untracked file, a gitignored file, a planted `.pyc`, a forged `.git/HEAD` with no commit object, or a renamed-but-edited tree refuses to start. The host files are not overwritten. A second copy, including one found by a baked file hash or by a git remote of `ComfyUI-MSS-Login`, also refuses to start.

Python bytecode for the app is written only under `PYTHONPYCACHEPREFIX=/tmp/comfy-pycache`. That directory is not a host mount and is not under mss-data. The image sets it, and the entrypoint sets it again before any `python` or `uv` command, so a `.pyc` beside the mounted source is not imported.

`MSS_LOGIN_DIR` (default `MSS-Login`) is only the folder used when nothing matches. An exact copy under another folder name is reused.

There is no stack variable and no file on the mss-data volume that disables the pin. A file named `MSS_LOGIN_BREAK_GLASS` is ignored. The only emergency path is a one-off process:

```bash
docker run -e MSS_LOGIN_ALLOW_UNPINNED=true ...
```

Do not add that variable to the Portainer stack. Rebuild with a new `MSS_LOGIN_REF` to change what is allowed to run.

## Runtime custom-node dependencies

`INSTALL_CUSTOM_NODE_DEPS` defaults to true. Only directories whose names appear, exactly, in `config/custom-node-deps-allowlist.txt` are installed. Every other `requirements.txt` is logged and skipped. MSS-Login is never installed at runtime; its resolved packages are pinned in `/opt/comfy-constraints/torch.txt` at build time together with torch and the CUDA wheels.

Stamps live in the venv (`.mss-node-dep-stamps`) and include the image revision, the constraints hash, and `/app/ComfyUI/.venv/.mss-build-id`, so a new image reinstalls.

Requirement lines that are options, nested includes, editable installs, local paths, path separators, wheels, sdists (`.whl`, `.zip`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`), or any URL are dropped and logged. Installs use PyPI only, as uid 1000.

`comfyui_ryanonyheinside` and `comfyui-supir` have a `requirements.txt` but no verifiable git remote, so they are not on the allowlist. Workflows that import them will fail until that list is updated.

## InsightFace models

InstantID and PuLID load faces from ComfyUI's `models/insightface`, not from `INSIGHTFACE_HOME`. The stack bind-mounts the host directory read-only at `/app/ComfyUI/models/insightface`.

The default host path is `/mnt/tmd-secure/Data/Docker/ComfyUI/models/insightface`. That directory already holds verified `antelopev2` and `buffalo_l` and must exist before deploy. Compose is set to `create_host_path: false`, so Docker will not create an empty root-owned directory if the path is missing. The entrypoint logs a warning when the mount is missing or empty. The image does not download these packs.

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
| `MSS_LOGIN_DIR` | `MSS-Login` | seed folder name; detection does not use it |
| `INSTALL_CUSTOM_NODE_DEPS` | `true` | `INSTALL_CUSTOM_NODE_DEPS` |
| `COMFYUI_INSIGHTFACE_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/models/insightface` | existing host directory, mounted read-only at `/app/ComfyUI/models/insightface` |
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
