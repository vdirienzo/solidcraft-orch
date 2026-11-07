#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-ping-ready.sh - ping-ready.sh leaves ONE comment per pull request and
# per head sha, it asks for the label and for nothing else, and it does not
# fall over when GitHub does not answer.
#
# WHY THESE TESTS EXIST (2026-11-07):
#   The upstream CI runs its HEAVY lane (native tests, native clippy, the test
#   build) only after a maintainer adds the `approved-for-ci` label. That is
#   the ONE thing we need from the maintainer, so the comment we leave has to
#   say exactly that, and it has to say the REAL state of the CI.
#
#   Two traps, both measured on real pull requests:
#     a) the rollup (statusCheckRollup) mixes the 'cancelled' of an old run
#        with the 'success' of the new run of the same check: a pull request
#        that is green looks red. The state has to be read from the check-runs
#        of the HEAD SHA, grouped by name, the most recent one winning.
#     b) the CI of a pull request that already carries the label can be green
#        on the change and carried into a merge of main: the heavy jobs of the
#        head are 'skipped' and the green one is the commit the head brings.
#        The comment must not claim that the heavy CI never ran.
#
#   These tests measure what matters:
#     a) a 'cancelled' old run plus a 'success' new one of the same name ->
#        the comment says the CI is green, NOT red;
#     b) a real 'failure' -> the summary says ROJO and the script does not
#        ask for the label (asking for it with a red CI makes no sense);
#     c) a pull request that already has 'approved-for-ci' -> the comment
#        does not ask for the label;
#     d) idempotency: run it twice -> ONE comment (the stub counts the calls
#        to 'gh pr comment');
#     e) a comment of ours with another sha -> a new comment for the current
#        sha (one per sha), and the old one is marked as superseded;
#     f) a pull request that gh cannot read -> the script goes on with the
#        others and exits with a code that is not 0.
#
#   And the rule that replaced '0 commits behind' (2026-11-08):
#     g) a branch 81 commits behind main that MERGES CLEANLY -> it IS
#        pinged and the summary says LISTO (behind is DATA, not a block:
#        upstream merges so fast that "0 behind" is a race that is always
#        lost);
#     h) a branch that CONFLICTS with main -> it is NOT pinged and the
#        summary says FALTA naming the conflict;
#     i) a CI that is still running -> it is NOT pinged and the summary
#        says PENDIENTE;
#     j) a conflict that can NOT be measured (no clone, fetch failed, git
#        too old) -> 'desconocido', NOT pinged: a safe failure.
#
# NOTHING IN THIS SCRIPT TOUCHES THE NETWORK: the gh is a stub AND the git
# is a stub (the conflict with main is measured with 'git merge-tree', and
# the stub decides what it answers).
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
PING_READY="$HERE/ping-ready.sh"
REPORT="$HERE/ping-ready-report.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-ping-ready.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

[ -f "$PING_READY" ] || { echo "no encuentro $PING_READY"; exit 1; }
command -v python3 >/dev/null || { echo "no hay python3"; exit 1; }

# ---------------------------------------------------------------------------
# el stub de gh
#
# Los datos vienen de $STUB_DIR:
#   prs.json              {"<num>": {numero, titulo, sha, labels[], draft}}
#   checkruns/<sha>.json  la lista de check-runs de ese sha
#   comments/<num>.json   los comentarios de ese PR
#   compare/<sha>.json    {"behind_by": N, "ahead_by": N}
#   commits/<sha>.json    {"parents":[{"sha":...}], "commit":{"message":...}}
#
# El stub deja en calls.log cada llamada, y en comment-calls.log las llamadas
# a 'gh pr comment' (una por linea): asi el test cuenta los comentarios.
# Un 'gh pr comment' AGREGA el comentario al archivo del PR, como lo hace
# GitHub: el segundo run del script lo tiene que ver.
# ---------------------------------------------------------------------------
cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env python3
import json, os, sys

D = os.environ.get("STUB_DIR", ".")
args = sys.argv[1:]
with open(os.path.join(D, "calls.log"), "a") as fh:
    fh.write(" ".join(args) + "\n")


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default


def val(flag):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def err(msg):
    sys.stderr.write("gh: %s\n" % msg)
    sys.exit(1)


def prs():
    return load(os.path.join(D, "prs.json"), {}) or {}


def save_comments(num, lst):
    d = os.path.join(D, "comments")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "%s.json" % num), "w", encoding="utf-8") as fh:
        json.dump(lst, fh, indent=1)


