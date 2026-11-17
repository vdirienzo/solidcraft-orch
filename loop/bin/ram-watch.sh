#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ram-watch.sh - the sampler of the RAM of the machine.
#
#   bin/ram-watch.sh --out DIR [--seconds N] [--every S]
#
# It samples every S seconds (5 by default) and writes one line per sample
# with:
#
#   * the memory of the system (/proc/meminfo): total, available, cached;
#   * the RSS of every process of the user, summed (the anonymous memory that
#     a runaway build would eat);
#   * the memory of the user slice, split: `anon` (the processes) and `file`
#     (the page cache of the build artifacts). The split matters: the limit of
#     a cgroup counts BOTH, so a number taken from `memory.current` alone
#     would choose a limit that the cache, not the processes, sets;
#   * the pressure of memory (PSI) and the OOM counter.
#
# It does NOT decide the limits: it measures. The numbers of `MemoryHigh` and
# `MemoryMax` are chosen from what this writes (see RUNBOOK.md, L4').
#
# It is read-only: it reads /proc and the cgroup of the user, and writes
# only into its own output directory.
# ---------------------------------------------------------------------------
set -uo pipefail

OUT=""
SECONDS_TOTAL=0
EVERY=5

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --seconds) SECONDS_TOTAL="$2"; shift 2 ;;
    --every) EVERY="$2"; shift 2 ;;
    --help|-h)
      printf 'usage: %s --out DIR [--seconds N] [--every S]\n' "$0"
      exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$OUT" ] || { printf '%s\n' "--out is needed" >&2; exit 2; }
case "$EVERY" in ''|*[!0-9]*) EVERY=5 ;; esac
case "$SECONDS_TOTAL" in ''|*[!0-9]*) SECONDS_TOTAL=0 ;; esac

mkdir -p "$OUT" || exit 1
SAMPLES="$OUT/ram-$(date -u +%Y%m%dT%H%M%SZ).tsv"
START="$(date +%s)"

# The cgroup of the user: cgroup v2 (verified on this machine).
CG="/sys/fs/cgroup/user.slice/user-1001.slice"
[ -d "$CG" ] || CG="/sys/fs/cgroup"

read_stat() { awk -v k="$1" '$1 == k { print $2; exit }' "$CG/memory.stat" 2>/dev/null; }
read_psi() {
  # The "some" line is "some avg10=0.14 avg60=0.10 avg300=0.01 total=123":
  # only the number of avg10 goes to the sample, so the column is comparable.
  awk '/^some/ { split($2, a, "="); print a[2]; exit }' /proc/pressure/memory 2>/dev/null
}
read_vmstat() { awk -v k="$1" '$1 == k { print $2; exit }' /proc/vmstat 2>/dev/null; }

{
  printf 't\tsince\tmem_total_mb\tmem_avail_mb\tcached_mb\trss_total_mb\tanon_mb\tfile_mb\tpsi_mem\t oom_kill\n'
} > "$SAMPLES"

while :; do
  now="$(date +%s)"
  since=$(( now - START ))

  mem_total="$(awk '/^MemTotal/ { print int($2/1024); exit }' /proc/meminfo)"
  mem_avail="$(awk '/^MemAvailable/ { print int($2/1024); exit }' /proc/meminfo)"
  cached="$(awk '/^Cached/ { print int($2/1024); exit }' /proc/meminfo)"
  # The RSS of the processes of this user: the memory that a runaway build
  # eats and that the kernel cannot reclaim.
  rss_total="$(ps -u "$(id -u)" -o rss= 2>/dev/null | awk '{s+=$1} END {printf "%d", s/1024}')"
  anon="$(read_stat anon)"
  file="$(read_stat file)"
  [ -n "$anon" ] || anon=0
  [ -n "$file" ] || file=0
  anon_mb=$(( anon / 1048576 ))
  file_mb=$(( file / 1048576 ))
  psi="$(read_psi)"
  oom="$(read_vmstat oom_kill)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$since" "${mem_total:-0}" "${mem_avail:-0}" "${cached:-0}" \
    "${rss_total:-0}" "$anon_mb" "$file_mb" "${psi:-0}" "${oom:-0}" >> "$SAMPLES"

  if [ "$SECONDS_TOTAL" -gt 0 ] && [ "$since" -ge "$SECONDS_TOTAL" ]; then
    break
  fi
  sleep "$EVERY"
done

# --- the summary ------------------------------------------------------------
awk -F'\t' 'BEGIN { anon = 0; rss = 0; avail = 0; psi = 0 }
NR > 1 {
  if ($7 + 0 > anon) anon = $7 + 0;
  if ($6 + 0 > rss) rss = $6 + 0;
  if (avail == 0 || $4 + 0 < avail) avail = $4 + 0;
  if ($9 + 0 > psi) psi = $9 + 0;
  n++;
}
END {
  printf "samples: %d\n", n;
  printf "peak_rss_user_mb: %d\n", rss;
  printf "peak_anon_slice_mb: %d\n", anon;
  printf "min_mem_available_mb: %d\n", avail;
  printf "peak_psi_memory: %s\n", psi;
}' "$SAMPLES" > "$OUT/summary.txt"

printf 'the samples are in %s\n' "$SAMPLES"
cat "$OUT/summary.txt"
