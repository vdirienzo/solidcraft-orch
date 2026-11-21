#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ping-ready.sh - leaves ONE review-package comment on each of our pull
# requests that is ready to review, and prints which ones are ready to ping.
#
#   bash bin/ping-ready.sh [--dry-run] [--report] [--max-pedidos N] [<pr> ...]
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
#        <si|no> LISTO|FALTA|EN-TURNO|ESPERA <que falta>
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
# THE BATCH: the tanda of 'approved-for-ci' requests (2026-11-08):
#   The maintainer merges our pull requests IN GROUPS BY AREA. Asking for
#   the label on four pull requests at once, spread over three areas, only
#   scatters the work. So the requests for the label go in a BATCH:
#
#     MAX_PEDIDOS     how many requests can be in flight at once (default 2)
#     VALVULA_HORAS   how long a request may wait before the batch gets one
#                     more slot (default 72 hours)
#
#   A REQUEST IN FLIGHT ('pedido en curso') is a pull request that has OUR
#   ping comment for its CURRENT head sha and does NOT have the label yet.
#   It is resolved when the maintainer adds the label, or when the pull
#   request is merged or closed (a closed pull request is not in flight and
#   does not hold a slot).
#
#   WHO ENTERS THE BATCH, when there is room:
#     a) the candidates are the READY pull requests (green CI, no conflict
#        with main, not a draft) that do NOT have a request in flight;
#     b) they are grouped by AREA. A pull request with several area labels
#        counts in every one of them; the group it is picked from is its
#        PRINCIPAL area, the first 'area:*' label in alphabetical order (a
#        rule, not the order the bot happened to push the labels in);
#     c) the area with the MOST ready pull requests goes first, so the
#        maintainer can merge a group in one go;
#     d) inside that area the OLDEST pull request goes first (the one
#        created before);
#     e) if that area does not fill the batch, the batch is completed with
#        the next areas, by the same rule (most ready first, then oldest).
#
#   THE VALVE: if the OLDEST request in flight has been waiting for MORE
#   THAN 72 HOURS without being resolved (its sha still has no label), one
#   EXTRA request is allowed (MAX_PEDIDOS + 1). A batch the maintainer
#   ignores must not block the queue forever. When the valve opens, the
#   summary says so.
#
#   THE SUMMARY, one line per pull request, now carries the decision of the
#   batch:
#     LISTO     it enters the batch now (the comment is posted)
#     EN-TURNO  it already has a request in flight (no new comment)
#     ESPERA    it is ready but the batch is full (nothing is posted yet)
#     FALTA     something is missing on our side (red CI, conflict, ...)
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
# ORCH_DIR: el orquestador es el padre de bin/ (el ORCH_DIR del ambiente lo
# puede pisar). 2026-11-21: el crontab corre el script DEL REPO; la copia de
# los crons viejos (fuera de bin/, sin pipeline.py al lado) ya no existe, y
# con ella se fue el fallback a la ruta de esta maquina.
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
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
# The batch: how many 'approved-for-ci' requests can be in flight at once,
# and how long the oldest one may wait before the batch gets one more slot.
MAX_PEDIDOS="${MAX_PEDIDOS:-2}"
VALVULA_HORAS="${VALVULA_HORAS:-72}"

say(){ printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }
die(){ printf '%s\n' "$*" >&2; exit 2; }

usage(){
  cat <<'USAGE' >&2
uso: ping-ready.sh [--dry-run] [--report] [--max-pedidos N] [<pr> ...]
  --dry-run  prints what it would do, without commenting anything
  --report   prints only the summary, without commenting anything
  --max-pedidos N  how many 'approved-for-ci' requests can be in flight (2)
  (with no <pr>: it lists them with gh pr list --author vdirienzo --state open)
  se pinguea si el CI del head esta verde y la rama MERGEA LIMPIO con main
  (el conflicto se mide con git merge-tree; 'commits atras' es dato, no bloqueo)
  tanda: nunca hay mas de MAX_PEDIDOS pedidos 'approved-for-ci' en curso;
  entra el area con mas PRs listos y dentro de ella el mas antiguo; a los
  VALVULA_HORAS (72) del pedido mas viejo sin resolver se permite uno mas
  resumen: <pr> <sha> <n-atras> <si|no|desconocido> <verde|rojo|pendiente> <si|no> LISTO|FALTA|EN-TURNO|ESPERA <que falta>
USAGE
}

