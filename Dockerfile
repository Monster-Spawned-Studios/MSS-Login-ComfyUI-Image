# ComfyUI runtime. ComfyUI-MSS-Login is not in this repository; the image
# fetches it over HTTPS at build time. The single pin is MSS_LOGIN_REF
# (development 1d9acbcee661088145e0adb38ab1dc829393108f). The full sha is
# written to /opt/mss-login/REVISION. The entrypoint does not run the host
# checkout. It copies this tree onto a root-owned tmpfs and checks MANIFEST.
# https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login
#
# Targets: cpu, nvidia, rocm, auto. The GitHub workflow publishes nvidia only.

FROM ubuntu:24.04 AS base

ARG MSS_LOGIN_REPO=https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git
ARG MSS_LOGIN_REF=1d9acbcee661088145e0adb38ab1dc829393108f

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    UV_INSTALL_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_TOOL_DIR=/opt/uv-tools \
    UV_CACHE_DIR=/tmp/uv-cache \
    VIRTUAL_ENV=/app/ComfyUI/.venv \
    PATH="/app/ComfyUI/.venv/bin:/usr/local/bin:/usr/bin:/bin" \
    MSS_LOGIN_SEED=/opt/mss-login/ComfyUI-MSS-Login \
    MSS_LOGIN_DATA_DIR=/data/mss-login \
    PYTHONPYCACHEPREFIX=/tmp/comfy-pycache \
    DEVICE_TYPE=auto

# curl is the container healthcheck client. git fetches the pinned custom node.
# libsqlcipher-dev builds sqlcipher3 from the pinned requirements.
# uv installer: https://docs.astral.sh/uv/getting-started/installation/
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        ffmpeg \
        git \
        libgl1 \
        libglib2.0-0 \
        libsqlcipher-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && uv python install 3.13 \
    && uv tool install comfy-cli

WORKDIR /app

RUN comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI install --version latest --cpu --fast-deps \
    && rm -rf /tmp/uv-cache

