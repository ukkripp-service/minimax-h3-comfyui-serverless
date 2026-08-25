# minimax-h3-comfyui-serverless

MiniMax H3 (Hailuo 3.0) video+audio generation as a RunPod serverless worker.
Sister repo of [krea2-comfyui-serverless](https://github.com/vincezh2000/krea2-comfyui-serverless), same pattern:
`runpod/worker-comfyui` base, weights baked into the image, GHA builds → ghcr.

**Image:** `ghcr.io/vincezh2000/minimax-h3-comfyui-serverless:latest`

This fork also builds a Turbo-enabled image in its own GHCR namespace. It adds
the pinned `ComfyUI-MiniMax-H3-Turbo` node and the recommended
`minimax_h3_turbo_v4_step600_ema.safetensors` LoRA. Use
`example_workflows/t2v_turbo_api.json` at 6–8 steps (8 by default).

## What's inside

- Base: `runpod/worker-comfyui:5.8.6-base`, ComfyUI pinned to **v0.30.1** (native H3 nodes need ≥0.30.0)
- Weights (ComfyUI-recommended pruned int8 set, 42.5 GB total, from [Comfy-Org/MiniMax-H3](https://huggingface.co/Comfy-Org/MiniMax-H3)):
  - `minimax_h3_fl2va_pruned_int8_convrot.safetensors` (21 GB) — covers **T2V and first/last-frame I2V**
  - `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` (15.7 GB) — text encoder
  - `minimax_h3_video_vae_fp16.safetensors` (5.2 GB) + `minimax_h3_audio_vae_fp32.safetensors` (0.6 GB)
- NOT included: `ref2va` model (reference-to-video, another 21 GB). Add a fourth aria2 RUN in the Dockerfile if needed.

Model capabilities: up to ~15s at 24 FPS with **native stereo audio** (speech/SFX/music generated in the same pass),
768px-short-edge canvas (max 768×1344 px area), aspect ratios from 21:9 to 9:16.

## RunPod endpoint settings

| Setting | Value |
|---|---|
| Container image | `ghcr.io/vincezh2000/minimax-h3-comfyui-serverless:latest` |
| GPU | 80 GB (A100/H100) recommended; 48 GB (L40S/A6000) works for 768p with offloading |
| Container disk | **≥ 100 GB** (image unpacks to ~55 GB) |
| FlashBoot | on |
| Env (optional) | `BUCKET_ENDPOINT_URL` etc. for S3 output upload — without it results return as base64 |

First cold pull of the ~50 GB image takes a while; subsequent starts on a cached host are fast.

## Calling it

`SaveVideo` results are collected by worker-comfyui like images (mp4 in, base64/S3 out — verified: the
history output key is `images`).

```bash
curl -s -X POST "https://api.runpod.ai/v2/<ENDPOINT_ID>/run" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"input\": {\"workflow\": $(cat example_workflows/t2v_api.json)}}"
```

The example workflow mirrors the official ComfyUI T2V template: `res_multistep` sampler, `simple` scheduler,
20 steps, `BasicGuider` (no CFG / no negative), dual VAE decode (video + audio) → `CreateVideo` (24 fps) → `SaveVideo`.

Knobs in `example_workflows/t2v_api.json`:

- **prompt** — describe shots, camera, and the audio (dialogue/SFX/music) in one block
- **width/height** — 32-multiples, area capped at 768×1344 (1344×768 = 16:9 max)
- **length** — frame count at 24 fps on the model's 17k+5 grid: 124 ≈ 5s, 243 ≈ 10s, 362 ≈ 15s
  (invalid values snap up automatically)
- **I2V**: add `"first_frame": ["<load_image_node>", 0]` (and optionally `last_frame`) to the
  `MiniMaxH3ImageToVideo` node; upload input images via worker-comfyui's `input.images` field

## Build pipeline

Push to `Dockerfile` or `build.yml` → GHA builds and pushes to ghcr.

Two-phase build (the naive single Dockerfile OOMs the runner disk — buildkit's export step needs
~2x the 42.5 GB of weight content):

1. `docker build` a slim **:code** image (base + ComfyUI v0.30.1 pin, no weights) and push it
2. For each weight file: download → tar → **`crane append`** streams it onto the remote image as a
   new layer (peak disk = one file + its tar, on /mnt) → final manifest tagged **:latest**
