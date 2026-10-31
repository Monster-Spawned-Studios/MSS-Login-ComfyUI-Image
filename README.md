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
- ComfyUI-MSS-Login at `/opt/mss-login/ComfyUI-MSS-Login`, owned by root, with `/opt/mss-login/MANIFEST` (sha256 of every file that is copied onto the shadow). `.git`, `__pycache__`, `.pyc`, and `.pyo` are not in that manifest.
- `curl`, used by the healthcheck.
- NVIDIA stage: PyTorch CUDA wheels and `LD_LIBRARY_PATH` pointed at the venv cuDNN/CUDA libraries (`/app/ComfyUI/.venv/lib/python3.13/site-packages/...`). This replaces `user-scripts/00-setup-uv-venv.sh`, which targeted `/root/ComfyUI/.venv`. The script is still mounted and is not executed.
- The host `custom_nodes/MSS-Login` checkout is not loaded. A tmpfs is mounted on that folder. Root copies the baked tree onto it, locks it `root:root` (`0755` directories, `0644` files), checks the manifest, and only then drops to uid 1000.
- NVIDIA stage also installs `onnxruntime-gpu==1.31.1` (CUDA 13 wheels), `insightface==2.1`, `onnx==1.23.2`, `gguf==0.19.0`, and `opencv-python-headless==5.0.0.93`, constrained to the baked torch/CUDA pins.
- sam2 is baked from `https://github.com/facebookresearch/sam2` commit `2b90b9f5ceec907a1c18123530e92e794ad901a4`. The image builds a wheel with `SAM2_BUILD_CUDA=0`, records its sha256 in `/opt/sam2/SHA256`, and installs that wheel with `--require-hashes --no-deps`. `hydra-core==1.3.8` and `iopath==0.1.10` are installed with it. Impact-Pack's `git+https://github.com/facebookresearch/sam2` line is skipped at runtime and the log names the node and the line.
- The container starts as root (`user: "0:0"`) so the entrypoint can `chown` root-owned volume data to uid 1000 and seed the shadow, then drops privileges with `setpriv`. The shadow stays root-owned. A directory whose top-level owner is already 1000 is not walked again.

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

The image revision is the full `MSS_LOGIN_REF` sha written to `/opt/mss-login/REVISION`. The running code is the image copy, not the host dev checkout.

`portainer-stack.yml` mounts a tmpfs at `/app/ComfyUI/custom_nodes/${MSS_LOGIN_DIR:-MSS-Login}` (`uid=0`, `gid=0`, `mode=0755`, `noexec`, `nosuid`, no size cap). That is the folder ComfyUI loads. The host directory of the same name, including its `.venv` and `__pycache__`, stays on the host and is not read. Startup refuses unless `/proc/self/mountinfo` shows that exact path with fstype `tmpfs` and the directory is empty before the copy. Root then copies the baked tree, sets `root:root` with mode `0755` on directories and `0644` on files, and checks every copied file against `/opt/mss-login/MANIFEST`. The check finishes before `setpriv`. A remount read-only is attempted. If the remount is not permitted, root ownership and those modes are the write barrier: uid 1000 cannot modify the tree.

Python bytecode is written only under `PYTHONPYCACHEPREFIX=/tmp/comfy-pycache`. The image sets that variable, the entrypoint forces it again before any `python` or `uv` command, and `sitecustomize.py` sets `sys.pycache_prefix` to the same directory. The host `__pycache__` is under the covered mount, so it is not on the import path.

### Duplicate custom nodes

ComfyUI is installed with `comfy install --version latest`, so this image does not pin the ComfyUI git sha. The duplicate check follows the loader in [`nodes.py` `init_external_custom_nodes`](https://github.com/comfyanonymous/ComfyUI/blob/0dbfd493b4cc604db743c699f0f7ce01348e54a4/nodes.py#L2371-L2380) at commit `0dbfd493b4cc604db743c699f0f7ce01348e54a4`:

```python
possible_modules = os.listdir(os.path.realpath(custom_node_path))
if "__pycache__" in possible_modules:
    possible_modules.remove("__pycache__")
for possible_module in possible_modules:
    module_path = os.path.join(custom_node_path, possible_module)
    if os.path.isfile(module_path) and os.path.splitext(module_path)[1] != ".py":
        continue
    if module_path.endswith(".disabled"):
        continue
```

Those are the only skips. A hidden directory such as `.venv` is still a loader entry when it sits directly in `custom_nodes`. Each loadable entry's root is checked for the pyproject name `MSS-Login`, `create_mss_login_middleware` in `mss_login.py`, a git remote of this plugin whose toplevel is that directory, or a sha256 match of a baked root file. Nested `.venv` or `node_modules` inside a node are not walked. A second match refuses to start. `*.disabled`, the `__pycache__` name, and non-`.py` files are not matches, because the loader does not import them. Optional manager and governance skips in that same function are not treated as skips here.

`MSS_LOGIN_ALLOW_UNPINNED=true` does not load the host tree and does not skip the tmpfs or manifest check. A file named `MSS_LOGIN_BREAK_GLASS` on the mss-data volume is ignored. There is no stack variable for this. The only way to set the environment variable is a one-off process:

```bash
docker run -e MSS_LOGIN_ALLOW_UNPINNED=true ...
```

Do not add that variable to the Portainer stack. Rebuild with a new `MSS_LOGIN_REF` to change what the shadow runs.

## Runtime custom-node dependencies

`INSTALL_CUSTOM_NODE_DEPS` defaults to true. Only directories whose names appear, exactly, in `config/custom-node-deps-allowlist.txt` are installed. Every other `requirements.txt` is logged and skipped. MSS-Login is never installed at runtime; its resolved packages are pinned in `/opt/comfy-constraints/torch.txt` at build time together with torch and the CUDA wheels.

Stamps live in the venv (`.mss-node-dep-stamps`) and include the image revision, the constraints hash, and `/app/ComfyUI/.venv/.mss-build-id`, so a new image reinstalls.

Requirement lines that are options, nested includes, editable installs, local paths, path separators, wheels, sdists (`.whl`, `.zip`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`), or any URL are dropped. The log line is `Skipping requirement for node <name>: <line>`, so a VCS URL such as Impact-Pack's `git+https://github.com/facebookresearch/sam2` names both the node and the line. sam2 is already in the image. Installs use PyPI only, as uid 1000.

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
| `MSS_LOGIN_DIR` | `MSS-Login` | folder ComfyUI loads; tmpfs target under `custom_nodes` |
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
