#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-publish-pr.sh - el camino UNICO de publicacion abre el pull request
# con la linea "Changes a default:" YA EN EL BODY, y no inventa un "no".
#
# POR QUE ESTOS TESTS EXISTEN (2026-11-07):
#   El bug de fondo NO era el check del upstream: era que HUBO DOS CAMINOS de
#   publicacion. Uno (bin/agent-issue.sh del loop) armaba el body y lo
#   validaba antes de abrir; el otro (los subagentes de la wave, con "gh pr
#   create" a mano) no pasaba por el freno, y el pull request se abria SIN la
#   linea. El check del upstream corre con types: [opened, ...], asi que se
#   disparaba contra ese body viejo y quedaba ROJO en pantalla (#12891,
#   #12574).
#
#   Estos tests miden lo que importa:
#     a) un body con la forma larga valida se publica y la linea NO se pisa;
#     b) un body SIN la linea que NO toca defaults se publica con
#        "Changes a default: no" agregado, y la linea esta en el body ANTES
#        de abrir (se mira el body que recibio el stub de gh);
#     c) un body SIN la linea que SI toca defaults NO se publica: el script
#        NO inventa un "no" (seria mentira) y lo dice;
#     d) un reclamo ocupado NO se publica;
#     e) un pull request abierto nuestro para ese issue: no se abre otro.
#
# NADA DE ESTE SCRIPT TOCA LA RED: el gh es un stub y el verificador del
# reclamo es el de la casa (claim-verify.sh) con el stub de gh delante.
# El validador de la linea de los defaults es el de la casa tambien
# (pr-defaults-line.sh, con el parser del upstream): la regla se mide con la
# regla, no con una copia de la regla.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
PUBLISH_PR="$HERE/publish-pr.sh"
CLAIM_VERIFY="$ORCH_DIR/bin/claim-verify.sh"
LOOP_REAL="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
DEFAULTS_LINE="$LOOP_REAL/bin/pr-defaults-line.sh"
# El checkout del upstream: de ahi sale el parser que el validador usa.
#
# The machine's own paths know where the checkout is (bin/paths.sh, 2026-11-24): the default
# below is only the fallback for a machine without that file. The literal was stale, so this
# suite could not measure the rule at all ("el parser del upstream no esta en ...").
if [ -z "${SOLIDCRAFT_REPO:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
fi
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-$HOME/solidcraft}"
PR_CHECKS_JS="${PR_CHECKS_JS:-$SOLIDCRAFT_REPO/scripts/pr-checks/pr-checks.js}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-publish-pr.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

[ -f "$PUBLISH_PR" ]   || { echo "no encuentro $PUBLISH_PR"; exit 1; }
[ -f "$CLAIM_VERIFY" ] || { echo "no encuentro $CLAIM_VERIFY"; exit 1; }
[ -f "$DEFAULTS_LINE" ] || { echo "no encuentro $DEFAULTS_LINE"; exit 1; }
command -v python3 >/dev/null || { echo "no hay python3"; exit 1; }

# El validador de la linea necesita node y el parser del upstream. Si no
# estan, el suite NO puede medir la regla: dice por que y sale (no verde
# por no haber medido nada).
if [ ! -f "$PR_CHECKS_JS" ]; then
  echo "el parser del upstream no esta en $PR_CHECKS_JS: no se puede medir la linea de los defaults"
  exit 1
fi
export PR_CHECKS_JS

# --- el LOOP de mentira: el validador real, con su LOOP_DIR aislado --------
LOOP_FAKE="$TMP/loop"
mkdir -p "$LOOP_FAKE/bin"
cp "$DEFAULTS_LINE" "$LOOP_FAKE/bin/pr-defaults-line.sh"
export LOOP_DIR="$LOOP_FAKE"

# --- el stub de gh ---------------------------------------------------------
# Simula: "pr create" (captura el body), "pr view", "pr list" y "api".
# Las respuestas vienen de $STUB_DIR (prs.json, issue.json).
cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env python3
import json, os, re, sys

