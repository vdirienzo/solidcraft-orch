#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-gc-orch-cap.sh - the cap of the tree of targets of the ORCHESTRATOR.
#
# WHY THIS FILE EXISTS (01-11-2026): the disk collector had a cap for the
# `deps` of the gate (DISK_DEPS_MAX_GB) and NONE for the tree of target
# dirs of the ORCHESTRATOR ($ORCH_TARGET_BASE). The retention of the
# orchestrator ("the slot stays while its pull request is open") had no
# bound of size and no bound of age: six open pull requests retained 73
# GB of target dirs, every new slot costs ~18 GB more (a whole build of
# the workspace) and the disk was at 50% with nothing able to stop it.
#
# The cap (DISK_ORCH_TARGET_MAX_GB, 60 by default) removes the OLDEST
# target dirs until the tree is under the cap, and it NEVER relaxes the
# guards of a live slot: the lock of the orchestrator, a live cargo, an
# issue in flight and a worktree in use are all untouchable. The base of
# the tree is never a candidate: the dirs of the slots go one by one. A
# HOT cache (touched less than DISK_ORCH_TARGET_MAX_AGE_H ago) is kept
# even over the cap: it is the cache of a pull request that is going to
# be re-gated.
#
# THE TESTS ARE HERMETIC: they build their own world inside a temporary
# directory (mktemp -d) and point the collector at it with the
# environment (LOOP_DIR, ORCH_DIR, ORCH_TARGET_BASE). The real tree of
# the orchestrator, the real loop and the real worktrees are NEVER read
# nor written: a test that deleted a real target would be a bug.
#
# WHERE THE CAP IS EXERCISED: in the DAILY pass, because that is the
# pass where the cap is the ONLY thing that touches the tree of the
# orchestrator. (In the directed pass the rules of the age have the
# first word: they remove the old targets of the slots without a pull
# request, and the cap only adds what is left.)
#
# THE SIZES ARE FAKE BUT REAL FOR THE CAP: the cap counts BYTES, and a
# sparse file of 300 MB weighs 300 MB for `du -b` (the apparent size)
# without occupying 300 MB of the disk. The tree of the tests weighs
# 1.5 GB and the cap is 1 GB.
#
# Run: bash ~/.local/share/solidcraft-loop/bin/test-gc-orch-cap.sh
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GC="$LOOP_DIR_REAL/bin/gc-disk.sh"
ORCH_REAL="${ORCH_REAL_DIR:-$HOME/.local/share/solidcraft-orch}"

PASS=0
FAIL=0
ROOT=""
W_HOME=""; W_LOOP=""; W_ORCH=""; W_BASE=""; W_WT=""; W_BIN=""

cleanup() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  ROOT=""
}
trap cleanup EXIT

ok() { PASS=$(( PASS + 1 )); echo "  ok   $1"; }
no() { FAIL=$(( FAIL + 1 )); echo "  FAIL $1"; echo "       <- $2"; }

# check <name> <exit-code> <detail>
check() {
  if [ "$2" -eq 0 ]; then ok "$1"; else no "$1" "${3:-}"; fi
}

# --- the world of the tests -------------------------------------------------
# It is rebuilt for every case: a case that deletes a target must not
# leave the world broken for the next one.
build_world() {
  rm -rf "$ROOT"
  ROOT="$(mktemp -d -t gc-orch-cap-XXXXXX)"
  W_HOME="$ROOT/home"
  W_LOOP="$ROOT/loop"
  W_ORCH="$ROOT/orch"
  W_BASE="$W_ORCH/targets"
  W_WT="$ROOT/wt"
  W_BIN="$ROOT/bin"
  mkdir -p "$W_HOME" "$W_LOOP/logs" "$W_LOOP/gates" "$W_ORCH/bin" "$W_ORCH/locks" \
           "$W_BASE" "$W_WT" "$W_BIN" "$ROOT/quick" "$ROOT/main-target"

  # The helper of the ORCHESTRATOR: the source of truth of the layout of
  # its tree. The real one is used when it is there (it only reads
  # ORCH_TARGET_BASE); a stub answers the same when it is not.
  if [ -f "$ORCH_REAL/bin/slot-target-dir.sh" ]; then
    cp "$ORCH_REAL/bin/slot-target-dir.sh" "$W_ORCH/bin/slot-target-dir.sh"
  else
    cat > "$W_ORCH/bin/slot-target-dir.sh" <<'STUB'
#!/usr/bin/env bash
BASE="${ORCH_TARGET_BASE:-${ORCH_DIR:-/tmp}/targets}"
for d in "$BASE"/slot-*; do
  [ -d "$d" ] || continue
  printf '%s\n' "$d"
done
STUB
  fi

  # The lock of a slot of the orchestrator: it answers --list with the
  # slots that are taken and --status for one slot. The STUB answer is
  # the environment: the test decides which slots are owned.
  cat > "$W_ORCH/bin/slot-lock.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
MODE=""; TARGET=""; ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) MODE=slot; TARGET="$2"; shift 2 ;;
    --status) ACTION=status; shift ;;
    --list) ACTION=list; shift ;;
    *) shift ;;
  esac
