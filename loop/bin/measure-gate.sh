#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# measure-gate.sh - measure what a gate really costs on this machine.
#
# A gate is `cargo xtask ci` in the gate worktree, launched by start-gate.sh
# as a transient systemd scope (solidcraft-gate-<slot>-<issue>-<slug>). That
# scope has its own cgroup, so the numbers are EXACT: the memory of the
# cgroup is the memory of the gate, and the cpu.stat of the cgroup is the
# cpu of the gate. Nothing is estimated and nothing has to be attributed by
# hand.
#
# WHAT IT MEASURES, every `--interval` seconds (2 by default):
#   - the RAM of the gate: memory.current and memory.peak of its cgroup.
#   - the CPU of the gate: cpu.stat usage_usec, and how many cores that is.
#   - the pressure: /proc/pressure/{cpu,io,memory} (PSI), which is what
#     tells a saturated machine from a busy one.
#   - the OOM counter: oom_kill in /proc/vmstat, before and after.
#   - the machine: the load average and the busy fraction of the CPUs.
#
# The samples go to a JSONL file (one object per line) and the summary goes
# to a text file and to the standard output.
#
# The thresholds of the RAM guard (L4') come from here: the peak of the
# measured gate, with the margin that the plan asks for.
#
# USAGE:
#   measure-gate.sh [--wait SECONDS] [--unit NAME] [--out DIR]
#                   [--interval SECONDS] [--max-seconds SECONDS]
#     --wait SECONDS    wait up to SECONDS for a gate to appear (the loop
#                       launches it; this attaches to it)
#     --unit NAME       attach to this unit instead of looking for one
#     --out DIR         where the samples and the summary are written
#                       (default: $LOOP_DIR/logs/measure)
#     --interval SEC    the sampling period (default: 2)
#     --max-seconds SEC stop the measurement after this long (default: 21600)
#
# It never fails the caller: a measurement that cannot start says why and
# exits 0. It never kills anything.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

WAIT_SECONDS=0
UNIT=""
OUT_DIR="$LOOP_DIR/logs/measure"
INTERVAL=2
MAX_SECONDS=21600

while [ $# -gt 0 ]; do
  case "$1" in
    --wait=*) WAIT_SECONDS="${1#--wait=}"; shift ;;
    --wait) WAIT_SECONDS="${2:-}"; shift 2 ;;
    --unit=*) UNIT="${1#--unit=}"; shift ;;
    --unit) UNIT="${2:-}"; shift 2 ;;
    --out=*) OUT_DIR="${1#--out=}"; shift ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --interval=*) INTERVAL="${1#--interval=}"; shift ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --max-seconds=*) MAX_SECONDS="${1#--max-seconds=}"; shift ;;
    --max-seconds) MAX_SECONDS="${2:-}"; shift 2 ;;
    *) echo "measure-gate: unknown argument: $1" >&2; exit 0 ;;
  esac
done

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=2 ;; esac
case "$WAIT_SECONDS" in ''|*[!0-9]*) WAIT_SECONDS=0 ;; esac
case "$MAX_SECONDS" in ''|*[!0-9]*) MAX_SECONDS=21600 ;; esac

mkdir -p "$OUT_DIR" || exit 0
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAMPLES="$OUT_DIR/gate-$STAMP.jsonl"
SUMMARY="$OUT_DIR/gate-$STAMP.summary.txt"

# The number of CPUs: the mean of the cores is what the CPU of the gate is
# measured against.
NCPU="$(nproc 2>/dev/null || echo 1)"
case "$NCPU" in ''|*[!0-9]*) NCPU=1 ;; esac

say() { echo "measure-gate: $*"; }

# --- find the gate ------------------------------------------------------------
# The gate is a transient SERVICE (systemd-run --unit=... without --scope),
# and its unit name is solidcraft-gate-<slot>-<issue>-<slug>.service.
# `--plain` matters: without it the first column of the listing carries the
# bullet of the tree and the unit name would be read wrong.
find_gate_unit() {
  systemctl --user list-units 'solidcraft-gate-*' --all --plain --no-legend --no-pager 2>/dev/null \
    | awk '$3 == "running" { print $1; exit }'
}