# --- gh pr list ------------------------------------------------------------
if args[:2] == ["pr", "list"]:
    out = []
    for num, pr in sorted(prs().items(), key=lambda kv: int(kv[0])):
        if pr.get("state", "OPEN") != "OPEN":
            continue
        if pr.get("author", "vdirienzo") != val("--author"):
            continue
        out.append({"number": pr.get("number", int(num))})
    print(json.dumps(out))
    sys.exit(0)

# --- gh pr view ------------------------------------------------------------
if args[:2] == ["pr", "view"]:
    num = args[2]
    pr = prs().get(num)
    if pr is None:
        err("could not resolve to a PullRequest: %s" % num)
    if pr.get("unreadable"):
        err("could not resolve to a PullRequest: %s" % num)
    out = {
        "number": pr.get("number", int(num)),
        "title": pr.get("title", ""),
        "headRefOid": pr.get("sha", ""),
        "labels": [{"name": n} for n in pr.get("labels", [])],
        "isDraft": bool(pr.get("draft", False)),
        "state": pr.get("state", "OPEN"),
    }
    print(json.dumps(out))
    sys.exit(0)

# --- gh pr comment ---------------------------------------------------------
if args[:2] == ["pr", "comment"]:
    num = args[2]
    body = ""
    if "--body-file" in args:
        try:
            with open(args[args.index("--body-file") + 1], encoding="utf-8") as fh:
                body = fh.read()
        except OSError:
            body = ""
    elif "--body" in args:
        body = args[args.index("--body") + 1]
    with open(os.path.join(D, "comment-calls.log"), "a") as fh:
        fh.write("%s\t%s\n" % (num, body.replace("\n", "\\n")))
    lst = load(os.path.join(D, "comments", "%s.json" % num), []) or []
    cid = 900000 + len(lst) + 1
    lst.append({"id": cid, "user": {"login": "vdirienzo"}, "body": body})
    save_comments(num, lst)
    print("https://github.com/tangency-labs/solidcraft/pull/%s#issuecomment-%s" % (num, cid))
    sys.exit(0)

# --- gh api ----------------------------------------------------------------
if args[:1] == ["api"]:
    # el endpoint es el primer argumento que NO es el valor de una bandera
    # (-X PATCH, -f body=...). "PATCH" NO es el endpoint.
    path = ""
    skip = set()
    for i, a in enumerate(args[1:]):
        if a in ("-X", "--method", "-f", "--field", "-F", "--raw-field"):
            skip.add(i + 1)
    for i, a in enumerate(args[1:]):
        if i in skip or a.startswith("-"):
            continue
        path = a
        break
    base = path.split("?")[0]
    qs = path.split("?")[1] if "?" in path else ""

    if base.startswith("repos/") and base.endswith("/check-runs"):
        sha = base.split("/commits/")[1].split("/")[0]
        runs = load(os.path.join(D, "checkruns", "%s.json" % sha))
        if runs is None:
            err("no check-runs for %s" % sha)
        print(json.dumps({"total_count": len(runs), "check_runs": runs}))
        sys.exit(0)

    if "/issues/" in base and base.endswith("/comments"):
        num = base.split("/issues/")[1].split("/")[0]
        lst = load(os.path.join(D, "comments", "%s.json" % num), []) or []
        print(json.dumps(lst))
        sys.exit(0)

    if base.startswith("repos/") and "/compare/" in base:
        head = base.split("/compare/")[1].split("...")[-1]
        c = load(os.path.join(D, "compare", "%s.json" % head))
        if c is None:
            err("compare failed for %s" % head)
        print(json.dumps(c))
        sys.exit(0)

    if base.startswith("repos/") and "/commits/" in base and not base.endswith("/check-runs"):
        sha = base.split("/commits/")[1].split("/")[0]
        c = load(os.path.join(D, "commits", "%s.json" % sha))
        if c is None:
            err("no commit %s" % sha)
        print(json.dumps(c))
        sys.exit(0)

    if "/issues/comments/" in base:
        cid = base.split("/issues/comments/")[1]
        body = val("-f") or ""
        if body.startswith("body="):
            body = body[len("body="):]
        with open(os.path.join(D, "patch-calls.log"), "a") as fh:
            fh.write("%s\t%s\n" % (cid, body.replace("\n", "\\n")))
        # el comentario editado: se busca en todos los PR del stub
        for num in prs():
            lst = load(os.path.join(D, "comments", "%s.json" % num), []) or []
            for c in lst:
                if str(c.get("id")) == str(cid):
                    c["body"] = body
                    save_comments(num, lst)
                    print(json.dumps(c))
                    sys.exit(0)
        err("comment %s not found" % cid)
    err("unknown api path: %s" % path)

err("unknown command: %s" % " ".join(args))
STUB
chmod +x "$TMP/gh"

