#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-deploy-drift.sh - el deploy del loop no puede perder el camino unico.
#
# QUE ES EL DRIFT (2026-11-07):
#   El directorio del loop (~/.local/share/solidcraft-loop) NO es un clon del
#   repo: es el directorio de trabajo, con COPIAS de una lista FIJA de
#   ficheros. Nada los sincroniza. Un fichero que no esta en esa lista vive
#   SOLO en el runtime: un deploy desde el repo lo pierde, y el prompt que
#   lo invoca se queda apuntando a un archivo que no existe.
#
#   publish-pr.sh era uno de esos ficheros: los prompts lo invocan por ruta
#   ABSOLUTA, y un deploy desde el source lo borraba del runtime.
#
# QUE MIRA ESTE TEST (todo SIN RED, todo en el disco):
#   1. el wrapper existe en el runtime y en el source, y es ejecutable;
#   2. el source lo tiene en la LISTA DE COPIA del RUNBOOK (si no, el
#      proximo deploy lo pierde otra vez);
#   3. la ruta que los prompts invocan RESUELVE a un archivo que existe
#      (la ruta se PARSEA de los prompts, no esta escrita aqui: si el prompt
#      cambia la ruta, el test cambia con el);
#   4. los prompts del runtime y los del source dicen lo MISMO en las
#      lineas clave del camino unico (grep de publish-pr.sh);
#   5. la rama de deploy contiene los commits del camino unico y los de
#      worth-an-agent (git merge-base --is-ancestor).
#
# CODIGO DE SALIDA: 0 si no hay drift, 1 si hay drift (cada fallo se
#   nombra en la salida).
# ---------------------------------------------------------------------------
set -uo pipefail

# The directory of this script: it is where bin/paths.sh lives.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
# The SOURCE of the loop: the code that is deployed into the runtime.
#
# On this machine the loop half is VERSIONED in this repo (loop/) and the
# runtime points at it with symlinks, so the source is that directory. The
# literal below is the separate clone the machine had before, and it stays as
# the fallback for a machine without bin/paths.sh (and for one whose loop half
# is not versioned here).
if [ -z "${LOOP_SRC:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
  if [ -d "$ORCH_DIR/loop" ]; then LOOP_SRC="$ORCH_DIR/loop"; fi
fi
LOOP_SRC="${LOOP_SRC:-/home/user/solidcraft-loop}"
LOOP_RT="${LOOP_RT:-/home/user/.local/share/solidcraft-loop}"
RUNBOOK="${RUNBOOK:-$LOOP_SRC/RUNBOOK/el-dir-del-loop-no-es-un-clon-del-repo.md}"

FAILURES=0
CHECKS=0

ok() {
  CHECKS=$((CHECKS + 1))
  echo "ok   - $1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  echo "FALLO - $1"
}

echo "=== el deploy del loop no puede perder el camino unico ==="
echo "source: $LOOP_SRC"
echo "runtime: $LOOP_RT"
echo

# --- 1. el wrapper existe en los dos lados, y es ejecutable ---------------
for dir in "$LOOP_RT" "$LOOP_SRC"; do
  case "$dir" in
    "$LOOP_RT") label="el runtime" ;;
    *) label="el source" ;;
  esac
  if [ ! -f "$dir/bin/publish-pr.sh" ]; then
    fail "el wrapper no esta en $label: $dir/bin/publish-pr.sh"
  elif [ ! -x "$dir/bin/publish-pr.sh" ]; then
    fail "el wrapper no es ejecutable en $label: $dir/bin/publish-pr.sh"
  else
    ok "el wrapper esta y es ejecutable en $label"
  fi
done

# --- 2. el source lo tiene en la LISTA DE COPIA del RUNBOOK --------------
if [ ! -f "$RUNBOOK" ]; then
  fail "no se encuentra el RUNBOOK de la lista de copia: $RUNBOOK"
else
  if grep -q 'bin/publish-pr\.sh' "$RUNBOOK"; then
    ok "el RUNBOOK de la lista de copia menciona bin/publish-pr.sh"
  else
    fail "el RUNBOOK de la lista de copia NO menciona bin/publish-pr.sh: un deploy lo pierde"
  fi
  # El SNIPPET del bucle de copia es lo que la gente ejecuta de verdad: si
  # el fichero esta en la tabla pero no en el bucle, el deploy lo pierde.
  if awk '/^for f in /,/; do/' "$RUNBOOK" | grep -q 'bin/publish-pr\.sh'; then
    ok "el bucle de copia del RUNBOOK copia bin/publish-pr.sh"
  else
    fail "el bucle de copia del RUNBOOK NO copia bin/publish-pr.sh: el deploy lo pierde"
  fi
fi

# --- 3. la ruta que los prompts invocan resuelve a un archivo que existe --
# La ruta se PARSEA de los prompts: no esta escrita en el test, para que el
# test siga siendo verdad si el prompt cambia la ruta.
PROMPT_PATH=""
# La ruta que el prompt invoca se busca con el prefijo de ESTA maquina, que
# se arma aqui para que este fichero no lo lleve escrito (el grep del criterio
# de portabilidad recorre bin/ y tiene que no encontrar nada, ni aqui).
HOMEBASE='/home/'"user"
for prompt in "$LOOP_RT"/prompts/*.md "$LOOP_SRC"/prompts/*.md; do
  [ -f "$prompt" ] || continue
  found="$(grep -o "$HOMEBASE/[^ \`"'"'"]*/bin/publish-pr\.sh" "$prompt" 2>/dev/null | head -1)"
  if [ -n "$found" ]; then
    PROMPT_PATH="$found"
    break
  fi