D = os.environ.get("STUB_DIR", ".")
args = sys.argv[1:]
with open(os.path.join(D, "calls.log"), "a") as fh:
    fh.write(" ".join(args) + "\n")


def fixtures():
    p = os.path.join(D, "prs.json")
    if not os.path.exists(p):
        return []
    try:
        return json.load(open(p))
    except Exception:
        return []


def issue():
    p = os.path.join(D, "issue.json")
    if not os.path.exists(p):
        return {"state": "open", "labels": []}
    try:
        return json.load(open(p))
    except Exception:
        return {"state": "open", "labels": []}


def val(flag):
    return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else None


if args[:2] == ["pr", "create"]:
    # el body que se publica: se captura PARA PODER MIRARLO
    body = ""
    for i, a in enumerate(args):
        if a == "--body-file" and i + 1 < len(args):
            try:
                body = open(args[i + 1], encoding="utf-8").read()
            except OSError:
                body = ""
    with open(os.path.join(D, "created-body.md"), "w", encoding="utf-8") as fh:
        fh.write(body)
    with open(os.path.join(D, "created.json"), "w", encoding="utf-8") as fh:
        json.dump({"args": args, "body": body}, fh)
    print("https://github.com/tangency-labs/solidcraft/pull/999")
    sys.exit(0)

if args[:2] == ["pr", "view"]:
    n = val("--jq")
    body = ""
    for pr in fixtures():
        if str(pr.get("number")) == (args[2] if len(args) > 2 else ""):
            body = pr.get("body") or ""
    created = os.path.join(D, "created-body.md")
    if os.path.exists(created):
        body = open(created, encoding="utf-8").read()
    if "--jq" in args and args[args.index("--jq") + 1] == ".body":
        print(body)
    else:
        print(json.dumps({"body": body}))
    sys.exit(0)

if args[:2] == ["pr", "list"]:
    js = val("--json") or ""
    if "--jq" in args:
        # la consulta del verificador del reclamo: se aplica el mismo filtro
        # que el upstream (un verbo de cierre seguido de #N).
        jq = val("--jq") or ""
        m = re.search(r"#(\d+)", jq)
        issue_no = m.group(1) if m else ""
        pat = re.compile(r"(?i)\b(fix(e[sd])?|close[sd]?|resolve[sd]?)\b:?[ \t]+#%s([^0-9]|$)"
                         % re.escape(issue_no))
        for pr in fixtures():
            text = (pr.get("title") or "") + " " + (pr.get("body") or "")
            if pat.search(text):
                print(pr.get("number"))
        sys.exit(0)
    if "--head" in args:
        head = val("--head")
        out = [{"number": pr.get("number"), "labels": pr.get("labels") or []}
               for pr in fixtures() if pr.get("head") == head]
        print(json.dumps(out))
        sys.exit(0)
    if "url" in js:
        # la consulta de idempotencia: el JSON entero
        print(json.dumps([{"number": pr.get("number"), "title": pr.get("title") or "",
                           "body": pr.get("body") or "", "url": pr.get("url") or "",
                           "author": pr.get("author") or {},
                           "head": pr.get("head") or ""} for pr in fixtures()]))
        sys.exit(0)
    # la sonda de "se puede leer GitHub"
    print("1")
    sys.exit(0)

if args[:2] == ["api", "user"] or args[:1] == ["user"]:
    if "--jq" in args and args[args.index("--jq") + 1] == ".login":
        print("vdirienzo")
    else:
        print(json.dumps({"login": "vdirienzo"}))
    sys.exit(0)

if args[:1] == ["api"]:
    path = args[1] if len(args) > 1 else ""
    if "issues/" in path:
        print(json.dumps(issue()))
        sys.exit(0)
    if "claim" in path:
        print(json.dumps({"claim": {"state": "free"}}))
        sys.exit(0)
    if "pulls" in path and "-X" in args and args[args.index("-X") + 1] == "POST":
        print(json.dumps({"number": 999,
                          "html_url": "https://github.com/tangency-labs/solidcraft/pull/999"}))
        sys.exit(0)
    print("{}")
    sys.exit(0)

