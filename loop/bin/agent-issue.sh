#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Corre una issue con OpenCode + MiniMax M3.1 Flash, en LOCAL, y deja el
# pull request en draft.
#
# POR QUÉ ESTO EXISTE, AL LADO DEL LOOP:
# El loop (bin/loop.sh) spends el 70% de su tiempo en el gate local: `cargo
# xtask ci` corre la suite COMPLETA del workspace (78 binarios, 56-90 min
# medidos en esta maquina) y solo puede correr uno a la vez porque satura la
# maquina. Este script hace la parte que un modelo hace bien (leer, escribir el
# fix, escribir el test, iterar hasta que el gate pasa) y le deja al
# MANTENEDOR la decision de mergear.
#
# Es el mismo agente y el mismo modelo que usa el loop (OpenCode +
# minimax/MiniMax-M3.1-Flash, el unico provider autenticado en esta maquina),
# pero en una sola pasada y con el gate angosto: `cargo fmt` + el test del
# crate tocado. El gate COMPLETO lo corre el CI del repo, en los runners de
# GitHub, sin tocar esta maquina.
#
# LA REGLA QUE NO SE DOBLA (misma idea que el supervisor): el modelo propone,
# este script dispone. El agente escribe el codigo y el test; el script
# comprueba que no toco nada de mas, que el gate angosto pasa, y SOLO entonces
# publica la rama y el pull request en draft. Nunca mergea, nunca cierra.
#
# QUE SE USA:
#   bin/agent-issue.sh <numero_de_issue> [--repo owner/name] [--model prov/model]
#                      [--work <dir>] [--timeout <minutos>] [--no-publish]
#                      [--dry-run]    # only shows the PR it would open, then exits
#
# EJEMPLOS:
#   bin/agent-issue.sh 6138
#   bin/agent-issue.sh 6138 --repo tangency-labs/solidcraft --timeout 30
#   bin/agent-issue.sh 6138 --no-publish        # solo implementa y prueba
#
# KNOBS (every one of them is read with its default when it is not set):
#   AGENT_CHANGES_DEFAULT   what the agent claims about the line of the
#                            defaults ("" when it claims nothing)
#   AGENT_DEFAULTS_FILES    the files of the defaults of the application
#                            (a comma separated list of paths)
#
#   EXIT CODES (the caller reads them here and nowhere else):
#   1  a generic failure
#   7  a person has to decide: the change alters a default
#   8  the line of the defaults is not confirmed
#   9  the rebase failed: nothing is published
#  10  the claim of the issue is TAKEN by another pull request (the brake of
#      the claim refused the publication and the work was SAVED)
#  11  the issue of the claim is not open any more (the work is MOOT for
#      this issue, not lost: the brake saved it)
#  12  the brake of the claim does not know (GitHub could not be read: the
#      publication is refused and the work is SAVED)
#
# The codes of the brake (bin/claim-brake.sh) ARE the verdict and they are
# NOT translated: 0 is the only code that lets the publication go on.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
export LOOP_DIR
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

# The directory of this script: the brakes live next to it (claim-guard.sh and
# pr-defaults-line.sh) and they are called by path, never by a guess.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The configuration is CHECKED before it is sourced: a value with spaces
# and no quotes breaks the source in the middle of the file, so the
# variable is never set and the script goes on with HALF of the policy, in
# silence (set -e is not on). The check only READS the file: the config.env
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "agente: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# config.env es la fuente de verdad de los paths, del modelo y del fork.
if [ -f "$LOOP_DIR/config.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$LOOP_DIR/config.env"
  set +a
fi

REPO="${REPO:-$HOME/solidcraft}"
FORK="${FORK:-}"
UPSTREAM="${UPSTREAM:-}"
MODEL="${MODEL:-minimax/MiniMax-M3.1-Flash}"
TIMEOUT_MIN="${TIMEOUT_MIN:-30}"
PUBLISH=1
DRY_RUN=0
WORK_ROOT="${WORK_ROOT:-$LOOP_DIR/work}"
BRANCH_PREFIX="${BRANCH_PREFIX:-spike/issue-}"

usage() {
  # Only the header comment block (up to the first line of code).
  awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

ISSUE=""
TARGET_REPO=""
PR_REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) TARGET_REPO="$2"; shift 2 ;;
    --pr-repo) PR_REPO="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --work) WORK_ROOT="$2"; shift 2 ;;
    --timeout) TIMEOUT_MIN="$2"; shift 2 ;;
    --no-publish) PUBLISH=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "agente: opcion desconocida: $1" >&2; usage 1 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || { echo "agente: falta el numero de issue" >&2; usage 1; }

