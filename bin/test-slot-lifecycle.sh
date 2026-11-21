#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-slot-lifecycle.sh - the lifecycle of a slot, end to end, with fakes.
#
# WHAT IT TESTS (the four acts of the loop, on a scratch directory):
#   1. state-set.py writes a key in the state and the artifact is rebuilt.
#   2. prepare-slot.sh takes the lock, creates the worktree and the branch,
#      renders the brief and writes the slot in the state.
#   3. the slot is refused when the claim is not free (the arbiter says no),
#      and our own open PR on the slot's branch is not a competitor.
#   4. close-slot.sh releases the lock, removes the worktree and the target
#      dir, and writes the PR in the state.
#   5. slot-busy.sh tells a live slot from a dead one (the wave never
#      touches a slot whose agent is working in it).
#   6. slot-prs.py matches the pull request of a slot: ours by the branch,
#      ours by the issue, and somebody else's when the claim was lost.
#
# IT NEVER TOUCHES GITHUB: the gh of the PATH is a stub, and the claim arbiter
# is the real one, which asks that stub (README rule 4: a stub of a tool never
# lives in a PATH directory of its own; here the PATH is the test's).
#
# Run: bash bin/test-slot-lifecycle.sh
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FALLA- %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-slot-lifecycle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- el gh de mentira -------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Un gh que no sabe nada: lo que responda es GH_FAKE_LIST.
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  echo "vdirienzo"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  # Aplica el filtro --jq como el gh de verdad: sin el, claim-verify.sh recibe
  # el JSON crudo, junta todos sus digitos en un numero ("12345900190019001")
  # y el PR propio "pierde" el claim contra si mismo (2026-11-21).
  jq_filter="" prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jq_filter="$a"
    prev="$a"
  done
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter" < "${GH_FAKE_LIST:-/dev/null}" 2>/dev/null
  else
    cat "${GH_FAKE_LIST:-/dev/null}" 2>/dev/null
  fi
  exit 0
fi
echo "[]"
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- un upstream de mentira, con un main -------------------------------------
UP="$TMP/upstream"
mkdir -p "$UP"
git -C "$UP" init -q -b main
git -C "$UP" config user.email "test@example.invalid"
git -C "$UP" config user.name "test"
echo "hola" > "$UP/README.md"
git -C "$UP" add -A
git -C "$UP" commit -qm "main"
BARE="$TMP/origin.git"
git clone -q --bare "$UP" "$BARE"
git -C "$UP" remote add origin "$BARE"
git -C "$UP" push -q origin main

# --- el ORCH_DIR de prueba ---------------------------------------------------
ORCH="$TMP/orch"
# EL GUARDIA (2026-11-21): el estado de la suite nunca cae en el orquestador vivo.
source "$REPO_ROOT/bin/test-guard.sh"
test_guard_orch_dir "$ORCH"
mkdir -p "$ORCH/prompts" "$ORCH/logs"
cp "$REPO_ROOT/prompts/agent-brief.md" "$ORCH/prompts/"
cp "$REPO_ROOT/bin/merge-state.sh" "$ORCH/bin/merge-state.sh" 2>/dev/null || { mkdir -p "$ORCH/bin"; cp "$REPO_ROOT/bin/merge-state.sh" "$ORCH/bin/"; }
export ORCH_DIR="$ORCH"
export SOLIDCRAFT_REPO="$UP"
export WORKTREES_DIR="$TMP/wt"
export UPSTREAM_REPO="vdirienzo/solidcraft"
bash "$REPO_ROOT/bin/merge-state.sh" --bootstrap >/dev/null 2>&1

# --- 1. state-set.py ---------------------------------------------------------
python3 "$REPO_ROOT/bin/state-set.py" slots "9001" '{"status":"prepared","phase":"prueba"}' >/dev/null 2>&1
if python3 - "$ORCH/state.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
slot = (data.get("slots") or {}).get("9001")
raise SystemExit(0 if slot and slot.get("status") == "prepared" else 1)
PY
then
  ok "state-set escribe el slot y el artefacto se reconstruye"
else
  no "state-set escribe el slot y el artefacto se reconstruye"
fi
python3 "$REPO_ROOT/bin/state-set.py" --delete slots "9001" >/dev/null 2>&1

# --- 2. prepare-slot.sh ------------------------------------------------------
BRIEF="$(bash "$REPO_ROOT/bin/prepare-slot.sh" 9001 "test" 2>&1)"
RC=$?
if [ "$RC" = "0" ] && [ -f "$BRIEF" ]; then
  ok "prepare-slot deja el brief listo (rc=0)"
