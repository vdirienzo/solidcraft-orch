#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# prepare-slot.sh - the slot of an issue, ready for an agent.
#
# WHAT IT DOES, IN ORDER (the order is the rule):
#   1. asks the ARBITER of the claim (bin/claim-verify.sh): a label is not a
#      claim, and the lowest-numbered open PR wins. If somebody else holds the
#      issue, NOTHING happens here.
#   2. takes the lock of the slot: two waves never touch the same slot.
#   3. creates the worktree and the branch from the upstream's main.
#   4. creates the target directory of the slot: every slot compiles in its
#      own directory, or cargo queues the builds in front of each other.
#   5. renders the brief (prompts/agent-brief.md) into prompts/agent-<issue>.md.
#   6. writes the slot in the state, so a session that dies finds the work
#      where it was left.
#
# USAGE:
#   bash bin/prepare-slot.sh <issue> [owner]
#
# EXIT CODES:
#   0  the slot is ready (the brief is on stdout)
#   3  the claim is not free (somebody else's PR is lower)
#   4  the lock of the slot is taken
#   5  the worktree could not be created
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
# The siblings: the cron runs a COPY of this script from ~/.hermes/scripts/,
# where the siblings are NOT. They live in the orchestrator's bin. When this
# script runs from the repo, they are right here.
if [ -f "$HERE/claim-verify.sh" ]; then ORCH_BIN="$HERE"; else ORCH_BIN="${ORCH_BIN:-$ORCH_DIR/bin}"; fi
REPO="${SOLIDCRAFT_REPO:-/home/user/Projects/solidcraft-orch}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
UPSTREAM_REPO="${UPSTREAM_REPO:-tangency-labs/solidcraft}"
ISSUE="${1:-}"
OWNER="${2:-wave-$$}"

[ -n "$ISSUE" ] || { echo "prepare-slot: falta el issue" >&2; exit 2; }

# 1. EL ARBITRO DEL CLAIM. Si dice que lo tiene otro, no se toca nada.
if ! bash "$ORCH_BIN/claim-verify.sh" "$ISSUE" >/dev/null 2>&1; then
  echo "prepare-slot: el issue #$ISSUE no está libre (el claim lo tiene otro PR)" >&2
  exit 3
fi

# 2. EL LOCK DEL SLOT.
if ! bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --take --owner "$OWNER" >/dev/null 2>&1; then
  echo "prepare-slot: el slot $ISSUE ya está tomado" >&2
  exit 4
fi

BRANCH="fix-$ISSUE"
WT="$WORKTREES_DIR/issue-$ISSUE"
BRIEF="$ORCH_DIR/prompts/agent-$ISSUE.md"
TEMPLATE="$ORCH_DIR/prompts/agent-brief.md"
# The template of the brief lives in the repo: on a machine where ORCH_DIR is
# not the repo (a symlink, a copy), the repo's copy is the one that is there.
[ -f "$TEMPLATE" ] || TEMPLATE="$(cd "$ORCH_BIN/.." && pwd)/prompts/agent-brief.md"

# 3. EL WORKTREE CON SU RAMA, desde el main del upstream.
if [ ! -f "$TEMPLATE" ]; then
  echo "prepare-slot: no está el template del brief: $TEMPLATE" >&2
  bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --release >/dev/null 2>&1
  exit 5
