#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SolidCraft issue loop supervisor: ONE turn per invocation.
#
# The durable loop is systemd (solidcraft-loop.timer). Every turn runs a fresh
# `opencode run --standalone` -> context back to zero, never blocks waiting for
# the gate.
#
# This script owns the state: the model PROPOSES (a ```json block at the end of
# its answer) and `bin/state.py` DECIDES (it merges the delta and keeps the
# bookkeeping: in_flight, published, prs, mode, counters). The orchestrator
# never writes state.json nor ledger.md: that is the difference between a loop
# that respects its quotas and one that can grant them to itself.
#
# Deliberate deviations from the original spec:
#  1) `--auto`: without it, any permission that resolves to "ask" hangs the
#     turn forever in non-interactive mode. The agents' explicit `deny` rules
#     still apply: they are the sandbox, not a permission.
#  2) The gate is NOT killed on every turn: the design is asynchronous and the
#     next turn has to be able to read its log. It is detected by PID
#     (gate.pid) and killed only when it exceeds GATE_TIMEOUT_MIN (a gate that
#     is genuinely stuck).
#  3) The janitor only touches `ses_loop-*` sessions, and only the old ones.
#     The spec's `ses_[a-z0-9]+` pattern truncates the real ids (they carry
#     upper case) and would point at the user's own sessions.
#  4) A daily turn cap (cost) and a rate-limit cooldown: an unattended loop
#     against the API burns its budget in a single day.
#  5) The turn budget is 55 min (the floor, see below): the implement phase
#     is real TDD with cargo and 25 min killed it in the middle, leaving the
#     phase in `claimed` and the tree dirty.
#  6) A turn that is KILLED (the budget ran out, or systemd stopped the
#     service) is not left half-done: the phase is marked `failed` (or kept
#     as `gating` if a gate is still running) and the checkout is reset, so
#     the next turn does not inherit a half-done tree.
#  7) The QUICK gate (the fast one, 1-5 min) is launched by THIS script, not
#     by the model: the prompt asks for it and six real turns read that
#     instruction and never ran it. A gate that is only an instruction is a
#     gate that does not run. The launch is mechanical and best effort: it
#     never changes the phase and it never breaks the turn.
# ---------------------------------------------------------------------------
set -uo pipefail

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess. It is computed BEFORE the copy below (the copy lives in
# /tmp) and it is EXPORTED so the copy inherits it. The inherited value
# wins: the copy of the supervisor runs from /tmp, and there the checker
# is NOT next to it.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export SCRIPT_DIR

# --- run from a copy of ourselves ----------------------------------------
# bash reads a script LAZILY, by byte offset. If this file is edited while it
# is running, the next read lands in the middle of a different file and the
# execution goes garbage: two turns were lost that way (another agent editing
# this file mid-turn). A copy is immune to it: the running instance reads its
# own snapshot and the edits land in the next turn.
if [ -z "${LOOP_SUPERVISOR_IS_COPY:-}" ]; then
  _copy="$(mktemp "${TMPDIR:-/tmp}/loop-supervisor.XXXXXX")"
  if cp "$0" "$_copy" 2>/dev/null; then
    chmod +x "$_copy" 2>/dev/null || true
    LOOP_SUPERVISOR_IS_COPY=1 export LOOP_SUPERVISOR_IS_COPY
    exec "$_copy" "$@"
  fi
  rm -f "$_copy" 2>/dev/null || true
fi

# The directory of the loop: the state, the ledger, the logs and the scripts.
# It comes from the ENVIRONMENT when it is set, so the loop can be run over
# a COPY of it (the dry run of the parallel layout needs a second loop
# directory: the real one has a state and a ledger that must not be touched).
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
STATE="$LOOP_DIR/state.json"
LEDGER="$LOOP_DIR/ledger.md"
LOG_DIR="$LOOP_DIR/logs"
TURN_DIR="$LOG_DIR/turns"
mkdir -p "$LOG_DIR" "$TURN_DIR" "$LOOP_DIR/results" "$LOOP_DIR/state"

# --- the budget of the scoped gate -------------------------------------------
# The scoped gate gets the time that is LEFT in the turn, and never more: the
# gate stops itself at its timeout, so a gate that is given more time than the
# turn has is killed by systemd before it can write its verdict, and a killed
# gate is not a verdict (the turn is lost with it).
#
# The floor (GATE_QUICK_MIN_MIN) is the time the nextest phase needs to be
# worth anything: with less, the gate is left for the next turn, which has
# the whole budget. The ceiling (GATE_QUICK_TIMEOUT_MIN) is the time the gate
# needs at most: more of it is time the turn needs for something else.
gate_budget() {
  # gate_budget <minutes left in the turn> -> the minutes the gate gets
  local left="$1" budget
  budget=$(( left - 2 ))
  [ "$budget" -gt "${GATE_QUICK_TIMEOUT_MIN:-30}" ] && budget="${GATE_QUICK_TIMEOUT_MIN:-30}"
  [ "$budget" -lt "${GATE_QUICK_MIN_MIN:-12}" ] && budget="${GATE_QUICK_MIN_MIN:-12}"
  printf '%s\n' "$budget"
}

# --- the query of the budget --------------------------------------------------
# `supervisor.sh --gate-budget <minutes left>` prints the budget the scoped
# gate would get with that many minutes left in the turn. It is a query: it
# takes no lock, it runs no turn and it touches nothing. It exists so that the
# rule is executable and not only written: the test of the budget asks the
# supervisor, it does not read its source.
if [ "${1:-}" = "--gate-budget" ]; then
  # The configuration is CHECKED before it is sourced: a value with spaces
  # and no quotes breaks the source in the middle of the file, so the
  # variable is never set and the script goes on with HALF of the policy, in
  # silence (set -e is not on). The check only READS the file: the config.env
  # is read twice and sourced once. If it is broken, the script STOPS here.
  if [ -r "$LOOP_DIR/config.env" ]; then
    if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
      bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
    elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
      echo "supervisor: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
      exit 2
    fi
    set -a
    # shellcheck source=/dev/null
    . "$LOOP_DIR/config.env"
    set +a
  fi
  gate_budget "${2:-0}"
  exit 0
fi

# --- the preflight of the agents -----------------------------------------------
# An agent FILE that exists is not an agent that opencode RESOLVES: the V2
# schema asks every permission rule for the three fields (`action`,
# `resource`, `effect`) and an agent with a rule without `resource` is not
# registered. opencode then answers "Agent not found: sc-orchestrator", the
# turn dies before its first step, and the loop loses the turns without
# saying why: on the 26-10 that was 137 turns and 2 h 55 min of a loop that
# did nothing at all.
#
# `bin/check-agents.sh` already knows how to see it (it probes opencode with
# a model that does not exist: the agent is resolved BEFORE the model is
# looked up, so a broken agent says "Agent not found" and a good one says
# "Model unavailable"; no model is called, so it costs nothing). The probe
# of EVERY agent is eight processes of opencode: too much for every turn,
# enough for a doctor. Here only the agent of THIS turn is probed.
#
# It FAILS OPEN: a checker that is not there, or a probe that answers
# something unexpected, does not block the loop. It only blocks when the
# agent of this turn cannot be resolved: the file is missing, one of its
# rules has no `resource` (opencode does not register it) or opencode says
# "Agent not found" out loud.
agents_preflight() {
  local agent="$1" checker="$LOOP_DIR/bin/check-agents.sh" out rc
  if [ ! -f "$checker" ]; then
    echo "the checker of the agents is not there: $checker"
    return 0
  fi
  out="$(CHECK_AGENTS_RESOLVE="only:$agent" bash "$checker" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    return 1
  fi
  return 0
}

# --- the query of the preflight -------------------------------------------------
# `supervisor.sh --preflight [agent]` says whether opencode resolves the agent
# and exits 1 when it does not. It is a query: it takes no lock, it runs no
# turn and it touches nothing. It exists so that the rule is executable and
# not only written: the test asks the supervisor, it does not read its
# source.
if [ "${1:-}" = "--preflight" ]; then
  _preflight_agent="${2:-sc-orchestrator}"
  if agents_preflight "$_preflight_agent"; then
    echo "OK: opencode resolves the agent $_preflight_agent"
    exit 0
  fi
  echo "ERROR: opencode does not resolve the agent $_preflight_agent"
  exit 1
fi

# --- the digest of the slot ----------------------------------------------------
# The summary that the model reads FIRST.
#
# Why it exists (26-10): the model read the view of the slot WHOLE (12 kB)
# and the ledger WHOLE (375 kB, 1121 lines) in every turn. 3,41 M of tokens
# of the ledger in 24 h without a single new datum in it: the answer was
# always in the last fifteen lines. A denial is not the only way to waste a
# turn: a file read whole is context that never comes back.
#
# The digest carries the state of the slot and the last turns of the
# ledger, and it has a FIXED ceiling: DIGEST_LINES lines of the ledger,
# each one cut at DIGEST_CHARS. The rest is a pointer: the view is read
# with `jq` (one key at a time), the ledger only if it is really needed.
#
# The size is a constant of the code (not of config.env): the digest is
# read by the model, and a knob that can grow it is a knob that will.
DIGEST_LINES="${DIGEST_LINES:-15}"
DIGEST_CHARS="${DIGEST_CHARS:-300}"

# --- the other slots: the work in flight that is NOT yours -----------------
# Why (27-10): the model of the slot 1 read the rows of the ledger (a
# SHARED file) about the issue #7058 and spent a whole turn (5,6 min)
# trying to adopt an issue that the slot 0 had in flight. The digest said
# nothing about the other slots, so the only way to know was to read the
# ledger of the whole loop.
#
# The digest is the FIRST thing the model reads: if the work in flight of
# the other slots is not in it, the model cannot know it. The rows come
# from the views of the other slots (the same ones the guard of the
# worktree reads), so the model and the guard see the same fact.
#
# A slot is ALIVE if it is running right now (the lock of its turn is
# held) or if its view was written recently (a turn that started a while
# ago). The number of minutes is the one of the guard of the worktree.
render_other_slots() {
  local view id phase issue pr running alive lock mtime age now
  local found=0 inflight=""
  now="$(date +%s)"
  printf '\n## Los otros slots (NO son tuyos)\n\n'
  for view in "$LOOP_DIR"/state/slot-*.json; do
    [ -f "$view" ] || continue
    id="$(basename "$view" .json)"
    id="${id#slot-}"
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ "$id" = "$SLOT" ] && continue
    phase="$(jq -r '(.phase // "") | tostring' "$view" 2>/dev/null)"
    issue="$(jq -r '(.issue // 0) | tostring' "$view" 2>/dev/null)"
    pr="$(jq -r '(.pr // 0) | tostring' "$view" 2>/dev/null)"
    running="no"
    alive="no"
    lock="$LOOP_DIR/.lock.$id"
    if [ -e "$lock" ] && ! flock -n "$lock" true 2>/dev/null; then
      running="sí"
      alive="sí (corriendo)"
    fi
    mtime="$(stat -c %Y "$view" 2>/dev/null || echo 0)"
    case "${mtime:-0}" in ''|*[!0-9]*) mtime=0 ;; esac
    if [ "$mtime" -gt 0 ]; then
      age=$(( now - mtime ))
      [ "$age" -ge 0 ] || age=0
      if [ "$age" -lt $(( ${ISSUE_IN_FLIGHT_FRESH_MIN:-15} * 60 )) ]; then
        alive="sí"
      fi
    fi
    if [ "$found" -eq 0 ]; then
      printf '| slot | phase | issue | pr | vivo |\n'
      printf '|---|---|---|---|---|\n'
      found=1
    fi
    printf '| %s | %s | %s | %s | %s |\n' "$id" "$phase" "$issue" "$pr" "$alive"
    case "$phase" in
      selected|claimed|implemented|gating|gated)
        case "$issue" in ''|0) ;; *) inflight="$inflight"$'\n'"- slot $id → issue #$issue" ;; esac
        ;;
      # `failed` with a pull request keeps the issue reserved (the same
      # rule as the state and the guard of the worktree).
      failed)
        case "$issue:$pr" in :*|*:*0) ;; *) inflight="$inflight"$'\n'"- slot $id → issue #$issue" ;; esac
        ;;
    esac
  done
  if [ "$found" -eq 0 ]; then
    printf '(no hay otros slots)\n'
    return 0
  fi
  printf '\n'
  if [ -n "$inflight" ]; then
    printf '**Issue en vuelo en OTRO slot**: no lo adoptés, no lo triages,\n'
    printf 'no lo publiques y no toques su worktree:%s\n' "$inflight"
  else
    printf 'Ningún otro slot tiene un issue en vuelo.\n'
  fi
}