MODE=post
PRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --report)  MODE=report ;;
    --max-pedidos)
      shift
      [ $# -gt 0 ] || die "--max-pedidos necesita un numero"
      MAX_PEDIDOS="$1" ;;
    --max-pedidos=*) MAX_PEDIDOS="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do PRS+=("$1"); shift; done; break ;;
    -*) die "opcion desconocida: $1" ;;
    *) PRS+=("$1") ;;
  esac
  shift
done

case "$MAX_PEDIDOS" in
  ''|*[!0-9]*) die "--max-pedidos tiene que ser un numero: $MAX_PEDIDOS" ;;
esac

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
#
#   analyze.py light <pr.json> <runs.jsonl> <comments.jsonl> <compare.json> <commit.json>
#   analyze.py full  <pr.json> <runs.jsonl> <comments.jsonl> <compare.json> <commit.json>
#
# 'light' is what the batch needs about EVERY open pull request (is there a
# request in flight? does it have the label? when was it asked?), and it does
# not read the CI at all. 'full' is what a pull request that is being
# evaluated needs (the CI, the heavy lane, the conflict data).
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
    if not path or not os.path.exists(path):
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
    if not path or not os.path.exists(path):
        return default
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default


mode = sys.argv[1] if len(sys.argv) > 1 else "full"
pr_path, runs_path, comments_path, compare_path, commit_path = sys.argv[2:7]
pr = js(pr_path, {}) or {}
runs = jsonl(runs_path)
comments = jsonl(comments_path)
compare = js(compare_path, {}) or {}
commit = js(commit_path, {}) or {}

sha = pr.get("headRefOid") or ""
title = (pr.get("title") or "").replace("\r", " ").replace("\n", " ").replace("\t", " ").strip()
labels = [l.get("name") if isinstance(l, dict) else str(l)
          for l in (pr.get("labels") or [])]
has_label = "approved-for-ci" in labels

# The AREAS of the pull request. The principal area is the FIRST 'area:*'
# label in alphabetical order: a RULE, not the order the triage bot happened
# to push the labels in, so the batch is the same in every run.
areas = sorted(l for l in labels if l.startswith("area:"))
principal = areas[0] if areas else ""

# The state of the pull request: a merged or closed one is NOT in flight and
# does NOT hold a slot of the batch.
state = pr.get("state") or "OPEN"

# The CI: the SAME rule as pipeline.py (group by name, the most recent by
# completed_at wins). An old 'cancelled' is NOT a red.
if mode == "light":
    ci = "na"
else:
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
    print("HEAVY=%s" % ("ran-on-head" if heavy_ran(runs) else "not-ran"))
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
ping_at = ""
for c in comments:
    if not isinstance(c, dict):
        continue
    login = ((c.get("user") or {}).get("login")) or ""
    if login and login != AUTHOR:
        continue
    body = c.get("body") or ""
    if marker in body:
        already = "si"
        # Cuando se pidio el label: la valvula de 72h lo necesita.
        ca = c.get("created_at") or ""
        if ca and (not ping_at or ca < ping_at):
            ping_at = ca
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
    v = str(v).replace("\r", " ").replace("\n", " ").replace("\t", " ")
    print("%s=%s" % (k, v))


