#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ping-ready.sh - leaves ONE review-package comment on each of our pull
# requests that is ready to review, and prints which ones are ready to ping.
#
#   bash bin/ping-ready.sh [--dry-run] [--report] [<pr> ...]
#
# WHY THIS SCRIPT EXISTS (2026-11-07):
#   The upstream CI (ci.yml) has two lanes. The LIGHT one runs on every push
#   (Select checks, Format and repository checks, Quick compile). The HEAVY
#   one (Native Linux tests, Native Linux Clippy, the test build) runs ONLY
#   after a maintainer adds the `approved-for-ci` label: upstream's ci.yml
#   turns `native` off for a pull request without that label and gives it a
#   quick compile instead. Only a maintainer can add that label (a
#   `gh pr edit --add-label` from us answers "does not have the correct
#   permissions to execute AddLabelsToLabelable").
#
#   So the ONE thing we need from the maintainer is `approved-for-ci`.
#   Everything else is on our side. This script leaves in each ready pull
#   request a single comment that says exactly that, with the REAL state of
#   the CI of that head, and then prints a summary the agent reads to decide
#   who to ping.
#
# WHAT IT DOES, in order:
#   1. Takes the pull requests from the arguments; with none, it lists them:
#      `gh pr list --author vdirienzo --state open`.
#   2. For each one it reads the head sha, the labels and the REAL CI of that
#      sha: the check-runs of the HEAD SHA grouped BY NAME, where the most
#      recent one wins (by completed_at). It does NOT use the rollup
#      (statusCheckRollup): the rollup mixes the 'cancelled' of an old run
#      with the 'success' of the new one of the same check and shows a pull
#      request that is green as red. The rule that groups and picks is the
#      house one (pipeline.py, evaluar_check_runs), not a copy of it.
#   3. If there is already a comment of ours with the marker
#      `<!-- ping-ready: sha=<sha> -->` of THAT sha, it does not comment
#      again (idempotent). A comment of ours with another sha is marked as
#      superseded (it is EDITED, never deleted), so the pull request does not
#      ask for the same thing twice.
#   4. The comment asks for ONE thing: that a maintainer add the label
#      `approved-for-ci`. It NEVER asks for a merge (the merge is the
#      maintainer's decision). If the pull request already has that label, it
#      does not ask for it.
#   5. At the end it prints one summary line per pull request:
#        <pr> <sha-corto> <n-atras> <si|no|desconocido> <verde|rojo|pendiente>
#        <si|no> LISTO|FALTA <que falta>
#      That summary is what the agent reads to decide who to ping.
#
# WHO GETS A COMMENT:
#   Only the pull requests that are really ready: the CI of the head is
#   green, the branch MERGES CLEANLY with the current main and the pull
#   request is not a draft. The conflict is measured with `git merge-tree`,
#   which says it exactly and without asking GitHub anything.
#
# WHY THE CONFLICT AND NOT THE "COMMITS BEHIND" (2026-11-08):
#   "Behind main" is INFORMATION, not a block. Upstream merges very fast
#   (81 new commits in five hours on 2026-11-07, with pull requests like
#   #12377, #12515 and #12592), so demanding "0 behind" is a race that is
#   always lost: by the time the comment is posted, main has moved again
#   and every pull request looks stale. On 2026-11-07 all six open pull
#   requests were blocked by that rule although their CI was green and
#   they merged cleanly.
#
#   What the maintainer needs is a pull request that MERGES. That is what
#   `git merge-tree --write-tree --name-only <head> origin/main` says, and
#   it says it exactly. The number of commits behind is still measured and
#   still printed, as data: the agent reads it, but it does not stop the
#   ping.
#
#   A pull request with a red CI, or one whose branch CONFLICTS with the
#   current main, is not pinged: it is reported in the summary as FALTA,
#   with what is missing. That way the pull request does not collect a
#   request that cannot be honoured yet, and it does not contradict the
#   other CI comment the loop leaves (solidcraft-loop/bin/pr-comment.sh).
#
#   If the conflict can NOT be measured (no local clone, the fetch of
#   origin failed, git too old, the head is not in the clone), the state is
#   'desconocido' and the pull request is NOT pinged: it is a safe failure,
#   it never asks for a review of something that could not be checked, and
#   the summary says so.
#
# IT WRITES NOTHING in the SolidCraft working tree: only comments on the
# pull requests. In the local clone of the SolidCraft it only READS the
# history and asks git for a merge that is never made (`merge-tree` writes
# an object and touches no branch). The scripts it touches live in the
# orchestrator (bin/).
#
# EXIT CODE:
#   0  every pull request ended with its comment (or there was nothing to do)
#   1  a pull request could not be read, or its comment could not be
#      published: the others still went through
#
# LANGUAGE of the comment: English, plain, one idea per sentence. The
# maintainer reads English. The script and the summary are in the language of
# the house.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ORCH_DIR: el orquestador. Desde ORCH/bin/ es el padre de HERE; desde la
# COPIA que los crons ejecutan (~/.hermes/scripts/) NO lo es: ahi el padre
# seria ~/.hermes, que no tiene bin/pipeline.py. Por eso se resuelve por la
# REGLA DEL CI: el orquestador es el directorio que tiene bin/pipeline.py. Si
# no hay ninguno (otra PC con otro layout), se queda el default de esta
# maquina, que el ORCH_DIR del ambiente puede pisar.
ORCH_DEFAULT="${ORCH_DEFAULT:-/home/user/.local/share/solidcraft-orch}"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
if [ ! -f "$ORCH_DIR/bin/pipeline.py" ] && [ -f "$ORCH_DEFAULT/bin/pipeline.py" ]; then
  ORCH_DIR="$ORCH_DEFAULT"