# --- the pull request body -------------------------------------------------
# It is built in ONE place: the simulation (--dry-run) and the publication
# have to show the SAME body, or the announced pull request is not the one
# that gets opened.
#   pr_body <issue> <issue_url> <issue_repo> <pr_repo> <model> <crate> <verdict>
pr_body() {
  local issue="$1" issue_url="$2" issue_repo="$3" pr_repo="$4" model="$5" crate="$6" verdict="${7:-no}"
  if [ "$issue_repo" = "$pr_repo" ]; then
    # Same repository: "Fixes #N" CLOSES the issue, which is what the
    # upstream bot expects.
    printf 'Fixes #%s\n' "$issue"
  else
    # Another repository: "Fixes #N" would close nothing (the number belongs
    # to another repository), but the MENTION "#N" still matters: our claim
    # guard looks for "#N" in the title and the body of the open pull
    # requests, and without the mention this pull request is invisible to it
    # (and the loop could claim the same issue twice).
    printf 'Task: %s\n' "$issue_url"
    printf 'Issue reference: #%s\n' "$issue"
  fi
  # The upstream asks every pull request to state whether it changes a
  # default: its pr-checks.yml fails a pull request without this line. The
  # VALUE is not written by hand here: it is computed (defaults_verdict) and
  # a "yes" is never decided by the loop.
  printf 'Changes a default: %s\n' "$verdict"
  printf '\n'
  printf 'Trabajo hecho con OpenCode y %s, en local.\n' "$model"
  printf '\n'
  printf -- '- gate angosto: cargo fmt + cargo test -p %s\n' "${crate:-<crate>}"
  printf -- '- gate completo: el CI del repo, en los runners de GitHub\n'
  printf '\n'
  printf 'No mergeado: la decision es del mantenedor.\n'
}

# --- the verdict of the line of the defaults -------------------------------
# The upstream asks every pull request to say whether it changes a default
# (scripts/pr-checks/pr-checks.js reads the line and only looks at its
# SHAPE: a false "no" passes in green). The loop does not write that answer:
# it COMPUTES it and, when the answer is not a plain "no", it ESCALATES to a
# person (exit 7) and leaves the work in the issue. A "yes" is never decided
# by a machine: a change of a default keeps the old behaviour behind a
# preference and the decision is the maintainer's.
#
# The verdict is fail-closed: anything the loop cannot read is an
# escalation, never a "no" and never a "yes".
#
#   defaults_verdict <received> <changed files>
#     received     what the agent claims about the line of the defaults
#                  ("" when it claims nothing)
#     changed      the files the change touches (a space separated list)
#     -> "no" or "escalate"
defaults_verdict() {
  local received="${1:-}"
  local changed="${2:-}"
  local answer="escalate"
  local lowered=""
  local defaults="${AGENT_DEFAULTS_FILES:-crates/ui-egui/src/prefs.rs}"
  local file=""
  local path=""
  # The upstream writes the answer in lower case and sometimes with a dot at
  # the end ("no."). Only an explicit "no" (or nothing claimed at all) is a
  # "no"; anything else is an escalation.
  lowered="$(printf '%s' "$received" | tr '[:upper:]' '[:lower:]' | sed -e 's/[[:space:]]*$//' -e 's/\.$//')"
  case "$lowered" in
    ""|no) answer="no" ;;
  esac
  # A file of the defaults that the change touches is an escalation even when
  # the answer says "no": the answer has to be TRUE, and a change of those
  # files is a change of a default by definition.
  for path in $(printf '%s' "$defaults" | tr ',' ' '); do
    for file in $changed; do
      case "$file" in
        *"$path"*) answer="escalate" ;;
      esac
    done
  done
  printf '%s\n' "$answer"
}

