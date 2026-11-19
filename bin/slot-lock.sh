#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# slot-lock.sh - the lock of a slot, and the global lock of the heavy phase.
#
# WHY (30-10-2026): the orchestrator runs several agents at once and a cron
# wave can run at the same time as an interactive session. On the 30-10 the
# cron wave of 11:18 deleted the worktree of an agent that was working in
# it, because nothing stopped the wave from touching a slot that was not
# its own.
#
# The original loop had the answer and it is the same one used here: a LOCK
# PER SLOT. The lock of the slot 0 is .lock.0 and the lock of the slot 1 is
# .lock.1: two instances of the same slot can never run at the same time,
# and each one writes only in its own slot.
#
# TWO LOCKS:
#   --slot <name>    the lock of that slot. It is HELD for the whole life of
#                    the slot (the agent that took it releases it when it
#                    finishes). A slot whose lock is taken is a slot that
#                    somebody else owns: nobody touches it.
#   --heavy          the lock of the heavy phase (the compile of the gate,
#                    the full test suite). It is the lock that the original
#                    loop calls .heavy.lock: only ONE heavy phase at a time
#                    in the whole machine, because two gates do not finish
#                    twice as fast, they fight for the same cores.
#
# USAGE:
#   bash slot-lock.sh --slot <name> --take     # take it (exit 0) or fail (exit 1)
#   bash slot-lock.sh --slot <name> --release  # release it
#   bash slot-lock.sh --slot <name> --status   # 0 = free, 1 = taken
#   bash slot-lock.sh --heavy --take [--wait N]
#   bash slot-lock.sh --heavy --status
#   bash slot-lock.sh --list                   # the slots that are taken
#
# EXIT CODES:
#   0  the lock was taken / released / is free
#   1  the lock is taken by somebody else (or the heavy phase is busy)
#   2  bad usage
# ---------------------------------------------------------------------------
set -uo pipefail

# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOCK_DIR="$ORCH_DIR/locks"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

normalize_slot() {
  local raw="$1" out
  out="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | cut -c1-60)"
  case "$out" in
    ""|.|..) return 1 ;;
    *..*) return 1 ;;
    .*|-*) return 1 ;;
  esac
  printf '%s' "$out"
}

# The lock is a DIRECTORY, not a file: a directory can be created atomically
# (mkdir) and it can carry the identity of the owner inside it, so a slot
# that is taken can be told from a slot that is stale.
slot_dir() {
  local name
  name="$(normalize_slot "$1")" || return 1
  printf '%s\n' "$LOCK_DIR/slot-$name"
}

# The heavy lock is a TOKEN, and there are SEVERAL of them (why: one gate
# alone already uses 80% of the CPU of a 16-core box and 23 GB of RAM, so a
# second one fits in the RAM but not in the CPU: two gates at the same time
# take the same wall clock as one and finish later. The tokens are here for
# the OTHER heavy work that is not a gate: a release link, an app build for
# the evidence, a sweep. One token per slot, so two slots can do heavy work
# at the same time, and the number of tokens is the ceiling:
#
#   MAX_HEAVY_TOKENS (default 2)
#
# The gate itself does NOT take a token: it takes the SLOT lock, and the
# slots.sh calibrator is the one that decides whether a gate may start
# (gate_may_start). The tokens are for the work that is NOT the gate.
# The heavy lock is a TOKEN, and there are SEVERAL of them. WHY: the gate is
# NOT the heavy work any more (it has its own slot lock and its own
# calibration), and the heavy work that is left -- a release link, an app
# build for the evidence, a sweep -- is I/O and link bound, not CPU bound:
# two of them at the same time use different cores and finish sooner.
#
# The tokens are SHARED and COUNTED: there are MAX_HEAVY_TOKENS of them, and
# a caller takes the first free one. A token named after the caller would
# never collide, and then the ceiling would not be a ceiling at all.
heavy_dir() {
  printf '%s\n' "$LOCK_DIR/heavy"
}

