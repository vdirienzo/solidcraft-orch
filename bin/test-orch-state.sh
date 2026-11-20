#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-orch-state.sh - the state accessor ANSWERS, and the summary is fast.
#
# WHY THESE TESTS EXIST (2026-11-17):
#   orch-state.sh is the SANCTIONED way to read the state (RULES.md:94-95):
#   state.json is 30-144 KB and is re-sent on every turn, so the agent reads
#   it BY PARTS. The command the agent runs for "what do I know about this
#   issue?" NEVER ANSWERED: open_prs is a LIST in state.json and the issue
#   branch iterated it as a dict (.items()), so every run died with an
#   AttributeError and an empty stdout (reports/loop-codigo.md:371-399,
#   B10b, open since 2026-11-02).
#
#   And the summary was SLOW: it called slot-stale.sh --hours 1, which makes
#   five calls to GitHub (one per pull request) and took 3m22s measured. The
#   agent waited three and a half minutes to see the state.
#
# WHAT IS TESTED (and why):
#   1. issue <n> with open_prs as a LIST (the real format) -> the PR line;
#   2. issue <n> with an entry that uses "pr" instead of "number" -> the PR
#      line too: the two shapes have to be normalized, not guessed;
#   3. issue <n> with open_prs as a DICT -> it does not die either;
#   4. issue <n> about an issue nobody knows -> a clear message, NEVER a
#      traceback;
#   5. a state that cannot be read -> the error says it, on stderr;
#   6. the summary calls slot-stale.sh --locks (the mode without GitHub);
#   7. the summary NEVER calls gh (a gh stub in the PATH fails loudly);
#   8. the summary SHOWS the locks section (the cut of the old output still
#      works with the new one);
#   9. a slot-stale.sh that fails is NOT hidden (rule 7: the verdict has to
#      reach the exit code);
#  10. the CONTRACT with the unit that splits slot-stale.sh: --locks exists,
#      returns the lock lines and does not call GitHub.
#
# THE TESTS ARE HERMETIC: a temporary ORCH_DIR with a fixture state.json, a
# stub slot-stale.sh that only records how it was called, and a gh stub that
# lives OUTSIDE the PATH of the machine (it is prepended to the PATH of the
# single command under test, and to nothing else).
#
# Run:  bash bin/test-orch-state.sh
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
ORCH_STATE="$HERE/orch-state.sh"
SLOT_STALE="$HERE/slot-stale.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-orch-state.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