p("SHA", sha)
p("TITLE", title)
p("LABEL", "si" if has_label else "no")
p("DRAFT", "si" if pr.get("isDraft") else "no")
p("STATE", state)
p("CI", ci)
p("BEHIND", behind if isinstance(behind, int) else "?")
p("AHEAD", ahead if isinstance(ahead, int) else "?")
p("HEAVY", heavy)
p("ALREADY", already)
p("PING_AT", ping_at)
p("CREATED", pr.get("createdAt") or "")
p("AREAS", ",".join(areas))
p("PRIMARY", principal)
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
    if HEAVY_ONLY=1 python3 "$TMP/analyze.py" light "" "$d/chain-runs.jsonl" "" "" "" 2>/dev/null \
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
#   <si|no> LISTO|FALTA|EN-TURNO|ESPERA <que falta>
#
# 'n-atras' (cuantos commits esta la rama atras de main) es DATO, no un
# bloqueo: sale siempre, pero no decide el veredicto. 'si|no|desconocido' es
# el conflicto con main: 'si' hay conflicto, 'no' no hay, 'desconocido' no
# se pudo medir. El '<si|no>' de adelante es si el PR ya tiene el label
# approved-for-ci. El veredicto lleva la decision de la tanda: LISTO (entra
# en la tanda ahora), EN-TURNO (ya tiene un pedido en curso), ESPERA (esta
# listo pero la tanda esta llena) o FALTA (le falta algo de nuestro lado).
# ---------------------------------------------------------------------------
resumen(){
  # $1 pr, $2 sha, $3 behind, $4 conflicto, $5 ci, $6 label, $7 veredicto,
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

# ---------------------------------------------------------------------------
# the batch: the tanda of 'approved-for-ci' requests
#
# It decides, for every pull request, whether it ENTERS the batch now, has a
# request IN FLIGHT, has to WAIT, or is missing something on our side.
#
# The facts it reads (one line per pull request, TAB separated):
#   pr, sha, label, state, ping, ping_at, created, primary, areas, ready,
#   reason
#
# It writes one line per pull request:
#   pr, veredicto (LISTO|FALTA|EN-TURNO|ESPERA), razon, accion (post|skip)
# ---------------------------------------------------------------------------
cat > "$TMP/plan.py" <<'PY'
import os, sys, time
from datetime import datetime, timezone

recs_path, out_path = sys.argv[1], sys.argv[2]
max_pedidos = int(os.environ.get("MAX_PEDIDOS", "2"))
valvula_horas = float(os.environ.get("VALVULA_HORAS", "72"))
now = float(os.environ.get("PING_NOW") or 0) or time.time()


def epoch(s):
    if not s:
        return None
    s = str(s).strip()
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


# Las columnas: pr, sha, label, state, ping, ping_at, created, primary,
# areas, ready, reason, target.
recs = []
with open(recs_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        f = line.split("\t")
        f += [""] * (12 - len(f))
        recs.append({
            "pr": f[0], "sha": f[1], "label": f[2], "state": f[3], "ping": f[4],
            "ping_at": f[5], "created": f[6], "primary": f[7], "areas": f[8],
            "ready": f[9], "reason": f[10], "target": f[11],
        })

# Un pedido EN CURSO: tiene nuestro comentario de ping para su head sha
# ACTUAL y NO tiene el label. Un PR mergeado o cerrado no esta en curso (no
# se lista, no se pide nada) y NO ocupa lugar: cuando se resuelve (el
# mantenedor pone el label, o el PR se mergea o se cierra), entra el
# siguiente.
en_curso = [r for r in recs
            if r["state"] == "OPEN" and r["ping"] == "si" and r["label"] == "no"]
n_curso = len(en_curso)

# La valvula: el pedido en curso mas viejo que sigue sin label.
esperas = []
for r in en_curso:
    e = epoch(r["ping_at"])
    if e is not None:
        esperas.append((now - e, r["pr"]))
mas_viejo, pr_mas_viejo = max(esperas) if esperas else (None, None)
valvula = mas_viejo is not None and mas_viejo > valvula_horas * 3600

# El tope: nunca hay mas de MAX_PEDIDOS pedidos en curso. La valvula abre
# UN lugar mas (MAX_PEDIDOS + 1) para que una tanda que el mantenedor
# ignora no bloquee la cola para siempre.
tope = max_pedidos + (1 if valvula else 0)
lugares = max(0, tope - n_curso)


def ckey(r):
    """El mas ANTIGUO primero: el PR creado antes."""
    e = epoch(r["created"])
    try:
        n = int(r["pr"])
    except Exception:
        n = 0
    return (e if e is not None else 0, n)


# Los candidatos: LISTOS (CI verde, sin conflicto, no draft), SIN pedido en
# curso y de los PRs que esta corrida puede comentar.
cands = [r for r in recs
         if r["target"] == "1" and r["state"] == "OPEN" and r["ready"] == "si"
         and r["label"] == "no" and r["ping"] != "si"]

# Los areas: un PR con varias areas cuenta en cada una (para medir el
# tamano del grupo), pero el GRUPO del que se elige es su area PRINCIPAL: la
# primera 'area:*' en orden alfabetico. Una regla, no el orden en que el bot
# de triage pusho las etiquetas.
sizes = {}
for c in cands:
    for a in (c["areas"].split(",") if c["areas"] else [""]):
        sizes[a] = sizes.get(a, 0) + 1
grupos = {}
for c in cands:
    grupos.setdefault(c["primary"], []).append(c)


def area_key(a):
    members = [c for c in cands if a in (c["areas"].split(",") if c["areas"] else [""])]
    k = min((ckey(c) for c in members), default=(0, 0))
    return (-sizes.get(a, 0), k[0], k[1], a)


# El area con MAS PRs listos entra primero (el mantenedor puede mergear un
# grupo en una sola pasada); dentro del area, el mas antiguo. Si el area
# elegida no llena la tanda, la tanda se completa con las areas siguientes,
# por el mismo criterio.
orden = sorted(sizes.keys(), key=area_key)
elegidos = []
for a in orden:
    for c in sorted(grupos.get(a, []), key=ckey):
        if len(elegidos) >= lugares:
            break
        elegidos.append(c)
    if len(elegidos) >= lugares:
        break

elegidos_pr = set(c["pr"] for c in elegidos)
nota_valvula = ""
if valvula:
    nota_valvula = ("valvula de %gh abierta: el pedido en curso mas viejo (#%s) lleva %.0fh "
                     "sin resolverse" % (int(valvula_horas), pr_mas_viejo, mas_viejo / 3600.0))

salida = []
for r in recs:
    if r["target"] != "1":
        continue
    pr = r["pr"]
    if r["ready"] == "na":
        veredicto, razon, accion = "FALTA", (r["reason"] or "no se pudo evaluar"), "skip"
    elif r["state"] != "OPEN":
        veredicto, razon, accion = "FALTA", "el PR no esta abierto (mergeado o cerrado)", "skip"
    elif r["ready"] != "si":
        veredicto, razon, accion = "FALTA", (r["reason"] or "le falta algo de nuestro lado"), "skip"
        # Un pedido en curso sigue occupying su lugar aunque el PR se haya
        # puesto rojo: el resumen lo dice para que no se accounted como libre.
        if r["ping"] == "si" and r["label"] == "no":
            razon = razon + "; el pedido del label sigue en curso"
    elif r["label"] == "si":
        veredicto = "LISTO"
        razon = r["reason"] or "nada, listo para revisar"
        accion = "skip" if r["ping"] == "si" else "post"
    elif r["ping"] == "si":
        veredicto = "EN-TURNO"
        razon = "el pedido del label esta en curso (falta el label approved-for-ci)"
        accion = "skip"
        if valvula and pr == pr_mas_viejo:
            razon = razon + "; " + nota_valvula
    elif pr in elegidos_pr:
        veredicto = "LISTO"
        razon = r["reason"] or "falta el label approved-for-ci"
        accion = "post"
        if valvula:
            razon = razon + "; " + nota_valvula
    else:
        veredicto = "ESPERA"
        razon = "espera su turno: hay %d pedido(s) en curso (tope %d)" % (n_curso, max_pedidos)
        accion = "skip"
        if valvula:
            razon = razon + "; " + nota_valvula
    salida.append("%s\x1f%s\x1f%s\x1f%s" % (pr, veredicto, str(razon).replace("\t", " "), accion))

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(salida) + ("\n" if salida else ""))

if valvula:
    sys.stderr.write("valvula de %gh abierta: se permite un pedido extra\n" % int(valvula_horas))
PY

FAILED=0

# ---------------------------------------------------------------------------
# the pull requests of this run
#
# The TARGETS are the pull requests this run reports on (the ones of the
# command line, or all of our open ones). The SCOPE is every open pull
# request of ours: the batch counts the requests in flight of ALL of them, so
# a request of another pull request holds its slot even when this run only
# looks at one.
# ---------------------------------------------------------------------------
ALL_OPEN=()
if ! "$GH_BIN" pr list --author "$AUTHOR" --state open --repo "$REPO" --json number \
     > "$TMP/list.json" 2> "$TMP/list.err"; then
  if [ "${#PRS[@]}" -eq 0 ]; then
    die "gh pr list fallo: $(head -1 "$TMP/list.err")"
  fi
  say "gh pr list fallo: $(head -1 "$TMP/list.err")"
  ALL_OPEN=("${PRS[@]}")
else
  while IFS= read -r n; do
    [ -n "$n" ] && ALL_OPEN+=("$n")
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
fi

if [ "${#PRS[@]}" -eq 0 ]; then
  PRS=("${ALL_OPEN[@]}")
  say "PRs abiertos de $AUTHOR: ${#PRS[@]}"
fi

# El alcance: los objetivos de esta corrida (los PRs de la linea de
# comandos, o todos los abiertos si no hay ninguno) MAS todos los PRs
# abiertos de los nuestros. Los abiertos se necesitan para CONTAR los
# pedidos en curso: el pedido de un PR que esta corriendo ocupa su lugar
# aunque esta corrida no lo evalue.
# Se deduplican: un PR repetido en la linea de comandos se procesa UNA vez
# (si no, su comentario se postearia dos veces en la misma corrida).
dedup(){
  local -a out=() v
  for v in "$@"; do
    [ -n "$v" ] || continue
    case " ${out[*]} " in
      *" $v "*) continue ;;
    esac
    out+=("$v")
  done
  printf '%s\n' "${out[@]}"
}
PRS=($(dedup "${PRS[@]+"${PRS[@]}"}"))
SCOPE=($(dedup "${PRS[@]+"${PRS[@]}"}" ${ALL_OPEN[@]+"${ALL_OPEN[@]}"}))

