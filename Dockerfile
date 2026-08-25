FROM runpod/worker-comfyui:5.8.6-base

# Pin ComfyUI to v0.30.1 (native MiniMax H3 nodes land in 0.30.0; verified in comfy_extras/nodes_minimax_h3.py)
# CRITICAL #1: the runtime venv is /opt/venv (see PATH in the base image env) — NOT /comfyui/.venv,
# which also exists but is dead weight. Installing requirements into the wrong venv leaves the
# runtime on the base image's June-era comfy-kitchen, whose tensor module lacks the INT8/ConvRot
# layout classes → quant_ops silently falls back → "'NoneType' object has no attribute 'Params'".
# CRITICAL #2: requirements drags torch up to a newer version whose default PyPI wheel is cu130,
# but RunPod's H100/H200 fleet runs driver 570.x (CUDA 12.8) where cu130 fails cuda init
# ("The NVIDIA driver on your system is too old" — captured from a live H200 boot log).
# Force torch back to cu126 wheels AFTER the requirements install; cu126 runs fine on 12.8
# drivers. comfy-kitchen then uses its eager backend (ComfyUI disables the CUDA backend for
# < 13.0 anyway), which implements every int8_convrot / nvfp4 op H3 needs.
RUN cd /comfyui && git fetch --depth 1 origin refs/tags/v0.30.1 && git checkout FETCH_HEAD && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt && \
    /opt/venv/bin/pip install --no-cache-dir --force-reinstall torch==2.12.0 torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu126

# MiniMax-H3 Turbo support pinned to a reviewed commit. The node handles the
# pruned INT8/curve base and the separate audio/video sampling schedules used by
# older ComfyUI releases.
ARG H3_TURBO_NODE_COMMIT=4274783a23afcfdbea3b4876cb79effd6c510785
RUN mkdir -p /comfyui/custom_nodes/ComfyUI-MiniMax-H3-Turbo && \
    cd /comfyui/custom_nodes/ComfyUI-MiniMax-H3-Turbo && \
    git init && \
    git remote add origin https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo.git && \
    git fetch --depth 1 origin "$H3_TURBO_NODE_COMMIT" && \
    git checkout FETCH_HEAD && \
    rm -rf .git

# Weights are NOT baked here: 42.5GB of layers makes buildkit's export step need
# 2x that on disk, which no GHA runner survives. The workflow instead builds this
# slim "code" image, then streams each weight file onto it as an image layer with
# `crane append` (single-copy disk usage). See .github/workflows/build.yml.
RUN mkdir -p /comfyui/models/diffusion_models /comfyui/models/text_encoders \
    /comfyui/models/vae /comfyui/models/loras