done
if [ "$ACTION" = list ]; then
  for n in ${STUB_TAKEN_LOCKS:-}; do
    printf '%s\t2026-11-01T00:00:00Z\tissue-%s\n' "$n" "$n"
  done
  exit 0
fi
[ "$MODE" = slot ] && [ "$ACTION" = status ] || exit 2
case " ${STUB_TAKEN_LOCKS:-} " in
  *" $TARGET "*) exit 1 ;;
esac
exit 0
STUB

  # The state of the orchestrator: it has to be READABLE for the cap to
  # act (without it the collector does not know what is alive) and it
  # says that the issues of slots 1002 and 1003 have an open pull
  # request.
  #
  # The shape of `open_prs` here is a DICT (pr -> entry). The real
  # orchestrator writes a LIST; the collector reads both.
  cat > "$W_ORCH/state.json" <<'JSON'
{"open_prs": {"9001": {"issue": 1002, "state": "open"}, "9002": {"issue": 1003, "state": "open"}}}
JSON

  # A target dir of a slot: a dir with a SPARSE file of 1000 MB (it weighs
  # 1000 MB for `du -b`, the apparent size, and occupies nothing) with
  # the given age. The age of the file is what the collector measures.
  mk_slot() {
    local name="$1" mb="$2" hours="$3" dir="$W_BASE/slot-$1"
    mkdir -p "$dir/ci"
    truncate -s "${mb}M" "$dir/ci/blob" 2>/dev/null \
      || dd if=/dev/zero of="$dir/ci/blob" bs=1048576 count="$mb" >/dev/null 2>&1
    touch -d "-${hours} hours" "$dir/ci/blob"
    touch -d "-${hours} hours" "$dir"
  }

  # The age of the tree decides the order in which the cap looks at the
  # targets (the oldest first). The two GUARDED slots are the OLDEST on
  # purpose: the cap has to walk over them to reach the ones it may
  # reclaim, so the report has to say that they were kept and why.
  #
  # The tree weighs 5000 MB and the cap is 1000 MB: the cap cannot be
  # satisfied by the two reclaimable slots alone, so it walks over ALL of
  # them and the hot one is reached (and kept) too.
  #
  # slot-1004: the oldest, with the LOCK of the orchestrator taken -> never reclaimed
  # slot-1005: old, with a LIVE CARGO writing in it          -> never reclaimed
  # slot-1001: old, WITHOUT a pull request                   -> reclaimable
  # slot-1002: old, WITH an open pull request               -> reclaimable over the cap
  # slot-1003: RECENT (hot cache of an open PR)              -> never reclaimed
  mk_slot 1004 1000 48
  mk_slot 1005 1000 46
  mk_slot 1001 1000 40
  mk_slot 1002 1000 30
  mk_slot 1003 1000 1

  # The `gh` of the tests: it answers an empty list and RECORDS that it
  # was called. The cap does not need it (it reads the local state of
  # the orchestrator), but the daily pass asks for the pull requests.
  cat > "$W_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'called\n' >> "${GH_CALLS:-/dev/null}"
exit 0
STUB
  chmod +x "$W_BIN/gh"
}

# The environment of the collector: it points at the world of the tests
# and at NOTHING of the live machine.
gc_env() {
  export HOME="$W_HOME"
  export PATH="$W_BIN:$PATH"
  export LOOP_DIR="$W_LOOP"
  export ORCH_DIR="$W_ORCH"
  export ORCH_TARGET_BASE="$W_BASE"
  export GATE_QUICK_TARGET_DIR="$ROOT/quick"
  export SOLIDCRAFT_WT_ROOT="$W_WT"
  export CARGO_TARGET_DIR="$ROOT/main-target"
  export GATE_WORKTREE="$ROOT/gate-wt"
  export EVIDENCE_WORKTREE="$ROOT/evidence-wt"
  export REPO="$ROOT/no-repo"
  export DISK_GC_ENABLED=1
  export DISK_GC_INTERVAL_H=0
  export DISK_GC_STALE_TARGET_H=1
  export DISK_ORCH_TARGET_MAX_AGE_H=6
  export DISK_ORCH_TARGET_MAX_GB=1
  export DISK_DEPS_MAX_GB=0
  export STUB_TAKEN_LOCKS=""
  export GH_CALLS="$ROOT/gh-calls.log"
}

