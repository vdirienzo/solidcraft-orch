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
# The paths of the machine, with a default (the portability check asks for
# it, and it is right: a script that uses one without defining it runs
# with an EMPTY path on the other PC).
LOOP_DIR="${LOOP_DIR:-$ORCH/loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-$ORCH/checkout-principal}"
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
  ORCH_DIR="$ORCH" \
  LOOP_DIR="${LOOP_DIR:-$ORCH/loop}" \
  SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-$ORCH/checkout-principal}" \
  WORKTREES_DIR="$WT" \
  GATE_STAGGER=0 \
    bash "$ORCH/bin/gate-queue.sh" "$@" 2>&1
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

# --- 5. el lock de un runner MUERTO no bloquea -----------------------------
# POR QUE: el lock era un mkdir y decidia "lock viejo" con pgrep -f
# gate-queue.sh, que siempre encontraba el "sh -c" del cron. El runner que
# murio en el reinicio del 2026-11-21 dejo gates/queue.lock y la cola quedo
# parada un dia entero. Ahora es un flock: el kernel lo suelta al morir.
echo "== el lock de un runner muerto no bloquea =="
: > "$ORCH/logs/gate-stub.log"
: > "$ORCH/gates/queue.txt"
mkdir -p "$ORCH/gates/queue.lock"                 # lo que deja el esquema viejo
touch -d '2026-11-20 17:50' "$ORCH/gates/queue.lock"
# un runner con flock que murio de verdad: el archivo queda, el lock no
# (las llaves se tragan el aviso "Killed" del shell)
{ ( exec 9>>"$ORCH/gates/queue.flock"; flock -n 9; kill -9 $BASHPID ); } 2>/dev/null
run_queue --enqueue 4242 abc1234 >/dev/null
out="$(run_queue --run 0)"; rc=$?
sleep 1
if grep -q '4242' "$ORCH/logs/gate-stub.log" 2>/dev/null; then
  ok "con el lock de un runner muerto la cola igual lanza el gate"
else
  no "con el lock de un runner muerto la cola igual lanza el gate" "rc=$rc out=[$out]"
fi
if [ ! -d "$ORCH/gates/queue.lock" ]; then
  ok "el directorio queue.lock del esquema viejo se borra"
else
  no "el directorio queue.lock del esquema viejo se borra" "$out"
fi

# --- 6. un runner VIVO si bloquea al segundo ---------------------------------
echo "== un runner vivo bloquea al segundo =="
: > "$ORCH/logs/gate-stub.log"
# exec sleep: el pid de $! ES el que tiene el lock. Con "flock archivo sleep
# 30 &" el kill mataba a flock y el sleep huerfano seguia con el lock.
( exec 9>>"$ORCH/gates/queue.flock"; flock -n 9; exec sleep 30 ) &
holder=$!
sleep 0.5
run_queue --enqueue 4242 abc1234 >/dev/null
out="$(run_queue --run 0)"; rc=$?
if printf '%s' "$out" | grep -q 'otro runner esta trabajando'; then
  ok "con otro runner vivo la cola dice 'otro runner esta trabajando'"
else
  no "con otro runner vivo la cola dice 'otro runner esta trabajando'" "$out"
fi
sleep 1
if [ ! -s "$ORCH/logs/gate-stub.log" ] && grep -q '^4242 ' "$ORCH/gates/queue.txt"; then
  ok "el runner rechazado no lanza nada y deja la cola intacta"
else
  no "el runner rechazado no lanza nada y deja la cola intacta" \
      "stub=[$(cat "$ORCH/logs/gate-stub.log")] cola=[$(cat "$ORCH/gates/queue.txt")]"
fi
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
: > "$ORCH/gates/queue.txt"

# --- 7. el gate en segundo plano NO se queda con el lock ---------------------
# El lock cubre al runner, no a los gates (como el mkdir, que se borraba al
# salir el runner): si el gate heredara el descriptor, la cola quedaria
# cerrada mientras compila.
echo "== el gate en segundo plano no retiene el lock =="
cat > "$ORCH/bin/gate.sh" <<'EOS'
#!/usr/bin/env bash
echo "gate.sh $*" >> "$ORCH/logs/gate-stub.log"
sleep 5
EOS
run_queue --enqueue 4242 abc1234 >/dev/null
run_queue --run 0 >/dev/null
if flock -n "$ORCH/gates/queue.flock" true; then
  ok "con el gate todavia corriendo, el lock esta libre al salir el runner"
else
  no "con el gate todavia corriendo, el lock esta libre al salir el runner"
fi
cat > "$ORCH/bin/gate.sh" <<'EOS'
#!/usr/bin/env bash
echo "gate.sh $*" >> "$ORCH/logs/gate-stub.log"
EOS
sleep 5

# --- 8. reencolar con OTRO sha reemplaza; con el mismo, no hace nada ---------
# POR QUE: la cola deduplicaba por slot y descartaba el sha nuevo: gateaba
# el commit viejo.
echo "== reencolar con otro sha reemplaza =="
: > "$ORCH/gates/queue.txt"
run_queue --enqueue 1111 aaa0001 >/dev/null
run_queue --enqueue 4242 abc1234 >/dev/null
run_queue --enqueue 2222 bbb0002 >/dev/null
out="$(run_queue --enqueue 4242 fff9999)"
if [ "$(sed -n 2p "$ORCH/gates/queue.txt")" = "4242 fff9999" ] \
   && [ "$(grep -c '^4242 ' "$ORCH/gates/queue.txt")" -eq 1 ] \
   && [ "$(wc -l < "$ORCH/gates/queue.txt")" -eq 3 ]; then
  ok "el sha nuevo reemplaza al viejo en su lugar de la cola"
else
  no "el sha nuevo reemplaza al viejo en su lugar de la cola" "$(cat "$ORCH/gates/queue.txt")"
fi
if printf '%s' "$out" | grep -q 'reemplazado' && printf '%s' "$out" | grep -q 'abc1234'; then
  ok "la salida dice que reemplazo y cual era el sha viejo"
else
  no "la salida dice que reemplazo y cual era el sha viejo" "$out"
fi
before="$(cat "$ORCH/gates/queue.txt")"
out="$(run_queue --enqueue 4242 fff9999)"
if [ "$(cat "$ORCH/gates/queue.txt")" = "$before" ] && printf '%s' "$out" | grep -q 'ya esta en la cola'; then
  ok "el mismo slot con el mismo sha no cambia la cola"
else
  no "el mismo slot con el mismo sha no cambia la cola" "out=[$out] cola=[$(cat "$ORCH/gates/queue.txt")]"
fi
: > "$ORCH/gates/queue.txt"

# --- 9. el log del slot se agrega, no se pisa --------------------------------
echo "== el log del slot se agrega con un separador fechado =="
rm -f "$ORCH/logs/gate-queue-4242.log"
run_queue --enqueue 4242 sha00001 >/dev/null; run_queue --run 0 >/dev/null; sleep 1
run_queue --enqueue 4242 sha00002 >/dev/null; run_queue --run 0 >/dev/null; sleep 1
log="$ORCH/logs/gate-queue-4242.log"
if [ "$(grep -c '^===== .* gate-queue: gate del slot 4242' "$log" 2>/dev/null)" -eq 2 ] \
   && grep -q 'sha00001' "$log" && grep -q 'sha00002' "$log"; then
  ok "las dos corridas quedan en el log, cada una con su separador"
else
  no "las dos corridas quedan en el log, cada una con su separador" "$(cat "$log" 2>&1)"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
