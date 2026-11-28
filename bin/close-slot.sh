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
# The siblings live next to this script: the crontab runs the scripts of the
# repo (2026-11-21). ORCH_BIN is only the fallback for a copy of the script
# that runs outside bin/ without them.
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
# The machine's own paths know where the worktrees are (bin/paths.sh, 2026-11-24): the default
# below is only the fallback for a machine without that file.
if [ -z "${WORKTREES_DIR:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
fi
WORKTREES_DIR="${WORKTREES_DIR:-$HOME/solidcraft-wt}"
if [ -z "$SLOT" ]; then
  SLOT="{\"issue\": $ISSUE, \"branch\": \"\", \"worktree\": \"$WORKTREES_DIR/issue-$ISSUE\", \"target_dir\": \"\"}"
  echo "close-slot: el slot $ISSUE no esta en el estado: se cierra por la convencion" >&2
fi

# El worktree del slot se borra. A veces NO es un worktree del repo: un
# agente que reconstruyo el suyo (un clon) deja un directorio que
# "git worktree remove" no conoce, y se quedan 7 GB sin que nadie los diga.
remove_worktree() {
  local wt="$1"
  [ -n "$wt" ] || return 0
  git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
  if [ -d "$wt" ]; then
    rm -rf "$wt" >/dev/null 2>&1 || true
  fi
}

BRANCH="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('branch',''))" "$SLOT")"
WT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('worktree',''))" "$SLOT")"
TD="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('target_dir',''))" "$SLOT")"
[ -n "$TD" ] || TD="$(bash "$ORCH_BIN/slot-target-dir.sh" --slot "$ISSUE" 2>/dev/null)"

# EL GATE DEL SLOT NO SE CORRE DEBAJO DE UN CIERRE (2026-11-20).
#
# POR QUE: el gate compila en el worktree y en el target del slot. El chequeo
# de "alguien trabaja en este slot" mira los PROCESOS con el cwd ahi, y entre
# dos fases del gate no hay ninguno (el gate mata los sobras de cada fase
# antes de la siguiente): la wave cerraba el slot en ese hueco, le borraba el
# worktree y el target DEBAJO del gate, y el gate se moria con "Could not
# locate working directory". El veredicto salia ROJO-SCOPE y un PR sano
# parecia roto (le paso al PR #20017, del issue #19523, el 20-11-2026).
#
# EL SEÑAL: el gate del slot se invoca como "gate-quick.sh --slot <issue>",
# asi que un proceso con ese argv ES un gate corriendo de ese slot. Y un gate
# EN COLA (la cola de gates tiene la linea "<issue> <sha>") todavia no empezo
# pero va a empezar: tambien necesita el worktree y el target del slot.
gate_running() {
  pgrep -f "gate-quick\.sh --slot ${ISSUE}( |$)" >/dev/null 2>&1 && return 0
  pgrep -f "bin/gate\.sh ${ISSUE}( |$)" >/dev/null 2>&1 && return 0
  local queue="$ORCH_DIR/gates/queue.txt"
  [ -f "$queue" ] || return 1
  grep -qE "^${ISSUE}[[:space:]]" "$queue" && return 0
  return 1
}