# run_gc <extra-args...> -> the report of the collector in $REPORT
REPORT=""
run_gc() {
  REPORT="$(timeout 180 bash "$GC" --force "$@" 2>&1)"
  return 0
}

# alive <dir> -> 0 when the dir is there
alive() { [ -d "$1" ]; }

echo "1. el tope del árbol de targets del orquestador"

# --- (a) UNDER the cap: nothing is touched --------------------------------
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1000
run_gc
check "bajo el tope no se borra nada" \
  "$( alive "$W_BASE/slot-1001" && alive "$W_BASE/slot-1002" \
       && alive "$W_BASE/slot-1003" && alive "$W_BASE/slot-1004" \
       && alive "$W_BASE/slot-1005" && echo 0 || echo 1 )" \
  "un target fue borrado con el árbol por debajo del tope"
check "bajo el tope no se anuncia ninguna borraración" \
  "$( printf '%s' "$REPORT" | grep -q "BORRARÍA" && echo 1 || echo 0 )" \
  "el reporte anunció una borraración con el árbol por debajo del tope"

# --- (b) OVER the cap: the oldest target without a PR goes ----------------
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
run_gc
check "sobre el tope se borra el target más viejo sin PR" \
  "$( alive "$W_BASE/slot-1001" && echo 1 || echo 0 )" \
  "el target más viejo sin PR (slot-1001) sigue ahí"
check "sobre el tope se borra por antigüedad y no al azar" \
  "$( alive "$W_BASE/slot-1002" && echo 1 || echo 0 )" \
  "el segundo más viejo (slot-1002) sigue ahí"
check "el reporte dice qué borró" \
  "$( printf '%s' "$REPORT" | grep -q "slot-1001" && echo 0 || echo 1 )" \
  "el reporte no menciona el target borrado"

# --- (c) a LOCKED target is never reclaimed --------------------------------
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
export STUB_TAKEN_LOCKS="1004"
run_gc
check "un target con lock vivo no se borra" \
  "$( alive "$W_BASE/slot-1004" && echo 0 || echo 1 )" \
  "el GC borró un target cuyo lock del orquestador está tomado"
check "el reporte explica por qué lo conserva" \
  "$( printf '%s' "$REPORT" | grep -q "tiene un lock vivo" && echo 0 || echo 1 )" \
  "el reporte no dice que el lock lo protege"

# --- (d) a LIVE CARGO target is never reclaimed ----------------------------
# A cargo that writes in the target dir: a copy of `sleep` called
# `cargo` is what the collector sees (it reads the NAME of the
# executable and the CARGO_TARGET_DIR of the process).
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
cp /bin/sleep "$W_BIN/cargo" 2>/dev/null
CARGO_TARGET_DIR="$W_BASE/slot-1005" "$W_BIN/cargo" 300 &
CARGO_PID=$!
sleep 1
run_gc
check "un target con un cargo vivo no se borra" \
  "$( alive "$W_BASE/slot-1005" && echo 0 || echo 1 )" \
  "el GC borró un target con un cargo vivo escribiendo ahí"
check "el reporte explica que hay un cargo vivo" \
  "$( printf '%s' "$REPORT" | grep -q "hay un cargo vivo" && echo 0 || echo 1 )" \
  "el reporte no dice que un cargo vivo lo protege"
kill "$CARGO_PID" 2>/dev/null
wait "$CARGO_PID" 2>/dev/null

# --- (e) the BASE of the tree is never a candidate ------------------------
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
run_gc
check "la base del árbol nunca se borra" \
  "$( alive "$W_BASE" && echo 0 || echo 1 )" \
  "el GC borró la base del árbol de targets"
check "la base del árbol no se anuncia como candidata" \
  "$( printf '%s' "$REPORT" | grep -qF "BORRARÍA $W_BASE " && echo 1 || echo 0 )" \
  "el reporte anunció la base del árbol como candidata"

