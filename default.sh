#!/usr/bin/env bash
# Vast.ai / ComfyUI provisioning
# Kromoss model: Civitai version 3422515 (NOT convrot)
# Text encoder and VAE: lodestones/Kromoss on Hugging Face

# Keep the Python environment and custom nodes from the original script.
if [[ -f /venv/main/bin/activate ]]; then
    # shellcheck disable=SC1091
    source /venv/main/bin/activate
fi

COMFYUI_DIR="${WORKSPACE:-/workspace}/ComfyUI"
APT_INSTALL="${APT_INSTALL:-apt-get install -y}"
KROMOSS_VERSION_ID="3422515"
KROMOSS_FILENAME="Kromoss_Civitai_v${KROMOSS_VERSION_ID}.safetensors"
FAILED_DOWNLOADS=0

APT_PACKAGES=(
    aria2
)

PIP_PACKAGES=(
)

NODES=(
    "https://github.com/ClownsharkBatwing/RES4LYF"
    "https://github.com/rgthree/rgthree-comfy"
    "https://github.com/WASasquatch/RES4SHO"
    "https://github.com/pamparamm/sd-perturbed-attention"
    "https://github.com/pamparamm/ComfyUI-ppm"
    "https://github.com/Clybius/ComfyUI-CES"
)

WORKFLOWS=(
)

CHECKPOINT_MODELS=(
)

UNET_MODELS=(
)

LORA_MODELS=(
)

# MOSS-Image uses models/text_encoders, NOT models/clip.
CLIP_MODELS=(
    "https://huggingface.co/lodestones/Kromoss/resolve/main/text_encoders/qwen3.5_9b_bf16.safetensors"
)

VAE_MODELS=(
    "https://huggingface.co/lodestones/Kromoss/resolve/main/vae/flux2-vae_small.safetensors"
)

ESRGAN_MODELS=(
)

CONTROLNET_MODELS=(
)

function provisioning_print_header() {
    printf '\n######### ComfyUI provisioning (Kromoss Civitai) #########\n\n'
}

function provisioning_get_apt_packages() {
    if (( ${#APT_PACKAGES[@]} > 0 )); then
        sudo $APT_INSTALL "${APT_PACKAGES[@]}"
    fi
}

function provisioning_get_pip_packages() {
    if (( ${#PIP_PACKAGES[@]} > 0 )); then
        python -m pip install --no-cache-dir "${PIP_PACKAGES[@]}"
    fi
}

function provisioning_get_nodes() {
    local repo dir path requirements
    mkdir -p "${COMFYUI_DIR}/custom_nodes"
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d "$path/.git" ]]; then
            if [[ "${AUTO_UPDATE:-true}" != "false" ]]; then
                printf 'Updating node: %s\n' "$repo"
                ( cd "$path" && git pull --ff-only ) || true
            fi
        elif [[ ! -e "$path" ]]; then
            printf 'Downloading node: %s\n' "$repo"
            git clone --recursive "$repo" "$path" || continue
        fi
        if [[ -f "$requirements" ]]; then
            python -m pip install --no-cache-dir -r "$requirements" || \
                printf 'WARNING: pip dependencies failed for %s\n' "$repo" >&2
        fi
    done
}

# Prevent mistaking an HTTP error page for a downloaded .safetensors model.
function provisioning_valid_safetensors() {
    python3 - "$1" <<'PY'
import json
import os
import struct
import sys
p = sys.argv[1]
try:
    size = os.path.getsize(p)
    with open(p, 'rb') as f:
        first = f.read(8)
        if len(first) != 8:
            raise ValueError('short header')
        header_len = struct.unpack('<Q', first)[0]
        if not (2 <= header_len <= 64 * 1024 * 1024 and 8 + header_len < size):
            raise ValueError('bad header size')
        metadata = json.loads(f.read(header_len))
        if not isinstance(metadata, dict):
            raise ValueError('bad metadata')
except (OSError, ValueError, UnicodeError, json.JSONDecodeError):
    sys.exit(1)
PY
}

# Download a named safetensors file using aria2c; resume interrupted downloads.
function provisioning_download() {
    local url="$1" outdir="$2" filename="$3"
    local dest="${outdir}/${filename}"
    local -a auth=()
    mkdir -p "$outdir"

    if [[ -s "$dest" && ! -f "${dest}.aria2" ]]; then
        if provisioning_valid_safetensors "$dest"; then
            printf 'Already downloaded: %s\n' "$dest"
            return 0
        fi
        printf 'Invalid existing file, removing: %s\n' "$dest" >&2
        rm -f "$dest"
    fi

    case "$url" in
        https://civitai.com/*)
            if [[ -z "${CIVITAI_TOKEN:-}" ]]; then
                printf 'ERROR: CIVITAI_TOKEN is not set. Supply it as a Vast.ai environment variable.\n' >&2
                return 1
            fi
            auth=(--header="Authorization: Bearer ${CIVITAI_TOKEN}")
            ;;
        https://huggingface.co/*)
            if [[ -n "${HF_TOKEN:-}" ]]; then
                auth=(--header="Authorization: Bearer ${HF_TOKEN}")
            fi
            ;;
    esac

    printf 'Downloading %s -> %s\n' "$url" "$dest"
    if ! aria2c -c -x 16 -s 16 -k 4M \
        --max-tries=10 --retry-wait=10 \
        --file-allocation=none --auto-file-renaming=false \
        --summary-interval=30 \
        "${auth[@]}" \
        -d "$outdir" -o "$filename" "$url"; then
        printf 'ERROR: Download failed: %s (see aria2 output).\n' "$filename" >&2
        return 1
    fi
    if ! provisioning_valid_safetensors "$dest"; then
        printf 'ERROR: Invalid safetensors file: %s (possibly an API/login error page).\n' "$dest" >&2
        rm -f "$dest" "${dest}.aria2"
        return 1
    fi
    printf 'Download completed: %s\n' "$dest"
}

function provisioning_get_files() {
    local outdir="$1" url filename
    shift
    (( $# > 0 )) || return 0
    for url in "$@"; do
        filename="${url##*/}"
        filename="${filename%%\?*}"
        if ! provisioning_download "$url" "$outdir" "$filename"; then
            FAILED_DOWNLOADS=$((FAILED_DOWNLOADS + 1))
        fi
    done
}

function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages

    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints" "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/loras" "${LORA_MODELS[@]}"

    # Civitai *original version 3422515*; NO ConvRot file from Hugging Face.
    if ! provisioning_download \
        "https://civitai.com/api/download/models/${KROMOSS_VERSION_ID}" \
        "${COMFYUI_DIR}/models/diffusion_models" \
        "$KROMOSS_FILENAME"; then
        FAILED_DOWNLOADS=$((FAILED_DOWNLOADS + 1))
    fi

    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${CLIP_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/controlnet" "${CONTROLNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/esrgan" "${ESRGAN_MODELS[@]}"

    if (( FAILED_DOWNLOADS > 0 )); then
        printf '\nWARNING: %d file(s) failed to download. Check logs and CIVITAI_TOKEN.\n' "$FAILED_DOWNLOADS" >&2
    else
        printf '\nProvisioning complete: all requested models are ready.\n'
    fi
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
