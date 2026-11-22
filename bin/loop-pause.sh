#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# loop-pause.sh - pause the loop while the user needs the PC, and resume it.
#
# WHY (2026-11-21): the loop runs from the user's crontab on the user's own PC
# (12 cores, 15 GB). An agent compiling SolidCraft takes most of the CPU and
# several GB of RAM. The user needs a way to get the machine back without
# reading the scripts, and to give it back to the loop when they leave.
#
# THREE LEVELS, because stopping what runs is not always what you want:
#   pause           no NEW work: the crontab block goes (install-crontab.sh
#                   --remove) and the marker locks/loop-paused is written (the
#                   wave exits early while it exists). What runs keeps running.
#   pause --freeze  also SIGSTOP of the loop's agents and gates: the CPU is
#                   free at once and nothing is lost; the RAM stays taken (the
#                   kernel may swap it out). A freeze longer than the agent's
#                   time ceiling ends that turn on resume (its pushed work
#                   survives in the fork).
#   pause --stop    also SIGTERM of the loop's agents and gates: CPU and RAM
#                   are free; the unpushed work of the turn is lost, and the
#                   wave resumes the saved slot when the loop comes back.
#   resume          SIGCONT of what was frozen, the marker goes and the
#                   crontab block comes back.
#   status          paused or not, the crontab, and the loop's processes.
# Spanish aliases: pausar, reanudar, estado (and --congelar, --cortar).
#
# WHAT IS "THE LOOP'S PROCESSES": the sessions of bin/agent-turn.sh (every
# agent runs in its own session: dispatch-slot.sh starts it with setsid, so
# the session holds the agent, its cargo and its rustc) and the process groups
# of the gates (bin/gate.sh, gate-quick.sh, gate-queue.sh). Nothing else: the
# user's own builds and sessions are never touched.
#
# Exit code: 0 done, 2 usage, 3 the crontab could not be changed.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
MARKER="$ORCH_DIR/locks/loop-paused"
FROZEN="$ORCH_DIR/locks/loop-frozen"
INSTALLER="${LOOP_PAUSE_INSTALLER:-$HERE/install-crontab.sh}"

usage() {
  echo "uso: bash bin/loop-pause.sh pause [--freeze|--stop] | resume | status" >&2
  exit 2
}

CMD="${1:-status}"
LEVEL="${2:-}"
case "$CMD" in
  pause|pausar) CMD=pause ;;
  resume|reanudar) CMD=resume ;;
  status|estado) CMD=status ;;
  -h|--help) usage ;;
  *) usage ;;
esac
case "$LEVEL" in
  ""|--freeze|--stop) ;;
  --congelar) LEVEL=--freeze ;;
  --cortar) LEVEL=--stop ;;
  *) usage ;;
esac

# --- the loop's processes ---------------------------------------------------
# One "<kind> <id>" per line: "sid N" for an agent session, "pgid N" for a
# gate's process group. The pattern is matched on the full command line, and
# this script's own line is skipped.
# The agent of a slot is matched two ways: by bin/agent-turn.sh (the current
# dispatch) and by `opencode run ... --title issue-N` (an agent started by the
# dispatch before agent-turn.sh existed, which still runs in its own session).
# LOOP_PAUSE_TAG (tests only): count only the lines that contain it, so a test
# never freezes or stops a real agent of the machine.
loop_units() {
  ps -eo pid=,sid=,pgid=,args= 2>/dev/null | awk -v self="$$" -v tag="${LOOP_PAUSE_TAG:-}" '
    $1 == self { next }
    /loop-pause\.sh/ { next }
    tag != "" && index($0, tag) == 0 { next }
    /bin\/agent-turn\.sh/ || /opencode run .*--title issue-[0-9]/ { print "sid", $2; next }
    /bin\/gate\.sh|gate-quick\.sh|bin\/gate-queue\.sh/ { print "pgid", $3; next }
  ' | sort -u
}

# The pids of one unit.
unit_pids() {
  case "$1" in
    sid) ps -eo pid=,sid= | awk -v s="$2" '$2 == s {print $1}' ;;
    pgid) ps -eo pid=,pgid= | awk -v g="$2" '$2 == g {print $1}' ;;
  esac
}