print("{}")
sys.exit(0)
STUB
chmod +x "$TMP/gh"

export STUB_DIR="$TMP"
export GH_BIN="$TMP/gh"
# El stub de gh NO va en el PATH: los scripts lo eligen con GH_BIN (regla 4).

# --- el cuerpo de cada caso ------------------------------------------------
B_YES="$TMP/body-yes.md"
cat > "$B_YES" <<'EOF'
Fixes #12842.

Changes a default: yes - a new length field in an operation dialog starts with the size its tool ships with, shown in the design's unit, old behaviour kept behind preference scaled_length_defaults

## Problem

The dialog opened with the wrong length.
EOF

B_PLAIN="$TMP/body-plain.md"
cat > "$B_PLAIN" <<'EOF'
Fixes #12842.

## Problem

The application crashed when the window was closed while a sketch was open.
EOF

B_PREF="$TMP/body-pref.md"
cat > "$B_PREF" <<'EOF'
Fixes #12842.

## Problem

The application crashed when the window was closed while a sketch was open.

## Fix

This adds a preference that stores the last sketch the user opened.
EOF

B_MALFORMED="$TMP/body-malformed.md"
cat > "$B_MALFORMED" <<'EOF'
Fixes #12842.

Changes a default: yes - changes the length of the new field
EOF

# --- el runner --------------------------------------------------------------
run_publish(){ # <body-file> <issue> <title> [extra...]
  local body="$1" issue="$2" title="$3"; shift 3
  : > "$TMP/calls.log"
  rm -f "$TMP/created-body.md" "$TMP/created.json"
  GH_BIN="$TMP/gh" LOOP_DIR="$LOOP_FAKE" CLAIM_VERIFY="$CLAIM_VERIFY" \
  bash "$PUBLISH_PR" --repo tangency-labs/solidcraft --base main \
       --head vdirienzo:fix/issue-12842-crash --title "$title" \
       --body-file "$body" --issue "$issue" "$@" > "$TMP/out.log" 2> "$TMP/err.log"
  echo $?
}
created(){ [ -f "$TMP/created-body.md" ] && cat "$TMP/created-body.md" || echo ""; }
created_exists(){ [ -f "$TMP/created-body.md" ]; }

# =====================================================================
# a) la forma larga valida: se publica y la linea NO se pisa
# =====================================================================
echo "# a) la forma larga valida se publica y la linea no se pisa"
echo '[]' > "$TMP/prs.json"
RC=$(run_publish "$B_YES" 12842 "Fix a crash in the operation dialog (#12842)")
[ "$RC" = "0" ] && ok "un body con la forma larga valida se publica (rc=0)" \
                || no "un body con la forma larga valida se publica" "rc=$RC $(cat "$TMP/err.log")"
created_exists && ok "se abrio el pull request" || no "se abrio el pull request"
if created | grep -q "^Changes a default: yes - a new length field"; then
  ok "la linea 'yes' se publica tal cual"
else
  no "la linea 'yes' se publica tal cual" "$(created)"
fi
if created | grep -q "Changes a default: no"; then
  no "un 'yes' valido NO se pisa con un 'no'"
else
  ok "un 'yes' valido NO se pisa con un 'no'"
fi

# =====================================================================
# b) sin linea y SIN tocar defaults: se publica con el 'no' agregado,
#    y la linea esta en el body ANTES de abrir
# =====================================================================
echo "# b) sin linea y sin tocar defaults: se publica con el 'no' y la linea va ANTES de abrir"
echo '[]' > "$TMP/prs.json"
RC=$(run_publish "$B_PLAIN" 12842 "Fix a crash when closing the window (#12842)")
[ "$RC" = "0" ] && ok "un body sin linea que no toca defaults se publica (rc=0)" \
                || no "un body sin linea que no toca defaults se publica" "rc=$RC $(cat "$TMP/err.log")"
