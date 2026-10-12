#!/bin/zsh
# hf-pull.sh <org/repo> : download a Hugging Face model repo into ~/.omlx/models/<org>/<repo>
# (resumable; skips images/assets). Then ask oMLX to rescan.
set -e
REPO="$1"; [[ -z "$REPO" ]] && { echo "usage: hf-pull.sh org/repo"; exit 1; }
DEST="$HOME/.omlx/models/$REPO"; mkdir -p "$DEST"
FILES=$(curl -fsS "https://huggingface.co/api/models/$REPO" | /usr/bin/python3 -c "import json,sys;print('\n'.join(s['rfilename'] for s in json.load(sys.stdin)['siblings'] if not s['rfilename'].startswith(('assets/','.git')) and not s['rfilename'].endswith(('.png','.jpg','.gif'))))")
for f in ${(f)FILES}; do
  mkdir -p "$DEST/${f:h}"
  echo "-> $f"
  curl -fL --retry 5 -C - -o "$DEST/$f" "https://huggingface.co/$REPO/resolve/main/$f"
done
echo "DONE $REPO -> $DEST ($(du -sh "$DEST" | cut -f1))"