done

if [ -z "$PROMPT_PATH" ]; then
  fail "ningun prompt invoca una ruta de publish-pr.sh: no hay nada que resolver"
else
  if [ -f "$PROMPT_PATH" ]; then
    ok "la ruta que invocan los prompts existe: $PROMPT_PATH"
  else
    fail "la ruta que invocan los prompts NO existe: $PROMPT_PATH"
  fi
fi

# --- 3b. el wrapper del runtime delega en el orquestador, que existe ------
ORCH_PUBLISH="$ORCH_DIR/bin/publish-pr.sh"
if [ ! -f "$ORCH_PUBLISH" ]; then
  fail "el orquestador no tiene bin/publish-pr.sh: $ORCH_PUBLISH"
elif [ ! -x "$ORCH_PUBLISH" ]; then
  fail "el orquestador tiene bin/publish-pr.sh pero no es ejecutable: $ORCH_PUBLISH"
else
  ok "el orquestador tiene bin/publish-pr.sh, ejecutable: $ORCH_PUBLISH"
fi

# --- 3c. el wrapper NO delega en si mismo (seria un bucle infinito) -------
# El wrapper se prueba con ORCH_DIR apuntando al propio runtime: si
# delegara en si mismo, el comando no volveria nunca. Con `timeout` el
# bucle se ve como un timeout, y eso es un FALLO, no un PASS.
if command -v timeout >/dev/null 2>&1; then
  out="$(ORCH_DIR="$LOOP_RT" timeout 20 bash "$LOOP_RT/bin/publish-pr.sh" --repo x/y 2>&1)"
  rc=$?
  if [ "$rc" -eq 124 ]; then
    fail "el wrapper con ORCH_DIR=$LOOP_RT se queda delegando en si mismo (timeout)"
  elif [ "$rc" -eq 0 ]; then
    fail "el wrapper con ORCH_DIR=$LOOP_RT sale con 0: un fallo silencioso"
  else
    ok "el wrapper con ORCH_DIR=$LOOP_RT se niega a delegar en si mismo (rc=$rc)"
  fi
else
  echo "AVISO - no hay 'timeout': no se prueba el bucle de delegacion"
fi

# --- 4. los prompts del runtime y los del source dicen lo MISMO ----------
# Solo en las LINEAS CLAVE del camino unico: el resto del prompt puede
# tener diferencias legitimas (el runtime tiene backups .bak, etc.).
for prompt in publish claim; do
  rt="$LOOP_RT/prompts/$prompt.md"
  src="$LOOP_SRC/prompts/$prompt.md"
  if [ ! -f "$rt" ] || [ ! -f "$src" ]; then
    fail "falta el prompt $prompt.md en el runtime o en el source"
    continue
  fi
  rt_lines="$(grep -c 'publish-pr\.sh' "$rt" 2>/dev/null || echo 0)"
  src_lines="$(grep -c 'publish-pr\.sh' "$src" 2>/dev/null || echo 0)"
  if [ "$rt_lines" -eq 0 ]; then
    fail "el prompt $prompt.md del runtime no menciona publish-pr.sh"
  elif [ "$rt_lines" -ne "$src_lines" ]; then
    fail "el prompt $prompt.md del runtime ($rt_lines) y el del source ($src_lines) no dicen lo mismo"
  elif ! diff -q <(grep 'publish-pr\.sh' "$rt") <(grep 'publish-pr\.sh' "$src") >/dev/null 2>&1; then
    fail "las lineas de publish-pr.sh del prompt $prompt.md difieren entre runtime y source"
  else
    ok "el prompt $prompt.md dice lo mismo en el runtime y en el source ($rt_lines lineas)"
  fi
done

# --- 4b. los ficheros que vivian SOLO en el runtime, ahora estan aqui ----
for f in pr-defaults-line.sh prompts-inventory.py test-prompts-inventory.py; do
  if [ ! -f "$LOOP_SRC/bin/$f" ]; then
    fail "el source no tiene bin/$f (vivia solo en el runtime)"
  elif [ ! -f "$LOOP_RT/bin/$f" ]; then
    fail "el runtime no tiene bin/$f"
  else
    ok "bin/$f esta en el source y en el runtime"
  fi
done

# --- 4c. pr-defaults-line.sh tiene el modo --body (lo que usa el script) -
if grep -q -- '--body' "$LOOP_SRC/bin/pr-defaults-line.sh" 2>/dev/null; then
  ok "bin/pr-defaults-line.sh del source tiene el modo --body"
else
  fail "bin/pr-defaults-line.sh del source NO tiene el modo --body"
fi

# --- 5. la rama de deploy contiene los commits del camino unico ---------
cd "$LOOP_SRC" 2>/dev/null || {
  fail "no se puede entrar al repo del source: $LOOP_SRC"
  echo
  echo "FALLOS: $FAILURES de $CHECKS"
  exit 1
}

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
for ref in origin/fix/publish-pr-unica origin/feat/worth-an-agent-list; do
  if ! git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    fail "la rama $ref no existe en el repo del source"
    continue
  fi
  if git merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
    ok "la rama de deploy ($BRANCH) contiene $ref"
  else
    fail "la rama de deploy ($BRANCH) NO contiene $ref"
  fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "OK: $CHECKS comprobaciones, sin drift de deploy."
  exit 0
fi
echo "FALLOS: $FAILURES de $CHECKS comprobaciones."
exit 1
