#!/usr/bin/env bash
# Re-verifica el claim de un issue DESPUES de abrir el draft.
#
# Por que existe: el bot pone el label 'in progress' con retraso, asi que
# entre el survey y el draft otro agente puede reclamar el issue. Perdimos
# #10134, #10138 y #10079 asi el 31-10-2026 (ver RULES.md, paso 5).
#
# Uso:
#   bash bin/claim-verify.sh <issue> [nuestro_pr]
#
# Salida:
#   0  -> el claim es NUESTRO: ningun PR abierto con numero menor menciona #N
#   1  -> el claim se PERDIO: hay un PR abierto con numero menor para #N
#   2  -> error de uso / no se pudo verificar
#
# Si se perdio, el que llamo tiene que:
#   gh pr close <nuestro_pr>      (cerrar el nuestro)
#   bash bin/slot-lock.sh --slot N --release
set -uo pipefail

ISSUE="${1:-}"
OUR_PR="${2:-}"

if [[ -z "$ISSUE" ]]; then
  echo "uso: bash bin/claim-verify.sh <issue> [nuestro_pr]" >&2
  exit 2
fi
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "el issue tiene que ser un numero: '$ISSUE'" >&2
  exit 2
fi

REPO="${SC_REPO:-tangency-labs/solidcraft}"
LIMIT="${SC_PR_LIMIT:-1000}"

# Los PRs abiertos que REALMENTE reclaman el issue.
#
# Un "claim" es un verbo de cierre (Fixes / Closes / Resolves) seguido del
# numero, como en el parser del upstream (scripts/pr-checks/pr-checks.js,
# parseClosing). Una MENSA en prosa NO es un claim: el PR #6997 decia "since
# #10183 the UI follows the system language" y con la regla anterior
# conta-ba como un competidor que nos quitaba el reclamo. El gate abortaba
# con exit 4 sobre un issue cuyo trabajo ya estaba mergeado.
#
# gh pr list (y no gh api) porque el listado de la api devuelve el cuerpo
# vacio en algunos PRs y el filtro sobre el body no encuentra nada.
# El filtro va en un archivo aparte: el jq lleva escapes de backslash y
# comillas, y metido en el --jq de una linea se rompe el quoting de bash.
# El filtro se construye con el numero del issue ya puesto: el --jq de una
# linea no aguanta los escapes del patron, y un archivo aparte con un sed
# encima metia una capa mas de la que depurar.
CLAIM_JQ="$(mktemp)"
{
  printf '%s\n' '.[] | select(((.title // "") + " " + (.body // ""))'
  printf '%s\n' "  | test(\"(?i)\\\\b(fix(e[sd])?|close[sd]?|resolve[sd]?)\\\\b:?[ \\\\t]+#${ISSUE}([^0-9]|$)\")"
  printf '%s\n' '  ) | .number'
} >"$CLAIM_JQ"
HITS="$(gh pr list --repo "$REPO" --state open --limit "$LIMIT" \
        --json number,title,body \
        --jq "$(cat "$CLAIM_JQ")" 2>/dev/null)"
rm -f "$CLAIM_JQ"

if [[ -z "$HITS" ]]; then
  # Distinguir "no hay ninguno" de "gh fallo": se comprueba que la lista
  # de PRs se pudo leer.
  if ! gh pr list --repo "$REPO" --state open --limit 1 --json number >/dev/null 2>&1; then
    echo "VEREDICTO=ERROR no se pudo leer los PRs de $REPO (gh fallo?)" >&2
    exit 2
  fi
  echo "issue=$ISSUE PRs que lo mencionan: (ninguno)"
  if [[ -n "$OUR_PR" ]]; then
    echo "VEREDICTO=OK el claim es nuestro (PR #$OUR_PR, nadie mas lo menciona)"
  else
    echo "VEREDICTO=OK el issue esta libre (nadie lo menciona)"
  fi
  exit 0
fi

# El PR con el numero menor gana.
WINNER="$(printf '%s\n' "$HITS" | sort -n | head -1)"
echo "issue=$ISSUE PRs que lo mencionan: $(echo $HITS | tr '\n' ' ')(gana el $WINNER)"

if [[ -n "$OUR_PR" ]]; then
  if [[ "$WINNER" == "$OUR_PR" ]]; then
    echo "VEREDICTO=OK el claim es nuestro (PR #$OUR_PR)"
    exit 0
  fi
  echo "VEREDICTO=PERDIDO el PR #$OUR_PR perdio contra el #$WINNER"
  echo "  cerralo con: gh pr close $OUR_PR"
  echo "  libera el slot con: bash bin/slot-lock.sh --slot $ISSUE --release"
  exit 1
fi

# Sin nuestro PR: solo informa quien gana.
if [[ "$WINNER" -le 0 ]]; then
  echo "VEREDICTO=OK el issue esta libre (nadie lo menciona)"
  exit 0
fi
echo "VEREDICTO=OCUPADO el PR #$WINNER ya reclama #$ISSUE"
exit 1
