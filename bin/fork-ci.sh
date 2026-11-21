#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fork-ci.sh - el CI de upstream, corrido en el fork, como gate de un PR.
#
# POR QUE EXISTE (2026-11-21): el gate local (bin/gate.sh -> gate-quick.sh)
# dio un ROJO FALSO en el PR #20017 mientras el "Native Linux tests" de
# upstream pasaba sobre el mismo head, y compilaba 30+ minutos llenando los
# 15 GB de la caja. El CONTRIBUTING de upstream (seccion "Sending a change",
# punto 3) dice como ver el CI completo sin esperar el label approved-for-ci:
# con las variables CI_RUNNER=ubuntu-24.04 y CI_RUNNER_WINDOWS=windows-latest
# en el fork,
#   gh workflow run ci.yml --ref <rama> -f cross_compile=true -R <fork>
# corre en los runners gratis de GitHub los jobs del merge queue (con el
# triple de tiempo por job). Un push a una rama que no es main NO lo arranca
# (ci.yml solo escucha push a main y develop): hay que despacharlo.
#
# USO:
#   bash bin/fork-ci.sh <issue|rama> [--sha SHA] [--force] [--no-cross]
#       despacha ci.yml en el fork para la rama del PR (la del issue, o la
#       rama dada). UNA vez por sha: un sha que ya tiene un run (en vuelo o
#       terminado) no se despacha otra vez sin --force, y la rama del fork
#       tiene que estar en ese sha (el run prueba la punta de la rama).
#   bash bin/fork-ci.sh <issue|rama> --status [--sha SHA]
#   bash bin/fork-ci.sh --status --sha SHA
#       una linea:
#         FORKCI=VERDE|ROJO|PENDIENTE|NINGUNO SHA=<sha> RUN=<url> FALLAN=<jobs>
#       (FALLAN va al final: los nombres de los jobs llevan espacios; van
#       separados por comas). El detalle va a stderr.
#
# LA REGLA DEL VEREDICTO es la de pipeline.evaluar_check_runs: de cada nombre
# de job manda el mas reciente, entre todos los runs despachados del sha. La
# logica vive en bin/pipeline.py (una sola implementacion para el pipeline,
# este script y bin/verify-pr.sh): este archivo es la puerta.
#
# CODIGOS DE SALIDA:
#   --status:   0 VERDE, 1 ROJO, 2 PENDIENTE, 3 NINGUNO (no hay run),
#               4 no hay PR o rama que mirar, 6 no se pudo leer (DESCONOCIDO)
#   despacho:   0 despachado, o el sha ya tenia run / despacho reciente
#               1 el despacho fallo, o GitHub lo rechazo hace menos de
#                 FORK_CI_ERROR_BACKOFF_S (3600 s) y no se reintenta sin --force
#                 (el 2026-11-21 el fork respondia "HTTP 422: Actions has been
#                 disabled for this repository": reintentarlo cada 5 minutos
#                 dejaba el cron rojo para siempre)
#               4 la rama del fork no existe o no esta en ese sha
#               5 ya hay FORK_CI_MAX_INFLIGHT runs en vuelo: despues
#               6 no se pudo leer GitHub
#   64          uso incorrecto
#
# ENTORNO: GH_BIN (el gh; un test lo apunta a un stub FUERA del PATH),
# ORCH_DIR (las marcas de despacho y la cache de jobs: $ORCH_DIR/gates/fork-ci/),
# FORK_CI_CROSS=0 (sin cross_compile), FORK_CI_MAX_INFLIGHT (2),
# FORK_CI_GRACE_S (900), FORK_CI_CANCEL_STALE=0 (no cancela el run viejo de
# la misma rama).
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
export ORCH_DIR LOOP_DIR
# El gh de la caja esta en ~/.local/bin, que un cron no tiene en el PATH.
if [ -z "${GH_BIN:-}" ] && ! command -v gh >/dev/null 2>&1 && [ -x "$HOME/.local/bin/gh" ]; then
  export GH_BIN="$HOME/.local/bin/gh"
fi

[ -f "$HERE/pipeline.py" ] || { echo "fork-ci: no encuentro $HERE/pipeline.py" >&2; exit 64; }

exec python3 - "$HERE" "$@" <<'PY'
import sys
here = sys.argv[1]
sys.path.insert(0, here)
import pipeline  # noqa: E402  (la logica del CI del fork vive en pipeline.py)
sys.exit(pipeline.fork_ci_cli(sys.argv[2:]))
PY
