#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-slot-stale.sh - the watchdog of the stuck slots SEES the locks.
#
# WHY THIS FILE EXISTS (2026-11-17): slot-stale.sh decides whether a slot is
# STUCK (an agent that took a lock and never let it go) or RESIDUE (a
# worktree without a lock, of an agent that finished). It was BLIND:
#
#   1. The producer (slot-lock.sh) writes $ORCH_DIR/locks/slot-<name>/{pid,
#      since,owner} as SEPARATE files, and the watchdog looked for a single
#      file named "lock" that nobody writes. The line that decides "this
#      worktree has no lock" therefore NEVER matched: a slot with a LIVE lock
#      was reported as "(SIN LOCK)" and counted as residue instead of stuck
#      (reports/loop-codigo.md:132-161, B2).
#   2. It took 3m22s: five calls to gh, one per pull request, and the summary
#      of the state (orch-state.sh) paid that price every time (B11).
#   3. Its errors went to /dev/null: a lock that could not be read was
#      skipped in silence, and "I do not know" was read as "there is nothing
#      there" (B16).
#
# WHAT IS TESTED (and why):
#   1. a REAL lock is reported with its owner and its age (the RED of the
#      blind watchdog);
#   2. an old lock is STUCK, not residue;
#   3. a worktree without a lock is residue, not stuck;
#   4. --locks does NOT call gh;
#   5. --locks prints ONLY the locks section (no pull requests);
#   6. a gh that fails is NOT read as "there are no pull requests": the
#      script says it could not read them and exits with rc!=0 (rule 7);
#   7. a lock that can not be read is NOT skipped in silence.
#
# THE TESTS ARE HERMETIC: a temporary ORCH_DIR, a throwaway git repository
# with a worktree, and a gh stub that lives OUTSIDE the PATH of the machine
# (README rule 4): the script picks it up with GH_BIN and the PATH of the
# test has the real gh removed, so a call that does not go through GH_BIN
# fails loudly instead of touching GitHub.
#
# Run:  bash bin/test-slot-stale.sh
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/slot-stale.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-slot-stale.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FALLO- %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fail=$((fail+1)); }

[ -f "$SCRIPT" ] || { echo "test-slot-stale: no existe $SCRIPT" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "test-slot-stale: no hay git" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "test-slot-stale: no hay jq" >&2; exit 2; }
command -v date >/dev/null 2>&1 || { echo "test-slot-stale: no hay date" >&2; exit 2; }

# --- the mini orchestrator ---------------------------------------------------
ORCH="$TMP/orch"      # the ORCH_DIR: the locks and the state live here
WT="$TMP/wt"          # the WORKTREES_DIR: issue-<slot>/
REPO="$TMP/repo"      # the repository of SolidCraft (a throwaway one)
STUB="$TMP/stub"      # the gh stub, OUTSIDE the PATH of the machine
mkdir -p "$ORCH/locks" "$WT" "$REPO" "$STUB"

# --- the stub of gh ---------------------------------------------------------
# It NEVER touches the network: it answers from the fixtures and it records
# every call. GH_STUB_FAIL=1 makes it fail, like a GitHub that is down or a
# token that expired: that is the case in which the script must NOT say
# "there are no pull requests".
cat > "$STUB/gh" <<'STUB_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
  echo "gh: no se pudo leer la API (stub)" >&2
  exit 1
fi
case "$1 $2" in
  "pr list")
    # the list of ALL the pull requests (the residue check) and the list of
    # OURS (the ones that wait for our answer) are two different calls.
    if printf '%s\n' "$*" | grep -q -- "--author"; then
      cat "${GH_MINE_FIXTURE:-/dev/null}"
    else
      cat "${GH_LIST_FIXTURE:-/dev/null}"
    fi
    exit 0 ;;
  "api graphql")
    cat "${GH_GRAPHQL_FIXTURE:-/dev/null}"
    exit 0 ;;
esac
printf '[]\n'
exit 0
STUB_GH
chmod +x "$STUB/gh"
export GH_BIN="$STUB/gh"
export GH_LOG="$TMP/gh.log"
export GH_LIST_FIXTURE="$TMP/prs.json"
export GH_MINE_FIXTURE="$TMP/mine.json"
export GH_GRAPHQL_FIXTURE="$TMP/waiting.json"
: > "$GH_LOG"

# THE REAL gh MUST NOT BE REACHABLE from this test: a test that talks to
# GitHub is not a test. The stub lives OUTSIDE the PATH (README rule 4) and
# the script uses it through GH_BIN; the directory of the real gh is taken
# out of the PATH, so a call that ignored GH_BIN fails instead of hitting the
# network.
real_gh="$(command -v gh || true)"
if [ -n "$real_gh" ]; then
  real_gh_dir="$(dirname "$real_gh")"
  PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$real_gh_dir" | paste -sd: -)"
  export PATH