# The first free token, or nothing when all of them are taken. The token
# that this caller takes is remembered in "$d" (the heavy dir), so the
# release knows which one to free.
heavy_free_token() {
  local t=0
  while [ "$t" -lt "$MAX_HEAVY_TOKENS" ]; do
    if mkdir "$LOCK_DIR/heavy-token-$t" 2>/dev/null; then
      printf '%s\n' "$LOCK_DIR/heavy-token-$t"
      return 0
    fi
    t=$(( t + 1 ))
  done
  return 1
}

MODE=""
TARGET=""
ACTION=""
WAIT=0
OWNER=""
# The token of the heavy lock: which slot asks for it. Two slots asking at
# the same time take two DIFFERENT tokens (there are MAX_HEAVY_TOKENS of
# them), and the third one waits.
# IT IS RESOLVED AFTER THE OPTIONS ARE PARSED: the owner (the label of the
# caller) arrives in the --owner option, and it is what names the token.
MAX_HEAVY_TOKENS="${MAX_HEAVY_TOKENS:-2}"
# The age a heavy token can reach before it is taken away from its dead owner:
# a gate that runs longer than its own ceiling (120 min) is already dead, and
# a token that nobody releases blocks every gate of the box.
HEAVY_STALE_MIN="${HEAVY_STALE_MIN:-180}"
# The number of heavy phases at the same time is the POLICY of the machine, not
# a number written in the code: the default of 2 is the one of the box with
# 62 GB, and this box has 15 GB, where two builds of the engine ask for ~10 GB
# of rustc between them and the OOM killer takes the agent's turn with them. The
# policy lives in the config.env of the machine; the environment still wins.
if [ -z "${MAX_HEAVY_TOKENS:-}" ]; then
  POLICY_FILE="${POLICY_FILE:-$HOME/.local/share/solidcraft-loop/config.env}"
  if [ -r "$POLICY_FILE" ]; then
    _mht="$(grep -E '^[[:space:]]*(export[[:space:]]+)?MAX_HEAVY_TOKENS=' "$POLICY_FILE" 2>/dev/null \
      | tail -n 1 | cut -d= -f2- | cut -d'#' -f1 | tr -d '"'"'" | tr -d '[:space:]')"
    [ -n "$_mht" ] && MAX_HEAVY_TOKENS="$_mht"
  fi
fi
OLDER_THAN="${SLOT_LOCK_STALE_MIN:-240}"
while [ $# -gt 0 ]; do
  case "$1" in
    --slot)   [ $# -ge 2 ] || { echo "slot-lock: --slot needs a name" >&2; exit 2; }
               MODE="slot"; TARGET="$2"; shift 2 ;;
    --heavy)  MODE="heavy"; shift ;;
    --take)   ACTION="take"; shift ;;
    --release) ACTION="release"; shift ;;
    --status) ACTION="status"; shift ;;
    --heartbeat) ACTION="heartbeat"; shift ;;
    --reap)   ACTION="reap"; shift ;;
    --owner)  [ $# -ge 2 ] || { echo "slot-lock: --owner needs a label" >&2; exit 2; }
               OWNER="$2"; shift 2 ;;
    --older-than) [ $# -ge 2 ] || { echo "slot-lock: --older-than needs the minutes" >&2; exit 2; }
               OLDER_THAN="$2"; shift 2 ;;
    --wait)   [ $# -ge 2 ] || { echo "slot-lock: --wait needs the seconds" >&2; exit 2; }
               WAIT="$2"; shift 2 ;;
    --list)   ACTION="list"; MODE="${MODE:-all}"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "slot-lock: unknown option: $1" >&2; exit 2 ;;
  esac
done

# The name of the token of the heavy lock: the name of the slot that asks
# for it (HEAVY_TOKEN_NAME), or the label of the owner (--owner). It is
# resolved HERE, after the options are parsed: before this, --owner had not
# been read yet and every caller asked for the same token.
HEAVY_TOKEN_NAME="${HEAVY_TOKEN_NAME:-${OWNER:-shared}}"

