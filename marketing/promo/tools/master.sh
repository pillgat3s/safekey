#!/usr/bin/env bash
# tools/master.sh [full|trailer] — mixes a soundtrack and masters it to
# -14 LUFS integrated, -1 dBTP (two-pass loudnorm) into public/audio/.
set -euo pipefail
CUT="${1:-full}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
PY="${PYTHON:-$ROOT/.venv/bin/python}"
"$PY" "$HERE/mix_soundtrack.py" "$CUT"
RAW="$HERE/build/mix_raw-$CUT.wav"
OUT="$ROOT/public/audio/soundtrack$([ "$CUT" = trailer ] && echo -trailer).wav"; mkdir -p "$(dirname "$OUT")"
M=$(ffmpeg -hide_banner -i "$RAW" -af loudnorm=I=-14:TP=-1.0:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
read -r I TP LRA THRESH OFFSET < <(echo "$M" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['input_i'], d['input_tp'], d['input_lra'], d['input_thresh'], d['target_offset'])")
ffmpeg -v error -y -i "$RAW" -af "loudnorm=I=-14:TP=-1.0:LRA=11:measured_I=${I}:measured_TP=${TP}:measured_LRA=${LRA}:measured_thresh=${THRESH}:offset=${OFFSET}:linear=true" -ar 48000 -c:a pcm_s16le "$OUT"
echo "wrote $OUT"