# -----------------------------------------------------------------------
# el stub de git
#
# El conflicto con main lo decide 'git merge-tree'. El stub lo simula con
# archivos dentro de $STUB_DIR/git/:
#
#   no-repo            el repo local no sirve (rev-parse falla)
#   no-fetch           el fetch de origin/main falla
#   missing/<sha>      el head no esta en el repo local
#   conflict/<sha>     merge-tree sale con 1: la rama CONFLICTA con main
#   error/<sha>        merge-tree sale con 128: no se pudo medir
#
# Por defecto merge-tree sale con 0: la rama mergea limpio con main.
# El stub deja en git-calls.log cada llamada, para que el test vea que se
# midio el conflicto con merge-tree y no con el campo 'mergeable' de la API.
# -----------------------------------------------------------------------
cat > "$TMP/git" <<'STUB'
#!/usr/bin/env bash
D="${STUB_DIR:-.}"
args=("$@")
if [ "${args[0]:-}" = "-C" ]; then
  dir="${args[1]:-}"; args=("${args[@]:2}")
else
  dir="."
fi
cmd="${args[0]:-}"
printf '%s %s\n' "$cmd" "${args[*]:-}" >> "$D/git-calls.log"
case "$cmd" in
  rev-parse)
    if [ -f "$D/git/no-repo" ] || [ ! -d "$dir" ]; then
      echo "fatal: not a git repository" >&2
      exit 128
    fi
    printf '%s/.git\n' "$dir"; exit 0 ;;
  fetch)
    if [ -f "$D/git/no-fetch" ]; then
      echo "fatal: could not fetch from origin" >&2
      exit 128
    fi
    exit 0 ;;
  cat-file)
    sha="${args[2]:-}"; sha="${sha%^*}"
    if [ -f "$D/git/missing/$sha" ]; then exit 1; fi
    exit 0 ;;
  merge-tree)
    sha=""
    for a in "${args[@]:1}"; do
      case "$a" in
        [0-9a-f]*) sha="$a"; break ;;
      esac
    done
    if [ -f "$D/git/conflict/$sha" ]; then
      printf 'cafebabe00000000000000000000000000000000\nsrc/file.rs\n'
      exit 1
    fi
    if [ -f "$D/git/error/$sha" ]; then
      echo "fatal: not a valid object name" >&2
      exit 128
    fi
    printf 'cafebabe00000000000000000000000000000000\n'
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/git"

# El conflicto con main se mide con el stub: el test NO toca la red ni el
# repo real de SolidCraft.
export GIT_BIN="$TMP/git"
export LOCAL_REPO="$TMP/local-repo"
mkdir -p "$LOCAL_REPO"

# ---------------------------------------------------------------------------
# los datos de cada caso
# ---------------------------------------------------------------------------
mkstub(){ # $1 = nombre del caso
  d="$TMP/$1"
  mkdir -p "$d/checkruns" "$d/comments" "$d/compare" "$d/commits"
  printf '%s' "$d"
}

SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"
SHA_OLD="9999999999999999999999999999999999999999"
SHA_PARENT="8888888888888888888888888888888888888888"
# el resumen imprime el sha corto
SHORT_A="${SHA_A:0:12}"
SHORT_B="${SHA_B:0:12}"

run_check(){ # $1 nombre, $2 conclusion, $3 completed_at, $4 id, $5 status
  python3 - "$1" "$2" "$3" "$4" "${5:-completed}" <<'PY'
import json, sys
name, conclusion, completed, rid, status = sys.argv[1:6]
print(json.dumps({"name": name, "status": status, "conclusion": conclusion,
                  "completed_at": completed, "started_at": completed, "id": int(rid)}))
PY
}

run_running(){ # $1 nombre, $2 started_at, $3 id: un check que CORRE ahora
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
name, started, rid = sys.argv[1:4]
print(json.dumps({"name": name, "status": "in_progress", "conclusion": None,
                  "started_at": started, "completed_at": None, "id": int(rid)}))
PY
}

# (a) un 'cancelled' viejo y un 'success' nuevo del MISMO nombre: VERDE.
CHECKS_A="[$(run_check 'ci' success 2026-11-07T15:34:38Z 900),"
CHECKS_A="$CHECKS_A$(run_check 'Defaults line check' cancelled 2026-11-06T15:46:35Z 800),"
CHECKS_A="$CHECKS_A$(run_check 'Defaults line check' success 2026-11-06T15:46:43Z 810),"
CHECKS_A="$CHECKS_A$(run_check 'Native Linux tests' skipped 2026-11-07T15:28:15Z 820),"
CHECKS_A="$CHECKS_A$(run_check 'Quick compile' success 2026-11-07T15:30:46Z 830)]"