signal_units() {  # $1 = signal name
  local kind id n=0 pids
  while read -r kind id; do
    [ -n "$id" ] || continue
    pids="$(unit_pids "$kind" "$id" | tr '\n' ' ')"
    [ -n "${pids// /}" ] || continue
    # shellcheck disable=SC2086
    kill -s "$1" $pids 2>/dev/null || true
    n=$((n + 1))
    echo "loop-pause: $1 a $kind $id ($(echo $pids | wc -w) proceso(s))"
  done < <(loop_units)
  echo "$n"
}

describe() {
  local kind id lead what state
  while read -r kind id; do
    [ -n "$id" ] || continue
    lead="$(unit_pids "$kind" "$id" | head -1)"
    what="$(ps -o args= -p "$id" 2>/dev/null | cut -c1-90)"
    [ -n "$what" ] || what="$(ps -o args= -p "$lead" 2>/dev/null | cut -c1-90)"
    state="$(unit_pids "$kind" "$id" | xargs -r ps -o stat= -p 2>/dev/null | cut -c1 | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
    echo "  $kind $id  estados: ${state:-?} | $what"
  done < <(loop_units)
}

crontab_installed() {
  crontab -l 2>/dev/null | grep -q '^# >>> solidcraft-orch >>>'
}

mkdir -p "$ORCH_DIR/locks"

case "$CMD" in
  pause)
    if bash "$INSTALLER" --remove >/dev/null 2>&1; then
      echo "loop-pause: los crons del loop se sacaron del crontab (no arranca nada nuevo)"
    else
      echo "loop-pause: no se pudo cambiar el crontab ($INSTALLER --remove)" >&2
      exit 3
    fi
    printf 'pausado %s nivel=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LEVEL:-crons}" > "$MARKER"
    case "$LEVEL" in
      --freeze)
        out="$(signal_units STOP)"; n="$(printf '%s\n' "$out" | tail -1)"
        printf '%s\n' "$out" | sed '$d'
        date -u +%Y-%m-%dT%H:%M:%SZ > "$FROZEN"
        echo "loop-pause: $n unidad(es) congelada(s): la CPU queda libre; 'resume' las descongela"
        ;;
      --stop)
        # A frozen process does not handle TERM until it runs again.
        signal_units CONT >/dev/null
        out="$(signal_units TERM)"; n="$(printf '%s\n' "$out" | tail -1)"
        printf '%s\n' "$out" | sed '$d'
        rm -f "$FROZEN"
        echo "loop-pause: $n unidad(es) cortada(s): lo pusheado queda en el fork y la wave retoma el slot al reanudar"
        ;;
      *)
        echo "loop-pause: lo que ya corre sigue hasta terminar ('pause --freeze' lo congela, 'pause --stop' lo corta)"
        ;;
    esac
    ;;
  resume)
    out="$(signal_units CONT)"; n="$(printf '%s\n' "$out" | tail -1)"
    [ "$n" -gt 0 ] && [ -f "$FROZEN" ] && echo "loop-pause: $n unidad(es) descongelada(s)"
    rm -f "$FROZEN" "$MARKER"
    if bash "$INSTALLER" >/dev/null 2>&1; then
      echo "loop-pause: los crons del loop volvieron al crontab: la wave corre en los proximos 10 minutos"
    else
      echo "loop-pause: no se pudo reinstalar el crontab ($INSTALLER)" >&2
      exit 3
    fi
    ;;
  status)
    if [ -f "$MARKER" ]; then
      echo "loop: PAUSADO ($(cat "$MARKER"))"
    else
      echo "loop: activo"
    fi
    if crontab_installed; then
      echo "crontab: los jobs del loop estan instalados ($(crontab -l 2>/dev/null | grep -c 'cd .*solidcraft-orch'))"
    else
      echo "crontab: sin los jobs del loop"
    fi
    if [ -n "$(loop_units)" ]; then
      echo "procesos del loop (estado T = congelado):"
      describe
    else
      echo "procesos del loop: ninguno"
    fi
    printf 'carga: %s   RAM disponible: %s GB\n' "$(cut -d' ' -f1 /proc/loadavg)" \
      "$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
    ;;
esac
exit 0