# The brake of the line of the defaults: a person has to decide. The work
# stays in the issue and NOTHING is published.
defaults_brake() {
  echo "agente: the change alters a default: a person has to decide (exit 7)" >&2
  echo "agente: nothing is published" >&2
  exit 7
}

# --- the simulation --------------------------------------------------------
# --dry-run shows the pull request the script WOULD open and exits: no
# network (gh), no git, no worktree, no push and no pull request. It runs
# BEFORE the requirements (repo, opencode, gh) and before reading the issue,
# so it can be simulated without a network and without a prepared machine.
if [ "$DRY_RUN" -eq 1 ]; then
  # No git: the repository of the issue comes from --repo or from UPSTREAM
  # (config.env).
  [ -n "$TARGET_REPO" ] || TARGET_REPO="${UPSTREAM:-}"
  [ -n "$PR_REPO" ] || PR_REPO="$TARGET_REPO"
  ISSUE_URL="https://github.com/$TARGET_REPO/issues/$ISSUE"
  TITLE="${AGENT_ISSUE_TITLE:-the issue title}"
  PR_TITLE="$TITLE (#$ISSUE)"
  # The verdict of the line of the defaults is computed even in the
  # simulation: a change of a default is not published either, and the
  # simulation has to say so.
  VERDICT="$(defaults_verdict "${AGENT_CHANGES_DEFAULT:-}" "")"
  if [ "$VERDICT" != "no" ]; then
    defaults_brake
  fi
  PR_BODY="$(pr_body "$ISSUE" "$ISSUE_URL" "$TARGET_REPO" "$PR_REPO" "$MODEL" "" "$VERDICT")"
  echo "agente: dry run: nothing is read, nothing is published" >&2
  printf 'pr-title: %s\n' "$PR_TITLE"
  printf '%s\n' "$PR_BODY" | while IFS= read -r line; do
    printf 'pr-body-line: %s\n' "$line"
  done
  exit 0
fi

