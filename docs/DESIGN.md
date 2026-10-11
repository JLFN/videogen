# Design notes

Why this recipe looks the way it does: what the reference deployment actually
is, why its own weights cannot run on one box, how the artifact ladder trades
fidelity against memory, and which question is still open.

## The model

MiniMax-H3 is a 33B dense, single-stream omni-modal diffusion transformer. It
emits video and 32 kHz stereo audio in the same denoising pass, at 24 fps, with
a 768-pixel short edge by default, for 4 to 15 seconds. The released checkpoints
are CFG-distilled, so there is no classifier-free guidance branch: one
conditioning input, `cfg 1.0`, no negative prompt.

Two task partitions ship: **FL2VA** (text, first frame, last frame to audio and
video) and **Ref2VA** (image, video and audio references to audio and video).
This recipe uses FL2VA, the partition the reference deployment serves.

## What the reference deployment is

The reference is a Gradio Space that runs MiniMax-H3 with two 4-step turbo LoRAs
folded into bf16 weights. It is not self-contained: it is the **denoising half
of a split deployment**.

- A hosted Space is evicted at 150 GB of storage, and the model in bf16 does not
  come close to fitting in one. So `h3_split_blocks.py` subclasses the diffusers
  `MiniMaxH3Blocks` pipeline with its `text_encoder` step removed, leaving a
  generator that holds only the transformer and the two autoencoders.
- The 62.14 GiB Qwen3-VL-32B conditioner runs in a second Space and hands over
  the text conditioning over the network: one safetensors file carrying
  `prompt_embeds` (bf16) and `text_token_tags` (int64), with the resolved
  height, width and frame count in its metadata header.
- The generator half is 77.3 GB: transformer plus video VAE plus audio VAE,
  bfloat16, with no quantization anywhere. Both autoencoders stay in float32,
  because a bf16 audio VAE decodes the soundtrack roughly 20 dB too quiet.
- The two turbo LoRAs are folded into the weights as `scale * (B @ A)` in
  float32 with a single rounding, rather than wrapped, because the AoTI-compiled
  block package reads each block's live weights. Both factor sets stay resident,
  so switching adapters is an in-place unfurl.
- With the AoTI path enabled, all 50 repeated transformer blocks run from one
  compiled package for a single (batch, torch, compute-capability) key. It
  carries no weights and reads each block's live weights on the first forward.
  Any mismatch falls back to eager with a log line; a mismatched package
  segfaults, which is why the key is checked rather than assumed.
- A separately spawned 270M text classifier scores NCII risk per request. It
  cannot run inside the main process: with it loaded there, every subsequent GPU
  worker dies at initialization.

The consequence for anyone reproducing it: half the pipeline is a network
dependency, and the other half does not fit a single 121.6 GiB unified-memory
host. This recipe replaces the split with quantization.

## Why quantization, not a smaller model

Resident cost of the reference deployment as published: 62.15 GiB for the
conditioner plus 72.16 GiB for the generator (61.73 GiB transformer, 10.43 GiB
of float32 autoencoders), 134.3 GiB together, against a usable pool of
119.68 GiB. That is over budget before a single activation.

On a hosted service with several GPUs the split is fine: the two halves live on
different devices. On one box they must co-reside, and moving 60-plus GiB per
request through unified memory is not a recipe, it is a swap storm.

So the recipe keeps the same checkpoint and the same two adapters at a bit width
that fits. That is not a different model; it is the same architecture with the
same LoRAs, quantized.

## The artifact ladder

The transformer is available at several widths, including republished
safetensors of the reference deployment's own weights. Sizes are exact byte
counts from the Hugging Face tree API; the full list is in
[models/MANIFEST.md](../models/MANIFEST.md).

| Transformer | Size | Note |
|---|---:|---|
| pruned FL2VA Q2_K | 6.26 GiB | Smallest useful build. |
| pruned FL2VA Q4_K | 10.64 GiB | The `q4` profile. |
| pruned FL2VA Q6_K | 15.45 GiB | The `q6` profile. |
| non-pruned FL2VA Q4_K_M | 17.49 GiB | Keeps the AdaLN layers; the `base-q4` profile. |
| pruned FL2VA Q8_0 | 19.97 GiB | The standing profile, `q8`. |
| pruned bf16 | 37.46 GiB | |
| non-pruned int8 | 31.70 GiB | |
| original bf16 | 61.73 GiB | The reference deployment's own transformer. |

"Pruned" means the AdaLN MLPs, roughly 13B parameters, are replaced by a curve
table. stable-diffusion.cpp detects that variant from the weights themselves, so
both trees load.

Three parity sums against the 119.68 GiB usable pool, using the 14.6 GiB NVFP4
encoder, the 25.3 GiB int8 encoder, and the 48.0 GiB bf16 encoder respectively:

| Combination | Total | Headroom |
|---|---:|---:|
| original bf16 transformer, NVFP4 encoder, VAEs | 81.75 GiB | about 38 GiB |
| original bf16 transformer, int8 encoder, VAEs | 92.42 GiB | about 27 GiB |
| original bf16 transformer, bf16 encoder, VAEs | 115.11 GiB | about 4.6 GiB |
| standing profile (pruned Q8_0, Q4_K_M encoder, VAEs) | 44.90 GiB | about 75 GiB |

The tight row is the interesting one: it keeps the reference deployment's
transformer bit-for-bit and quantizes only the encoder, and it leaves 4.6 GiB
where that deployment measures roughly 6.4 GiB allocated and 13.2 GiB reserved
of working set at 1344x768. That is the arithmetic behind "the unquantized
pipeline does not fit".

The trade in the other direction is throughput, not correctness: the transformer
bytes are read at every denoising step, so a wider transformer costs step time
directly. Memory buys weight fidelity; time buys sampling; they are not
substitutes.

## Why stable-diffusion.cpp

The runner is `leejet/stable-diffusion.cpp`, the same family this project's
image-generation sibling uses: pure C/C++ on ggml, no ComfyUI, no Python
service, no cloud API.

What matters for H3 in particular, read from its source:

- Its H3 documentation describes the four components the model needs
  (`--diffusion-model`, `--vae`, `--audio-vae`, `--llm`) and the task variants
  (T2VA, I2VA, FL2VA, Ref2VA) with the first-frame, last-frame and reference
  inputs.
- Its model loader detects both the original time-embedder DiT and the smaller
  AdaLN curve-table variant from the weights, which is what makes the pruned
  ladder usable at all.
- Its LoRA converter maps both naming conventions (`lora_A.weight` and the PEFT
  `lora_A.default.weight` form) onto its own down/up tensors, and for video
  families it expects the original reference (Comfy) key tree. That is exactly
  what the larry adapter targets and what lightx2v ships its `comfyui` files
  for. The lightx2v `peft` file the reference deployment itself loads is also
  accepted, by the same converter.

The runner cannot write H.264, so the wrapper remuxes its VP8 `.webm` with
ffmpeg. That is a container detail, not a quality one: both streams survive.

## The open question: a turbo LoRA on a pruned model

The pruned transformers replace roughly 13B of AdaLN MLP parameters with a curve
table. The larry adapter contains AdaLN projection targets
(`final_layer.adaln_proj.linear` and the per-block AdaLN projections), so some
of its 363 entries may have nothing to fold into on a pruned base.

The adapter's own model card addresses this: it states that a single LoRA file
covers every base, including the pruned and curve variants, because the ComfyUI
node detects a pruned base and re-injects the time conditioning at run time.

That is a runtime re-injection in a different loader, not the fold the reference
deployment performs, and this project has not measured the difference. What is
measured here is weaker: the runner reports `apply_loras completed`, so the
adapter is applied, and a clip came out with the expected structure. Whether the
AdaLN entries land where they should is the first A/B this recipe asks for:

- larry against lightx against no adapter, at identical seed and prompt;
- the pruned Q8_0 against the non-pruned Q4_K_M at the same seed and prompt.

Until that runs, the standing profile is a working configuration rather than a
verified-equivalent one.

## What "UNCENSORED" means on that Space, and what it does not

The reference deployment's name carries an `UNCENSORED` label, and the honest
finding is that it is not a different model. Cloning both of that author's
Spaces and diffing them shows identical file sets, identical model dependency
lists (both including the NCII classifier), and an `app.py` that differs only in
blank lines inside docstrings and the launch line.

What makes either of them uncensored is structural rather than weight-level: the
released MiniMax-H3 weights carry no moderation stage. The guardrails MiniMax
documents live in the hosted H3-Context-IR service and in the hosted API, whose
model card states that user-submitted text, images and videos, and enhanced
prompts, are subject to automated moderation. Neither Space calls those.

This recipe uses the same base weights and the same turbo adapter, quantized,
and does not include the NCII classifier both Spaces bolt on. So: the same
model, with one fewer gate in front of it.

## Where the numbers came from

| Claim class | Source |
|---|---|
| Artifact sizes, revisions, licenses | Hugging Face API, live. Every pin in `models/MANIFEST.md` was re-checked against the repositories when this repository was published. |
| Reference deployment internals (split, LoRA folding, fp32 autoencoders, AOTI keying, NCII subprocess) | The Space's own source, cloned and read. |
| Prompt structure and the rules in [PROMPTING.md](PROMPTING.md) | `MiniMaxAI/MiniMax-H3`, `docs/VIDEO_PROMPT_WRITING_GUIDE_base_en.md`. |
| CFG-distilled weights, 24 fps, 4-15 s, 768-pixel short edge, H3-Context-IR not open | `MiniMaxAI/MiniMax-H3`, model card. |
| The 4-to-8-step useful range and over-sharpening past it | `larryvrh/MiniMax-H3-Turbo-Lora`, model card. |
| Host memory figures and the usable-pool number | The host's own specifications and its measured pool. |
| Measured run times and peak memory | This project's own runs; see [Verification status](USAGE.md#verification-status). |

Where a figure in this document has no source in that list, it is stated as
unverified where it appears.