fi
REPO="${REPO:-tangency-labs/solidcraft}"
AUTHOR="${AUTHOR:-vdirienzo}"
GH_BIN="${GH_BIN:-gh}"
# The local clone of the upstream. The conflict with main is measured there
# with `git merge-tree`: it says exactly if the branch merges, it does not
# touch the network of GitHub and it does not touch any branch or the
# working tree. GIT_BIN and LOCAL_REPO can be pointed somewhere else (the
# tests do it with a stub).
GIT_BIN="${GIT_BIN:-git}"
LOCAL_REPO="${LOCAL_REPO:-/home/user/solidcraft}"
CI_LABEL="approved-for-ci"

say(){ printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }
die(){ printf '%s\n' "$*" >&2; exit 2; }

usage(){
  cat <<'USAGE' >&2
uso: ping-ready.sh [--dry-run] [--report] [<pr> ...]
  --dry-run  prints what it would do, without commenting anything
  --report   prints only the summary, without commenting anything
  (with no <pr>: it lists them with gh pr list --author vdirienzo --state open)
  se pinguea si el CI del head esta verde y la rama MERGEA LIMPIO con main
  (el conflicto se mide con git merge-tree; 'commits atras' es dato, no bloqueo)
  resumen: <pr> <sha> <n-atras> <si|no|desconocido> <verde|rojo|pendiente> <si|no> LISTO|FALTA <que falta>
USAGE
}

MODE=post
PRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --report)  MODE=report ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do PRS+=("$1"); shift; done; break ;;
    -*) die "opcion desconocida: $1" ;;
    *) PRS+=("$1") ;;
  esac
  shift
done

command -v python3 >/dev/null || die "no hay python3"

# The rule of the CI (group the check-runs by name and keep the most recent)
# lives in pipeline.py. It is USED, not copied.
PIPELINE_PY=""
for cand in "$ORCH_DIR/bin/pipeline.py" "$HERE/pipeline.py"; do
  [ -f "$cand" ] && { PIPELINE_PY="$cand"; break; }