# ---------------------------------------------------------------------------
# primera pasada (ligera): de TODOS los PRs del alcance
#
# De cada uno se necesita solo lo que decide la tanda: el head sha, si tiene
# el label, si tiene un pedido en curso (nuestro comentario para su sha
# actual) y desde cuando se pidio.
# ---------------------------------------------------------------------------
declare -A R_SHA=() R_LABEL=() R_STATE=() R_PING=() R_PINGAT=() R_CREATED=()
declare -A R_PRIMARY=() R_AREAS=() R_READY=() R_REASON=() R_CI=() R_CONFLICT=()
declare -A R_BEHIND=() R_TITLE=() R_HEAVY=() R_CARRIER=() R_SUPERSEDE=()
declare -A R_LEIDO=()

for pr in "${SCOPE[@]}"; do
  d="$TMP/pr-$pr"; mkdir -p "$d"
  R_LEIDO[$pr]="no"

  # --- the pull request itself --------------------------------------------
  if ! "$GH_BIN" pr view "$pr" --repo "$REPO" \
       --json number,title,headRefOid,labels,isDraft,state,createdAt \
       > "$d/pr.json" 2> "$d/pr.err"; then
    say "PR #$pr: no se pudo leer: $(head -1 "$d/pr.err")"
    R_LABEL[$pr]="?"; R_STATE[$pr]="?"; R_PING[$pr]="no"
    R_READY[$pr]="na"; R_REASON[$pr]="no se pudo leer el PR"
    R_SHA[$pr]="?"; R_CREATED[$pr]=""; R_PRIMARY[$pr]=""; R_AREAS[$pr]=""
    R_CI[$pr]="?"; R_CONFLICT[$pr]="?"; R_BEHIND[$pr]="?"
    FAILED=1
    continue
  fi

  fetch_comments "$pr" "$d/comments.jsonl" || {
    FAILED=1
    R_LABEL[$pr]="?"; R_STATE[$pr]="?"; R_PING[$pr]="no"
    R_READY[$pr]="na"; R_REASON[$pr]="no se pudieron leer los comentarios"
    R_SHA[$pr]="?"; R_CREATED[$pr]=""; R_PRIMARY[$pr]=""; R_AREAS[$pr]=""
    R_CI[$pr]="?"; R_CONFLICT[$pr]="?"; R_BEHIND[$pr]="?"
    continue
  }

  declare -A A=()
  while IFS='=' read -r k v; do
    [ -n "${k:-}" ] && A["$k"]="$v"
  done < <(python3 "$TMP/analyze.py" light "$d/pr.json" "" "$d/comments.jsonl" "" "")

  R_SHA[$pr]="${A[SHA]:-}"
  R_LABEL[$pr]="${A[LABEL]:-no}"
  R_STATE[$pr]="${A[STATE]:-OPEN}"
  R_PING[$pr]="${A[ALREADY]:-no}"
  R_PINGAT[$pr]="${A[PING_AT]:-}"
  R_CREATED[$pr]="${A[CREATED]:-}"
  R_PRIMARY[$pr]="${A[PRIMARY]:-}"
  R_AREAS[$pr]="${A[AREAS]:-}"
  R_READY[$pr]="na"
  R_LEIDO[$pr]="si"

  if [ "${R_LABEL[$pr]}" = "no" ] && [ "${R_PING[$pr]}" = "si" ]; then
    say "PR #$pr: hay un pedido en curso (falta el label $CI_LABEL)"
  fi
