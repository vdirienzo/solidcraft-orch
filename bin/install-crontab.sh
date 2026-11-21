#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-crontab.sh - the crons of the loop, in the crontab of the user.
#
# WHY (2026-11-21): the crons of the loop lived in hermes (`hermes cron create
# --script wave.sh --no-agent`), and hermes runs COPIES of the scripts in
# ~/.hermes/scripts. hermes is NOT installed on this machine: ~/.hermes does
# not exist, so there was NO cron at all. The wave did not run, the pipeline
# only ran while a session was alive, the gate queue never drained and the
# slots piled up (three slots "running" with no agent, 53 GB of worktrees and
# target dirs, a PR en draft sin veredicto del gate).
#
# The crontab of the user is the scheduler that DOES exist here (cron is
# active), and it has an advantage over the copies of hermes: the cron runs
# THE SCRIPT OF THE REPO, not a copy of it. A fix in bin/ reaches the cron at
# once. The failure mode of the copies was silent: the wave ran a week-old
# wave.sh (the one that did not push the branch of a dead slot to the fork) and
# the only warning was a line under a "todo lo necesario esta" that reads like
# an ok.
#
# WHAT IT INSTALLS: one job per line of bin/crons.txt (the register is the
# source of truth), with the schedule of the register, running the script of
# the repo. The block of the orchestrator is marked, so the installer can
# replace it without touching the other jobs of the user.
#
# USAGE:
#   bash bin/install-crontab.sh            # installs (idempotent)
#   bash bin/install-crontab.sh --dry-run  # says what it would do
#   bash bin/install-crontab.sh --remove   # takes the jobs away
#
# EXIT CODES:
#   0  the crontab is (or would be) as it should be
#   2  the register is not there, or crontab is not usable
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
REGISTER="${CRON_REGISTER:-$HERE/crons.txt}"
BEGIN="# >>> solidcraft-orch >>>"
END="# <<< solidcraft-orch <<<"

MODE="install"
case "${1:-}" in
  --dry-run) MODE="dry" ;;
  --remove) MODE="remove" ;;
  "") ;;
  *) echo "install-crontab: uso: --dry-run | --remove" >&2; exit 2 ;;
esac

[ -f "$REGISTER" ] || { echo "install-crontab: no esta el registro: $REGISTER" >&2; exit 2; }
command -v crontab >/dev/null 2>&1 || { echo "install-crontab: no hay crontab en esta maquina" >&2; exit 2; }

# --- el bloque del orquestador ------------------------------------------------
# EL PATH DEL CRON (2026-11-21): cron arranca los jobs con PATH=/usr/bin:/bin,
# y en esta maquina gh (~/.local/bin), opencode (~/.opencode/bin) y cargo
# (~/.cargo/bin) no estan ahi. Sin ellos claim-verify.sh respondia ERROR en
# cada pasada, prepare-slot no preparaba ningun slot, next-issue.py no veia
# ningun issue libre y la wave arrancaba CERO agentes, sin decir por que. El
# PATH del bloque se arma con los directorios donde ESTA maquina tiene esas
# herramientas al instalar, mas los del sistema.
cron_path() {
  local p="" dir tool
  for tool in gh opencode cargo python3 git; do
    dir="$(dirname "$(command -v "$tool" 2>/dev/null)" 2>/dev/null)"
    [ -n "$dir" ] && [ "$dir" != "." ] || continue
    case ":$p:" in *":$dir:"*) ;; *) p="${p:+$p:}$dir" ;; esac
  done
  for dir in "$HOME/.local/bin" "$HOME/.cargo/bin" /usr/local/bin /usr/bin /bin; do
    case ":$p:" in *":$dir:"*) ;; *) p="${p:+$p:}$dir" ;; esac
  done
  printf '%s' "$p"
}

# EL INTERPRETE SALE DE LA EXTENSION (2026-11-21): el bloque corria TODO con
# `bash <script>`, tambien los .py: pipeline.py, comment_watch.py,
# daily-report.py y loop-status.py fallaban en cada pasada con "import:
# command not found" (bash leyendo Python) y nadie lo veia.
interpreter_for() {
  case "$1" in
    *.py) printf 'python3' ;;
    *) printf 'bash' ;;
  esac
}