# EL CERRADO: el target, el worktree, el brief y el lock. SOLO si no hay un
# gate corriendo: si lo hay, el slot sigue vivo (el PR ya quedo anotado) y la wave
# lo cierra en un turno posterior, cuando el gate haya escrito su veredicto.
#
# POR QUE LA LIMPIEZA ESTA ACA Y NO EN EL AGENTE (2026-11-21): el brief le
# pedia al agente borrar su worktree y su target antes de reportar. El gate del
# slot compila EN el worktree y EN el target del slot, y el pipeline encola ese
# gate DESPUES de que el agente abre el PR: si el agente borra el worktree, el
# gate arranca sobre un arbol que ya no esta, se muere con "Could not locate
# working directory" y escribe un veredicto ROJO de un PR sano (le paso al PR
# #20017 el 20-11-2026). Ademas el agente que borra su worktree se borra la
# evidencia con el (el gate necesita el arbol para escribir el veredicto).
#
# LO QUE SE BORRA (lo que ya no se usa porque el PR ya esta en GitHub):
#   - el target dir del slot (5,6 GB): es una cache, cargo la reconstruye;
#   - el worktree del slot (700 MB): el trabajo esta en la rama del fork;
#   - el brief del slot: nadie lo lee mas (se vuelve a renderizar con la
#     plantilla si el slot vuelve a abrirse);
#   - el lock del slot: se suelta para que la caja lo pueda tomar.
# LO QUE NO SE BORRA (la evidencia): logs/<issue>-verify.log, el veredicto del
# gate (gates/<issue>/ dentro del LOOP_DIR) y la rama.
cleanup_slot() {
  if gate_running; then
    echo "close-slot: el slot $ISSUE tiene un gate corriendo: NO se borran el target ni el worktree" >&2
    return 1
  fi
  [ -n "$TD" ] && rm -rf "$TD"
  remove_worktree "$WT"
  rm -f "$ORCH_DIR/prompts/agent-$ISSUE.md"
  bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --release >/dev/null 2>&1
  return 0
}

# 1. EL ARBITRO DEL CLAIM, CON NUESTRO PR.
VERDICT="$(bash "$ORCH_BIN/claim-verify.sh" "$ISSUE" $OUR_PR 2>&1)"
RC=$?
# EL GANADOR (2026-11-21): la linea de PERDIDO es "el PR #<nuestro> perdio
# contra el #<ganador>", asi que el primer #N era NUESTRO PR y el comentario
# publico nombraba mal al ganador. Se lee el numero que sigue a "contra el" (o
# a "gana el" de la linea del resumen); OCUPADO nombra al ganador primero.
WINNER="$(printf '%s\n' "$VERDICT" | grep -oE '(contra|gana) el #?[0-9]+' | head -1 | grep -oE '[0-9]+')"
[ -n "$WINNER" ] || WINNER="$(printf '%s\n' "$VERDICT" | grep -E '^VEREDICTO=OCUPADO' | grep -oE '#[0-9]+' | head -1 | tr -d '#')"

if [ "$RC" = "1" ]; then
  # EL CLAIM SE PERDIÓ: se cierra nuestro PR, se guarda el trabajo y se ofrece.
  if [ -n "$OUR_PR" ]; then
    # In English (2026-11-21): upstream's rule is "English throughout", and
    # this comment is public.
    gh pr close "$OUR_PR" -R "$UPSTREAM_REPO" --comment \
      "Closing this PR: #$WINNER claimed the same issue first, and the lowest-numbered open PR wins. \
The work stays on the branch \`$(git -C "$REPO" branch --list "fix-$ISSUE" --format='%(refname:short)' | head -1)\` \
in case it helps there." >/dev/null 2>&1
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
  cleanup_slot || true
  echo "close-slot: #$ISSUE perdió el claim contra el #$WINNER; el trabajo quedó en $SAVE y ofrecido en el PR ganador"
  exit 0
fi

if [ "$RC" != "0" ]; then
  echo "close-slot: el claim no se pudo verificar (rc=$RC): no se publica nada y no se tira nada" >&2
  exit 4
fi

# 2. EL PR ES NUESTRO: se verifica, se anota y el slot se cierra.
if [ -n "$OUR_PR" ]; then
  # El directorio de los logs puede no existir (una maquina nueva): sin el, la
  # redireccion falla, el `|| true` lo tapa y la evidencia se pierde.
  mkdir -p "$ORCH_DIR/logs"
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

if cleanup_slot; then
  python3 "$ORCH_BIN/state-set.py" --delete slots "$ISSUE" >/dev/null 2>&1
  echo "close-slot: #$ISSUE cerrado (PR #$OUR_PR); el target y el worktree fueron, la rama y el PR quedan"
else
  # EL GATE CORRIA: el slot sigue vivo. El PR ya quedo anotado arriba; el
  # target y el worktree se quedan (el gate los esta usando) y la wave
  # cierra el slot en un turno posterior.
  echo "close-slot: #$ISSUE tiene un gate corriendo: el slot sigue vivo hasta que el gate escriba su veredicto" >&2
fi
exit 0