# --list does not need a slot: it lists every lock that is taken. It is the
# query an orchestrator makes BEFORE it decides that a slot is free.
if [ "$ACTION" = "list" ] && [ "$MODE" = "all" ]; then
  for l in "$LOCK_DIR"/slot-*; do
    [ -d "$l" ] || continue
    raw="${l##*/slot-}"
    since=""
    [ -f "$l/since" ] && since="$(cat "$l/since" 2>/dev/null)"
    owner="-"
    [ -f "$l/owner" ] && owner="$(cat "$l/owner" 2>/dev/null)"
    printf '%s\t%s\t%s\n' "$raw" "$since" "$owner"
  done
  [ -d "$LOCK_DIR/heavy" ] && printf 'heavy\t\n'
  for _l in "$LOCK_DIR"/heavy-token-*; do
    case "$_l" in *.path) continue ;; esac
    [ -d "$_l" ] || continue
    _own="-"
    [ -f "$_l/owner" ] && _own="$(cat "$_l/owner" 2>/dev/null)"
    _since=""
    [ -f "$_l/since" ] && _since="$(cat "$_l/since" 2>/dev/null)"
    printf 'heavy-token-%s\t%s\t%s\n' "${_l##*/heavy-token-}" "$_since" "$_own"
  done
  exit 0
fi

[ -n "$MODE" ] && [ -n "$ACTION" ] || {
  echo "slot-lock: usage: --slot <name>|--heavy with --take|--release|--status|--list" >&2
  exit 2
}

NOW_EPOCH="$(date -u +%s)"

lock_age_min() {
  local d="$1" s t
  s=""
  [ -f "$d/since" ] && s="$(cat "$d/since" 2>/dev/null)"
  [ -n "$s" ] || { printf '%s' "-1"; return 0; }
  t="$(date -u -d "$s" +%s 2>/dev/null)" || { printf '%s' "-1"; return 0; }
  printf '%s' "$(( (NOW_EPOCH - t) / 60 ))"
}

# The name of the owner of a lock, or '-' when it was taken without one.
lock_owner() {
  local d="$1" o=""
  [ -f "$d/owner" ] && o="$(cat "$d/owner" 2>/dev/null)"
  printf '%s' "${o:--}"
}