build_block() {
  printf '%s\n' "$BEGIN"
  printf '# Los crons del loop de SolidCraft. Generado por bin/install-crontab.sh;\n'
  printf '# el registro de verdad es bin/crons.txt. No editar a mano: el proximo\n'
  printf '# install-crontab.sh reescribe este bloque.\n'
  printf 'PATH=%s\n' "$(cron_path)"
  while IFS='|' read -r job schedule script node rest; do
    case "$job" in ''|\#*) continue ;; esac
    job="$(printf '%s' "$job" | tr -d '[:space:]')"
    # El horario SOLO se recorta de los bordes: los espacios del medio son los
    # que separan los cinco campos ("3,8,13 * * * *"), y quitarlos deja un
    # horario invalido que el cron no entiende (y no dice nada).
    schedule="$(printf '%s' "$schedule" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    script="$(printf '%s' "$script" | tr -d '[:space:]')"
    [ -n "$schedule" ] && [ -n "$script" ] || continue
    [ -f "$REPO_ROOT/$script" ] || { echo "install-crontab: el script del job $job no esta: $script" >&2; continue; }
    # El log de cada job: sin el, un cron que falla en silencio es un cron que
    # no existe (y el registro dice que existe).
    # El horario del registro ya tiene sus cinco campos: el cron no admite un
    # sexto (un campo de mas y el cron no dice nada: el job no existe).
    printf '%s cd %s && %s %s %s >> %s/logs/cron-%s.log 2>&1\n' \
      "$schedule" "$REPO_ROOT" "/usr/bin/env" "$(interpreter_for "$script")" "$script" "$REPO_ROOT" "$job"
  done < "$REGISTER"
  printf '%s\n' "$END"
}

CURRENT="$(crontab -l 2>/dev/null || true)"

# Lo que hay del orquestador, sin el bloque.
strip_block() {
  printf '%s\n' "$1" | awk -v b="$BEGIN" -v e="$END" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    !inblock { print }
  ' | sed '/^[[:space:]]*$/d'
}

if [ "$MODE" = "remove" ]; then
  NEW="$(strip_block "$CURRENT")"
  if [ "$NEW" = "$(printf '%s\n' "$CURRENT" | sed '/^[[:space:]]*$/d')" ]; then
    echo "install-crontab: no hay jobs del orquestador en el crontab"
    exit 0
  fi
  if [ "$MODE" = "dry" ]; then :; fi
  printf '%s\n' "$NEW" | crontab - 2>/dev/null || { echo "install-crontab: crontab - fallo" >&2; exit 2; }
  echo "install-crontab: los jobs del orquestador se sacaron del crontab"
  exit 0
fi

BLOCK="$(build_block)"
NEW="$(strip_block "$CURRENT")"
NEW="$(printf '%s\n%s\n' "$NEW" "$BLOCK" | sed '/^[[:space:]]*$/d')"

if [ "$MODE" = "dry" ]; then
  echo "install-crontab: (seco) el crontab quedaria:"
  printf '%s\n' "$BLOCK"
  exit 0
fi

printf '%s\n' "$NEW" | crontab - 2>/dev/null || { echo "install-crontab: crontab - fallo" >&2; exit 2; }

# El registro y el crontab tienen que decir lo mismo: un cron que corre y no
# esta en el registro no existe, y un cron del registro que no esta en el
# crontab es un trabajo que nadie hace.
INSTALLED="$(crontab -l 2>/dev/null | grep -c 'cd .*solidcraft-orch' || true)"
WANTED="$(grep -cE '^[[:space:]]*[^#[:space:]][^|]*\|' "$REGISTER" || true)"
echo "install-crontab: $INSTALLED job(s) en el crontab, $WANTED en el registro"
if [ "$INSTALLED" -lt "$WANTED" ]; then
  echo "install-crontab: FALTAN jobs (mira el log: el script de un job no esta en el repo)" >&2
  exit 2
fi
exit 0