WORKDIR /opt/mss-login
RUN if [[ "${MSS_LOGIN_REPO}" != https://* ]]; then \
      echo "MSS_LOGIN_REPO must be an https:// URL" >&2; \
      exit 1; \
    fi \
    && if [[ "${MSS_LOGIN_REPO}" == *"@"* ]]; then \
      echo "MSS_LOGIN_REPO must not embed credentials" >&2; \
      exit 1; \
    fi \
    && if [[ ! "${MSS_LOGIN_REF}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then \
      echo "MSS_LOGIN_REF must be a 7-40 character commit SHA" >&2; \
      exit 1; \
    fi \
    && git init --quiet ComfyUI-MSS-Login \
    && git -C ComfyUI-MSS-Login remote add origin "${MSS_LOGIN_REPO}" \
    && if ! GIT_TERMINAL_PROMPT=0 git -C ComfyUI-MSS-Login fetch --depth 1 origin "${MSS_LOGIN_REF}"; then \
      echo "Direct fetch of ${MSS_LOGIN_REF} failed; fetching development and checking out that sha." >&2; \
      GIT_TERMINAL_PROMPT=0 git -C ComfyUI-MSS-Login fetch origin development; \
    fi \
    && git -C ComfyUI-MSS-Login checkout --detach "${MSS_LOGIN_REF}" \
    && got="$(git -C ComfyUI-MSS-Login rev-parse HEAD)" \
    && if [[ "${got}" != "${MSS_LOGIN_REF}"* ]]; then \
      echo "checked out ${got}, wanted ${MSS_LOGIN_REF}" >&2; \
      exit 1; \
    fi \
    && printf '%s\n' "${got}" > /opt/mss-login/REVISION \
    && uv pip install --python /app/ComfyUI/.venv/bin/python -r /opt/mss-login/ComfyUI-MSS-Login/requirements.txt \
    && rm -rf /tmp/uv-cache

# These stay root:root under /usr/local/bin. The later chown of /app must not
# cover them: uid 1000 can write the venv, and root executes this entrypoint.
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 update.sh /usr/local/bin/update.sh
COPY --chmod=755 scripts/write-torch-constraints.sh /usr/local/bin/write-torch-constraints.sh
COPY --chmod=755 scripts/write-mss-login-manifest.sh /usr/local/bin/write-mss-login-manifest.sh
COPY --chmod=755 scripts/mss-login-healthcheck /usr/local/bin/mss-login-healthcheck
COPY patches/mss-login-no-inplace-update.patch /opt/mss-login/patches/mss-login-no-inplace-update.patch
COPY config/custom-node-deps-allowlist.txt /opt/mss-login/custom-node-deps-allowlist.txt

# facebookresearch/sam2 main at the time of this pin. The wheel is built in
# this stage with CUDA extensions off, hash-checked, and installed with
# --require-hashes. Impact-Pack's git+ line is dropped at runtime.
ARG SAM2_REPO=https://github.com/facebookresearch/sam2.git
ARG SAM2_REF=2b90b9f5ceec907a1c18123530e92e794ad901a4
# ComfyUI app/frontend_management.py (0dbfd493) uses
# web_custom_versions/<owner>_<repo>/<version without v> and skips the GitHub
# download when that directory already exists.
ARG COMFYUI_FRONTEND_VERSION=v1.55.11
ARG COMFYUI_FRONTEND_SHA256=37fac946be14a9cd96ec3fc0dd92fca826c24093c11e1e7184262f8a187f1071
ARG DOTENVX_VERSION=v2.38.2
ARG DOTENVX_SHA256=18196e97e94124de756cc728a1472bc242c81d9760733880522471f81484454e

RUN mkdir -p \
        /data/mss-login \
        /app/ComfyUI/custom_nodes \
        /app/ComfyUI/input \
        /app/ComfyUI/models \
        /app/ComfyUI/output \
        /app/ComfyUI/user \
        /app/ComfyUI/temp \
        /opt/comfy-frontend \
    && curl -fsSL -o /tmp/frontend-dist.zip \
        "https://github.com/Comfy-Org/ComfyUI_frontend/releases/download/${COMFYUI_FRONTEND_VERSION}/dist.zip" \
    && echo "${COMFYUI_FRONTEND_SHA256}  /tmp/frontend-dist.zip" | sha256sum -c - \
    && frontend_dir="/app/ComfyUI/web_custom_versions/Comfy-Org_ComfyUI_frontend/${COMFYUI_FRONTEND_VERSION#v}" \
    && mkdir -p "${frontend_dir}" \
    && /app/ComfyUI/.venv/bin/python -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' /tmp/frontend-dist.zip "${frontend_dir}" \
    && rm -f /tmp/frontend-dist.zip \
    && printf '%s\n' "${COMFYUI_FRONTEND_VERSION}" > /opt/comfy-frontend/VERSION \
    && printf '%s\n' "${COMFYUI_FRONTEND_SHA256}" > /opt/comfy-frontend/SHA256 \
    && curl -fsSL -o /tmp/dotenvx.tar.gz \
        "https://github.com/dotenvx/dotenvx/releases/download/${DOTENVX_VERSION}/dotenvx-${DOTENVX_VERSION#v}-linux-x86_64.tar.gz" \
    && echo "${DOTENVX_SHA256}  /tmp/dotenvx.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/dotenvx.tar.gz -C /tmp \
    && mv /tmp/dotenvx /usr/local/bin/dotenvx \
    && rm -f /tmp/dotenvx.tar.gz \
    && chown root:root /usr/local/bin/dotenvx \
    && chmod 755 /usr/local/bin/dotenvx \
    && (getent group comfy >/dev/null || groupadd --gid 1000 comfy) \
    && (id -u comfy >/dev/null 2>&1 || useradd --uid 1000 --gid 1000 --create-home --home-dir /home/comfy --shell /bin/bash comfy) \
    && (getent group render >/dev/null || groupadd --system render) \
    && usermod -aG video,render comfy \
    && mkdir -p \
        /home/comfy/.cache/huggingface/hub \
        /home/comfy/.cache/torch/hub \
        /home/comfy/user-scripts \
        /opt/comfy-constraints \
        /tmp/comfy-pycache \
    && chown 1000:1000 /tmp/comfy-pycache \
    && chmod 0700 /tmp/comfy-pycache \
    && /usr/local/bin/write-torch-constraints.sh \
    && cp /opt/mss-login/REVISION /app/ComfyUI/.venv/.mss-build-id \
    && git -C /opt/mss-login/ComfyUI-MSS-Login apply --check /opt/mss-login/patches/mss-login-no-inplace-update.patch \
    && git -C /opt/mss-login/ComfyUI-MSS-Login apply /opt/mss-login/patches/mss-login-no-inplace-update.patch \
    && printf '%s\n' "mss-login-no-inplace-update.patch" > /opt/mss-login/PATCHES \
    && /usr/local/bin/write-mss-login-manifest.sh /opt/mss-login/ComfyUI-MSS-Login /opt/mss-login/MANIFEST \
    && if [[ "${SAM2_REPO}" != "https://github.com/facebookresearch/sam2.git" && "${SAM2_REPO}" != "https://github.com/facebookresearch/sam2" ]]; then \
         echo "SAM2_REPO must be https://github.com/facebookresearch/sam2.git" >&2; \
         exit 1; \
       fi \
    && if [[ "${SAM2_REPO}" == *"@"* ]]; then \
         echo "SAM2_REPO must not embed credentials" >&2; \
         exit 1; \
       fi \
    && if [[ ! "${SAM2_REF}" =~ ^[0-9a-f]{40}$ ]]; then \
         echo "SAM2_REF must be a full 40-character lowercase commit SHA" >&2; \
         exit 1; \
       fi \
    && git init --quiet /tmp/sam2-src \
    && git -C /tmp/sam2-src remote add origin "${SAM2_REPO}" \
    && GIT_TERMINAL_PROMPT=0 git -C /tmp/sam2-src fetch --depth 1 origin "${SAM2_REF}" \
    && git -C /tmp/sam2-src checkout --detach "${SAM2_REF}" \
    && got="$(git -C /tmp/sam2-src rev-parse HEAD)" \
    && if [[ "${got}" != "${SAM2_REF}" ]]; then \
         echo "sam2 checkout ${got}, wanted ${SAM2_REF}" >&2; \
         exit 1; \
       fi \
    && SAM2_BUILD_CUDA=0 uv build --wheel --out-dir /opt/sam2 /tmp/sam2-src \
    && rm -rf /tmp/sam2-src \
    && whl="$(find /opt/sam2 -maxdepth 1 -type f -name '*.whl' -print)" \
    && if [[ -z "${whl}" || "$(printf '%s\n' "${whl}" | wc -l)" -ne 1 ]]; then \
         echo "expected one sam2 wheel in /opt/sam2" >&2; \
         exit 1; \
       fi \
    && sha256sum "${whl}" | awk '{print $1}' > /opt/sam2/SHA256 \
    && printf '%s  %s\n' "$(tr -d '[:space:]' < /opt/sam2/SHA256)" "${whl}" > /opt/sam2/SHA256SUMS \
    && sha256sum -c /opt/sam2/SHA256SUMS \
    && printf 'SAM-2 @ file://%s --hash=sha256:%s\n' "${whl}" "$(tr -d '[:space:]' < /opt/sam2/SHA256)" > /opt/sam2/requirements.txt \
    && printf '%s\n' "${SAM2_REF}" > /opt/sam2/REVISION \
    && uv pip install --python /app/ComfyUI/.venv/bin/python --no-deps --require-hashes -r /opt/sam2/requirements.txt \
    && uv pip install --python /app/ComfyUI/.venv/bin/python \
         --constraint /opt/comfy-constraints/torch.txt \
         "hydra-core==1.3.8" \
         "iopath==0.1.10" \
    && rm -rf /tmp/uv-cache \
    && chown -R 1000:1000 /app /data/mss-login /home/comfy /opt/uv-python /opt/uv-tools /opt/comfy-constraints \
    && chown root:root /app /app/ComfyUI \
    && chmod 755 /app /app/ComfyUI \
    && chown -R root:root /app/ComfyUI/web_custom_versions /opt/comfy-frontend \
    && find /app/ComfyUI/web_custom_versions /opt/comfy-frontend -type d -exec chmod 755 {} + \
    && find /app/ComfyUI/web_custom_versions /opt/comfy-frontend -type f -exec chmod 644 {} + \
    && chown -R root:root /opt/mss-login /opt/sam2 \
    && find /opt/mss-login /opt/sam2 -type d -exec chmod 0755 {} + \
    && find /opt/mss-login /opt/sam2 -type f -exec chmod 0644 {} + \
    && chown root:root \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/update.sh \
        /usr/local/bin/write-torch-constraints.sh \
        /usr/local/bin/write-mss-login-manifest.sh \
        /usr/local/bin/mss-login-healthcheck \
    && chmod 755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/update.sh \
        /usr/local/bin/write-torch-constraints.sh \
        /usr/local/bin/write-mss-login-manifest.sh \
        /usr/local/bin/mss-login-healthcheck
# Root does not source /home/comfy/.bashrc or /etc/profile.d. No sitecustomize
# is installed. The venv is uid 1000, including any .pth a later pip install
# writes; startup python passes --check-hash-based-pycs always and the config
# writer uses python -S so a venv sitecustomize is not imported as root.

LABEL org.opencontainers.image.source="https://github.com/Monster-Spawned-Studios/MSS-Login-ComfyUI-Image" \
      org.opencontainers.image.title="comfyui-mss-login" \
      org.opencontainers.image.description="ComfyUI with ComfyUI-MSS-Login fetched over HTTPS at build time" \
      com.monsterspawned.mss-login.revision="${MSS_LOGIN_REF}"

USER comfy
WORKDIR /app/ComfyUI
EXPOSE 9008

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=600s \
    CMD ["/usr/local/bin/mss-login-healthcheck"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

FROM base AS cpu
ENV DEVICE_TYPE=cpu \
    USE_CPU=1
RUN uv pip install --python /app/ComfyUI/.venv/bin/python \
        --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
        --index-url https://download.pytorch.org/whl/cpu \
        torch torchvision torchaudio \
    && echo "cpu" > /app/ComfyUI/.venv/.mss_torch_backend \
    && /usr/local/bin/write-torch-constraints.sh \
    && rm -rf /tmp/uv-cache

FROM base AS nvidia
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG CUDA_VERSION=cu130
# Re-derived from the stack 250 cuDNN path for this image's venv layout
# (/app/ComfyUI/.venv, Debian lib/, no system CUDA prefix). Venv wheels come
# first so a system cuDNN cannot shadow them. user-scripts/00-setup-uv-venv.sh
# is not used; that script addresses the old /root/ComfyUI/.venv layout.
# onnxruntime-gpu==1.31.1 publishes CUDA 13 / cuDNN 9 wheels, which matches
# this stage. insightface, onnx, gguf, and opencv-python-headless are pinned
# to exact versions. The CPU onnxruntime distribution is removed if insightface
# pulls it in. buffalo_l is not downloaded; mount a verified tree instead.
# sam2 is already installed in the base stage from commit
# 2b90b9f5ceec907a1c18123530e92e794ad901a4 (wheel sha256 recorded at
# /opt/sam2/SHA256). This stage does not reinstall it.
# LD_LIBRARY_PATH is not set in this image. Root unsets it. uid 1000 sets it
# from the venv after setpriv.
ENV DEVICE_TYPE=cuda \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility
RUN case "${CUDA_VERSION}" in \
      cu128|cu130) ;; \
      *) echo "CUDA_VERSION must be cu128 or cu130" >&2; exit 1 ;; \
    esac \
    && uv pip install --python /app/ComfyUI/.venv/bin/python \
        --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
        --index-url "https://download.pytorch.org/whl/${CUDA_VERSION}" \
        torch torchvision torchaudio \
    && echo "cuda" > /app/ComfyUI/.venv/.mss_torch_backend \
    && /usr/local/bin/write-torch-constraints.sh \
    && uv pip install --python /app/ComfyUI/.venv/bin/python \
        --constraint /opt/comfy-constraints/torch.txt \
        --only-binary torch,torchvision,torchaudio,onnxruntime-gpu,onnx,gguf,opencv-python-headless,insightface \
        "onnxruntime-gpu==1.31.1" \
        "onnx==1.23.2" \
        "insightface==2.1" \
        "gguf==0.19.0" \
        "opencv-python-headless==5.0.0.93" \
    && if uv pip show --python /app/ComfyUI/.venv/bin/python onnxruntime >/dev/null 2>&1; then \
      uv pip uninstall --python /app/ComfyUI/.venv/bin/python onnxruntime; \
    fi \
    && rm -rf /tmp/uv-cache

FROM base AS rocm
ARG ROCM_VERSION=rocm6.2.4
ENV DEVICE_TYPE=rocm
RUN uv pip install --python /app/ComfyUI/.venv/bin/python \
        --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
        --index-url "https://download.pytorch.org/whl/${ROCM_VERSION}" \
        torch torchvision torchaudio \
    && echo "rocm" > /app/ComfyUI/.venv/.mss_torch_backend \
    && /usr/local/bin/write-torch-constraints.sh \
    && rm -rf /tmp/uv-cache

FROM base AS auto
ENV DEVICE_TYPE=auto