else
  no "prepare-slot deja el brief listo" "rc=$RC: $BRIEF"
fi
if [ -f "$WORKTREES_DIR/issue-9001/prompts/x" ] || [ -d "$WORKTREES_DIR/issue-9001" ]; then
  ok "prepare-slot crea el worktree del slot"
else
  no "prepare-slot crea el worktree del slot" "$WORKTREES_DIR"
fi
if grep -q "9001" "$BRIEF" 2>/dev/null && grep -q "issue-9001" "$BRIEF" 2>/dev/null; then
  ok "el brief tiene el issue y el worktree del slot"
else
  no "el brief tiene el issue y el worktree del slot" "$BRIEF"
fi
if bash "$REPO_ROOT/bin/slot-lock.sh" --slot 9001 --status >/dev/null 2>&1; then
  no "el lock del slot queda tomado mientras el slot vive"
else
  ok "el lock del slot queda tomado mientras el slot vive"
fi
if python3 - "$ORCH/state.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
slot = (data.get("slots") or {}).get("9001")
raise SystemExit(0 if slot and slot.get("status") == "prepared" else 1)
PY
then
  ok "el slot queda anotado en el estado (sobrevive a la sesion)"
else
  no "el slot queda anotado en el estado (sobrevive a la sesion)"
fi

# --- 3. un claim que no esta libre ------------------------------------------
# Otro autor tiene PRs abiertos que mencionan los issues (#9001 para el
# arbitro, #9002 para prepare-slot: cada caso mira SU issue).
cat > "$TMP/otros.json" <<'JSON'
[{"number":4242,"title":"otro (#9001)","body":"Fixes #9001","author":{"login":"otro"},"headRefName":"fix-9001","isDraft":true},
 {"number":4243,"title":"otro (#9002)","body":"Fixes #9002","author":{"login":"otro"},"headRefName":"fix-9002","isDraft":true}]
JSON
export GH_FAKE_LIST="$TMP/otros.json"
CLAIM="$(cd "$REPO_ROOT" && bash bin/claim-verify.sh 9001 2>&1)"
RC=$?
if [ "$RC" = "1" ]; then
  ok "el arbitro del claim dice que el issue no esta libre (rc=1)"
else
  no "el arbitro del claim dice que el issue no esta libre" "rc=$RC: $CLAIM"
fi
OUT="$(bash "$REPO_ROOT/bin/prepare-slot.sh" 9002 "test" 2>&1)"
if [ "$?" = "3" ]; then
  ok "prepare-slot se niega cuando el claim no esta libre (rc=3)"
else
  no "prepare-slot se niega cuando el claim no esta libre" "$OUT"
fi

# --- 3b. NUESTRO PROPIO PR NO ES UN COMPETIDOR (2026-11-21) ----------------
# El slot 19690 tenia nuestro PR #20081 abierto (rama fix-19690) y el arbitro,
# llamado SIN nuestro numero de PR, lo tomaba por un competidor: el slot no se
# podia volver a preparar nunca. prepare-slot busca nuestro PR de la rama del
# slot y se lo pasa al arbitro de verdad (--our-pr).
cat > "$TMP/propio.json" <<'JSON'
[{"number":20081,"title":"nuestro (#9007)","body":"Fixes #9007","author":{"login":"vdirienzo"},"headRefName":"fix-9007","isDraft":true}]
JSON
export GH_FAKE_LIST="$TMP/propio.json"
OUT="$(bash "$REPO_ROOT/bin/prepare-slot.sh" 9007 "test" 2>&1)"
RC=$?
if [ "$RC" = "0" ]; then
  ok "prepare-slot prepara un slot que ya tiene nuestro PR abierto (rc=0)"
else
  no "prepare-slot prepara un slot que ya tiene nuestro PR abierto" "rc=$RC: $OUT"
fi
if python3 - "$ORCH/state.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
slot = (data.get("slots") or {}).get("9007") or {}
raise SystemExit(0 if slot.get("pr") == 20081 else 1)
PY
then
  ok "el PR nuestro queda en el estado del slot"
else
  no "el PR nuestro queda en el estado del slot"
fi
# Un PR de OTRO autor en la rama fix-9008 no es el nuestro: el claim sigue
# perdido (rc=3) y el motivo del arbitro sale en el stderr.
cat > "$TMP/ajeno.json" <<'JSON'
[{"number":4250,"title":"otro (#9008)","body":"Fixes #9008","author":{"login":"otro"},"headRefName":"fix-9008","isDraft":true}]
JSON
export GH_FAKE_LIST="$TMP/ajeno.json"
OUT="$(bash "$REPO_ROOT/bin/prepare-slot.sh" 9008 "test" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" = "3" ] && printf '%s' "$OUT" | grep -q "claim-verify rc=1"; then
  ok "el PR de otro en la rama del slot no cuenta como nuestro (rc=3, con el motivo)"