done
[ -n "$PIPELINE_PY" ] || die "no encuentro pipeline.py: la regla del CI vive ahi"
export PIPELINE_DIR="$(dirname "$PIPELINE_PY")"
export ORCH_DIR
export AUTHOR REPO

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ping-ready.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# the analyzer: it reads the JSON the gh calls brought and says what has to
# be known about the pull request. It is pure: it does not touch the network.
# ---------------------------------------------------------------------------
cat > "$TMP/analyze.py" <<'PY'
import json, os, sys

sys.path.insert(0, os.environ.get("PIPELINE_DIR", "."))
import pipeline

# The jobs of the HEAVY lane that run on a pull request with the label: the
# native tests and the native clippy. ("Build tests" only runs on the
# schedule, the GPU tests only for render changes, the doc tests and the
# reference tests only on main.)
HEAVY = ("Native Linux tests", "Native Linux Clippy")
ROJO = ("failure", "timed_out", "action_required", "startup_failure")
AUTHOR = os.environ.get("AUTHOR", "vdirienzo")


def jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def js(path, default=None):
    if not os.path.exists(path):
        return default
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default


pr_path, runs_path, comments_path, compare_path, commit_path = sys.argv[1:6]
pr = js(pr_path, {}) or {}
runs = jsonl(runs_path)
comments = jsonl(comments_path)
compare = js(compare_path, {}) or {}
commit = js(commit_path, {}) or {}

sha = pr.get("headRefOid") or ""
title = (pr.get("title") or "").replace("\r", " ").replace("\n", " ").strip()
labels = [l.get("name") if isinstance(l, dict) else str(l)
          for l in (pr.get("labels") or [])]
has_label = "approved-for-ci" in labels

# The state of the CI: the SAME rule as pipeline.py (group by name, the most
# recent by completed_at wins). An old 'cancelled' is NOT a red.
estado, _detalle = pipeline.evaluar_check_runs(runs)
ci = {"verde": "verde", "rojo": "rojo", "pendiente": "pendiente"}.get(estado, "pendiente")

groups = {}
for r in runs:
    if isinstance(r, dict):
        groups.setdefault(r.get("name") or "?", []).append(r)


def corrio_en_verde(rs):
    """True: el job de este grupo CORRIO y paso. False: no corrio."""
    vigente = pipeline._vigente(rs)
    if vigente is None:
        return False
    conclusion = pipeline._conclusion(vigente)
    if conclusion in ("success", "neutral"):
        return True
    if conclusion in ("cancelled", "stale"):
        # Un run superseded: si hay un gemelo en verde creado despues, ese
        # gemelo es el que cuenta.
        gemelo = max((r for r in rs
                      if pipeline._id(r) > pipeline._id(vigente)
                      and pipeline._conclusion(r) in ("success", "neutral")),
                     key=pipeline._id, default=None)
        return gemelo is not None
    return False


def heavy_ran(run_list):
    g = {}
    for r in run_list:
        if isinstance(r, dict):
            g.setdefault(r.get("name") or "?", []).append(r)
    for name, rs in g.items():
        if name not in HEAVY:
            continue
        if corrio_en_verde(rs):
            return True
    return False


# El modo "solo el heavy": el bash lo llama por cada commit de la cadena de
# merges de main y le pregunta solo si el heavy corrio en verde ahi.
if os.environ.get("HEAVY_ONLY"):
    print("HEAVY=%s" % ("ran-on-head" if heavy_ran(jsonl(sys.argv[1])) else "not-ran"))
    sys.exit(0)

heavy_head = heavy_ran(runs)
if heavy_head:
    heavy = "ran-on-head"
elif not has_label:
    heavy = "waiting"
else:
    heavy = "unknown"

behind = compare.get("behind_by")
ahead = compare.get("ahead_by")

marker = "<!-- ping-ready: sha=%s -->" % sha
already = "no"
supersede = []
for c in comments:
    if not isinstance(c, dict):
        continue
    login = ((c.get("user") or {}).get("login")) or ""
    if login and login != AUTHOR:
        continue
    body = c.get("body") or ""
    if marker in body:
        already = "si"
        continue
    tag = "<!-- ping-ready: sha="
    if tag in body:
        i = body.index(tag)
        rest = body[i + len(tag):]
        j = rest.find(" -->")
        if j > 0:
            viejo = rest[:j].strip()
            if viejo and viejo != sha:
                supersede.append("%s:%s" % (c.get("id"), viejo))