[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || { echo "agente: REPO=$REPO no es un repo" >&2; exit 1; }
command -v opencode >/dev/null || { echo "agente: opencode no esta en el PATH" >&2; exit 1; }
command -v gh >/dev/null || { echo "agente: gh no esta en el PATH" >&2; exit 1; }

# El repo de trabajo es el que tiene los issues. Por defecto, el upstream.
[ -n "$TARGET_REPO" ] || TARGET_REPO="${UPSTREAM:-$(cd "$REPO" && git config --get remote.origin.url | sed -E 's#.*github.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')}"
# Donde se abre el pull request. Por defecto, el mismo repo del issue.
[ -n "$PR_REPO" ] || PR_REPO="$TARGET_REPO"
ISSUE_URL="https://github.com/$TARGET_REPO/issues/$ISSUE"

echo "agente: issue      $ISSUE_URL"
echo "agente: pr         $PR_REPO"
echo "agente: modelo     $MODEL"
echo "agente: repo       $REPO"
echo "agente: timeout    ${TIMEOUT_MIN} min"

# --- el issue -------------------------------------------------------------
TITLE="$(gh issue view "$ISSUE" -R "$TARGET_REPO" --json title --jq .title 2>/dev/null || true)"
BODY="$(gh issue view "$ISSUE" -R "$TARGET_REPO" --json body --jq .body 2>/dev/null || true)"
if [ -z "$TITLE" ]; then
  echo "agente: no pude leer la issue $ISSUE en $TARGET_REPO" >&2
  exit 1
fi
# The pull request title carries the issue number: that is what the
# upstream bot looks for ("<summary> (#N)"). TITLE keeps being the title of
# the ISSUE (the agent prompt uses it).
PR_TITLE="$TITLE (#$ISSUE)"

# --- el worktree ----------------------------------------------------------
# Worktree, no clon: comparte el object store con el repo, asi que no se
# descargan los 140 MB otra vez. Sale de upstream/main, no de la rama local,
# para que el diff del PR sea solo el cambio del agente.
BRANCH="${BRANCH_PREFIX}${ISSUE}"
WORK="$WORK_ROOT/issue-$ISSUE"
LOG="$WORK_ROOT/issue-$ISSUE.log"

mkdir -p "$WORK_ROOT"
if [ -d "$WORK" ]; then
  echo "agente: trabajo previo en $WORK, lo limpio"
  git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || rm -rf "$WORK"
fi

git -C "$REPO" fetch --quiet origin 2>/dev/null || true
BASE_REF="origin/main"
if [ -n "$UPSTREAM" ]; then
  # Una ref propia, no FETCH_HEAD: FETCH_HEAD queda vacio con --quiet y el
  # worktree se cae. La URL, no el nombre: el remote puede llamarse distinto.
  if git -C "$REPO" fetch --quiet "https://github.com/$UPSTREAM" main:refs/remotes/agent/upstream-main 2>/dev/null; then
    BASE_REF="refs/remotes/agent/upstream-main"
  else
    echo "agente: no pude traer $UPSTREAM/main, uso origin/main" >&2
  fi
fi

echo "agente: preparo el worktree $WORK desde $BASE_REF"
git -C "$REPO" worktree add --detach "$WORK" "$BASE_REF" || {
  echo "agente: no pude crear el worktree" >&2
  exit 1
}
git -C "$WORK" checkout -q -B "$BRANCH"

# Las reglas de la casa: el loop las instala en el worktree de cada issue en un
# archivo SIN SEGUIR (.house-rules.md) excluido con core.excludesFile por
# worktree. No se toca ningun archivo versionado: el arbol queda limpio, el
# rebase no necesita --autostash y no hay conflicto UU AGENTS.md posible.
# El modelo recibe la RUTA (no el contenido pegado) en el prompt.
HOUSE_RULES=""
if HOUSE_RULES="$(bash "$LOOP_DIR/bin/house-rules.sh" install "$WORK" 2>/dev/null)"; then
  echo "agente: reglas de la casa instaladas en $HOUSE_RULES"
else
  echo "agente: WARNING no pude instalar las reglas de la casa en $WORK" >&2
  HOUSE_RULES=""
fi

# --- el prompt ------------------------------------------------------------
PROMPT_TEMPLATE="$LOOP_DIR/prompts/agent-issue.md"
[ -f "$PROMPT_TEMPLATE" ] || PROMPT_TEMPLATE="$(dirname "$0")/../prompts/agent-issue.md"
PROMPT_FILE="$WORK_ROOT/issue-$ISSUE.prompt.md"
if [ -f "$PROMPT_TEMPLATE" ]; then
  # El cuerpo de la issue es texto libre, multilinea, con / & y comillas: sed
  # no lo aguanta. Python si.
  TITLE="$TITLE" BODY="$BODY" ISSUE="$ISSUE" BRANCH="$BRANCH" ISSUE_URL="$ISSUE_URL" \
    HOUSE_RULES="$HOUSE_RULES" \
    python3 - "$PROMPT_TEMPLATE" "$PROMPT_FILE" <<'PY'
import os, sys
tpl, out = sys.argv[1], sys.argv[2]
text = open(tpl, encoding="utf-8").read()
for key in ("TITLE", "BODY", "ISSUE", "BRANCH", "ISSUE_URL", "HOUSE_RULES"):
    text = text.replace("{{%s}}" % key, os.environ.get(key, ""))
open(out, "w", encoding="utf-8").write(text)
PY
else
  {
    printf '%s\n\n%s\n\nWork on %s in branch %s.\n' "$TITLE" "$BODY" "$ISSUE_URL" "$BRANCH"
    if [ -n "$HOUSE_RULES" ]; then
      printf '\nThe house rules of this loop are in %s. Read that file first: it is\n' "$HOUSE_RULES"
      printf 'the rulebook of this repository, and the repository rules (AGENTS.md and\n'
      printf 'skills/) are the source of truth when they disagree.\n'
    fi
  } > "$PROMPT_FILE"
fi
if [ ! -s "$PROMPT_FILE" ]; then
  echo "agente: el prompt quedo vacio" >&2
  exit 1
fi

# --- our own pull request of this branch ----------------------------------
# WHY IT IS KNOWN BEFORE THE BRAKE OF THE CLAIM: the brake asks about OUR
# OWN pull requests. Our own pull request does not take the claim of its
# issue away from us (the house rule), so the brake has to know WHICH pull
# request is ours (`--pr`). Without that, a re-run on a branch that already
# has our draft reads our own pull request as somebody else's claim and the
# turn is refused before the model writes a line.
#
# The fork is not needed to work (only to publish), so the lookup is made
# only when there is a fork, and its absence is not an error.
FORK_NAME=""
EXISTING_PR=""
if [ -n "$FORK" ]; then
  FORK_NAME="$(echo "$FORK" | sed -E 's#.*github.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
  # The pull request of this branch, if it already exists. The list is read
  # with `.[].number` and NOT with `.[0].number`: with an empty list the
  # latter prints "null", and "null" is not a pull request.
  EXISTING_PR="$(gh pr list -R "$PR_REPO" --head "$FORK_NAME:$BRANCH" --state all --json number --jq '.[].number' 2>/dev/null | head -1 || true)"
  case "$EXISTING_PR" in
    ''|*[!0-9]*) EXISTING_PR="" ;;
  esac
