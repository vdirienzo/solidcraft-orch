#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# publish-pr.sh - EL CAMINO UNICO para abrir un pull request nuestro.
#
# POR QUE ESTE SCRIPT EXISTE (2026-11-07, bug real):
#   El check de upstream (pr-checks.yml) corre con
#     pull_request: types: [opened, edited, synchronize, reopened, ...]
#   asi que el job "Defaults line check" se dispara AL ABRIR el pull request,
#   contra el body que tiene EN ESE MOMENTO. Si el body no lleva la linea
#   "Changes a default:", el check queda ROJO y sigue en pantalla hasta el
#   siguiente push (medido: #12891 y #12574).
#
#   El problema NO era el check: era que HUBO DOS CAMINOS de publicacion.
#     * bin/agent-issue.sh (del loop): arma el body, lo valida con
#       pr-defaults-line.sh ANTES de publicar y abre el PR. Ese camino esta
#       bien.
#     * los subagentes de la wave: "gh pr create" a mano, sin freno. Por ahi
#       se escapa la linea (#12491, #12511).
#   Este script es el segundo camino, BIEN: es el unico que se usa, y arma el
#   body con la linea ANTES de que el pull request exista.
#
# EL ORDEN ES TODO:
#   la linea tiene que estar en el body EN EL MOMENTO de "gh pr create".
#   NUNCA "gh pr edit" despues para agregar la linea: eso dispara el check
#   contra el body viejo y deja el pull request con un check rojo en pantalla.
#
# USO:
#   bash bin/publish-pr.sh --repo <owner/name> --base <branch> --head <branch>
#                          --title <titulo> --body-file <archivo> --issue <N>
#                          [--draft]
#   --body <texto> es la alternativa a --body-file (un agente que no puede
#   escribir archivos).
#
# QUE HACE, EN ORDEN:
#   1. lee el body;
#   2. decide la linea de los defaults de forma HONESTA:
#      - si el body YA trae una linea "Changes a default:", NO la pisa nunca
#        (ni un "yes" valido): una linea existente nunca se reescribe;
#      - si el body NO trae la linea y el cambio TOCA defaults/preferencias,
#        NO la inventa: NO publica y deja el motivo (una persona decide);
#      - si el body NO trae la linea y el cambio NO toca defaults, agrega
#        "Changes a default: no", que es la verdad;
#   3. valida el body final con LOOP/bin/pr-defaults-line.sh (el parser del
#      upstream): si no pasa, NO se abre el pull request;
#   4. es idempotente: si ya hay un pull request abierto nuestro para ese
#      issue, lo imprime y sale con 0 (no abre un segundo);
#   5. verifica el reclamo con ORCH/bin/claim-verify.sh ANTES de abrir: si
#      el reclamo esta ocupado (1) o el issue ya no esta abierto (11), NO
#      abre el pull request;
#   6. abre el pull request EN DRAFT (el gate local y el CI de GitHub son los
#      que lo pasan a ready) y verifica el body publicado con "gh pr view".
#
# CODIGOS DE SALIDA:
#   0  el pull request se abrio (o ya existia)
#   2  uso incorrecto
#   3  el body NO pasa el check de la linea de los defaults: no se publica
#   4  el reclamo no es nuestro (ocupado) o el issue ya no esta abierto:
#      no se publica
#   5  GitHub no pudo abrir (o no se pudo leer) el pull request
#   6  el check de la linea NO se pudo hacer (UNKNOWN): no se publica
#
# NUNCA: mergea, cierra, etiqueta ni pushea a upstream.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
DEFAULTS_LINE="$LOOP_DIR/bin/pr-defaults-line.sh"
# El checkout del upstream: de ahi sale el parser que valida el body (lo llama
# LOOP/bin/pr-defaults-line.sh).
#
# The machine's own paths know where the checkout is (bin/paths.sh, 2026-11-24): the default
# below is only the fallback for a machine without that file. The literal was stale, so the
# validator answered "the parser of the upstream is not there" (exit 6) and NO pull request was
# ever published.
if [ -z "${SOLIDCRAFT_REPO:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
fi
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
export SOLIDCRAFT_REPO
# El verificador del reclamo: el de la casa por defecto, pero se puede
# cambiar (un test pone uno de mentira).
CLAIM_VERIFY="${CLAIM_VERIFY:-$ORCH_DIR/bin/claim-verify.sh}"
GH_BIN="${GH_BIN:-gh}"
# pipeline.py vive al lado de este script: sus funciones puras son la regla
# de la linea de los defaults (mismo criterio que el upstream, sin duplicarlo).
export PUBLISH_PR_BIN_DIR="$HERE"

REPO=""
BASE=""
HEAD=""
TITLE=""
BODY_FILE=""
BODY_TEXT=""
ISSUE=""
# el draft es el default: lo pasan a ready el gate local y el CI de GitHub

die() { # <codigo> <mensaje...>
  local rc="$1"; shift
  printf 'publish-pr: %s\n' "$*" >&2
  exit "$rc"
}

usage() {
  cat >&2 <<'EOF'
uso: publish-pr.sh --repo <owner/name> --base <branch> --head <branch>
                    --title <titulo> --body-file <archivo> --issue <N> [--draft]
       publish-pr.sh ... --body <texto>   (en vez de --body-file)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --base)      BASE="${2:-}"; shift 2 ;;
    --head)      HEAD="${2:-}"; shift 2 ;;
    --title)     TITLE="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --body)      BODY_TEXT="${2:-}"; shift 2 ;;
    --issue)     ISSUE="${2:-}"; shift 2 ;;
    --draft)     shift ;;  # el draft es el default: el flag se acepta y no cambia nada
    --no-draft)  die 2 "el pull request se abre SIEMPRE en draft: el gate local y el CI de GitHub lo pasan a ready" ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die 2 "opcion desconocida: $1" ;;
  esac
