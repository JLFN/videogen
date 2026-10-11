# Model manifest — MiniMax-H3 Turbo

Every file is pinned to a repository revision. Sizes below are exact byte counts read from the
Hugging Face tree API and re-verified against the live repositories at
publication; recompute hashes
on download and record them in the local ledger (`models/SHA256SUMS`, created by
`scripts/start-videogen.sh verify`). Never trust sizes alone.

## Standing profile — the four components plus two LoRAs

DiT (the denoising transformer), FL2VA partition, pruned AdaLN curve-table build:
- Source:   https://huggingface.co/unsloth/MiniMax-H3-GGUF
- Revision: d629413c2e5b51b38c453668b75ca3b06ca92703
- File:     minimax_h3_fl2va_pruned-Q8_0.gguf
- Size:     21,437,786,208 bytes (19.97 GiB)

Text encoder (Qwen3-VL-32B truncated to 50 language layers, vision tower kept):
- Source:   https://huggingface.co/unsloth/MiniMax-H3-GGUF
- Revision: d629413c2e5b51b38c453668b75ca3b06ca92703
- File:     qwen3vl_32b_minimax_h3-Q4_K_M.gguf
- Size:     18,218,065,024 bytes (16.97 GiB)

Video VAE and audio VAE (safetensors, both from the same repo):
- vae/minimax_h3_video_vae_fp16.safetensors   5,207,808,496 bytes (4.85 GiB)
- vae/minimax_h3_audio_vae_fp32.safetensors     605,254,808 bytes (0.56 GiB)

