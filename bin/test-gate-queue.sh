#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-gate-queue.sh - the queue of the gates, and what it does when
# there is nothing to gate.
#
# POR QUE EXISTEN: la cola caia al checkout principal cuando el
# worktree del slot no estaba:
#
#     ( cd "$WORKTREES_DIR/issue-$issue" 2>/dev/null || cd "$SOLIDCRAFT_REPO"
#
# El gate compilaba un arbol que NO contenia el cambio y escribia un
# verdict que decia si. bin/verify-pr.sh lo leia como "el gate de este
# pull request". El gate mismo ahora se niega (exit 5, bin/gate.sh); la
# cola tiene que negarse tambien, o lanza un gate que va a fallar.
#
# Y la cola salia SIEMPRE con 0: un cron verde sobre gates que no
# corrieron. El rc de la cola es "pude lanzarlos"; el veredicto de cada
# gate esta en $LOOP_DIR/gates/<slot>/scope.verdict, que es donde el
# resto del sistema lo lee.
#
# NADA de esto compila Rust: el gate es un stub.
#
# Run:  bash bin/test-gate-queue.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_QUEUE_SH:-$HERE/gate-queue.sh}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-gate-queue.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); [ $# -gt 1 ] && printf '       %s\n' "$2"; }

ORCH="$TMP/orch"
WT="$TMP/wt"
mkdir -p "$ORCH/bin" "$ORCH/gates" "$ORCH/logs" "$WT"
cp "$SRC" "$ORCH/bin/gate-queue.sh"

# El gate es un stub: escribe lo que se le pidio y nada mas.
# ORCH se exporta: el stub corre en un subshell de la cola y lo necesita.
export ORCH
cat > "$ORCH/bin/gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "gate.sh $*" >> "$ORCH/logs/gate-stub.log"
EOF
cat > "$ORCH/bin/build-slot.sh" <<'EOF'
#!/usr/bin/env bash
echo "build-slots: 0 used of 2"
EOF
chmod +x "$ORCH/bin/gate.sh" "$ORCH/bin/build-slot.sh"

run_queue() {
  # GATE_STAGGER=0: the stagger is 90 s in production (so the second gate finds
  # a warm sccache). Here it would just make the suite slow.
  ORCH_DIR="$ORCH" WORKTREES_DIR="$WT" GATE_STAGGER=0 bash "$ORCH/bin/gate-queue.sh" "$@" 2>&1
}

# --- 1. encolar y listar ---------------------------------------------------
echo "== encolar y listar =="
run_queue --enqueue 4242 abc1234 >/dev/null
out="$(run_queue --list)"
if printf '%s' "$out" | grep -q '4242'; then
  ok "el encolado aparece en la lista"
else
  no "el encolado aparece en la lista" "$out"
fi

# --- 2. SIN worktree: la cola NO cae al checkout principal ------------------
echo "== sin worktree, la cola no compila el arbol equivocado =="
: > "$ORCH/logs/gate-stub.log"
out="$(run_queue --run 0)"; rc=$?
if [ ! -s "$ORCH/logs/gate-stub.log" ]; then
  ok "sin worktree NO se lanza ningun gate (no compila el checkout principal)"
else
  no "sin worktree NO se lanza ningun gate (no compila el checkout principal)" \
      "$(cat "$ORCH/logs/gate-stub.log")"
fi
if printf '%s' "$out" | grep -qi 'worktree'; then
  ok "la cola dice que falta el worktree y donde lo espera"
else
  no "la cola dice que falta el worktree y donde lo espera" "$out"
fi
if [ "$rc" -ne 0 ]; then
  ok "la cola sale con rc distinto de cero cuando no pudo gatear (rc=$rc)"
else
  no "la cola sale con rc distinto de cero cuando no pudo gatear (rc=0)"
fi

# --- 3. CON worktree: la cola lanza el gate --------------------------------
echo "== con worktree, la cola lanza el gate =="
: > "$ORCH/logs/gate-stub.log"
mkdir -p "$WT/issue-4242"
run_queue --enqueue 4242 abc1234 >/dev/null
out="$(run_queue --run 0)"; rc=$?
sleep 1
if grep -q '4242' "$ORCH/logs/gate-stub.log" 2>/dev/null; then
  ok "con worktree la cola lanza el gate del slot"
else
  no "con worktree la cola lanza el gate del slot" "rc=$rc out=[$out] log=[$(cat "$ORCH/logs/gate-stub.log" 2>&1)]"
fi

# --- 4. la cola con un slot que NO tiene worktree no se lo come en silencio --
echo "== el slot sin worktree sale de la cola, no se reintenta para siempre =="
run_queue --enqueue 7777 def5678 >/dev/null
run_queue --run 0 >/dev/null 2>&1
out="$(run_queue --list)"
if printf '%s' "$out" | grep -q '7777'; then
  no "el slot sin worktree sale de la cola (no se reintenta para siempre)" "$out"
else
  ok "el slot sin worktree sale de la cola (no se reintenta para siempre)"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
