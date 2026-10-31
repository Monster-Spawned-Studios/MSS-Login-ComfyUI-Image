#!/usr/bin/env bash
# Freeze the torch, torchvision, torchaudio, and NVIDIA CUDA/cuDNN wheels
# already installed in the image venv. Runtime custom-node installs use this
# file so a requirements.txt cannot replace those builds.
set -euo pipefail

python_bin="${PYTHON:-/app/ComfyUI/.venv/bin/python}"
out_dir="${MSS_TORCH_CONSTRAINTS_DIR:-/opt/comfy-constraints}"
out_file="${out_dir}/torch.txt"
mkdir -p "$out_dir"

"$python_bin" - "$out_file" <<'PY'
import sys
from importlib import metadata
from pathlib import Path

out = Path(sys.argv[1])
exact = {"torch", "torchvision", "torchaudio", "triton"}
lines = []
for dist in metadata.distributions():
    name = dist.metadata["Name"] if dist.metadata else ""
    if not name:
        continue
    key = name.lower().replace("_", "-")
    if key in exact or key.startswith("nvidia-") or key.startswith("cuda-"):
        lines.append(f"{name}=={dist.version}")
text = "\n".join(sorted(set(lines), key=str.lower))
if text:
    text += "\n"
out.write_text(text)
print(f"[comfyui-deploy] Wrote {len(lines)} torch/CUDA pins to {out}")
PY
