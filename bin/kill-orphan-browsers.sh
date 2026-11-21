#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# kill-orphan-browsers.sh - mata los navegadores del MCP de chrome-devtools
# que quedaron sin dueno.
#
# POR QUE EXISTE (2026-11-20): un agente que abre un navegador (el MCP de
# chrome-devtools) deja el Chrome vivo cuando su turno se corta: el proceso
# del MCP muere y el navegador queda huerfano, con 40 procesos y 3,7 GB de
# RAM en una caja de 15 GB. Dos veces se comio la memoria de la caja y el
# bucle dejo de despachar. El navegador de un MCP VIVO no se toca.
#
# EL INCIDENTE DEL 2026-11-21 (por que el script es como es): la primera
# version recorria la salida de `ps` con `for line in $(...)`, que corta por
# PALABRAS y no por lineas. Cada palabra (el pid, el PPID, los argumentos)
# terminaba en un `kill`. El PPID de un navegador huerfano, en un escritorio
# con systemd, es `systemd --user` (el subreaper de la sesion, no el pid 1):
# el reaper le mandaba SIGTERM y GNOME cerraba la sesion entera. Paso tres
# veces seguidas al correr bin/test-all.sh --fast. Por eso:
#   - la lista se lee LINEA por linea (`while read -r pid ppid uid args`);
#   - solo se mata el pid del navegador, nunca su padre ni otra cosa;
#   - antes de cada kill se vuelve a leer /proc/<pid> y se comprueba que
#     sigue siendo el MISMO navegador (el pid puede haberse reusado);
#   - nunca se mata el pid 1, este proceso, sus ancestros ni un systemd;
#   - con una lista de procesos de mentira (KOB_PS_FILE) NUNCA se mata nada:
#     es solo para los tests y fuerza --dry-run.
#
# QUE NAVEGADORES SON DEL MCP: chrome-devtools-mcp (1.12) lanza Chrome con
# Puppeteer y `pipe: true` (--remote-debugging-pipe) y un perfil propio:
#   ~/.cache/chrome-devtools-mcp/chrome-profile[-<canal>]   (el default)
#   ~/.cache/chrome-devtools-mcp-cli/chrome-profile[-<canal>]
#   /tmp/puppeteer_dev_chrome_profile-XXXXXX                 (--isolated)
# Se cuenta solo el proceso principal (sin --type=: los renderers, el gpu y
# el utility mueren con el). El Chrome del usuario no tiene ese perfil y no
# se toca nunca, aunque tenga --remote-debugging-port.
#
# COMO SE SABE QUE QUEDO HUERFANO: Puppeteer lanza el navegador como hijo
# directo del proceso del MCP. Si el MCP muere, el kernel se lo da al
# subreaper mas cercano (systemd --user en el escritorio) o al pid 1. Es
# huerfano si su padre es el pid 1, ya no existe, o es uno de los adoptantes
# (KOB_ADOPTERS, por defecto "systemd init"). Con cualquier otro padre vivo
# (el MCP, un script de Puppeteer) esta en uso y no se toca. Si otro
# subreaper lo adopta (un agente que se declara subreaper), no se mata: el
# reaper se equivoca hacia el lado seguro.
#
# USO:
#   bash bin/kill-orphan-browsers.sh               # mata los huerfanos
#   bash bin/kill-orphan-browsers.sh --dry-run     # dice cuales mataria
#   bash bin/kill-orphan-browsers.sh --match RE    # ademas, solo los que
#                                                  # coinciden con RE (tests)
#
# VARIABLES (para los tests):
#   KOB_PS_FILE   lista de procesos de mentira, una por linea:
#                 "<pid> <ppid> <uid> <args...>". Fuerza --dry-run.
#   KOB_UID       el uid cuyos navegadores se miran (default: el propio)
#   KOB_ADOPTERS  nombres de los procesos que adoptan huerfanos
#                 (default: "systemd init")
#
# SALIDA: una linea por navegador ("would-kill <pid>" o "killed <pid>") y un
# resumen. EXIT CODES:
#   0  todo bien (puede haber matado navegadores)
#   1  no se pudo leer la lista de procesos
#   2  uso incorrecto
# ---------------------------------------------------------------------------
set -uo pipefail

DRY=0
MATCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --match)
      [ $# -ge 2 ] || { echo "kill-orphan-browsers: --match necesita una regex" >&2; exit 2; }
      MATCH="$2"; shift ;;
    *) echo "kill-orphan-browsers: uso: [--dry-run] [--match REGEX]" >&2; exit 2 ;;
  esac
  shift
done