def p(k, v):
    v = str(v).replace("\r", " ").replace("\n", " ")
    print("%s=%s" % (k, v))


p("SHA", sha)
p("TITLE", title)
p("LABEL", "si" if has_label else "no")
p("DRAFT", "si" if pr.get("isDraft") else "no")
p("CI", ci)
p("BEHIND", behind if isinstance(behind, int) else "?")
p("AHEAD", ahead if isinstance(ahead, int) else "?")
p("HEAVY", heavy)
p("ALREADY", already)
p("SUPERSEDE", " ".join(supersede))
PY

# ---------------------------------------------------------------------------
# the calls to gh
# ---------------------------------------------------------------------------

# One page of an endpoint: it appends it as JSONL and says how many items it
# brought (to know whether to ask for another page).
fetch_page(){
  # $1 = json file of the page, $2 = key of the json, $3 = output jsonl
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, key, out = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    print(0)
    sys.exit(0)
if isinstance(d, list):
    items = d
elif isinstance(d, dict):
    items = d.get(key, []) if key else []
else:
    items = []
with open(out, "a", encoding="utf-8") as fh:
    for it in items:
        fh.write(json.dumps(it) + "\n")
print(len(items))
PY
}

# Every check-run of the sha (paginated), one per line.
fetch_check_runs(){
  # $1 = sha, $2 = output jsonl
  local sha="$1" out="$2" page=1 n
  : > "$out"
  while : ; do
    if ! "$GH_BIN" api "repos/$REPO/commits/$sha/check-runs?per_page=100&page=$page" \
         > "$TMP/page.json" 2> "$TMP/page.err"; then
      say "los check-runs de $sha no se pudieron leer: $(head -1 "$TMP/page.err")"
      return 1
    fi
    n="$(fetch_page "$TMP/page.json" "check_runs" "$out")"
    [ "${n:-0}" -lt 100 ] && break
    page=$((page + 1))
    [ "$page" -gt 20 ] && break
  done
  return 0
}

# The comments of the pull request (paginated), one per line.
fetch_comments(){
  # $1 = pr, $2 = output jsonl
  local pr="$1" out="$2" page=1 n
  : > "$out"
  while : ; do
    if ! "$GH_BIN" api "repos/$REPO/issues/$pr/comments?per_page=100&page=$page" \
         > "$TMP/page.json" 2> "$TMP/page.err"; then
      say "los comentarios de #$pr no se pudieron leer: $(head -1 "$TMP/page.err")"
      return 1
    fi
    n="$(fetch_page "$TMP/page.json" "" "$out")"
    [ "${n:-0}" -lt 100 ] && break
    page=$((page + 1))
    [ "$page" -gt 20 ] && break
  done
  return 0
}

# ---------------------------------------------------------------------------
# el conflicto con main: git merge-tree
#
# 'commits atras' es INFORMACION, no un bloqueo (upstream mergea rapido: 81
# commits nuevos en cinco horas el 2026-11-07). Lo que decide si el
# mantenedor puede mergear es si la rama CONFLICTA con el main actual, y
# eso lo dice exactamente, sin tocar la red de GitHub:
#
#   git merge-tree --write-tree --name-only <head-sha> origin/main
#
#   rc=0  la rama mergea limpio
#   rc=1  la rama CONFLICTA
#   rc>1  no se pudo medir (git viejo, sha que no esta, error)
#
# merge-tree escribe un objeto en el repo y NO toca ninguna rama ni el
# working tree: es seguro.
#
# Si el conflicto NO se puede medir, el estado es 'desconocido' y el PR NO
# se pinguea (fallo seguro): no se pide revisar algo que no se pudo
# comprobar. El resumen lo dice.
# ---------------------------------------------------------------------------
MAIN_STATE="pendiente"

