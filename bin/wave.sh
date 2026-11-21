#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wave.sh - the loop: close what finished, and start what is free.
#
# WHAT IT DOES, IN ONE TURN OF THE WAVE:
#   1. COLLECTS the slots in flight: the ones written in the state AND the
#      ones whose lock is taken. The state can lose a slot (a session that
#      died, a state that was rewritten) and the LOCK is the durable record
#      of "this slot is in flight": on 19-11 the state was empty and three
#      locks were taken, two of them finished and one alive.
#   2. CLOSES the slots whose work landed as a pull request AND whose agent
#      is not working anymore: the PR is verified, the target dir and the
#      worktree go, the lock is released. That is what frees the disk for
#      the next agent (5.6 GB of target and 700 MB of worktree per slot).
#   3. REAPS the locks of the slots that are dead without a pull request:
#      the residue of an agent that died. Its branch is in the fork: the work
#      is not thrown away, it is offered.
#   4. STARTS the slots that are free: it takes the next issue worth an
#      agent (bin/next-issue.py), prepares it (bin/prepare-slot.sh) and
#      dispatches its agent (bin/dispatch-slot.sh).
#
# THE RULE THAT MATTERS MOST: a slot whose agent is ALIVE is never touched.
# "The PR exists" is not "the work is done": an agent that opened the PR
# keeps working on it (the gate, the evidence). The liveness is a process
# working in the worktree of the slot or in its target dir (bin/slot-busy.sh).
#
# IT IS SAFE TO RUN IT TWICE: a slot that is already taken is not taken
# again, and the issue whose claim was lost is skipped by the arbiter.
#
# USAGE:
#   bash bin/wave.sh              # one turn of the wave
#   bash bin/wave.sh --dry-run    # what it would do, without doing it
#
# EXIT CODES:
#   0  the turn ended (with agents running, or with a reason why none did)
#   2  the state could not be read
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
WORKTREES_DIR="${WORKTREES_DIR:-$HOME/solidcraft-wt}"
UPSTREAM_REPO="${UPSTREAM_REPO:-tangency-labs/solidcraft}"
STALE_MIN="${SLOT_LOCK_STALE_MIN:-240}"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

# The siblings: the cron runs a COPY of this script from ~/.hermes/scripts/,
# where the siblings are NOT. They live in the orchestrator's bin. When this
# script runs from the repo, they are right here.
if [ -f "$HERE/claim-verify.sh" ]; then ORCH_BIN="$HERE"; else ORCH_BIN="${ORCH_BIN:-$ORCH_DIR/bin}"; fi