done

[ -n "$REPO" ]  || { usage; die 2 "falta --repo"; }
[ -n "$BASE" ]  || { usage; die 2 "falta --base"; }
[ -n "$HEAD" ]  || { usage; die 2 "falta --head"; }
[ -n "$TITLE" ] || { usage; die 2 "falta --title"; }
[ -n "$ISSUE" ] || { usage; die 2 "falta --issue"; }
case "$ISSUE" in ''|*[!0-9]*) usage; die 2 "el issue tiene que ser un numero: $ISSUE" ;; esac

if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die 2 "el archivo del body no existe: $BODY_FILE"
  BODY_TEXT="$(cat -- "$BODY_FILE")" || die 2 "el body no se pudo leer: $BODY_FILE"
elif [ -z "$BODY_TEXT" ]; then
  usage; die 2 "falta --body-file o --body"
fi

# --- 1. el body, en un archivo temporal -------------------------------------
TMP_BODY="$(mktemp "${TMPDIR:-/tmp}/publish-pr-body.XXXXXX")" || die 2 "no se pudo crear el archivo del body"
cleanup() { rm -f "$TMP_BODY"; }
trap cleanup EXIT
printf '%s' "$BODY_TEXT" > "$TMP_BODY"

# --- 2. la decision HONESTA de la linea de los defaults ----------------------
# Las tres preguntas se las responde pipeline.py (mismo criterio que el
# upstream): la linea esta?, esta mal formada?, el texto habla de defaults?
ANALYSIS="$(PUBLISH_PR_BIN_DIR="$HERE" python3 - "$TMP_BODY" "$TITLE" <<'PY' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ.get("PUBLISH_PR_BIN_DIR", "."))
try:
    import pipeline as P
except Exception:
    print("ERROR 0 0")
    raise SystemExit(0)
body = open(sys.argv[1], encoding="utf-8").read()
title = sys.argv[2]
try:
    presente = 1 if P.linea_defaults_presente(body) else 0
    malformada = 1 if P.linea_defaults_malformada(body) else 0
    habla = 1 if P.habla_de_defaults(body, title) else 0
except Exception:
    presente = malformada = habla = 0
print(f"{presente} {malformada} {habla}")
PY
)"
[ -n "$ANALYSIS" ] || ANALYSIS="ERROR 0 0"
read -r HAVE_LINE MALFORMED TALKS <<<"$ANALYSIS"

if [ "$HAVE_LINE" = "ERROR" ]; then
  die 6 "no se pudo analizar el body (no esta pipeline.py): el check de la linea de los defaults NO se hizo"