done

# ---------------------------------------------------------------------------
# segunda pasada (completa): solo los PRs que esta corrida evalua
# ---------------------------------------------------------------------------
for pr in "${PRS[@]}"; do
  d="$TMP/pr-$pr"; mkdir -p "$d"
  if [ "${R_LEIDO[$pr]:-no}" != "si" ]; then
    # no se pudo leer en la primera pasada: el resumen lo imprime la tanda
    continue
  fi

  sha="${R_SHA[$pr]}"
  if [ -z "$sha" ]; then
    say "PR #$pr: no tiene head sha"
    R_REASON[$pr]="no se pudo leer el head sha"
    FAILED=1
    continue
  fi

  fetch_check_runs "$sha" "$d/runs.jsonl" || {
    R_REASON[$pr]="no se pudieron leer los check-runs"
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

  declare -A A=()
  while IFS='=' read -r k v; do
    [ -n "${k:-}" ] && A["$k"]="$v"
  done < <(python3 "$TMP/analyze.py" full "$d/pr.json" "$d/runs.jsonl" \
      "$d/comments.jsonl" "$d/compare.json" "$d/commit.json")

  CI="${A[CI]:-pendiente}"
  BEHIND="${A[BEHIND]:-?}"
  HEAVY="${A[HEAVY]:-unknown}"
  TITLE="${A[TITLE]:-}"
  DRAFT="${A[DRAFT]:-no}"
  CARRIER=""
  R_CI[$pr]="$CI"
  R_CONFLICT[$pr]="$CONFLICT"
  R_BEHIND[$pr]="$BEHIND"
  R_TITLE[$pr]="$TITLE"
  R_HEAVY[$pr]="$HEAVY"
  R_CARRIER[$pr]=""
  R_SUPERSEDE[$pr]="${A[SUPERSEDE]:-}"

  # If the pull request already has the label but the heavy CI is not on this
  # head, the head may be a merge of main that carries the result of the
  # change: the chain of merges of main that the head brings is walked, the
  # same way upstream does it (scripts/ci/main_merge.py), and the commit
  # where the heavy CI did run is looked for.
  if [ "${R_LABEL[$pr]}" = "si" ] && [ "$HEAVY" = "unknown" ]; then
    walk_merge_chain "$sha" "$d"
    HEAVY="${CHAIN_HEAVY:-unknown}"
    CARRIER="${CHAIN_CARRIER:-}"
    R_HEAVY[$pr]="$HEAVY"
    R_CARRIER[$pr]="$CARRIER"
  fi

  # --- el veredicto de fondo ----------------------------------------------
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
    R_READY[$pr]="si"
    if [ "${R_LABEL[$pr]}" = "si" ]; then
      R_REASON[$pr]="nada, listo para revisar"
    else
      R_REASON[$pr]="falta el label approved-for-ci"
    fi
  else
    R_READY[$pr]="no"
    R_REASON[$pr]="$(printf '%s; ' "${FALTAN[@]}")"
    R_REASON[$pr]="${R_REASON[$pr]%; }"
  fi
done

# ---------------------------------------------------------------------------
# la tanda: que PR entra, cual tiene un pedido en curso y cual espera
# ---------------------------------------------------------------------------
: > "$TMP/recs.tsv"
for pr in "${PRS[@]}"; do
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t1\n' \
    "$pr" "${R_SHA[$pr]:-}" "${R_LABEL[$pr]:-no}" "${R_STATE[$pr]:-OPEN}" \
    "${R_PING[$pr]:-no}" "${R_PINGAT[$pr]:-}" "${R_CREATED[$pr]:-}" \
    "${R_PRIMARY[$pr]:-}" "${R_AREAS[$pr]:-}" "${R_READY[$pr]:-na}" \
    "${R_REASON[$pr]:-}" >> "$TMP/recs.tsv"
done
# Los pedidos en curso se cuentan sobre TODOS los PRs del alcance, no solo
# sobre los de esta corrida: el pedido de otro PR tambien ocupa lugar.
for pr in "${SCOPE[@]}"; do
  case " ${PRS[*]} " in
    *" $pr "*) continue ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\n' \
    "$pr" "${R_SHA[$pr]:-}" "${R_LABEL[$pr]:-no}" "${R_STATE[$pr]:-OPEN}" \
    "${R_PING[$pr]:-no}" "${R_PINGAT[$pr]:-}" "${R_CREATED[$pr]:-}" \
    "${R_PRIMARY[$pr]:-}" "${R_AREAS[$pr]:-}" "na" "" >> "$TMP/recs.tsv"
