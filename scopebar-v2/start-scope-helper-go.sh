#!/bin/sh
# Start the PipeWire monitor and the native Go DSP helper.
# Usage: start-scope-helper-go.sh [sink description] [keep-every] [points]
set -eu

DESC="${1:-}"
KEEP="${2:-16}"
POINTS="${3:-96}"
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN="$DIR/scopebar-go"
OUT="/tmp/noctalia-scopebar-go.csv"

pkill -f 'scopebar-go-helper' 2>/dev/null || true
pkill -f 'scopebar-go-bin' 2>/dev/null || true
pkill -f 'pw-record --ra[w]' 2>/dev/null || true
sleep 0.15

TARGET=""
if [ -n "$DESC" ] && command -v pw-dump >/dev/null 2>&1; then
  QUERY=$(printf '%s' "$DESC" | sed 's/\.monitor$//')
  TARGET=$(pw-dump -N 2>/dev/null | python3 -c '
import sys, json
q = sys.argv[1].lower()
try: data = json.load(sys.stdin)
except Exception: raise SystemExit
for obj in data:
    props = (obj.get("info") or {}).get("props") or {}
    if props.get("media.class") not in ("Audio/Sink", "Audio/Sink/Virtual"): continue
    name = props.get("node.name", "")
    hay = " ".join(x for x in (props.get("node.description"), props.get("node.nick"), name) if x).lower()
    if q == hay or q in hay or hay in q:
        print(name); break
' "$QUERY" 2>/dev/null || true)
fi

if [ -z "$TARGET" ] && command -v pactl >/dev/null 2>&1; then
  TARGET=$(pactl get-default-sink 2>/dev/null || true)
fi
if [ -z "$TARGET" ] || [ "$TARGET" = "@DEFAULT_AUDIO_SINK@" ]; then
  echo "scopebar: no sink resolved" >&2
  exit 1
fi
if [ ! -x "$BIN" ]; then
  echo "scopebar: missing executable $BIN (run install.sh or go build -o scopebar-go .)" >&2
  exit 1
fi

# The marker in the command line is used by onExit without matching this
# launcher itself.  PIPEWIRE_PROPS selects the sink monitor, never the mic.
exec setsid nohup env PIPEWIRE_PROPS='{ stream.capture.sink = true }' sh -c 'exec pw-record --raw --format f32 --channels 1 --rate 48000 --latency 256 --target "$1" - 2>/tmp/noctalia-scopebar-go-pw.err | exec "$2" -rate 48000 -keep "$3" -points "$4" -output "$5"' scopebar-go-helper "$TARGET" "$BIN" "$KEEP" "$POINTS" "$OUT" >/tmp/noctalia-scopebar-go-helper.log 2>&1 &
