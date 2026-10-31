# ComfyUI MSS-Login image

Production image and Portainer stack for ComfyUI plus the [ComfyUI-MSS-Login](https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login) custom node.

The stack pulls `ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia`. It does not build during deploy. The `:nvidia` tag is published only by a manual GitHub Actions run.

## Publish

Workflow: `.github/workflows/publish-ghcr.yml`.

- Trigger: `workflow_dispatch` only. No push, tag, or schedule.
- Auth: the workflow `GITHUB_TOKEN` with `packages: write`. No other secrets.
- Input `target` (default `nvidia`; also `cpu`, `rocm`, `auto`): the Dockerfile stage to build. The nvidia stage uses CUDA channel `cu130` by default.
- Every run pushes `ghcr.io/monster-spawned-studios/comfyui-mss-login:sha-<12 character commit>` (nvidia) or `:sha-<12>-<target>` (other targets).
- Input `push_nvidia_tag` (boolean, default **off**) also pushes `:nvidia`, and only with `target` `nvidia`. Portainer re-pulls `:nvidia`, so leave this off until the image is ready to deploy.
- `:latest` and `:cuda` are refused. Optional input `tag` adds one extra tag (for example `cpu` or `rocm` for a local overlay).
- A final job sends an ntfy notification when the `NTFY_URL` and `NTFY_TOPIC` secrets exist; it is skipped otherwise.
- There is no workflow input for the MSS-Login pin. `MSS_LOGIN_REF` is the `ARG` default in the Dockerfile. A direct sha fetch is tried first; if that fails, the build fetches `development` and checks out that exact sha.

Build args:

| Arg | Default |
|---|---|
| `MSS_LOGIN_REPO` | `https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git` |
| `MSS_LOGIN_REF` | `1d9acbcee661088145e0adb38ab1dc829393108f` |
| `CUDA_VERSION` | `cu130` on the nvidia stage (`cu128` is the other accepted value) |

`cpu`, `rocm`, and `auto` remain Dockerfile targets. Build them locally with `docker build --target cpu` (or `rocm` / `auto`), or publish a sha tag with the workflow's `target` input. Only the nvidia image is reviewed for Portainer.

```bash
docker build --target nvidia \
  --build-arg MSS_LOGIN_REF=1d9acbcee661088145e0adb38ab1dc829393108f \
  -t ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia .
```

## What the image contains