if [ "$MODE" = "heavy" ]; then
  d="$(heavy_dir)"
  case "$ACTION" in
    take)
      # LOS TOKENS VIEJOS SE APARTAN ANTES DE CONTAR (2026-11-19).
      #
      # Un token pesado cuyo dueño murió (el agente que tomo el token y
      # murio con el turno) bloquea TODOS los gates hasta que alguien lo
      # aparta a mano: con un solo token pesado, como el de esta caja, eso es
      # la fase pesada parada para siempre. El criterio es la EDAD, el mismo
      # que el de los locks de slot (el PID del token es el del script que lo
      # tomo, y ese script sale de inmediato).
      for _t in "$LOCK_DIR"/heavy-token-*; do
        [ -d "$_t" ] || continue
        _tage="$(lock_age_min "$_t")"
        if [ "$_tage" -ge 0 ] && [ "$_tage" -ge "$HEAVY_STALE_MIN" ]; then
          printf 'reaped: %s (owner %s, %s min old)\n' "${_t##*/}" "$(lock_owner "$_t")" "$_tage" >&2
          rm -rf "$_t" 2>/dev/null || true
        fi
      done
      # The token that this caller takes is remembered in the heavy dir, so
      # the release frees exactly that one.
      _tok=""
      if [ "$WAIT" -gt 0 ]; then
        n=0
        while [ "$n" -lt "$WAIT" ]; do
          _tok="$(heavy_free_token)" && break
          sleep 1; n=$(( n + 1 ))
        done
        if [ -z "$_tok" ]; then
          echo "slot-lock: the heavy phase is busy after ${WAIT}s" >&2
          exit 1
        fi
      else
        _tok="$(heavy_free_token)" || exit 1
      fi
      printf '%s\n' "$$" > "$_tok/pid" 2>/dev/null || true
      printf '%s\n' "$(date -u +%FT%TZ)" > "$_tok/since" 2>/dev/null || true
      printf '%s\n' "${OWNER:-heavy}" > "$_tok/owner" 2>/dev/null || true
      # The dir of the heavy lock records WHICH token this caller took, so
      # the release frees exactly that one. The dir is created here: it did
      # not exist, because the tokens live in their own dirs.
      mkdir -p "$d" 2>/dev/null || true
      printf '%s\n' "$_tok" > "$d/token" 2>/dev/null || true
      exit 0
      ;;
    release)
      # The token this caller took is the one recorded in "$d/token": the
      # release frees exactly that one and not the token of somebody else.
      # A lock with no "token" is the lock of the old version of this script
      # (a single dir): it is freed whole.
      if [ -f "$d/token" ]; then
        _tok="$(cat "$d/token" 2>/dev/null)"
        if [ -n "$_tok" ]; then
          rm -rf "$_tok" 2>/dev/null || true
        fi
      fi
      rm -rf "$d" 2>/dev/null || true
      exit 0
      ;;
    reap)
      # The heavy lock records the PID of the SCRIPT that took it, and that
      # script exits at once: the PID was dead by design and could never say
      # whether the heavy phase was alive. So the liveness here is the AGE
      # (the file "since"), exactly like the liveness of a slot lock. A
      # heavy lock with no "since" is an orphan of an older version of this
      # script: it can never be reaped by age, and it blocks every gate.
      age="$(lock_age_min "$d")"
      if [ "$age" -ge 0 ] && [ "$age" -ge "$OLDER_THAN" ]; then
        printf 'reaped: heavy (owner %s, %s min old)\n' "$(lock_owner "$d")" "$age"
        rm -rf "$d" 2>/dev/null || true
      elif [ "$age" -lt 0 ] && [ -d "$d" ]; then
        printf 'reaped: heavy (orphan without "since": the lock of an older script)\n'
        rm -rf "$d" 2>/dev/null || true
      fi
      # LOS TOKENS SUELTOS (2026-11-19): el dir "heavy" puede irse (lo suelta
      # un --release) y dejar el token tomados. El token es el lock, no el dir:
      # sin apartarlo, no hay token libre y ningun gate arranca.
      for _t in "$LOCK_DIR"/heavy-token-*; do
        [ -d "$_t" ] || continue
        _tage="$(lock_age_min "$_t")"
        if [ "$_tage" -ge 0 ] && [ "$_tage" -ge "$OLDER_THAN" ]; then
          printf 'reaped: %s (owner %s, %s min old)\n' "${_t##*/}" "$(lock_owner "$_t")" "$_tage"
          rm -rf "$_t" 2>/dev/null || true
        fi
      done
      exit 0
      ;;
    status)
      # The heavy phase is busy when every token is taken. The tokens are the
      # locks now: a caller that wants one takes a free one, and there are
      # MAX_HEAVY_TOKENS of them. The count is a COUNT, not a probe: a probe
      # that takes a token to see if there is one has a race with a real
      # caller that takes it at the same time.
      _used=0
      _t=0
      while [ "$_t" -lt "$MAX_HEAVY_TOKENS" ]; do
        [ -d "$LOCK_DIR/heavy-token-$_t" ] && _used=$(( _used + 1 ))
        _t=$(( _t + 1 ))
      done
      # The lock of the old version of this script (a single dir) also
      # counts: it is a heavy phase that is running.
      [ -d "$d" ] && [ ! -f "$d/token" ] && _used=$(( _used + 1 ))
      if [ "$_used" -ge "$MAX_HEAVY_TOKENS" ]; then
        exit 1
      fi
      exit 0
      ;;
    list)
      [ -d "$d" ] && printf 'heavy\n'
      for _l in "$LOCK_DIR"/heavy-token-*; do
        case "$_l" in *.path) continue ;; esac
        [ -d "$_l" ] && printf 'heavy-token\t%s\n' "${_l##*/heavy-token-}"
      done
      exit 0
      ;;
  esac