fi

# Un "\`\\n" LITERAL en el body (escribirlo en una sola linea) es una trampa:
# el upstream lee el body linea por linea, asi que "Changes a default:" no
# queda al principio de una linea y el check la rechaza. Solo se avisa cuando
# el arreglo es claro (convertirlo en un salto de verdad deja la linea en su
# sitio); un "\n" de verdad dentro de un bloque de codigo no se toca.
ESCAPE_ALT="$(PUBLISH_PR_BIN_DIR="$HERE" python3 - "$TMP_BODY" <<'PY' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ.get("PUBLISH_PR_BIN_DIR", "."))
try:
    import pipeline as P
except Exception:
    print("0"); raise SystemExit(0)
body = open(sys.argv[1], encoding="utf-8").read()
if "\\n" not in body:
    print("0"); raise SystemExit(0)
try:
    if P.linea_defaults_presente(body):
        print("0"); raise SystemExit(0)
    if P.linea_defaults_presente(body.replace("\\n", "\n")):
        print("1"); raise SystemExit(0)
except Exception:
    pass
print("0")
PY
)"
if [ "$ESCAPE_ALT" = "1" ]; then
  die 3 "el body tiene un '\\n' LITERAL (la barra y la ene, no un salto de linea): el upstream lee el body linea por linea, asi que la linea 'Changes a default:' no queda al principio de una linea y el check la rechaza. Escribi el body con saltos de linea de verdad (un archivo con --body-file, o el prompt que lo arma) y volve a intentarlo"
fi

# La etiqueta 'changes-default' (la del upstream) tambien dice que el cambio
# toca defaults. Se mira en el issue y en un pull request que ya exista de esta
# rama: un "no" automatico con esa etiqueta seria mentira.
# El estado del issue tambien se lee aqui: un issue CERRADO (o resuelto) no
# se publica (es el "11" de claim-brake.sh: el trabajo es MOOT, no perdido).
LABEL_DEFAULT=0
ISSUE_STATE="open"
issue_json="$("$GH_BIN" api "repos/$REPO/issues/$ISSUE" 2>/dev/null || true)"
if [ -n "$issue_json" ]; then
  read -r LABEL_DEFAULT ISSUE_STATE <<<"$(printf '%s' "$issue_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
names = []
for l in (d.get("labels") or []):
    names.append((l.get("name") if isinstance(l, dict) else str(l)) or "")
print(("1" if "changes-default" in names else "0"),
      (d.get("state") or "open"))
' 2>/dev/null || echo "0 open")"
fi
branch_prs="$("$GH_BIN" pr list --repo "$REPO" --state all --head "$HEAD" --json number,labels 2>/dev/null || true)"
if [ -n "$branch_prs" ]; then
  case "$branch_prs" in *'"changes-default"'*) LABEL_DEFAULT=1 ;; esac
fi

if [ "$HAVE_LINE" = "1" ]; then
  # Una linea existente NUNCA se reescribe: ni un "yes" valido, ni un "no".
  if [ "$MALFORMED" = "1" ]; then
    die 3 "el body trae una linea 'Changes a default:' MAL FORMADA: no se reescribe (una linea existente nunca se pisa) y el check de upstream la va a rechazar. Escribila bien y volve a intentarlo"
  fi
  echo "publish-pr: el body ya trae la linea de los defaults: no se toca" >&2
elif [ "$TALKS" = "1" ] || [ "$LABEL_DEFAULT" = "1" ]; then
  # El cambio TOCA defaults: el script NO inventa el "no". El que decide es
  # una persona (la regla del repo: el comportamiento viejo queda detrás de
  # una preferencia).
  die 3 "el pull request toca defaults/preferencias y el body NO trae la linea 'Changes a default:': no se publica y no se inventa un 'no'. Escribila a mano con la forma larga:
  Changes a default: yes - <que cambia>, old behaviour kept behind preference <nombre>"
else
  # No toca defaults: el "no" es la verdad.
  LINEA_NO="Changes a default: no"
  PUBLISH_PR_BIN_DIR="$HERE" python3 - "$TMP_BODY" "$LINEA_NO" <<'PY' || die 3 "no se pudo escribir la linea de los defaults en el body"