# (b) un 'failure' real: ROJO.
CHECKS_B="[$(run_check 'ci' failure 2026-11-07T10:17:35Z 900),"
CHECKS_B="$CHECKS_B$(run_check 'Defaults line check' failure 2026-11-07T10:10:56Z 800),"
CHECKS_B="$CHECKS_B$(run_check 'Quick compile' success 2026-11-07T10:13:27Z 810)]"

# (c) verde con el heavy corrido en el head.
CHECKS_C="[$(run_check 'ci' success 2026-11-07T15:34:38Z 900),"
CHECKS_C="$CHECKS_C$(run_check 'Native Linux tests' success 2026-11-07T15:30:00Z 800),"
CHECKS_C="$CHECKS_C$(run_check 'Native Linux Clippy' success 2026-11-07T15:31:00Z 810)]"

# (c2) verde con el heavy corrido en el PADRE (el head es un merge de main):
#      el head trae el heavy por la cadena de merges, como upstream.
CHECKS_C2="[$(run_check 'ci' success 2026-11-07T15:34:38Z 900),"
CHECKS_C2="$CHECKS_C2$(run_check 'Native Linux tests' skipped 2026-11-07T15:28:15Z 800),"
CHECKS_C2="$CHECKS_C2$(run_check 'Native Linux Clippy' skipped 2026-11-07T15:28:15Z 810)]"
CHECKS_PARENT="[$(run_check 'ci' success 2026-11-07T15:20:00Z 700),"
CHECKS_PARENT="$CHECKS_PARENT$(run_check 'Native Linux tests' success 2026-11-07T15:19:00Z 600),"
CHECKS_PARENT="$CHECKS_PARENT$(run_check 'Native Linux Clippy' success 2026-11-07T15:19:30Z 610)]"

# (i) el CI CORRE: uno verde viejo y uno in_progress mas nuevo -> PENDIENTE.
CHECKS_PENDIENTE="[$(run_check 'ci' success 2026-11-07T15:34:38Z 900),"
CHECKS_PENDIENTE="$CHECKS_PENDIENTE$(run_check 'Quick compile' success 2026-11-07T15:30:46Z 830),"
CHECKS_PENDIENTE="$CHECKS_PENDIENTE$(run_running 'ci' 2026-11-07T16:02:11Z 950)]"

# el escenario base: un PR verde sin label.
setup_base(){ # $1 = stub dir, $2 = sha
  cat > "$1/prs.json" <<JSON
{
 "12891": {"number": 12891, "title": "Crash: a clean exit is reported as an unclean exit (#12842)",
           "sha": "$2", "labels": ["area:ui"], "draft": false, "state": "OPEN"},
 "12574": {"number": 12574, "title": "Preset numbers for functions (#12418)",
           "sha": "$2", "labels": ["area:ui"], "draft": false, "state": "OPEN"}
}
JSON
  printf '%s' "$CHECKS_A" > "$1/checkruns/$2.json"
  printf '%s' '{"behind_by": 0, "ahead_by": 3}' > "$1/compare/$2.json"
  printf '%s' '{"parents": [], "commit": {"message": "Fix: whatever"}}' > "$1/commits/$2.json"
  printf '%s' '[]' > "$1/comments/12891.json"
  printf '%s' '[]' > "$1/comments/12574.json"
}

# ---------------------------------------------------------------------------
# (a) un 'cancelled' viejo + un 'success' nuevo del mismo nombre
# ---------------------------------------------------------------------------
D="$(mkstub a)"
setup_base "$D" "$SHA_A"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
rc=$?
body="$(grep '^12891	' "$D/comment-calls.log" | cut -f2)"

[ "$rc" -eq 0 ] && ok "(a) el script sale con 0" || no "(a) el script sale con 0" "rc=$rc"
if printf '%s' "$body" | grep -q 'CI on this head: green'; then
  ok "(a) el comentario dice que el CI de ese head esta VERDE"
else
  no "(a) el comentario dice que el CI de ese head esta VERDE" "$body"
fi
if printf '%s' "$body" | grep -qi 'CI on this head: red\|CI is red\|rojo'; then
  no "(a) el comentario NO dice que el CI esta rojo" "$body"
else
  ok "(a) el comentario NO dice que el CI esta rojo"
fi
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras no verde no LISTO"; then
  ok "(a) el resumen dice verde y LISTO"
else
  no "(a) el resumen dice verde y LISTO" "$out"
fi

# ---------------------------------------------------------------------------
# (b) un 'failure' real: ROJO, y no se pide el label
# ---------------------------------------------------------------------------
D="$(mkstub b)"
setup_base "$D" "$SHA_A"
printf '%s' "$CHECKS_B" > "$D/checkruns/$SHA_A.json"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
rc=$?
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras no rojo no FALTA"; then
  ok "(b) el resumen dice ROJO y FALTA"
