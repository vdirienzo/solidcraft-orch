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
# WHAT IS TESTED:
#   1. the worktree of a slot whose branch is only in the fork starts at the
#      head of the fork.
#   2. a brief written by hand is not overwritten.
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
mkdir -p "$ORCH/prompts" "$ORCH/logs" "$ORCH/bin"
cp "$REPO_ROOT/prompts/agent-brief.md" "$ORCH/prompts/"
cp "$REPO_ROOT/bin/merge-state.sh" "$ORCH/bin/" 2>/dev/null
# El arbitro del claim dice que el issue esta libre.
cat > "$ORCH/bin/claim-verify.sh" <<'STUB'
#!/usr/bin/env bash
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

# --- 2. UN BRIEF ESCRITO A MANO NO SE PISA ----------------------------------
BRIEF="$ORCH/prompts/agent-9002.md"
printf 'BRIEF ESCRITO A MANO: el repair del PR #20017\n' > "$BRIEF"
bash "$ORCH/bin/prepare-slot.sh" 9002 "test-resume-2" >/dev/null 2>&1
if grep -q "BRIEF ESCRITO A MANO" "$BRIEF" 2>/dev/null; then
  ok "un brief escrito a mano no se pisa con la plantilla"
else
  no "un brief escrito a mano no se pisa con la plantilla" "el brief se reescribio"
fi

printf '\n%s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