fi

# --- the throwaway repository ------------------------------------------------
(
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email "test@example.com"
  git config user.name "test"
  printf 'base\n' > file.txt
  git add -A
  git commit -q -m base
  git update-ref refs/remotes/origin/main main
) >/dev/null 2>&1

# --- the helpers -------------------------------------------------------------
# take_lock <slot> <owner> <hours since the lock was taken>
# THE FORMAT OF THE PRODUCER: slot-lock.sh writes $ORCH_DIR/locks/slot-<name>/
# with pid, since and owner as SEPARATE files.
take_lock() {
  local slot="$1" owner="$2" hours="$3" now d
  d="$ORCH/locks/slot-$slot"
  now="$(date +%s)"
  mkdir -p "$d"
  printf '%s\n' "$$" > "$d/pid"
  printf '%s\n' "$(date -u -d "@$(( now - hours * 3600 ))" +%FT%TZ)" > "$d/since"
  printf '%s\n' "$owner" > "$d/owner"
}

# make_worktree <slot> <branch> <hours since the work moved>
# The work has to LOOK old: the mtime of the files and of the index (the
# index is the one that counts when the worktree is clean, which is the case
# of the agents that burned hours: zero commits and a clean worktree).
make_worktree() {
  local slot="$1" branch="$2" hours="$3" idx when wt
  wt="$WT/issue-$slot"
  when="@$(( $(date +%s) - hours * 3600 ))"
  git -C "$REPO" worktree add -q -b "$branch" "$wt" main >/dev/null 2>&1
  find "$wt" -maxdepth 1 -type f -not -name .git -exec touch -d "$when" {} + 2>/dev/null
  idx="$(git -C "$wt" rev-parse --git-path index 2>/dev/null)"
  [ -n "$idx" ] && [ -f "$idx" ] && touch -d "$when" "$idx" 2>/dev/null
  return 0
}

# write_pr_list <number>|<title>|<body>|<headRefName>|<state>
write_pr_list() {
  local arr="[]" spec n t b head state
  for spec in "$@"; do
    n="${spec%%|*}"; spec="${spec#*|}"
    t="${spec%%|*}"; spec="${spec#*|}"
    b="${spec%%|*}"; spec="${spec#*|}"
    head="${spec%%|*}"; state="${spec##*|}"
    arr="$(jq -n --argjson arr "$arr" --argjson number "$n" --arg title "$t" \
             --arg body "$b" --arg head "$head" --arg state "$state" \
             '$arr + [{number:$number,title:$title,body:$body,headRefName:$head,state:$state}]')"
  done
  printf '%s\n' "$arr" > "$GH_LIST_FIXTURE"
}

# write_mine <number>...: the pull requests of ours that are open
write_mine() {
  local arr="[]" n
  for n in "$@"; do
    arr="$(jq -n --argjson arr "$arr" --argjson number "$n" \
             '$arr + [{number:$number}]')"
  done
  printf '%s\n' "$arr" > "$GH_MINE_FIXTURE"
}

# write_waiting <number>|<who>|<when>: the answer of the GraphQL query, with
# the alias of every pull request (p<number>).
write_waiting() {
  local spec n who at
  local repo="{}"
  for spec in "$@"; do
    n="${spec%%|*}"; spec="${spec#*|}"
    who="${spec%%|*}"; at="${spec##*|}"
    repo="$(jq -n --argjson repo "$repo" --arg key "p$n" --arg who "$who" --arg at "$at" \
             '$repo + {($key): {comments: {nodes: [{author: {login: $who}, createdAt: $at}]}}}')"
  done
  jq -n --argjson repo "$repo" '{data: {repository: $repo}}' > "$GH_GRAPHQL_FIXTURE"
}

