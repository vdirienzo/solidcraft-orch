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
    echo "wave: el slot $ISSUE lo tiene el PR #$PR de otro: el claim se perdio, se reapa el lock"
    [ -n "$DRY" ] || bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --reap --older-than 0 >/dev/null 2>&1
    continue
  fi

  # Sin PR: el slot esta muerto. Si el lock es viejo, el lock se reapa.
  AGE=999999
  if [ -n "$SINCE" ]; then
    T="$(date -u -d "$SINCE" +%s 2>/dev/null || echo 0)"
    [ "$T" -gt 0 ] && AGE=$(( ( $(date -u +%s) - T ) / 60 ))
  fi
  if [ "$AGE" -ge "$STALE_MIN" ]; then
    echo "wave: el slot $ISSUE no tiene PR y su lock tiene ${AGE} min: se reapa (el trabajo queda en la rama)"
    [ -n "$DRY" ] || bash "$ORCH_BIN/slot-lock.sh" --slot "$ISSUE" --reap --older-than "$STALE_MIN" >/dev/null 2>&1
  else
    echo "wave: el slot $ISSUE no tiene PR todavia (lock de ${AGE} min): se lo deja"
  fi
done < "$TMP/matched.tsv"

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
exit 0