MY_UID="${KOB_UID:-$(id -u)}"
ADOPTERS=" ${KOB_ADOPTERS:-systemd init} "
# El proceso principal de un navegador del MCP: el canal de debugging y el
# perfil del MCP. Las regex son ERE (grep -E).
DEBUG_RE='--remote-debugging-(pipe|port=)'
PROFILE_RE='--user-data-dir=[^ ]*(/chrome-devtools-mcp(-cli)?/chrome-profile|/puppeteer_dev_chrome_profile-)'

if [ -n "${KOB_PS_FILE:-}" ]; then
  # Una lista de mentira nunca mata: sus pids no son los de esta maquina.
  DRY=1
  ps_out="$(cat -- "$KOB_PS_FILE" 2>/dev/null)" || { echo "kill-orphan-browsers: no se pudo leer $KOB_PS_FILE" >&2; exit 1; }
else
  ps_out="$(ps -eo pid=,ppid=,uid=,args= 2>/dev/null)" || { echo "kill-orphan-browsers: no se pudo leer la lista de procesos" >&2; exit 1; }
fi

# --- el indice de la lista: pid -> nombre del ejecutable -------------------
declare -A NAME_OF=()
while read -r pid ppid uid args; do
  [ -n "${pid:-}" ] || continue
  exe="${args%% *}"
  NAME_OF["$pid"]="${exe##*/}"
done <<< "$ps_out"

# --- los pids que nunca se tocan: el 1, este proceso y sus ancestros --------
declare -A PROTECTED=([0]=1 [1]=1)
a="$$"
while [ -n "$a" ] && [ "$a" != "0" ] && [ -z "${PROTECTED[$a]:-}" ]; do
  PROTECTED["$a"]=1
  a="$(awk '{print $4}' "/proc/$a/stat" 2>/dev/null)" || break
done

is_mcp_browser() {
  # is_mcp_browser <args>
  local args="$1"
  printf '%s\n' "$args" | grep -qE -- "$DEBUG_RE" || return 1
  printf '%s\n' "$args" | grep -qE -- "$PROFILE_RE" || return 1
  printf '%s\n' "$args" | grep -qE -- '--type=' && return 1
  if [ -n "$MATCH" ]; then
    printf '%s\n' "$args" | grep -qE -- "$MATCH" || return 1
  fi
  return 0
}

# still_same <pid> <ppid>: el pid sigue siendo un navegador del MCP, del
# usuario, con el mismo padre (el pid no se reuso desde que se leyo la lista).
still_same() {
  local pid="$1" ppid="$2" cmd stat_ppid owner
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || return 1
  [ -n "$cmd" ] || return 1
  is_mcp_browser "$cmd" || return 1
  stat_ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)" || return 1
  [ "$stat_ppid" = "$ppid" ] || return 1
  owner="$(stat -c %u "/proc/$pid" 2>/dev/null)" || return 1
  [ "$owner" = "$MY_UID" ] || return 1
  return 0
}

FOUND=0
KILLED=0
while read -r pid ppid uid args; do
  [ -n "${pid:-}" ] || continue
  # Solo numeros: una linea rota no se convierte en un kill.
  case "$pid$ppid$uid" in *[!0-9]*) continue ;; esac
  [ "$uid" = "$MY_UID" ] || continue
  [ -z "${PROTECTED[$pid]:-}" ] || continue
  [ "$pid" != "$ppid" ] || continue
  is_mcp_browser "$args" || continue
  # Un systemd o un init nunca es un navegador (cinturon y tirantes).
  case " ${NAME_OF[$pid]:-} " in " systemd "|" init ") continue ;; esac

  parent="${NAME_OF[$ppid]:-}"
  orphan=0
  if [ "$ppid" = "1" ] || [ -z "$parent" ]; then
    orphan=1
  else
    case "$ADOPTERS" in *" $parent "*) orphan=1 ;; esac
  fi
  [ "$orphan" -eq 1 ] || continue

  FOUND=$((FOUND + 1))
  if [ "$DRY" -eq 1 ]; then
    echo "would-kill $pid (padre $ppid ${parent:-ausente})"
    continue
  fi
  still_same "$pid" "$ppid" || continue
  kill -TERM "$pid" 2>/dev/null || continue
  # Chrome se cierra con SIGTERM; el que no, a los 5 s recibe SIGKILL, y
  # solo si sigue siendo el mismo navegador.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "/proc/$pid" ] || break
    sleep 0.5
  done
  if still_same "$pid" "$ppid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  KILLED=$((KILLED + 1))
  echo "killed $pid (padre $ppid ${parent:-ausente})"
done <<< "$ps_out"

if [ "$DRY" -eq 1 ]; then
  echo "kill-orphan-browsers: $FOUND navegador(es) huerfano(s)"
else
  echo "kill-orphan-browsers: $FOUND navegador(es) huerfano(s), $KILLED muerto(s)"
fi
exit 0