# reset: no locks, no worktrees, no pull requests
reset() {
  # the worktrees AND their branches go away: a branch that is still there
  # makes `git worktree add` fail, and the fixture would be a worktree that
  # does not exist.
  for w in "$WT"/*; do
    [ -d "$w" ] && git -C "$REPO" worktree remove --force "$w" >/dev/null 2>&1
  done
  for b in $(git -C "$REPO" branch --format='%(refname:short)' 2>/dev/null | grep -v '^main$'); do
    git -C "$REPO" branch -D "$b" >/dev/null 2>&1
  done
  rm -rf "$ORCH/locks" "$WT"/*
  mkdir -p "$ORCH/locks"
  printf '[]\n' > "$GH_LIST_FIXTURE"
  printf '[]\n' > "$GH_MINE_FIXTURE"
  printf '{"data":{"repository":{}}}\n' > "$GH_GRAPHQL_FIXTURE"
  : > "$GH_LOG"
}

# run_stale [args...] -> the output in $OUT, the rc in $RC, stderr in $ERR
run_stale() {
  OUT="$(ORCH_DIR="$ORCH" WORKTREES_DIR="$WT" REPO="$REPO" SOLIDCRAFT_REPO="$REPO" \
    bash "$SCRIPT" "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}

# --- 1. a REAL lock is reported with its owner and its age -------------------
echo "== un lock real se reporta con su dueno y su edad =="

reset
take_lock 4712 "agente-1" 5
make_worktree 4712 issue-4712-fix 6
run_stale --hours 1 --json

if printf '%s' "$OUT" | grep -q '"slot":"4712"'; then
  ok "el slot del lock real aparece en el reporte"
else
  no "el slot del lock real aparece en el reporte" "rc=$RC out=[$OUT] err=[$ERR]"
fi

if printf '%s' "$OUT" | grep -q '"owner":"agente-1"'; then
  ok "el lock real se reporta con su dueno"
else
  no "el lock real se reporta con su dueno" "rc=$RC out=[$OUT] err=[$ERR]"
fi

if printf '%s' "$OUT" | grep -q '"lock_age_h":5'; then
  ok "el lock real se reporta con su edad (5h)"
else
  no "el lock real se reporta con su edad (5h)" "rc=$RC out=[$OUT] err=[$ERR]"
fi

if printf '%s' "$OUT" | grep -q 'SIN LOCK'; then
  no "el lock real NO se reporta como '(SIN LOCK)'" "out=[$OUT]"
else
  ok "el lock real NO se reporta como '(SIN LOCK)'"
fi

# --- 2. an old lock is STUCK, not residue ------------------------------------
echo
echo "== un lock viejo es ATASCADO, no residuo =="

reset
take_lock 4712 "agente-1" 5
make_worktree 4712 issue-4712-fix 6
# a pull request that closes the issue: with the OLD watchdog the slot was
# classified as residue (its lock was never seen).
write_pr_list '11205|Fixes #4712|Fixes #4712|issue-4712-fix|OPEN'
run_stale --hours 1 --json

if printf '%s' "$OUT" | grep -q '"state":"residuo"'; then
  no "un slot con lock NO es residuo" "out=[$OUT]"
else
  ok "un slot con lock NO es residuo"
fi

if printf '%s' "$OUT" | grep -q '"slot":"4712"' && printf '%s' "$OUT" | grep -q '"owner":"agente-1"'; then
  ok "el slot con lock viejo queda como atascado, con su dueno"
else
  no "el slot con lock viejo queda como atascado, con su dueno" "rc=$RC out=[$OUT] err=[$ERR]"
fi

# --- 3. a worktree without a lock is residue, not stuck ----------------------
echo
echo "== un worktree sin lock es RESIDUO, no atascado =="

reset
make_worktree 5555 issue-5555-fix 6
write_pr_list '11300|Fixes #5555|Fixes #5555|issue-5555-fix|OPEN'
run_stale --hours 1 --json

if printf '%s' "$OUT" | grep -q '"slot":"5555"' && printf '%s' "$OUT" | grep -q '"state":"residuo"'; then
  ok "el worktree sin lock con su PR publicado es residuo"
else
  no "el worktree sin lock con su PR publicado es residuo" "rc=$RC out=[$OUT] err=[$ERR]"
fi

if printf '%s' "$OUT" | grep -q 'SIN LOCK'; then
  no "el worktree sin lock con su PR publicado NO se reporta como atascado" "out=[$OUT]"
else
  ok "el worktree sin lock con su PR publicado NO se reporta como atascado"
fi

# --- 4. --locks does NOT call gh ---------------------------------------------
echo
echo "== --locks NO llama a GitHub =="

reset
take_lock 4712 "agente-1" 5
make_worktree 4712 issue-4712-fix 6
export GH_STUB_FAIL=1
run_stale --locks
unset GH_STUB_FAIL

if [ "$RC" -eq 0 ]; then
  ok "--locks sale con rc=0 aunque gh este roto (no lo necesita)"
else
  no "--locks sale con rc=0 aunque gh este roto (no lo necesita)" "rc=$RC out=[$OUT] err=[$ERR]"
fi

if [ -s "$GH_LOG" ]; then
  no "--locks NO llama a gh" "gh fue invocado: $(cat "$GH_LOG")"
else
  ok "--locks NO llama a gh"
fi

# --- 5. --locks prints ONLY the locks section --------------------------------
echo
echo "== --locks imprime SOLO la seccion de locks =="

reset
take_lock 4712 "agente-1" 5
make_worktree 4712 issue-4712-fix 6
run_stale --locks --hours 1

if printf '%s' "$OUT" | grep -q 'slot 4712'; then
  ok "--locks imprime la linea del lock"
else
  no "--locks imprime la linea del lock" "rc=$RC out=[$OUT] err=[$ERR]"
fi

if printf '%s' "$OUT" | grep -q 'esperan una respuesta nuestra'; then
  no "--locks NO imprime la seccion de PRs" "out=[$OUT]"
else
  ok "--locks NO imprime la seccion de PRs"
fi

# every line of --locks is a lock line or the count of them
bad_lines="$(printf '%s\n' "$OUT" | grep -vE '^  slot |^  (ningun slot atascado|[0-9]+ slot\(s\) atascado\(s\))' | grep -v '^$')"
if [ -z "$bad_lines" ]; then
  ok "--locks imprime solo lineas de lock (y el contador)"
else
  no "--locks imprime solo lineas de lock (y el contador)" "lineas: $bad_lines"
fi

# --- 6. a gh that fails is NOT "there are no pull requests" ------------------
echo
echo "== un gh que falla NO es 'no hay PRs' =="

reset
take_lock 4712 "agente-1" 5
make_worktree 4712 issue-4712-fix 6
export GH_STUB_FAIL=1
run_stale --hours 1
unset GH_STUB_FAIL

if [ "$RC" -ne 0 ]; then
  ok "el script sale con rc!=0 si no pudo leer los PRs (rc=$RC)"
else
  no "el script sale con rc!=0 si no pudo leer los PRs" "rc=0 out=[$OUT] err=[$ERR]"
fi

if printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'no se pudo leer'; then
  ok "el script dice que NO pudo leer los PRs"
else
  no "el script dice que NO pudo leer los PRs" "out=[$OUT] err=[$ERR]"
fi

# --- 7. a lock that can not be read is NOT skipped in silence ----------------
echo
echo "== un lock que no se puede leer NO se salta en silencio =="

reset
# a directory where a file is expected: it exists and it can NOT be read
mkdir -p "$ORCH/locks/slot-9999/since"
printf 'agente-9\n' > "$ORCH/locks/slot-9999/owner"
run_stale --hours 1

if [ "$RC" -ne 0 ]; then
  ok "el script sale con rc!=0 si no pudo leer un lock (rc=$RC)"
else
  no "el script sale con rc!=0 si no pudo leer un lock" "rc=0 out=[$OUT] err=[$ERR]"
fi

if printf '%s\n%s' "$OUT" "$ERR" | grep -q '9999'; then
  ok "el script dice QUE lock no pudo leer"
else
  no "el script dice QUE lock no pudo leer" "out=[$OUT] err=[$ERR]"
fi

if printf '%s' "$OUT" | grep -q 'ningun slot atascado'; then
  no "el script NO dice 'ningun slot atascado' cuando no pudo leer" "out=[$OUT]"
else
  ok "el script NO dice 'ningun slot atascado' cuando no pudo leer"
fi

# --- 8. the OLD format of the lock is still read -----------------------------
echo
echo "== el formato viejo del lock (un archivo 'lock') tambien se lee =="

reset
mkdir -p "$ORCH/locks/4712"
printf 'since=%s\nowner=agente-legacy\n' \
  "$(date -u -d "@$(( $(date +%s) - 5 * 3600 ))" +%FT%TZ)" > "$ORCH/locks/4712/lock"
make_worktree 4712 issue-4712-fix 6
run_stale --hours 1 --json

if printf '%s' "$OUT" | grep -q '"slot":"4712"' && printf '%s' "$OUT" | grep -q '"owner":"agente-legacy"'; then
  ok "el lock del formato viejo se lee con su dueno"
else
  no "el lock del formato viejo se lee con su dueno" "rc=$RC out=[$OUT] err=[$ERR]"
fi

# --- 9. --prs is the mode that talks to GitHub --------------------------------
echo
echo "== --prs es el modo que habla con GitHub =="

reset
take_lock 4712 "agente-1" 5
make_worktree 4712 issue-4712-fix 6
write_mine 11205 11300
write_waiting '11205|el-mantenedor|2026-11-17T09:00:00Z' '11300|vdirienzo|2026-11-17T10:00:00Z'
run_stale --prs --hours 1

if printf '%s' "$OUT" | grep -q '#11205' && printf '%s' "$OUT" | grep -q 'el-mantenedor'; then
  ok "--prs imprime los PRs que esperan una respuesta"
else
  no "--prs imprime los PRs que esperan una respuesta" "rc=$RC out=[$OUT] err=[$ERR]"
fi

if printf '%s' "$OUT" | grep -q '#11300'; then
  no "--prs NO lista el PR cuyo ultimo comentario es nuestro" "out=[$OUT]"
else
  ok "--prs NO lista el PR cuyo ultimo comentario es nuestro"
fi

if printf '%s' "$OUT" | grep -q 'slot 4712'; then
  no "--prs NO imprime la seccion de locks" "out=[$OUT]"
else
  ok "--prs NO imprime la seccion de locks"
fi

# --- the verdict -------------------------------------------------------------
printf '\n%d ok, %d FALLA\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