# --- (f) a RECENT target with an open PR is kept --------------------------
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
run_gc
check "un target con PR abierto y reciente se conserva" \
  "$( alive "$W_BASE/slot-1003" && echo 0 || echo 1 )" \
  "el GC borró el target caliente del PR abierto"
check "un target con PR abierto y VIEJO sí se suelta sobre el tope" \
  "$( alive "$W_BASE/slot-1002" && echo 1 || echo 0 )" \
  "el cache frío del PR abierto sigue ahí: el tope no lo suelta"
check "el reporte dice que el PR abierto y viejo se suelta" \
  "$( printf '%s' "$REPORT" | grep -qE "(borrado|BORRARÍA) .*slot-1002.*PR abierto" && echo 0 || echo 1 )" \
  "el reporte no dice que el PR abierto y viejo se suelta"

# --- (f2) the state of the orchestrator as a LIST --------------------------
# The real orchestrator does NOT write a dict: it writes a LIST of
# entries. A collector that only knows the dict sees "no pull request"
# in every slot and reclaims caches that are in use.
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
cat > "$W_ORCH/state.json" <<'JSON'
{"open_prs": [{"issue": 1002, "number": 9001, "state": "draft"}, {"issue": 1003, "number": 9002, "state": "draft"}]}
JSON
run_gc
check "con el estado como lista el PR abierto y viejo sí se suelta" \
  "$( alive "$W_BASE/slot-1002" && echo 1 || echo 0 )" \
  "con el estado como lista el tope no soltó el PR abierto y viejo"
check "con el estado como lista el PR abierto y caliente se conserva" \
  "$( alive "$W_BASE/slot-1003" && echo 0 || echo 1 )" \
  "con el estado como lista el GC borró el target caliente"

# --- (f3) a state that cannot be read: NOTHING is reclaimed ---------------
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
echo "{ this is not json" > "$W_ORCH/state.json"
run_gc
check "con el estado ilegible no se borra nada" \
  "$( alive "$W_BASE/slot-1001" && alive "$W_BASE/slot-1002" && echo 0 || echo 1 )" \
  "el GC borró un target sin poder leer el estado del orquestador"
check "el reporte explica que no se pudo leer el estado" \
  "$( printf '%s' "$REPORT" | grep -q "no se pudo leer el estado del orquestador" && echo 0 || echo 1 )" \
  "el reporte no dice que el estado del orquestador es ilegible"

# --- (g) the rehearsal lists what it would delete, and deletes NOTHING ----
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=1
run_gc --dry-run
check "el dry-run lista lo que borraría" \
  "$( printf '%s' "$REPORT" | grep -q "BORRARÍA" && echo 0 || echo 1 )" \
  "el dry-run no announces nada"
check "el dry-run dice el peso de lo que borraría" \
  "$( printf '%s' "$REPORT" | grep -qE "BORRARÍA .*slot-1001.*[0-9]+ (MB|GB)" && echo 0 || echo 1 )" \
  "el dry-run no dice el tamaño del target"
check "el dry-run no borra nada" \
  "$( alive "$W_BASE/slot-1001" && alive "$W_BASE/slot-1002" && echo 0 || echo 1 )" \
  "el dry-run borró un target"

# --- the cap can be turned off ---------------------------------------------
build_world
gc_env
export DISK_ORCH_TARGET_MAX_GB=0
run_gc
check "con el tope en 0 no se borra nada" \
  "$( alive "$W_BASE/slot-1001" && alive "$W_BASE/slot-1002" && echo 0 || echo 1 )" \
  "un target se borró con el tope desactivado"

# --- the rule is in the CODE ------------------------------------------------
check "el GC conoce la variable del tope" \
  "$( grep -q "DISK_ORCH_TARGET_MAX_GB" "$GC" && echo 0 || echo 1 )" \
  "el GC no menciona DISK_ORCH_TARGET_MAX_GB"
check "el GC documenta el tope del árbol" \
  "$( grep -q "DISK_ORCH_TARGET_MAX_GB=" "$GC" && echo 0 || echo 1 )" \
  "el GC no documenta DISK_ORCH_TARGET_MAX_GB"
check "el GC conoce el límite de edad de la caché caliente" \
  "$( grep -q "DISK_ORCH_TARGET_MAX_AGE_H" "$GC" && echo 0 || echo 1 )" \
  "el GC no menciona DISK_ORCH_TARGET_MAX_AGE_H"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "todas las reglas pasan ($PASS)"
  exit 0
fi
echo "$FAIL regla(s) fallan de $PASS"
exit 1
