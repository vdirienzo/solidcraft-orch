#!/usr/bin/env bash
# loop.sh - control and diagnostics for the SolidCraft loop on this machine.
#
# The loop is a systemd *user* timer, one unit per slot:
#   solidcraft-loop.timer   -> fires solidcraft-loop@0.service (Type=oneshot)
#   solidcraft-loop@1.timer -> fires solidcraft-loop@1.service
#   solidcraft-loop@<n>.service -> one turn: bin/supervisor.sh -> opencode run
#                              --agent sc-orchestrator
# The queue of the gates has its own timer (solidcraft-loop-gate-queue.timer):
# it drains the requests that a slot leaves when another gate is alive.
# The gate runs in its own transient unit: solidcraft-gate-<issue>-<slug>.service
#
# Usage:
#   loop.sh status        timer, turn in flight, phase, gate verdict, quotas
#   loop.sh start         start the timer and enable it for the next boot
#   loop.sh stop          stop the timer (a turn in flight finishes on its own)
#   loop.sh stop --now    stop the timer and kill the turn in flight
#   loop.sh restart       stop + start
#   loop.sh park          soft stop: the loop keeps running but opens no new PRs
#   loop.sh unpark        undo park
#   loop.sh run-once      run one turn in the foreground, ignoring the timer
#   loop.sh doctor        missing variables and failed preconditions
#   loop.sh turn          the delta the last turn proposed
#   loop.sh logs [N]      last N lines of the service journal (default 40)
#   loop.sh err [N]       last N lines of today's error log
#   loop.sh gate          the gate verdict on its own
#   loop.sh gc            clean the disk now (--dry-run, --deep)
#   loop.sh docs          regenerate the loop documentation page (docs/index.html)
#   loop.sh guide         regenerate the visual guide and publish it to Vercel
#   loop.sh help
#
# Exit codes: 0 = healthy, 1 = something is wrong (status, doctor).
#
# Notes:
#   - "stop" only stops future turns. The supervisor of a running turn is not
#     touched, so a turn that is mid-gate keeps its work.
#   - "stop --now" kills the turn. The flock of the supervisor is released when
#     the process dies, so the next turn is not blocked.
#   - Messages are in Spanish (they are for the human); the code comments are
#     in English (they are for whoever maintains the script).

set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
STATE_FILE="$LOOP_DIR/state.json"
CONFIG_FILE="$LOOP_DIR/config.env"
GH_ENV_FILE="$LOOP_DIR/gh.env"
VERDICT_FILE="$LOOP_DIR/gate.verdict"
LEDGER_FILE="$LOOP_DIR/ledger.md"
BASE_FILE="$LOOP_DIR/baseline-failures.txt"
DISK_STATUS_FILE="$LOOP_DIR/disk.status"
PROMPTS_DIR="$LOOP_DIR/prompts"
TURN_DIR="$LOOP_DIR/logs/turns"
LOCK_FILE="$LOOP_DIR/.lock"
AGENT_DIR="${AGENT_DIR:-$HOME/.config/opencode/agents}"
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
TIMER="solidcraft-loop.timer"
SERVICE="solidcraft-loop.service"
SERVICE_TEMPLATE="solidcraft-loop@.service"
GATE_UNIT_PATTERN="solidcraft-gate-*"
# The loop runs one systemd unit per slot: solidcraft-loop@<slot>.service,
# driven by solidcraft-loop.timer (slot 0) and solidcraft-loop@1.timer (slot
# 1). The panel has to look at the slots: solidcraft-loop.service is a legacy
# unit that no timer starts any more.
SLOTS=(0 1)
# The queue of the gates has its own timer: it drains the requests that a
# slot leaves when another gate (or a CI) is alive. Without it a queued gate
# never runs.
GATE_QUEUE_TIMER="solidcraft-loop-gate-queue.timer"

# Variables that the systemd unit must define for the turn to work.
UNIT_VARS=(
  HOME PATH CARGO_TARGET_DIR LD_LIBRARY_PATH CHROME XKB_CONFIG_ROOT
  VK_ICD_FILENAMES DISPLAY SOLIDCRAFT_GPU SOLIDCRAFT_RENDERER
)

# Variables that config.env must define (quotas, paths, model).
CFG_VARS=(
  REPO GATE_WORKTREE EVIDENCE_WORKTREE BASELINE_FAILURES MODEL
  MAX_TURN_MIN MAX_TURNS_PER_DAY MIN_FREE_GB SKIP_FREE_GB MAX_LOAD
  MAX_PR_PER_DAY MIN_MINUTES_BETWEEN_PUBLISH MAX_WORK_MINUTES_PER_ISSUE
  GATE_TIMEOUT_MIN MAX_INFLIGHT_MIN UPSTREAM FORK FORK_OWNER
  ALLOW_NEW_PRS MAINT_THRESHOLD RETIRED_PRS RATE_LIMIT_COOLDOWN_MIN
  LOG_RETENTION_DAYS
)

# Agent files the orchestrator dispatches. A missing one kills the turn.
AGENT_FILES=(
  sc-orchestrator sc-triage sc-claim sc-implement sc-evidence sc-review
  sc-gate sc-publish
)

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'
  C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_OFF=""
