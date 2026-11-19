#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# close-slot.sh - the close-out of a slot: the PR is up, or the claim was lost.
#
# WHAT IT DOES, IN ORDER:
#   1. asks the arbiter of the claim with OUR pull request. Two outcomes:
#      - the claim is OURS: the PR is verified, recorded in the state, and the
#        slot is closed: the target dir and the worktree go, the lock is
#        released. What survives is the branch (in the fork) and the PR.
#      - the claim is LOST: our PR is closed, the work is saved (the diff, the
#        commits and a note in logs/claims-lost/) and OFFERED on the PR that
#        won. The work of a lost claim is never thrown away.
#   2. the disk: the target directory of the slot is 5.6 GB and the worktree
#      another 700 MB. The next agent starts as soon as this one is done.
#
# USAGE:
#   bash bin/close-slot.sh <issue> [our PR]
#
# EXIT CODES:
#   0  the slot is closed
#   2  the issue was not given
#   4  the claim could not be verified (nothing is published and nothing is lost)
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
# The siblings: the cron runs a COPY of this script from ~/.hermes/scripts/,
# where the siblings are NOT. They live in the orchestrator's bin. When this
# script runs from the repo, they are right here.
if [ -f "$HERE/claim-verify.sh" ]; then ORCH_BIN="$HERE"; else ORCH_BIN="${ORCH_BIN:-$ORCH_DIR/bin}"; fi
REPO="${SOLIDCRAFT_REPO:-/home/user/Projects/solidcraft-orch}"
UPSTREAM_REPO="${UPSTREAM_REPO:-tangency-labs/solidcraft}"
ISSUE="${1:-}"
OUR_PR="${2:-}"
[ -n "$ISSUE" ] || { echo "close-slot: falta el issue" >&2; exit 2; }

SLOT="$(python3 - "$ORCH_DIR/state.json" "$ISSUE" <<'PY'
import json, sys
path, issue = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
slot = (data.get("slots") or {}).get(issue)
print(json.dumps(slot) if isinstance(slot, dict) else "")
PY
)"
# Un slot que no esta en el estado tambien se puede cerrar: el estado puede
# perderlo (una sesion que murio) y el LOCK sigue saidolo. En ese caso el
# worktree y el target se sacan por la CONVENCION (el nombre del slot), que
# es la que usa prepare-slot.sh.
WORKTREES_DIR="${WORKTREES_DIR:-$HOME/solidcraft-wt}"
if [ -z "$SLOT" ]; then
  SLOT="{\"issue\": $ISSUE, \"branch\": \"\", \"worktree\": \"$WORKTREES_DIR/issue-$ISSUE\", \"target_dir\": \"\"}"
  echo "close-slot: el slot $ISSUE no esta en el estado: se cierra por la convencion" >&2
fi

BRANCH="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('branch',''))" "$SLOT")"
WT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('worktree',''))" "$SLOT")"
TD="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('target_dir',''))" "$SLOT")"
[ -n "$TD" ] || TD="$(bash "$ORCH_BIN/slot-target-dir.sh" --slot "$ISSUE" 2>/dev/null)"

# 1. EL ARBITRO DEL CLAIM, CON NUESTRO PR.
VERDICT="$(bash "$ORCH_BIN/claim-verify.sh" "$ISSUE" $OUR_PR 2>&1)"
RC=$?
WINNER="$(printf '%s\n' "$VERDICT" | grep -oE '#([0-9]+)' | head -1 | tr -d '#')"

if [ "$RC" = "1" ]; then
  # EL CLAIM SE PERDIÓ: se cierra nuestro PR, se guarda el trabajo y se ofrece.
  if [ -n "$OUR_PR" ]; then
    gh pr close "$OUR_PR" -R "$UPSTREAM_REPO" --comment \
      "Cierro este PR: el claim lo tiene el #$WINNER, que tiene el número menor y por lo tanto gana. \
Dejo el trabajo en la rama \`$(git -C "$REPO" branch --list "fix-$ISSUE" --format='%(refname:short)' | head -1)\` \
y el diagnóstico en el comentario del PR ganador." >/dev/null 2>&1
  fi
  STAMP="$(date -u +%Y%m%d-%H%M%S)"
  SAVE="$ORCH_DIR/logs/claims-lost/$ISSUE-$STAMP"
  mkdir -p "$SAVE"
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    git -C "$WT" diff > "$SAVE/diff.patch" 2>/dev/null
    git -C "$WT" log --oneline -20 > "$SAVE/commits.txt" 2>/dev/null
  fi
  cat > "$SAVE/README.md" <<EOF
# El claim de #$ISSUE se perdió

Nuestro PR #$OUR_PR perdió contra el #$WINNER (el número menor gana).
El trabajo queda acá: el diff, los commits y la rama.

- La rama: \`$BRANCH\`
- El PR que ganó: https://github.com/$UPSTREAM_REPO/pull/$WINNER

La oferta está en el comentario del PR ganador.
EOF
  python3 "$ORCH_BIN/state-set.py" --delete slots "$ISSUE" >/dev/null 2>&1
  [ -n "$TD" ] && rm -rf "$TD"
  [ -n "$WT" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --release >/dev/null 2>&1
  echo "close-slot: #$ISSUE perdió el claim contra el #$WINNER; el trabajo quedó en $SAVE y ofrecido en el PR ganador"
  exit 0
fi

if [ "$RC" != "0" ]; then
  echo "close-slot: el claim no se pudo verificar (rc=$RC): no se publica nada y no se tira nada" >&2
  exit 4
fi

# 2. EL PR ES NUESTRO: se verifica, se anota y el slot se cierra.
if [ -n "$OUR_PR" ]; then
  bash "$ORCH_BIN/verify-pr.sh" "$OUR_PR" >>"$ORCH_DIR/logs/$ISSUE-verify.log" 2>&1 || true
  python3 "$ORCH_BIN/state-set.py" open_prs "$OUR_PR" "$(python3 - "$OUR_PR" "$ISSUE" "$BRANCH" <<'PY'
import json, sys
pr, issue, branch = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "number": int(pr),
    "issue": int(issue),
    "state": "open",
    "branch": branch,
}))
PY
)" >/dev/null 2>&1
fi

python3 "$ORCH_BIN/state-set.py" --delete slots "$ISSUE" >/dev/null 2>&1
[ -n "$TD" ] && rm -rf "$TD"
[ -n "$WT" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --release >/dev/null 2>&1
echo "close-slot: #$ISSUE cerrado (PR #$OUR_PR); el target y el worktree fueron, la rama y el PR quedan"
exit 0
