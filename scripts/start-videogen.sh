#!/usr/bin/env bash
# start-videogen.sh — download, build and verify the MiniMax-H3 Turbo recipe on
# a local host. Subcommands: recon build download verify status clean
#
# Every path is overridable by environment:
#   VIDEOGEN_ROOT (default: the parent of this script's directory)
#   SDCPP_DIR     (default: $VIDEOGEN_ROOT/.src/sdcpp)
#   CUDA_HOME     (default: /usr/local/cuda)
set -euo pipefail

ROOT="${VIDEOGEN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SDCPP_DIR="${SDCPP_DIR:-$ROOT/.src/sdcpp}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
CUDA_ARCH="${CUDA_ARCH:-121}"       # CMAKE_CUDA_ARCHITECTURES; set for your GPU
SDCPP_REPO="${SDCPP_REPO:-https://github.com/leejet/stable-diffusion.cpp}"
SDCPP_REV="${SDCPP_REV:-}"          # empty = HEAD; pin a SHA for reproducibility
SD="$ROOT/models/sd"
LORA_DIR="$ROOT/models/loras"
OUT="$ROOT/out"
JOBS="${JOBS:-$(nproc)}"

# Pinned revisions. See models/MANIFEST.md for the byte sizes.
UNSLOTH_REV="d629413c2e5b51b38c453668b75ca3b06ca92703"
LEEJET_REV="d9c4c6312b4728a68a15a35626d84775a6523783"
LARRY_REV="43a74557ac3f6539db8e0f2a959d03feb7a81480"
LIGHTX_REV="3ec17a324ced54151364f24f8b5fb6bf7e26414f"

# Standing profile: the artefact list from models/MANIFEST.md.
PROFILE="${PROFILE:-q8}"
case "$PROFILE" in
  q8) DIT_FILE="minimax_h3_fl2va_pruned-Q8_0.gguf" ;;
  q6) DIT_FILE="minimax_h3_fl2va_pruned-Q6_K.gguf" ;;
  q4) DIT_FILE="minimax_h3_fl2va_pruned-Q4_K.gguf" ;;
  base-q4) DIT_FILE="minimax_h3_fl2va-Q4_K_M.gguf" ;;
  *) echo "unknown PROFILE '$PROFILE' (q8|q6|q4|base-q4)" >&2; exit 2 ;;
esac
ENCODER_FILE="${ENCODER_FILE:-qwen3vl_32b_minimax_h3-Q4_K_M.gguf}"

# The usage text is the leading comment block of this file (line 2 up to the
# first line that is not a comment), so it cannot drift out of step with the
# header when the header is edited.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

log() { printf '[videogen] %s\n' "$*"; }
die() { printf '[videogen] error: %s\n' "$*" >&2; exit 1; }

# The hub CLI is tried first: it resumes inside its own cache and speaks Xet.
# curl is the fallback and is pinned to HTTP/1.1, because HTTP/2 streams from the
# CDN were observed to abort mid-transfer with "stream 1 was not closed cleanly".
HF_CLI="${HF_CLI:-$(command -v hf || command -v huggingface-cli || true)}"
DL_TMP="$ROOT/models/.dl"

hf_url() { printf 'https://huggingface.co/%s/resolve/%s/%s' "$1" "$2" "$3"; }

fetch() { # fetch <repo> <revision> <remote_path> <dest>
  local repo="$1" rev="$2" rpath="$3" dest="$4"
  mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ] && [ "${FORCE:-0}" != "1" ]; then
    log "have $(basename "$dest") ($(du -h "$dest" | cut -f1)), skipping"
    return 0
  fi
  if [ -n "$HF_CLI" ]; then
    log "hf download $repo :: $rpath @ ${rev:0:8}"
    rm -rf "$DL_TMP/out"
    mkdir -p "$DL_TMP/out"
    "$HF_CLI" download "$repo" "$rpath" --revision "$rev" --local-dir "$DL_TMP/out" \
      || { log "hf download failed for $rpath"; return 1; }
    mv -f "$DL_TMP/out/$rpath" "$dest" || return 1
    rm -rf "$DL_TMP/out"
  else
    log "curl $repo :: $rpath @ ${rev:0:8}"
    curl -fL --http1.1 --retry 10 --retry-delay 5 --retry-all-errors -C - \
      -o "$dest.part" "$(hf_url "$repo" "$rev" "$rpath")" \
      || { log "curl failed for $rpath"; return 1; }
    mv "$dest.part" "$dest"
  fi
  log "  $(du -h "$dest" | cut -f1)  $(basename "$dest")"
}

