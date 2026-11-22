#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-slot-resume.sh - the tests of the RESUME of a slot.
#
# WHY THE TESTS EXIST: a slot is resumed when its agent died with the work
# half done. Two things have to be true for the next agent to be useful: the
# worktree has to start from the head of the BRANCH (the head of the pull
# request, which lives in the fork), and the brief that says what to do (for
# a repair: the tests that fail and the log of the gate) has to survive.
#
# WHAT BROKE (2026-11-20): prepare-slot.sh only fetched `origin`, so a branch
# that was ONLY in the fork was created from origin/main, and the agent of the
# repair of the PR #20017 worked on b292d76a9 (the base that was not) instead
# of 471445c5e (the head of the PR): it could not even see the failures it
# had to fix. And the brief was rewritten from the template, losing the
# hand written repair brief.
#
# WHAT CHANGED (2026-11-21): the brief that was already there won over the
# template, and the stale briefs kept telling the agent to `rm -rf` its target
# and `git worktree remove --force` its worktree. The brief is now ALWAYS the
# template, and the hand written part lives in prompts/repair-<N>.md, appended
# under "## Notes for this slot". And our own open PR (the head branch fix-N)
# goes to the arbiter as --our-pr: without it the arbiter took our PR #20081
# for a competitor and slot 19690 could never be prepared again.
#
# WHAT IS TESTED:
#   1. the worktree of a slot whose branch is only in the fork starts at the
#      head of the fork.
#   2. a stale brief is replaced by the template; the repair note is appended
#      with its placeholders rendered, {{PR}} too.
#   3. our own open PR is passed to the arbiter as --our-pr and written in
#      the state of the slot.
#   4. the wave: a prepare that fails is an attempt (no endless loop), the
#      issues already tried go to the selector as --exclude, a slot that
#      already has a worktree is not offered again, and the reason of the
#      failure is in the output of the wave.
#   5. the wave: a saved slot that fails to resume counts its failures in the
#      state and stops being retried after WAVE_MAX_RESUME_FAILS.
#
# EXIT CODES:
#   0  every test passed
#   1  at least one failed
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FALLA- %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-slot-resume.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- el gh de mentira -------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "user" ]; then echo "vdirienzo"; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then echo "un issue de prueba"; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ -n "${GH_FAKE_LIST:-}" ]; then
  # Aplica el --jq como el gh de verdad, sobre la lista de PRs de la prueba.
  jq_filter="" prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jq_filter="$a"
    prev="$a"
  done
  if [ -n "$jq_filter" ]; then jq -r "$jq_filter" < "$GH_FAKE_LIST" 2>/dev/null; else cat "$GH_FAKE_LIST"; fi
  exit 0
fi
echo "[]"
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- el upstream y el fork --------------------------------------------------
UP="$TMP/repo"
mkdir -p "$UP"
git -C "$UP" init -q -b main
git -C "$UP" config user.email "test@example.invalid"
git -C "$UP" config user.name "test"
echo "hola" > "$UP/README.md"
git -C "$UP" add -A
git -C "$UP" commit -qm "main"
ORIGIN_BARE="$TMP/origin.git"
git clone -q --bare "$UP" "$ORIGIN_BARE"

# El fork tiene una rama que el upstream no tiene: el trabajo del slot.
FORK_BARE="$TMP/fork.git"
git clone -q --bare "$UP" "$FORK_BARE"
git -C "$UP" remote add origin "$ORIGIN_BARE"
git -C "$UP" remote add fork "$FORK_BARE"
git -C "$UP" checkout -q -b fix-9002
echo "el trabajo del slot" > "$UP/trabajo.txt"
git -C "$UP" add -A
git -C "$UP" commit -qm "el trabajo del slot"
FORK_SHA="$(git -C "$UP" rev-parse HEAD)"
git -C "$UP" push -q fork fix-9002
git -C "$UP" checkout -q main
git -C "$UP" branch -q -D fix-9002