done

MAX_PEDIDOS="$MAX_PEDIDOS" VALVULA_HORAS="$VALVULA_HORAS" \
  python3 "$TMP/plan.py" "$TMP/recs.tsv" "$TMP/plan.tsv" || die "no se pudo calcular la tanda"

# ---------------------------------------------------------------------------
# tercera pasada: los comentarios y el resumen
# ---------------------------------------------------------------------------
while IFS=$'\x1f' read -r pr VERDICTO RAZON ACCION; do
  [ -n "${pr:-}" ] || continue
  d="$TMP/pr-$pr"
  sha="${R_SHA[$pr]:-?}"
  CONFLICT="${R_CONFLICT[$pr]:-?}"
  CI="${R_CI[$pr]:-?}"
  LABEL="${R_LABEL[$pr]:-?}"

  if [ "$ACCION" = "post" ] && [ "$MODE" != "report" ]; then
    build_body "${R_TITLE[$pr]:-}" "$sha" "${R_HEAVY[$pr]:-unknown}" \
      "${R_CARRIER[$pr]:-}" "$LABEL"
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
    else
      say "PR #$pr: dry-run, no se comenta"
      printf -- '--- PR #%s (dry-run) ---\n' "$pr"
      cat "$TMP/body.md"
      printf -- '--- fin PR #%s ---\n\n' "$pr"
    fi
    # The comments with another sha are marked as superseded: they are
    # EDITED, never deleted, and the old marker is kept so that the
    # idempotency per sha stays exact.
    for par in ${R_SUPERSEDE[$pr]:-}; do
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
  elif [ "$ACCION" = "post" ]; then
    say "PR #$pr: report, no se comenta"
  else
    case "$VERDICTO" in
      EN-TURNO) say "PR #$pr: ya tiene un pedido en curso: no se comenta otra vez" ;;
      ESPERA)   say "PR #$pr: la tanda esta llena: espera su turno" ;;
      FALTA)    say "PR #$pr: no se pinguea todavia (${RAZON:-sin estado})" ;;
      *)        say "PR #$pr: no se pinguea (${RAZON:-sin estado})" ;;
    esac
  fi

  resumen "$pr" "$sha" "${R_BEHIND[$pr]:-?}" "$CONFLICT" "$CI" "$LABEL" "$VERDICTO" "$RAZON"
done < "$TMP/plan.tsv"

if [ "$FAILED" -ne 0 ]; then
  say "hubo fallos: el codigo de salida es 1"
  exit 1
fi
exit 0