# El main de referencia tiene que estar al dia: se trae una vez por corrida.
prepare_main(){
  case "$MAIN_STATE" in
    listo) return 0 ;;
    sin-repo|sin-fetch) return 1 ;;
  esac
  if ! "$GIT_BIN" -C "$LOCAL_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    say "no hay repo local en $LOCAL_REPO: el conflicto con main no se puede medir"
    MAIN_STATE="sin-repo"
    return 1
  fi
  if ! "$GIT_BIN" -C "$LOCAL_REPO" fetch --no-tags --quiet origin main >/dev/null 2>&1; then
    say "el fetch de origin/main fallo: el conflicto con main no se puede medir"
    MAIN_STATE="sin-fetch"
    return 1
  fi
  MAIN_STATE="listo"
  return 0
}

# $1 = pr, $2 = head sha. Imprime: si | no | desconocido
conflict_state(){
  local pr="$1" sha="$2" rc
  if ! prepare_main; then
    printf 'desconocido\n'
    return 0
  fi
  # el head tiene que estar en el repo local: si no esta, se trae la
  # referencia del pull request (GitHub la publica)
  if ! "$GIT_BIN" -C "$LOCAL_REPO" cat-file -e "$sha^{commit}" >/dev/null 2>&1; then
    "$GIT_BIN" -C "$LOCAL_REPO" fetch --no-tags --quiet origin "refs/pull/$pr/head" \
      >/dev/null 2>&1 || :
  fi
  if ! "$GIT_BIN" -C "$LOCAL_REPO" cat-file -e "$sha^{commit}" >/dev/null 2>&1; then
    say "PR #$pr: el head $sha no esta en el repo local: el conflicto es desconocido"
    printf 'desconocido\n'
    return 0
  fi
  "$GIT_BIN" -C "$LOCAL_REPO" merge-tree --write-tree --name-only "$sha" origin/main \
    > "$TMP/merge-tree.out" 2> "$TMP/merge-tree.err"
  rc=$?
  case "$rc" in
    0)
      printf 'no\n' ;;
    1)
      say "PR #$pr: la rama CONFLICTA con origin/main: $(head -3 "$TMP/merge-tree.out" | tr '\n' ' ')"
      printf 'si\n' ;;
    *)
      say "PR #$pr: merge-tree fallo (rc=$rc): $(head -1 "$TMP/merge-tree.err")"
      printf 'desconocido\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# la cadena de merges de main
#
# Un head que es un merge de main puede arrastrar el resultado del heavy CI
# de un commit anterior (upstream lo hace con scripts/ci/main_merge.py). Para
# no mentir ("the heavy CI has not run") hay que mirar la cadena: se siguen
# los PRIMEROS padres mientras sean merges de main, y se busca el commit
# donde el heavy SI corrio en verde.
#
# CHAIN_HEAVY    = ran-on-chain | unknown
# CHAIN_CARRIER  = el sha donde el heavy corrio (vacio si no se encontró)
# ---------------------------------------------------------------------------
CHAIN_HEAVY=""
CHAIN_CARRIER=""

