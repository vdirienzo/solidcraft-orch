#!/usr/bin/env bash
# ------------------------------------------------------------------
# nice-compilations.sh - keep the compilations at the bottom of the
# priority queue, so that the box does what the box is for.
#
# WHY: this machine is SHARED (see the comment of ~/.cargo/config.toml:
# "esta maquina es COMPARTIDA ... si el loadavg esta por encima de 24,
# espera; y compila con nice -n 19 cargo build"). The orchestrator, the
# gateway and the agents are the work; the compilation is the filler.
# With nice 19 a compilation takes the CPU only when nothing else wants
# it, and the box stays responsive while six compilations run.
#
# It runs every couple of minutes from a cron without an agent (no
# tokens): the rustc processes are born and die constantly, so a single
# pass is not enough.
#
# It never touches the processes that are not a compilation.
# ------------------------------------------------------------------
set -uo pipefail

PIDS="$(ps -eo pid,comm --no-headers 2>/dev/null \
        | awk '$2 ~ /^(cargo|rustc)$/ {print $1}' \
        | tr '\n' ' ')"

[ -z "${PIDS// /}" ] && exit 0

# renice one group at a time: a long list in one call is rejected.
for p in $PIDS; do
  renice -n 19 -p "$p" >/dev/null 2>&1 || true
done
exit 0
