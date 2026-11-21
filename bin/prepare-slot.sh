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
#   5. renders the brief (prompts/agent-brief.md) into prompts/agent-<issue>.md,
#      ALWAYS from the template, plus the repair note prompts/repair-<issue>.md
#      when there is one.
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
# The siblings live next to this script: the crontab runs the scripts of the
# repo (2026-11-21). ORCH_BIN is only the fallback for a copy of the script
# that runs outside bin/ without them.
if [ -f "$HERE/claim-verify.sh" ]; then ORCH_BIN="$HERE"; else ORCH_BIN="${ORCH_BIN:-$ORCH_DIR/bin}"; fi
REPO="${SOLIDCRAFT_REPO:-/home/user/Projects/solidcraft-orch}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
UPSTREAM_REPO="${UPSTREAM_REPO:-tangency-labs/solidcraft}"
ISSUE="${1:-}"
OWNER="${2:-wave-$$}"

[ -n "$ISSUE" ] || { echo "prepare-slot: falta el issue" >&2; exit 2; }
BRANCH="fix-$ISSUE"

# 0. NUESTRO PROPIO PR, ANTES DEL CLAIM (2026-11-21).
#
# POR QUE: el arbitro sin nuestro numero de PR no sabe cual es el nuestro, y
# nuestro propio PR abierto (el #20081, rama fix-19690, del slot 19690) le
# parecia un competidor: OCUPADO. El slot 19690 no se podia volver a preparar
# NUNCA, y la wave lo reintentaba en cada turno. Se busca el PR abierto de la
# rama del slot cuyo autor somos nosotros (solo lectura) y se le pasa al
# arbitro con --our-pr. El filtro por la rama va tambien en el --jq: el
# resultado no depende de que el --head del gh filtre bien.
# Quien somos: la misma fuente que el arbitro (FORK_OWNER, despues gh).
ME="${OUR_LOGIN:-${FORK_OWNER:-$(gh api user --jq .login 2>/dev/null || true)}}"
[ -n "$ME" ] || ME="vdirienzo"
OUR_PR="$(gh pr list -R "$UPSTREAM_REPO" --head "$BRANCH" --state open --json number,author,headRefName \
  --jq "[.[] | select(.headRefName == \"$BRANCH\" and .author.login == \"$ME\")] | .[0].number // empty" 2>/dev/null | head -1)"
[[ "$OUR_PR" =~ ^[0-9]+$ ]] || OUR_PR=""
if [ -n "$OUR_PR" ]; then
  echo "prepare-slot: el slot $ISSUE ya tiene nuestro PR #$OUR_PR (rama $BRANCH)" >&2
  # El PR queda en el estado YA: la wave deja de tratar el slot como "guardado
  # sin PR" aunque el resto de la preparacion falle.
  python3 "$ORCH_BIN/state-set.py" --merge slots "$ISSUE" "{\"pr\": $OUR_PR}" >/dev/null 2>&1 || true
fi

# 1. EL ARBITRO DEL CLAIM. Si dice que lo tiene otro, no se toca nada.
# Lo que dice el arbitro va al stderr: la wave lo escribe en su salida, y un
# "no se pudo preparar" sin el motivo no se puede arreglar.
#
# LA FOTO DE next-issue.py (2026-11-21): la wave llama a next-issue.py y en
# seguida a este script, y los dos le preguntaban a GitHub por los ~1000 PRs
# abiertos (~11 paginas cada vez). El arbitro lee la foto de bin/gh_snapshot.py
# si tiene menos de GH_SNAPSHOT_MAX_AGE_MIN minutos (15) y conoce el issue; si
# no, pregunta en vivo como antes. El gate y publish-pr.sh siguen en vivo.
SNAPSHOT="${GH_SNAPSHOT:-$ORCH_DIR/state/cache/gh-snapshot.json}"
if [ -n "$OUR_PR" ]; then
  CLAIM_OUT="$(bash "$ORCH_BIN/claim-verify.sh" "$ISSUE" --our-pr "$OUR_PR" --snapshot "$SNAPSHOT" 2>&1)"
else
  CLAIM_OUT="$(bash "$ORCH_BIN/claim-verify.sh" "$ISSUE" --snapshot "$SNAPSHOT" 2>&1)"
fi
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  echo "prepare-slot: el issue #$ISSUE no está libre (claim-verify rc=$CLAIM_RC${OUR_PR:+, nuestro PR #$OUR_PR}): $(printf '%s' "$CLAIM_OUT" | tail -3 | tr '\n' ' ')" >&2
  exit 3
fi

# 2. EL LOCK DEL SLOT.
if ! bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --take --owner "$OWNER" >/dev/null 2>&1; then
  echo "prepare-slot: el slot $ISSUE ya está tomado" >&2
  exit 4
fi

WT="$WORKTREES_DIR/issue-$ISSUE"
BRIEF="$ORCH_DIR/prompts/agent-$ISSUE.md"
TEMPLATE="$ORCH_DIR/prompts/agent-brief.md"
# The template of the brief lives in the repo: on a machine where ORCH_DIR is
# not the repo (a symlink, a copy), the repo's copy is the one that is there.
[ -f "$TEMPLATE" ] || TEMPLATE="$(cd "$ORCH_BIN/.." && pwd)/prompts/agent-brief.md"
REPAIR="$ORCH_DIR/prompts/repair-$ISSUE.md"
[ -f "$REPAIR" ] || REPAIR="$(cd "$ORCH_BIN/.." && pwd)/prompts/repair-$ISSUE.md"

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
# SIEMPRE DESDE LA PLANTILLA (2026-11-21). Antes un brief que ya existia
# (prompts/agent-<N>.md) ganaba a la plantilla, y los briefs viejos seguian
# mandando lo que la plantilla ya no dice: el de 19690 le pedia al agente
# `rm -rf` de su target y `git worktree remove --force` de su worktree
# (lineas 109-110), con el gate en cola usandolos. Un brief generado es un
# artefacto: se regenera en cada preparacion.
#
# Lo que el brief escrito a mano tenia de valioso (un repair: los tests que
# fallan, el log del gate) va en prompts/repair-<N>.md, que se agrega al final
# bajo "## Notes for this slot", con sus marcadores rellenados tambien.
TITLE="$(gh issue view "$ISSUE" -R "$UPSTREAM_REPO" --json title --jq .title 2>/dev/null)"
python3 - "$TEMPLATE" "$BRIEF" "$ISSUE" "$TITLE" "$REPO" "$WT" "$BRANCH" "$TD" "$OUR_PR" "$REPAIR" <<'PY'
import os, sys
template, out, issue, title, repo, wt, branch, target, pr, repair = sys.argv[1:11]
with open(template, encoding="utf-8") as fh:
    text = fh.read()
if os.path.isfile(repair):
    with open(repair, encoding="utf-8") as fh:
        note = fh.read().strip()
    if note:
        text = text.rstrip("\n") + "\n\n## Notes for this slot\n\n" + note + "\n"
for key, value in {
    "{{ISSUE}}": issue,
    "{{TITLE}}": title,
    "{{REPO}}": repo,
    "{{WORKTREE}}": wt,
    "{{BRANCH}}": branch,
    "{{TARGET_DIR}}": target,
    "{{PR}}": pr or "none yet",
}.items():
    text = text.replace(key, value)
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

# 6. EL ESTADO: el slot queda escrito para que otra sesion lo encuentre.
python3 "$ORCH_BIN/state-set.py" slots "$ISSUE" "$(python3 - "$ISSUE" "$OWNER" "$BRANCH" "$WT" "$BRIEF" "$TD" "$OUR_PR" <<'PY'
import json, sys
issue, owner, branch, wt, brief, target, pr = sys.argv[1:8]
entry = {
    "issue": int(issue),
    "status": "prepared",
    "phase": "el brief está escrito; el agente todavía no arrancó",
    "owner": owner,
    "branch": branch,
    "worktree": wt,
    "brief": brief,
    "target_dir": target,
}
# Nuestro PR, si lo hay: el slot no es "guardado sin PR" (2026-11-21).
if pr.isdigit():
    entry["pr"] = int(pr)
print(json.dumps(entry))
PY
)" >/dev/null 2>&1

echo "$BRIEF"
exit 0