else
  no "(b) el resumen dice ROJO y FALTA" "$out"
fi
if [ -s "$D/comment-calls.log" ]; then
  no "(b) con el CI en rojo no se pide el label (no hay comentario)" "$(cat "$D/comment-calls.log")"
else
  ok "(b) con el CI en rojo no se pide el label (no hay comentario)"
fi
[ "$rc" -eq 0 ] && ok "(b) el script sale con 0" || no "(b) el script sale con 0" "rc=$rc"

# ---------------------------------------------------------------------------
# (c) un PR que YA tiene approved-for-ci: el comentario NO pide el label
# ---------------------------------------------------------------------------
D="$(mkstub c)"
setup_base "$D" "$SHA_A"
python3 - "$D/prs.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["12891"]["labels"] = ["area:ui", "approved-for-ci"]
json.dump(d, open(p, "w"), indent=1)
PY
printf '%s' "$CHECKS_C" > "$D/checkruns/$SHA_A.json"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
rc=$?
body="$(grep '^12891	' "$D/comment-calls.log" | cut -f2)"
if [ -z "$body" ]; then
  no "(c) hay un comentario" "no se publico ninguno"
elif printf '%s' "$body" | grep -qi 'add the .approved-for-ci. label\|please add'; then
  no "(c) el comentario NO pide el label" "$body"
else
  ok "(c) el comentario NO pide el label"
fi
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras no verde si LISTO"; then
  ok "(c) el resumen dice que el label esta puesto"
else
  no "(c) el resumen dice que el label esta puesto" "$out"
fi
[ "$rc" -eq 0 ] && ok "(c) el script sale con 0" || no "(c) el script sale con 0" "rc=$rc"

# (c2) el heavy corrido en el padre: el comentario NO dice que el heavy
#      nunca corrio.
D="$(mkstub c2)"
setup_base "$D" "$SHA_A"
python3 - "$D/prs.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["12891"]["labels"] = ["approved-for-ci"]
json.dump(d, open(p, "w"), indent=1)
PY
printf '%s' "$CHECKS_C2" > "$D/checkruns/$SHA_A.json"
printf '%s' "$CHECKS_PARENT" > "$D/checkruns/$SHA_PARENT.json"
printf '%s' "{\"parents\": [{\"sha\": \"$SHA_PARENT\"}], \"commit\": {\"message\": \"Merge branch 'main' into fix/issue-1\"}}" > "$D/commits/$SHA_A.json"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
body="$(grep '^12891	' "$D/comment-calls.log" | cut -f2)"
if printf '%s' "$body" | grep -q 'is green on this change'; then
  ok "(c2) el comentario dice que el heavy esta verde en el cambio"
else
  no "(c2) el comentario dice que el heavy esta verde en el cambio" "$body"
fi
if printf '%s' "$body" | grep -q 'has not run on this head'; then
  no "(c2) el comentario NO dice que el heavy nunca corrio" "$body"
else
  ok "(c2) el comentario NO dice que el heavy nunca corrio"
fi

# ---------------------------------------------------------------------------
# (d) idempotencia: dos runs -> UN comentario
# ---------------------------------------------------------------------------
D="$(mkstub d)"
setup_base "$D" "$SHA_A"
GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 >/dev/null 2>&1
GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 >/dev/null 2>&1
GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 >/dev/null 2>&1
n="$(grep -c . "$D/comment-calls.log" 2>/dev/null || echo 0)"
[ "$n" = "1" ] && ok "(d) tres runs dejan UN comentario" || no "(d) tres runs dejan UN comentario" "comentarios=$n"

# el marcador del sha esta en el cuerpo
body="$(grep '^12891	' "$D/comment-calls.log" | cut -f2)"
if printf '%s' "$body" | grep -q "ping-ready: sha=$SHA_A"; then
  ok "(d) el comentario lleva el marcador de su sha"
else
  no "(d) el comentario lleva el marcador de su sha" "$body"
fi

# dos runs sobre DOS PRs: un comentario por PR
D="$(mkstub d2)"
setup_base "$D" "$SHA_A"
GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" >/dev/null 2>&1
n1="$(grep -c . "$D/comment-calls.log" 2>/dev/null || echo 0)"
GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" >/dev/null 2>&1
n2="$(grep -c . "$D/comment-calls.log" 2>/dev/null || echo 0)"
if [ "$n1" = "2" ] && [ "$n2" = "2" ]; then
  ok "(d) sin argumentos comenta los PRs abiertos, una vez cada uno"