cmd_recon() {
  log "host:      $(hostname)"
  log "arch:      $(uname -m)   kernel: $(uname -r)"
  log "os:        $(. /etc/os-release && echo "$PRETTY_NAME")"
  log "model:     $(cat /proc/device-tree/model 2>/dev/null || echo unknown)"
  log "memory:    $(awk '/MemTotal/{printf "%.1f GiB total", $2/1048576}' /proc/meminfo)"
  log "disk free: $(df -h "$ROOT" | awk 'NR==2{print $4" avail on "$6}')"
  if command -v nvcc >/dev/null; then log "nvcc:      $(nvcc --version | awk -F'release ' '/release/{print $2}' | cut -d, -f1)"
  elif [ -x "$CUDA_HOME/bin/nvcc" ]; then log "nvcc:      $("$CUDA_HOME/bin/nvcc" --version | awk -F'release ' '/release/{print $2}' | cut -d, -f1) ($CUDA_HOME)"
  else log "nvcc:      NOT FOUND (needed for the CUDA build)"; fi
  # The accelerator is reported through the vendor's own CLI when it is present.
  SMI="$(command -v nvidia-smi || true)"
  if [ -n "$SMI" ]; then
    log "gpu:       $("$SMI" --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>/dev/null || echo unknown)"
  else
    log "gpu:       no GPU query tool on PATH"
  fi
  log "cuda arch: ${CUDA_ARCH:-121} (CMAKE_CUDA_ARCHITECTURES for the build)"
  log "ffmpeg:    $(command -v ffmpeg || echo MISSING)"
  log "python:    $(command -v python3 || echo missing)"
  log "torch:     $(python3 -c 'import torch;print(torch.__version__, "cuda", torch.version.cuda)' 2>/dev/null || echo 'not installed (not needed for this recipe)')"
  log "sd-cli:    $([ -x "$ROOT/bin/sd-cli" ] && echo "$ROOT/bin/sd-cli" || echo 'not built yet')"
  log "weights:   $(du -sh "$SD" 2>/dev/null | cut -f1 || echo none) in $SD"
  log "exist. dir:$(ls -d "$ROOT"/../*comfy* "$HOME"/*sd*cpp* 2>/dev/null | tr '\n' ' ' || true)"
}

cmd_build() {
  command -v cmake >/dev/null || die "cmake not installed"
  [ -x "$CUDA_HOME/bin/nvcc" ] || log "warning: $CUDA_HOME/bin/nvcc missing; the CUDA build will fail"
  if [ ! -d "$SDCPP_DIR/.git" ]; then
    log "cloning $SDCPP_REPO (recursive: ggml is a submodule) into $SDCPP_DIR"
    mkdir -p "$(dirname "$SDCPP_DIR")"
    git clone --recursive "$SDCPP_REPO" "$SDCPP_DIR"
  fi
  git -C "$SDCPP_DIR" submodule update --init --recursive
  if [ -n "$SDCPP_REV" ]; then git -C "$SDCPP_DIR" checkout "$SDCPP_REV"; fi
  log "building sd-cli at $(git -C "$SDCPP_DIR" rev-parse --short HEAD)"
  cmake -S "$SDCPP_DIR" -B "$SDCPP_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DSD_CUDA=ON
  cmake --build "$SDCPP_DIR/build" --config Release -j "$JOBS"
  mkdir -p "$ROOT/bin"
  for candidate in "$SDCPP_DIR/build/bin/sd-cli" "$SDCPP_DIR/build/sd-cli" "$SDCPP_DIR/build/bin/Release/sd-cli"; do
    if [ -x "$candidate" ]; then cp -f "$candidate" "$ROOT/bin/sd-cli"; break; fi
  done
  [ -x "$ROOT/bin/sd-cli" ] || die "sd-cli not found in the build tree"
  log "installed $ROOT/bin/sd-cli"
  "$ROOT/bin/sd-cli" --help >/dev/null 2>&1 || true
}