render_slot_digest() {
  local view="$1" lines="${2:-$DIGEST_LINES}" chars="${3:-$DIGEST_CHARS}"
  [ -f "$view" ] || return 0
  printf '# Digest del slot %s (%s)\n\n' "$SLOT" "$(date -u +%FT%TZ)"
  printf 'Lo escribe el supervisor antes de cada vuelta. Es el resumen:\n'
  printf '**no leas el ledger ni la vista JSON entera**. Si te falta un\n'
  printf 'campo, leé la vista con `jq` (una clave por vez).\n\n'
  printf '## Tu slot\n\n'
  jq -r '
    def v: if . == null then "-" else tostring end;
    def s: if . == null or . == "" then "-" else tostring end;
    def h: if . == null then "-" else (tostring[0:12]) end;
    "- phase: " + (.phase | v),
    "- issue: " + (.issue | v),
    "- branch: " + (.branch | v),
    "- branch_sha: " + (.branch_sha | h),
    "- pr: " + (.pr | v),
    "- review: " + (.review | s),
    "- gate_verdict: " + (.gate_verdict | s),
    "- scope_verdict: " + (.scope_verdict | s) + " (kind: " + (.scope_kind | v)
        + ", packages: " + (.scope_packages | v) + ")",
    # A deferral is NOT a verdict: the scope was POSTPONED (the complete
    # gate was alive and the machine was busy), it was never judged. The
    # digest has to say it, or the model reads a SKIP as a red scope.
    "- scope_deferred: " + (.scope_deferred | s),
    "- merge_verdict: " + (.merge_verdict.verdict | s) + " (pr "
        + (.merge_verdict.pr | v) + ", sha " + (.merge_verdict.sha | h) + ")",
    "- in_flight: " + (.in_flight | v),
    "- published_pr: " + (.published_pr | v),
    "- mode: " + (.mode | v),
    "- counters: iterations=" + (.counters.iterations | v)
        + " failures=" + (.counters.failures | v)
        + " consecutive=" + (.counters.consecutive | v),
    "- open_unmerged: " + (.open_unmerged | v),
    "- allow_new_prs: " + (.allow_new_prs | v),
    "- report: last=" + (.report.last | v) + " pending=" + (.report.pending | v),
    "- attempts: " + ((.attempts // {}) | to_entries
        | map("\(.key)=\(.value)") | join(" ")),
    "- triage: " + ((.triage // {}) | length | tostring) + " entradas",
    "- published: " + ((.published // {}) | length | tostring) + " hoy",
    "- prs: " + ((.prs // {}) | length | tostring) + " abiertos"
  ' "$view" 2>/dev/null
  render_other_slots
  printf '\n## Las últimas %s vueltas (ledger.md)\n\n' "$lines"
  # The rows are HISTORY: every row carries the `next` that the model of
  # that turn wrote. A row of the slot 1 said "next: kill the group of the
  # hung complete gate (pid 1594753, kill by PGID)" and that row stayed in
  # the digest of the following turns: the watchdog is the ONLY authority
  # that kills the complete gate (rule 32) and a model that kills it by
  # hand throws away the evidence of the watchdog's verdict.
  printf 'Las filas son HISTORIA: el `próximo` de una vuelta pasada NO es un\n'
  printf 'plan para ejecutar (el plan vigente es el de esta vuelta).\n\n'
  if [ -f "$LEDGER" ]; then
    tail -n "$lines" "$LEDGER" 2>/dev/null | cut -c1-"$chars"
  fi
  printf '\n\n## El detalle\n\n'
  printf -- '- la vista: %s (con `jq`, no entera)\n' "$view"
  printf -- '- el ledger: %s (`tail -n %s` sólo si de verdad lo necesitás)\n' \
    "$LEDGER" "$lines"
}

# The digest on disk: the same thing that `render_slot_digest` prints.
write_slot_digest() {
  local tmp="$SLOT_DIGEST.tmp.$$"
  if ! render_slot_digest "$SLOT_VIEW" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null || true
    log "warning: the digest of the slot $SLOT could not be written"
    return 0
  fi
  mv -f "$tmp" "$SLOT_DIGEST"
  log "the digest of the slot $SLOT is written ($SLOT_DIGEST, $(wc -c < "$SLOT_DIGEST") bytes)"
}

# --- the query of the digest ---------------------------------------------------
# `supervisor.sh --digest [slot]` prints the digest of the slot: what the
# model reads first. It is a query: it takes no lock, it runs no turn and
# it touches nothing. It exists so that the rule is executable and not
# only written: the test asks the supervisor, it does not read its source.
if [ "${1:-}" = "--digest" ]; then
  _digest_slot="${2:-0}"
  _digest_view="$LOOP_DIR/state/slot-$_digest_slot.json"
  # The log of the supervisor is noise in a query: it goes to stderr and it
  # does not touch the log of the turn (a query writes nothing).
  log() { echo "[$(date -Is)] $*" >&2; }
  if [ ! -f "$_digest_view" ]; then
    echo "there is no view of the slot $_digest_slot: $_digest_view" >&2
    exit 1
  fi
  SLOT="$_digest_slot"
  render_slot_digest "$_digest_view"
  exit 0
fi

# --- the slot of this invocation -------------------------------------------
# The slot comes from the ENVIRONMENT (the systemd instance puts it there:
# Environment=SLOT=%i), NEVER from config.env: the lock of the turn is taken
# BEFORE config.env is read, so a slot that came from config.env would be the
# same one for every instance and the slots would never run in parallel.
#
# The slot is the identity of the unit of work: the lock of the turn, the
# state and the view of the model are all per slot.
SLOT="${SLOT:-0}"
case "$SLOT" in
  ''|*[!0-9A-Za-z_-]*)
    echo "the slot name is not usable: $SLOT" >&2
    exit 2
    ;;
esac
SLOT_VIEW="$LOOP_DIR/state/slot-$SLOT.json"
SLOT_DIGEST="$LOOP_DIR/state/slot-$SLOT.digest.md"

# --- the message of the turn ------------------------------------------------
# The message of the turn is the HEADER of the slot followed by the prompt of
# the iteration. The header is the FIRST thing of the message: the prompt
# promises it ("the supervisor picks the slot and tells you which one at the
# very beginning of this message, in a header") and a model that does not find
# it reads the EXAMPLE of the prompt, whose slot was `0`: the slot 1 read the
# view of the slot 0, two slots on the same work item, and that is how the
# conflict of `main` of the 28-10-2026 happened.
#
# The header is per slot and the session is per slot too (`SID` carries the
# slot), so the prefix of the session is stable turn after turn: the cache of
# the prefix still hits.
compose_prompt() {
  printf 'SLOT: %s\nSLOT_VIEW: %s\nSLOT_DIGEST: %s\n\n%s' \
    "$SLOT" "$SLOT_VIEW" "$SLOT_DIGEST" \
    "$(cat "$LOOP_DIR/prompts/iteration.md")"
}

# --- the query of the message ------------------------------------------------
# `supervisor.sh --prompt [slot]` prints the message of the turn of that slot.
# It is a query: it takes no lock, it runs no turn and it touches nothing. It
# exists so that the rule is EXECUTABLE and not only written: the test asks
# the supervisor for the message and reads its first lines.
if [ "${1:-}" = "--prompt" ]; then
  _prompt_slot="${2:-$SLOT}"
  case "$_prompt_slot" in
    ''|*[!0-9A-Za-z_-]*)
      echo "the slot name is not usable: $_prompt_slot" >&2
      exit 2
      ;;
  esac
  SLOT="$_prompt_slot"
  SLOT_VIEW="$LOOP_DIR/state/slot-$SLOT.json"
  SLOT_DIGEST="$LOOP_DIR/state/slot-$SLOT.digest.md"
  compose_prompt
  exit 0
fi

# --- one turn at a time, per slot ------------------------------------------
# The lock is PER SLOT: the slots run in parallel and two turns of the SAME
# slot do not. With one slot (the default) this is the lock of today, with
# the name of the slot in it.
exec 9>"$LOOP_DIR/.lock.$SLOT"
flock -n 9 || { echo "turn already running for the slot $SLOT"; exit 0; }

# The locks of the short critical sections. They are opened once and locked
# only for the section that needs them: the state (the same one state.py
# takes), the heavy phase and the fetch.
exec 6>"$LOOP_DIR/.state.lock"
exec 7>"$LOOP_DIR/.fetch.lock"
exec 8>"$LOOP_DIR/.heavy.lock"

# --- environment ---------------------------------------------------------
# The values that the ENVIRONMENT overrides, saved BEFORE config.env is
# sourced: config.env does `set -a` and is sourced over the environment, so
# an override given from outside (a test, an operator) would be lost.
#
# This matters for MAX_LOAD: the load is a property of the MACHINE at this
# instant, and the ceiling has to be raisable without editing the config of
# the loop (the dry run of the parallel layout has to be reproducible while
# the machine is busy with a gate).
ENV_MAX_LOAD="${MAX_LOAD:-}"
# The configuration is CHECKED before it is sourced: a value with spaces
# and no quotes breaks the source in the middle of the file, so the variable
# is never set and the supervisor goes on with HALF of the policy, in
# silence (set -e is not on). The check only READS the file: the config.env
# is read twice and sourced once. If it is broken, the supervisor STOPS.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "supervisor: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi
set -a
# shellcheck source=/dev/null
. "$LOOP_DIR/config.env"
# shellcheck source=/dev/null
. "$LOOP_DIR/gh.env"
set +a
if [ -n "$ENV_MAX_LOAD" ]; then
  MAX_LOAD="$ENV_MAX_LOAD"
  export MAX_LOAD
fi
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.opencode/bin:${PATH}"
# The binary of OpenCode. It is a variable so that a test can replace it with
# a fake turn: the test of the token budget must not spend a real turn (nor
# touch the real repository), and the PATH alone cannot do it: the binary of
# OpenCode is in $HOME/.opencode/bin, which is BEFORE the inherited PATH.
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$REPO/target}"
# The compilation of the turns is bounded. Cargo compiles with one job per
# core by default, and the crate `engine` of this workspace is big: sixteen
# rustc of it at once is tens of gigabytes of anon memory. On the 26-10-2026
# the OOM killer killed a process of the GATE (the biggest cgroup of the
# machine, so the victim the kernel picked) while the loop was compiling at
# the same time, and the host has no swap. Eight jobs keep the compilation of
# a turn inside a budget that leaves room for the gate (which has a cgroup of
# its own and a limit of its own). The gate does NOT inherit this:
# `systemd-run` does not pass the environment of the caller to the unit, and
# the gate names its own (CARGO_BUILD_JOBS=4, see bin/start-gate.sh).
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"
GATE_WORKTREE="${GATE_WORKTREE:-$LOOP_DIR/../solidcraft-gate}"
# The cwd of /proc is ALWAYS resolved: the pattern that looks for the
# orphans of the gate has to be the real path, or a worktree written
# with a `..` in it would never match and the orphans would keep the
# memory of the machine.
[ -d "$GATE_WORKTREE" ] && GATE_WORKTREE="$(readlink -f "$GATE_WORKTREE")"
# The root of the worktrees of the issues. It is read ONCE, here, after
# config.env: the cleanup of a dead turn has to know the SAME root as the
# turn itself (a cleanup that looked at another root would leave the cargo of
# a quick gate alive, and it would keep the lock of the target dir).
WT_ROOT="${SOLIDCRAFT_WT_ROOT:-$HOME/solidcraft-wt}"
# The worktree of the quick gate when the worktree of the issue is not
# there: it is created when the gate runs and it is removed when it ends.
# It is empty the rest of the time.
QUICK_GATE_TEMP_WT=""

# The number of slots that run in parallel. It is 1 by default: the
# parallelism is enabled by the human, changing this value, never by default.
# With one slot the behavior is exactly the one of today (one lock, one
# worktree, no election).
MAX_SLOTS="${MAX_SLOTS:-1}"
case "$MAX_SLOTS" in ''|*[!0-9]*) MAX_SLOTS=1 ;; esac
[ "$MAX_SLOTS" -ge 1 ] || MAX_SLOTS=1

DAY="$(date -u +%F)"
JSONL="$LOG_DIR/$DAY.jsonl"
ERR="$LOG_DIR/$DAY.err"
COOLDOWN_FILE="$LOOP_DIR/.cooldown"
# The backoff of the TRANSPORT failures: its OWN file, because a broken
# connection is not an exhausted plan and must not wait for the quota's
# cooldown.
TRANSPORT_COOLDOWN_FILE="$LOOP_DIR/.cooldown-transport"
log() { echo "[$(date -Is)] $*" | tee -a "$ERR" >&2; }

log "=== turn $(date -u +%FT%H:%M:%SZ) ==="
# The turn has to WRITE on the upstream (the body of the PR, the comments,
# `gh pr ready`) and the PAT of gh.env cannot. gh prefers the environment
# over ~/.config/gh/hosts.yml, so the PAT LEAVES the turn and what is left
# is the OAuth classic of hosts.yml (scope `repo`): the loop is the AUTHOR
# of its own PRs and it has no write access upstream, so it cannot merge.
# LOOP_GH_WRITE_TOKEN_FILE: the escape hatch (a 0600 file OUTSIDE the dir).
if [ -n "${LOOP_GH_WRITE_TOKEN_FILE:-}" ] && [ -r "${LOOP_GH_WRITE_TOKEN_FILE:-}" ]; then
  export GH_TOKEN="$(tr -d '\r\n' < "$LOOP_GH_WRITE_TOKEN_FILE")"
  log "the turn writes with the token of ${LOOP_GH_WRITE_TOKEN_FILE}"
else
  unset GH_TOKEN GITHUB_TOKEN
  log "the turn writes with the OAuth of ~/.config/gh/hosts.yml"
fi

# --- the budget of the turn ------------------------------------------------
# A turn has to cover the IMPLEMENT phase: the implementer does real TDD
# with cargo (compile + run the tests) and the per-issue time-box is
# MAX_WORK_MINUTES_PER_ISSUE=45. With a budget of 25 min the turn was
# killed in the middle of the implementation: no delta at all, the phase
# stuck in `claimed` and the checkout left dirty for the next turn.
# 55 min (the per-issue time-box plus the triage/claim/gate bookkeeping) is
# the FLOOR: a config.env that still says 25 does not shorten it, and a
# bigger value is honored.
DEFAULT_TURN_MIN=55
TURN_BUDGET_MIN="${MAX_TURN_MIN:-$DEFAULT_TURN_MIN}"
case "$TURN_BUDGET_MIN" in ''|*[!0-9]*) TURN_BUDGET_MIN="$DEFAULT_TURN_MIN";; esac
if [ "$TURN_BUDGET_MIN" -lt "$DEFAULT_TURN_MIN" ]; then
  log "the turn budget is raised to ${DEFAULT_TURN_MIN} min (config.env says ${MAX_TURN_MIN}: a turn that implements with TDD needs more than the ${MAX_WORK_MINUTES_PER_ISSUE:-45} min of the per-issue time-box)"
  TURN_BUDGET_MIN="$DEFAULT_TURN_MIN"
fi

# systemd kills the service at TimeoutStartSec. If that is SHORTER than the
# turn budget, systemd kills the turn BEFORE `timeout` does: the trap below
# still cleans up (state + checkout), but the turn is lost anyway and the
# unit has to be raised. It is said out loud, not silently absorbed.
UNIT_FILE="$HOME/.config/systemd/user/solidcraft-loop.service"
UNIT_TIMEOUT_SEC=0
if [ -r "$UNIT_FILE" ]; then
  v="$(sed -n 's/^[[:space:]]*TimeoutStartSec[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$UNIT_FILE" | head -1)"
  case "${v:-}" in ''|*[!0-9]*) v=0;; esac
  UNIT_TIMEOUT_SEC="$v"
fi
if [ "$UNIT_TIMEOUT_SEC" -gt 0 ] && [ "$((UNIT_TIMEOUT_SEC / 60))" -lt "$TURN_BUDGET_MIN" ]; then
  log "WARNING: solidcraft-loop.service has TimeoutStartSec=${UNIT_TIMEOUT_SEC}s ($((UNIT_TIMEOUT_SEC / 60)) min) < the turn budget (${TURN_BUDGET_MIN} min): systemd kills the turn first (the trap cleans up, but the turn is lost: the unit has to be raised)"
fi

# --- the token budget of the turn -------------------------------------------
# The time budget bounds the wall clock of a turn, not its spend. A turn that
# runs 240 steps can cost 50M tokens (a dollar) and the loop runs unattended
# 24/7, so there is a second ceiling: the tokens of the turn.
#
# WHAT IT COSTS: the delta of a turn is emitted at its VERY END (measured: the
# last delta arrives at 100% of the tokens of the turn), so a turn stopped at
# 60% of its tokens produces NO delta: the phase is marked failed and the
# issue is implemented again in the next turn. Stopping a turn is NOT free.
#
# That is why the default is a SAFETY NET and not an optimization: 40M tokens
# is above every turn of the measured history (the most expensive one spent
# 51M with the old compaction ceiling, and the ceiling of 150K cuts it to
# ~21M). Lowering it trades work for tokens, and the exchange is measured:
#   8M -> 12 of 200 turns stopped, -19% of the cost of the loop
#   4M -> 31 of 200 turns stopped, -34%
# With 0 the watchdog is not started at all.
DEFAULT_TURN_TOKEN_BUDGET=40000000
TURN_TOKEN_BUDGET="${TURN_TOKEN_BUDGET:-$DEFAULT_TURN_TOKEN_BUDGET}"
case "$TURN_TOKEN_BUDGET" in ''|*[!0-9]*) TURN_TOKEN_BUDGET="$DEFAULT_TURN_TOKEN_BUDGET";; esac
if [ "$TURN_TOKEN_BUDGET" -lt 0 ]; then
  TURN_TOKEN_BUDGET=0
fi
TURN_TOKEN_WATCHDOG="$LOOP_DIR/bin/turn-token-watchdog.py"
if [ "$TURN_TOKEN_BUDGET" -gt 0 ] && [ ! -x "$TURN_TOKEN_WATCHDOG" ]; then
  log "WARNING: the token budget is ${TURN_TOKEN_BUDGET} but the watchdog is not there (${TURN_TOKEN_WATCHDOG}): the turn has no token ceiling"
  TURN_TOKEN_BUDGET=0
fi