else
  no "(d) sin argumentos comenta los PRs abiertos, una vez cada uno" "primero=$n1 segundo=$n2"
fi

# ---------------------------------------------------------------------------
# (e) un comentario nuestro de otro sha -> comentario nuevo (1 por sha)
# ---------------------------------------------------------------------------
D="$(mkstub e)"
setup_base "$D" "$SHA_A"
python3 - "$D/comments/12891.json" "$SHA_OLD" <<'PY'
import json, sys
path, old = sys.argv[1], sys.argv[2]
body = ("Ready for review: algo\n\n- Head: `%s`\n\n<!-- ping-ready: sha=%s -->\n" % (old, old))
json.dump([{"id": 111, "user": {"login": "vdirienzo"}, "body": body}], open(path, "w"), indent=1)
PY
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
rc=$?
n="$(grep -c . "$D/comment-calls.log" 2>/dev/null || echo 0)"
[ "$n" = "1" ] && ok "(e) hay un comentario NUEVO para el sha de ahora" || no "(e) hay un comentario NUEVO para el sha de ahora" "comentarios=$n"
body="$(grep '^12891	' "$D/comment-calls.log" | cut -f2)"
if printf '%s' "$body" | grep -q "ping-ready: sha=$SHA_A"; then
  ok "(e) el comentario nuevo lleva el sha de ahora"
else
  no "(e) el comentario nuevo lleva el sha de ahora" "$body"
fi
if grep -q 'Superseded' "$D/patch-calls.log" 2>/dev/null; then
  ok "(e) el comentario viejo se marca como superado"
else
  no "(e) el comentario viejo se marca como superado" "$(cat "$D/patch-calls.log" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# (f) un PR que gh no puede leer: sigue con los demas y sale con != 0
# ---------------------------------------------------------------------------
D="$(mkstub f)"
setup_base "$D" "$SHA_A"
python3 - "$D/prs.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["12891"]["unreadable"] = True
json.dump(d, open(p, "w"), indent=1)
PY
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 12574 2>"$D/err")"
rc=$?
[ "$rc" -ne 0 ] && ok "(f) con un PR ilegible el codigo de salida NO es 0" || no "(f) con un PR ilegible el codigo de salida NO es 0" "rc=$rc"
if printf '%s' "$out" | grep -q '^12891 .* FALTA '; then
  ok "(f) el PR ilegible sale como FALTA en el resumen"
else
  no "(f) el PR ilegible sale como FALTA en el resumen" "$out"
fi
if printf '%s' "$out" | grep -q "^12574 $SHORT_A 0 atras no verde no LISTO"; then
  ok "(f) el script sigue con los demas PRs"
else
  no "(f) el script sigue con los demas PRs" "$out"
fi
if grep -q '^12574	' "$D/comment-calls.log" 2>/dev/null; then
  ok "(f) el PR que se puede leer recibe su comentario"
else
  no "(f) el PR que se puede leer recibe su comentario" "$(cat "$D/comment-calls.log" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# el contenido del comentario: lo que el mantenedor lee
# ---------------------------------------------------------------------------
D="$(mkstub w)"
setup_base "$D" "$SHA_A"
GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 >/dev/null 2>&1
body="$(grep '^12891	' "$D/comment-calls.log" | cut -f2 | sed 's/\\n/\n/g')"

if printf '%s' "$body" | grep -q "approved-for-ci"; then
  ok "(w) el comentario pide el label approved-for-ci"
else
  no "(w) el comentario pide el label approved-for-ci" "$body"
fi
if printf '%s' "$body" | grep -qi 'please merge\|can you merge\|merge it\|merge this pr'; then
  no "(w) el comentario NO pide merge" "$body"
else
  ok "(w) el comentario NO pide merge"
fi
if printf '%s' "$body" | grep -q 'maintainer'; then
  ok "(w) el comentario dice que lo agrega un maintainer"
else
  no "(w) el comentario dice que lo agrega un maintainer" "$body"
fi
if printf '%s' "$body" | grep -q 'current `main`'; then
  ok "(w) el comentario dice que la rama lleva el main actual"
else
  no "(w) el comentario dice que la rama lleva el main actual" "$body"
fi
if printf '%s' "$body" | grep -q "$SHA_A"; then
  ok "(w) el comentario lleva el head sha"
else
  no "(w) el comentario lleva el head sha" "$body"
fi
lines="$(printf '%s' "$body" | grep -c .)"
if [ "$lines" -le 12 ]; then
  ok "(w) el comentario tiene 12 lineas o menos ($lines)"
else
  no "(w) el comentario tiene 12 lineas o menos" "lineas=$lines"