fi

# --- the claim is checked BEFORE the model starts ---------------------------
# WHY THIS IS HERE AND NOT ONLY AT THE PUBLISH: the race is lost BETWEEN the
# survey of the issues and the opening of the draft, because the bot of the
# upstream applies the label 'in progress' with a DELAY. The brake at the
# publish catches it, but by then the agent has written the code, the gate
# has compiled the scope and the hours are spent. Here the check is BEFORE
# the first line of code: a race that is already lost costs a call to GitHub
# and nothing else.
#
# The mode is 'selection': the loose house rule (an open pull request of
# another author that mentions the issue, plus the RECORD of the issue: its
# assignees and its comments). It is deliberately wider than the rule of the
# upstream (the lowest numbered pull request that claims the issue): a
# question that the rule of the upstream answers "ours" and the record of the
# issue answers "not free" is a question that we do not want to spend an
# agent on.
#
# Our own pull request of this branch is TOLD to the brake (`--pr`): it is
# not a claim against us, and the work is saved by the brake when the claim
# is gone, so this check does not throw anything away: it says it early.

CLAIM_CHECK_ARGS=(--issue "$ISSUE" --mode selection)
if [ -n "${WORK:-}" ]; then
  CLAIM_CHECK_ARGS+=(--work "$WORK")
fi
if [ -n "${BRANCH:-}" ]; then
  CLAIM_CHECK_ARGS+=(--branch "$BRANCH")
fi
if [ -n "${EXISTING_PR:-}" ]; then
  # Our own pull request of this branch is not a claim against us.
  CLAIM_CHECK_ARGS+=(--pr "$EXISTING_PR")
fi
CLAIM_CHECK_OUT="$(bash "$SCRIPT_DIR/claim-brake.sh" "${CLAIM_CHECK_ARGS[@]}" 2>&1)"
CLAIM_CHECK_RC=$?
if [ "$CLAIM_CHECK_RC" -ne 0 ]; then
  printf '%s\n' "$CLAIM_CHECK_OUT" | sed 's/^/agente: /' >&2
  echo "agente: el reclamo de $ISSUE NO esta libre: el modelo no arranca (rc=$CLAIM_CHECK_RC)" >&2
  printf '%s\n' "$CLAIM_CHECK_OUT" | grep -E '^(HOLDER|REASON|VERDICT)=' >&2 || true
  exit "$CLAIM_CHECK_RC"
fi
printf '%s\n' "$CLAIM_CHECK_OUT" | grep -E '^VERDICT=' | sed 's/^/agente: /' >&2 || true

# --- el agente ------------------------------------------------------------
cd "$WORK" || exit 1
START=$(date +%s)
echo "agente: corre el modelo (log: $LOG)"
timeout "${TIMEOUT_MIN}m" opencode run --standalone --auto -m "$MODEL" "$(cat "$PROMPT_FILE")" >"$LOG" 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
echo "agente: el modelo termino en $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s (rc=$RC)"

# --- lo que dispone el script (no el modelo) ------------------------------
# Lo que se entrega son los COMMITS, no el working tree: las reglas de la casa
# viven en un archivo sin seguir y excluido, asi que no ensucian el arbol.
COMMITS="$(git -C "$WORK" rev-list --count "$BASE_REF..HEAD" 2>/dev/null || echo 0)"
if [ "$COMMITS" -eq 0 ]; then
  echo "agente: el modelo no dejo ningun commit" >&2
  tail -40 "$LOG" >&2
  exit 1