import re, sys
path = sys.argv[1]
LINE = sys.argv[2]
text = open(path, encoding="utf-8").read()
m = re.match(r"^(?:Fixes|Closes|Resolves)\b[^\n]*\n", text)
if m:
    rest = text[m.end():].lstrip("\n")
    new = text[:m.end()].rstrip("\n") + "\n\n" + LINE + "\n\n" + rest
else:
    new = LINE + "\n\n" + text
open(path, "w", encoding="utf-8").write(new)
PY
  echo "publish-pr: el body no trae la linea y el cambio NO toca defaults: se agrega '$LINEA_NO'" >&2
fi

# --- 3. el pre-flight: el parser del upstream sobre el body final -----------
if [ ! -f "$DEFAULTS_LINE" ]; then
  die 6 "el check de la linea de los defaults no esta ahi: $DEFAULTS_LINE (UNKNOWN: el check NO se hizo)"
fi
VALIDATE_OUT="$(bash "$DEFAULTS_LINE" --body "$TMP_BODY" 2>&1)"
VALIDATE_RC=$?
case "$VALIDATE_RC" in
  0) echo "publish-pr: el body pasa el check de la linea de los defaults ($VALIDATE_OUT)" >&2 ;;
  1) printf '%s\n' "$VALIDATE_OUT" >&2
     die 3 "el body NO pasa el check de la linea de los defaults: no se publica" ;;
  2) printf '%s\n' "$VALIDATE_OUT" >&2
     die 2 "el check de la linea de los defaults no se pudo correr (uso o lectura)" ;;
  6) printf '%s\n' "$VALIDATE_OUT" >&2
     die 6 "el check de la linea de los defaults NO se pudo hacer (UNKNOWN): no se publica" ;;
  *) printf '%s\n' "$VALIDATE_OUT" >&2
     die 3 "el check de la linea de los defaults dio un codigo inesperado: $VALIDATE_RC" ;;
esac

# --- 4. idempotencia: un pull request abierto nuestro para ese issue --------
# El autor "nuestro": el del fork (FORK_OWNER) o, si no se sabe, el usuario
# autenticado. Si no se puede determinar, se es conservador: cualquier pull
# request abierto que mencione el issue cuenta como "ya abierto".
AUTHOR="${FORK_OWNER:-}"
if [ -z "$AUTHOR" ] && [ -r "$LOOP_DIR/config.env" ]; then
  AUTHOR="$(grep -E '^[[:space:]]*(export[[:space:]]+)?FORK_OWNER=' "$LOOP_DIR/config.env" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"'"'" | tr -d '[:space:]')"
fi
if [ -z "$AUTHOR" ]; then
  AUTHOR="$("$GH_BIN" api user --jq .login 2>/dev/null || true)"
fi
EXISTING="$("$GH_BIN" pr list --repo "$REPO" --state open --json number,title,body,url,author 2>/dev/null || true)"
EXISTING_N=""
if [ -n "$EXISTING" ]; then
  # El JSON va por un archivo: un heredoc por stdin taparia el pipe.
  EXISTING_FILE="$(mktemp "${TMPDIR:-/tmp}/publish-pr-existing.XXXXXX")"
  printf '%s' "$EXISTING" > "$EXISTING_FILE"
  EXISTING_N="$(PUBLISH_PR_BIN_DIR="$HERE" python3 - "$EXISTING_FILE" "$ISSUE" "$AUTHOR" <<'PY' 2>/dev/null
import json, re, sys
issue = sys.argv[2]
author = (sys.argv[3] or "").strip().lower()
try:
    prs = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    prs = []
pat = re.compile(r"(?i)(?:#|issue\s*#?)\s*%s([^0-9]|$)" % re.escape(issue))
for pr in prs or []:
    a = pr.get("author") or {}
    login = (a.get("login") if isinstance(a, dict) else str(a)) or ""
    if author and login and login.lower() != author:
        continue
    text = (pr.get("title") or "") + " " + (pr.get("body") or "")
    if pat.search(text):
        print("%s\t%s" % (pr.get("number"), pr.get("url") or ""))
        break
PY
)"
  rm -f "$EXISTING_FILE"