[ -f "$ORCH_DIR/state.json" ] || { echo "wave: no hay estado en $ORCH_DIR/state.json" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- 0. LA HIGIENE DE LA CAJA ------------------------------------------------
# Un agente que abre un navegador deja el Chrome vivo cuando su turno se
# corta: el proceso del MCP de chrome-devtools se va y el navegador queda
# huerfano, con 40 procesos y 3,7 GB de RAM en una caja de 15 GB. Dos veces
# se comio la memoria de la caja y el bucle dejo de despachar. El navegador de
# un MCP VIVO no se toca (el reaper solo mata los que quedaron sin dueno).
# El reaper solo mira los navegadores con el perfil del MCP
# (~/.cache/chrome-devtools-mcp/...) y solo mata el pid del navegador: nunca
# su padre (el 2026-11-21 una version rota mataba el `systemd --user` que lo
# adopto y GNOME cerraba la sesion; ver bin/kill-orphan-browsers.sh).
if [ -f "$ORCH_BIN/kill-orphan-browsers.sh" ]; then
  if [ -n "$DRY" ]; then
    echo "wave: los navegadores huerfanos se matan en el turno de verdad"
  else
    bash "$ORCH_BIN/kill-orphan-browsers.sh" 2>/dev/null | sed 's/^/wave: /'
  fi
fi

# --- 1. LOS SLOTS EN VUELO: el estado y los locks ---------------------------
bash "$ORCH_BIN/slot-lock.sh" --list > "$TMP/locks.tsv" 2>/dev/null
python3 - "$ORCH_DIR/state.json" "$TMP/locks.tsv" "$TMP/slots.json" "$WORKTREES_DIR" <<'PY'
import json, os, sys

state_path, locks_path, out_path, worktrees = sys.argv[1:5]
slots = {}
try:
    with open(state_path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    data = {}
for name, slot in (data.get("slots") or {}).items():
    if not isinstance(slot, dict):
        continue
    try:
        issue = int(name)
    except ValueError:
        continue
    slots[issue] = {
        "issue": issue,
        "branch": slot.get("branch") or "",
        "worktree": slot.get("worktree") or os.path.join(worktrees, f"issue-{issue}"),
        "target_dir": slot.get("target_dir") or "",
        "since": "",
        "in_state": True,
    }

# The locks are the durable record: a slot whose entry was lost from the
# state is still in flight if its lock is taken.
try:
    with open(locks_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except OSError:
    lines = []
for line in lines:
    parts = line.split("\t")
    name = parts[0].strip() if parts else ""
    since = parts[1].strip() if len(parts) > 1 else ""
    if not name or name.startswith("heavy"):
        continue
    try:
        issue = int(name)
    except ValueError:
        continue
    entry = slots.get(issue)
    if entry is None:
        slots[issue] = {
            "issue": issue,
            "branch": "",
            "worktree": os.path.join(worktrees, f"issue-{issue}"),
            "target_dir": "",
            "since": since,
            "in_state": False,
        }
    elif not entry["since"]:
        entry["since"] = since

# The worktrees ON DISK are the third source of slots: an agent that released
# its lock but died before deleting its worktree leaves 7 GB nobody knows
# about. The worktree is the proof that the slot existed.
try:
    for name in sorted(os.listdir(worktrees)):
        if not name.startswith("issue-"):
            continue
        try:
            issue = int(name[len("issue-"):])
        except ValueError:
            continue
        if issue in slots:
            continue
        slots[issue] = {
            "issue": issue,
            "branch": "",
            "worktree": os.path.join(worktrees, name),
            "target_dir": "",
            "since": "",
            "in_state": False,
        }
except OSError:
    pass

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump([slots[k] for k in sorted(slots)], fh)
PY

# --- 2. LOS PRs ABIERTOS (una sola llamada) ---------------------------------
gh pr list -R "$UPSTREAM_REPO" --state open --limit 200 \
  --json number,title,body,headRefName,author > "$TMP/prs.json" 2>/dev/null
[ -s "$TMP/prs.json" ] || echo "[]" > "$TMP/prs.json"
ME="$(gh api user --jq .login 2>/dev/null || echo vdirienzo)"
python3 "$ORCH_BIN/slot-prs.py" "$TMP/slots.json" "$TMP/prs.json" "$ME" > "$TMP/matched.tsv" 2>/dev/null

# --- 3. CERRAR, REAPAR O DEJAR CADA SLOT -----------------------------------
while IFS=$'\t' read -r ISSUE PR BRANCH OWNER; do
  [ -n "$ISSUE" ] || continue
  SLOT="$(python3 - "$TMP/slots.json" "$ISSUE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    slots = json.load(fh)
for slot in slots:
    if str(slot["issue"]) == sys.argv[2]:
        print(json.dumps(slot))
        break
PY
)"
  [ -n "$SLOT" ] || continue
  WT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('worktree',''))" "$SLOT")"
  TD="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('target_dir',''))" "$SLOT")"
  [ -n "$TD" ] || TD="$(bash "$ORCH_BIN/slot-target-dir.sh" --slot "$ISSUE" 2>/dev/null)"
  SINCE="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('since',''))" "$SLOT")"

  # ¿ALGUIEN TRABAJA EN ESTE SLOT? Un slot vivo no se toca.
  if bash "$ORCH_BIN/slot-busy.sh" "$WT" "$TD" >/dev/null 2>&1; then
    echo "wave: el slot $ISSUE esta VIVO (alguien trabaja en el): se lo deja"
    continue
  fi

  if [ -n "$PR" ] && [ "$OWNER" = "ours" ]; then
    echo "wave: el slot $ISSUE tiene el PR #$PR y nadie trabaja en el: se cierra"
    [ -n "$DRY" ] || bash "$ORCH_BIN/close-slot.sh" "$ISSUE" "$PR" || true
    continue
  fi

  if [ -n "$PR" ] && [ "$OWNER" = "other" ]; then
    # El claim lo tiene otro PR: nuestro trabajo (sin PR nuestro) se ofrece
    # en el PR que gano. El worktree se deja: ahi esta el trabajo.
    echo "wave: el slot $ISSUE lo tiene el PR #$PR de otro: el claim se perdio, se reapa el lock"
    [ -n "$DRY" ] || bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --reap --older-than 0 >/dev/null 2>&1
    continue
  fi

  # Sin PR: el slot esta muerto. El lock viejo se reap; el WORKTREE NO se
  # borra: ahi esta el trabajo sin publicar y una sesion lo puede rescatar
  # (docs/agent-handover.md).
  AGE=999999
  if [ -n "$SINCE" ]; then
    T="$(date -u -d "$SINCE" +%s 2>/dev/null || echo 0)"
    [ "$T" -gt 0 ] && AGE=$(( ( $(date -u +%s) - T ) / 60 ))
  fi
  # THE BRANCH GOES TO THE FORK BEFORE THE LOCK IS GIVEN BACK (2026-11-19).
  #
  # WHY: the wave assumed that the branch of a dead slot was already in the
  # fork ("its branch is in the fork: the work is not thrown away"). That
  # assumption broke twice on 19-11-2026: two agents of the slot 19523 ended
  # their turn without pushing, and the RED test with the fix died with the
  # worktree. So the wave pushes it itself, when it reaps a slot with no pull
  # request: a branch in the fork is the work that survives; a branch in a
  # worktree is the work that dies with the box.
  push_slot_branch() {
    [ -n "$DRY" ] && return 0
    _wt="$WORKTREES_DIR/issue-$1"
    _br="$(git -C "$_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ -n "$_br" ] || return 0
    [ "$_br" = "HEAD" ] && return 0
    [ "$_br" = "master" ] && return 0
    [ "$_br" = "main" ] && return 0
    if git -C "$_wt" push --quiet fork "$_br":"$_br" >/dev/null 2>&1; then
      echo "wave: la rama $_br del slot $1 esta en el fork (el trabajo no se pierde)"
    else
      git -C "$_wt" push --quiet --force-with-lease fork "$_br":"$_br" >/dev/null 2>&1 \
        && echo "wave: la rama $_br del slot $1 se pusheo al fork con --force-with-lease (la del fork era otra)" \
        || echo "wave: NO se pudo pushear la rama $_br del slot $1: el trabajo sigue solo en el worktree"
    fi
  }

  # EL SLOT APARECE COMO "GUARDADO", NO COMO "CORRIENDO" (2026-11-20).
  #
  # POR QUE: un slot reapado sin PR que queda en el estado como "running"
  # no lo retoma nadie: el paso 3b solo busca los slots "saved". Y el estado
  # decia "corriendo" con un agente que llevaba horas muerto: la memoria
  # del loop mintiendo es peor que la memoria vacia.
  mark_saved() {
    [ -n "$DRY" ] && return 0
    _wt="$WORKTREES_DIR/issue-$1"
    _br="$(git -C "$_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    _sha="$(git -C "$_wt" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$_sha" ] || return 0
    python3 "$ORCH_BIN/state-set.py" --merge slots "$1" "$(python3 - "$_br" "$_sha" <<'PY'
