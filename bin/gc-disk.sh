#!/usr/bin/env bash
# The cron entry point of the disk cleanup.
#
# WHY THIS WRAPPER EXISTS (2026-11-17): the cleanup itself lives in
# $LOOP_DIR/bin/gc-disk.sh (the half of the orchestrator that was outside
# git until this repo versioned it in loop/). The cron line of bin/crons.txt
# names bin/gc-disk.sh, and this wrapper delegates in the versioned copy of
# the cleanup that lives in this repo:
#
#   1. the copy in this repo (loop/bin/gc-disk.sh) when it is there, so
#      the repo is the source of truth;
#   2. the live $LOOP_DIR/bin/gc-disk.sh otherwise, so a machine that
#      has not fetched the repo yet still cleans its disk.
#
# (2026-11-21: the crontab of the user runs the scripts OF THE REPO, so the
# repo is found from this script's own directory. The old scheduler ran
# copies outside bin/ and needed the absolute path of this machine.)
#
# WHY IT DELEGATES AND DOES NOT DUPLICATE: the cleanup has a guard of
# 24 hours (DISK_GC_INTERVAL_H) and its own lock ($LOOP_DIR/.lock.gc):
# running it often is cheap and safe. The guard is what makes it run
# once a day, NOT the frequency of the cron.
#
# WHY IT NEVER FAILS THE CRON: a cleanup that cannot run (no disk, no
# permission, a repo not fetched) must not turn into an alert every
# 15 minutes. The failures go to stderr and the exit code is 0.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

# The copy of the repo first: the repo is the source of truth.
target="$ORCH_DIR/loop/bin/gc-disk.sh"
[ -f "$target" ] || target="$LOOP_DIR/bin/gc-disk.sh"

if [ ! -f "$target" ]; then
  echo "gc-disk: no hay ni $ORCH_DIR/loop/bin/gc-disk.sh ni $LOOP_DIR/bin/gc-disk.sh" >&2
  exit 0
fi

bash "$target" "$@"
rc=$?

# The cleanup is best-effort: a disk that filled up is reported by the
# disk itself, not by an alert of the cron every 15 minutes.
if [ "$rc" -ne 0 ]; then
  echo "gc-disk: la limpieza devolvio rc=$rc (se ignora: es de mejor esfuerzo)" >&2
fi
exit 0