if created | grep -q "^Changes a default: no$"; then
  ok "el body publicado lleva 'Changes a default: no'"
else
  no "el body publicado lleva 'Changes a default: no'" "$(created)"
fi
if created | grep -q "^Fixes #12842\.$"; then
  ok "el body conserva la linea 'Fixes #N.'"
else
  no "el body conserva la linea 'Fixes #N.'" "$(created)"
fi
# la prueba del ORDEN: el body que recibio el stub YA.traia la linea, o sea
# que estaba en el body cuando se abrio el pull request.
if grep -q "Changes a default: no" "$TMP/created.json" 2>/dev/null; then
  ok "la linea estaba en el body ANTES de abrir (no se agrego despues)"
else
  no "la linea estaba en el body ANTES de abrir (no se agrego despues)" "$(cat "$TMP/created.json" 2>/dev/null)"
fi
if grep -q "pr edit" "$TMP/calls.log"; then
  no "el camino de publicacion NUNCA usa 'gh pr edit' (dispara el check contra el body viejo)"
else
  ok "el camino de publicacion NUNCA usa 'gh pr edit' (dispara el check contra el body viejo)"
fi

# =====================================================================
# h) el body con un "\n" LITERAL (una sola linea): NO se publica
#    con un mensaje que diga la verdad (el "\`\\n" literal no es un salto)
# =====================================================================
echo "# h) el body con un '\n' literal no se publica y el mensaje lo explica"
B_ESCAPE="$TMP/body-escape.md"
printf 'Fixes #12842.\\nChanges a default: no\\n' > "$B_ESCAPE"
RC=$(run_publish "$B_ESCAPE" 12842 "Fix a crash when closing the window (#12842)")
if [ "$RC" != "0" ]; then
  ok "un body con un '\\n' literal NO se publica (rc!=0)"
else
  no "un body con un '\\n' literal NO se publica" "rc=0"
fi
if grep -qi "literal" "$TMP/err.log"; then
  ok "el mensaje explica que el '\\n' es literal y no un salto de linea"
else
  no "el mensaje explica que el '\\n' es literal y no un salto de linea" "$(cat "$TMP/err.log")"
fi
if [ -f "$TMP/created.json" ]; then
  no "no se abrio ningun pull request con el body del escape literal"
else
  ok "no se abrio ningun pull request con el body del escape literal"
fi

# =====================================================================
# c) sin linea y SI tocando defaults: NO se publica
# =====================================================================
echo "# c) sin linea y tocando defaults: no se publica y no se inventa un 'no'"
echo '[]' > "$TMP/prs.json"
RC=$(run_publish "$B_PREF" 12842 "Fix a crash when closing the window (#12842)")
[ "$RC" != "0" ] && ok "un PR que toca defaults NO se publica (rc=$RC)" \
                 || no "un PR que toca defaults NO se publica" "rc=0 (se publico)"
if created_exists; then
  no "no se abrio ningun pull request"
else
  ok "no se abrio ningun pull request"
fi
if grep -q "Changes a default" "$TMP/err.log"; then
  ok "el mensaje explica que falta la linea de los defaults"
else
  no "el mensaje explica que falta la linea de los defaults" "$(cat "$TMP/err.log")"
fi
if grep -q "old behaviour kept behind preference" "$TMP/err.log"; then
  ok "el mensaje dice la forma larga que hay que escribir"
else
  no "el mensaje dice la forma larga que hay que escribir" "$(cat "$TMP/err.log")"
fi

# =====================================================================
# d) el reclamo esta ocupado: NO se publica
# =====================================================================
echo "# d) el reclamo ocupado: no se publica"
cat > "$TMP/prs.json" <<'EOF'
[{"number": 12491, "title": "Fix a crash when closing the window (#12842)",
  "body": "Fixes #12842\n", "url": "https://github.com/tangency-labs/solidcraft/pull/12491",
  "author": {"login": "alguien-otro"}, "head": "alguien-otro:otra-rama", "labels": []}]