else
  no "el PR de otro en la rama del slot no cuenta como nuestro" "rc=$RC: $OUT"
fi
bash "$REPO_ROOT/bin/slot-lock.sh" --slot 9007 --release >/dev/null 2>&1
git -C "$UP" worktree remove --force "$WORKTREES_DIR/issue-9007" >/dev/null 2>&1
python3 "$REPO_ROOT/bin/state-set.py" --delete slots "9007" >/dev/null 2>&1

# --- 4. close-slot.sh --------------------------------------------------------
cat > "$TMP/nuestro.json" <<'JSON'
[{"number":12345,"title":"nuestro (#9001)","body":"Fixes #9001","author":{"login":"vdirienzo"},"headRefName":"fix-9001","isDraft":true}]
JSON
export GH_FAKE_LIST="$TMP/nuestro.json"
bash "$REPO_ROOT/bin/close-slot.sh" 9001 12345 >/dev/null 2>&1
RC=$?
if [ "$RC" = "0" ]; then
  ok "close-slot cierra el slot (rc=0)"
else
  no "close-slot cierra el slot" "rc=$RC"
fi
if [ ! -d "$WORKTREES_DIR/issue-9001" ]; then
  ok "close-slot borra el worktree del slot"
else
  no "close-slot borra el worktree del slot"
fi
if bash "$REPO_ROOT/bin/slot-lock.sh" --slot 9001 --status >/dev/null 2>&1; then
  ok "close-slot libera el lock del slot"
else
  no "close-slot libera el lock del slot"
fi
if python3 - "$ORCH/state.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
raise SystemExit(0 if "9001" not in (data.get("slots") or {}) else 1)
PY
then
  ok "el slot desaparece del estado"
else
  no "el slot desaparece del estado"
fi
# LA LIMPIEZA COMPLETA (2026-11-21): cuando el PR ya esta en GitHub, lo que
# ya no se usa se va: el target (5,6 GB), el worktree (700 MB) y el brief del
# slot. La evidencia se queda (logs y veredicto del gate).
if [ ! -d "$ORCH/targets/slot-9001" ]; then
  ok "close-slot borra el target dir del slot"
else
  no "close-slot borra el target dir del slot" "$ORCH/targets/slot-9001 sigue"
fi
if [ ! -f "$ORCH/prompts/agent-9001.md" ]; then
  ok "close-slot borra el brief del slot"
else
  no "close-slot borra el brief del slot" "$ORCH/prompts/agent-9001.md sigue"
fi
if [ -f "$ORCH/logs/9001-verify.log" ]; then
  ok "close-slot deja la evidencia (el log de la verificacion)"
else
  no "close-slot deja la evidencia (el log de la verificacion)" "$ORCH/logs/9001-verify.log no esta"
fi

# --- 5. slot-busy.sh: un slot vivo no se toca -------------------------------
# Un worktree sin nadie dentro: el slot esta libre.
mkdir -p "$TMP/libre"
if bash "$REPO_ROOT/bin/slot-busy.sh" "$TMP/libre" "" >/dev/null 2>&1; then
  no "slot-busy dice LIBRE un worktree sin nadie dentro"
else
  ok "slot-busy dice LIBRE un worktree sin nadie dentro"
fi
# Un worktree con un proceso dentro: el slot esta vivo.
mkdir -p "$TMP/ocupado"
( cd "$TMP/ocupado" && exec sleep 120 ) &
BUSY_PID=$!
sleep 1
if bash "$REPO_ROOT/bin/slot-busy.sh" "$TMP/ocupado" "" >/dev/null 2>&1; then
  ok "slot-busy dice VIVO un worktree con un proceso dentro"
else
  no "slot-busy dice VIVO un worktree con un proceso dentro"
fi
kill "$BUSY_PID" 2>/dev/null
wait "$BUSY_PID" 2>/dev/null
# Un RESTO de un turno que ya termino (el Xvfb que el agente levanto) tiene
# su directorio de trabajo DENTRO del worktree y sobrevive al turno: no es
# trabajo, y un slot con un resto NO esta vivo.
mkdir -p "$TMP/restos"
( cd "$TMP/restos" && exec -a "Xvfb :99 -screen 0 1400x800x24" sleep 120 ) &
RESTO_PID=$!
sleep 1
if bash "$REPO_ROOT/bin/slot-busy.sh" "$TMP/restos" "" >/dev/null 2>&1; then
  no "slot-busy dice LIBRE un worktree con solo restos de un turno terminado"