cmd_download() {
  mkdir -p "$SD" "$LORA_DIR" "$OUT"
  local failed=0
  fetch unsloth/MiniMax-H3-GGUF "$UNSLOTH_REV" "$DIT_FILE" "$SD/$(basename "$DIT_FILE")" || failed=1
  fetch unsloth/MiniMax-H3-GGUF "$UNSLOTH_REV" "$ENCODER_FILE" "$SD/$(basename "$ENCODER_FILE")" || failed=1
  fetch unsloth/MiniMax-H3-GGUF "$UNSLOTH_REV" "vae/minimax_h3_video_vae_fp16.safetensors" "$SD/minimax_h3_video_vae_fp16.safetensors" || failed=1
  fetch unsloth/MiniMax-H3-GGUF "$UNSLOTH_REV" "vae/minimax_h3_audio_vae_fp32.safetensors" "$SD/minimax_h3_audio_vae_fp32.safetensors" || failed=1
  fetch larryvrh/MiniMax-H3-Turbo-Lora "$LARRY_REV" "minimax_h3_turbo_4step_ema_ckpt850.safetensors" "$LORA_DIR/larry_4step_ema_ckpt850.safetensors" || failed=1
  fetch lightx2v/Minimax-h3-Turbo "$LIGHTX_REV" "minimax_h3_fl2v_turbo_4step_v1.2_768p_comfyui_bf16.safetensors" "$LORA_DIR/lightx_4step_v1.2_768p_comfyui_bf16.safetensors" || failed=1
  if [ "$failed" != "0" ]; then
    log "one or more files failed; re-run to resume (completed files are skipped)"
    return 1
  fi
  log "downloaded $(du -sh "$SD" | cut -f1) of weights, $(du -sh "$LORA_DIR" | cut -f1) of LoRAs"
}

cmd_verify() {
  local ledger="$ROOT/models/SHA256SUMS"
  if [ "${1:-}" = "--write" ]; then
    ( cd "$ROOT/models" && find sd loras -type f -name '*.gguf' -o -type f -name '*.safetensors' | sort | xargs -r sha256sum ) > "$ledger"
    log "wrote $ledger with $(wc -l < "$ledger") entries"
    return
  fi
  [ -f "$ledger" ] || die "no ledger at $ledger; run: start-videogen.sh verify --write"
  ( cd "$ROOT/models" && sha256sum -c "$(basename "$ledger")" )
}

cmd_status() {
  log "root:     $ROOT"
  log "sd-cli:   $([ -x "$ROOT/bin/sd-cli" ] && echo present || echo absent)"
  log "sd.cpp:   $([ -d "$SDCPP_DIR/.git" ] && git -C "$SDCPP_DIR" rev-parse --short HEAD || echo 'not cloned')"
  log "profile:  $PROFILE ($DIT_FILE)"
  log "weights:"
  for f in "$SD/$DIT_FILE" "$SD/$ENCODER_FILE" "$SD/minimax_h3_video_vae_fp16.safetensors" \
           "$SD/minimax_h3_audio_vae_fp32.safetensors" "$LORA_DIR"/*.safetensors; do
    [ -e "$f" ] && printf '  %10s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"
  done
  log "total:    $(du -sh "$ROOT" 2>/dev/null | cut -f1)"
}

cmd_clean() {
  log "removing build tree $SDCPP_DIR/build"
  rm -rf "$SDCPP_DIR/build"
}

case "${1:-}" in
  recon)    shift; cmd_recon "$@" ;;
  build)    shift; cmd_build "$@" ;;
  download) shift; cmd_download "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  status)   shift; cmd_status "$@" ;;
  clean)    shift; cmd_clean "$@" ;;
  *) usage; exit 2 ;;
esac