import json, sys
print(json.dumps({
    "status": "saved",
    "phase": "el agente se fue sin pull request: la rama y el commit quedan en el fork, el worktree sigue para retomarlo",
    "rescue": {"branch": sys.argv[1], "sha": sys.argv[2]},
}))
PY
)" >/dev/null 2>&1 || true
  }

  # NADIE TRABAJA EN EL Y NO HAY PR: EL AGENTE SE FUE, EL LOCK SE SUELTA YA.
  #
  # POR QUE (2026-11-20): la EDAD (240 min) era la regla que dejaba la caja
  # PARADA cuatro horas por cada agente que moria. El 19-11 el slot 19523
  # dejo el lock tomado a las 13:16 y la wave no despacho NADA hasta las
  # 20:10; el 20-11 el slot 19690 dejo la caja idle desde las 23:09 hasta
  # las 00:20. Tres horas y pico de noche sin procesar un solo issue, con la
  # maquina con 12 nucleos libres.
  #
  # La EDAD era para los slots VIVOS cuyo lock no se refresca; ese caso ya
  # esta arriba (el check de "alguien trabaja en el" se fue por el `continue`).
  # Aqui nadie esta trabajando: el proceso del agente no existe, y un lock
  # sin proceso es un lock que come la caja.
  if [ "$AGE" -lt "$STALE_MIN" ]; then
    echo "wave: el slot $ISSUE no tiene PR y NADIE trabaja en el (lock de ${AGE} min): se suelta el lock ya, el agente se fue"
    push_slot_branch "$ISSUE"
    mark_saved "$ISSUE"
    [ -n "$DRY" ] || bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --reap --older-than 0 >/dev/null 2>&1
    continue
  fi
  if [ "$AGE" -ge "$STALE_MIN" ]; then
    echo "wave: el slot $ISSUE no tiene PR y su lock tiene ${AGE} min: se reapa (el trabajo queda en la rama y en el worktree)"
    push_slot_branch "$ISSUE"
    mark_saved "$ISSUE"
    [ -n "$DRY" ] || bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --reap --older-than "$STALE_MIN" >/dev/null 2>&1
  elif [ -n "$SINCE" ]; then
    echo "wave: el slot $ISSUE no tiene PR todavia (lock de ${AGE} min): se lo deja"
  else
    echo "wave: el worktree del slot $ISSUE esta huerfano (sin lock y sin PR): se lo deja para que una sesion lo rescate"
  fi