fi
if [ -n "$EXISTING_N" ]; then
  EX_NUM="${EXISTING_N%%$'\t'*}"
  EX_URL="${EXISTING_N#*$'\t'}"
  [ "$EX_URL" = "$EXISTING_N" ] && EX_URL=""
  echo "publish-pr: ya hay un pull request abierto nuestro para el issue $ISSUE: #$EX_NUM" >&2
  printf 'pr: %s\n' "$EX_NUM"
  [ -n "$EX_URL" ] && printf 'url: %s\n' "$EX_URL"
  printf 'abierto: no (ya existia)\n'
  exit 0
fi

# --- 5. el reclamo, ANTES de abrir -----------------------------------------
# claim-verify.sh: 0 = el reclamo es nuestro o el issue esta libre,
# 1 = otro pull request lo reclama (ocupado), 11 = el issue ya no esta
# abierto (resuelto), 2 = no se pudo verificar (UNKNOWN).
CLAIM_OUT=""
CLAIM_RC=0
if [ -f "$CLAIM_VERIFY" ]; then
  CLAIM_OUT="$(SC_REPO="$REPO" bash "$CLAIM_VERIFY" "$ISSUE" 2>&1)"
  CLAIM_RC=$?
else
  CLAIM_OUT="claim-verify.sh no esta ahi: $CLAIM_VERIFY"
  CLAIM_RC=2
fi
# THE EXIT CODES OF THE ARBITER ARE THE VERDICT AND THEY ARE NOT
# TRANSLATED (2026-11-17). The arbiter returns 0 (ours), 1 (lost) and 2
# (could not be checked). This used to fold the 2 into the same 4 as the
# "lost", which told the operator that somebody else had the issue when
# nobody knew: the two cost very different things. A lost claim is a
# race we lost; an unknown claim is a question we could not answer, and
# the answer is to ask again, not to close the work.
case "$CLAIM_RC" in
  0) echo "publish-pr: el reclamo es nuestro: $CLAIM_OUT" >&2 ;;
  1) printf '%s\n' "$CLAIM_OUT" >&2
     die 4 "el reclamo del issue $ISSUE lo tiene otro pull request: no se publica" ;;
  2) printf '%s\n' "$CLAIM_OUT" >&2
     die 2 "el reclamo del issue $ISSUE no se pudo verificar (UNKNOWN): no se publica ni se abandona" ;;
  *) printf '%s\n' "$CLAIM_OUT" >&2
     die 2 "el reclamo del issue $ISSUE dio un codigo inesperado ($CLAIM_RC): no se publica" ;;
esac

# El issue cerrado es el caso "RESOLVED" del freno del reclamo (11): el
# trabajo es MOOT para este issue, no perdido. No se publica.
if [ "$ISSUE_STATE" != "open" ]; then
  die 4 "el issue $ISSUE esta '$ISSUE_STATE' (ya no esta abierto): no se publica"
fi

# --- 5b. el DUPLICADO por parche, ANTES de abrir ---------------------------
# claim-verify.sh (y el Duplicate PR check del upstream) buscan solo el verbo
# de cierre (Fixes/Closes/Resolves #N). Un competidor que describe el fallo en
# prosa, sin el verbo, es INVISIBLE para los dos: asi nos paso con el PR
# #14822, duplicado byte a byte del #14811 de otro autor, y el guard dio por
# nuestro lo que era el rival. Dos PRs con el mismo diff se bloquean entre si
# y el perdedor no se mergea nunca.
#
# dup-scan.sh razona sobre el PARCHE: si otro PR abierto agrega las mismas
# lineas que el nuestro, compiten por el mismo merge. rc=1 = duplicado
# CONFIRMADO: no se publica.
#
# rc=2 (no se pudo verificar) NO frena: es un fallo de la herramienta, no un
# hecho. Publicar de mas se corrige cerrando el PR; frenar el wave por un
# error de red no tiene arreglo. El aviso queda en el log.
DUP_SCAN="${DUP_SCAN:-$ORCH_DIR/bin/dup-scan.sh}"
if [ -f "$DUP_SCAN" ]; then
  DUP_OUT="$(SC_REPO="$REPO" SC_WORKTREE="${SC_WORKTREE:-$REPO}" \
               bash "$DUP_SCAN" "$ISSUE" "$HEAD" 2>&1)"
  DUP_RC=$?
  case "$DUP_RC" in
    0) echo "publish-pr: sin duplicado por parche." >&2 ;;
    1) printf '%s\n' "$DUP_OUT" >&2
       die 4 "hay un PR abierto que replica nuestro parche: no se publica (el numero mas bajo gana)" ;;
    2) printf '%s\n' "$DUP_OUT" >&2
       echo "publish-pr: ATENCION: no se pudo verificar el duplicado por parche: se publica igual." >&2 ;;
    *) printf '%s\n' "$DUP_OUT" >&2
       echo "publish-pr: ATENCION: el chequeo de duplicado dio un codigo inesperado ($DUP_RC): se publica igual." >&2 ;;
  esac
