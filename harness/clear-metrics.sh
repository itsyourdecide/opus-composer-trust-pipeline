#!/usr/bin/env bash
#
# clear-metrics.sh [--purge] [--yes]
#
# Resets the rolling self-baseline telemetry: runs/metrics.jsonl (Composer side) and
# runs/opus-metrics.jsonl (Opus side). These are the feed metrics-report.sh / `opctl metrics`
# read; emptying them zeroes the dashboard without touching the ledger, STATE.md, or any
# committed fixtures (reconcile reads the ledger, not these logs, so it stays green).
#
# Files are TRUNCATED, not deleted — metrics-report.sh requires them to exist.
#
#   (default)   archive a timestamped copy under runs/archive/<ts>/ then truncate
#   --purge     truncate WITHOUT archiving (irreversible)
#   --yes, -y   skip the confirmation prompt
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_DIR="$ROOT/runs"
TARGETS=("$RUNS_DIR/metrics.jsonl" "$RUNS_DIR/opus-metrics.jsonl")

PURGE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "clear-metrics: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

# Count what's there now (missing file = 0 lines).
total=0
for f in "${TARGETS[@]}"; do
  n=0; [[ -f "$f" ]] && n="$(wc -l < "$f" | tr -d ' ')"
  printf '  %-24s %s lines\n' "$(basename "$f")" "$n" >&2
  total=$((total + n))
done

if [[ "$total" -eq 0 ]]; then
  echo "clear-metrics: already empty — nothing to do." >&2
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  action="archive + truncate"; [[ "$PURGE" -eq 1 ]] && action="PURGE (no archive)"
  printf 'clear-metrics: %s %d record(s)? [y/N] ' "$action" "$total" >&2
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted." >&2; exit 1; }
fi

if [[ "$PURGE" -ne 1 ]]; then
  ARCHIVE_DIR="$RUNS_DIR/archive/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$ARCHIVE_DIR"
  for f in "${TARGETS[@]}"; do
    [[ -f "$f" ]] && cp -- "$f" "$ARCHIVE_DIR/"
  done
  echo "archived to ${ARCHIVE_DIR#"$ROOT"/}" >&2
fi

# Truncate in place (keep the file present so the reader doesn't exit 2).
for f in "${TARGETS[@]}"; do
  : > "$f"
done

echo "clear-metrics: cleared $total record(s)." >&2