else
  ok "slot-busy dice LIBRE un worktree con solo restos de un turno terminado"
fi
kill "$RESTO_PID" 2>/dev/null
wait "$RESTO_PID" 2>/dev/null
# Un proceso que SOLO MENCIONA el worktree (un ls, un grep) NO esta
# trabajando en el: la primera version de slot-busy.sh lo contaba y un slot
# vivo nunca se cerraba (7 GB que nadie libera).
mkdir -p "$TMP/mentado"
( sleep 120 ) >/dev/null 2>&1 &
MENT_PID=$!
# El comando del proceso menciona el path, pero no trabaja ahi.
( exec -a "ls -d $TMP/mentado" sleep 120 ) &
MENT_PID=$!
sleep 1
if bash "$REPO_ROOT/bin/slot-busy.sh" "$TMP/mentado" "" >/dev/null 2>&1; then
  no "slot-busy dice LIBRE cuando un proceso solo menciona el worktree"
else
  ok "slot-busy dice LIBRE cuando un proceso solo menciona el worktree"
fi
kill "$MENT_PID" 2>/dev/null
wait "$MENT_PID" 2>/dev/null

# --- 6. slot-prs.py: el PR de cada slot ------------------------------------
cat > "$TMP/slots.json" <<'JSON'
[{"issue":9001,"branch":"fix-9001"},{"issue":9002,"branch":"fix-9002"},{"issue":9003,"branch":"fix-9003"}]
JSON
cat > "$TMP/prs.json" <<'JSON'
[{"number":111,"title":"nuestro por rama","body":"otra cosa","author":{"login":"vdirienzo"},"headRefName":"fix-9001"},
 {"number":222,"title":"nuestro por issue","body":"Fixes #9002","author":{"login":"vdirienzo"},"headRefName":"otra-rama"},
 {"number":333,"title":"de otro","body":"Fixes #9003","author":{"login":"otro"},"headRefName":"fix-9003"}]
JSON
MATCH="$(python3 "$REPO_ROOT/bin/slot-prs.py" "$TMP/slots.json" "$TMP/prs.json" vdirienzo)"
if printf '%s\n' "$MATCH" | grep -q "^9001	111	fix-9001	ours$"; then
  ok "slot-prs encuentra nuestro PR por la rama"
else
  no "slot-prs encuentra nuestro PR por la rama" "$MATCH"
fi
if printf '%s\n' "$MATCH" | grep -q "^9002	222	otra-rama	ours$"; then
  ok "slot-prs encuentra nuestro PR por el issue"
else
  no "slot-prs encuentra nuestro PR por el issue" "$MATCH"
fi
if printf '%s\n' "$MATCH" | grep -q "^9003	333	fix-9003	other$"; then
  ok "slot-prs dice que el PR es de otro (el claim se perdio)"
else
  no "slot-prs dice que el PR es de otro (el claim se perdio)" "$MATCH"
fi

# --- 7. state-set --merge no borra lo que ya estaba -------------------------
python3 "$REPO_ROOT/bin/state-set.py" slots "9004" '{"branch":"fix-9004","worktree":"/tmp/wt-9004"}' >/dev/null 2>&1
python3 "$REPO_ROOT/bin/state-set.py" --merge slots "9004" '{"status":"running"}' >/dev/null 2>&1
if python3 - "$ORCH/state.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
slot = (data.get("slots") or {}).get("9004") or {}
raise SystemExit(0 if slot.get("status") == "running" and slot.get("branch") == "fix-9004" else 1)
PY
then
  ok "state-set --merge cambia una clave y deja las otras"
else
  no "state-set --merge cambia una clave y deja las otras"
fi
python3 "$REPO_ROOT/bin/state-set.py" --delete slots "9004" >/dev/null 2>&1

# --- 8. close-slot borra un worktree que no es del repo ----------------------
# Un agente que reconstruyo su worktree (un clon suelto) deja un directorio
# que "git worktree remove" no conoce: se quedan 7 GB.
mkdir -p "$WORKTREES_DIR/issue-9005"
echo "trabajo" > "$WORKTREES_DIR/issue-9005/apuntes.txt"
python3 "$REPO_ROOT/bin/state-set.py" slots "9005" "{\"issue\": 9005, \"status\": \"running\", \"worktree\": \"$WORKTREES_DIR/issue-9005\"}" >/dev/null 2>&1
cat > "$TMP/pr9005.json" <<JSON
[{"number":90051,"title":"nuestro (#9005)","body":"Fixes #9005","author":{"login":"vdirienzo"},"headRefName":"fix-9005","isDraft":true}]
JSON
export GH_FAKE_LIST="$TMP/pr9005.json"
bash "$REPO_ROOT/bin/close-slot.sh" 9005 90051 >/dev/null 2>&1
if [ ! -d "$WORKTREES_DIR/issue-9005" ]; then
  ok "close-slot borra un worktree que no es un worktree del repo"