fi
CHANGED="$(git -C "$WORK" diff --name-only "$BASE_REF..HEAD")"
echo "agente: el modelo dejo $COMMITS commit(s), archivos:"
echo "$CHANGED" | sed 's/^/  /'

LEFT="$(git -C "$WORK" status --porcelain | awk '{print $2}')"
if [ -n "$LEFT" ]; then
  echo "agente: quedaron cambios sin commitear en el arbol: $LEFT" >&2
fi

# Las reglas de la casa: el modelo no puede tocar las reglas ni el CI.
for f in $CHANGED; do
  case "$f" in
    AGENTS.md|.github/workflows/*|xtask/*|patches/*)
      echo "agente: el modelo toco $f, que no puede tocar" >&2
      exit 1 ;;
  esac
done

# --- rebase: the pull request is published on top of the CURRENT main -----
# The upstream CI runs on top of its main: a pull request with a stale base
# costs a red check. The base is fetched again (the copy fetched while
# preparing the worktree may be stale) and the branch is rebased onto it,
# BEFORE the narrow gate, so the gate validates the tree that is published.
echo "agente: rebase onto $BASE_REF"
if [ "$BASE_REF" = "refs/remotes/agent/upstream-main" ]; then
  git -C "$REPO" fetch --quiet "https://github.com/$UPSTREAM" main:refs/remotes/agent/upstream-main 2>/dev/null \
    || echo "agente: could not fetch $UPSTREAM/main again; rebasing onto the local copy" >&2
else
  git -C "$REPO" fetch --quiet origin 2>/dev/null \
    || echo "agente: could not fetch origin again; rebasing onto the local copy" >&2
fi
# The tree is clean: the house rules live in an untracked, excluded file, so
# there is nothing to stash and no `--autostash` (an autostash that is not
# popped back leaves the branch with a dirty tree and, in the worst case, an
# orphan stash that conflicts with `main`). If the rebase fails, the abort
# leaves the branch as it was AND the publication stops: a branch that is NOT
# on top of the base cannot be published (the narrow gate would have
# validated a tree that is not the published one, and the pull request would
# be born red). The branch stays local and the turn reports it.
if git -C "$WORK" rebase "$BASE_REF"; then
  echo "agente: rebase ok onto $BASE_REF"
else
  echo "agente: the rebase onto $BASE_REF failed: nothing is published" >&2
  git -C "$WORK" rebase --abort 2>/dev/null || true
  exit 9
fi

# El gate angosto: el crate que se toco. El gate COMPLETO lo corre el CI.
CRATE=""
for f in $CHANGED; do
  case "$f" in
    crates/*/*) c="crates/$(echo "$f" | cut -d/ -f2)"; [ -n "$c" ] && CRATE="$c"; break ;;
  esac