fi

have() { command -v "$1" >/dev/null 2>&1; }

# slot_timer SLOT -> the timer that drives the slot
slot_timer() { if [[ "$1" == "0" ]]; then printf 'solidcraft-loop.timer'; else printf 'solidcraft-loop@%s.timer' "$1"; fi; }
# slot_service SLOT -> the unit of one turn of the slot
slot_service() { printf 'solidcraft-loop@%s.service' "$1"; }
# slot_lock SLOT -> the lock file that the supervisor of the slot takes
slot_lock() { printf '%s/.lock.%s' "$LOOP_DIR" "$1"; }

ok()   { printf '%sOK   %s %s\n' "$C_OK"   "$C_OFF" "$1"; }
bad()  { printf '%sFAIL %s %s\n' "$C_BAD"  "$C_OFF" "$1"; }
warn() { printf '%sWARN %s %s\n' "$C_WARN" "$C_OFF" "$1"; }
info() { printf '     %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
head1() { printf '\n== %s ==\n' "$1"; }

# cfg NAME [file] -> value of a KEY=VALUE line, empty when not found
cfg() {
  local name="$1" file="${2:-$CONFIG_FILE}" line
  [[ -f "$file" ]] || return 1
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file" 2>/dev/null | tail -n 1)
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  line="${line%% #*}"          # strip inline comments ("MAX_LOAD=24   # tope")
  line="${line%"${line##*[![:space:]]}"}"   # trim trailing blanks
  line="${line#\"}"; line="${line%\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

# unit_env NAME -> value of an Environment= line of the service unit
unit_env() {
  local name="$1" line
  [[ -f "$UNIT_DIR/$SERVICE" ]] || return 1
  line=$(grep -E "^Environment=${name}=" "$UNIT_DIR/$SERVICE" 2>/dev/null | tail -n 1)
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#Environment=${name}=}"
}

# verdict_field KEY -> value of a KEY= line of gate.verdict
verdict_field() {
  local key="$1"
  [[ -f "$VERDICT_FILE" ]] || return 1
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$VERDICT_FILE"
}

# disk_free_gb -> free space of the root filesystem, in GB (empty when unknown)
disk_free_gb() {
  df -BG --output=avail / 2>/dev/null | tail -n 1 | tr -dc '0-9'
}

sysd_active() {
  local out
  out=$(systemctl --user is-active "$1" 2>/dev/null)
  [[ -n "$out" ]] && printf '%s' "$out" || printf 'inactive'
}
sysd_enabled() {
  local out
  out=$(systemctl --user is-enabled "$1" 2>/dev/null)
  [[ -n "$out" ]] && printf '%s' "$out" || printf 'unknown'
}
sysd_prop() { systemctl --user show "$1" -p "$2" --value 2>/dev/null; }

# lock_free SLOT -> 0 when nobody holds the supervisor lock of the slot,
# 2 when the lock cannot be checked (no flock), 1 when it is held
lock_free() {
  local file
  file="$(slot_lock "${1:-0}")"
  have flock || return 2
  [[ -e "$file" ]] || return 0
  flock -n "$file" -c true 2>/dev/null
}

# ---------------------------------------------------------------- status ----
cmd_status() {
  local rc=0
  local slot timer svc timer_state timer_enabled svc_state lock_rc
  head1 "loop de SolidCraft"
  for slot in "${SLOTS[@]}"; do
    timer="$(slot_timer "$slot")"
    svc="$(slot_service "$slot")"
    timer_state=$(sysd_active "$timer")
    timer_enabled=$(sysd_enabled "$timer")
    svc_state=$(sysd_active "$svc")
    if [[ "$timer_state" == "active" && "$timer_enabled" == "enabled" ]]; then
      ok "slot $slot: timer $timer $timer_state ($timer_enabled)"
    else
      bad "slot $slot: timer $timer $timer_state ($timer_enabled) - este slot NO esta andando"
      rc=1
    fi
    if [[ "$svc_state" == "active" || "$svc_state" == "activating" ]]; then
      local started elapsed
      started=$(sysd_prop "$svc" ExecMainStartTimestamp)
      ok "slot $slot: vuelta en curso ($svc_state, desde $started)"
      info "pid del supervisor: $(sysd_prop "$svc" MainPID)"
      if [[ -n "$started" ]]; then
        elapsed=$(date -d "$started" +%s 2>/dev/null)
        [[ -n "$elapsed" ]] && info "hace $(( ( $(date +%s) - elapsed ) / 60 )) min de $(cfg MAX_TURN_MIN || echo 55) de presupuesto"
      fi
      info "la proxima vuelta dispara en cuanto termine esta (OnUnitInactiveSec=2min)"
    else
      lock_rc=0
      lock_free "$slot" || lock_rc=$?
      if [[ "$lock_rc" -eq 0 ]]; then
        info "slot $slot: sin vuelta en curso (esperando al proximo disparo del timer)"
      elif [[ "$lock_rc" -eq 2 ]]; then
        warn "slot $slot: no se puede comprobar el lock (falta flock)"
      else
        bad "slot $slot: sin vuelta en curso, pero el lock $(slot_lock "$slot") esta tomado: el supervisor quedo colgado"
        info "el lock se suelta solo cuando muere el proceso: loop.sh stop --now"
        rc=1
      fi
    fi
  done

  if have systemctl; then
    local sched
    sched=$(systemctl --user list-timers --all --no-pager 2>/dev/null | grep -E "solidcraft-loop(@[0-9]+)?\.timer" || true)
    [[ -n "$sched" ]] && info "$sched"
  fi

  head1 "estado del loop"
  # The state that the loop writes lives in the view of each slot: the
  # supervisor never writes state.json any more (it is the state of the loop
  # before the slots). Reading it here showed a frozen phase.
  local slot_view slot_seen=0
  for slot in "${SLOTS[@]}"; do
    slot_view="$LOOP_DIR/state/slot-$slot.json"
    [[ -f "$slot_view" ]] || continue
    slot_seen=1
    if have jq; then
      jq -r --arg s "$slot" '
        "slot \($s): fase \(.phase // "?")   issue #\(.issue // 0)   pr #\(.pr // 0)   rama \(if (.branch // "") == "" then "-" else .branch end)",
        "        modo \(.mode // "?")   revision: \(if (.review // "") == "" then "(sin veredicto)" else .review end)   gate: \(.gate_verdict // "sin veredicto")",
        "        en vuelo: \(if .in_flight then "issue #\(.in_flight.issue) hace \((now - .in_flight.started) / 60 | floor) min" else "ninguno" end)   reporte: \(if (.report.pending // false) then "pendiente (" + (.report.last // "?") + ")" else "al dia (" + (.report.last // "?") + ")" end)"
      ' "$slot_view" 2>/dev/null || warn "no se pudo leer $slot_view"
    else
      warn "falta jq: no se puede leer $slot_view"
    fi
  done
  [[ "$slot_seen" -eq 0 ]] && warn "no hay vista de slot en $LOOP_DIR/state: el loop no ha escrito su estado"

  if have jq; then
    local d0 quota pub
    d0=$(date -u -d "today 00:00" +%s 2>/dev/null || echo 0)
    quota=$(cfg MAX_PR_PER_DAY 2>/dev/null || echo "?")
    # The publications of the day are the union of the maps of the slots: a
    # slot adds its own publications to the map it inherited.
    pub=$(jq -s --argjson d0 "$d0" \
          '[.[] | (.published // {}) | .[] | .[]? | select(.at >= $d0)] | unique_by(.pr) | length' \
          "$LOOP_DIR"/state/slot-*.json 2>/dev/null || echo "?")
    [[ "$pub" == "?" ]] && pub=$(jq -r --argjson d0 "$d0" '[(.published // {}) | .[] | .[]? | select(.at >= $d0)] | length' "$STATE_FILE" 2>/dev/null || echo "?")
    info "publicaciones hoy: $pub de $quota"
    info "ALLOW_NEW_PRS=$(cfg ALLOW_NEW_PRS || echo '?') (0 = el loop no abre PRs nuevos)"
    if [[ -f "$STATE_FILE" ]]; then
      jq -r '"vueltas (contador heredado del loop entero): \(.counters.iterations)  (fallos \(.counters.failures), seguidos \(.counters.consecutive))"' \
         "$STATE_FILE" 2>/dev/null || warn "state.json no se pudo leer"
    fi
  else
    warn "no se puede leer el estado (falta jq)"
  fi

  head1 "gate"
  if [[ -f "$VERDICT_FILE" ]]; then
    local v st nf
    v=$(verdict_field VERDICT || echo "?")
    st=$(verdict_field GATE_STATUS || echo "?")
    nf=$(verdict_field NEW_FAILURES || echo "?")
    local gates
    gates=$(systemctl --user list-units "$GATE_UNIT_PATTERN" --all --no-pager 2>/dev/null \
            | awk '$3 == "active" || $3 == "activating" { n++ } END { print n+0 }')
    case "$v" in
      VERDE)     ok "gate $v (estado $st, $nf fallos nuevos)" ;;
      ROJO)      bad "gate $v (estado $st, $nf fallos nuevos)"; rc=1 ;;
      PENDIENTE)
        if [[ "$st" == "dead" ]]; then
          if [[ "${gates:-0}" -gt 0 ]]; then
            warn "gate $v (estado $st, $nf fallos nuevos) - el gate anterior murio; hay $gates gate(s) vivo(s), el veredicto saldra de ese"
          else
            warn "gate $v (estado $st, $nf fallos nuevos) - el gate anterior murio y no hay ninguno vivo"
          fi
        else
          warn "gate $v (estado $st, $nf fallos nuevos) - sigue corriendo"
        fi ;;
      *)         warn "gate $v (estado $st, $nf fallos nuevos)" ;;
    esac
    info "log: $(verdict_field GATE_LOG || echo '-')"
  else
    info "sin veredicto de gate ($VERDICT_FILE)"
  fi

  [[ "${gates:-0}" -gt 0 ]] && info "gates vivos: $gates"

  head1 "maquina"
  info "carga: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)  (tope $(cfg MAX_LOAD || echo '?'))"
  info "disco libre: $(df -h --output=avail / 2>/dev/null | tail -n 1 | tr -d ' ')  (minimo $(cfg MIN_FREE_GB || echo '?') GB)"
  local free_gb last_gc
  free_gb=$(disk_free_gb)
  last_gc=$(cfg LAST_RUN "$DISK_STATUS_FILE" || echo "sin limpieza todavia")
  info "disco: ${free_gb:-?} GB libres  (ultima limpieza: ${last_gc:-sin limpieza todavia})"

  if [[ -f "$LEDGER_FILE" ]]; then
    head1 "ultimas vueltas"
    tail -n 3 "$LEDGER_FILE" 2>/dev/null | cut -c1-170 | sed 's/^/  /'
  fi

  return $rc
}

