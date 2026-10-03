#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  edge0-termux-convert.sh
#
#  Converts Edge0/Edge0-8B-A1B-preview (MLX safetensors, ~4.3 GB) into the
#  llama.cpp GGUF artefacts the Edge0 Android app expects, ENTIRELY ON THE
#  PHONE, then stages them where the app's model picker can reach them.
#
#  Why on-device: the converted GGUF is ~5 GB. Producing it needs the 4.3 GB
#  source and the 5 GB output present at the same time, so a host machine
#  needs ~10 GB free. Phones have the space; PCs often do not.
#
#  Memory: safe on 8 GB+. The repacker streams one tensor at a time from the
#  safetensors headers (seek+read per tensor); it never loads the model whole.
#
#  Run in Termux (F-Droid build):  bash edge0-termux-convert.sh
# ============================================================================
set -euo pipefail

WORK="${EDGE0_WORK:-$HOME/edge0-work}"
REPO="$WORK/Edge0"
SRC="$WORK/models/edge0-8b"
OUT="$SRC-gguf"
STAGE="/sdcard/Download/edge0-models"
REPO_URL="${EDGE0_REPO_URL:-https://github.com/Edge0-AI/Edge0.git}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m%s\033[0m\n' "$*"; }
warn() { printf '    \033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. preflight
log "0/6  Preflight"
command -v pkg >/dev/null || die "This script must run inside Termux."
if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ]; then
  ok "Termux detected at $PREFIX"
fi

# ------------------------------------------------------------ 1. storage setup
log "1/6  Shared-storage access"
echo "    A permission dialog will appear - tap ALLOW."
termux-setup-storage 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -d /sdcard ] && break
  sleep 1
done
[ -d /sdcard ] || die "/sdcard unavailable - grant storage permission to Termux, then re-run."
ok "shared storage mounted"

FREE_KB=$(df -k "$HOME" | awk 'NR==2{print $4}')
FREE_GB=$((FREE_KB / 1024 / 1024))
if [ "$FREE_GB" -lt 12 ]; then
  warn "only ${FREE_GB} GB free under \$HOME; ~10 GB is needed (4.3 GB source + 5 GB GGUF)"
else
  ok "${FREE_GB} GB free"
fi

# -------------------------------------------------------------- 2. dependencies
log "2/6  Installing python + numpy + git (one time)"
pkg update -y >/dev/null 2>&1 || warn "pkg update failed - continuing"
pkg install -y python git >/dev/null 2>&1 || die "could not install python/git"

if python -c 'import numpy' 2>/dev/null; then
  ok "numpy present: $(python -c 'import numpy; print(numpy.__version__)')"
else
  pkg install -y python-numpy >/dev/null 2>&1 || true
  if ! python -c 'import numpy' 2>/dev/null; then
    warn "python-numpy package unavailable; building via pip (this can take a while)"
    pip install --no-cache-dir numpy || die "numpy is required and could not be installed"
  fi
  ok "numpy ready: $(python -c 'import numpy; print(numpy.__version__)')"
fi
ok "$(python --version 2>&1)"

# ------------------------------------------------------------------ 3. the repo
log "3/6  Fetching the Edge0 converter"
mkdir -p "$WORK"
if [ ! -d "$REPO/.git" ]; then
  git clone --depth 1 "$REPO_URL" "$REPO" || die "git clone failed"
else
  ok "repo already present"
fi
CONV="$REPO/windows/tools/convert_mlx_to_gguf.py"
[ -f "$CONV" ] || die "converter not found at $CONV (does the pin still ship windows/tools?)"
ok "converter found"

# --------------------------------------------------------------- 4. the model
log "4/6  Downloading the 8B checkpoint (~4.3 GB, resumable)"
if [ -f "$SRC/model.safetensors" ]; then
  ok "source already downloaded - skipping"
else
  pip install --no-cache-dir -q "huggingface_hub[cli]" >/dev/null 2>&1 \
    || warn "could not install huggingface_hub; will try hf CLI if already present"
  if command -v hf >/dev/null 2>&1; then
    HF="hf"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    HF="huggingface-cli"
  else
    die "no hf/huggingface-cli available to download the model"
  fi
  mkdir -p "$SRC"
  "$HF" download Edge0/Edge0-8B-A1B-preview --local-dir "$SRC" || die "model download failed"
fi
for f in config.json tokenizer.json model.safetensors lora_edge0_8b.safetensors; do
  [ -f "$SRC/$f" ] || die "missing required source file: $SRC/$f"
done
ok "source complete ($(du -sh "$SRC" | cut -f1))"

# --------------------------------------------------------------- 5. conversion
log "5/6  Converting MLX -> GGUF  (this is the long step: expect 10-40 min)"
echo "    source : $SRC"
echo "    output : $OUT"
echo "    Safe to leave running; keep Termux in the foreground and the screen on."

cd "$REPO/windows/tools"
python convert_mlx_to_gguf.py --dir "$SRC" || die "conversion failed - see $OUT/convert.log"

[ -f "$OUT/edge0-8b.gguf" ]              || die "edge0-8b.gguf not produced"
[ -f "$OUT/lora_edge0_8b-gguf.gguf" ]    || die "lora_edge0_8b-gguf.gguf not produced"
ok "edge0-8b.gguf        $(du -h "$OUT/edge0-8b.gguf" | cut -f1)"
ok "lora_adapter.gguf    $(du -h "$OUT/lora_edge0_8b-gguf.gguf" | cut -f1)"

# ----------------------------------------------------------------- 6. staging
log "6/6  Staging for the app's in-app picker"
mkdir -p "$STAGE"
cp "$OUT/edge0-8b.gguf"           "$STAGE/"
cp "$OUT/lora_edge0_8b-gguf.gguf" "$STAGE/"
[ -f "$OUT/manifest.json" ] && cp "$OUT/manifest.json" "$STAGE/" || true
ok "staged into $STAGE"
ls -la "$STAGE"

cat <<EOF

============================================================================
 DONE

 Model is converted and staged. Import it into the app:

   1. Open  Edge0 Chat  ->  Models  ->  the import/picker button
   2. Import BOTH files from  Download/edge0-models/ :
         edge0-8b.gguf
         lora_edge0_8b-gguf.gguf
   3. edge0-8b appears in the model list (the lora_ file is picked up by the
      runtime automatically and is intentionally not listed).

 Source files are kept at $SRC - delete only when you are happy, so you never
 have to re-download 4.3 GB.
============================================================================
EOF