if [ -z "$UNIT" ]; then
  UNIT="$(find_gate_unit)"
  if [ -z "$UNIT" ] && [ "$WAIT_SECONDS" -gt 0 ]; then
    say "no gate is running: waiting up to ${WAIT_SECONDS}s"
    deadline=$(( $(date +%s) + WAIT_SECONDS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      sleep 5
      UNIT="$(find_gate_unit)"
      [ -n "$UNIT" ] && break
    done
  fi
fi

if [ -z "$UNIT" ]; then
  say "there is no gate to measure"
  exit 0
fi
say "attaching to $UNIT"

CGROUP="$(systemctl --user show "$UNIT" -p ControlGroup --value 2>/dev/null || true)"
CGROUP="${CGROUP#/}"
if [ -z "$CGROUP" ]; then
  say "the unit has no control group (it may have just finished)"
  exit 0
fi
CG_DIR="/sys/fs/cgroup/$CGROUP"
if [ ! -d "$CG_DIR" ]; then
  say "the control group $CGROUP does not exist"
  exit 0
fi
say "control group: $CGROUP"

# --- the readers --------------------------------------------------------------
# Every reader returns empty when the value is not there: the unit can die
# between two samples, and a sample that does not exist is not a zero.
read_num() {
  local file="$1" value
  [ -r "$file" ] || { echo ""; return 0; }
  value="$(tr -dc '0-9' < "$file" 2>/dev/null | head -c 20)"
  echo "$value"
}

read_psi() {
  local file="$1" avg
  [ -r "$file" ] || { echo ""; return 0; }
  avg="$(awk '/^some/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg/) { split($i, a, "="); print a[2]; exit } }' "$file" 2>/dev/null)"
  echo "$avg"
}

# The same value in hundredths: the PSI is a float ("0.00", "15.45") and the
# comparisons of the peaks are with integers.
read_psi_centi() {
  local file="$1" avg
  avg="$(read_psi "$file")"
  case "$avg" in ''|*[!0-9.]*) echo 0; return 0 ;; esac
  awk -v v="$avg" 'BEGIN { printf "%d", v * 100 }'
}

read_psi_total() {
  local file="$1" total
  [ -r "$file" ] || { echo ""; return 0; }
  total="$(awk '/^total/ { for (i = 1; i <= NF; i++) if ($i ~ /^total=/) { split($i, a, "="); print a[2]; exit } }' "$file" 2>/dev/null)"
  echo "$total"
}

read_vmstat() {
  local key="$1" value
  [ -r /proc/vmstat ] || { echo ""; return 0; }
  value="$(awk -v k="$key" '$1 == k { print $2; exit }' /proc/vmstat 2>/dev/null)"
  echo "$value"
}

# The busy fraction of the CPUs, from /proc/stat: the difference of the two
# samples of the jiffies, busy over total.
read_cpu_jiffies() {
  awk '/^cpu / { print $2+$3+$4+$5+$6+$7+$8, $2+$3+$4+$5+$6+$7+$8+$9 }' /proc/stat 2>/dev/null
}

# --- the measurement ----------------------------------------------------------
START="$(date +%s)"
START_ISO="$(date -Is)"
OOM_KILL_0="$(read_vmstat oom_kill)"
PGMAJ_0="$(read_vmstat pgmajfault)"
PSI_CPU_T0="$(read_psi_total /proc/pressure/cpu)"
PSI_IO_T0="$(read_psi_total /proc/pressure/io)"
PSI_MEM_T0="$(read_psi_total /proc/pressure/memory)"
BUSY0="$(read_cpu_jiffies)"
set -- $BUSY0
BUSY_PREV="${1:-0}"
TOTAL_PREV="${2:-0}"

PEAK_MEM=0
PEAK_MEM_AT=0
PEAK_LOAD=0
PEAK_PSI_CPU=0
PEAK_PSI_IO=0
PEAK_PSI_MEM=0
PEAK_TASKS=0
SAMPLES_N=0
MEM_SUM=0
MEM_MAX_CGROUP=0

: > "$SAMPLES"
say "sampling every ${INTERVAL}s into $SAMPLES"

DEADLINE=$(( START + MAX_SECONDS ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  NOW="$(date +%s)"

  # The unit can disappear at any moment (systemd-run --collect): that is
  # the end of the measurement, not an error.
  if ! systemctl --user show "$UNIT" -p ActiveState --value >/dev/null 2>&1; then
    break
  fi
  STATE="$(systemctl --user show "$UNIT" -p ActiveState --value 2>/dev/null || true)"
  [ "$STATE" = "active" ] || [ "$STATE" = "activating" ] || break

  MEM="$(read_num "$CG_DIR/memory.current")"
  MEM_PEAK="$(read_num "$CG_DIR/memory.peak")"
  CPU_US="$(awk '/^usage_usec/ { print $2; exit }' "$CG_DIR/cpu.stat" 2>/dev/null)"
  TASKS="$(read_num "$CG_DIR/pids.current")"
  LOAD1="$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)"
  PSI_CPU="$(read_psi /proc/pressure/cpu)"
  PSI_IO="$(read_psi /proc/pressure/io)"
  PSI_MEM="$(read_psi /proc/pressure/memory)"
  PSI_CPU_C="$(read_psi_centi /proc/pressure/cpu)"
  PSI_IO_C="$(read_psi_centi /proc/pressure/io)"
  PSI_MEM_C="$(read_psi_centi /proc/pressure/memory)"
  OOM_KILL="$(read_vmstat oom_kill)"
  BUSY="$(read_cpu_jiffies)"
  set -- $BUSY
  BUSY_NOW="${1:-0}"
  TOTAL_NOW="${2:-0}"

  BUSY_DELTA=$(( BUSY_NOW - BUSY_PREV ))
  TOTAL_DELTA=$(( TOTAL_NOW - TOTAL_PREV ))
  BUSY_PCT=0
  [ "${TOTAL_DELTA:-0}" -gt 0 ] && BUSY_PCT=$(( BUSY_DELTA * 100 / TOTAL_DELTA ))
  BUSY_PREV="$BUSY_NOW"
  TOTAL_PREV="$TOTAL_NOW"

  printf '{"t":%s,"mem":%s,"mem_peak":%s,"cpu_us":%s,"tasks":%s,"load1":%s,"psi_cpu":%s,"psi_io":%s,"psi_mem":%s,"oom_kill":%s,"busy_pct":%s}\n' \
    "$NOW" "${MEM:-0}" "${MEM_PEAK:-0}" "${CPU_US:-0}" "${TASKS:-0}" "${LOAD1:-0}" \
    "${PSI_CPU:-0}" "${PSI_IO:-0}" "${PSI_MEM:-0}" "${OOM_KILL:-0}" "$BUSY_PCT" >> "$SAMPLES"
  SAMPLES_N=$(( SAMPLES_N + 1 ))

  [ "${MEM:-0}" -gt "$PEAK_MEM" ] && { PEAK_MEM="$MEM"; PEAK_MEM_AT="$NOW"; }
  [ "${MEM_PEAK:-0}" -gt "$MEM_MAX_CGROUP" ] && MEM_MAX_CGROUP="$MEM_PEAK"
  [ "${LOAD1%%.*}" -gt "$PEAK_LOAD" ] && PEAK_LOAD="${LOAD1%%.*}"
  [ "${PSI_CPU_C:-0}" -gt "$PEAK_PSI_CPU" ] && PEAK_PSI_CPU="$PSI_CPU_C"
  [ "${PSI_IO_C:-0}" -gt "$PEAK_PSI_IO" ] && PEAK_PSI_IO="$PSI_IO_C"
  [ "${PSI_MEM_C:-0}" -gt "$PEAK_PSI_MEM" ] && PEAK_PSI_MEM="$PSI_MEM_C"
  [ "${TASKS:-0}" -gt "$PEAK_TASKS" ] && PEAK_TASKS="$TASKS"
  MEM_SUM=$(( MEM_SUM + ${MEM:-0} ))

  sleep "$INTERVAL"
done

END="$(date +%s)"
END_ISO="$(date -Is)"
DURATION=$(( END - START ))
[ "$DURATION" -lt 1 ] && DURATION=1

OOM_KILL_1="$(read_vmstat oom_kill)"
PGMAJ_1="$(read_vmstat pgmajfault)"
PSI_CPU_T1="$(read_psi_total /proc/pressure/cpu)"
PSI_IO_T1="$(read_psi_total /proc/pressure/io)"
PSI_MEM_T1="$(read_psi_total /proc/pressure/memory)"
CPU_US_END="$(awk '/^usage_usec/ { print $2; exit }' "$CG_DIR/cpu.stat" 2>/dev/null)"
[ -z "$CPU_US_END" ] && CPU_US_END=0
CPU_US_START=0
if [ -s "$SAMPLES" ]; then
  CPU_US_START="$(head -1 "$SAMPLES" | sed -n 's/.*"cpu_us":\([0-9]*\).*/\1/p')"
fi
CPU_US_TOTAL=$(( CPU_US_END - CPU_US_START ))
MEAN_CORES="$(awk -v u="$CPU_US_TOTAL" -v d="$DURATION" 'BEGIN { printf "%.2f", u / 1000000 / d }')"
MEAN_MEM=$(( MEM_SUM / (SAMPLES_N > 0 ? SAMPLES_N : 1) ))
OOM_DELTA=$(( ${OOM_KILL_1:-0} - ${OOM_KILL_0:-0} ))
PGMAJ_DELTA=$(( ${PGMAJ_1:-0} - ${PGMAJ_0:-0} ))
PSI_CPU_D=$(( ${PSI_CPU_T1:-0} - ${PSI_CPU_T0:-0} ))
PSI_IO_D=$(( ${PSI_IO_T1:-0} - ${PSI_IO_T0:-0} ))
PSI_MEM_D=$(( ${PSI_MEM_T1:-0} - ${PSI_MEM_T0:-0} ))

{
  echo "gate: $UNIT"
  echo "cgroup: $CGROUP"
  echo "start: $START_ISO"
  echo "end: $END_ISO"
  echo "duration_s: $DURATION"
  echo "samples: $SAMPLES_N"
  echo "interval_s: $INTERVAL"
  echo
  echo "# RAM"
  echo "peak_mem_bytes: $PEAK_MEM"
  echo "peak_mem_gb: $(awk -v b="$PEAK_MEM" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"
  echo "peak_mem_at: $PEAK_MEM_AT"
  echo "cgroup_mem_peak_bytes: $MEM_MAX_CGROUP"
  echo "cgroup_mem_peak_gb: $(awk -v b="$MEM_MAX_CGROUP" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"
  echo "mean_mem_gb: $(awk -v b="$MEAN_MEM" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"
  echo
  echo "# CPU"
  echo "cpu_us_total: $CPU_US_TOTAL"
  echo "mean_cores: $(awk -v u="$CPU_US_TOTAL" -v d="$DURATION" 'BEGIN { printf "%.2f", u / 1000000 / d }')"
  echo "machine_cores: $NCPU"
  echo "mean_core_share: $(awk -v u="$CPU_US_TOTAL" -v d="$DURATION" -v n="$NCPU" 'BEGIN { printf "%.1f", (n > 0) ? (u / 1000000 / d) * 100 / n : 0 }')%"
  echo "peak_load1: $PEAK_LOAD"
  echo "peak_tasks: $PEAK_TASKS"
  echo
  echo "# PRESSURE (PSI, microseconds of stall)"
  echo "psi_cpu_avg10_peak: $(awk -v c="$PEAK_PSI_CPU" 'BEGIN { printf "%.2f", c / 100 }')"
  echo "psi_io_avg10_peak: $(awk -v c="$PEAK_PSI_IO" 'BEGIN { printf "%.2f", c / 100 }')"
  echo "psi_memory_avg10_peak: $(awk -v c="$PEAK_PSI_MEM" 'BEGIN { printf "%.2f", c / 100 }')"
  echo "psi_cpu_total_us: $PSI_CPU_D"
  echo "psi_io_total_us: $PSI_IO_D"
  echo "psi_memory_total_us: $PSI_MEM_D"
  echo
  echo "# SAFETY"
  echo "oom_kill_before: ${OOM_KILL_0:-0}"
  echo "oom_kill_after: ${OOM_KILL_1:-0}"
  echo "oom_kill_delta: $OOM_DELTA"
  echo "pgmajfault_delta: $PGMAJ_DELTA"
  echo
  echo "samples_file: $SAMPLES"
} > "$SUMMARY"

cat "$SUMMARY"
say "the summary is in $SUMMARY"
exit 0
