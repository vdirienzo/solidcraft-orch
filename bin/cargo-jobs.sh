#!/usr/bin/env bash
# ------------------------------------------------------------------
# cargo-jobs.sh - how many parallel jobs a cargo invocation should use.
#
# WHY THIS EXISTS (2026-11-03): the machine has 16 cores and 62 GB of RAM
# and it is SHARED. ~/.cargo/config.toml already sets jobs = 12, and its
# own comment says the measurement: 12 == 16 in build time, but "a partir
# de 20 el System time se multiplica x8 por saturacion de ancho de banda
# de memoria". Five concurrent compilations (2 gates + 3 agent tests) ask
# for 60 jobs on 16 cores: the load average went to 41, every compile got
# slower and the big crates died OOM-killed.
#
# So the TOTAL of the jobs has to stay near the number of cores, no
# matter how many compilations run at the same time:
#
#   jobs = max(4, floor(16 / concurrent_compilations))
#
# With one compilation it is 16 (the whole box, the fastest single build),
# with two it is 8, with three 5, with five 4. The total never passes 16,
# so the "system time x8" cliff is never reached. The floor of 4 keeps a
# compile moving when the box is crowded.
#
# It also prints the nice level the compilation should run with: the
# config of the machine says that when the load average is above 24 you
# have to wait, and to compile with "nice -n 19" so that the interactive
# work (the agents, the gateway) is not starved by the compiler.
#
# USAGE:
#   bash cargo-jobs.sh            -> the number of jobs (on stdout)
#   bash cargo-jobs.sh --explain  -> the same, with the arithmetic
#   bash cargo-jobs.sh --env      -> "CARGO_BUILD_JOBS=N NICE_LEVEL=M"
#
# It is also exported as CARGO_BUILD_JOBS, which cargo prefers over the
# [build] jobs of ~/.cargo/config.toml.
# ------------------------------------------------------------------
set -uo pipefail

CORES="$(nproc 2>/dev/null || echo 4)"

# The compilations running right now: one per cargo process. Counting the
# rustc children instead would count the jobs of a single compilation.
#
# WHY THE NAME IS NOT ENOUGH (2026-11-18): `pgrep -x cargo` matches the
# process NAME exactly, and cargo is not always called 'cargo': a clippy
# runs as 'cargo-clippy' and a nextest as 'cargo-nextest'. The script counted
# ONE compilation while a clippy of seven packages was running with 16 jobs,
# and its clippy-driver of solidcraft_engine reached 4.7 GB of RSS: the OOM
# killer took it, and with it the whole scope of the build that was next to
# it (the nextest of another slot, which died with exit 143 and no fault of
# its own).
#
# The count is by COMMAND, and each cargo invocation counts ONCE: the
# 'timeout --kill-after' wrapper and the 'cargo' that it runs are the same
# compilation.
# Each PROCESS is a compilation, so the count cannot be a count of NAMES: a
# box with eight 'cargo' processes has eight compilations, not one. The
# name of the binary is what tells them apart from the rest of the system.
CONC="$(ps -eo cmd= 2>/dev/null \
        | grep -E '(^|[ /])cargo(-clippy|-nextest)?( |$)' \
        | grep -vE 'cargo-jobs(\.sh)?( |$)' \
        | awk 'END{print NR}' | tr -d ' ')"
case "$CONC" in ''|*[!0-9]*) CONC=1 ;; esac
[ "$CONC" -lt 1 ] && CONC=1

JOBS=$(( CORES / CONC ))
[ "$JOBS" -lt 4 ] && JOBS=4
[ "$JOBS" -gt "$CORES" ] && JOBS="$CORES"

# The load average decides the nice level: the box is shared, and a
# compile that is not urgent must not take the cores from the agents.
LOAD="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)"
NICE=19
if [ "$LOAD" -lt 8 ] 2>/dev/null; then NICE=10; fi
if [ "$LOAD" -lt 4 ] 2>/dev/null; then NICE=0; fi

case "${1:-}" in
  --explain) printf 'cores=%s concurrent_compilations=%s load=%s jobs=%s nice=%s\n' \
              "$CORES" "$CONC" "$LOAD" "$JOBS" "$NICE" ;;
  --env)     printf 'CARGO_BUILD_JOBS=%s NICE_LEVEL=%s\n' "$JOBS" "$NICE" ;;
  *)         printf '%s\n' "$JOBS" ;;
esac
exit 0
