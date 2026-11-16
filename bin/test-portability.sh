#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-portability.sh - the orchestrator has to run on ANOTHER PC.
#
# WHY THE TESTS EXIST: the orchestrator was written on ONE machine and every
# script carried its absolute paths. On another PC, with another user, they
# do not exist and every script dies. The paths have to come from the
# environment, with a default that keeps THIS machine working unchanged.
#
# WHAT IS TESTED:
#   1. no script of bin/ has an absolute path of THIS machine outside the
#      documented defaults (${VAR:-<path of this machine>}).
#   2. every script that uses ORCH_DIR/LOOP_DIR/SOLIDCRAFT_REPO/WORKTREES_DIR/
#      HERMES_SCRIPTS defines it with a default, so it never runs with an
#      empty path on the other PC.
#   3. the five variables are documented in the README.
#   4. the rules and the traps of the skill are in docs/ (the other PC has no
#      skill: it has the repo).
#
# EXIT CODES:
#   0  every test passed
#   1  at least one failed
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
BIN="$ORCH_DIR/bin"

PASS=0
FAIL=0

ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# The path of THIS machine, assembled so that THIS file does not carry the
# literal path (the grep of the acceptance criterion runs over bin/, and it
# has to find nothing, not even here).
HOMEBASE='/home/'"user"
DEFPAT=':-'"$HOMEBASE"

# The scripts of bin/: the ones that TRAVEL to the other PC. Those are the
# ones Git knows (tracked or staged): a script lying loose in the directory
# is NOT in the repo, so it does not travel and it cannot break the
# portability of the repo. Measuring the index, not the directory, is what
# makes this gate answer the question it asks. When the tree is not a git
# repo (a tarball), it falls back to the directory.
scripts() {
  if git -C "$ORCH_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$ORCH_DIR" ls-files -- 'bin/*' 2>/dev/null \
      | sed -n 's|^bin/\([^/]*\)$|\1|p'
  else
    find "$BIN" -maxdepth 1 -type f \
      ! -name '*.bak*' ! -name '*.pyc' \
      -printf '%f\n' 2>/dev/null
  fi | sort
}

# --- 1. no absolute path of this machine outside the defaults ----------------
# The rule: an absolute path that survives is a DEFAULT (${VAR:-<path>}),
# never a path used directly. A path used directly is a machine, and the
# orchestrator has to run on more than one.
HARD=""
while read -r f; do
  [ -z "$f" ] && continue
  hits="$(grep -n "$HOMEBASE" "$BIN/$f" 2>/dev/null | grep -v "$DEFPAT" || true)"
  [ -n "$hits" ] && HARD="$HARD$f"$'\n'"$hits"$'\n'
done < <(scripts)

if [ -z "$HARD" ]; then
  ok "portability: no script of bin/ has a hardcoded path of this machine outside the defaults"
else
  bad "portability: a script of bin/ has a hardcoded path of this machine outside the defaults" \
      "$(printf '%s' "$HARD" | head -20)"
fi

# The same rule for the repo and the worktrees: a path that is not a default
# does not exist on the other PC.
HARD2=""
while read -r f; do
  [ -z "$f" ] && continue
  hits="$(grep -nE "$HOMEBASE/(solidcraft|solidcraft-wt)" "$BIN/$f" 2>/dev/null \
          | grep -v "$DEFPAT" || true)"
  [ -n "$hits" ] && HARD2="$HARD2$f"$'\n'"$hits"$'\n'
done < <(scripts)

if [ -z "$HARD2" ]; then
  ok "portability: the repo and the worktrees are not hardcoded outside the defaults"
else
  bad "portability: the repo or the worktrees are hardcoded outside the defaults" \
      "$(printf '%s' "$HARD2" | head -20)"
fi

# --- 2. the variables that are used are DEFINED ------------------------------
# A script that uses $WORKTREES_DIR without defining it runs with an EMPTY
# path on the other PC (or with the path of another variable). Every script
# that uses one of the five variables has to define it with a default: either
# an assignment at the top, or a default in the very use of it.
VARS="ORCH_DIR LOOP_DIR SOLIDCRAFT_REPO WORKTREES_DIR HERMES_SCRIPTS"

for v in $VARS; do
  MISSING=""
  while read -r f; do
    [ -z "$f" ] && continue
    [ "$f" = "test-portability.sh" ] && continue
    # Does the script USE the variable?
    uses=0
    grep -qE "\\\$\{?$v([^A-Za-z0-9_]|$)" "$BIN/$f" 2>/dev/null && uses=1
    grep -q "os.environ.get(\"$v\"" "$BIN/$f" 2>/dev/null && uses=1
    grep -q "os.environ\[\"$v\"\]" "$BIN/$f" 2>/dev/null && uses=1
    [ "$uses" = "0" ] && continue
    # Does it DEFINE it with a default?
    def=0
    grep -qE "^[[:space:]]*(export[[:space:]]+)?$v[[:space:]]*=" "$BIN/$f" 2>/dev/null && def=1
    grep -qE "\\\$\{$v:-" "$BIN/$f" 2>/dev/null && def=1
    grep -q "os.environ.get(\"$v\"" "$BIN/$f" 2>/dev/null && def=1
    [ "$def" = "0" ] && MISSING="$MISSING$f "
  done < <(scripts)

  if [ -z "$MISSING" ]; then
    ok "portability: every script that uses $v defines it with a default"
  else
    bad "portability: a script uses $v without defining it with a default" "$MISSING"
  fi
done

# --- 3. the variables are documented ----------------------------------------
for v in $VARS; do
  if grep -q "$v" "$ORCH_DIR/README.md" 2>/dev/null; then
    ok "portability: the README documents $v"
  else
    bad "portability: the README does not document $v"
  fi
done

# The default of ORCH_DIR is the path of THIS machine: the machine keeps
# working without changing anything, and the other PC exports its own.
if grep -qF "ORCH_DIR=\"\${ORCH_DIR:-$HOMEBASE/.local/share/solidcraft-orch}\"" "$BIN/gate-queue.sh" 2>/dev/null; then
  ok "portability: the default of ORCH_DIR is the path of this machine"
else
  bad "portability: the default of ORCH_DIR is not the path of this machine"
fi

# The scripts that the crons run live in HERMES_SCRIPTS: the variable has to
# be documented with its default, because that is where the crons of the
# other PC look for them.
if grep -qF "HERMES_SCRIPTS=\"\${HERMES_SCRIPTS:-$HOMEBASE/.hermes/scripts}\"" "$ORCH_DIR/README.md" 2>/dev/null; then
  ok "portability: the README documents HERMES_SCRIPTS with its default"
else
  bad "portability: the README does not document HERMES_SCRIPTS with its default"
fi

# --- 4. the knowledge travels with the code ---------------------------------
# The other PC has no skill: it has the repo.
if [ -f "$ORCH_DIR/docs/slot-rules.md" ] && [ -f "$ORCH_DIR/docs/known-traps.md" ]; then
  ok "portability: the rules and the traps are in docs/"
else
  bad "portability: docs/ does not have the rules and the traps"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