done < "$TMP/matched.tsv"

# --- 3b. EL TRABAJO A MEDIAS, ANTES QUE LO NUEVO -----------------------------
#
# Un slot con el trabajo YA en el fork y sin pull request vale mas que un
# issue nuevo: el test RED ya esta escrito, el analisis ya esta hecho y el
# upstream no nos lo va a dar otra vez (el claim de 14 dias). El 20-11-2026
# los slots 19523 y 19690 tenian el trabajo a medias (el RED con sus numeros,
# el fix sin verificar, el analisis del fallo en solidcore) y la wave los
# esquivaba para despacho issues nuevos, que son casi todos de causa del
# kernel (aparcado).
#
# Asi que primero se termina lo que esta a medias: el slot se vuelve a
# preparar (el worktree y la rama ya estan, no se tocan) y se despacha.
FREE_SAVED="$(bash "$ORCH_BIN/slots.sh" 2>/dev/null | grep -oE 'free_slots=[0-9]+' | head -1 | cut -d= -f2)"
FREE="${FREE_SAVED:-0}"
if [ "${FREE:-0}" -gt 0 ]; then
  for SAVED in $(python3 - "$ORCH_DIR/state.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(0)
for name, slot in (data.get("slots") or {}).items():
    if not isinstance(slot, dict):
        continue
    if slot.get("status") != "saved":
        continue
    if slot.get("pr"):
        continue
    print(name)
PY
  ); do
    [ -n "$SAVED" ] || continue
    # LA CAJA MIDE: un slot libre, un agente. Esta caja cabe UNO (mem_slots=1),
    # asi que el trabajo a medias se retoma de a uno, no de a dos.
    [ "${FREE:-0}" -gt 0 ] || break
    if [ -n "$DRY" ]; then
      echo "wave: (seco) retomaría el slot $SAVED (el trabajo está a medias en el fork)"
      FREE=$((FREE - 1))
      continue
    fi
    BRIEF="$(bash "$ORCH_BIN/prepare-slot.sh" "$SAVED" "wave-$$" 2>/dev/null)"
    if [ -z "$BRIEF" ]; then
      echo "wave: el slot $SAVED no se pudo preparar: se sigue con los issues nuevos"
      continue
    fi
    LOG="$(bash "$ORCH_BIN/dispatch-slot.sh" "$SAVED" 2>/dev/null)"
    if [ -z "$LOG" ]; then
      echo "wave: el agente del slot $SAVED no arrancó"
      continue
    fi
    echo "wave: el agente del slot $SAVED arrancó con el trabajo a medias (log: $LOG)"
    FREE=$((FREE - 1))
  done
fi

# --- 4. EMPEZAR LOS SLOTS QUE ESTAN LIBRES ----------------------------------
FREE="$(bash "$ORCH_BIN/slots.sh" 2>/dev/null | grep -oE 'free_slots=[0-9]+' | head -1 | cut -d= -f2)"
FREE="${FREE:-0}"
echo "wave: free_slots=$FREE"
while [ "${FREE:-0}" -gt 0 ]; do
  ISSUE="$(python3 "$ORCH_BIN/next-issue.py" 2>/dev/null | head -1)"
  if [ -z "$ISSUE" ] || ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
    echo "wave: no hay ningún issue libre que valga un agente ahora"
    break
  fi
  if [ -n "$DRY" ]; then
    echo "wave: (seco) prepararía el slot $ISSUE"
    FREE=$((FREE - 1))
    continue
  fi
  BRIEF="$(bash "$ORCH_BIN/prepare-slot.sh" "$ISSUE" "wave-$$" 2>/dev/null)"
  if [ -z "$BRIEF" ]; then
    echo "wave: el issue #$ISSUE no se pudo preparar (el claim lo tiene otro): se prueba el siguiente"
    continue
  fi
  LOG="$(bash "$ORCH_BIN/dispatch-slot.sh" "$ISSUE" 2>/dev/null)"
  if [ -z "$LOG" ]; then
    echo "wave: el agente del slot $ISSUE no arrancó"
    continue
  fi
  echo "wave: el agente del slot $ISSUE arrancó (log: $LOG)"
  FREE=$((FREE - 1))
done