# --- el ORCH_DIR de prueba --------------------------------------------------
ORCH="$TMP/orch"
# EL GUARDIA (2026-11-21): el estado de la suite nunca cae en el orquestador vivo.
source "$REPO_ROOT/bin/test-guard.sh"
test_guard_orch_dir "$ORCH"
mkdir -p "$ORCH/prompts" "$ORCH/logs" "$ORCH/bin"
cp "$REPO_ROOT/prompts/agent-brief.md" "$ORCH/prompts/"
cp "$REPO_ROOT/bin/merge-state.sh" "$ORCH/bin/" 2>/dev/null
# El arbitro del claim dice que el issue esta libre, y anota con que lo
# llamaron (el --our-pr).
cat > "$ORCH/bin/claim-verify.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TMP/claim-args.txt"
exit 0
STUB
chmod +x "$ORCH/bin/claim-verify.sh"
cp "$REPO_ROOT/bin/prepare-slot.sh" "$ORCH/bin/"
cp "$REPO_ROOT/bin/slot-lock.sh" "$ORCH/bin/" 2>/dev/null
cp "$REPO_ROOT/bin/slot-target-dir.sh" "$ORCH/bin/" 2>/dev/null
cp "$REPO_ROOT/bin/state-set.py" "$ORCH/bin/" 2>/dev/null
export ORCH_DIR="$ORCH"
export SOLIDCRAFT_REPO="$UP"
export WORKTREES_DIR="$TMP/wt"
export UPSTREAM_REPO="vdirienzo/solidcraft"
export PATH="$TMP/bin:$PATH"
bash "$REPO_ROOT/bin/merge-state.sh" --bootstrap >/dev/null 2>&1

# --- 1. EL WORKTREE NACE EN EL HEAD DEL FORK --------------------------------
# The copy inside the scratch ORCH_DIR runs, so its siblings (the stub of
# the claim arbiter) are the ones it finds: HERE decides ORCH_BIN.
bash "$ORCH/bin/prepare-slot.sh" 9002 "test-resume" >/dev/null 2>&1
WT="$TMP/wt/issue-9002"
if [ -d "$WT" ]; then
  HEAD_SHA="$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
  if [ "$HEAD_SHA" = "$FORK_SHA" ]; then
    ok "el worktree de una rama que solo esta en el fork nace en el head del fork"
  else
    no "el worktree de una rama que solo esta en el fork nace en el head del fork" \
       "nacio en $HEAD_SHA y el fork esta en $FORK_SHA"
  fi
else
  no "el worktree de una rama que solo esta en el fork nace en el head del fork" "no hay worktree"
fi

# --- 2. EL BRIEF SALE SIEMPRE DE LA PLANTILLA; LA NOTA DE REPAIR SE AGREGA --
# La plantilla de la prueba lleva el marcador {{PR}} (el de verdad lo agrega
# quien edita prompts/agent-brief.md).
grep -q '{{PR}}' "$ORCH/prompts/agent-brief.md" || printf '\nPR:         {{PR}}\n' >> "$ORCH/prompts/agent-brief.md"
BRIEF="$ORCH/prompts/agent-9002.md"
printf 'BRIEF VIEJO: rm -rf el target y git worktree remove --force\n' > "$BRIEF"
printf 'El repair del slot {{ISSUE}}: los tests que fallan, en {{WORKTREE}}.\n' > "$ORCH/prompts/repair-9002.md"
# El lock de la preparacion anterior se suelta (el agente se fue): si no,
# prepare-slot sale con 4 antes de llegar al brief y la prueba no prueba nada.
bash "$ORCH/bin/slot-lock.sh" --slot 9002 --release >/dev/null 2>&1
bash "$ORCH/bin/prepare-slot.sh" 9002 "test-resume-2" >/dev/null 2>&1
if ! grep -q "BRIEF VIEJO" "$BRIEF" 2>/dev/null && grep -q "issue-9002" "$BRIEF" 2>/dev/null; then
  ok "un brief viejo se reemplaza por la plantilla"
else
  no "un brief viejo se reemplaza por la plantilla" "$(head -3 "$BRIEF" 2>/dev/null)"
fi
if grep -q "^## Notes for this slot" "$BRIEF" 2>/dev/null \
   && grep -q "El repair del slot 9002: los tests que fallan, en $TMP/wt/issue-9002." "$BRIEF" 2>/dev/null; then
  ok "la nota de repair se agrega bajo 'Notes for this slot', con sus marcadores rellenados"
else
  no "la nota de repair se agrega bajo 'Notes for this slot', con sus marcadores rellenados" "$(tail -4 "$BRIEF" 2>/dev/null)"
fi
if grep -q "none yet" "$BRIEF" 2>/dev/null && ! grep -q '{{PR}}' "$BRIEF" 2>/dev/null; then
  ok "sin PR nuestro, {{PR}} dice 'none yet'"
else
  no "sin PR nuestro, {{PR}} dice 'none yet'" "$(grep -n 'PR' "$BRIEF" | head -3)"
fi
rm -f "$ORCH/prompts/repair-9002.md"