done
if [ -n "$CRATE" ]; then
  PKG="$(grep -m1 '^name *=' "$WORK/$CRATE/Cargo.toml" 2>/dev/null | sed -E 's/.*=[[:space:]]*"?([^"]*)"?/\1/')"
  echo "agente: gate angosto: fmt + test -p $PKG"
  ( cd "$WORK" && cargo fmt --all -- --check ) || { echo "agente: fmt FALLO" >&2; exit 1; }
  ( cd "$WORK" && cargo test -p "$PKG" ) || { echo "agente: el test del crate FALLO" >&2; exit 1; }
else
  echo "agente: no toco ningun crate, no hay gate angosto que correr"
fi

if [ "$PUBLISH" -eq 0 ]; then
  echo "agente: --no-publish: no publico nada"
  exit 0
fi

# The fork: the branch is pushed there.
[ -n "$FORK" ] || { echo "agente: no hay FORK en config.env, no publico" >&2; exit 1; }

# The pull request of this branch was already known BEFORE the brake of the
# claim (the brake asks about OUR OWN pull requests).
if [ -n "$EXISTING_PR" ]; then
  echo "agente: ya existe el pull request #$EXISTING_PR"
fi

# --- the brake of the claim ---
# The protocol of the claims is not an instruction to a model: the code that
# PUBLISHES runs the brake and does not publish when the brake does not
# answer 0. The brake asks THE RULE (bin/claim-race.sh, the one implementation
# of "who holds the claim") and then ACTS on the answer:
#   0  OK        the claim is ours (or the issue is free): publish.
#   10 TAKEN     somebody else holds it: our pull request lost the race, or
#                the issue was taken before we started. The work is SAVED and
#                the publish is REFUSED.
#   11 RESOLVED  the issue is not open any more: nobody won a race against
#                us, the work is MOOT for this issue but not lost. The publish
#                is REFUSED and the work is SAVED (it can be re-targeted).
#   12 UNKNOWN   GitHub could not be read: the brake does NOT know, and a
#                publish without a check is a duplicate waiting to happen. The
#                publish is REFUSED and the work is SAVED.
# The exit codes of the brake ARE the verdict: they are not translated.
#
# The work is saved BY the brake (bin/claim-salvage.sh behind it): the diff
# and the commits of the slot go to the logs of the loop and the diagnosis to
# the fork as a wip branch, so the hours of an agent are never thrown away
# because a race was lost. Losing a race costs the publish, not the work.
# The mode is 'auto': the race when we have a pull request of our own for
# the issue, the selection otherwise. The brake resolves it before it asks
# the rule (the rule knows 'selection', 'race' and 'funnel' only).
BRAKE_ARGS=(--issue "$ISSUE" --mode auto)
# The worktree and the branch are the context of the publisher. The brake
# uses them to SAVE the work when the claim is gone, and it works without
# them (it just cannot collect the patch), so they are optional here and the
# script keeps working with `set -u` when the caller does not provide them.
if [ -n "${WORK:-}" ]; then
  BRAKE_ARGS+=(--work "$WORK")
fi
if [ -n "${BRANCH:-}" ]; then
  BRAKE_ARGS+=(--branch "$BRANCH")
fi
if [ -n "${EXISTING_PR:-}" ]; then
  # Our own pull request of this branch is not a claim against us.
  BRAKE_ARGS+=(--pr "$EXISTING_PR")
fi
BRAKE_OUT="$(bash "$SCRIPT_DIR/claim-brake.sh" "${BRAKE_ARGS[@]}" 2>&1)"
BRAKE_RC=$?
printf '%s\n' "$BRAKE_OUT" | sed 's/^/agente: /' >&2
if [ "$BRAKE_RC" -ne 0 ]; then
  echo "agente: el freno del reclamo dice $BRAKE_RC: no publico nada" >&2
  printf '%s\n' "$BRAKE_OUT" | grep -E '^(HOLDER|REASON|VERDICT)=' >&2 || true
  exit "$BRAKE_RC"
fi

# --- the brake of the line of the defaults ---
# The verdict is COMPUTED (defaults_verdict): the loop never writes the
# answer by hand and it never decides a "yes". A change of a default is left
# in the issue and escalated to a person (exit 7).
VERDICT="$(defaults_verdict "${AGENT_CHANGES_DEFAULT:-}" "$CHANGED")"
if [ "$VERDICT" != "no" ]; then
  defaults_brake
fi
echo "agente: la linea de los defaults: $VERDICT"

# --- the body of the pull request ---
# "Fixes #N" only when the issue lives in the repository where the pull
# request opens (otherwise the number points to another issue and the link
# lies); in the other case the task line and the MENTION "#N" (our claim
# guard reads it). And always, whether the pull request changes a default.
PR_BODY="$(pr_body "$ISSUE" "$ISSUE_URL" "$TARGET_REPO" "$PR_REPO" "$MODEL" "${PKG:-}" "$VERDICT")"
BODY_FILE="$WORK_ROOT/issue-$ISSUE.body.md"
printf '%s\n' "$PR_BODY" > "$BODY_FILE"
echo "agente: el cuerpo del pull request: $BODY_FILE"

# --- the pre-flight of the line of the defaults ---
# The body that is going to be published is checked BEFORE the push: a body
# without the line of the defaults never leaves this machine.
if bash "$SCRIPT_DIR/pr-defaults-line.sh" --body "$BODY_FILE"; then
  echo "agente: la linea de los defaults esta en el cuerpo: se puede publicar"
else
  echo "agente: the body does not state the line of the defaults: nothing is published" >&2
  exit 8
fi

# --- publicar: la rama y el draft PR (nunca el merge) ---------------------
echo "agente: publico la rama en $FORK_NAME"
git -C "$WORK" remote get-url fork >/dev/null 2>&1 || git -C "$WORK" remote add fork "$FORK"
# --force-with-lease es lo seguro: no pisa una rama que cambio otra persona.
# Pero falla si la rama remota NO existe (lease obsoleto), y en ese caso la
# rama es nueva y se puede crear sin --force.
if git -C "$WORK" push --force-with-lease fork "$BRANCH:$BRANCH" 2>/dev/null; then
  :
else
  REMOTE_SHA="$(git ls-remote "$FORK" "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')"
  if [ -z "$REMOTE_SHA" ]; then
    git -C "$WORK" push fork "$BRANCH:$BRANCH" || exit 1
  else
    echo "agente: la rama $BRANCH ya existe en el fork y cambio; no la piso" >&2
    exit 1
  fi
fi

# GitHub tarda unos segundos en ver la rama nueva: sin esto, `gh pr create`
# falla con "Head sha can't be blank".
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if gh api "repos/$FORK_NAME/git/ref/heads/$BRANCH" >/dev/null 2>&1; then break; fi
  sleep 3
done

PR_NUMBER="$EXISTING_PR"
if [ -z "$PR_NUMBER" ]; then
  echo "agente: abro el pull request en draft en $PR_REPO"
  # Se abre por la API REST y no por `gh pr create` (GraphQL): la mutacion
  # GraphQL ve la rama nueva del fork con 1-2 min de retraso y falla con
  # "Head sha can't be blank" aunque la rama ya este publicada.
  OUT=""
  for attempt in $(seq 1 10); do
    OUT="$(gh api -X POST "repos/$PR_REPO/pulls" \
      -f title="$PR_TITLE" \
      -f body="$PR_BODY" \
      -f head="$FORK_NAME:$BRANCH" -f base=main -F draft=true 2>&1)"
    if [ $? -eq 0 ]; then
      # The number of the pull request comes from the JSON of the REST API.
      # The old `sed` looked for a field "html" that the API does not have
      # (it is "html_url"), so it never found anything and the number was
      # never known.
      PR_NUMBER="$(printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
print(data.get("number") or "")' 2>/dev/null || true)"
      break
    fi
    case "$OUT" in
      *"already exists"*) PR_NUMBER=""; break ;;
    esac
    echo "agente: el PR no salio todavia (intento $attempt), reintento" >&2
    sleep 15
  done
  if [ -z "$PR_NUMBER" ]; then
    # The last resort: the list of the pull requests of this branch.
    PR_NUMBER="$(gh pr list -R "$PR_REPO" --head "$FORK_NAME:$BRANCH" --state all --json number --jq '.[].number' 2>/dev/null | head -1 || true)"
  fi
  case "$PR_NUMBER" in
    ''|*[!0-9]*)
      echo "agente: no pude saber el numero del pull request: the line of the defaults is not confirmed" >&2
      printf '%s\n' "$OUT" >&2
      exit 8
      ;;
  esac
  echo "agente: pull request: #$PR_NUMBER"
fi

# --- the post-flight of the line of the defaults ---
# The publication can fail: the pull request can be opened without the line
# (a body truncated, a bot that rewrote it). The line is CHECKED on the
# published pull request: if it is not there, the publication is NOT
# confirmed and the turn says so (exit 8).
PUBLISHED_BODY="$(gh pr view "$PR_NUMBER" -R "$PR_REPO" --json body --jq .body 2>/dev/null || true)"
if ! grep -q '^Changes a default:' <<<"$PUBLISHED_BODY"; then
  echo "agente: the line of the defaults is not confirmed on the pull request #$PR_NUMBER: nothing is published" >&2
  exit 8
fi
echo "agente: la linea de los defaults esta confirmada en el pull request #$PR_NUMBER"

# --- the end of the publication ---
echo "agente: pull request: https://github.com/$PR_REPO/pull/$PR_NUMBER"

echo "agente: listo en $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