walk_merge_chain(){
  local cur="$1" d="$2" depth=0
  CHAIN_HEAVY="unknown"
  CHAIN_CARRIER=""
  while [ "$depth" -lt 5 ] && [ -n "$cur" ]; do
    depth=$((depth + 1))
    "$GH_BIN" api "repos/$REPO/commits/$cur" > "$d/chain.json" 2>/dev/null || return 0
    local msg parent
    msg="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
print(((d.get("commit") or {}).get("message") or "").split("\n")[0])' "$d/chain.json")"
    parent="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
p=d.get("parents") or []
print((p[0].get("sha") if p else "") or "")' "$d/chain.json")"
    # solo un merge de main sigue la cadena
    case "$msg" in
      *"Merge branch 'main'"*|*"Merge remote-tracking branch 'upstream/main'"*) ;;
      *) return 0 ;;
    esac
    [ -n "$parent" ] || return 0
    cur="$parent"
    # el heavy de ese commit?
    fetch_check_runs "$cur" "$d/chain-runs.jsonl" 2>/dev/null || return 0
    if HEAVY_ONLY=1 python3 "$TMP/analyze.py" "$d/chain-runs.jsonl" "" "" "" "" 2>/dev/null \
         | grep -q '^HEAVY=ran-on-head'; then
      CHAIN_HEAVY="ran-on-chain"
      CHAIN_CARRIER="$cur"
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# the body of the comment
# ---------------------------------------------------------------------------
build_body(){
  # $1 title, $2 sha, $3 heavy, $4 carrier sha, $5 label
  local titulo="$1" sha="$2" heavy="$3" carrier="$4" label="$5"
  {
    printf '%s\n\n' "$titulo"
    printf -- '- Head: `%s`\n' "$sha"
    printf -- '- CI on this head: green. Every check that ran passed.\n'
    case "$heavy" in
      ran-on-head)
        printf -- '- The heavy CI (native tests, native clippy) ran on this head and it is green.\n' ;;
      ran-on-chain)
        printf -- '- The heavy CI (native tests, native clippy) is green on this change: it ran on `%s`, and this head only merges the current `main` into it.\n' "${carrier:0:12}" ;;
      waiting)
        printf -- '- The heavy CI (native tests, native clippy) has not run on this head. It runs only after a maintainer adds the `approved-for-ci` label.\n' ;;
      *)
        printf -- '- The heavy CI (native tests, native clippy) has not run on this head.\n' ;;
    esac
    printf -- '- This branch merges cleanly with the current `main`.\n\n'
    if [ "$label" = "no" ]; then
      printf 'Please add the `approved-for-ci` label to this pull request. That is the only thing missing on our side.\n\n'
    else
      printf 'Nothing else is missing on our side. This pull request is ready for review.\n\n'
    fi
    printf '<!-- ping-ready: sha=%s -->\n' "$sha"
  } > "$TMP/body.md"
}

# ---------------------------------------------------------------------------
# the summary
#
#   <pr> <sha-corto> <n-atras> <si|no|desconocido> <verde|rojo|pendiente>
#   <si|no> LISTO|FALTA <que falta>
#
# 'n-atras' (cuantos commits esta la rama atras de main) es DATO, no un
# bloqueo: sale siempre, pero no decide el veredicto. 'si|no|desconocido' es
# el conflicto con main: 'si' hay conflicto, 'no' no hay, 'desconocido' no
# se pudo medir. El '<si|no>' de adelante es si el PR ya tiene el label
# approved-for-ci.
# ---------------------------------------------------------------------------
resumen(){
  # $1 pr, $2 sha, $3 behind, $4 conflicto, $5 ci, $6 label, $7 LISTO|FALTA,
  # $8 que falta
  local pr="$1" sha="${2:-?}" behind="${3:-?}" conflicto="${4:-?}" ci="${5:-?}"
  local label="${6:-?}" veredicto="${7:-FALTA}" razon="${8:-}"
  local corto atras
  corto="$sha"
  [ "${#corto}" -gt 12 ] && corto="${corto:0:12}"
  case "$behind" in
    ''|*[!0-9]*) atras="? atras" ;;
    *)            atras="$behind atras" ;;
  esac
  if [ -n "$razon" ]; then
    printf '%s %s %s %s %s %s %s %s\n' "$pr" "$corto" "$atras" "$conflicto" "$ci" \
      "$label" "$veredicto" "$razon"
  else
    printf '%s %s %s %s %s %s %s\n' "$pr" "$corto" "$atras" "$conflicto" "$ci" \
      "$label" "$veredicto"
  fi
}

FAILED=0