fi

# --- 6. abrir el pull request, EN DRAFT ------------------------------------
# "gh pr create" con --body-file: el body que se lee es EXACTAMENTE el que
# se valido arriba (con la linea dentro). Nunca "gh pr edit" despues.
CREATE_OUT=""
CREATE_RC=0
ATTEMPT=0
while [ "$ATTEMPT" -lt 3 ]; do
  ATTEMPT=$(( ATTEMPT + 1 ))
  CREATE_OUT="$("$GH_BIN" pr create --draft --repo "$REPO" --base "$BASE" --head "$HEAD" \
                        --title "$TITLE" --body-file "$TMP_BODY" 2>&1)"
  CREATE_RC=$?
  [ "$CREATE_RC" -eq 0 ] && break
  sleep 5
done

if [ "$CREATE_RC" -ne 0 ]; then
  # El GraphQL ve la rama nueva del fork con retraso ("Head sha can't be
  # blank"): el camino que nunca falla es la API REST.
  printf '%s\n' "$CREATE_OUT" >&2
  FINAL_BODY="$(cat -- "$TMP_BODY")"
  CREATE_OUT="$("$GH_BIN" api -X POST "repos/$REPO/pulls" \
                       -f title="$TITLE" -f body="$FINAL_BODY" \
                       -f head="$HEAD" -f base="$BASE" -F draft=true 2>&1)"
  CREATE_RC=$?
fi

PR_NUMBER=""
PR_URL=""
if [ "$CREATE_RC" -eq 0 ]; then
  PR_NUMBER="$(printf '%s' "$CREATE_OUT" | grep -o 'pull/[0-9]\+' | head -1 | cut -d/ -f2)"
  PR_URL="$(printf '%s' "$CREATE_OUT" | grep -o 'https://[^ ]*pull/[0-9]\+' | head -1)"
  if [ -z "$PR_NUMBER" ]; then
    PR_NUMBER="$(printf '%s' "$CREATE_OUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("number") or "")' 2>/dev/null || true)"
    [ -n "$PR_URL" ] || PR_URL="https://github.com/$REPO/pull/$PR_NUMBER"
  fi
fi

if [ -z "$PR_NUMBER" ]; then
  printf '%s\n' "$CREATE_OUT" >&2
  die 5 "no se pudo abrir el pull request: el numero no se pudo leer"
fi

# --- 7. el post-flight: el body publicado carries the line ------------------
PUBLISHED_BODY="$("$GH_BIN" pr view "$PR_NUMBER" --repo "$REPO" --json body --jq .body 2>/dev/null || true)"
if [ -n "$PUBLISHED_BODY" ]; then
  printf '%s' "$PUBLISHED_BODY" > "$TMP_BODY"
  if ! bash "$DEFAULTS_LINE" --body "$TMP_BODY" >/dev/null 2>&1; then
    die 5 "el pull request #$PR_NUMBER se abrio SIN la linea de los defaults: no se confirma la publicacion"
  fi
  echo "publish-pr: la linea de los defaults esta confirmada en el pull request #$PR_NUMBER" >&2
else
  echo "publish-pr: no se pudo leer el body publicado (el pull request #$PR_NUMBER existe)" >&2
fi

printf 'pr: %s\n' "$PR_NUMBER"
printf 'url: %s\n' "$PR_URL"
printf 'draft: si (el gate local y el CI de GitHub lo pasan a ready)\n'
exit 0
