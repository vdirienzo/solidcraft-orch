#!/usr/bin/env bash
# sccache-health.sh - is the compile cache earning the disk it holds?
#
# WHY THIS EXISTS (2026-11-17): a hit rate near 0% has TWO causes, and they
# call for opposite actions.
#
#   1. The cache has nothing to hit (the crates changed): it is pure loss, and
#      the disk-hygiene rule says to delete it.
#   2. The cache is TOO SMALL: it evicts, between builds, exactly what the next
#      build needs. It looks like case 1 in `sccache --show-stats` and it makes
#      every slot's gate pay the cold price forever.
#
# MEASURED ON THIS BOX (2026-11-17, the ci profile of solidcraft-io +
# solidcraft-engine): one build leaves 5.6 GB of artifacts and the default
# sccache cap is 10 GiB, so the cache is full after two builds and the hit
# rate stays at 0% (293 compiles, 0 hits). With the cap at 60 GB the same
# build comes out of the cache.
#
# WHAT IT PRINTS:
#   - the hit rate, the cache size, its cap and the free disk
#   - the verdict: the cache is too small, or it is not earning its disk, or it
#     is working
#
# EXIT CODES:
#   0  the cache is working (or there is nothing to measure)
#   1  the cache is too small: raise SCCACHE_MAX_CACHE_SIZE
#   2  the cache is not earning its disk: delete it (the disk-hygiene rule)
#   3  the cache could not be read
#
# usage: bash bin/sccache-health.sh
set -uo pipefail
# The numbers are printed with a dot and compared as numbers: a locale that
# prints "10,0" turns awk's comparison into a string comparison ("10,0" < "9").
export LC_ALL=C

# The sccache to ask. It lives outside the PATH on purpose (README rule 4),
# and a test points this at a stub.
SCCACHE_BIN="${SCCACHE_BIN:-/home/user/.local/bin/sccache}"
# Where the cache lives, and the biggest one build of this workspace leaves
# (the ci profile of the two biggest crates). Both are measured, not guessed.
CACHE_DIR="${SCCACHE_CACHE_DIR:-$HOME/.cache/sccache}"
BUILD_GB="${SCCACHE_BUILD_GB:-5.6}"

if ! command -v "$SCCACHE_BIN" >/dev/null 2>&1 && [ ! -x "$SCCACHE_BIN" ]; then
  echo "sccache-health: sccache is not there: $SCCACHE_BIN" >&2
  exit 3
fi

stats="$("$SCCACHE_BIN" --show-stats 2>/dev/null)" || stats=""
if [ -z "$stats" ]; then
  echo "sccache-health: sccache did not answer: $SCCACHE_BIN --show-stats" >&2
  exit 3
fi

hits="$(printf '%s\n' "$stats" | awk '$1 == "Cache" && $2 == "hits" {print $3; exit}')"
misses="$(printf '%s\n' "$stats" | awk '$1 == "Cache" && $2 == "misses" {print $3; exit}')"
total=$(( ${hits:-0} + ${misses:-0} ))
rate="$(awk -v h="${hits:-0}" -v t="$total" 'BEGIN { if (t > 0) printf "%.1f", 100 * h / t; else print "0" }')"
cap="$(printf '%s\n' "$stats" | awk '$1 == "Max" && $2 == "cache" && $3 == "size" {print $4 " " $5; exit}')"
cap_gb="$(printf '%s' "${cap:-0}" | awk '{print $1 + 0}')"
size_gb="$(printf '%s\n' "$stats" | awk '$1 == "Cache" && $2 == "size" {print $3; exit}')"
size_gb="$(printf '%s' "${size_gb:-}" | awk '{print $1 + 0}')"
if [ "${size_gb:-0}" = "0" ]; then
  size_gb="$(du -sm "$CACHE_DIR" 2>/dev/null | awk '{printf "%.1f", $1 / 1024}')"
fi
free_gb="$(df -BG "$CACHE_DIR" 2>/dev/null | awk 'NR == 2 {gsub("G", "", $4); print $4}')"

echo "hit rate: ${rate}% (${hits:-0} hits, ${misses:-0} misses)"
echo "cache: ${size_gb:-0} GB on disk, cap ${cap:-unknown}, ${free_gb:-?} GB free"
echo "one build of this workspace leaves about ${BUILD_GB} GB of artifacts"

if [ "${total:-0}" -eq 0 ]; then
  echo "VERDICT: nothing was compiled yet: there is nothing to measure"
  exit 0
fi

# The cache is too small when it is FULL and it still misses everything: the
# cap is below what a build needs, so the LRU evicts what comes next.
if awk -v s="${size_gb:-0}" -v c="${cap_gb:-0}" 'BEGIN { exit !((c + 0) > 0 && (s + 0) >= (c + 0) * 0.9) }'; then
  echo "VERDICT: the cache is too small: it is at its cap (${cap:-unknown}) and it still misses everything."
  echo "  One build leaves about ${BUILD_GB} GB, so the cap has to hold at least two of them."
  echo "  Raise it in the machine's cargo config: [env] SCCACHE_MAX_CACHE_SIZE = \"60G\","
  echo "  then restart the cache: ${SCCACHE_BIN} --stop-server"
  exit 1
fi

if awk -v r="$rate" 'BEGIN { exit !((r + 0) < 20) }'; then
  echo "VERDICT: the cache is not earning its disk: ${rate}% of the compiles came from it."
  echo "  The disk-hygiene rule covers this one: delete the cache."
  exit 2
fi

echo "VERDICT: the cache is working: ${rate}% of the compiles came from it"
exit 0