# The list of pull requests: from the arguments, or from gh pr list.
if [ "${#PRS[@]}" -eq 0 ]; then
  if ! "$GH_BIN" pr list --author "$AUTHOR" --state open --repo "$REPO" --json number \
       > "$TMP/list.json" 2> "$TMP/list.err"; then
    die "gh pr list fallo: $(head -1 "$TMP/list.err")"
  fi
  while IFS= read -r n; do
    [ -n "$n" ] && PRS+=("$n")
  done < <(python3 - "$TMP/list.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    d = []
for pr in d:
    n = pr.get("number") if isinstance(pr, dict) else pr
    if n is not None:
        print(n)
PY
)
  say "PRs abiertos de $AUTHOR: ${#PRS[@]}"
fi

for pr in "${PRS[@]}"; do
  d="$TMP/pr-$pr"; mkdir -p "$d"

  # --- the pull request itself --------------------------------------------
  if ! "$GH_BIN" pr view "$pr" --repo "$REPO" \
       --json number,title,headRefOid,labels,isDraft,state > "$d/pr.json" 2> "$d/pr.err"; then
    say "PR #$pr: no se pudo leer: $(head -1 "$d/pr.err")"
    resumen "$pr" "?" "?" "?" "?" "?" "FALTA" "no se pudo leer el PR"
    FAILED=1
    continue
  fi

  # --- the REAL CI of the head, the comments, the comparison with main -----
  sha="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
