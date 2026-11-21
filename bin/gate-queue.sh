#!/usr/bin/env bash
# ------------------------------------------------------------------
# gate-queue.sh - the queue of gates that are waiting for a build slot.
#
# WHY THIS EXISTS (2026-11-03): the gate takes a build token with
# "--take --wait 1800", so when the two slots of the box are busy it
# waits half an hour and then gives up with "no free build slot". With
# four gates pending and two slots, the queue never advanced: every
# gate expired on its own and had to be relaunched by hand.
#
# The queue lives in a file, the runner drains it, and the wait happens
# HERE and not in the gate: the runner is the only one that waits, so
# two gates can never fight over the same slot and a gate never dies
# with its own timeout while its turn is legitimate.
#
# USAGE:
#   bash gate-queue.sh --enqueue <issue> <sha>   -> adds a gate to the queue
#   bash gate-queue.sh --list                    -> shows the queue
#   bash gate-queue.sh --run [max_wait_minutes]  -> drains the queue
#
# The runner is safe to run from a cron every few minutes: it takes a
# lock (flock on gates/queue.flock) so only one runner works at a time.
# ------------------------------------------------------------------
set -uo pipefail

# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
# La mitad LOOP: el gate que compila (gate-quick.sh) vive ahi, y el
# worktree del publisher tambien. Antes este script no la nombraba, y con
# "set -u" usarlo sin definirla mataba el script en la mitad.
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
BIN="$ORCH_DIR/bin"
QUEUE="$ORCH_DIR/gates/queue.txt"
# El lock es un flock sobre un ARCHIVO, no un mkdir (2026-11-21). El
# mkdir dependia de un trap para borrarse y de "pgrep -f gate-queue.sh"
# para decidir si su dueno vivia; pgrep siempre encontraba el "sh -c" del
# cron y el subshell $(...) del propio runner, asi que el lock de un runner
# muerto (reinicio de la caja el 2026-11-21) no se libero nunca y la cola
# quedo parada desde el 2026-11-20 17:50. Un flock lo suelta el kernel
# cuando muere el proceso que tiene el descriptor: no hay lock viejo.
# Nombre NUEVO a proposito: el directorio queue.lock del esquema viejo no
# puede chocar con el archivo (ver OLD_LOCK_DIR en run).
LOCK="$ORCH_DIR/gates/queue.flock"
OLD_LOCK_DIR="$ORCH_DIR/gates/queue.lock"
LOGDIR="$ORCH_DIR/logs"
mkdir -p "$ORCH_DIR/gates" "$LOGDIR"

enqueue(){
  local issue="$1" sha="$2"
  # El mismo slot con el mismo sha no se encola dos veces. El mismo slot
  # con OTRO sha reemplaza la linea (2026-11-21): antes se descartaba el sha
  # nuevo y la cola gateaba el commit viejo, un verdict que no dice nada del
  # pull request tal como esta. La linea se reemplaza EN SU LUGAR: el slot
  # no pierde su turno por haber empujado otro commit.
  if [ -f "$QUEUE" ]; then
    local queued
    queued="$(awk -v i="$issue" '$1 == i {print $2; exit}' "$QUEUE")"
    if [ -n "$queued" ] || awk -v i="$issue" '$1 == i {f=1} END {exit !f}' "$QUEUE"; then
      if [ "$queued" = "$sha" ]; then
        echo "gate-queue: el slot $issue ya esta en la cola ($sha)"
        return 0
      fi
      local tmpq="$QUEUE.tmp.$$"
      awk -v i="$issue" -v s="$sha" '
        $1 == i { if (!done) { print i " " s; done=1 }; next }
        { print }' "$QUEUE" > "$tmpq" && mv "$tmpq" "$QUEUE"
      echo "gate-queue: el slot $issue ya estaba en la cola con ${queued:-sin sha}: reemplazado por $sha"
      return 0
    fi
  fi
  printf '%s %s\n' "$issue" "$sha" >> "$QUEUE"
  echo "gate-queue: encolado el gate del slot $issue ($sha)"
}