fi
if printf '%s' "$body" | grep -qP '[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]'; then
  no "(w) el comentario NO tiene emojis" "$body"
else
  ok "(w) el comentario NO tiene emojis"
fi
if printf '%s' "$body" | grep -qi '\bsorry\b'; then
  no "(w) el comentario NO dice sorry" "$body"
else
  ok "(w) el comentario NO dice sorry"
fi
if printf '%s' "$body" | grep -q 'The CI of this pull request'; then
  no "(w) el comentario NO usa la firma del otro script (pr-comment.sh)" "$body"
else
  ok "(w) el comentario NO usa la firma del otro script (pr-comment.sh)"
fi

# ---------------------------------------------------------------------------
# --dry-run y --report: no comentan
# ---------------------------------------------------------------------------
D="$(mkstub dry)"
setup_base "$D" "$SHA_A"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" --dry-run 12891 2>"$D/err")"
if [ ! -s "$D/comment-calls.log" ]; then
  ok "(--dry-run) no comenta nada"
else
  no "(--dry-run) no comenta nada" "$(cat "$D/comment-calls.log")"
fi
if printf '%s' "$out" | grep -q 'ping-ready: sha='; then
  ok "(--dry-run) imprime lo que haria"
else
  no "(--dry-run) imprime lo que haria" "$out"
fi
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras no verde no LISTO"; then
  ok "(--dry-run) imprime tambien el resumen"
else
  no "(--dry-run) imprime tambien el resumen" "$out"
fi

D="$(mkstub rep)"
setup_base "$D" "$SHA_A"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" --report 12891 2>"$D/err")"
if [ ! -s "$D/comment-calls.log" ]; then
  ok "(--report) no comenta nada"
else
  no "(--report) no comenta nada" "$(cat "$D/comment-calls.log")"
fi
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras no verde no LISTO"; then
  ok "(--report) imprime el resumen"
else
  no "(--report) imprime el resumen" "$out"
fi

# el script hermano del reporte
if [ -f "$REPORT" ]; then
  D="$(mkstub rep2)"
  setup_base "$D" "$SHA_A"
  out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$REPORT" 12891 2>"$D/err")"
  if [ ! -s "$D/comment-calls.log" ] && printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras no verde no LISTO"; then
    ok "(ping-ready-report.sh) imprime el resumen y no comenta"
  else
    no "(ping-ready-report.sh) imprime el resumen y no comenta" "$out"
  fi
else
  no "(ping-ready-report.sh) existe"
fi

# ---------------------------------------------------------------------------
# (g) una rama 81 commits atras pero SIN conflicto: SE PINGUEA
#
# 'commits atras' es DATO, no un bloqueo. Upstream mergea tan rapido (81
# commits nuevos en cinco horas el 2026-11-07) que exigir '0 atras' es una
# carrera que se pierde siempre: el 2026-11-07 el script bloqueo los seis
# PRs abiertos con 'la rama esta 81 commits atras de main' aunque su CI
# estaba verde y mergeaban limpio con main.
# ---------------------------------------------------------------------------
D="$(mkstub behind)"
setup_base "$D" "$SHA_A"
printf '%s' '{"behind_by": 81, "ahead_by": 3}' > "$D/compare/$SHA_A.json"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
rc=$?
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 81 atras no verde no LISTO"; then
  ok "(g) una rama 81 atras y sin conflicto sale LISTO"
else
  no "(g) una rama 81 atras y sin conflicto sale LISTO" "$out"
fi
if grep -q '^12891	' "$D/comment-calls.log" 2>/dev/null; then
  ok "(g) una rama 81 atras y sin conflicto SE PINGUEA"
else
  no "(g) una rama 81 atras y sin conflicto SE PINGUEA" "$(cat "$D/comment-calls.log" 2>/dev/null)"
fi
if printf '%s' "$out" | grep -q 'falta el label approved-for-ci'; then
  ok "(g) el resumen dice que falta el label"
else
  no "(g) el resumen dice que falta el label" "$out"
fi
if printf '%s' "$out" | grep -qi 'atras de main'; then
  no "(g) el resumen NO reporta la atraso como FALTA" "$out"
else
  ok "(g) el resumen NO reporta la atraso como FALTA"
fi
[ "$rc" -eq 0 ] && ok "(g) el script sale con 0" || no "(g) el script sale con 0" "rc=$rc"

# ---------------------------------------------------------------------------
# (h) una rama que CONFLICTA con main: NO se pinguea
# ---------------------------------------------------------------------------
D="$(mkstub conflict)"
setup_base "$D" "$SHA_A"
mkdir -p "$D/git/conflict"
: > "$D/git/conflict/$SHA_A"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras si verde no FALTA"; then
  ok "(h) una rama que CONFLICTA con main sale FALTA"