print(d.get("headRefOid") or "")' "$d/pr.json")"
  if [ -z "$sha" ]; then
    say "PR #$pr: no tiene head sha"
    resumen "$pr" "?" "?" "?" "?" "?" "FALTA" "no se pudo leer el head sha"
    FAILED=1
    continue
  fi

  fetch_check_runs "$sha" "$d/runs.jsonl" || {
    resumen "$pr" "$sha" "?" "?" "?" "?" "FALTA" "no se pudieron leer los check-runs"
    FAILED=1
    continue
  }
  fetch_comments "$pr" "$d/comments.jsonl" || {
    resumen "$pr" "$sha" "?" "?" "?" "?" "FALTA" "no se pudieron leer los comentarios"
    FAILED=1
    continue
  }
  # El conflicto con main: lo decide git merge-tree, no el campo 'mergeable'
  # de la API (ese campo puede ser UNKNOWN mientras GitHub recalcula, y
  # UNKNOWN NO es un conflicto).
  CONFLICT="$(conflict_state "$pr" "$sha")"
  if ! "$GH_BIN" api "repos/$REPO/compare/main...$sha" > "$d/compare.json" 2> "$d/compare.err"; then
    # 'cuantos commits atras' es DATO: si no se pudo medir, el PR sigue
    # evaluado (el CI y el conflicto son los que bloquean).
    say "PR #$pr: la comparacion con main fallo: $(head -1 "$d/compare.err")"
    : > "$d/compare.json"
    FAILED=1
  fi
  "$GH_BIN" api "repos/$REPO/commits/$sha" > "$d/commit.json" 2>/dev/null || : > "$d/commit.json"

  analyze(){
    python3 "$TMP/analyze.py" "$d/pr.json" "$d/runs.jsonl" "$d/comments.jsonl" \
      "$d/compare.json" "$d/commit.json"
  }

  # --- the first analysis -------------------------------------------------
  declare -A A=()
  while IFS='=' read -r k v; do
    [ -n "${k:-}" ] && A["$k"]="$v"
  done < <(analyze)

  CI="${A[CI]:-pendiente}"
  LABEL="${A[LABEL]:-no}"
  BEHIND="${A[BEHIND]:-?}"
  HEAVY="${A[HEAVY]:-unknown}"
  TITLE="${A[TITLE]:-}"
  ALREADY="${A[ALREADY]:-no}"
  DRAFT="${A[DRAFT]:-no}"
  CARRIER=""

  # If the pull request already has the label but the heavy CI is not on this
  # head, the head may be a merge of main that carries the result of the
  # change: the chain of merges of main that the head brings is walked, the
  # same way upstream does it (scripts/ci/main_merge.py), and the commit
  # where the heavy CI did run is looked for.
  if [ "$LABEL" = "si" ] && [ "$HEAVY" = "unknown" ]; then
    walk_merge_chain "$sha" "$d"
    HEAVY="${CHAIN_HEAVY:-unknown}"
    CARRIER="${CHAIN_CARRIER:-}"
  fi

  # --- the verdict ---------------------------------------------------------
  # 'commits atras' NO bloquea: es informacion (upstream mergea rapido y una
  # rama siempre queda atras). Bloquea el CI que no esta verde y la rama que
  # CONFLICTA con main.
  FALTAN=()
  if [ "$CI" != "verde" ]; then
    case "$CI" in
      rojo)      FALTAN+=("el CI esta rojo") ;;
      pendiente) FALTAN+=("el CI esta pendiente") ;;
      *)         FALTAN+=("el CI esta $CI") ;;
    esac
  fi
  case "$CONFLICT" in
    si)          FALTAN+=("la rama conflictua con main") ;;
    desconocido) FALTAN+=("el conflicto con main no se pudo medir") ;;
  esac
  if [ "$DRAFT" = "si" ]; then
    FALTAN+=("el PR es un draft")
  fi

  if [ "${#FALTAN[@]}" -eq 0 ]; then
    VERDICTO="LISTO"
    if [ "$LABEL" = "si" ]; then
      RAZON="nada, listo para revisar"
    else
      RAZON="falta el label approved-for-ci"
    fi
  else
    VERDICTO="FALTA"
    RAZON="$(printf '%s; ' "${FALTAN[@]}")"
    RAZON="${RAZON%; }"
  fi

  # --- the comment ---------------------------------------------------------
  if [ "$CI" = "verde" ] && [ "$CONFLICT" = "no" ] && [ "$DRAFT" != "si" ]; then
    if [ "$ALREADY" = "si" ]; then
      say "PR #$pr: ya tiene el comentario de este head ($sha): no se comenta otra vez"
    else
      build_body "$TITLE" "$sha" "$HEAVY" "$CARRIER" "$LABEL"
      if [ "$MODE" = "post" ]; then
        if "$GH_BIN" pr comment "$pr" --repo "$REPO" --body-file "$TMP/body.md" \
             > "$TMP/comment.out" 2> "$TMP/comment.err"; then
          say "PR #$pr: comentario publicado (sha $sha)"
        else
          say "PR #$pr: el comentario no se pudo publicar: $(head -1 "$TMP/comment.err")"
          VERDICTO="FALTA"
          RAZON="el comentario no se pudo publicar"
          FAILED=1
        fi
      elif [ "$MODE" = "dry" ]; then
        say "PR #$pr: dry-run, no se comenta"
        printf -- '--- PR #%s (dry-run) ---\n' "$pr"
        cat "$TMP/body.md"
        printf -- '--- fin PR #%s ---\n\n' "$pr"
      else
        say "PR #$pr: report, no se comenta"
      fi
      # The comments with another sha are marked as superseded: they are
      # EDITED, never deleted, and the old marker is kept so that the
      # idempotency per sha stays exact.
      for par in ${A[SUPERSEDE]:-}; do
        cid="${par%%:*}"; viejo="${par##*:}"
        [ -n "$cid" ] || continue
        [ "$MODE" = "post" ] || continue
        if "$GH_BIN" api -X PATCH "repos/$REPO/issues/comments/$cid" \
             -f "body=Superseded: this note was about the head ${viejo}. The current state is in the note above.

<!-- ping-ready: sha=${viejo} -->" \
             > /dev/null 2>&1; then
          say "PR #$pr: el comentario $cid (sha $viejo) se marco como superado"
        else
          say "PR #$pr: el comentario $cid (sha $viejo) no se pudo marcar"
          FAILED=1
        fi
      done
    fi
  else
    say "PR #$pr: no se pinguea todavia (${RAZON:-sin estado})"
  fi

  resumen "$pr" "$sha" "$BEHIND" "$CONFLICT" "$CI" "$LABEL" "$VERDICTO" "$RAZON"
done

if [ "$FAILED" -ne 0 ]; then
  say "hubo fallos: el codigo de salida es 1"
  exit 1
fi
exit 0