list(){
  if [ ! -f "$QUEUE" ] || [ ! -s "$QUEUE" ]; then echo "gate-queue: la cola esta vacia"; return 0; fi
  echo "gate-queue: $(wc -l < "$QUEUE" | tr -d ' ') gate(s) en la cola"
  sed 's/^/  /' "$QUEUE"
}

run(){
  local max_wait="${1:-240}"
  # Un runner a la vez: flock -n sobre el descriptor 9, que queda abierto
  # toda la vida del runner. Si el runner muere (kill -9, reinicio) el kernel
  # cierra el descriptor y el lock se suelta solo: no hace falta trap, ni
  # edad, ni adivinar con pgrep quien es el dueno. El archivo NO se borra al
  # salir: borrarlo dejaria a un runner con flock sobre un inodo huerfano y
  # a otro con flock sobre el archivo nuevo, dos runners a la vez.
  if ! exec 9>>"$LOCK"; then
    echo "gate-queue: no pude abrir el lock $LOCK" >&2
    return 1
  fi
  if ! flock -n 9; then
    exec 9>&-
    echo "gate-queue: otro runner esta trabajando (lock $(basename "$LOCK"))"
    return 0
  fi
  # LA TRANSICION: un runner del esquema viejo (mkdir) que murio deja el
  # directorio queue.lock. Ya no bloquea a nadie (el lock es otro archivo),
  # pero se borra para que nadie lo lea como "hay un runner". rmdir solo
  # borra un directorio vacio, que es lo que dejaba el esquema viejo.
  if [ -d "$OLD_LOCK_DIR" ] && rmdir "$OLD_LOCK_DIR" 2>/dev/null; then
    echo "gate-queue: se borro el lock viejo $(basename "$OLD_LOCK_DIR") (del esquema mkdir)"
  fi
  echo "gate-queue: $(date +%H:%M:%S) runner activo (espera maxima ${max_wait} min)"
  local waited=0
  local sin_worktree=0
  while [ -s "$QUEUE" ]; do
    # "build-slots: 0 used of 2" -> used=0, total=2. The old parse took the
    # LAST number for both, so it read "2 used of 2" and the queue never
    # started a gate even with the box empty.
    local used total
    # 9>&-: nada que lance el runner hereda el lock (ver el gate abajo).
    read -r used total <<< "$(bash "$BIN/build-slot.sh" --status 2>/dev/null 9>&- \
        | awk '{print $(NF-3), $NF}')"
    local free=$(( total - used ))
    # free is the number of FREE slots (total - used): there is no slot when
    # there are none free. The condition was the other way round and the
    # queue never started a gate with the box empty.
    if [ -z "$free" ] || [ -z "$total" ] || [ "$free" -le 0 ]; then
      echo "gate-queue: no hay slot libre todavia (esperando; van ${waited} min)"
      [ "$waited" -ge "$max_wait" ] && { echo "gate-queue: se agoto la espera de la cola"; break; }
      sleep 60; waited=$((waited+1)); continue
    fi
    local entry; entry="$(head -1 "$QUEUE")"
    local issue sha
    issue="$(printf '%s' "$entry" | awk '{print $1}')"
    sha="$(printf '%s' "$entry" | awk '{print $2}')"
    [ -z "$issue" ] && { sed -i '1d' "$QUEUE"; continue; }
    # THE WORKTREE OF THE SLOT, OR NOTHING (2026-11-17).
    #
    # The queue used to fall back to the main checkout: `cd
    # "$WORKTREES_DIR/issue-$issue" || cd "$SOLIDCRAFT_REPO"`. The gate then
    # compiled a tree that did NOT contain the change and wrote a verdict that
    # read as if it did - and bin/verify-pr.sh took it as "the gate of this
    # pull request". The gate itself refuses now (exit 5); the queue has to
    # refuse too, or it launches a gate that is going to fail.
    local wt="$WORKTREES_DIR/issue-$issue"
    if [ ! -d "$wt" ] && [ ! -d "$LOOP_DIR/work/issue-$issue" ]; then
      echo "gate-queue: el slot $issue no tiene worktree en $wt: NO lanzo el gate" >&2
      echo "gate-queue:   (un gate sobre el checkout principal compila un arbol sin el cambio)" >&2
      sin_worktree=$(( sin_worktree + 1 ))
      sed -i '1d' "$QUEUE"
      waited=0
      continue
    fi
    # the gate takes the token itself: there is a free slot right now
    echo "gate-queue: lanzando el gate del slot $issue ($sha) (hay $free de $total slots libres)"
    sed -i '1d' "$QUEUE"
    ( cd "$wt" 2>/dev/null || cd "$LOOP_DIR/work/issue-$issue" 2>/dev/null || cd "$SOLIDCRAFT_REPO"
      # The scoped gate gives the fmt phase 2% of the budget: with the 60 min default that
      # is 72 s, and `cargo fmt --all -- --check` over the whole workspace takes ~67 s
      # on an idle box and more when the agents are compiling. The phase is then killed
      # by timeout and the gate reports ROJO-SCOPE with fmt:fail and NO failed test:
      # a false red that keeps the pull request in draft for nothing. 120 min gives the
      # phase 144 s and it passes. (skill: solidcraft-gate-fmt-slice)
      #
      # El log del slot se AGREGA con un separador fechado (2026-11-21): antes
      # cada corrida lo pisaba y el rojo anterior se perdia al relanzar.
      printf '\n===== %s gate-queue: gate del slot %s (%s) =====\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "$issue" "$sha"
      GATE_QUICK_TIMEOUT_MIN="${GATE_QUICK_TIMEOUT_MIN:-120}" \
      bash "$BIN/gate.sh" "$issue" "$sha"
    ) >> "$LOGDIR/gate-queue-$issue.log" 2>&1 9>&- &
    # 9>&- arriba: el gate corre en segundo plano y dura mucho mas que el
    # runner. El lock cubre al RUNNER (como el mkdir, que se borraba al salir
    # el runner con los gates todavia corriendo); si el gate heredara el
    # descriptor, la cola quedaria cerrada hasta que terminara cada gate.
    sleep "${GATE_STAGGER:-90}"   # delay medido: con 90 s el 2do gate encuentra el sccache caliente
    waited=0
  done
  echo "gate-queue: $(date +%H:%M:%S) runner terminado; cola: $( [ -s "$QUEUE" ] && wc -l < "$QUEUE" | tr -d ' ' || echo 0) pendiente(s)"
  # THE VERDICT REACHES THE EXIT CODE (rule 7).
  #
  # The gate itself runs in the background: its verdict lands in
  # $LOOP_DIR/gates/<slot>/scope.verdict, which is where the rest of the
  # system reads it. What the QUEUE can answer is "could I launch it": a
  # queue that skipped a slot because there was no worktree has to say so,
  # or the cron is green over a gate that never ran.
  if [ "$sin_worktree" -gt 0 ]; then
    echo "gate-queue: $sin_worktree slot(s) sin worktree: NO se gatearon" >&2
    return 1
  fi
  return 0
}

case "${1:-}" in
  --enqueue) enqueue "${2:-}" "${3:-}" ;;
  --list)    list ;;
  --run)     run "${2:-240}"; exit $? ;;
  # WITHOUT ARGUMENTS IT RUNS THE QUEUE: this is how the cron calls it
  # (a cron job runs a script with no arguments), and a script that only
  # printed the usage would leave the queue standing still.
  "")        run 240; exit $? ;;
  *) echo "usage: gate-queue.sh --enqueue <issue> <sha> | --list | --run [min]" >&2; exit 2 ;;
esac
exit 0