fi

d="$(slot_dir "$TARGET")" || {
  echo "slot-lock: the slot name is not usable: $TARGET" >&2
  exit 2
}

# --- the age of a lock ------------------------------------------------------
# WHY THIS EXISTS (30-10-2026): the lock recorded the PID of the SCRIPT that
# took it, and that script exits the moment it is done: the PID was dead by
# design, so "is the owner alive?" could never be answered and every lock
# looked stale. Four locks of a dead wave then ate every slot and the
# calibrator reported free_slots=0 with an idle machine.
#
# So the liveness of a lock is NOT a PID: it is the AGE of the lock and the
# name of its owner. A lock that nobody refreshes for longer than the
# threshold is stale, and the orchestrator reaps it on purpose (--reap), with
# the evidence that its owner is gone.
NOW_EPOCH="$(date -u +%s)"

case "$ACTION" in
  take)
    if mkdir "$d" 2>/dev/null; then
      printf '%s\n' "$$" > "$d/pid" 2>/dev/null || true
      printf '%s\n' "$(date -u +%FT%TZ)" > "$d/since" 2>/dev/null || true
      [ -n "$OWNER" ] && printf '%s\n' "$OWNER" > "$d/owner" 2>/dev/null || true
      exit 0
    fi
    echo "slot-lock: the slot $TARGET is taken by somebody else" >&2
    exit 1
    ;;
  release)
    rm -rf "$d" 2>/dev/null || true
    exit 0
    ;;
  status)
    [ -d "$d" ] && exit 1 || exit 0
    ;;
  # The owner of a long job refreshes its lock: the lock stays alive while
  # the job works and goes stale when the job dies without saying goodbye.
  heartbeat)
    [ -d "$d" ] || { echo "slot-lock: the slot $TARGET is not taken" >&2; exit 1; }
    printf '%s\n' "$(date -u +%FT%TZ)" > "$d/since" 2>/dev/null || true
    exit 0
    ;;
  # The reaping of the locks whose owner is gone. It is NEVER automatic: the
  # orchestrator reaps a lock when it has the evidence that the owner died.
  reap)
    # A lock with no "since" is an ORPHAN of an older version of this
    # script: the age of a lock is its "since", so an orphan can never
    # expire by age and no command would ever free it. It stays in the
    # listing forever and in the way of the slot it names. The heavy lock
    # has had this case since it was found blocking every gate; a slot
    # lock has the same shape and the same fix.
    age="$(lock_age_min "$d")"
    if [ "$age" -ge 0 ] && [ "$age" -ge "$OLDER_THAN" ]; then
      printf 'reaped: %s (owner %s, %s min old)\n' "$TARGET" "$(lock_owner "$d")" "$age"
      rm -rf "$d" 2>/dev/null || true
    elif [ "$age" -lt 0 ] && [ -d "$d" ]; then
      printf 'reaped: %s (orphan without "since": the lock of an older script)\n' "$TARGET"
      rm -rf "$d" 2>/dev/null || true
    fi
    exit 0
    ;;
  list)
    for l in "$LOCK_DIR"/slot-*; do
      [ -d "$l" ] || continue
      raw="${l##*/slot-}"
      since=""
      [ -f "$l/since" ] && since="$(cat "$l/since" 2>/dev/null)"
      printf '%s\t%s\t%s\n' "$raw" "$since" "$(lock_owner "$l")"
    done
    [ -d "$LOCK_DIR/heavy" ] && printf 'heavy\t\n'
    exit 0
    ;;
esac