[ -f "$ORCH_STATE" ] || { echo "test-orch-state: no existe $ORCH_STATE" >&2; exit 2; }
[ -f "$SLOT_STALE" ] || { echo "test-orch-state: no existe $SLOT_STALE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "test-orch-state: no hay python3" >&2; exit 2; }

# --- the mini orchestrator --------------------------------------------------
ORCH="$TMP/orch"
EMPTY="$TMP/empty"          # a WORKTREES_DIR and a REPO with nothing in them
GH_DIR="$TMP/gh"            # the directory of the gh stub (OUTSIDE the PATH)
mkdir -p "$ORCH/bin" "$EMPTY" "$GH_DIR"

# The gh stub. It lives in $TMP, NOT in the PATH of the machine (rule 4): it
# is prepended to the PATH of the single command under test. It fails
# loudly, so a command that must not talk to GitHub leaves a trace.
export GH_CALLS="$TMP/gh-calls.txt"
cat > "$GH_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS"
echo "test-orch-state: gh fue invocado: $*" >&2
exit 1
STUB
chmod +x "$GH_DIR/gh"
: > "$GH_CALLS"

# Where the stub slot-stale.sh records how it was called.
export LLAMADAS="$TMP/llamadas.txt"
: > "$LLAMADAS"

# The script under test, against the temporary ORCH_DIR.
run_state() {
  ORCH_DIR="$ORCH" WORKTREES_DIR="$EMPTY" REPO="$EMPTY" SOLIDCRAFT_REPO="$EMPTY" \
    PATH="$GH_DIR:$PATH" bash "$ORCH_STATE" "$@"
}

# A fixture state.json. open_prs is a LIST, the real format: the entries use
# "number", and one of them uses "pr".
fixture() {
  cat > "$ORCH/state.json"
}

# The stub of slot-stale.sh: it does not do the work, it records how it was
# called and prints what it was told to print.
stub_slot_stale() {
  cat > "$ORCH/bin/slot-stale.sh" <<'STUB'
#!/usr/bin/env bash
echo "slot-stale.sh $*" >> "$LLAMADAS"
echo "  slot 4712    lock de hace 5h  owner agente-1"
exit 0
STUB
  chmod +x "$ORCH/bin/slot-stale.sh"
}

# --- 1. the issue command (C1) ----------------------------------------------
fixture <<'EOF'
{
  "updated_at": "2026-11-17T10:00:00",
  "pending": [{"kind": "review", "what": "responder el PR 11205", "action": "mirar los comments"}],
  "slots": {"4712": {"issue": 7114, "status": "running"}},
  "gates": {"7114": {"verdict": "VERDE-SCOPE"}},
  "open_prs": [
    {"number": 11205, "issue": 7114, "state": "OPEN", "head": "aaaa"},
    {"number": 11207, "issue": 9999, "state": "DRAFT"}
  ]
}
EOF
out="$(run_state issue 7114 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PR #11205'; then
  ok "issue <n> with open_prs as a LIST (number) prints the PR and exits 0"
else
  no "issue <n> with open_prs as a LIST (number) prints the PR and exits 0" "rc=$rc out=[$out] err=[$err]"
fi
if printf '%s' "$err" | grep -q 'Traceback'; then
  no "issue <n> with open_prs as a LIST (number) does NOT print a traceback" "err=[$err]"
else
  ok "issue <n> with open_prs as a LIST (number) does NOT print a traceback"
fi

# The same, with the entry that uses "pr" instead of "number".
fixture <<'EOF'
{
  "updated_at": "2026-11-17T10:00:00",
  "pending": [],
  "slots": {},
  "gates": {},
  "open_prs": [{"pr": 11205, "issue": 7114, "state": "OPEN"}]
}
EOF
out="$(run_state issue 7114 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PR #11205'; then
  ok "issue <n> with the entry that uses 'pr' instead of 'number' prints the PR too"
else
  no "issue <n> with the entry that uses 'pr' instead of 'number' prints the PR too" "rc=$rc out=[$out] err=[$err]"
fi

# open_prs as a DICT (the other format): it does not die either.
fixture <<'EOF'
{
  "updated_at": "2026-11-17T10:00:00",
  "pending": [],
  "slots": {},
  "gates": {},
  "open_prs": {"11205": {"issue": 7114, "state": "OPEN"}}
}
EOF
out="$(run_state issue 7114 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if ! printf '%s' "$err" | grep -q 'Traceback' && \
   { { [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PR #11205'; } || \
     printf '%s' "$out" | grep -qi 'open_prs\|format'; }; then
  ok "issue <n> with open_prs as a DICT does not crash: it normalizes or says which format it expects"
else
  no "issue <n> with open_prs as a DICT does not crash: it normalizes or says which format it expects" "rc=$rc out=[$out] err=[$err]"
fi

# An issue nobody knows about: a clear message, never a traceback.
fixture <<'EOF'
{
  "updated_at": "2026-11-17T10:00:00",
  "pending": [],
  "slots": {},
  "gates": {},
  "open_prs": [{"number": 11205, "issue": 7114, "state": "OPEN"}]
}
EOF
out="$(run_state issue 424242 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if ! printf '%s' "$err" | grep -q 'Traceback' && \
   { [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qi 'nothing recorded\|424242'; }; then
  ok "issue <n> about an issue nobody knows: a clear message and no traceback"
else
  no "issue <n> about an issue nobody knows: a clear message and no traceback" "rc=$rc out=[$out] err=[$err]"
fi

# A state that cannot be read: the error says it, on stderr, and the rc is
# not 0 (rule 7).
printf 'this is not json' > "$ORCH/state.json"
out="$(run_state issue 7114 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qi 'unreadable\|ilegible\|no se pudo leer' && \
   ! printf '%s' "$err" | grep -q 'Traceback'; then
  ok "an unreadable state.json: the error says it (stderr) and the rc is not 0"
else
  no "an unreadable state.json: the error says it (stderr) and the rc is not 0" "rc=$rc out=[$out] err=[$err]"
fi

# --- 2. the summary (C2) ---------------------------------------------------
# The fixture state again: the summary reads slots, open_prs, gates, pending.
fixture <<'EOF'
{
  "updated_at": "2026-11-17T10:00:00",
  "pending": [{"kind": "review", "what": "responder el PR 11205", "action": "mirar los comments"}],
  "slots": {"4712": {"issue": 7114, "status": "running"}},
  "gates": {"7114": {"verdict": "VERDE-SCOPE"}},
  "open_prs": [{"number": 11205, "issue": 7114, "state": "OPEN"}]
}
EOF

# 2.1 the summary calls slot-stale.sh with --locks (the mode without GitHub).
stub_slot_stale
: > "$LLAMADAS"
out="$(run_state summary 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
llamadas="$(cat "$LLAMADAS")"
if printf '%s' "$llamadas" | grep -q -- '--locks'; then
  ok "the summary calls slot-stale.sh --locks (the mode that does not touch GitHub)"
else
  no "the summary calls slot-stale.sh --locks (the mode that does not touch GitHub)" "calls=[$llamadas] err=[$err]"
fi

# The threshold does not change: the summary shows the same slots it always
# showed, it just does not pay GitHub for them.
if printf '%s' "$llamadas" | grep -q -- '--hours 1'; then
  ok "the summary keeps the --hours 1 threshold of the old call"
else
  no "the summary keeps the --hours 1 threshold of the old call" "calls=[$llamadas] err=[$err]"
fi

# 2.2 the summary SHOWS the locks section: the cut of the old output still
# works with the new one.
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'slot 4712'; then
  ok "the summary shows the locks section"
else
  no "the summary shows the locks section" "rc=$rc out=[$out] err=[$err]"
fi

# 2.3 the summary does NOT call gh (the real slot-stale.sh, a gh stub in the
# PATH that fails loudly). With the locks dir present, the old --hours 1 call
# reached GitHub; --locks must not.
cp "$SLOT_STALE" "$ORCH/bin/slot-stale.sh"
mkdir -p "$ORCH/locks"
: > "$GH_CALLS"
out="$(run_state summary 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if [ -s "$GH_CALLS" ]; then
  no "the summary does NOT call gh" "gh was called: $(cat "$GH_CALLS")"
else
  ok "the summary does NOT call gh"
fi
# ...and the summary really READ the locks (a summary that could not read
# them does not call gh either: it would pass the test above for the wrong
# reason).
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ningun slot atascado\|slot '; then
  ok "the summary READ the locks of slot-stale.sh --locks and exits 0"
else
  no "the summary READ the locks of slot-stale.sh --locks and exits 0" "rc=$rc out=[$out] err=[$err]"
fi

# 2.4 a slot-stale.sh that fails is NOT hidden (rule 7).
cat > "$ORCH/bin/slot-stale.sh" <<'STUB'
#!/usr/bin/env bash
echo "slot-stale.sh: no se pudo leer el estado de los locks" >&2
exit 6
STUB
chmod +x "$ORCH/bin/slot-stale.sh"
out="$(run_state summary 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if [ "$rc" -ne 0 ] || printf '%s\n%s\n' "$out" "$err" | grep -qi 'no se pudo leer el estado de los locks'; then
  ok "a slot-stale.sh that fails is not hidden: rc!=0 or an explicit warning"
else
  no "a slot-stale.sh that fails is not hidden: rc!=0 or an explicit warning" "rc=$rc out=[$out] err=[$err]"
fi

# The rc of the thing that failed is PROPAGATED, not replaced by a generic 1
# (rule 7: the one that reports propagates the rc).
if [ "$rc" -eq 6 ]; then
  ok "the summary propagates the rc of slot-stale.sh (6 = UNKNOWN)"
else
  no "the summary propagates the rc of slot-stale.sh (6 = UNKNOWN)" "rc=$rc out=[$out] err=[$err]"
fi

# The stdout must not lie either: a reader that only sees the output cannot
# read "there is nothing stuck" when the truth is "I could not look".
if printf '%s' "$out" | grep -qi 'no se pudo leer\|UNKNOWN'; then
  ok "the output of the summary says that the locks could NOT be read"
else
  no "the output of the summary says that the locks could NOT be read" "rc=$rc out=[$out] err=[$err]"
fi

# 2.5 the CONTRACT with the unit that splits slot-stale.sh: --locks exists,
# it returns the lock lines and it does not call GitHub.
cp "$SLOT_STALE" "$ORCH/bin/slot-stale.sh"
mkdir -p "$ORCH/locks"
: > "$GH_CALLS"
out="$(ORCH_DIR="$ORCH" WORKTREES_DIR="$EMPTY" REPO="$EMPTY" SOLIDCRAFT_REPO="$EMPTY" \
       PATH="$GH_DIR:$PATH" bash "$SLOT_STALE" --locks 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if [ "$rc" -eq 0 ] && [ ! -s "$GH_CALLS" ]; then
  ok "the contract with the other unit: slot-stale.sh --locks exists and does not call gh"
else
  no "the contract with the other unit: slot-stale.sh --locks exists and does not call gh" "rc=$rc out=[$out] err=[$err]"
fi

# --- the HISTORY is readable (2026-11-17) -----------------------------------
# The command the HANDOFF documents ("bin/orch-state.sh history 10") died
# with a SyntaxError: the Python was in single quotes and the f-string used
# escaped double quotes, which is a SyntaxError before Python 3.12.
#
# EL HISTORIAL SE LEE EN EL DIRECTORIO DE PRUEBA, NUNCA EN EL REAL (2026-11-20).
#
# POR QUE: esta suite escribia su fixture sobre "$ORCH_DIR/history.jsonl", y
# ORCH_DIR es el directorio del orquestador de verdad (en esta maquina el repo
# del orquestador y el directorio del loop son el mismo fichero). La suite
# BORRABA el historial del loop cada vez que se corria, y el repo manda
# correr la suite antes de cada commit: las dos entradas de la sesion
# anterior (13:48) se perdieron asi el 20-11-2026. Un test que borra la
# memoria del loop es peor que un test que no existe.
mkdir -p "$ORCH"
printf '{"at":"2026-11-17T10:00:00Z","action":"algo paso"}\n{"at":"2026-11-17T11:00:00Z","action":"otra cosa"}\n' > "$ORCH/history.jsonl"
out="$(ORCH_DIR="$ORCH" bash "$ORCH_STATE" history 5 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "algo paso" && ! printf '%s' "$out" | grep -qi "SyntaxError"; then
  ok "the history is readable and prints the actions"
else
  no "the history is readable and prints the actions" "rc=$rc out=[$out]"
fi

# --- the verdict ------------------------------------------------------------
printf '\n%d ok, %d FALLA\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