# --- 3. NUESTRO PR ABIERTO VA AL ARBITRO Y AL ESTADO ------------------------
# El PR #20081 (nuestro, rama fix-9002) y uno de otro en otra rama: el nuestro
# es el que va como --our-pr.
cat > "$TMP/prs.json" <<'JSON'
[{"number":20090,"title":"otro (#9002)","author":{"login":"otro"},"headRefName":"otra-rama"},
 {"number":20081,"title":"nuestro (#9002)","author":{"login":"vdirienzo"},"headRefName":"fix-9002"}]
JSON
export GH_FAKE_LIST="$TMP/prs.json"
: > "$TMP/claim-args.txt"
bash "$ORCH/bin/slot-lock.sh" --slot 9002 --release >/dev/null 2>&1
bash "$ORCH/bin/prepare-slot.sh" 9002 "test-resume-3" >/dev/null 2>&1
if grep -q -- "9002 --our-pr 20081" "$TMP/claim-args.txt" 2>/dev/null; then
  ok "prepare-slot le pasa nuestro PR al arbitro (--our-pr)"
else
  no "prepare-slot le pasa nuestro PR al arbitro (--our-pr)" "$(cat "$TMP/claim-args.txt")"
fi
if python3 - "$ORCH/state.json" <<'PY'
import json, sys
slot = (json.load(open(sys.argv[1], encoding="utf-8")).get("slots") or {}).get("9002") or {}
raise SystemExit(0 if slot.get("pr") == 20081 else 1)
PY
then
  ok "nuestro PR queda en el estado del slot (deja de ser 'guardado sin PR')"
else
  no "nuestro PR queda en el estado del slot (deja de ser 'guardado sin PR')"
fi
if grep -q "20081" "$BRIEF" 2>/dev/null; then
  ok "{{PR}} se rellena con nuestro PR"
else
  no "{{PR}} se rellena con nuestro PR"
fi
unset GH_FAKE_LIST

# --- 4 y 5. LA WAVE, con todos sus hermanos de mentira ----------------------
# Una caja propia para la wave: su ORCH_DIR, sus worktrees y sus stubs. Solo
# wave.sh, state-set.py y merge-state.sh son los de verdad.
W="$TMP/wave"
test_guard_orch_dir "$W/orch"
mkdir -p "$W/orch/bin" "$W/orch/prompts" "$W/wt"
cp "$REPO_ROOT/bin/wave.sh" "$REPO_ROOT/bin/state-set.py" "$REPO_ROOT/bin/merge-state.sh" "$W/orch/bin/"
WB="$W/orch/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WB/claim-verify.sh"
# El lock: ninguno tomado, todos libres.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WB/slot-lock.sh"
printf '#!/usr/bin/env bash\necho "free_slots=${FAKE_FREE:-1}"\n' > "$WB/slots.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WB/slot-target-dir.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WB/slot-busy.sh"
printf 'import sys\n' > "$WB/slot-prs.py"
# El selector: el mas bajo de una lista que no este en --exclude (ninguno si
# existe el archivo no-issues), y anota con que lo llamaron.
cat > "$WB/next-issue.py" <<PY
import os, sys
args = sys.argv[1:]
with open("$W/next-args.txt", "a") as fh:
    fh.write(" ".join(args) + "\\n")
excl = set()
if "--exclude" in args:
    excl = {p for p in args[args.index("--exclude") + 1].split(",") if p}
for n in (100, 101, 102, 103, 104, 105):
    if str(n) not in excl and not os.path.exists("$W/no-issues"):
        print(n)
        raise SystemExit(0)