- ComfyUI under `/app/ComfyUI`, Python 3.13 via uv, user `comfy` (uid/gid 1000).
- ComfyUI-MSS-Login at `/opt/mss-login/ComfyUI-MSS-Login`, owned by root. `/opt/mss-login/MANIFEST` is the sha256 of regular files. `MANIFEST.entries` lists every non-directory (including symlinks and fifos). `MANIFEST.dirs` lists directories. `.git`, `__pycache__`, `.pyc`, and `.pyo` are omitted. `/opt/mss-login/PATCHES` names `mss-login-no-inplace-update.patch`.
- `entrypoint.sh`, `update.sh`, `write-torch-constraints.sh`, `write-mss-login-manifest.sh`, `mss-login-healthcheck`, and `mss-download-models` are root:root mode `0755` in `/usr/local/bin`. The venv stays uid 1000. There is no `sitecustomize.py`. Root does not source `/home/comfy/.bashrc` or `/etc/profile.d`.
- `curl`, used by the healthcheck.
- NVIDIA stage: PyTorch CUDA wheels and `LD_LIBRARY_PATH` pointed at the venv cuDNN/CUDA libraries (`/app/ComfyUI/.venv/lib/python3.13/site-packages/...`). This replaces `user-scripts/00-setup-uv-venv.sh`, which targeted `/root/ComfyUI/.venv`. No script in the user-scripts mount is executed; see [Model downloads and user-scripts](#model-downloads-and-user-scripts).
- The host `custom_nodes/MSS-Login` checkout is not loaded. A tmpfs is mounted on that folder. Root copies the baked tree onto it, locks it `root:root` (`0755` directories, `0644` files), checks the manifest, and only then drops to uid 1000.
- NVIDIA stage also installs `onnxruntime-gpu==1.31.1` (CUDA 13 wheels), `insightface==2.1`, `onnx==1.23.2`, `gguf==0.19.0`, and `opencv-python-headless==5.0.0.93`, constrained to the baked torch/CUDA pins.
- sam2 is baked from `https://github.com/facebookresearch/sam2` commit `2b90b9f5ceec907a1c18123530e92e794ad901a4`. The image builds a wheel with `SAM2_BUILD_CUDA=0`, records its sha256 in `/opt/sam2/SHA256`, and installs that wheel with `--require-hashes --no-deps`. `hydra-core==1.3.8` and `iopath==0.1.10` are installed with it. Impact-Pack's `git+https://github.com/facebookresearch/sam2` line is skipped at runtime and the log names the node and the line.
- The container starts as root (`user: "0:0"`). The entrypoint immediately sets `PATH` to the system directories and unsets `LD_LIBRARY_PATH`, `LD_PRELOAD`, `LD_AUDIT`, `PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, `PYTHONUSERBASE`, `BASH_ENV`, and `ENV`. `setpriv` is `/usr/bin/setpriv`. The venv `bin` directory and the cuDNN `LD_LIBRARY_PATH` are added only for the uid 1000 process. A stack `LD_LIBRARY_PATH` is ignored by root. `dotenvx` `v2.38.2` is at `/usr/local/bin/dotenvx` (tarball sha256 `18196e97e94124de756cc728a1472bc242c81d9760733880522471f81484454e`). MSS-Login's `install_dependencies()` is a no-op in the image patch, and `auto_install_deps` plus `experimental.install_other_nodes_deps` are forced off.

## Portainer

Compose path: `portainer-stack.yml`. Do not attach the `hwaccel.*.yml` files. GPU passthrough for both devices is already in the stack (`CUDA_VISIBLE_DEVICES` default `0,1`, NVIDIA device reservation `count: ${GPU_COUNT:-all}`). GPU selection is environment-only: set `GPU_COUNT`, `CUDA_VISIBLE_DEVICES`, or `NVIDIA_VISIBLE_DEVICES` in the stack environment instead of editing YAML.

`pull_policy` is `${PULL_POLICY:-missing}`. `missing` pulls only when the image is absent. `always` re-pulls on every deploy, which behaves like auto-update. `build` is not valid here because the stack has no build section.

`COMPOSE_PROFILES` only controls the tunnel (`COMPOSE_PROFILES=tunnel`). There is no hardware profile: the NVIDIA service always starts. For local rocm or cpu runs use `docker compose -f portainer-stack.yml -f hwaccel.rocm.yml up -d` (or `hwaccel.cpu.yml`) with a locally built image.

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

The image revision is the full `MSS_LOGIN_REF` sha written to `/opt/mss-login/REVISION`. The running code is the image copy, not the host dev checkout. Edits to the host `nodes/MSS-Login` directory do not take effect in the container. Every MSS-Login change needs an image rebuild with a new `MSS_LOGIN_REF`.

`portainer-stack.yml` mounts a tmpfs at `/app/ComfyUI/custom_nodes/MSS-Login` (`uid=0`, `gid=0`, `mode=0755`, `noexec`, `nosuid`, no size cap). That folder name is fixed. `MSS_LOGIN_DIR` is not a stack variable; only `MSS_LOGIN_TEST_MODE=1` may point tests at another name. The host directory of the same name, including its `.venv` and `__pycache__`, stays on the host and is not read. Startup refuses unless `/proc/self/mountinfo` shows that exact path as fstype `tmpfs` and the directory is empty before the copy. Root then copies the baked tree, sets `root:root` with mode `0755` on directories and `0644` on files, and checks the shadow against the baked file hashes, the non-directory list, and the directory list. The check finishes before `setpriv`. A remount read-only is attempted. If the remount is not permitted, root ownership and those modes are the write barrier: uid 1000 cannot modify the tree.

Startup refuses `CLI_ARGS` and `EXTRA_CLI_ARGS` tokens that change node loading or a base path. From `comfy/cli_args.py` at `0dbfd493b4cc604db743c699f0f7ce01348e54a4`, the refused flags are `--disable-all-custom-nodes`, `--whitelist-custom-nodes`, `--enable-manager`, `--enable-manager-legacy-ui`, `--disabled-nodes-config`, `--disable-partner-nodes`, `--disable-api-nodes`, `--offline`, `--base-directory`, `--extra-model-paths-config`, `--output-directory`, `--temp-directory`, `--input-directory`, `--previews-directory`, `--user-directory`, and `--models-directory`. `--front-end-version`, `--listen`, `--port`, `--enable-cors-header`, `--use-pytorch-cross-attention`, `--reserve-vram`, `--disable-smart-memory`, and `--cache-lru` are not refused. `extra_model_paths.yaml` is parsed with PyYAML and refused when it contains a `custom_nodes` key or cannot be parsed. After ComfyUI starts, the entrypoint requires `GET /login` to return 200, 301, or 302 within 600 seconds and stops the process if it does not. The Docker healthcheck uses the same 600 second `start_period` because the first boot still checks Impact, RMBG, and controlnet_aux model files before the login route answers.

Python bytecode is written only under `PYTHONPYCACHEPREFIX=/tmp/comfy-pycache`. On startup, root deletes that directory and recreates it mode `0700` owned by uid 1000. Every `python` launch from the entrypoint and `update.sh` passes `--check-hash-based-pycs always`. The host `__pycache__` is under the covered mount, so it is not on the import path. Git metadata inside other custom nodes is read as uid 1000 with `safe.directory` set to that directory only.

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

## MSS-Login updates

Pinned `1d9acbcee661088145e0adb38ab1dc829393108f` stores update behavior in the data-dir `config.json` key `auto_update` (`utils/updater.py`). There is no environment variable for it. On every start the entrypoint sets `enabled` to true and `mode` to `notify`, so a newer release is still reported. `mode` is not `auto`, so the background check does not `git pull`.

`POST /mss-login/api/update-apply` ignores `auto_update` and would otherwise call `perform_update` (git pull plus pip). The image applies `patches/mss-login-no-inplace-update.patch` with `git apply --check` and then `git apply` before it writes the manifest. The build fails if that patch does not apply. `/opt/mss-login/PATCHES` records the patch name, and `/opt/mss-login/REVISION` stays the pinned commit. The patched route returns HTTP 403 and `Updates are applied by rebuilding the image with a new MSS_LOGIN_REF`. `perform_update` and `perform_recovery_update` return that same error and do not run git or pip. The Update now button is created in JavaScript (`web/js/auth.js` and `web/js/loading.js`), not a one-line template, so the button can still appear in notify mode. The API refuses it.

`utils/updater.py` line 533 writes `.last_update_check` into the plugin tree and ignores the error. In notify mode that write can be reached. Failure on the read-only shadow is expected.

## ComfyUI frontend

`--front-end-version Comfy-Org/ComfyUI_frontend@v1.55.11` is the stack 250 value. ComfyUI's `app/frontend_management.py` `init_frontend_unsafe` at commit `0dbfd493b4cc604db743c699f0f7ce01348e54a4` looks for `web_custom_versions/Comfy-Org_ComfyUI_frontend/1.55.11` under the ComfyUI root (`Path(__file__).parents[1]`, lines 390–400). If that directory exists it does not download. The image extracts the release asset `dist.zip` there after checking sha256 `37fac946be14a9cd96ec3fc0dd92fca826c24093c11e1e7184262f8a187f1071`, then makes `/app/ComfyUI` and that tree root:root mode `0755`/`0644`. uid 1000 cannot replace it, and startup does not need GitHub.

To bump it, change both Dockerfile `ARG`s and rebuild:

- `COMFYUI_FRONTEND_VERSION` (default `v1.55.11`, the tag on `https://github.com/Comfy-Org/ComfyUI_frontend/releases`)
- `COMFYUI_FRONTEND_SHA256` (`sha256sum` of that tag's `dist.zip`)

The directory name drops the leading `v`. Set stack `FRONTEND_VERSION` to the same tag. `CLI_ARGS` and `EXTRA_CLI_ARGS` are one extra argument string. If both are non-empty and not the same text, startup refuses. A `--listen` or `--port` in that string is the one that is launched; the image default is not also passed. Other repeated flags follow argparse, which keeps the last value. The healthcheck (`/usr/local/bin/mss-login-healthcheck`) reads that same assembly and curls `127.0.0.1` on the resulting port.

## Updating MSS-Login

1. Push the MSS-Login commits to `https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git`.
2. Open a pull request in this repository that changes the `ARG MSS_LOGIN_REF` default in the `Dockerfile` to that full commit sha. That `ARG` is the only pin. `.github/workflows/publish-ghcr.yml` does not take an `mss_login_ref` input and does not pass `MSS_LOGIN_REF` as a build-arg, so a dispatch cannot select a different commit. If `patches/mss-login-no-inplace-update.patch` no longer applies, update that file in the same pull request. Security reviews the pin and the patch.
3. Merge the pull request to `production`.
4. Manually run the `Publish image` workflow (`.github/workflows/publish-ghcr.yml`, `workflow_dispatch`) with `target` `nvidia`. Set the input `push_nvidia_tag` to true to publish `ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia`. Every run also pushes the immutable tag `sha-<first 12 characters of GITHUB_SHA>`. Leave `tag` blank unless an extra tag is required. Do not use `latest`.
5. Redeploy the ComfyUI stack in Portainer (the new stack created in the Portainer UI with auto-update off; stack 256 was deleted). The stack image is `ghcr.io/monster-spawned-studios/comfyui-mss-login:nvidia` (`COMFYUI_IMAGE`). With auto-update off, Portainer does not re-pull on a schedule: pull the image and redeploy the stack by hand. Watchtower stays off (`AUTO_UPDATE` default `false`). Confirm `/opt/mss-login/REVISION` is the new sha and that the log contains `MSS-Login shadow` and `mode=notify`. `GET /login` must return 200, 301, or 302.
6. Rollback by setting `COMFYUI_IMAGE` to the previous `ghcr.io/monster-spawned-studios/comfyui-mss-login:sha-<12>` tag and redeploying the stack. Do not retag `:nvidia` backward unless that image is the one that should stay current.

## Model downloads and user-scripts

The host user-scripts directory (`COMFYUI_USER_SCRIPTS_DIR`, mounted at `/home/comfy/user-scripts`) is read as data only. The container never runs `pre-start.sh` or any other script from it.

Before ComfyUI starts, and after the MSS-Login shadow, pin, and custom-node dependency steps, the entrypoint runs the baked `/usr/local/bin/mss-download-models` as uid 1000. It is the development branch's `01-download-models.sh` with these limits:

- It refuses to run as root.
- It reads `/home/comfy/user-scripts/models-to-download.txt`, or `MODELS_TO_DOWNLOAD` (comma-separated) when set. The format is unchanged (`type:hf:…`, `type:civitai:<version id>`, `type:https://…`). `user-scripts/models-to-download.txt` in this repo is the current list; copy it to the host directory.
- Every write stays inside `/app/ComfyUI/models`. `MODELS_DOWNLOAD_DIR` outside that folder is ignored. Destinations that resolve outside it, symlinks, and file names with a path or leading dot are refused. The hash cache is `models/.download-hash-cache.tsv`.
- Checksums from Hugging Face, CivitAI, or the server are verified when published. `HF_TOKEN` goes only to huggingface.co and `CIVITAI_TOKEN` only to civitai.com.
- Failures are logged and startup continues. `DOWNLOAD_MODELS=false` skips the step. Large first downloads delay startup; the 600s healthcheck start period starts counting at container start.

Not carried from the development user-scripts, because each one runs host-editable code or changes code that ComfyUI loads, outside the pin, the shadow, or the allowlist: `pre-start.sh` (root hook), `00-setup-uv-venv.sh` (replaced by the baked venv), `02-download-nodes.sh` and `custom-nodes.txt` (git clone of nodes), `03-install-node-deps.sh` (replaced by the allowlisted install below), `04-set-permissions.sh` (replaced by the entrypoint's fixed chown list), `05-reapply-multigpu-fp8.sh` (patches node code), and the `sqlalchemy`/`sageattention` upgrade (unpinned pip install).

## Runtime custom-node dependencies

`INSTALL_CUSTOM_NODE_DEPS` defaults to true. Only directories whose names appear, exactly, in `config/custom-node-deps-allowlist.txt` are installed. Every other `requirements.txt` is logged and skipped. MSS-Login is never installed at runtime; its resolved packages are pinned in `/opt/comfy-constraints/torch.txt` at build time together with torch and the CUDA wheels.

Stamps live in the venv (`.mss-node-dep-stamps`) and include the image revision, the constraints hash, and `/app/ComfyUI/.venv/.mss-build-id`, so a new image reinstalls.

Requirement lines that are options, nested includes, editable installs, local paths, path separators, wheels, sdists (`.whl`, `.zip`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`), or any URL are dropped. The log line is `Skipping requirement for node <name>: <line>`, so a VCS URL such as Impact-Pack's `git+https://github.com/facebookresearch/sam2` names both the node and the line. sam2 is already in the image. Installs use PyPI only, as uid 1000.

`comfyui_ryanonyheinside` and `comfyui-supir` have a `requirements.txt` but no verifiable git remote, so they are not on the allowlist. Workflows that import them will fail until that list is updated.

## InsightFace models

InstantID and PuLID load faces from ComfyUI's `models/insightface`, not from `INSIGHTFACE_HOME`. The stack bind-mounts the host directory read-only at `/app/ComfyUI/models/insightface`.

The default host path is `/mnt/tmd-secure/Data/Docker/ComfyUI/models/insightface`. That directory already holds verified `antelopev2` and `buffalo_l` and must exist before deploy. Compose is set to `create_host_path: false`, so Docker will not create an empty root-owned directory if the path is missing. The entrypoint logs a warning when the mount is missing or empty. The image does not download these packs.

`extra_model_paths.yaml` and `.bashrc` must already be files on the host. Docker creates a directory if a file bind is missing, and the entrypoint then refuses to start. `extra_model_paths.yaml` is mounted read-only. A `custom_nodes` key in it is refused. If the file is mode `600` and owned by root, make it readable by uid 1000 on the host (`chmod a+r`). The entrypoint does not source `.bashrc`.

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
| `PULL_POLICY` | `missing` | compose `pull_policy`, not an env var |
| `GPU_COUNT` | `all` | NVIDIA device reservation count, not an env var |
| `CUDA_VISIBLE_DEVICES` | `0,1` | `CUDA_VISIBLE_DEVICES` |
| `NVIDIA_VISIBLE_DEVICES` | `all` | `NVIDIA_VISIBLE_DEVICES` |
| `NVIDIA_DRIVER_CAPABILITIES` | `compute,utility` | `NVIDIA_DRIVER_CAPABILITIES` |
| `DEVICE_TYPE` | `cuda` | `DEVICE_TYPE` |
| `USE_CPU` | `0` | `USE_CPU` |
| `FORCE_REINSTALL_TORCH` | `0` | `FORCE_REINSTALL_TORCH` |
| `INSTALL_CUSTOM_NODE_DEPS` | `true` | `INSTALL_CUSTOM_NODE_DEPS` |
| `COMFYUI_INSIGHTFACE_DIR` | `/mnt/tmd-secure/Data/Docker/ComfyUI/models/insightface` | existing host directory, mounted read-only at `/app/ComfyUI/models/insightface` |
| `CORS` | `*` | inside `CLI_ARGS` |
| `VRAM_RESERVE_GB` | `1.5` | inside `CLI_ARGS` (`--reserve-vram`) |
| `FRONTEND_VERSION` | `v1.55.11` | `--front-end-version Comfy-Org/ComfyUI_frontend@<version>` when that flag is absent |
| `CLI_ARGS` | empty | `STACK_CLI_ARGS`. Alias of `EXTRA_CLI_ARGS` (stack 250). Both set and different refuses to start |
| `EXTRA_CLI_ARGS` | empty | `EXTRA_CLI_ARGS` |
| `PYTORCH_CUDA_ALLOC_CONF` | `expandable_segments:True` | `PYTORCH_CUDA_ALLOC_CONF` |
| `TZ` | `America/Boise` | `TZ` and `TIME_ZONE` |
| `CIVITAI_TOKEN` | empty | `CIVITAI_TOKEN` |
| `HF_TOKEN` | empty | `HF_TOKEN` |
| `DOWNLOAD_MODELS` | `true` | `DOWNLOAD_MODELS` |
| `MODELS_TO_DOWNLOAD` | empty | `MODELS_TO_DOWNLOAD` |
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
| `LD_LIBRARY_PATH` | venv `torch/lib` and `nvidia/{cu13,cudnn,cusparselt,nccl,nvshmem}/lib` |
| `HF_HOME` | `/home/comfy/.cache/huggingface` |
| `HUGGINGFACE_HUB_CACHE` | `/home/comfy/.cache/huggingface/hub` |
| `TORCH_HOME` | `/home/comfy/.cache/torch` |
| `XDG_CACHE_HOME` | `/home/comfy/.cache` |

`NTFY_AUTH_TOKEN` and `POST_HOST` / `POST_PORT` / `POST_DB` / `POST_USER` / `POST_PASS` keep the stack 250 names. The container still sees `NTFY_API_KEY` and `POSTGRES_*`.

## Updates inside a running container

`/app/ComfyUI` is root-owned, so `comfy update` cannot change ComfyUI core inside a running container. A core update is a new image build. `docker exec -u 1000 comfyui-server /usr/local/bin/update.sh` can still refresh PyTorch wheels in the venv. It does not replace MSS-Login. Change that pin with the steps in [Updating MSS-Login](#updating-mss-login).