EOF
RC=$(run_publish "$B_PLAIN" 12842 "Fix a crash when closing the window (#12842)")
if [ "$RC" = "0" ]; then
  no "un reclamo ocupado NO se publica (rc=0)"
else
  ok "un reclamo ocupado NO se publica (rc=$RC)"
fi
if grep -q "reclamo" "$TMP/err.log"; then
  ok "el mensaje dice que el reclamo es de otro"
else
  no "el mensaje dice que el reclamo es de otro" "$(cat "$TMP/err.log")"
fi
if created_exists; then
  no "no se abrio ningun pull request con el reclamo ocupado"
else
  ok "no se abrio ningun pull request con el reclamo ocupado"
fi

# =====================================================================
# e) ya hay un pull request abierto nuestro para ese issue: no se abre otro
# =====================================================================
echo "# e) ya hay un pull request abierto nuestro: no se abre otro"
cat > "$TMP/prs.json" <<'EOF'
[{"number": 12500, "title": "Fix a crash when closing the window (#12842)",
  "body": "Fixes #12842\nChanges a default: no\n",
  "url": "https://github.com/tangency-labs/solidcraft/pull/12500",
  "author": {"login": "vdirienzo"}, "head": "vdirienzo:fix/issue-12842-crash", "labels": []}]
EOF
RC=$(run_publish "$B_PLAIN" 12842 "Fix a crash when closing the window (#12842)")
[ "$RC" = "0" ] && ok "ya existe un PR nuestro: sale con 0 (rc=0)" \
                || no "ya existe un PR nuestro: sale con 0" "rc=$RC $(cat "$TMP/err.log")"
if created_exists; then
  no "no se abrio un SEGUNDO pull request para el mismo issue"
else
  ok "no se abrio un SEGUNDO pull request para el mismo issue"
fi
if grep -q "^pr: 12500" "$TMP/out.log"; then
  ok "imprime el numero del pull request que ya existia"
else
  no "imprime el numero del pull request que ya existia" "$(cat "$TMP/out.log")"
fi

# =====================================================================
# f) una linea mal formada: NO se publica (y no se reescribe sola)
# =====================================================================
echo "# f) una linea mal formada: no se publica"
echo '[]' > "$TMP/prs.json"
RC=$(run_publish "$B_MALFORMED" 12842 "Fix a crash when closing the window (#12842)")
[ "$RC" != "0" ] && ok "una linea mal formada NO se publica (rc=$RC)" \
                 || no "una linea mal formada NO se publica" "rc=0"
if created_exists; then
  no "no se abrio ningun pull request con la linea mal formada"
else
  ok "no se abrio ningun pull request con la linea mal formada"
fi

# =====================================================================
# g) el body del PR se valida con el parser del upstream, no con una copia
# =====================================================================
echo "# g) el validador es el de la casa (el parser del upstream)"
if grep -q "pr-defaults-line.sh" "$PUBLISH_PR"; then
  ok "el script valida el body con pr-defaults-line.sh"
else
  no "el script valida el body con pr-defaults-line.sh"
fi
# Prohibido: "gh pr edit". Se mira la EJECUCION, no la prosa: el script
# explica en un comentario por que no se usa, y ese comentario no es la
# llamada. Una linea que EJECUTA el edit (no empieza por #) es un bug.
if grep -vE '^\s*#' "$PUBLISH_PR" | grep -qE '(^|["$ ])pr edit|gh pr edit'; then
  no "el script NO ejecuta ningun 'gh pr edit'" \
     "$(grep -vE '^\s*#' "$PUBLISH_PR" | grep -nE '(^|["$ ])pr edit|gh pr edit' | head -3)"
else
  ok "el script NO ejecuta ningun 'gh pr edit'"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
