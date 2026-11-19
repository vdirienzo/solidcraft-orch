#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-slot-lifecycle.sh - the lifecycle of a slot, end to end, with fakes.
#
# WHAT IT TESTS (the four acts of the loop, on a scratch directory):
#   1. state-set.py writes a key in the state and the artifact is rebuilt.
#   2. prepare-slot.sh takes the lock, creates the worktree and the branch,
#      renders the brief and writes the slot in the state.
#   3. the slot is refused when the claim is not free (the arbiter says no).
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
  cat "${GH_FAKE_LIST:-/dev/null}" 2>/dev/null
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
# Otro autor tiene un PR abierto que menciona el issue.
cat > "$TMP/otros.json" <<'JSON'
[{"number":4242,"title":"otro (#9001)","body":"Fixes #9001","author":{"login":"otro"},"headRefName":"fix-9001","isDraft":true}]
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
# Un RESTO de un turno que ya termino (el Xvfb que el agente levanto, el
# sandbox de hermes) tiene su directorio de trabajo DENTRO del worktree y
# sobrevive al turno: no es trabajo, y un slot con un resto NO esta vivo.
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

printf '\n%d casos, %d fallan\n' "$((PASS + FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