else
  no "(h) una rama que CONFLICTA con main sale FALTA" "$out"
fi
if printf '%s' "$out" | grep -q 'la rama conflictua con main'; then
  ok "(h) el resumen NOMBRA el conflicto"
else
  no "(h) el resumen NOMBRA el conflicto" "$out"
fi
if [ -s "$D/comment-calls.log" ]; then
  no "(h) una rama que conflictua NO se pinguea" "$(cat "$D/comment-calls.log")"
else
  ok "(h) una rama que conflictua NO se pinguea"
fi
if grep -q 'merge-tree' "$D/git-calls.log" 2>/dev/null; then
  ok "(h) el conflicto se midio con git merge-tree"
else
  no "(h) el conflicto se midio con git merge-tree" "$(cat "$D/git-calls.log" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# (i) el CI esta CORRIENDO: NO se pinguea, dice pendiente
# ---------------------------------------------------------------------------
D="$(mkstub pending)"
setup_base "$D" "$SHA_A"
printf '%s' "$CHECKS_PENDIENTE" > "$D/checkruns/$SHA_A.json"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras no pendiente no FALTA"; then
  ok "(i) el CI en curso sale PENDIENTE y FALTA"
else
  no "(i) el CI en curso sale PENDIENTE y FALTA" "$out"
fi
if printf '%s' "$out" | grep -q 'el CI esta pendiente'; then
  ok "(i) el resumen dice que el CI esta pendiente"
else
  no "(i) el resumen dice que el CI esta pendiente" "$out"
fi
if [ -s "$D/comment-calls.log" ]; then
  no "(i) con el CI en curso NO se pinguea" "$(cat "$D/comment-calls.log")"
else
  ok "(i) con el CI en curso NO se pinguea"
fi

# ---------------------------------------------------------------------------
# (j) el conflicto NO se pudo medir: 'desconocido' y NO se pinguea
#
# Es el fallo seguro: si no se puede comprobar que la rama mergea, no se
# pide revisar. El resumen lo dice.
# ---------------------------------------------------------------------------
D="$(mkstub unknown)"
setup_base "$D" "$SHA_A"
mkdir -p "$D/git/error"
: > "$D/git/error/$SHA_A"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras desconocido verde no FALTA"; then
  ok "(j) un conflicto que no se pudo medir sale desconocido y FALTA"
else
  no "(j) un conflicto que no se pudo medir sale desconocido y FALTA" "$out"
fi
if printf '%s' "$out" | grep -q 'el conflicto con main no se pudo medir'; then
  ok "(j) el resumen dice que el conflicto no se pudo medir"
else
  no "(j) el resumen dice que el conflicto no se pudo medir" "$out"
fi
if [ -s "$D/comment-calls.log" ]; then
  no "(j) con el conflicto desconocido NO se pinguea" "$(cat "$D/comment-calls.log")"
else
  ok "(j) con el conflicto desconocido NO se pinguea"
fi

# (j2) sin repo local: el conflicto tampoco se puede medir
D="$(mkstub norepo)"
setup_base "$D" "$SHA_A"
out="$(LOCAL_REPO="$TMP/no-existe-local" GH_BIN="$TMP/gh" STUB_DIR="$D" \
       bash "$PING_READY" 12891 2>"$D/err")"
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras desconocido verde no FALTA"; then
  ok "(j2) sin repo local el conflicto sale desconocido"
else
  no "(j2) sin repo local el conflicto sale desconocido" "$out"
fi
if [ -s "$D/comment-calls.log" ]; then
  no "(j2) sin repo local NO se pinguea" "$(cat "$D/comment-calls.log")"
else
  ok "(j2) sin repo local NO se pinguea"
fi

# (j3) el fetch de origin falla: tambien es desconocido
D="$(mkstub nofetch)"
setup_base "$D" "$SHA_A"
mkdir -p "$D/git"
: > "$D/git/no-fetch"
out="$(GH_BIN="$TMP/gh" STUB_DIR="$D" bash "$PING_READY" 12891 2>"$D/err")"
if printf '%s' "$out" | grep -q "^12891 $SHORT_A 0 atras desconocido verde no FALTA"; then
  ok "(j3) con el fetch caido el conflicto sale desconocido"
else
  no "(j3) con el fetch caido el conflicto sale desconocido" "$out"
fi
if [ -s "$D/comment-calls.log" ]; then
  no "(j3) con el fetch caido NO se pinguea" "$(cat "$D/comment-calls.log")"
else
  ok "(j3) con el fetch caido NO se pinguea"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