Turbo LoRA A — larry (the Space's default, 4-step EMA ckpt850):
- Source:   https://huggingface.co/larryvrh/MiniMax-H3-Turbo-Lora
- Revision: 43a74557ac3f6539db8e0f2a959d03feb7a81480
- File:     minimax_h3_turbo_4step_ema_ckpt850.safetensors
- Size:     779,849,816 bytes (0.73 GiB)
- Base:     Comfy-Org/MiniMax-H3 (the reference tree sd.cpp loads)

  Alternative worth switching to later, same source and revision, same size:
  minimax_h3_turbo_v4_step600_ema.safetensors, 779,849,816 bytes (0.73 GiB).
  The author now recommends it over the ckpt850 v1 line, calls the v1 line
  over-sharpened and plastic in general, and states that one LoRA file covers
  every base including the pruned and curve variants. The manifest keeps
  ckpt850 as the default only because that is what the page pins.

Turbo LoRA B — lightx (4-step, ComfyUI export preferred for sd.cpp):
- Source:   https://huggingface.co/lightx2v/Minimax-h3-Turbo
- Revision: 3ec17a324ced54151364f24f8b5fb6bf7e26414f
- File:     minimax_h3_fl2v_turbo_4step_v1.2_768p_comfyui_bf16.safetensors
- Size:     1,956,193,000 bytes (1.82 GiB)
- Note:     the peft sibling the Space itself loads is
            minimax_h3_fl2v_turbo_4step_v0.1.safetensors, 1,383,677,888 bytes
            (1.29 GiB); sd.cpp's converter accepts both naming forms
            (name_conversion.cpp:1577-1580). Also present: the 4-step and
            8-step, 768p, bf16 and comfyui variants, and one 34,023,114,720-byte
            fp8 file, which is not a LoRA-sized artefact.

STANDING DOWNLOAD TOTAL: 48,204,957,352 bytes = 44.90 GiB (48.20 GB).
  DiT 19.97 + encoder 16.97 + video VAE 4.85 + audio VAE 0.56
  + larry 0.73 + lightx 1.82 = 44.90 GiB.
Against a 121.6 GiB pool that leaves roughly 76 GiB for the packed sequence,
the attention working set and the decoders at 768p. The sd.cpp source and its
build tree add roughly 2 GB on top of that, unmeasured.

## Alternatives, all pulled from the same pinned revisions

DiT ladder, pruned FL2VA (unsloth):
  Q2_K   6,724,190,304 B   6.26 GiB     Q5_0  13,923,170,400 B  12.97 GiB
  Q3_K   8,759,328,864 B   8.16 GiB     Q6_K  16,586,784,864 B  15.45 GiB
  Q4_K  11,420,663,904 B  10.64 GiB     Q8_0  21,437,786,208 B  19.97 GiB
  UD-Q2_K_XL 8,063,029,344 B 7.51 GiB   UD-Q3_K_XL 9,558,675,552 B 8.90 GiB

Non-pruned FL2VA (leejet/MiniMax-H3-GGUF, revision
d9c4c6312b4728a68a15a35626d84775a6523783), needed for the pruned-vs-not A/B:
  minimax_h3_fl2va-Q4_K_M.gguf         18,779,848,448 B  17.49 GiB
  minimax_h3_fl2va_pruned-Q4_K_M.gguf  11,420,663,904 B  10.64 GiB

Reference-to-video partition, if Ref2VA is wanted later (same repos):
  ref2va pruned Q2_K 6.22 GiB, Q3_K 8.12 GiB, Q4_K 10.60 GiB,
                Q5_0 12.94 GiB, Q6_K 15.42 GiB, Q8_0 19.94 GiB

Text encoder alternatives: qwen3vl_32b_minimax_h3-Q2_K_M.gguf 12.20 GiB.

If every variant listed in this manifest were downloaded, the DiT ladders, the
encoders and the VAEs alone total 279,365,147,624 bytes (260.2 GiB / 279.4 GB),
before any LoRA. Nothing in the recipe needs that; the standing profile above is
what to fetch.

Useful partial extras on top of the standing 44.90 GiB:
  + non-pruned FL2VA Q4_K_M for the pruned-vs-not A/B      +17.49 GiB = 62.39 GiB
  + the v4-600 larry checkpoint instead of, or beside, v1   +0.73 GiB = 45.63 GiB
  + the Ref2VA partition at pruned Q4_K if wanted later     +10.60 GiB = 55.50 GiB

## Parity with the reference page — what is the same and what is not

The page loads MiniMaxAI/MiniMax-H3 directly and runs the FL2VA transformer
unquantized. Comfy-Org/MiniMax-H3 republishes those exact weights as safetensors,
and sd.cpp's own H3 doc names that repo as a download source, so the page's real
transformer is available to this runner:

- diffusion_models/minimax_h3_fl2va_bf16.safetensors        66,280,487,368 B  61.73 GiB
- diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors 34,038,892,334 B 31.70 GiB
- diffusion_models/minimax_h3_fl2va_pruned_bf16.safetensors  40,225,724,176 B 37.46 GiB
- diffusion_models/minimax_h3_fl2va_pruned_fp8_scaled.safetensors  20,958,205,608 B 19.52 GiB
- diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors 20,970,379,616 B 19.53 GiB
- diffusion_models/minimax_h3_fl2va_pruned_w6a8.safetensors  15,983,746,636 B 14.89 GiB
- text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors      51,506,295,256 B 47.97 GiB
- text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors 27,141,342,152 B 25.28 GiB
- text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors  15,687,142,551 B 14.61 GiB

Sums, against the reference host's 119.68 GiB usable pool:

- page transformer bf16 + nvfp4 encoder + VAEs = 81.75 GiB, about 38 GiB headroom.
  This keeps the page's actual transformer bit-for-bit and quantizes only the
  encoder, which is the closest practical parity.
- page transformer bf16 + int8 encoder + VAEs = 92.42 GiB, about 27 GiB headroom.
- page transformer bf16 + bf16 encoder + VAEs = 115.11 GiB, about 4.6 GiB left.
  Too tight: the Space measures roughly 6.4 GiB allocated and 13.2 GiB reserved
  of working set at 1344x768. This is the arithmetic behind "the unquantized page
  does not fit one host".
- the standing profile above (pruned Q8_0) trades the transformer's exactness for
  a 44.90 GiB total.

So the current standing profile is NOT the page's exact transformer: it is
quantized to Q8_0 and pruned at the AdaLN. Same base model, same LoRAs, same
encoders and VAEs by origin, different arithmetic. The parity row is the option
that keeps the page's transformer exactly, at a larger download and a slower
step, since transformer bytes are read every denoising step and the host's
memory bandwidth is the wall.

## Not from these repos

The AoTI block package (multimodalart/minimax-h3-aoti) is not used here: a
compiled package is bound to one exact (batch, torch and compute-capability)
key and exists for a hosted GPU service whose hardware this is not. sd.cpp
compiles the graph itself, or runs it eagerly, instead. sd.cpp compiles or runs
eagerly instead.

## License

MiniMax-H3 weights are under the MiniMax H3 Community License Agreement
(license:other, license_link LICENSE in MiniMaxAI/MiniMax-H3). The larry LoRA is
Apache-2.0; lightx2v/Minimax-h3-Turbo is Apache-2.0. Weight access and license
obligations are separate from this recipe's code.