# --- helpers --------------------------------------------------------------
# --- the state of THIS slot ------------------------------------------------
# The schema v2 keeps the per-slot fields under `slots[<id>]`. The flat keys
# at the top level are the LEGACY storage of the slot "0" (state.py reads
# them back into the slot "0" when it loads the file), so for the slot "0"
# they win, exactly like state.py applies them. A state that has not been
# migrated yet (v1) has them at the top level and they ARE the slot 0.
#
# The object of the slot is computed once and reused: the reads below are
# per slot, never over the whole file (a sed or a jq over the whole JSON
# would take the first key of the file: the phase of the slot that was
# inserted first).
slot_object() {
  jq -c --arg s "$SLOT" '
    def flat: ["phase", "issue", "branch", "pr", "review", "review_sha",
               "review_issue", "review_branch", "branch_sha", "in_flight",
               "gate_log", "gate_verdict", "gate_checked_at",
               "quick_verdict", "merge_verdict", "published_pr",
               "published_sha", "consecutive_failures",
               "scope_verdict", "scope_status", "scope_kind",
               "scope_packages", "scope_checks", "scope_new_failures",
               "scope_failed_tests", "scope_sha", "scope_at", "scope_stale",
               "scope_reason", "scope_deferred"];
    . as $root
    | (if ((.slots? | type) == "object")
       then (if (.slots[$s]? | type) == "object" then (.slots[$s] // {}) else {} end)
       elif $s == "0" then $root
       else {} end) as $sl
    | (if ((.slots? | type) == "object") and ($s == "0")
       then reduce flat[] as $k ($sl; if $root[$k] == null then . else .[$k] = $root[$k] end)
       else $sl end)
  ' "$STATE" 2>/dev/null
}

# A field of THIS slot, as text. The argument is a jq PATH inside the slot
# (["phase"], ["gate","log"]).
slot_field() {
  local obj
  obj="$(slot_object)"
  [ -n "$obj" ] || return 0
  printf '%s' "$obj" | jq -r --argjson p "$1" '
    getpath($p)
    | if type == "string" then .
      elif type == "number" then tostring
      elif type == "null" then ""
      else tojson end
  ' 2>/dev/null
}

# The number of the issue of THIS slot (nothing when there is no issue).
slot_issue() {
  local num
  num="$(slot_field '["issue"]')"
  case "${num:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$num" -gt 0 ] || return 1
  printf '%s' "$num"
}

# The log of the gate of THIS slot: the flat `gate_log` of the slot or the
# frozen `gate.log` of the schema v2.
slot_gate_log() {
  local obj
  obj="$(slot_object)"
  [ -n "$obj" ] || return 0
  printf '%s' "$obj" | jq -r '.gate_log // .gate.log? // ""' 2>/dev/null
}

# The view of THIS slot for the model. The model does NOT read state.json:
# it reads the view of its slot, with the same flat keys it has always read
# (the prompt changes its path, not its shape) plus the globals it
# consults. The view is written from the state that is fresh NOW, before
# the turn, so the model never sees the phase of the other slot.
write_slot_view() {
  local tmp="$SLOT_VIEW.tmp.$$" obj
  obj="$(slot_object)"
  if [ -n "$obj" ] && jq --argjson sl "$obj" --arg s "$SLOT" '
    {
      phase: ($sl.phase // ""),
      issue: ($sl.issue // 0),
      branch: ($sl.branch // ""),
      pr: ($sl.pr // 0),
      gate_log: ($sl.gate_log // $sl.gate.log? // ""),
      review: ($sl.review // ""),
      review_sha: ($sl.review_sha // ""),
      review_issue: ($sl.review_issue // 0),
      review_branch: ($sl.review_branch // ""),
      branch_sha: ($sl.branch_sha // ""),
      in_flight: ($sl.in_flight // null),
      gate_verdict: ($sl.gate_verdict // ""),
      gate_checked_at: ($sl.gate_checked_at // 0),
      quick_verdict: ($sl.quick_verdict // {}),
      merge_verdict: ($sl.merge_verdict // {}),
      scope_verdict: ($sl.scope_verdict // ""),
      scope_status: ($sl.scope_status // ""),
      scope_kind: ($sl.scope_kind // ""),
      scope_packages: ($sl.scope_packages // ""),
      scope_checks: ($sl.scope_checks // ""),
      scope_new_failures: ($sl.scope_new_failures // 0),
      scope_failed_tests: ($sl.scope_failed_tests // ""),
      scope_sha: ($sl.scope_sha // ""),
      scope_at: ($sl.scope_at // 0),
      scope_stale: ($sl.scope_stale // false),
      scope_reason: ($sl.scope_reason // ""),
      scope_deferred: ($sl.scope_deferred // ""),
      published_pr: ($sl.published_pr // 0),
      published_sha: ($sl.published_sha // ""),
      consecutive_failures: ($sl.consecutive_failures // 0),
      triage: (.triage // {}),
      published: (.published // {}),
      prs: (.prs // {}),
      skipped: (.skipped // []),
      counters: (.counters // {}),
      mode: (.mode // "normal"),
      report: (.report // {}),
      allow_new_prs: (.allow_new_prs // true),
      open_unmerged: (.open_unmerged // 0),
      attempts: (.attempts // {}),
      slot: $s,
      version: (.version // 0)
    }
  ' "$STATE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$SLOT_VIEW"
    log "the view of the slot $SLOT is written ($SLOT_VIEW)"
  else
    rm -f "$tmp" 2>/dev/null || true
    log "warning: the view of the slot $SLOT could not be written"
  fi
}

# The reset of the checkout. The main checkout is the loop's working area
# and it is reset to origin/main so that the next turn does not start on a
# dirty tree. The issue branch keeps its commits (the branch ref is not
# touched): only the working tree is cleaned.
#
# With several slots the main checkout may hold the tree of the OTHER slot:
# a reset would destroy the work that is running in parallel. It is only
# done when no other slot is active (no other slot in a phase that means
# "work in progress").
can_reset_checkout() {
  local others
  others="$(jq -r --arg s "$SLOT" '
    [ ((.slots? // {}) | to_entries[])
      | select(.key != $s)
      | (.value.phase // "")
      | select(. == "selected" or . == "claimed" or . == "implemented"
               or . == "gating" or . == "gated")
    ] | length
  ' "$STATE" 2>/dev/null)"
  # A state that cannot be read has no other slot: the reset is safe.
  case "${others:-}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$others" -eq 0 ]
}

reset_checkout() {
  if ! can_reset_checkout; then
    log "the main checkout is NOT reset: another slot is active (its tree would be destroyed)"
    return 0
  fi
  git -C "$REPO" checkout -qf main 2>/dev/null || true
  # `main` is fast-forwarded to `origin/main`. NEVER `reset --hard`: it throws
  # away commits that were merged locally and it needs a clean tree to be safe.
  # The fast-forward is only possible when the branch is really `main`: on the
  # issue branch it would move the branch, so it is skipped there.
  if [ "$(git -C "$REPO" branch --show-current 2>/dev/null)" = "main" ]; then
    if ! git -C "$REPO" merge --ff-only origin/main 2>/dev/null; then
      log "warning: main could not be fast-forwarded to origin/main (it has diverged)"
    fi
  fi
  git -C "$REPO" clean -qfd 2>/dev/null || true
  # The house rules are NOT a patch over `AGENTS.md` any more: they live in an
  # untracked, excluded file (`house-rules.sh`), so `clean -qfd` (which does not
  # touch ignored/excluded files) keeps them and no tracked file is ever
  # modified by the loop.
}

# --- pre-flight: the repository has to be usable BEFORE any operation -------
# The loop used to start a turn on a repository that was ALREADY broken: a
# merge or a rebase that was never finished (`UU AGENTS.md`), a dirty tree or
# the leftovers of a failed patch (`*.rej`, `*.orig`). Every one of them
# poisons the turn: the rebase, the gate and the publication all run on top
# of that mess and the result is another mess (the incident that started all
# this: an orphan autostash left `main` with `UU AGENTS.md`).
#
# The pre-flight does NOT fix anything: it PARKS the loop (the turn does not
# start) and says WHY, in Spanish, because the reader of the log is a human.
# The next turn checks again: when the repository is usable again the loop
# goes on by itself, without a human restarting it.
#
#   (a) `git ls-files -u`        -> a merge or a rebase that was not finished
#   (b) `git status --porcelain` -> a dirty tree
#   (c) `*.rej` / `*.orig`       -> the leftovers of a failed patch
#
# The fourth check (`main` against `origin/main`) is NOT here: it needs the
# fetch, so it runs after it (see below).
#
# `park_turn` ends the turn with a code of 0: a parked turn is not a failed
# turn, it is a turn that did not start (like the cooldown).
park_turn() {
  log "$1"
  exit 0
}

preflight_repo() {
  local unmerged dirty leftovers
  # (a) an unfinished merge or rebase
  unmerged="$(git -C "$REPO" ls-files -u 2>/dev/null | head -5)"
  if [ -n "$unmerged" ]; then
    park_turn "pre-vuelo: el repositorio tiene una fusion o un rebase sin terminar ($REPO): $(printf '%s' "$unmerged" | tr '\n' ' '). No arranco el turno: un rebase o una fusion a medias envenena todo lo que viene despues. Terminalo a mano (git rebase --abort, git merge --abort, o git checkout --<archivo>) y el loop sigue solo en el proximo turno."
  fi
  # (b) a dirty tree
  dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | head -20)"
  if [ -n "$dirty" ]; then
    park_turn "pre-vuelo: el arbol del repositorio esta sucio ($REPO): $(printf '%s' "$dirty" | tr '\n' ' '). No arranco el turno: un arbol sucio rompe el rebase, el gate y la publicacion. Guardalo o descartalo (git stash, git checkout --<archivo>) y el loop sigue solo en el proximo turno."
  fi
  # (c) the leftovers of a failed patch: they are not tracked, so they do not
  # show up in `ls-files -u`; they are searched among the untracked files and
  # among the ignored ones (with the directories collapsed, so the search does
  # not walk `target/`).
  leftovers="$( { git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null
                  git -C "$REPO" ls-files --others --ignored --exclude-standard --directory 2>/dev/null
                } | grep -E '\.(rej|orig)$' | head -10)"
  if [ -n "$leftovers" ]; then
    park_turn "pre-vuelo: hay restos de un parche que no aplico en el repositorio ($REPO): $(printf '%s' "$leftovers" | tr '\n' ' '). No arranco el turno: borralos (rm <archivo>) y el loop sigue solo en el proximo turno."
  fi
}

# The state of a turn that did not finish. `state.py` owns the state, but it
# cannot know that the turn was killed before it emitted its delta: without
# this the phase stays `claimed` forever. The write is atomic (a temporary
# file + rename), like the one of state.py.
#
# With several slots the write is PER SLOT: the state of the other slot is
# never rewritten (a snapshot of a stale world would erase its phase). The
# globals (the counters, the last turn) are written under the GLOBAL lock of
# the state (`.state.lock`, the same one state.py takes): the read -> merge
# -> write has to be atomic against the other slot and against state.py.
#   $1: failed | gating
#   $2: 1 to count the failure in the counters
mark_turn_state() {
  local mode="$1" count="$2" rc=0
  if ! flock -w 30 6; then
    log "the lock of the state is busy: the phase is not marked (the next turn will)"
    return 1
  fi
  python3 - "$STATE" "$SLOT" "$mode" "$count" "$TURN_BUDGET_MIN" "$LOOP_DIR/gate.path" <<'PY'
import datetime as dt
import json
import os
import sys
import tempfile

path, slot, mode, count, budget, gate_path = sys.argv[1:7]
count = str(count).strip() == "1"     # it arrives as a string: "0" is truthy

state = {}
try:
    with open(path, encoding="utf-8") as fh:
        loaded = json.load(fh)
    if isinstance(loaded, dict):
        state = loaded
except (OSError, ValueError):
    state = {}

counters = state.get("counters")
if not isinstance(counters, dict):
    counters = {}
for key in ("iterations", "failures", "consecutive"):
    try:
        counters[key] = int(counters.get(key, 0))
    except (TypeError, ValueError):
        counters[key] = 0

# The v2 shape: the fields of a slot live under `slots[<id>]`. A state that
# has not been migrated yet (v1) has them at the top level and they belong
# to the slot 0.
slots = state.get("slots")
if isinstance(slots, dict):
    own = slots.get(slot)
    if not isinstance(own, dict):
        own = {}
        slots[slot] = own
elif slot == "0":
    # v1: the flat fields ARE the fields of the slot 0.
    own = state
else:
    # v1 and a slot that does not exist yet: the migration to v2 is done
    # here, so that this slot has its own fields from now on. The flat keys
    # stay at the top level: they are the legacy storage of the slot 0.
    migrated = {}
    for key in ("phase", "issue", "branch", "pr", "review", "review_sha",
                "branch_sha", "in_flight", "gate_log", "gate_verdict",
                "gate_checked_at", "quick_verdict", "merge_verdict",
                "scope_verdict", "scope_status", "scope_kind",
                "scope_packages", "scope_checks", "scope_new_failures",
                "scope_failed_tests", "scope_sha", "scope_at",
                "scope_stale", "scope_reason", "scope_deferred"):
        if key in state:
            migrated[key] = state[key]
    slots = {"0": migrated, slot: {}}
    state["slots"] = slots
    own = slots[slot]
    print("the state has been migrated to v2 (the slot %r is new)" % slot,
          file=sys.stderr)

# The flat keys at the top level are the LEGACY storage of the slot "0"
# (state.py reads them back into the slot "0" when it loads the file): the
# slot "0" writes both of them, or its phase would be restored from the
# flat key of the last turn.
MIRRORED = ("phase", "in_flight", "gate_log")


def set_field(key, value):
    own[key] = value
    if slot == "0" and key in MIRRORED:
        state[key] = value


if mode == "gating":
    # A gate is still running: the phase must not strand it. The next turn
    # reads its log (gate-check.sh) and advances it.
    if own.get("phase") not in ("published", "skipped"):
        set_field("phase", "gating")
    if not own.get("gate_log") and not (own.get("gate") or {}).get("log"):
        candidate = ""
        try:
            with open(gate_path, encoding="utf-8") as fh:
                candidate = fh.readline().strip()
        except OSError:
            candidate = ""
        if candidate:
            set_field("gate_log", candidate)
            gate = own.get("gate")
            if isinstance(gate, dict):
                gate["log"] = candidate
else:
    # `published`/`skipped` are DONE: not rewritten, not counted as failures.
    if own.get("phase") in ("published", "skipped"):
        counters["consecutive"] = 0
        print("the phase stays %r: a done fact" % own.get("phase"), file=sys.stderr)
    else:
        was_failed = own.get("phase") == "failed"
        set_field("phase", "failed")
        set_field("in_flight", None)
        if count and not was_failed:
            counters["failures"] += 1
            counters["consecutive"] += 1

state["counters"] = counters
if mode != "gating":
    state["last_turn"] = {
        "ended": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "result": mode,
        "budget_min": budget,
    }

d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".state.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
  rc=$?
  flock -u 6
  return "$rc"
}

# The worktree of the issue in flight ("" when there is no issue in flight).
# The QUICK gate runs there, so its cargo is one of the leftovers of a dead
# turn: alive, it keeps the lock of the target dir and the next turn blocks
# on it.
issue_worktree() {
  local num
  # The issue of THIS slot: with several slots the worktree of the issue of
  # the other slot is not the one of this turn.
  num="$(slot_issue 2>/dev/null || true)"
  case "${num:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$num" -gt 0 ] || return 1
  printf '%s/issue-%s\n' "$WT_ROOT" "$num"
}

# The verdict file of the SCOPED gate of THIS slot: it is PER SLOT, because
# the verdict of a slot is never the verdict of another one.
#
# There is NO fallback to the legacy global file (gate.quick.verdict): that
# file is a mirror of the scoped gate (it is what the state machine exposes as
# `quick_verdict`), and the mirror of ANY slot would answer for this one.
# A slot whose own file is missing has no verdict: the scoped gate is
# launched again, which is the only way to get one.
scope_verdict_file() {
  local own="$LOOP_DIR/gates/$SLOT/scope.verdict"
  if [ -r "$own" ]; then
    printf '%s' "$own"
    return 0
  fi
  return 1
}

# A field of the verdict of the SCOPED gate of THIS slot. The file is DATA: it
# is read with sed and it is never sourced.
scope_verdict_field() {
  local file
  file="$(scope_verdict_file)" || return 0
  sed -n "s/^$1=//p" "$file" 2>/dev/null | head -1
}

# The complete gate that is alive RIGHT NOW, in any slot: it saturates the
# machine (load 231 on 16 vCPU), so nothing is launched while it runs. The pid
# files are read AGAIN (not the value read at the beginning of the turn): the
# turn itself may have launched the complete gate, and that value is stale.
live_gate_pid() {
  local pid=0 file cmd
  for file in "$LOOP_DIR/gate.pid" "$LOOP_DIR"/gates/*/pid; do
    [ -r "$file" ] || continue
    pid="$(tr -dc '0-9' < "$file" 2>/dev/null | head -c 10)"
    case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 0 ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    # A recycled pid is not a gate: the command line of the gate carries its
    # marker (`solidcraft-gate-slot:<slot>`) or the command it runs.
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [ -z "$cmd" ]; then
      # The command line cannot be read: it is taken for a gate (the
      # conservative direction: nothing is launched on a saturated machine).
      printf '%s' "$pid"
      return 0
    fi
    case "$cmd" in
      *solidcraft-gate-slot:*|*"xtask ci"*)
        printf '%s' "$pid"
        return 0 ;;
    esac
  done
  return 1
}

# The tip of the branch in flight: the commit the issue is about. The branch
# is built in the worktree of the issue, so its ref is the tip; the HEAD of
# that worktree is the fallback and the ref of the main repo is the last one.
# It is the same order that state.py uses to tie a verdict to a commit.
issue_branch_sha() {
  local wt="$1" branch="$2" sha=""
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if [ -n "$branch" ]; then
      sha="$(git -C "$wt" rev-parse "$branch" 2>/dev/null)"
    fi
    case "${sha:-}" in
      ''|*[!0-9a-f]*) sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" ;;
    esac
  fi
  case "${sha:-}" in
    ''|*[!0-9a-f]*) sha="" ;;
  esac
  if [ -z "$sha" ] && [ -n "$branch" ]; then
    sha="$(git -C "$REPO" rev-parse "$branch" 2>/dev/null)"
  fi
  case "${sha:-}" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  printf '%s' "$sha"
}

# The refusals of the complete gate in the log of the turn: the shell calls
# that launched start-gate.sh and got its exit code. The codes of
# start-gate.sh are 5 (this slot already has a live gate), 6 (queued), 8
# (this sha was already gated), 10 (the quick gate is red for this sha: the
# refusal) and 11 (the complete gate is disabled by configuration). Only the
# refusals are reported here: the others are the normal life of the gate.
gate_refusals_of_turn() {
  python3 - "$TURN_LOG" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    fh = open(path, encoding="utf-8", errors="replace")
except OSError:
    sys.exit(0)
with fh:
    for line in fh:
        if "start-gate.sh" not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        part = obj.get("part") or {}
        if part.get("type") != "tool":
            continue
        state = part.get("state") or {}
        meta = (state.get("metadata") or {}).get("metadata") or {}
        try:
            code = int(meta.get("exit"))
        except (TypeError, ValueError):
            continue
        if code not in (10, 11):
            continue
        reason = ""
        markers = ("quick gate is red", "complete gate is disabled")
        for raw in str(state.get("output") or "").splitlines():
            if any(marker in raw for marker in markers):
                reason = raw.strip()
                break
        if not reason:
            reason = ("the quick gate is red for this sha" if code == 10
                      else "the complete gate is disabled by configuration")
        print(reason)
PY
}

# The worktree of the quick gate when the worktree of the ISSUE is not there.
#
# It is a worktree of its OWN, detached at the sha that is checked, and it
# lives only while the gate runs. It is NOT the worktree of the issue
# (`issue-<n>`): that path belongs to the turn of the issue, and a turn that
# claims an issue inside itself does not have it yet.
quick_gate_temp_path() {
  printf '%s/gate-quick-%s\n' "$WT_ROOT" "${SLOT:-0}"
}

# The worktree of the quick gate is forgotten: the directory is removed and
# the registration of the worktree in the repository is pruned. It is the
# cleanup of the run that died, and it is called before the worktree is
# created again (a worktree that is registered cannot be created twice).
quick_gate_temp_forget() {
  local path="$1"
  [ -n "$path" ] || return 0
  # The path is removed only when it is THE path of the gate: the removal is
  # a `rm -rf`, and a path that is not the one of the gate would delete
  # something else.
  case "$path" in
    "$WT_ROOT"/gate-quick-[0-9]*) ;;
    *) return 0 ;;
  esac
  git -C "$REPO" worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
}

# The worktree of the quick gate is created: a worktree detached at the sha
# that is checked. The sha is a commit of the repository, so the tree of that
# worktree IS the tree of the commit, without anything of the working tree of
# the turn in it.
#
# It returns 1 when the worktree cannot be created: the quick gate is BEST
# EFFORT, and a gate that is not launched is not a failed turn.
quick_gate_temp_create() {
  local path="$1" sha="$2"
  [ -n "$path" ] || return 1
  [ -n "$sha" ] || return 1
  mkdir -p "$WT_ROOT" 2>/dev/null || true
  # The leftover of a run that died is removed first: a path that is
  # registered in the repository cannot be used again.
  quick_gate_temp_forget "$path"
  if git -C "$REPO" worktree add --detach "$path" "$sha" >/dev/null 2>&1; then
    QUICK_GATE_TEMP_WT="$path"
    return 0
  fi
  quick_gate_temp_forget "$path"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  return 1
}

# The worktree of the quick gate is removed. It is called at the end of the
# run AND by the EXIT trap: a turn that dies in the middle of the gate (a
# signal, a kill) leaves a worktree that the next turn has to prune, and a
# worktree that stays keeps the lock of the target dir.
quick_gate_temp_remove() {
  local path="${QUICK_GATE_TEMP_WT:-}"
  QUICK_GATE_TEMP_WT=""
  [ -n "$path" ] || return 0
  quick_gate_temp_forget "$path"
}

# The quick gate: the FAST gate, launched HERE and not by the model.
#
# Why: the prompt asks the orchestrator to run the quick gate before the
# complete one, and in six real turns it read that instruction and never ran
# it (the model does not run what the prompt only mentions). The launch is
# mechanical: when the phase that the delta leaves is `implemented` (the code
# is committed and the complete gate has not been launched yet), the quick
# gate runs on the tip of the branch in flight.
#
# It is BEST EFFORT: the launch itself does not change the phase, it does not
# touch the state and it never breaks the turn. A scoped gate that fails is a
# note in the log, not a failed turn: the publication needs a green gate, and
# the complete gate is still there as the alternative.
maybe_run_quick_gate() {
  local wt="$1" branch="$2"
  local sha q_sha q_status q_verdict q_deferred q_decision rc=0 started ended elapsed left pid budget
  local gate_wt="$wt" temp_wt="" prev_exit=""

  # (1) A complete gate is alive: the machine is saturated. Nothing is
  # launched on top of it.
  if pid="$(live_gate_pid)"; then
    log "the quick gate is not launched: the complete gate is alive (pid $pid):" \
      "the machine is saturated"
    return 0
  fi

  # (2) The tip of the branch in flight: without it there is nothing to
  # check.
  if ! sha="$(issue_branch_sha "$wt" "$branch")"; then
    log "the quick gate is not launched: the tip of the branch in flight cannot be read"
    return 0
  fi

  # (3) The tree that the quick gate compiles: the working tree of the issue
  # worktree when that worktree is there, and a worktree of its own when it
  # is not.
  #
  # The worktree of the issue does not exist when the issue is claimed
  # inside THIS turn: the model claims the issue, writes the code and the
  # turn ends with the phase `implemented`, all of it in the same turn. The
  # gate of that turn had no tree to compile, so it was skipped, and the
  # code reached the complete gate without a fast check.
  #
  # The tree of the worktree of the gate is the tree of the COMMIT of the
  # tip of the branch: the changes that are not committed yet are not in it
  # (the commit of the branch is what the complete gate checks).
  if [ -z "$gate_wt" ] || [ ! -d "$gate_wt" ] \
     || ! git -C "$gate_wt" rev-parse --git-dir >/dev/null 2>&1; then
    gate_wt=""
  fi

  # (4) It is idempotent: the verdict of a sha that is already checked IS the
  # verdict of that sha (the tree did not change). A run that did not finish
  # is NOT a verdict, so that one is repeated. The verdict read here is the
  # one of THIS slot (the scoped gate writes it per slot).
  q_sha="$(scope_verdict_field SHA)"
  q_status="$(scope_verdict_field GATE_STATUS)"
  q_verdict="$(scope_verdict_field VERDICT)"
  q_deferred="$(scope_verdict_field DEFERRED)"
  # The decision is a VALUE and not a `return`: this block can be extracted
  # from the supervisor and run on its own (the rule 31 of the test suite
  # does exactly that), and a `return` inside a sourced block does not
  # abort the function that sources it.
  #   run  = the scope gate is launched
  #   skip = the verdict of this sha is already there: nothing is launched
  q_decision="run"
  if [ -n "$q_sha" ] && [ "$q_sha" = "$sha" ]; then
    if [ -n "$q_deferred" ]; then
      # A deferral is a POSTPONEMENT, not a verdict: the scope was never
      # judged (it was postponed because the complete gate was alive). It
      # is run again when the machine is free.
      log "the quick gate is launched again: the previous run for $sha was" \
        "deferred (${q_deferred:-?}): it is not a verdict"
      q_decision="run"
    elif [ "$q_status" != "failed" ]; then
      log "the quick gate is not launched again: its verdict for $sha is" \
        "already there (${q_verdict:-?})"
      q_decision="skip"
    else
      log "the quick gate is launched again: the previous run for $sha did not" \
        "finish (${q_status:-?}): it is not a verdict"
      q_decision="run"
    fi
  fi
  if [ "$q_decision" = "skip" ]; then
    return 0
  fi

  # (5) The service has to be alive when the quick gate ends: systemd kills
  # the turn at TimeoutStartSec, and a killed turn marks the phase as failed.
  # The quick gate is worth less than the work of the turn.
  #
  # The gate gets the time that is LEFT in the turn, and not a fixed budget:
  # the gate stops itself at its timeout, so a gate that is given more time
  # than the turn has is killed by systemd before it can write its verdict,
  # and a killed gate is not a verdict (the turn is lost with it).
  if [ "${UNIT_TIMEOUT_SEC:-0}" -gt 0 ]; then
    elapsed=$(( ( $(date -u +%s) - NOW_EPOCH ) / 60 ))
    left=$(( UNIT_TIMEOUT_SEC / 60 - elapsed ))
    if [ "$left" -lt "$(( ${GATE_QUICK_MIN_MIN:-12} + 2 ))" ]; then
      log "the quick gate is not launched: the service ends in ${left} min and" \
        "the quick gate needs ${GATE_QUICK_MIN_MIN:-12} min (a turn killed" \
        "by systemd loses the work)"
      return 0
    fi
    # The budget of this run: what is left of the turn (see gate_budget).
    budget="$(gate_budget "$left")"
  else
    # Without a known deadline (no unit file) the gate gets its ceiling.
    budget="${GATE_QUICK_TIMEOUT_MIN:-30}"
  fi

  # The quick gate compiles: it is a heavy phase. With several slots only
  # one heavy phase runs at a time: if another slot has it, the quick gate
  # is left for the next turn (it is best effort anyway).
  if [ "$MAX_SLOTS" -gt 1 ] && ! heavy_available; then
    log "the quick gate is not launched: another slot is doing the heavy phase"
    return 0
  fi

  # There is no tree to compile: the quick gate gets a worktree of its OWN,
  # detached at the sha that is checked. It lives only while the gate runs
  # (the EXIT trap removes it when the turn dies in the middle of the gate),
  # and it is NOT the worktree of the issue: that path belongs to the turn of
  # the issue.
  if [ -z "$gate_wt" ]; then
    temp_wt="$(quick_gate_temp_path)"
    if ! quick_gate_temp_create "$temp_wt" "$sha"; then
      log "the quick gate is not launched: the worktree of the issue is not" \
        "there and the worktree of the gate could not be created"
      return 0
    fi
    # The cleanup is armed BEFORE the gate runs: a turn that dies in the
    # middle of the gate leaves a worktree behind, and a worktree that stays
    # keeps the lock of the target dir.
    prev_exit="$(trap -p EXIT 2>/dev/null || true)"
    trap 'quick_gate_temp_remove' EXIT
    gate_wt="$temp_wt"
    log "the quick gate runs in a worktree of its own at $gate_wt" \
      "(detached at $sha)"
  fi

  log "the quick gate is launched on $sha (the tip of the branch in flight):" \
    "the fast check before the complete gate"
  started="$(date -u +%s)"
  # The slot goes with the run: the verdict of the scoped gate is written in
  # gates/<slot>/scope.verdict, the file of THIS slot, and never in the file
  # of another one. The budget of this run is what is left of the turn.
  ( cd "$gate_wt" && GATE_QUICK_TIMEOUT_MIN="$budget" \
      bash "$LOOP_DIR/bin/gate-quick.sh" origin/main "$sha" \
      --slot "$SLOT" ) >>"$ERR" 2>&1 || rc=$?
  ended="$(date -u +%s)"
  # The worktree of the gate is removed: it lived only while the gate ran.
  if [ -n "$temp_wt" ]; then
    trap - EXIT
    if [ -n "$prev_exit" ]; then
      eval "$prev_exit"
    fi
    quick_gate_temp_remove
  fi
  q_verdict="$(scope_verdict_field VERDICT)"
  if [ "$rc" -eq 0 ]; then
    log "the quick gate finished in $(( ended - started )) s (verdict: ${q_verdict:-?} for $sha)"
  else
    log "the quick gate failed (exit $rc) after $(( ended - started )) s: it is" \
      "not a verdict (the complete gate is the one that decides)"
  fi
  # The gate is given the time that is left of the turn, so the budget of this
  # run is what it is supposed to take: a run that goes over it means that the
  # gate did not stop itself.
  if [ "$(( ended - started ))" -gt "$(( budget * 60 + 60 ))" ]; then
    log "warning: the quick gate took more than its budget (${budget} min):" \
      "something is wrong (the script stops itself at its timeout)"
  fi
}

# Is the process that works in `cwd` a leftover of THIS turn? With one slot
# it is every cargo of the loop (the behavior of today). With several slots
# only the ones of the worktree of THIS slot: the cargo of the other slot is
# the implement that runs in parallel and it has to survive.
leftover_is_ours() {
  local cwd="$1" issue_wt="$2" gate_wt
  if [ "${MAX_SLOTS:-1}" -le 1 ]; then
    case "$cwd" in
      "$REPO"|"$REPO"/*|"$WT_ROOT"|"$WT_ROOT"/*) return 0 ;;
    esac
    return 1
  fi
  # The worktree of this slot: the implement and the quick gate of this
  # turn live there.
  if [ -n "$issue_wt" ]; then
    case "$cwd" in
      "$issue_wt"|"$issue_wt"/*) return 0 ;;
    esac
  fi
  # The worktree of the QUICK GATE of this slot: when the worktree of the
  # issue is not there the quick gate compiles a worktree of its own, and the
  # cargo that it leaves when the turn is killed is ours too (the one of the
  # OTHER slot is not: it is the implement that runs in parallel).
  gate_wt="$(quick_gate_temp_path)"
  case "$cwd" in
    "$gate_wt"|"$gate_wt"/*) return 0 ;;
  esac
  # The main checkout is shared: it is only touched when no other slot is
  # active (there is nobody whose tree could be destroyed).
  if can_reset_checkout; then
    case "$cwd" in
      "$REPO"|"$REPO"/*|"$WT_ROOT"|"$WT_ROOT"/*) return 0 ;;
    esac
  fi
  return 1
}

# The tools of a killed turn can survive it: `timeout` signals the turn, not
# its children, and a cargo that is compiling in this checkout keeps the lock
# of the target dir: the next turn would block on it. Only the processes that
# work in THIS checkout are killed: the ones of the complete gate (they work
# in the gate worktree, with their own target dir) are left alone.
#
# The QUICK gate is NOT the complete gate: it runs in the worktree of the
# issue, with the target dir of the main checkout, so its cargo is a leftover
# of the dead turn like any other and it has to die with the turn.
kill_turn_leftovers() {
  local pid cwd killed=0 issue_wt
  issue_wt="$(issue_worktree 2>/dev/null || true)"
  for pid in $(pgrep -x cargo 2>/dev/null; pgrep -x rustc 2>/dev/null); do
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" || continue
    [ -n "$cwd" ] || continue
    # The complete gate that is running is NOT touched: it works in its own
    # worktree (the default one or a slot), with its own target dir, and it
    # has to be allowed to finish.
    case "$cwd" in
      "$GATE_WORKTREE"|"$GATE_WORKTREE"/*|"$LOOP_DIR"/worktrees/*) continue ;;
    esac
    # The cargo of the OTHER slot is not touched either: it is the implement
    # that runs in parallel with this turn.
    if ! leftover_is_ours "$cwd" "$issue_wt"; then
      continue
    fi
    case "$cwd" in
      "$REPO"|"$REPO"/*|"$WT_ROOT"|"$WT_ROOT"/*)
        if [ -n "$issue_wt" ] && [ "$cwd" = "$issue_wt" ]; then
          log "killing the cargo the quick gate left in the worktree of the issue (pid $pid)"
        else
          log "killing the leftover of the killed turn (pid $pid, cwd $cwd)"
        fi
        kill -TERM "$pid" 2>/dev/null && killed=1
        ;;
    esac
  done
  if [ "$killed" -eq 1 ]; then
    sleep 2
    for pid in $(pgrep -x cargo 2>/dev/null; pgrep -x rustc 2>/dev/null); do
      cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" || continue
      [ -n "$cwd" ] || continue
      case "$cwd" in
        "$GATE_WORKTREE"|"$GATE_WORKTREE"/*|"$LOOP_DIR"/worktrees/*) continue ;;
      esac
      leftover_is_ours "$cwd" "$issue_wt" || continue
      case "$cwd" in
        "$REPO"|"$REPO"/*|"$WT_ROOT"|"$WT_ROOT"/*) kill -KILL "$pid" 2>/dev/null || true ;;
      esac
    done
  fi
}

# The turn was killed (the budget ran out, or systemd stopped the service).
# The phase is marked and the checkout is reset, so the next turn does not
# inherit a half-done tree.
#   $1: 1 to count the failure in the counters
handle_killed_turn() {
  local pid=0 alive=0
  if [ -r "$LOOP_DIR/gate.pid" ]; then
    pid=$(tr -dc '0-9' < "$LOOP_DIR/gate.pid" | head -c 10)
  fi
  if [ "${pid:-0}" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
    alive=1
  fi
  kill_turn_leftovers
  if [ "$alive" -eq 1 ]; then
    # The gate lives in its own worktree: the reset of the main checkout
    # does not disturb it and the next turn reads its log.
    log "a gate is alive (pid $pid): the phase stays 'gating' and the next turn reads its log"
    mark_turn_state gating "${1:-0}"
  else
    log "the phase is marked as failed: the killed turn produced no delta"
    mark_turn_state failed "${1:-0}"
  fi
  # The reset of the main checkout is only done when no other slot is
  # active: with several slots that checkout can hold the tree of the slot
  # that is working in parallel and a reset would destroy it.
  if can_reset_checkout; then
    reset_checkout
  else
    log "the main checkout is NOT reset: another slot is active (its tree would be destroyed)"
  fi
}

# SIGTERM (systemd's TimeoutStartSec, or a manual stop) kills the turn in
# the middle of the work: the same cleanup as the timeout case, so the phase
# does not stay `claimed` with a dirty tree. The failure is counted (the
# turn died), but only if it was not counted already: `mark_turn_state` does
# not count a turn that was already failed.
on_signal() {
  log "the turn got $1: cleaning up (phase and checkout)"
  handle_killed_turn 1
  exit 143
}
trap 'on_signal SIGTERM' TERM
trap 'on_signal SIGINT' INT

# --- pre-flight: the repository is checked BEFORE anything else ------------
# The traps are already armed: a turn that is stopped here is cleaned up like
# any other (the phase is not touched: nothing started).
preflight_repo

# --- precondition 0: rate-limit cooldown ---------------------------------
# A 429 from MiniMax or a secondary 403 from the GitHub API is not a failure
# of the work: it means "wait". Without this, the timer keeps firing and every
# turn spends a call that is going to fail anyway.
#
# The transport backoff is checked apart: a connection that broke is not an
# exhausted plan. It waits a few minutes, not the quota's cooldown.
NOW_EPOCH=$(date -u +%s)
if [ -s "$COOLDOWN_FILE" ]; then
  until=$(tr -dc '0-9' < "$COOLDOWN_FILE" | head -c 12)
  if [ -n "$until" ] && [ "$until" -gt "$NOW_EPOCH" ]; then
    log "cooldown active until $(date -u -d @"$until" +%FT%H:%MZ): skipping turn"
    exit 0
  fi
fi
if [ -s "$TRANSPORT_COOLDOWN_FILE" ]; then
  until=$(tr -dc '0-9' < "$TRANSPORT_COOLDOWN_FILE" | head -c 12)
  if [ -n "$until" ] && [ "$until" -gt "$NOW_EPOCH" ]; then
    log "transport backoff active until $(date -u -d @"$until" +%FT%H:%MZ): skipping turn"
    exit 0
  fi
fi

# --- precondition 1: disk ------------------------------------------------
# The emergency path: the disk is almost full. The ORDER MATTERS. The
# `incremental` caches of cargo are a cache: cargo rebuilds them and they are
# worthless across branches (they had grown to 94 GB). `target/release` is
# the build of the app that the evidence worker uses: 12 GB that cost a
# rebuild with LTO. The free ones go first, the expensive one only if the
# cheap ones were not enough.
free_gb=$(df --output=avail -BG /home | tail -1 | tr -dc '0-9')
if [ "${free_gb:-0}" -lt "${MIN_FREE_GB:-60}" ]; then
  log "low disk (${free_gb} GB < ${MIN_FREE_GB} GB): pruning caches"
  rm -rf "$REPO/target/debug/incremental" "$REPO/target/ci/incremental" \
         "$REPO/target/release/incremental" 2>/dev/null || true
  free_gb=$(df --output=avail -BG /home | tail -1 | tr -dc '0-9')
  if [ "${free_gb:-0}" -lt "${MIN_FREE_GB:-60}" ]; then
    log "low disk (${free_gb} GB): pruning the release build"
    rm -rf "$REPO/target/release" "$REPO/target/wasm32-unknown-unknown" 2>/dev/null || true
    free_gb=$(df --output=avail -BG /home | tail -1 | tr -dc '0-9')
  fi
fi
if [ "${free_gb:-0}" -lt "${SKIP_FREE_GB:-25}" ]; then
  log "low disk (${free_gb} GB): skipping turn"
  exit 0
fi

# --- the gate from the previous turn -------------------------------------
# Decided by PID (gate.pid) plus age (gate.started), NEVER with a blind
# pkill: the gate may be legitimately running and has to be allowed to finish.
# The original pkill killed the legitimate gate and the loop never reached
# `gated`.
GATE_PID=0
GATE_STARTED=0
[ -r "$LOOP_DIR/gate.pid" ] && GATE_PID=$(tr -dc '0-9' < "$LOOP_DIR/gate.pid" | head -c 10)
[ -r "$LOOP_DIR/gate.started" ] && GATE_STARTED=$(tr -dc '0-9' < "$LOOP_DIR/gate.started" | head -c 12)
GATE_ALIVE=0
if [ "${GATE_PID:-0}" -gt 0 ] && kill -0 "$GATE_PID" 2>/dev/null; then
  GATE_ALIVE=1
fi

# The phase of THIS slot, read once (the model proposes it, state.py decides).
# It is read with jq and NOT with sed: with the schema v2 the fields of a
# slot live under `slots[<id>]` and a sed over the JSON would take the FIRST
# key of the file (the phase of the slot that was inserted first), which is
# the phase of the other slot.
phase="$(slot_field '["phase"]')"

# --- the gate of the previous turn: did it finish? ------------------------
# The gate runs 40-90 min and the turn is short: the phase stays `gating`
# until some turn reads its log and applies the verdict (gate-check.sh).
# Two things can break that chain and both are checked here:
#
#  1. The log path is only known to the state if the delta that launched the
#     gate arrived. If the turn that launched it was killed, the delta never
#     arrived: the path is taken from gate.path (written by start-gate.sh).
#  2. The gate can be finished (its log has EXIT=) while the state still
#     says `gating`: the next turn has to see it and advance the phase.
#
# The log is the one of THIS slot (the v2 schema freezes it in
# `slots[<id>].gate.log`): the log of the other slot is not the one of this
# turn.
STATE_GATE_LOG="$(slot_gate_log)"
GATE_PATH_FILE=""
if [ -r "$LOOP_DIR/gate.path" ]; then
  GATE_PATH_FILE=$(head -1 "$LOOP_DIR/gate.path" 2>/dev/null | tr -d '\r\n')
fi
if [ "${phase:-idle}" = "gating" ]; then
  if [ -z "${STATE_GATE_LOG:-}" ] && [ -n "$GATE_PATH_FILE" ] && [ -f "$GATE_PATH_FILE" ]; then
    log "the phase is 'gating' but the state does not know the log: it is backfilled from gate.path ($GATE_PATH_FILE)"
    mark_turn_state gating 0
    STATE_GATE_LOG="$GATE_PATH_FILE"
  fi
  if [ -n "${STATE_GATE_LOG:-}" ]; then
    # The log of the run that is going on AND its rotated one (<log>.1): the
    # EXIT= of the run that already finished is in the rotated one, so the
    # chain is not broken by the rotation.
    for gate_log_file in "$STATE_GATE_LOG" "$STATE_GATE_LOG.1"; do
      [ -f "$gate_log_file" ] || continue
      if grep -qE '^EXIT=[0-9]+[[:space:]]*$' "$gate_log_file"; then
        log "the gate already finished (EXIT= in $gate_log_file) and the phase is still 'gating': the next turn reads the log and advances"
        break
      fi
    done
  fi
fi

# --- the gate verdict: mechanical, computed here and left for the turn ---
# The verdict is a RULE (the only failures are the ones in the baseline), so
# the script applies it, not the model. The supervisor runs every couple of
# minutes: it computes the verdict and leaves it in gate.verdict, and the
# turn reads that file instead of spending a model call asking a question the
# script can answer.
VERDICT_FILE="$LOOP_DIR/gate.verdict"
GATE_LOG_FOR_VERDICT="${STATE_GATE_LOG:-}"
if [ "$GATE_ALIVE" -eq 1 ] && [ -n "$GATE_PATH_FILE" ]; then
  # A live gate: its own log is the one that matters. The state can still
  # point at the log of the previous gate.
  GATE_LOG_FOR_VERDICT="$GATE_PATH_FILE"
fi
if [ -n "${GATE_LOG_FOR_VERDICT:-}" ] && [ -f "$GATE_LOG_FOR_VERDICT" ]; then
  VERDICT_TMP="$LOOP_DIR/.gate.verdict.tmp"
  if bash "$LOOP_DIR/bin/gate-check.sh" "$GATE_LOG_FOR_VERDICT" > "$VERDICT_TMP" 2>/dev/null && [ -s "$VERDICT_TMP" ]; then
    { echo "GATE_LOG=$GATE_LOG_FOR_VERDICT"; cat "$VERDICT_TMP"; } > "$VERDICT_FILE" 2>/dev/null || true
  fi
  rm -f "$VERDICT_TMP" 2>/dev/null || true
fi

# The issue and the branch of THIS slot: the evidence of the other slot is
# not published by this turn.
EVID_ISSUE="$(slot_field '["issue"]')"
EVID_BRANCH="$(slot_field '["branch"]')"
case "${EVID_ISSUE:-}" in ''|*[!0-9]*) EVID_ISSUE=0 ;; esac


# --- precondition 2: load ------------------------------------------------
# The asynchronous gate runs ~20 test binaries in parallel and drives the load
# average to ~250 on 16 vCPUs: the next turn would see load > MAX_LOAD and
# skip itself, the gate would never be checked, would never finish, and the
# loop would never publish. A logical deadlock. While our own gate is alive
# the load is ours: not a reason to skip.
#
# With several slots the load of the machine is the sum of OURS: the gate
# plus, at most, ONE implement (the rule is one heavy phase at a time). The
# exception therefore holds while our own heavy processes are at most
# MAX_SLOTS-1: with two slots the gate + one implement still runs the turn
# that reads the log of the gate. Without this the second slot would skip
# every turn while the first one gates, and the loop would lose half of its
# time.
#
# The heavy processes of the loop are the cargo of an implement (in the main
# checkout or in the worktree of an issue). The cargo of the gate is NOT one
# of them: it works in the worktree of the gate and it is excluded.
our_heavy_processes() {
  local pid cwd n=0
  for pid in $(pgrep -x cargo 2>/dev/null); do
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" || continue
    [ -n "$cwd" ] || continue
    case "$cwd" in
      "$GATE_WORKTREE"|"$GATE_WORKTREE"/*|"$LOOP_DIR"/worktrees/*) continue ;;
    esac
    case "$cwd" in
      "$REPO"|"$REPO"/*|"$WT_ROOT"|"$WT_ROOT"/*) n=$(( n + 1 )) ;;
    esac
  done
  printf '%s' "$n"
}
load=$(cut -d' ' -f1 /proc/loadavg)
if awk -v l="${load:-0}" -v m="${MAX_LOAD:-24}" 'BEGIN{exit !(l>m)}'; then
  heavy_ours=0
  gate_alive="$GATE_ALIVE"
  if [ "$MAX_SLOTS" -gt 1 ]; then
    # With several slots the gate that saturates the machine can be the one
    # of another slot (there is ONE gate in the machine) and the load can
    # also be the implement of this loop.
    heavy_ours="$(our_heavy_processes)"
    if [ "$GATE_ALIVE" -eq 1 ] || live_gate_pid >/dev/null 2>&1; then
      gate_alive=1
    else
      gate_alive=0
    fi
  fi
  if [ "$MAX_SLOTS" -gt 1 ] && [ "$heavy_ours" -ge 1 ] \
     && [ "$heavy_ours" -le $(( MAX_SLOTS - 1 )) ]; then
    # The load is ours (one implement of the loop): skipping the turn would
    # leave the work of the other slot without anybody.
    log "high load (${load} > ${MAX_LOAD}) but it is ours (${heavy_ours} heavy process(es)" \
      "of the loop): the turn goes on"
  elif [ "$gate_alive" -eq 1 ]; then
    log "high load (${load} > ${MAX_LOAD}) but our gate is alive: the turn goes on"
  else
    log "high load (${load} > ${MAX_LOAD}): skipping turn"
    exit 0
  fi
fi

# --- gate watchdog -------------------------------------------------------
# THE AGE ALONE DOES NOT DECIDE. The complete gate takes about 2 h 50 min and
# it PRINTS while it works (nextest lists its slow tests every minute, so the
# log grows every 60 s). The age alone killed TWO gates that were making
# progress: 2 h 50 min of CPU thrown away twice, and the issue that was in
# flight stayed without a verdict for hours. The log moving is the proof that
# the gate is alive.
#
# The decision is taken by bin/gate-watchdog.sh, which says why:
#   alive    the log moves: it is left alone
#   stale    the sha it gates was thrown away by a rewrite of the branch
#   stuck    its log has not moved for GATE_SILENT_MIN minutes
#   expired  it is older than the hard ceiling (GATE_TIMEOUT_MIN)
#
# IT FAILS OPEN: without a start marker, without a log, without a branch or
# without a sha, the verdict is `alive` and nothing is killed. The watchdog
# never kills a gate it cannot judge.
#
# This watchdog watches the COMPLETE gate only: the pid of gate.pid, the log
# of gate.path (the log of the LIVE gate: the gate_log of the state can point
# at the log of a gate that is dead) and the sha of gate.sha. It never looks
# at the verdict of the SCOPED gate (gates/<slot>/scope.verdict): that gate
# runs inside the turn, it has its own budget (GATE_QUICK_TIMEOUT_MIN) and it
# is not a process of its own.
# The orphans of a DEAD gate: nextest runs every test in its OWN process
# group, so the kill of the group of the gate does not reach the test
# binaries (19 GB and 16 GB). When the gate dies, they stay alive as
# orphans and keep the memory of the machine.
#
# The detection is by CWD: only the gate works in the gate worktree (the
# repo and the worktrees of the issues are somewhere else). The gate itself
# is excluded: it is not an orphan and a live gate is never touched.
gate_orphan_pids() {
  local d pid cwd cmd
  # With an empty GATE_WORKTREE the pattern of the cwd would be "/*": it
  # would match every process of the machine. Without a gate worktree
  # there are no orphans to look for.
  [ -n "${GATE_WORKTREE:-}" ] || return 0
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "$pid" = "$$" ] && continue
    cwd="$(readlink -f "$d/cwd" 2>/dev/null)" || continue
    case "$cwd" in
      "$GATE_WORKTREE"|"$GATE_WORKTREE"/*) : ;;
      *) continue ;;
    esac
    cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" || continue
    case "$cmd" in
      # the gate itself is not an orphan (nor the cargo of a gate that is
      # being launched right now)
      *solidcraft-gate-slot:*|*xtask\ ci*|*cargo-nextest*) continue ;;
    esac
    printf '%s\n' "$pid"
  done
}

# Kill the orphans of a gate that is DEAD. It only runs when the gate does
# not live any more: the processes that work in the gate worktree then
# cannot be anything but the children of the gate that survived its death.
kill_gate_orphans() {
  local pids count
  pids="$(gate_orphan_pids)"
  [ -n "$pids" ] || return 0
  count="$(printf '%s\n' "$pids" | wc -l | tr -d ' ')"
  log "the dead gate left ${count} orphan(s) in the gate worktree: they are killed (they keep tens of gigabytes)"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  sleep 2
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null || true
}

if [ "$GATE_ALIVE" -eq 1 ]; then
  # The log of the LIVE gate: gate.path is written by start-gate.sh when the
  # gate starts. The gate_log of the state can be the log of a gate that is
  # dead (the state was not updated), and a watchdog that watches a dead log
  # sees a log that does not move and kills a gate that is working.
  WD_LOG="${GATE_PATH_FILE:-}"
  [ -n "$WD_LOG" ] || WD_LOG="${STATE_GATE_LOG:-}"
  WD_SHA=""
  if [ -r "$LOOP_DIR/gate.sha" ]; then
    WD_SHA="$(tr -dc '0-9a-f' < "$LOOP_DIR/gate.sha" | head -c 40)"
  fi
  WD_BRANCH="$(slot_field '["branch"]')"
  WD_OUT=""
  if WD_OUT="$(bash "$LOOP_DIR/bin/gate-watchdog.sh" --pid "$GATE_PID" \
        --started "${GATE_STARTED:-0}" --now "$NOW_EPOCH" --log "$WD_LOG" \
        --sha "$WD_SHA" --branch "$WD_BRANCH" --repo "$REPO" \
        --timeout-min "${GATE_TIMEOUT_MIN:-300}" \
        --silent-min "${GATE_SILENT_MIN:-90}" 2>/dev/null)"; then
    WD_VERDICT="$(printf '%s\n' "$WD_OUT" | sed -n 's/^VERDICT=//p' | head -1)"
    WD_REASON="$(printf '%s\n' "$WD_OUT" | sed -n 's/^REASON=//p' | head -1)"
  else
    # The watchdog itself failed: nothing is killed.
    WD_VERDICT="alive"
    WD_REASON="the watchdog could not answer: the gate is left alone"
  fi
  case "$WD_VERDICT" in
    stale|stuck|expired)
      log "gate ${WD_VERDICT} (${WD_REASON}): killing group $GATE_PID"
      kill -TERM "-$GATE_PID" 2>/dev/null || kill -TERM "$GATE_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "-$GATE_PID" 2>/dev/null || kill -KILL "$GATE_PID" 2>/dev/null || true
      # The group is gone but the children of the gate that were in their
      # own group (the test binaries of nextest) are still alive: they are
      # orphans now and they keep the memory of the machine.
      kill_gate_orphans
      GATE_ALIVE=0
      rm -f "$LOOP_DIR/gate.pid"
      # A gate that was killed does not write its EXIT=: without it the log
      # would say "running" for ever and the phase would wait for a verdict
      # that is never coming. EXIT=124 is the code of `timeout`: the gate was
      # killed, it did not pass.
      if [ -n "$WD_LOG" ] && [ -f "$WD_LOG" ]; then
        printf 'EXIT=124\n' >> "$WD_LOG" 2>/dev/null || true
      fi
      log "the killed gate is marked as failed on the next turn"
      ;;
    *)
      log "gate running (${WD_REASON:-alive}): left alone, the turn checks it"
      ;;
  esac
fi

# --- the reaper of the dead gate -----------------------------------------
# A gate can die WITHOUT writing its EXIT=: a hand kill (the model killing
# the group of processes), a crash, the OOM killer. Then the log keeps
# saying "running" for ever and the state waits GATE_TIMEOUT_MIN for a
# verdict that is never coming.
#
# The reaper does NOT kill anything: the gate is already dead when it runs.
# It only writes the record of a death that already happened: EXIT=124, the
# code of `timeout`: the gate was killed, it did not pass. It fails open:
# without a pid, with a live pid, without a log or with a log of another
# run, nothing is written.
RP_PID_FILE="$LOOP_DIR/gate.pid"
RP_LOG="${GATE_PATH_FILE:-}"
[ -n "$RP_LOG" ] || RP_LOG="$LOOP_DIR/gate.path"
RP_SHA=""
if [ -r "$LOOP_DIR/gate.sha" ]; then
  RP_SHA="$(tr -dc '0-9a-f' < "$LOOP_DIR/gate.sha" | head -c 40)"
fi
if [ -r "$RP_PID_FILE" ]; then
  RP_OUT=""
  if RP_OUT="$(bash "$LOOP_DIR/bin/gate-reap.sh" --pid-file "$RP_PID_FILE" \
        --log "$RP_LOG" --sha "$RP_SHA" 2>/dev/null)"; then
    RP_VERDICT="$(printf '%s\n' "$RP_OUT" | sed -n 's/^VERDICT=//p' | head -1)"
    RP_REASON="$(printf '%s\n' "$RP_OUT" | sed -n 's/^REASON=//p' | head -1)"
    if [ "${RP_VERDICT:-}" = "reaped" ]; then
      log "the dead gate is recorded as killed: ${RP_REASON:-the gate died without EXIT=}"
      rm -f "$RP_PID_FILE"
      # The gate died by hand (or crashed): its children that were in their
      # own group are orphans now. They are killed here: the reaper does not
      # kill anything, this is the cleanup of the orphans.
      kill_gate_orphans
    fi
  fi
fi

# --- precondition 3: gh -------------------------------------------------
# The error of gh is logged: "gh does not answer" without the reason is not
# diagnosable (it is what the rehearsal of bin/dry-run.sh hit: the turn was
# skipped with no clue why).
GH_ERR=""
if ! GH_ERR="$(gh api user --jq .login 2>&1 >/dev/null)"; then
  log "gh does not answer: skipping turn (${GH_ERR:-no answer})"
  exit 0
fi

# --- precondition 4: daily turn cap (cost) -------------------------------
MAX_TURNS="${MAX_TURNS_PER_DAY:-12}"
# The cap is a GLOBAL cost and with several slots the consumption is
# duplicated: each slot compares against its share of it. With one slot the
# share is the whole cap (the behavior of today).
MAX_TURNS_SLOT=$(( MAX_TURNS / MAX_SLOTS ))
[ "$MAX_TURNS_SLOT" -ge 1 ] || MAX_TURNS_SLOT=1
# The count is THIS SLOT's turns, not the turns of the machine: the cap is
# split between the slots, so a slot that has already done its share must
# stop while the other slot continues.
#
# It counted EVERY turn of the day (the name of the log of a turn did not
# carry the slot) and compared the total against the SHARE of one slot: with
# two slots the loop stopped at 144 turns of the day, half of the 288 that
# config.env documents. On the 25-10 that cost 176 skipped turns and 4 h 22
# min of machine time (the log said "daily turn cap reached (144 >= 144,
# the share of 2 slots)").
turns_today=$(find "$TURN_DIR" -maxdepth 1 -name "${DAY}*-slot${SLOT}.jsonl" 2>/dev/null | wc -l)
if [ "$turns_today" -ge "$MAX_TURNS_SLOT" ]; then
  log "daily turn cap reached ($turns_today >= $MAX_TURNS_SLOT," \
    "the share of $MAX_SLOTS slots): skipping turn"
  exit 0
fi

# --- precondition 5: the agents resolve -------------------------------------
# The last precondition, and the one that is NOT about the machine: the turn
# needs an agent that opencode RESOLVES, not an agent FILE that exists. When
# the agent does not resolve, opencode answers "Agent not found" and the turn
# dies before its first step: 137 turns and 2 h 55 min of loop on the 26-10,
# with nothing in the log but the error of a turn that never ran.
#
# It is here and not before: the preconditions above are cheap and they exit
# without spending a process, and everything below this line touches the
# worktree of the issue. The check FAILS OPEN (a checker that is not there, or
# a probe that answers something unexpected, does not block the loop): only an
# explicit "Agent not found" does.
if ! agents_preflight sc-orchestrator; then
  log "ERROR: opencode does not resolve the agent sc-orchestrator: the turn is not started"
  log "the agent files live in $HOME/.config/opencode/agents (bin/check-agents.sh says why)"
  exit 1
fi

# --- the choice of the slot: deterministic ---------------------------------
# The design (slots-design.md §9) says who works now:
#   1. gated + review approved + quota/cooldown OK -> publish first
#   2. gating whose gate just finished -> adopt the verdict
#   3. implemented without verdict -> review (cheap, it does not compile)
#   4. claimed -> implement (heavy: cargo)
#   5. idle -> triage and selection of a new issue
# The tie is the oldest by in_flight.started (FIFO) and then the lowest id.
#
# The supervisor is bound to ONE slot (the one of the invocation), so the
# election decides the HEAVY work: only one slot implements at a time. The
# light phases (the review, the reading of the log of the gate, the triage)
# do not compete: they are cheap and they do not fight for the CPU. That is
# the parallelism: the slot that waits for the gate leaves the machine to the
# slot that implements.
#
# The ranking is recomputed from the state on EVERY turn: a slot that does
# not advance does not keep the focus (the phase of the other slot wins).
slot_ranking() {
  jq -r '
    def slots_of:
      if ((.slots? | type) == "object") then .slots
      elif (.phase? != null) then {"0": .}
      else {} end;
    def rank(p):
      if p == "gated" then 1
      elif p == "gating" then 2
      elif p == "implemented" then 3
      elif p == "claimed" then 4
      else 5 end;
    (slots_of | to_entries
     | map({id: .key,
            phase: (.value.phase // ""),
            started: ((.value.in_flight.started // 0) | tonumber? // 0)})
     | sort_by([rank(.phase),
                (if .started > 0 then .started else 999999999999 end),
                (.id | tonumber? // 999999)])
     | .[] | [.id, .phase, (.started | tostring)] | @tsv)
  ' "$STATE" 2>/dev/null
}

# The slot that takes the heavy work: the first one of the ranking that
# demands it (the implement). The other slots cede the turn.
heavy_owner_slot() {
  local id phase started
  while IFS=$'\t' read -r id phase started; do
    [ -n "$id" ] || continue
    if [ "$phase" = "claimed" ]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(slot_ranking)
  return 1
}

# Is the slot running RIGHT NOW? Its lock of the turn is held while it runs:
# if the lock can be taken, nobody is working on it.
slot_is_running() {
  if flock -n "$LOOP_DIR/.lock.$1" true 2>/dev/null; then
    return 1
  fi
  return 0
}

# Can this process do heavy work? It can if it already holds the lock (its
# own turn is the heavy one) or if it takes it now.
heavy_available() {
  [ "${HEAVY_HELD:-0}" -eq 1 ] && return 0
  if flock -n 8; then
    HEAVY_HELD=1
    return 0
  fi
  return 1
}

# --- the issue of another slot is in flight: do not touch its worktree ----
# The worktree of an issue is at ONE path (worktrees/issue-N) and the slot
# that does not own it removes it with `git worktree remove --force`. Two
# slots on the same issue would make the second one erase the work of the
# first one: the fix that is not committed yet, the evidence, the branch.
# The prompt tells the model not to do it; this is the guard that does not
# depend on the model.
#
# A slot is ALIVE if it is running right now (the lock of its turn is held)
# or if it started a turn recently (the view of the slot is written at the
# BEGINNING of its turn). A dead slot owns nothing: its issue is abandoned
# work that another slot may take over (the adoption of the orphan PRs).
ISSUE_IN_FLIGHT_FRESH_MIN="${ISSUE_IN_FLIGHT_FRESH_MIN:-15}"

# The rank of a phase: the slot that is further along owns the issue.
phase_rank() {
  case "${1:-}" in
    gated)       printf '1' ;;
    gating)      printf '2' ;;
    implemented) printf '3' ;;
    claimed)     printf '4' ;;
    selected)    printf '5' ;;
    failed)      printf '6' ;;
    *)           printf '9' ;;
  esac
}

# The slots (other than this one) that have the issue in flight and are
# alive: one line per slot, "<id> <phase>".
issue_owners_alive() {
  local issue="$1" view id other_issue other_phase other_pr mtime age
  case "${issue:-}" in ''|*[!0-9]*) return 1 ;; esac
  for view in "$LOOP_DIR"/state/slot-*.json; do
    [ -f "$view" ] || continue
    id="$(basename "$view" .json)"
    id="${id#slot-}"
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ "$id" = "$SLOT" ] && continue
    other_issue="$(jq -r '(.issue // 0) | tostring' "$view" 2>/dev/null)"
    other_phase="$(jq -r '(.phase // "") | tostring' "$view" 2>/dev/null)"
    other_pr="$(jq -r '(.pr // 0) | tostring' "$view" 2>/dev/null)"
    [ "${other_issue:-0}" = "$issue" ] || continue
    case "${other_phase:-}" in
      selected|claimed|implemented|gating|gated) ;;
      # `failed` reserves the issue too while the slot holds a pull
      # request: the slot resumes it and the PR is open upstream. It is
      # the SAME rule as the one of the state (state.py, the arbitration
      # of the claim): the three have to agree about the same fact.
      failed)
        case "${other_pr:-0}" in ''|0) continue ;; esac
        ;;
      *) continue ;;
    esac
    # The slot is running right now: its lock of the turn is held.
    if slot_is_running "$id"; then
      printf '%s %s\n' "$id" "$other_phase"
      continue
    fi
    # The slot started a turn recently: its view was written at the
    # beginning of that turn.
    mtime="$(stat -c %Y "$view" 2>/dev/null || echo 0)"
    case "${mtime:-0}" in ''|*[!0-9]*) mtime=0 ;; esac
    [ "$mtime" -gt 0 ] || continue
    age=$(( NOW_EPOCH - mtime ))
    [ "$age" -ge 0 ] || continue
    if [ "$age" -lt $(( ISSUE_IN_FLIGHT_FRESH_MIN * 60 )) ]; then
      printf '%s %s\n' "$id" "$other_phase"
    fi
  done
  return 0
}

# The slot that owns the issue among the other ones: the one that is
# further along (the phase with more rank) and, in a tie, the lowest id.
# It prints "<id> <phase>".
issue_owner_elsewhere() {
  local issue="$1" best_id="" best_phase="" best_rank=9 id ph rank
  while read -r id ph; do
    [ -n "$id" ] || continue
    rank="$(phase_rank "$ph")"
    if [ "$rank" -lt "$best_rank" ]; then
      best_id="$id"; best_phase="$ph"; best_rank="$rank"
    elif [ "$rank" -eq "$best_rank" ] && [ "$id" -lt "${best_id:-999}" ]; then
      best_id="$id"; best_phase="$ph"
    fi
  done < <(issue_owners_alive "$issue")
  [ -n "$best_id" ] || return 1
  printf '%s %s' "$best_id" "$best_phase"
}

# --- the complete gate alive: the machine is not ours ----------------------
# The complete gate runs the whole test suite of the workspace: it takes
# about ten cores and thirty gigabytes, and its clock tests (a budget of
# 30 s) go red with the load of another cargo in the same box. The gate is
# therefore a HEAVY PHASE like the implement is, and the slot that has
# heavy work cedes the turn while it runs.
#
# The cede happens BEFORE the model is called: no turn file is written, no
# token is spent and the daily cap of the slot is not consumed. The light
# work (the triage, the claim, the reading of a verdict) is NOT ceded: it
# is the work that has to keep flowing while the gate runs.
#
# The phase `implemented` is ceded only when the captures are missing: with
# them on disk the only thing left is the publication (a push), which does
# not compete with the gate.
GATE_BUSY_PID=""
case "${phase:-idle}" in
  claimed|implemented) GATE_BUSY_PID="$(live_gate_pid 2>/dev/null || true)" ;;
esac
if [ -n "$GATE_BUSY_PID" ]; then
  if [ "${phase:-idle}" = "implemented" ]; then
    busy_issue="$(slot_issue 2>/dev/null || true)"
    busy_captures=0
    if [ -n "$busy_issue" ] \
       && ls "$LOOP_DIR/evidence/${busy_issue}"-*.png >/dev/null 2>&1; then
      busy_captures=1
    fi
    if [ "$busy_captures" -eq 1 ]; then
      log "the complete gate is alive (pid $GATE_BUSY_PID): the publication of" \
        "the evidence of #${busy_issue} goes on (the captures are on disk)"
    else
      log "the complete gate is alive (pid $GATE_BUSY_PID): the capture of the" \
        "evidence would compete with it: this slot ($SLOT) cedes the turn"
      exit 0
    fi
  else
    log "the complete gate is alive (pid $GATE_BUSY_PID): the implement would" \
      "compete with it: this slot ($SLOT) cedes the turn"
    exit 0
  fi
fi

# --- the heavy phase: one at a time in the whole machine ------------------
# The rule is hard: at most ONE heavy phase (implement, gate, evidence) at a
# time. The lock is global and short (`.heavy.lock`): the slot that does
# not get it does not do the heavy work.
#
# The complete gate is launched by the model inside the turn and start-gate.sh
# is the one that guarantees a single live gate (it queues the second one).
HEAVY_HELD=0
if [ "$MAX_SLOTS" -gt 1 ] && [ "${phase:-idle}" = "claimed" ]; then
  heavy_owner="$(heavy_owner_slot 2>/dev/null || true)"
  if [ -n "$heavy_owner" ] && [ "$heavy_owner" != "$SLOT" ] && slot_is_running "$heavy_owner"; then
    log "the heavy phase (implement) belongs to the slot $heavy_owner (it is running):" \
      "this slot ($SLOT) cedes the turn"
    exit 0
  fi
  if ! flock -w "${HEAVY_LOCK_WAIT_SEC:-120}" 8; then
    log "the heavy phase is being done by another slot: this slot ($SLOT) cedes the turn"
    exit 0
  fi
  HEAVY_HELD=1
  log "the heavy phase (implement) is taken by the slot $SLOT"
fi

# --- log rotation (G15) --------------------------------------------------
# The logs and the PNGs grow without bound. The ledger is the only thing kept
# forever: it is the loop's memory.
RETENTION="${LOG_RETENTION_DAYS:-14}"
find "$LOG_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime "+$RETENTION" -delete 2>/dev/null || true
find "$LOG_DIR" -maxdepth 1 -type f -name '*.err'  -mtime "+$RETENTION" -delete 2>/dev/null || true
find "$TURN_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime "+$RETENTION" -delete 2>/dev/null || true
find "$LOOP_DIR/evidence" -maxdepth 1 -type f -name '*.png' -mtime "+$RETENTION" -delete 2>/dev/null || true
# the WebP copies of the captures (the ones the agent reads) age the same way
find "$LOOP_DIR/evidence" -maxdepth 1 -type f -name '*.webp' -mtime "+$RETENTION" -delete 2>/dev/null || true
# The gate logs are 40-90 min of cargo output EACH (one per gate) and they
# were never rotated: the directory grew without bound. They are rotated
# apart, with their own window (a week by default, configurable with
# GATE_LOG_RETENTION_DAYS). The log of the gate that is running is never
# touched: cargo keeps its mtime fresh while it writes.
GATE_RETENTION="${GATE_LOG_RETENTION_DAYS:-7}"
# The pattern covers the ROTATED logs too (gate-*.log.1): they are the same
# cargo output and they would pile up forever without being deleted.
find "$LOG_DIR" -maxdepth 1 -type f -name 'gate-*.log*' -mtime "+$GATE_RETENTION" -delete 2>/dev/null || true

# --- the disk garbage collector (once a day) --------------------------------
# The disk used to fill up without anybody noticing: the cargo `incremental`
# caches (94 GB in the main checkout), the worktrees of dead sessions and the
# local branches of closed pull requests grew without bound, and nothing in
# the loop ever removed them. `bin/gc-disk.sh` is the one that does.
#
# It is called on every turn and its own daily guard (DISK_GC_INTERVAL_H)
# makes it run once a day; the call costs a few seconds. Its guards are its
# own: it never touches a target tree with a live cargo, a dirty worktree, a
# branch with an open pull request or the `evidence/*` branches of the fork.
# It always exits 0: a cleanup that fails must never break a turn.
if [ "${DISK_GC_ENABLED:-1}" = "1" ] && [ -x "$LOOP_DIR/bin/gc-disk.sh" ]; then
  bash "$LOOP_DIR/bin/gc-disk.sh" >>"$ERR" 2>&1 || true
fi

# --- the worktree of the issue ---------------------------------------------
# Each issue works in its own worktree: the branch lives there, not in the main
# checkout (the main checkout carries the local AGENTS.md overlay, and a
# `git checkout` there fails and takes the work of the others with it).
#
# The worktree lives OUTSIDE the loop dir on purpose: the workers sandboxes deny
# edit/write under ~/.local/share/solidcraft-loop/** (that deny comes after the
# allow), so a worktree there would be read-only for them.
#
# The worktree is the one of the issue of THIS slot: the worktree of the
# issue of the other slot is never removed (the `git worktree prune` only
# cleans the metadata of the worktrees that are gone).
#
# The path is derived from the issue, so the state needs no field for it.
# (WT_ROOT is read once, at the top of this file: the cleanup of a dead turn
# needs the same root.)
WT_PHASE_OK="no"
case "${phase:-idle}" in
  selected|claimed|implemented|gating|gated) WT_PHASE_OK="yes" ;;
esac
WT_ISSUE="$(slot_field '["issue"]')"
case "${WT_ISSUE:-}" in ''|*[!0-9]*) WT_ISSUE=0 ;; esac
# The issue is in flight in another slot: its worktree is not touched. The
# worktree of an issue is at ONE path and the slot that does not own it
# removes it: two slots on the same issue would erase the work of each
# other. The owner is the slot that is further along (its phase has more
# rank) and, in a tie, the lowest id: without that rule the two slots
# would cede to each other and the issue would stay still.
WT_OWNER=""
WT_OWNER_PHASE=""
if [ "$WT_ISSUE" -gt 0 ]; then
  WT_OWNER_INFO="$(issue_owner_elsewhere "$WT_ISSUE" 2>/dev/null || true)"
  if [ -n "$WT_OWNER_INFO" ]; then
    WT_OWNER="${WT_OWNER_INFO%% *}"
    WT_OWNER_PHASE="${WT_OWNER_INFO#* }"
  fi
fi
WT_PATH=""
if [ "${WT_ISSUE:-0}" -gt 0 ]; then
  WT_PATH="$WT_ROOT/issue-${WT_ISSUE}"
  WT_BRANCH="wt/issue-${WT_ISSUE}"
  if [ "$WT_PHASE_OK" = "yes" ]; then
    # The issue is in flight in another slot that is alive: this slot does
    # not touch the worktree of the issue (it would remove it).
    if [ -n "$WT_OWNER" ]; then
      my_rank="$(phase_rank "${phase:-idle}")"
      owner_rank="$(phase_rank "$WT_OWNER_PHASE")"
      cede=0
      if [ "$owner_rank" -lt "$my_rank" ]; then
        cede=1
      elif [ "$owner_rank" -eq "$my_rank" ] && [ "$WT_OWNER" -lt "$SLOT" ]; then
        cede=1
      fi
      if [ "$cede" -eq 1 ]; then
        log "the issue #$WT_ISSUE is in flight in the slot $WT_OWNER" \
          "(phase $WT_OWNER_PHASE): this slot ($SLOT) cedes the turn" \
          "(the worktree of an issue is at one path)"
        exit 0
      fi
    fi
    WT_BRANCH_NOW=""
    [ -d "$WT_PATH" ] && WT_BRANCH_NOW=$(git -C "$WT_PATH" branch --show-current 2>/dev/null)
    WT_REUSE="no"
    case "${WT_BRANCH_NOW:-}" in
      "$WT_BRANCH"|fix/issue-${WT_ISSUE}-*) WT_REUSE="yes" ;;
    esac
    if [ "$WT_REUSE" != "yes" ]; then
      if [ -d "$WT_PATH" ]; then
        git -C "$REPO" worktree remove --force "$WT_PATH" >/dev/null 2>&1 || rm -rf "$WT_PATH"
      fi
      mkdir -p "$WT_ROOT" 2>/dev/null || true
      git -C "$REPO" worktree prune >/dev/null 2>&1 || true
      if git -C "$REPO" worktree add --detach "$WT_PATH" origin/main >/dev/null 2>&1 \
         && git -C "$WT_PATH" checkout -B "$WT_BRANCH" >/dev/null 2>&1; then
        log "issue #${WT_ISSUE}: worktree created at $WT_PATH (branch $WT_BRANCH)"
      else
        log "issue #${WT_ISSUE}: could not create the worktree (the turn uses the main checkout)"
        WT_PATH=""
      fi
    fi
    # The house rules travel with the worktree: the workers read them and
    # they have to be the rules of the LOOP, not only the ones of upstream.
    # They are installed in an UNTRACKED, excluded file (`.house-rules.md`),
    # so no versioned file is modified and the tree stays clean (the
    # pre-flight would park the loop otherwise). It is done also when the
    # worktree is reused: the rules could be missing there (a worktree
    # created before this change).
    if [ -n "$WT_PATH" ] && [ -d "$WT_PATH" ]; then
      bash "$LOOP_DIR/bin/house-rules.sh" install "$WT_PATH" >/dev/null 2>&1 \
        || log "warning: the house rules could not be installed in $WT_PATH"
    fi
  else
    # The issue is done: its worktree is not needed any more.
    #
    # NOT when another alive slot is working on the issue RIGHT NOW: the
    # worktree of an issue is at one path and that slot is working inside
    # it. The removal is deferred to the turn in which that slot is done.
    if [ -n "$WT_OWNER" ]; then
      log "the worktree of the issue #$WT_ISSUE is not removed: the slot" \
        "$WT_OWNER is working on it"
    elif [ -d "$WT_PATH" ]; then
      git -C "$REPO" worktree remove --force "$WT_PATH" >/dev/null 2>&1 || rm -rf "$WT_PATH"
      git -C "$REPO" worktree prune >/dev/null 2>&1 || true
      log "issue #${WT_ISSUE}: worktree removed ($WT_PATH)"
    fi
  fi
fi


# --- the turn ------------------------------------------------------------
if [ -n "${WT_PATH:-}" ] && [ -d "$WT_PATH" ]; then
  cd "$WT_PATH" || { log "cannot enter $WT_PATH"; exit 1; }
else
  cd "$REPO" || { log "cannot enter $REPO"; exit 1; }
fi

# Upstream's main moves (on 22-10-23 upstream's CI was red at 0db2abbe and
# green at b0048a61). Without this fetch the loop branches from a stale main
# and its PRs are born with conflicts the maintainer has to resolve. This is
# not a catch-up of an open PR: it is having the right base to branch from.
# It runs BEFORE the reset below, so the reset lands on the fresh main.
#
# The fetch updates the refs of the SHARED repository: two concurrent
# fetches fight for the lock of the refs of git. It has its own lock.
if flock -w "${FETCH_LOCK_WAIT_SEC:-300}" 7; then
  git -C "$REPO" fetch --prune origin 2>>"$ERR" \
    || log "git fetch origin failed (continuing with the current origin/main)"
  flock -u 7
else
  log "another slot is fetching: the turn goes on with the current origin/main"
fi

# --- (d) `main` is at `origin/main` ----------------------------------------
# The fourth check of the pre-flight: it needs the fetch, so it runs after
# it. The turn branches from `origin/main`: a `main` that is behind produces
# PRs born with conflicts and a rebase that fights the upstream.
#
# The fast-forward NEVER throws away commits: `merge --ff-only` fails when
# the branches diverged and the failure is a warning, not a reset. It is only
# done with `main` checked out (on the issue branch it would move the branch
# of the work in flight).
if [ "$(git -C "$REPO" branch --show-current 2>/dev/null)" = "main" ]; then
  if ! git -C "$REPO" merge --ff-only origin/main 2>/dev/null; then
    log "warning: main is not at origin/main and it cannot be fast-forwarded (it has diverged)"
  fi
else
  local_main="$(git -C "$REPO" rev-parse main 2>/dev/null || true)"
  origin_main="$(git -C "$REPO" rev-parse origin/main 2>/dev/null || true)"
  if [ -n "$local_main" ] && [ -n "$origin_main" ] && [ "$local_main" != "$origin_main" ]; then
    log "warning: main ($local_main) is not at origin/main ($origin_main): the turn branches from origin/main"
  fi
fi

# --- main checkout -------------------------------------------------------
# It is the loop's working area (the issue branch lives there). If a turn
# leaves it dirty, the next sc-claim starts on a dirty tree. It is only cleaned
# when nothing is in flight: a cleanup with the issue branch unpushed would
# lose the work. (the cleanup itself is in the helper `reset_checkout`: it is
# also used when a turn is killed).
if [ "$GATE_ALIVE" -eq 0 ] && { [ "${phase:-idle}" = "idle" ] || [ "${phase:-idle}" = "failed" ] || [ "${phase:-idle}" = "skipped" ]; }; then
  reset_checkout
fi

# The view of the slot is written BEFORE the turn: it is what the model
# reads. It is rewritten by state.py at the end of the turn (with the delta
# applied), so the next turn always starts from a fresh view.
write_slot_view

# The digest is written right after the view: it is the summary of it (the
# state of the slot and the last turns of the ledger) that the model reads
# FIRST, so it does not have to read the view whole nor the ledger whole.
write_slot_digest

STAMP="$(date -u +%FT%H%M%SZ)-$$"
# The slot is in the name of the log of the turn: the daily turn cap counts
# the turns of THIS slot (the cap is split between the slots) and the metrics
# of the slots read the slot from the name.
TURN_LOG="$TURN_DIR/${STAMP}-slot${SLOT}.jsonl"
# The session id carries the SLOT: the sweep of the orphans deletes the
# sessions of the turns that are over, and with two slots it must be able to
# tell whose session it is. The id also has to be unique: the stamp already
# has the pid, so two slots never collide.
SID="ses_loop-${STAMP}-slot${SLOT}"
rc=0
KILLED_TURN=0
# The marker of the token watchdog. It is written by the watchdog BEFORE it
# stops the turn, so the supervisor finds it as soon as the turn is over.
TOKEN_MARKER="$TURN_DIR/${STAMP}.budget"
rm -f "$TOKEN_MARKER"
WATCHDOG_PID=0
if [ "${DRY_RUN:-0}" = "1" ]; then
  # Test mode: the model is not called, a turn with a delta is simulated.
  printf '%s\n' '{"type":"text","part":{"text":"dry run\n```json\n{\"phase\": \"idle\", \"summary\": \"dry run: the model was not called\"}\n```"}}' > "$TURN_LOG"
  log "DRY_RUN=1: simulated turn"
else
  # The watchdog of the token budget: it reads the tokens the turn has spent
  # (the same ones the audit counts) and stops the turn when it goes over the
  # budget. It matches the process by the session id, so it only ever touches
  # the turn of THIS slot.
  if [ "$TURN_TOKEN_BUDGET" -gt 0 ]; then
    "$TURN_TOKEN_WATCHDOG" "$TURN_LOG" "$SID" "$TURN_TOKEN_BUDGET" "$TOKEN_MARKER" 10 \
      >>"$ERR" 2>&1 &
    WATCHDOG_PID=$!
    log "the token watchdog is watching this turn (budget ${TURN_TOKEN_BUDGET} tokens, pid ${WATCHDOG_PID})"
  fi
  # The turn spec IS the message. `opencode run -f file` only ATTACHES a file
  # to a message: on its own it fails with "You must provide a message", and
  # the turn dies before doing anything.
  #
  # The message is composed by `compose_prompt`: the header of the slot and
  # the prompt of the iteration. The query `--prompt` prints the SAME
  # message, so the test does not read the source of the rule.
  PROMPT="$(compose_prompt)"
  # The house rules of the loop are ALSO in a file of the working directory of
  # the WORKERS (`.house-rules.md`: untracked, excluded, and the ONLY copy of
  # the rules that does not touch a versioned file). The PATH is given, never
  # the content pasted: the rules of the repository (AGENTS.md and skills/)
  # are the source of truth when the two disagree.
  #
  # The turn runs in the main checkout, but the workers work in the worktree
  # of the issue: the rules are looked for THERE first, because that is the
  # directory the worker sees and the one it may read. When there is no
  # worktree (the issue is done, or it could not be created) the canonical
  # copy of the loop is given instead: the orchestrator may read it (it is
  # under the loop directory) and it passes the path to the worker.
  RULES_IN_CWD=""
  if [ -n "${WT_PATH:-}" ] && [ -d "${WT_PATH:-}" ]; then
    RULES_IN_CWD="$(bash "$LOOP_DIR/bin/house-rules.sh" path "$WT_PATH" 2>/dev/null || true)"
  fi
  [ -n "$RULES_IN_CWD" ] || RULES_IN_CWD="$(bash "$LOOP_DIR/bin/house-rules.sh" path "$PWD" 2>/dev/null || true)"
  if [ -z "$RULES_IN_CWD" ] && [ -f "$LOOP_DIR/bin/house-rules.md" ]; then
    RULES_IN_CWD="$LOOP_DIR/bin/house-rules.md"
  fi
  if [ -n "$RULES_IN_CWD" ]; then
    PROMPT="$PROMPT

The house rules of this loop are in $RULES_IN_CWD. Read that file before you
work: it is the rulebook of the loop, and the rules of the repository
(AGENTS.md and skills/) are the source of truth when the two disagree. The
workers work in a different directory: pass them the PATH of that file (they
read it themselves, they never need the content pasted here)."
  fi
  # --kill-after: `timeout` signals the turn, but a turn that does not stop
  # at the first SIGTERM (a tool that is in the middle of something) would
  # keep the turn alive forever and the timeout would wait for it. The
  # SIGKILL after the grace period makes the deadline real.
  timeout --foreground --kill-after="${TURN_KILL_GRACE_SEC:-120}" "${TURN_BUDGET_MIN}m" \
    "$OPENCODE_BIN" run --standalone --auto \
    --model "${MODEL:-minimax/MiniMax-M3.1-Flash}" \
    --agent sc-orchestrator \
    --session "$SID" \
    --format json \
    "$PROMPT" \
    >"$TURN_LOG" 2>>"$ERR" || rc=$?
fi
# The watchdog must not outlive the turn: it is stopped here. The marker was
# written before the turn was stopped, so nothing is lost by killing it now.
if [ "$WATCHDOG_PID" -gt 0 ]; then
  kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=0
fi
cat "$TURN_LOG" >>"$JSONL" 2>/dev/null || true
echo "EXIT=$rc" >>"$ERR"
log "turn finished with EXIT=$rc (log: $TURN_LOG)"

# --- the turn was stopped by the token budget ------------------------------
# The marker is only there when the watchdog found the turn over the budget
# AND stopped it. The delta of a turn is emitted at its very end, so a turn
# stopped here produced no delta: it is handled exactly like a turn that was
# killed (phase failed, checkout reset) and the issue is retried.
if [ -f "$TOKEN_MARKER" ]; then
  spent="$(tr -dc '0-9' < "$TOKEN_MARKER" | head -c 14)"
  log "the turn went over its token budget (${spent:-?} tokens > ${TURN_TOKEN_BUDGET}): it was stopped and it produced no delta"
  rm -f "$TOKEN_MARKER"
  rc=124
  KILLED_TURN=1
fi

# --- the turn was killed --------------------------------------------------
# rc=124 is `timeout`'s code (the budget ran out), 137 is the SIGKILL of
# the grace period and 143 is SIGTERM (systemd's TimeoutStartSec, or a
# manual stop). A killed turn produces NO delta: without this the phase
# stays `claimed` forever and the checkout stays dirty, and the next turn
# inherits a half-done tree. The phase is marked `failed` and the checkout
# is reset to origin/main.
# A gate that is still running is NOT stranded: the phase stays `gating` and
# the next turn reads its log (the gate lives in its own worktree, so the
# reset of the main checkout does not disturb it).
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ] || [ "$rc" -eq 130 ]; then
  log "the turn was killed (EXIT=$rc, budget ${TURN_BUDGET_MIN} min): the phase is marked and the checkout is reset"
  handle_killed_turn 0
  KILLED_TURN=1
fi

# --- rate limit and transport: the cooldown and the backoff ---------------
# ONLY the error events count. The assistant's own text is not evidence: the
# turn reads config.env, whose comments literally say "rate limit", and the
# loop was arming a cooldown on its own documentation.
#
# TWO classes, because they are not the same thing:
#  1) The QUOTA of the provider: `provider.quota` ("The Token Plan usage
#     limit has been reached"). The plan is exhausted: the turn has to
#     wait. This pattern matched NONE of the 32 error events of the 25-10,
#     so the quota was invisible: no cooldown was armed, nothing was
#     logged and nothing was counted.
#  2) The TRANSPORT: `provider.transport` (ECONNRESET). The plan is FINE,
#     the connection broke. It waits a few minutes, with its own backoff,
#     and it never counts as a quota.
EVENT_COUNTS="$(python3 - "$TURN_LOG" <<'PY'
import json, re, sys
# The quota: the plan is exhausted. `provider.quota` is the error the
# provider really sends, and its plain wording is kept too, so a change of
# the wording does not make the quota invisible again.
quota = re.compile(r"provider\.quota|token plan usage limit|rate[ _]?limit|"
                   r"too many requests|resource_exhausted|\b429\b|"
                   r"quota exceeded|secondary rate", re.I)
# The transport: the connection broke. It is NOT a quota.
transport = re.compile(r"provider\.transport|econnreset|econnrefused|etimedout|"
                       r"socket hang up|connection (lost|closed|reset|refused)|"
                       r"fetch failed|network error", re.I)
# The AGENT: opencode does not resolve the agent of the turn. It is not a
# quota and it is not the transport: the configuration of the agents is
# broken, and no amount of waiting fixes it.
agent = re.compile(r"agent not found", re.I)
quota_hits = 0
transport_hits = 0
agent_hits = 0
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") != "error":
                continue
            text = json.dumps(obj.get("error") or obj, ensure_ascii=False)
            # The transport is checked FIRST: a connection that broke is not
            # a quota, whatever else its message says.
            if transport.search(text):
                transport_hits += 1
            elif agent.search(text):
                agent_hits += 1
            elif quota.search(text):
                quota_hits += 1
except OSError:
    pass
print(quota_hits, transport_hits, agent_hits)
PY
)"
read -r QUOTA_HITS TRANSPORT_HITS AGENT_HITS <<<"$EVENT_COUNTS"
[ -n "$QUOTA_HITS" ] || QUOTA_HITS=0
[ -n "$TRANSPORT_HITS" ] || TRANSPORT_HITS=0
[ -n "$AGENT_HITS" ] || AGENT_HITS=0
# The agent that does not resolve: it is NOT a cooldown and NOT a backoff.
# Waiting does not fix a broken agent: the turn has to be READ as a
# configuration failure, and the preflight of the next turn is the one that
# keeps it from happening again.
if [ "$AGENT_HITS" -gt 0 ]; then
  log "ERROR: opencode did not resolve the agent ($AGENT_HITS error events): the turn did nothing"
  log "the agent files live in $HOME/.config/opencode/agents (bin/check-agents.sh says why)"
fi
if [ "$QUOTA_HITS" -gt 0 ]; then
  prev=0
  [ -s "$COOLDOWN_FILE" ] && prev=$(tr -dc '0-9' < "$COOLDOWN_FILE" | head -c 12)
  base=$(( ${prev:-0} > NOW_EPOCH ? prev - NOW_EPOCH : 0 ))
  cool=$(( base * 2 ))
  [ "$cool" -lt "${RATE_LIMIT_COOLDOWN_MIN:-30}" ] && cool="${RATE_LIMIT_COOLDOWN_MIN:-30}"
  [ "$cool" -gt 480 ] && cool=480
  echo $((NOW_EPOCH + cool * 60)) > "$COOLDOWN_FILE"
  log "rate limit detected ($QUOTA_HITS error events): cooldown of ${cool} min"
fi
# The transport failures have their OWN backoff, in their OWN file: the
# connection broke, the plan is fine. It doubles while it repeats and it is
# much shorter than the quota's cooldown: the quota waits for the plan, a
# broken socket waits for the network. The floor is TRANSPORT_BACKOFF_MIN
# (5 min by default; config.env can raise it).
if [ "$TRANSPORT_HITS" -gt 0 ]; then
  prev=0
  [ -s "$TRANSPORT_COOLDOWN_FILE" ] && prev=$(tr -dc '0-9' < "$TRANSPORT_COOLDOWN_FILE" | head -c 12)
  # The remaining MINUTES of the last backoff, doubled.
  base=$(( ( ${prev:-0} > NOW_EPOCH ? prev - NOW_EPOCH : 0 ) / 60 ))
  back=$(( base * 2 ))
  [ "$back" -lt "${TRANSPORT_BACKOFF_MIN:-5}" ] && back="${TRANSPORT_BACKOFF_MIN:-5}"
  [ "$back" -gt 60 ] && back=60
  echo $((NOW_EPOCH + back * 60)) > "$TRANSPORT_COOLDOWN_FILE"
  log "transport failure detected ($TRANSPORT_HITS error events): backoff of ${back} min"
fi

# --- apply the delta and keep the bookkeeping ----------------------------
# The delta of the model is applied to the slot of THIS invocation: the slot
# is decided by the supervisor (the environment), never by the model.
#
# The flags of the v2 state (`--slot`, `--slot-view`) arrive with the
# schema: passing a flag that argparse does not know would make the whole
# invocation fail and the delta would be lost, so they are only passed when
# this state.py knows them.
state_py_knows() {
  grep -q -- "\"$1\"" "$LOOP_DIR/bin/state.py" 2>/dev/null
}
STATE_ARGS=(
  --state "$STATE"
  --ledger "$LEDGER"
  --turn-log "$TURN_LOG"
  --config "$LOOP_DIR/config.env"
  --gate-pid-file "$LOOP_DIR/gate.pid"
  --gate-started-file "$LOOP_DIR/gate.started"
  --reports-dir "$LOOP_DIR/reports"
  --loop-dir "$LOOP_DIR"
  --session-id "$SID"
)
if state_py_knows --slot; then
  STATE_ARGS+=(--slot "$SLOT")
fi
if state_py_knows --slot-view; then
  STATE_ARGS+=(--slot-view "$SLOT_VIEW")
fi
python3 "$LOOP_DIR/bin/state.py" "${STATE_ARGS[@]}" || log "state.py failed"
# --- the evidence of the issue: publish it so the PR body can link it ------
# From a fork the pictures cannot be attached to the PR (`gh pr edit --attach`
# uploads the asset to the base repo, where the fork has no write access) and
# a gist does not render a PNG inline. What works, and what the repo
# maintainers do, is a branch of the fork with the raw links. The evidence
# worker cannot do it (its sandbox has no git add/commit), so the supervisor
# does it and leaves the URLs for the NEXT turn, which is the one that writes
# the body of the PR.
if [ "${EVID_ISSUE:-0}" -gt 0 ] && [ -n "${EVID_BRANCH:-}" ]; then
  EVID_PNGS=()
  for png in "$LOOP_DIR/evidence/${EVID_ISSUE}"-*.png; do
    [ -f "$png" ] && EVID_PNGS+=("$png")
  done
  if [ "${#EVID_PNGS[@]}" -gt 0 ]; then
    # The evidence is a heavy phase (it pushes to the fork): with several
    # slots it waits for the heavy lock and it is published in a later turn
    # if another slot has it.
    if [ "$MAX_SLOTS" -gt 1 ] && ! heavy_available; then
      log "the evidence of #${EVID_ISSUE} is not published now:" \
        "another slot is doing the heavy phase"
    else
      EVID_URLS=$(bash "$LOOP_DIR/bin/publish-evidence.sh" "$EVID_BRANCH" \
        "${EVID_PNGS[@]}" 2>>"$ERR")
      if [ -n "$EVID_URLS" ]; then
        printf "%s\n" "$EVID_URLS" > "$LOOP_DIR/evidence/urls-${EVID_ISSUE}.txt"
        log "evidence: published ${#EVID_PNGS[@]} picture(s) of #${EVID_ISSUE}" \
          "to the fork (urls in evidence/urls-${EVID_ISSUE}.txt)"
      fi
    fi
  fi
fi


# A killed turn has no valid delta. If state.py applied one anyway (the model
# emitted a JSON block before it died), the failure is re-asserted here: the
# phase must not go back to `claimed` with a dirty tree. The failure is
# counted only when state.py did not count it (it counts the turns it sees
# as failed).
if [ "${KILLED_TURN:-0}" -eq 1 ]; then
  handle_killed_turn 1
fi

# --- the quick gate: the fast check before the complete gate --------------
# The delta has been applied: the phase it leaves decides whether the quick
# gate is due. `implemented` means the code is committed and the complete
# gate has not been launched yet: that is the moment of the quick gate. The
# phase is read AGAIN (the one read at the beginning of the turn is the one
# BEFORE the delta).
PHASE_AFTER="$(slot_field '["phase"]')"
if [ "${KILLED_TURN:-0}" -eq 0 ] && [ "${PHASE_AFTER:-}" = "implemented" ]; then
  maybe_run_quick_gate "$(issue_worktree 2>/dev/null || true)" \
    "$(slot_field '["branch"]')"
fi

# --- the refusals of the complete gate in THIS turn -----------------------
# The model launches the complete gate (bin/start-gate.sh). That script
# refuses with the exit code 10 when the quick gate is RED for that sha: an
# hour of CI on code that is already known to be broken. The refusal is NOT a
# failure of the turn (the phase stays `implemented` and the next turn fixes
# the code), but it belongs in the log of the supervisor and not only in the
# log of the turn.
GATE_REFUSALS="$(gate_refusals_of_turn 2>/dev/null || true)"
if [ -n "${GATE_REFUSALS:-}" ]; then
  while IFS= read -r refusal; do
    [ -n "$refusal" ] || continue
    log "the complete gate was refused by start-gate.sh: $refusal (not a" \
      "failure of the turn: the phase stays 'implemented')"
  done <<< "$GATE_REFUSALS"
fi

# --- janitor: only the loop's old sessions -------------------------------
# (never touches the user's own sessions)
mapfile -t loop_sessions < <(
  "$OPENCODE_BIN" session list 2>/dev/null | awk '$1 ~ /^ses_loop-/ {print $1}'
)
KEEP=10
if [ "${#loop_sessions[@]}" -gt "$KEEP" ]; then
  for s in "${loop_sessions[@]:$KEEP}"; do
    "$OPENCODE_BIN" session delete "$s" 2>/dev/null || true
  done
  log "janitor: deleted ${#loop_sessions[@]} - $KEEP old loop sessions"
fi

# The copy of ourselves (see the top of this file) is not needed any more.
[ -n "${LOOP_SUPERVISOR_IS_COPY:-}" ] && rm -f "$0" 2>/dev/null

exit 0