# ---------------------------------------------------------------- doctor ----
cmd_doctor() {
  local rc=0
  local missing=()

  head1 "unit de systemd"
  if [[ -f "$UNIT_DIR/$SERVICE_TEMPLATE" ]]; then
    ok "$UNIT_DIR/$SERVICE_TEMPLATE"
  else
    bad "falta $UNIT_DIR/$SERVICE_TEMPLATE"; missing+=("unit file $SERVICE_TEMPLATE")
  fi
  if [[ -f "$UNIT_DIR/$SERVICE" ]]; then
    ok "$UNIT_DIR/$SERVICE"
  else
    bad "falta $UNIT_DIR/$SERVICE"; missing+=("unit file $SERVICE")
  fi
  local slot timer
  for slot in "${SLOTS[@]}"; do
    timer="$(slot_timer "$slot")"
    if [[ -f "$UNIT_DIR/$timer" ]]; then
      ok "$UNIT_DIR/$timer"
    else
      bad "falta $UNIT_DIR/$timer"; missing+=("unit file $timer")
    fi
  done
  if [[ -f "$UNIT_DIR/$GATE_QUEUE_TIMER" ]]; then
    ok "$UNIT_DIR/$GATE_QUEUE_TIMER"
  else
    bad "falta $UNIT_DIR/$GATE_QUEUE_TIMER"; missing+=("unit file $GATE_QUEUE_TIMER")
  fi
  if [[ -f "$UNIT_DIR/$TIMER" ]]; then
    ok "$UNIT_DIR/$TIMER"
  else
    bad "falta $UNIT_DIR/$TIMER"; missing+=("unit file $TIMER")
  fi
  if systemctl --user show-environment >/dev/null 2>&1; then
    ok "el user manager de systemd responde"
  else
    bad "systemctl --user no responde: el timer no puede arrancar"; missing+=("systemd user manager")
  fi
  local linger
  linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)
  if [[ "$linger" == "yes" ]]; then
    ok "Linger=yes (el timer sobrevive a un logout)"
  else
    warn "Linger=${linger:-desconocido}: el timer muere al cerrar sesion"
  fi

  head1 "variables del unit"
  local v val
  for v in "${UNIT_VARS[@]}"; do
    if val=$(unit_env "$v"); then
      ok "$v=${val}"
    else
      bad "$v no esta en Environment= del unit"; missing+=("unit: $v")
    fi
  done

  local tos budget
  tos=$(grep -E "^TimeoutStartSec=" "$UNIT_DIR/$SERVICE" 2>/dev/null | tail -n 1 | cut -d= -f2)
  budget=$(cfg MAX_TURN_MIN || echo 55)
  if [[ -n "$tos" ]]; then
    local tos_sec=$((tos / 1))
    if [[ "$tos" =~ ^[0-9]+$ ]] && [[ "$tos_sec" -ge $((budget * 60)) ]]; then
      ok "TimeoutStartSec=${tos}s >= presupuesto de ${budget} min"
    else
      bad "TimeoutStartSec=${tos}s es menor que el presupuesto de ${budget} min: systemd mataria la vuelta"
      missing+=("TimeoutStartSec del unit")
    fi
  fi

  head1 "variables de config.env"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    bad "falta $CONFIG_FILE"; missing+=("$CONFIG_FILE")
  else
    for v in "${CFG_VARS[@]}"; do
      if val=$(cfg "$v"); then
        ok "$v=$val"
      else
        bad "$v no esta en config.env"; missing+=("config.env: $v")
      fi
    done
  fi

  head1 "github"
  if [[ ! -f "$GH_ENV_FILE" ]]; then
    bad "falta $GH_ENV_FILE (el unit lo carga como EnvironmentFile opcional)"; missing+=("gh.env")
  elif val=$(cfg GH_TOKEN "$GH_ENV_FILE" 2>/dev/null) && [[ -n "$val" ]]; then
    ok "GH_TOKEN definido en gh.env (${#val} caracteres, no se muestra)"
  elif val=$(cfg GITHUB_TOKEN "$GH_ENV_FILE" 2>/dev/null) && [[ -n "$val" ]]; then
    ok "GITHUB_TOKEN definido en gh.env (${#val} caracteres, no se muestra)"
  else
    bad "gh.env no define GH_TOKEN: la vuelta no puede ni leer ni escribir en GitHub"
    missing+=("GH_TOKEN en gh.env")
  fi
  if have gh; then
    if gh auth status >/dev/null 2>&1; then
      ok "gh responde y esta autenticado"
    else
      bad "gh auth status falla"; missing+=("gh auth")
    fi
  else
    bad "gh no esta en el PATH"; missing+=("gh")
  fi

  head1 "opencode y modelo"
  if have opencode; then
    ok "opencode: $(command -v opencode)"
  else
    bad "opencode no esta en el PATH del usuario"; missing+=("opencode en el PATH")
  fi
  local model provider authout
  model=$(cfg MODEL || echo "")
  provider="${model%%/*}"
  if [[ -n "$model" ]]; then
    ok "MODEL=$model"
    if have opencode; then
      authout=$(opencode auth list 2>&1 || true)
      if printf '%s' "$authout" | grep -qi -- "$provider"; then
        ok "opencode tiene credenciales para el proveedor '$provider'"
      else
        bad "opencode no tiene credenciales para '$provider' (opencode auth list)"
        missing+=("opencode auth para $provider")
      fi
    fi
  else
    bad "MODEL no esta en config.env"; missing+=("config.env: MODEL")
  fi
  if have cargo; then
    ok "cargo: $(command -v cargo)"
  else
    bad "cargo no esta en el PATH (el gate no puede compilar)"; missing+=("cargo en el PATH")
  fi

  head1 "agentes y prompts"
  local a
  for a in "${AGENT_FILES[@]}"; do
    if [[ -f "$AGENT_DIR/$a.md" ]]; then
      ok "$AGENT_DIR/$a.md"
    else
      bad "falta $AGENT_DIR/$a.md"; missing+=("agent $a.md")
    fi
  done
  # An agent file that EXISTS is not an agent that opencode RESOLVES. A
  # permission rule without `resource` (the V2 schema asks for the three
  # fields) makes opencode drop the agent: the turn dies with "Agent not
  # found" and the loop loses three hours before anybody looks. The check
  # below is the one that sees it (gap G2, 26-10-2026).
  if [[ -x "$LOOP_DIR/bin/check-agents.sh" ]]; then
    local agents_out
    if agents_out="$(bash "$LOOP_DIR/bin/check-agents.sh" 2>&1)"; then
      ok "los agentes son validos y opencode los resuelve"
    else
      bad "agentes invalidos (opencode no los resuelve):"
      printf '%s\n' "$agents_out" | sed 's/^/      /'
      missing+=("agentes invalidos")
    fi
  fi
  if [[ -f "$PROMPTS_DIR/iteration.md" ]]; then
    ok "$PROMPTS_DIR/iteration.md"
  else
    bad "falta $PROMPTS_DIR/iteration.md"; missing+=("prompts/iteration.md")
  fi

  head1 "ficheros y rutas"
  for f in "$STATE_FILE" "$VERDICT_FILE" "$LEDGER_FILE" "$BASE_FILE"; do
    if [[ -f "$f" ]]; then
      ok "$f"
    else
      warn "falta $f"
    fi
  done
  local repo gw ew
  repo=$(cfg REPO || echo "$HOME/solidcraft")
  gw=$(cfg GATE_WORKTREE || echo "$HOME/solidcraft-gate")
  ew=$(cfg EVIDENCE_WORKTREE || echo "$HOME/solidcraft-evidence")
  for f in "$repo" "$gw" "$ew"; do
    if [[ -d "$f" ]]; then
      ok "$f (worktree)"
    else
      bad "falta el worktree $f"; missing+=("worktree $f")
    fi
  done

  head1 "graficos y navegador (para la evidencia y el gate)"
  local chrome display
  chrome=$(unit_env CHROME || cfg CHROME || echo "")
  if [[ -n "$chrome" && -x "$chrome" ]]; then
    ok "CHROME=$chrome"
  else
    warn "CHROME=${chrome:-sin definir} no es ejecutable: el web-offline-test del gate se saltea en silencio"
  fi
  display=$(unit_env DISPLAY || echo "")
  if [[ "$(sysd_active xvfb.service)" == "active" ]]; then
    ok "xvfb.service active (DISPLAY=${display:-:99})"
  else
    warn "xvfb.service no esta active: las capturas de la app fallan"
  fi

  head1 "precondiciones de una vuelta"
  local load minfree skipfree avail
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  minfree=$(cfg MIN_FREE_GB || echo 60)
  skipfree=$(cfg SKIP_FREE_GB || echo 25)
  avail=$(disk_free_gb)
  if [[ -n "${avail:-}" && "${avail:-0}" -ge "${minfree:-60}" ]]; then
    ok "disco: ${avail} GB libres (minimo ${minfree} GB)"
  elif [[ -n "${avail:-}" && "${avail:-0}" -ge "${skipfree:-25}" ]]; then
    warn "disco: ${avail} GB libres (por debajo de ${minfree} GB, por encima de ${skipfree} GB): se pueden limpiar caches"
  else
    bad "disco: ${avail:-0} GB libres (por debajo de ${skipfree:-25} GB): el loop se saltea la vuelta"
    missing+=("disco libre")
  fi
  if [[ -n "${load:-}" ]]; then
    if awk -v l="$load" -v m="$(cfg MAX_LOAD || echo 24)" 'BEGIN { exit !(l < m) }'; then
      ok "carga $load (tope $(cfg MAX_LOAD || echo 24))"
    else
      warn "carga $load (tope $(cfg MAX_LOAD || echo 24)): la vuelta se saltea"
    fi
  fi
  local turncap maxturns maxslots share cap lifetime day slot slotturns detail free_slots legacy
  # The daily cap counts the turns of TODAY, not the lifetime counter:
  # `.counters.iterations` counts every turn of the life of the loop and it
  # is never reset, so comparing it against MAX_TURNS_PER_DAY reported a
  # false FAIL ("vueltas hoy 488 >= tope 288") as soon as the machine
  # passed 288 turns in total, even with the day barely started.
  #
  # The count is the one of the supervisor (bin/supervisor.sh): one log per
  # turn, named <date>T<time>Z-<pid>-slot<n>.jsonl, with the date in UTC.
  # The cap is SPLIT between the slots: every slot stops when it reaches
  # its share of MAX_TURNS_PER_DAY, so the whole loop is done for the day
  # only when EVERY slot has reached its share.
  day="$(date -u +%F)"
  maxturns=$(cfg MAX_TURNS_PER_DAY || echo 288)
  maxslots=$(cfg MAX_SLOTS || echo 1)
  case "${maxturns:-}" in ''|*[!0-9]*) maxturns=288 ;; esac
  case "${maxslots:-}" in ''|*[!0-9]*) maxslots=1 ;; esac
  [[ "${maxslots:-0}" -ge 1 ]] || maxslots=1
  share=$(( maxturns / maxslots ))
  [[ "${share:-0}" -ge 1 ]] || share=1
  cap=$(( maxslots * share ))
  turncap=0
  detail=""
  free_slots=0
  for ((slot=1; slot<=maxslots; slot++)); do
    slotturns=$(find "$TURN_DIR" -maxdepth 1 -name "${day}*-slot${slot}.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    case "${slotturns:-}" in ''|*[!0-9]*) slotturns=0 ;; esac
    turncap=$(( turncap + slotturns ))
    if [[ "${slotturns:-0}" -lt "${share:-1}" ]]; then
      free_slots=$(( free_slots + 1 ))
    fi
    if [ -n "$detail" ]; then
      detail="${detail}, "
    fi
    detail="${detail}slot${slot}=${slotturns}"
  done
  if [[ "${free_slots:-0}" -eq 0 ]]; then
    bad "vueltas hoy $turncap >= tope $cap: el loop no arranca otra vuelta (los $maxslots slots llegaron a su parte de $share)"; missing+=("tope de vueltas por dia")
  else
    ok "vueltas hoy $turncap de $cap (por slot: $detail; tope por slot $share de $maxturns por dia)"
  fi
  # The logs of the old format (before the slots) belong to no slot, and the
  # supervisor does not count them either: they are said out loud so that the
  # number of the line above is not read as the number of logs of the day.
  legacy=$(find "$TURN_DIR" -maxdepth 1 -name "${day}*.jsonl" ! -name "*-slot*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  case "${legacy:-}" in ''|*[!0-9]*) legacy=0 ;; esac
  if [[ "${legacy:-0}" -gt 0 ]]; then
    info "vueltas de hoy con el nombre antiguo (sin slot): $legacy (el supervisor no las cuenta para el tope)"
  fi
  # The lifetime is the counter of the slots: they inherit the one of the
  # whole loop and keep counting from there.
  local lifetime=0
  if have jq; then
    local it iters
    for it in "$LOOP_DIR"/state/slot-*.json; do
      [[ -f "$it" ]] || continue
      iters=$(jq -r '.counters.iterations // 0' "$it" 2>/dev/null || echo 0)
      case "${iters:-0}" in ''|*[!0-9]*) iters=0 ;; esac
      [[ "$iters" -gt "$lifetime" ]] && lifetime="$iters"
    done
  fi
  [[ "$lifetime" -eq 0 ]] && lifetime=$(jq -r '.counters.iterations // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  info "vueltas totales desde el inicio del loop: $lifetime (no es un tope diario)"
  if [[ -f "$LOOP_DIR/.cooldown" ]]; then
    warn "cooldown activo hasta $(cat "$LOOP_DIR/.cooldown" 2>/dev/null) (rate limit)"
  fi
  # The report of the day is written by the supervisor in the view of each
  # slot: state.json is not written any more.
  local slot_view rpend rlast slot_id
  for slot_view in "$LOOP_DIR"/state/slot-*.json; do
    [[ -f "$slot_view" ]] || continue
    have jq || break
    slot_id=$(basename "$slot_view" .json)
    rpend=$(jq -r '.report.pending // false' "$slot_view" 2>/dev/null)
    rlast=$(jq -r '.report.last // "-"' "$slot_view" 2>/dev/null)
    if [[ "$rpend" == "true" ]]; then
      warn "el reporte diario de $slot_id esta pendiente (ultimoposted: $rlast): el supervisor no lo pudo postear"
      info "canal: https://github.com/vdirienzo/solidcraft/issues/1"
    else
      ok "reporte diario al dia ($rlast, $slot_id)"
    fi
  done
  local slot lock_rc svc
  for slot in "${SLOTS[@]}"; do
    lock_rc=0
    lock_free "$slot" || lock_rc=$?
    if [[ "$lock_rc" -eq 0 ]]; then
      ok "slot $slot: el lock del supervisor esta libre"
    elif [[ "$lock_rc" -eq 2 ]]; then
      warn "slot $slot: no se puede comprobar el lock (falta flock)"
    else
      svc=$(sysd_active "$(slot_service "$slot")")
      if [[ "$svc" == "active" || "$svc" == "activating" ]]; then
        ok "slot $slot: el lock lo tiene la vuelta en curso ($svc): normal"
      else
        warn "slot $slot: el lock $(slot_lock "$slot") esta tomado y no hay vuelta en curso ($svc): supervisor colgado"
      fi
    fi
  done

  head1 "resumen"
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "no falta nada: el loop puede correr una vuelta"
  else
    bad "faltan ${#missing[@]} cosa(s):"
    local m
    for m in "${missing[@]}"; do info "$m"; done
    rc=1
  fi
  return $rc
}

# ---------------------------------------------------------------- control ---
cmd_start() {
  local slot timer rc=0
  for slot in "${SLOTS[@]}"; do
    timer="$(slot_timer "$slot")"
    if systemctl --user start "$timer" 2>/dev/null; then
      systemctl --user enable "$timer" >/dev/null 2>&1
      ok "$timer arrancado y habilitado (queda en marcha tras un reinicio)"
    else
      bad "no se pudo arrancar $timer"
      rc=1
    fi
  done
  if systemctl --user start "$GATE_QUEUE_TIMER" 2>/dev/null; then
    systemctl --user enable "$GATE_QUEUE_TIMER" >/dev/null 2>&1
    ok "$GATE_QUEUE_TIMER arrancado (drena la cola de gates cada 2 min)"
  else
    warn "no se pudo arrancar $GATE_QUEUE_TIMER: las gates encoladas no se drainarian"
  fi
  info "la proxima vuelta dispara el servicio en ~2 min"
  return $rc
}

cmd_stop() {
  local now="${1:-}"
  local slot timer
  for slot in "${SLOTS[@]}"; do
    timer="$(slot_timer "$slot")"
    systemctl --user stop "$timer" 2>/dev/null
    ok "$timer parado: no hay mas vueltas nuevas"
  done
  systemctl --user stop "$GATE_QUEUE_TIMER" 2>/dev/null
  ok "$GATE_QUEUE_TIMER parado: la cola de gates ya no se drena"
  if [[ "$now" == "--now" ]]; then
    systemctl --user stop "$SERVICE" 2>/dev/null
    pkill -f 'opencode run --standalone' 2>/dev/null
    pkill -f 'bin/supervisor.sh' 2>/dev/null
    ok "vuelta en curso terminada (el lock del supervisor se suelta solo)"
  else
    info "la vuelta en curso sigue: termina sola. Usa 'loop.sh stop --now' para cortarla"
  fi
  info "para que no vuelva tras un reinicio: loop.sh disable"
}

cmd_enable() {
  local slot timer
  for slot in "${SLOTS[@]}"; do
    timer="$(slot_timer "$slot")"
    systemctl --user enable --now "$timer" >/dev/null 2>&1
    ok "$timer habilitado y en marcha"
  done
  systemctl --user enable --now "$GATE_QUEUE_TIMER" >/dev/null 2>&1
  ok "$GATE_QUEUE_TIMER habilitado y en marcha"
}

cmd_disable() {
  local slot timer
  for slot in "${SLOTS[@]}"; do
    timer="$(slot_timer "$slot")"
    systemctl --user disable --now "$timer" >/dev/null 2>&1
    ok "$timer deshabilitado: no vuelve a arrancar tras un reinicio"
  done
  systemctl --user disable --now "$GATE_QUEUE_TIMER" >/dev/null 2>&1
  ok "$GATE_QUEUE_TIMER deshabilitado"
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_park() {
  [[ -f "$CONFIG_FILE" ]] || { bad "no existe $CONFIG_FILE"; return 1; }
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
  if grep -q '^ALLOW_NEW_PRS=' "$CONFIG_FILE"; then
    sed -i 's/^ALLOW_NEW_PRS=.*/ALLOW_NEW_PRS=0/' "$CONFIG_FILE"
  else
    printf '\n# parked by loop.sh on %s\nALLOW_NEW_PRS=0\n' "$(date -Is)" >> "$CONFIG_FILE"
  fi
  ok "ALLOW_NEW_PRS=0: el loop sigue corriendo pero no abre issues ni PRs nuevos"
  info "trabaja solo sobre los PRs abiertos (modo maintenance). Volver: loop.sh unpark"
}

cmd_unpark() {
  [[ -f "$CONFIG_FILE" ]] || { bad "no existe $CONFIG_FILE"; return 1; }
  if grep -q '^ALLOW_NEW_PRS=' "$CONFIG_FILE"; then
    sed -i 's/^ALLOW_NEW_PRS=.*/ALLOW_NEW_PRS=1/' "$CONFIG_FILE"
  else
    printf '\nALLOW_NEW_PRS=1\n' >> "$CONFIG_FILE"
  fi
  ok "ALLOW_NEW_PRS=1: el loop vuelve a abrir issues y PRs"
}

cmd_run_once() {
  echo "== una vuelta en primer plano (sin timer) =="
  info "la vuelta vive hasta $(cfg MAX_TURN_MIN || echo 55) min; el gate puede tardar 40-90 min"
  bash "$LOOP_DIR/bin/supervisor.sh"
}

# last_json_block FILE -> the last ```json block of a turn log
last_json_block() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  have jq || return 1
  jq -r 'select(.type == "text") | .part.text // empty' "$f" 2>/dev/null \
    | awk '
        /^```json/ { inblock = 1; block = ""; next }
        /^```/     { if (inblock) { last = block; inblock = 0 } ; next }
        inblock    { block = block $0 "\n" }
        END        { if (last != "") printf "%s", last }
      '
}

cmd_turn() {
  local f block=""
  if [[ -n "${1:-}" ]]; then
    f="$1"
    block=$(last_json_block "$f")
    [[ -n "$block" ]] && info "log de la vuelta: $f"
  else
    while IFS= read -r f; do
      block=$(last_json_block "$f")
      [[ -n "$block" ]] && break
    done < <(ls -t "$TURN_DIR"/*.jsonl 2>/dev/null | head -n 5)
    [[ -n "$block" ]] && info "log de la vuelta: $f"
  fi
  if [[ -n "$block" ]]; then
    printf '%s\n' "$block"
  else
    echo "no se encontro un bloque json (delta) en los logs de vuelta"
    return 1
  fi
}

cmd_logs() {
  local n="${1:-40}" slot svc found=0
  for slot in "${SLOTS[@]}"; do
    svc="$(slot_service "$slot")"
    if journalctl --user -u "$svc" -n "$n" --no-pager 2>/dev/null; then
      found=1
    fi
  done
  [[ "$found" -eq 1 ]] || echo "no se pudo leer el journal de los servicios del loop"
}

cmd_err() {
  local n="${1:-40}" f
  f="$LOOP_DIR/logs/$(date +%F).err"
  [[ -f "$f" ]] || { echo "no hay $f"; return 1; }
  tail -n "$n" "$f"
}

cmd_gate() {
  if [[ -f "$VERDICT_FILE" ]]; then
    cat "$VERDICT_FILE"
  else
    echo "sin veredicto ($VERDICT_FILE)"
  fi
  if [[ -f "$LOOP_DIR/gate.pid" ]]; then
    info "gate pid $(cat "$LOOP_DIR/gate.pid" 2>/dev/null), sha $(cat "$LOOP_DIR/gate.sha" 2>/dev/null)"
  fi
  systemctl --user list-units "$GATE_UNIT_PATTERN" --all --no-pager 2>/dev/null | grep "solidcraft-gate-" || true
}

# cmd_gc [flags...] -> run the disk cleanup script with the given flags as they are
cmd_gc() {
  local script="$LOOP_DIR/bin/gc-disk.sh"
  if [[ ! -f "$script" ]]; then
    bad "el script de limpieza todavia no existe ($script)"
    info "sin ese script el loop no puede limpiar el disco a mano"
    return 1
  fi
  local rc=0
  bash "$script" "$@" || rc=$?
  return $rc
}

cmd_help() {
  awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print; next } else { exit } }' "$0"
}

# cmd_docs [flags...] -> regenerate the loop documentation page (docs/index.html)
cmd_docs() {
  local script="$LOOP_DIR/bin/docs-html.sh"
  if [[ ! -f "$script" ]]; then
    bad "el generador de la documentacion todavia no existe ($script)"
    return 1
  fi
  bash "$script" "$@" || return 1
  info "documentacion: $LOOP_DIR/docs/index.html"
}

# cmd_guide [commit message] -> regenerate the visual guide and publish it to Vercel
cmd_guide() {
  local script="$LOOP_DIR/bin/deploy-guide.sh"
  if [[ ! -f "$script" ]]; then
    bad "el script de la guia visual todavia no existe ($script)"
    return 1
  fi
  bash "$script" "$@" || return 1
}

case "${1:-status}" in
  status)   cmd_status ;;
  doctor)   cmd_doctor ;;
  start)    cmd_start ;;
  stop)     cmd_stop "${2:-}" ;;
  enable)   cmd_enable ;;
  disable)  cmd_disable ;;
  restart)  cmd_restart ;;
  park)     cmd_park ;;
  unpark)   cmd_unpark ;;
  run-once) cmd_run_once ;;
  turn)     cmd_turn ;;
  logs)     cmd_logs "${2:-40}" ;;
  err)      cmd_err "${2:-40}" ;;
  gate)     cmd_gate ;;
  gc)       shift; cmd_gc "$@" ;;
  docs)     cmd_docs "$@" ;;
  guide)    shift; cmd_guide "$@" ;;
  help|-h|--help) cmd_help ;;
  *)
    echo "comando desconocido: $1" >&2
    cmd_help >&2
    exit 2
    ;;
esac