else
  no "close-slot borra un worktree que no es un worktree del repo" "$WORKTREES_DIR/issue-9005 sigue"
fi

# --- 9. close-slot NO cierra un slot con un gate corriendo -------------------
# El gate compila en el worktree y en el target del slot. Si la wave cierra el
# slot mientras el gate corre, le borra el worktree DEBAJO y el gate se muere
# con "Could not locate working directory": el veredicto sale ROJO-SCOPE y un
# PR sano parece roto (le paso al PR #20017, del issue #19523, el 20-11).
mkdir -p "$WORKTREES_DIR/issue-9006"
echo "trabajo" > "$WORKTREES_DIR/issue-9006/apuntes.txt"
python3 "$REPO_ROOT/bin/state-set.py" slots "9006" "{\"issue\": 9006, \"status\": \"running\", \"worktree\": \"$WORKTREES_DIR/issue-9006\"}" >/dev/null 2>&1
cat > "$TMP/pr9006.json" <<JSON
[{"number":90061,"title":"nuestro (#9006)","body":"Fixes #9006","author":{"login":"vdirienzo"},"headRefName":"fix-9006","isDraft":true}]
JSON
export GH_FAKE_LIST="$TMP/pr9006.json"
# Un gate "corriendo" para ese slot: un proceso cuyo argv es el del gate.
bash -c 'exec -a "bash /tmp/gate-quick.sh --slot 9006" sleep 60' &
GATE_FAKE=$!
sleep 1
bash "$REPO_ROOT/bin/close-slot.sh" 9006 90061 >"$TMP/close9006.log" 2>&1
OUT9="$(cat "$TMP/close9006.log")"
if [ -d "$WORKTREES_DIR/issue-9006" ]; then
  ok "close-slot NO borra el worktree de un slot con un gate corriendo"
else
  no "close-slot NO borra el worktree de un slot con un gate corriendo" "$WORKTREES_DIR/issue-9006 no sigue"
fi
# El lock del slot NO se suelta con un gate corriendo: el slot sigue vivo y
# ningun otro agente puede tomarlo. "--status" sale 0 cuando el lock ESTA
# libre (esa es la convencion del repo), asi que libre es rc=0.
bash "$REPO_ROOT/bin/slot-lock.sh" --slot 9006 --take --owner test >/dev/null 2>&1
bash "$REPO_ROOT/bin/close-slot.sh" 9006 90061 >"$TMP/close9006b.log" 2>&1
if bash "$REPO_ROOT/bin/slot-lock.sh" --slot 9006 --status >/dev/null 2>&1; then
  no "el lock de un slot con un gate corriendo NO se suelta" "el lock quedo libre: $(cat "$TMP/close9006b.log")"
else
  ok "el lock de un slot con un gate corriendo NO se suelta"
fi
bash "$REPO_ROOT/bin/slot-lock.sh" --slot 9006 --release >/dev/null 2>&1
kill "$GATE_FAKE" >/dev/null 2>&1
wait "$GATE_FAKE" >/dev/null 2>&1
# Un gate EN COLA tambien protege al slot: todavia no empezo, pero va a
# empezar y necesita el worktree y el target del slot.
mkdir -p "$ORCH/gates"
printf '9006 abcdef1234\n' > "$ORCH/gates/queue.txt"
bash "$REPO_ROOT/bin/close-slot.sh" 9006 90061 >/dev/null 2>&1
if [ -d "$WORKTREES_DIR/issue-9006" ]; then
  ok "close-slot NO borra el worktree de un slot con un gate EN COLA"
else
  no "close-slot NO borra el worktree de un slot con un gate EN COLA" "$WORKTREES_DIR/issue-9006 no sigue"
fi
rm -f "$ORCH/gates/queue.txt"
# Sin gate corriendo ni en cola, el worktree se borra.
bash "$REPO_ROOT/bin/close-slot.sh" 9006 90061 >/dev/null 2>&1
if [ ! -d "$WORKTREES_DIR/issue-9006" ]; then
  ok "sin gate corriendo, close-slot borra el worktree y cierra el slot"
else
  no "sin gate corriendo, close-slot borra el worktree y cierra el slot" "$WORKTREES_DIR/issue-9006 sigue"
fi

printf '\n%d casos, %d fallan\n' "$((PASS + FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
