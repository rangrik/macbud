#!/bin/bash
# Helpers to drive MacBud through its URL scheme during development.
# Usage: source scripts/e2e.sh; mb open section=clipboard; mb key seq=down,return; snap name; dump
OUT=${OUT:-/tmp/macbud-e2e}
mkdir -p "$OUT"
MBCTL=${MBCTL:-$(dirname "${BASH_SOURCE[0]}")/../build/mbctl}
mb() { local cmd=$1; shift; local q=""; for p in "$@"; do q="${q}&${p}"; done
  if [ -x "$MBCTL" ]; then "$MBCTL" "${cmd}?${q#&}"; else open -g "macbud://${cmd}?${q#&}"; fi; }
snap() { mb snapshot "path=$OUT/$1.png" "window=${2:-panel}"; sleep 0.4; }
dump() { rm -f "$OUT/dump.json"; mb dump "path=$OUT/dump.json"; sleep 0.3; cat "$OUT/dump.json" 2>/dev/null; echo; }
typetext() { mb type "text=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")"; sleep 0.3; }
keys() { mb key "seq=$1"; sleep "${2:-0.4}"; }
