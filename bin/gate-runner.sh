#!/bin/bash
# El runner de los gates: uno a uno, sin la carrera del diferimiento.
#
# POR QUE EXISTE: gate-quick toma el lock de scope GLOBAL con GATE_SCOPE_LOCK_WAIT=0.
# Si dos gates se lanzan a la vez, CADA UNO cree que el otro tiene el lock, y los
# dos se difieren (GATE_STATUS=skipped, DEFERRED=scope-gate-alive). El resultado es
# que ningun gate corre y los dos PRs quedan sin veredicto.
#
# Este runner los recorre en serie: uno espera a que el anterior termine. Como es
# el unico que lanza gates, nunca se diferira por otro gate.
#
# Uso: gate-runner.sh <slot> <sha> [<worktree>]
#   sin argumentos: corre los gates PENDIENTES que salen del ESTADO
#   (bin/orch-state.sh), no de una lista escrita en este archivo.
set -u
# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
# The accessor of the state reads $ORCH_DIR: it has to be the SAME directory
# this script resolved, so it is exported.
export ORCH_DIR
B="$ORCH_DIR/bin"
L="$LOOP_DIR/gates"
LOGD="$ORCH_DIR/logs"
mkdir -p "$LOGD"

# el veredicto de este sha ya sirve? El vocabulario real de GATE_STATUS es
# finished|failed|skipped (NO passed/green/ok): con el vocabulario equivocado el
# served() nunca daba true y el runner relanzaba el 100% de los gates (39% del
# gasto medido: 30 core-h).
#
# EL SHA SE COMPARA ANCLADO (2026-11-17): el "grep -q SHA=$sha" de antes no
# estaba anclado y encontraba "SHA=0d74d8ca" DENTRO de la linea "SHA=0d74d8cae"
# de un veredicto de OTRO commit: el runner daba por gateado un commit que no
# se gateo. El sha del veredicto tiene que ser EXACTAMENTE el que se pide.
served() {
  local slot="$1" sha="$2" v="$L/$slot/scope.verdict"
  [ -n "$sha" ] || return 1
  # A sha is hexadecimal: anything else is not a sha and it can not be
  # compared (and it does not have to go into the pattern of grep).
  case "$sha" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ -f "$v" ] || return 1
  grep -qE "^SHA=${sha}[[:space:]]*$" "$v" || return 1
  grep -qE '^GATE_STATUS=finished' "$v"
}

run_one() {
  local slot="$1" sha="$2" wt="$3"
  local v="$L/$slot/scope.verdict"
  if served "$slot" "$sha"; then
    echo "[$(date +%H:%M:%S)] $slot $sha ya tiene veredicto: $(grep -hE '^(GATE_STATUS|VERDICT)' "$v" | tr '\n' ' ')"
    return 0
  fi
  echo "[$(date +%H:%M:%S)] corro el gate de $slot ($sha) en $wt"
  cd "$wt" || { echo "  no existe el worktree $wt"; return 1; }
  bash "$B/gate.sh" "$slot" "$sha" > "/tmp/gate-$slot.log" 2>&1
  local rc=$?
  echo "[$(date +%H:%M:%S)] $slot termino (rc=$rc): $(grep -hE '^(GATE_STATUS|VERDICT|SHA|NEW_FAILURES|DEFERRED)' "$v" 2>/dev/null | tr '\n' ' ' | cut -c1-190)"
  tail -4 "/tmp/gate-$slot.log" | sed 's/^/    /'
  # The exit code of the gate is the exit code of this function (RULES.md: the
  # one that reports it propagates it). Before, the runner said "termino
  # (rc=0)" and then returned 0 whatever the gate had said.
  return $rc
}

# ---------------------------------------------------------------------------
# THE PENDING SLOTS COME FROM THE STATE (2026-11-17).
#
# BEFORE: the slots to gate were WRITTEN in this file (a hardcoded line per
# slot, with its sha). The runner was a script of one day: the day the slot
# changed, it gated a commit that was not the one of the state, or nothing at
# all.
#
# NOW: without arguments, the runner asks the STATE for the gates that are
# pending and it gates THOSE. The state is read with bin/orch-state.sh, the
# accessor that everybody uses: the state is 30-144 KB and it is NEVER read
# whole.
#
# WHAT COUNTS AS PENDING (the rules, not the implementation):
#   * the entry has an issue number AND a sha: without both there is nothing
#     to gate;
#   * the entry does not say that its gate already happened: a terminal status
#     (finished, done, published, merged, ...) or the verdict of a finished run
#     (VERDE-SCOPE, ROJO-SCOPE, ...) means the gate is done. A DEFERRED gate
#     (skipped) is NOT a verdict: it is still pending, it has to run;
#   * a slot that is in the state twice (in "gates" and in "slots") is gated
#     once.
# ---------------------------------------------------------------------------