print("next-issue: no hay", file=sys.stderr)
raise SystemExit(1)
PY
# prepare-slot que siempre falla, con su motivo en el stderr.
cat > "$WB/prepare-slot.sh" <<SH
#!/usr/bin/env bash
echo "\$1" >> "$W/prepare-calls.txt"
[ "\$1" = 201 ] && { echo "prepare-slot: la ficha del issue #201 dice que la causa esta en el kernel" >&2; exit 6; }
echo "prepare-slot: MOTIVO-DE-PRUEBA del \$1" >&2
exit 3
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$WB/dispatch-slot.sh"
chmod +x "$WB"/*.sh
# El slot 101 ya tiene worktree: no es un issue nuevo.
mkdir -p "$W/wt/issue-101"
(
  export ORCH_DIR="$W/orch" WORKTREES_DIR="$W/wt"
  bash "$WB/merge-state.sh" --bootstrap >/dev/null 2>&1
)

run_wave() {
  ORCH_DIR="$W/orch" WORKTREES_DIR="$W/wt" FAKE_FREE="${1:-1}" \
    timeout 60 bash "$WB/wave.sh" 2>&1
}

OUT="$(run_wave 1)"
RC=$?
CALLS="$(tr '\n' ' ' < "$W/prepare-calls.txt" 2>/dev/null)"
if [ "$RC" -ne 124 ] && [ "$(wc -l < "$W/prepare-calls.txt")" -eq 3 ]; then
  ok "la wave para despues de 3 fallos de prepare-slot (sin bucle sin fin)"
else
  no "la wave para despues de 3 fallos de prepare-slot (sin bucle sin fin)" "rc=$RC llamadas: $CALLS"
fi
if [ "$CALLS" = "100 102 103 " ]; then
  ok "la wave no repite un issue y salta el que ya tiene worktree (101)"
else
  no "la wave no repite un issue y salta el que ya tiene worktree (101)" "llamadas: $CALLS"
fi
if grep -q -- "--exclude 101,100,102" "$W/next-args.txt" 2>/dev/null; then
  ok "la wave le pasa al selector los que ya probo (--exclude)"
else
  no "la wave le pasa al selector los que ya probo (--exclude)" "$(cat "$W/next-args.txt")"
fi
if printf '%s\n' "$OUT" | grep -q "MOTIVO-DE-PRUEBA del 100" && printf '%s\n' "$OUT" | grep -q "rc=3"; then
  ok "el motivo y el codigo del fallo de prepare-slot estan en la salida de la wave"
else
  no "el motivo y el codigo del fallo de prepare-slot estan en la salida de la wave" "$OUT"
fi

# 5. Un slot guardado sin PR que no se puede retomar.
touch "$W/no-issues"
: > "$W/prepare-calls.txt"
ORCH_DIR="$W/orch" python3 "$WB/state-set.py" slots 200 '{"issue": 200, "status": "saved"}' >/dev/null 2>&1
for _ in 1 2 3; do run_wave 1 > "$W/last.txt"; done
FAILS="$(python3 - "$W/orch/state.json" <<'PY'
import json, sys
slot = (json.load(open(sys.argv[1], encoding="utf-8")).get("slots") or {}).get("200") or {}
print(slot.get("resume_failures"), "|", slot.get("resume_last_error", ""))
PY
)"
if [ "${FAILS%% *}" = "3" ] && printf '%s' "$FAILS" | grep -q "MOTIVO-DE-PRUEBA del 200"; then
  ok "cada fallo al retomar un slot guardado suma en su estado, con el motivo"
else
  no "cada fallo al retomar un slot guardado suma en su estado, con el motivo" "$FAILS"
fi
OUT="$(run_wave 1)"
if [ "$(wc -l < "$W/prepare-calls.txt")" -eq 3 ] && printf '%s\n' "$OUT" | grep -q "no se reintenta"; then
  ok "despues de 3 fallos seguidos el slot guardado no se reintenta"
else
  no "despues de 3 fallos seguidos el slot guardado no se reintenta" "llamadas: $(tr '\n' ' ' < "$W/prepare-calls.txt") / $OUT"
fi

# 6. Un slot guardado cuya causa esta en el kernel (prepare-slot rc=6, la
# ficha) se aparca: no cuenta como fallo y no se vuelve a preparar.
: > "$W/prepare-calls.txt"
ORCH_DIR="$W/orch" python3 "$WB/state-set.py" slots 200 '{"issue": 200, "status": "parked-test"}' >/dev/null 2>&1
ORCH_DIR="$W/orch" python3 "$WB/state-set.py" slots 201 '{"issue": 201, "status": "saved"}' >/dev/null 2>&1
OUT="$(run_wave 1)"
STATUS="$(python3 - "$W/orch/state.json" <<'PY'
import json, sys
slot = (json.load(open(sys.argv[1], encoding="utf-8")).get("slots") or {}).get("201") or {}
print(slot.get("status"), slot.get("resume_failures"))
PY
)"
if [ "$STATUS" = "parked-kernel None" ] && printf '%s\n' "$OUT" | grep -q "se aparca"; then
  ok "un slot con la causa en el kernel se aparca, sin contar un fallo"
else
  no "un slot con la causa en el kernel se aparca, sin contar un fallo" "$STATUS / $OUT"
fi
run_wave 1 >/dev/null
if [ "$(grep -c '^201$' "$W/prepare-calls.txt")" -eq 1 ]; then
  ok "un slot aparcado por el kernel no se vuelve a preparar"
else
  no "un slot aparcado por el kernel no se vuelve a preparar" "$(tr '\n' ' ' < "$W/prepare-calls.txt")"
fi

printf '\n%s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