fi
git -C "$REPO" fetch origin >/dev/null 2>&1
# EL FORK TAMBIEN (2026-11-20): la rama de un slot puede estar SOLO en el
# fork (el agente la pusheo y esta maquina la borro). El worktree tiene que
# nacer en el head del fork, no en origin/main ni en una rama local vieja: el
# agente de repair del PR #20017 trabajo sobre b292d76a9 (la base que no era)
# en vez de 471445c5e (el head del PR), y no podia ver los fallos que tenia
# que arreglar.
git -C "$REPO" fetch fork "$BRANCH:refs/remotes/fork/$BRANCH" >/dev/null 2>&1 || true
FORK_SHA="$(git -C "$REPO" rev-parse -q --verify "refs/remotes/fork/$BRANCH" 2>/dev/null || true)"
if [ ! -d "$WT" ]; then
  # THE BRANCH THAT IS ALREADY THERE (the rescue of a slot whose work was
  # saved): `git worktree add -b` FAILS when the branch exists, and the work of
  # the rescued slot (the RED test, the fix a medias) would stay in a branch
  # that nobody checks out. The worktree is attached to the branch as it is.
  if git -C "$REPO" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null; then
    git -C "$REPO" worktree add -q "$WT" "$BRANCH" >/dev/null 2>&1 || {
      echo "prepare-slot: no se pudo crear el worktree sobre la rama $BRANCH: $WT" >&2
      bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --release >/dev/null 2>&1
      exit 5
    }
  elif [ -n "$FORK_SHA" ]; then
    # The branch is only in the fork: the worktree starts from THERE (the head
    # of the PR), not from origin/main.
    git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$FORK_SHA" >/dev/null 2>&1 || {
      echo "prepare-slot: no se pudo crear el worktree sobre la rama $BRANCH: $WT" >&2
      bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --release >/dev/null 2>&1
      exit 5
    }
  else
    git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" origin/main >/dev/null 2>&1 || {
      echo "prepare-slot: no se pudo crear el worktree: $WT" >&2
      bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --release >/dev/null 2>&1
      exit 5
    }
  fi
fi

# 4. EL TARGET DIR DEL SLOT.
TD="$(bash "$ORCH_BIN/slot-target-dir.sh" --slot "$ISSUE" 2>/dev/null)"
[ -n "$TD" ] && mkdir -p "$TD"

# 5. EL BRIEF, con lo único que cambia por issue.
#
# UN BRIEF ESCRITO A MANO NO SE PISA (2026-11-20): el brief de un slot es lo
# que el agente lee, y un brief escrito a mano (un repair de un PR que ya esta
# abierto, con los tests que fallan y el log del gate) es informacion que la
# plantilla no tiene. Si el brief ya existe, se rellenan sus marcadores y se
# deja su texto como estaba.
TITLE="$(gh issue view "$ISSUE" -R "$UPSTREAM_REPO" --json title --jq .title 2>/dev/null)"
python3 - "$TEMPLATE" "$BRIEF" "$ISSUE" "$TITLE" "$REPO" "$WT" "$BRANCH" "$TD" <<'PY'
import os, sys
template, out, issue, title, repo, wt, branch, target = sys.argv[1:9]
# The brief that is already there wins over the template: a hand written brief
# (the repair of a pull request that is already open) is the information the
# agent needs, and the template does not have it.
text = open(out, encoding="utf-8").read() if os.path.exists(out) else open(template, encoding="utf-8").read()
for key, value in {
    "{{ISSUE}}": issue,
    "{{TITLE}}": title,
    "{{REPO}}": repo,
    "{{WORKTREE}}": wt,
    "{{BRANCH}}": branch,
    "{{TARGET_DIR}}": target,
}.items():
    text = text.replace(key, value)
with open(out, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

# 6. EL ESTADO: el slot queda escrito para que otra sesion lo encuentre.
python3 "$ORCH_BIN/state-set.py" slots "$ISSUE" "$(python3 - "$ISSUE" "$OWNER" "$BRANCH" "$WT" "$BRIEF" "$TD" <<'PY'
import json, sys
issue, owner, branch, wt, brief, target = sys.argv[1:7]
print(json.dumps({
    "issue": int(issue),
    "status": "prepared",
    "phase": "el brief está escrito; el agente todavía no arrancó",
    "owner": owner,
    "branch": branch,
    "worktree": wt,
    "brief": brief,
    "target_dir": target,
}))
PY
)" >/dev/null 2>&1

echo "$BRIEF"
exit 0