# The reader of the state: it prints one "issue sha" line per pending slot.
#   $1 = "compact" (the output of the accessor) | "json" (the path of the state)
#   $2 = the payload of that mode
state_pending() {
  python3 - "$1" "${2:-}" <<'PY'
import json, re, sys

# The statuses that say "the gate already happened".
TERMINAL = {
    "finished", "done", "complete", "completed", "served", "published",
    "merged", "closed", "cancelled", "canceled", "abandoned", "lost",
    "perdido", "perdedor", "verde", "green", "ok", "rojo", "red",
    "finalizado", "terminado",
}
# A deferred gate is NOT a verdict: it has to run again.
PENDING_VERDICTS = {"deferred", "skipped", "diferido", "pendiente", "pending"}
SHA_RE = re.compile(r"^[0-9a-fA-F]{7,40}$")


def as_dict(value):
    """The value of an entry as a dict, plus its raw text.

    The accessor cuts the long values at 400 characters, so a value that is
    not valid JSON is read with a regex on the fields that matter.
    """
    if isinstance(value, dict):
        return value, ""
    if isinstance(value, str) and value.startswith("{"):
        try:
            parsed = json.loads(value)
        except ValueError:
            return {}, value
        if isinstance(parsed, dict):
            return parsed, ""
    return {}, ""


def field(d, raw, names, rx):
    for name in names:
        if name in d:
            return d[name]
    m = re.search(rx, raw)
    return m.group(1) if m else None


def issue_of(key, d, raw):
    v = field(d, raw, ("issue", "numero", "number"), r'"issue"\s*:\s*"?(\d+)')
    if isinstance(v, int) and v > 0:
        return v
    if isinstance(v, str) and v.strip().isdigit():
        return int(v.strip())
    m = re.search(r"(\d+)", str(key))
    return int(m.group(1)) if m else None


def sha_of(d, raw):
    v = field(d, raw, ("sha", "commit", "head_sha"),
              r'"sha"\s*:\s*"([0-9a-fA-F]{7,40})"')
    if isinstance(v, str) and SHA_RE.match(v.strip()):
        return v.strip()
    return None


def status_of(d, raw):
    v = field(d, raw, ("status", "state", "estado"), r'"status"\s*:\s*"([^"]*)"')
    return v.strip().lower() if isinstance(v, str) else ""


def verdict_of(d, raw):
    v = field(d, raw, ("verdict", "veredicto"), r'"verdict"\s*:\s*"([^"]*)"')
    return v.strip().lower() if isinstance(v, str) else ""


mode = sys.argv[1] if len(sys.argv) > 1 else ""
payload = sys.argv[2] if len(sys.argv) > 2 else ""
entries = []

if mode == "compact":
    # The output of bin/orch-state.sh: one "key: value" line per entry, with
    # the value in JSON.
    for line in payload.splitlines():
        line = line.rstrip()
        if not line.strip():
            continue
        if line.startswith("["):
            i = line.find("]")
            if i < 0:
                continue
            key = line[1:i].strip()
            rest = line[i + 1:].strip()
        else:
            i = line.find(":")
            if i < 0:
                continue
            key = line[:i].strip()
            rest = line[i + 1:].strip()
        try:
            value = json.loads(rest)
        except ValueError:
            value = rest
        entries.append((key, value))
else:
    # The fallback: the SAME two keys, read directly. The state is never read
    # whole: only "gates" and "slots" come out of it.
    try:
        with open(payload, encoding="utf-8") as fh:
            state = json.load(fh)
    except Exception:
        state = {}
    if not isinstance(state, dict):
        state = {}
    for group in ("gates", "slots"):
        g = state.get(group)
        if isinstance(g, dict):
            for k, v in g.items():
                entries.append((str(k), v))
        elif isinstance(g, list):
            for i, v in enumerate(g):
                entries.append((str(i), v))

seen = set()
for key, value in entries:
    d, raw = as_dict(value)
    if not d and not raw:
        continue
    st = status_of(d, raw)
    if st and st in TERMINAL:
        continue
    vd = verdict_of(d, raw)
    if vd and vd not in PENDING_VERDICTS:
        continue
    issue = issue_of(key, d, raw)
    sha = sha_of(d, raw)
    if not issue or not sha:
        continue
    if issue in seen:
        continue
    seen.add(issue)
    print("%d %s" % (issue, sha))
PY
}

# The pending slots, read from the state.
pending_slots() {
  local acc="$B/orch-state.sh" raw="" out=""
  if [ -f "$acc" ]; then
    raw="$(bash "$acc" gates 2>/dev/null; bash "$acc" slots 2>/dev/null)"
  fi
  if [ -n "$raw" ]; then
    out="$(state_pending compact "$raw")"
  fi
  if [ -z "$out" ]; then
    # The accessor did not answer (it is not there, or the state is not
    # readable, or it changed its format): the SAME two keys are read
    # directly, so a change in the accessor does not leave the work ungated.
    out="$(state_pending json "$ORCH_DIR/state.json" 2>/dev/null)"
  fi
  printf '%s\n' "$out"
}

if [ $# -ge 2 ]; then
  # pares slot sha [worktree]
  run_one "$1" "$2" "${3:-$WORKTREES_DIR/issue-$1}"
  exit $?
fi

# sin argumentos: los gates pendientes del ESTADO, no los que estan escritos
# en este archivo.
PENDING="$(pending_slots)"
if [ -z "$PENDING" ]; then
  # no hay trabajo: no es un error.
  echo "[$(date +%H:%M:%S)] no hay gates pendientes en el estado"
  exit 0
fi
RC=0
while read -r SLOT SHA; do
  [ -n "${SLOT:-}" ] || continue
  run_one "$SLOT" "$SHA" "$WORKTREES_DIR/issue-$SLOT" || RC=$?
done <<EOF
$PENDING
EOF
exit $RC
