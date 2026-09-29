#!/usr/bin/env bash
# Measure what EdgeBeat costs the machine: its own CPU, power and memory, plus
# WindowServer, which pays for compositing the overlay and never shows up in
# EdgeBeat's own numbers.
#
#   bash scripts/measure.sh [seconds] [label]
#
# Prints mean CPU %, mean POWER (top's energy-impact score) and last RSS for
# each process, and appends one line per process to measurements.tsv so runs
# can be compared later. The first top sample is always 0 and is discarded.
set -euo pipefail

SECONDS_TO_SAMPLE="${1:-20}"
LABEL="${2:-unlabelled}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$ROOT/measurements.tsv"

player_state() {
  if pgrep -x Music >/dev/null; then
    osascript -e 'tell application "Music" to player state as string' 2>/dev/null || echo unknown
  else
    echo "not-running"
  fi
}

pids=()
names=()
if pid="$(pgrep -x EdgeBeat | head -n 1)"; then
  pids+=("$pid"); names+=("EdgeBeat")
else
  echo "EdgeBeat is not running" >&2
fi
pids+=("$(pgrep -x WindowServer | head -n 1)"); names+=("WindowServer")

pid_args=()
for pid in "${pids[@]}"; do pid_args+=(-pid "$pid"); done

state="$(player_state)"
echo "==> $LABEL: sampling ${SECONDS_TO_SAMPLE}s (Music: $state)"
raw="$(top -l "$((SECONDS_TO_SAMPLE + 1))" -s 1 "${pid_args[@]}" -stats pid,cpu,power,mem)"

[ -f "$LOG" ] || printf 'date\tlabel\tmusic\tprocess\tcpu_mean\tpower_mean\trss\n' > "$LOG"
for index in "${!pids[@]}"; do
  pid="${pids[$index]}"
  name="${names[$index]}"
  summary="$(awk -v pid="$pid" '
    $1 == pid { n++; if (n > 1) { cpu += $2; power += $3; count++ } rss = $4 }
    END { if (count) printf "%.1f\t%.1f\t%s", cpu / count, power / count, rss; else print "n/a\tn/a\tn/a" }
  ' <<<"$raw")"
  IFS=$'\t' read -r cpu power rss <<<"$summary"
  printf '    %-13s cpu %6s%%   power %6s   rss %s\n' "$name" "$cpu" "$power" "$rss"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%FT%T)" "$LABEL" "$state" "$name" "$cpu" "$power" "$rss" >> "$LOG"
done
