#!/usr/bin/env bash
# ------------------------------------------------------------------
# experimento-paralelismo.sh - responde con numeros si conviene compilar
# de a 1 (16 jobs) o de a 2 (8+8 jobs), en serie o en paralelo.
#
# POR QUE: la pregunta de fondo es "20 issues en serie con toda la CPU, o de a 2 a la vez".
# El dato que falta es empirico: cuanto rinde cada reparto.
#
# LOS TRES CASOS, con el MISMO crate (solidcraft-sketch + solidcraft-doc, puros: no
# dependen de solidcore, asi que no se mide el git-dep) y el perfil que usan los gates (ci):
#
#   A  UNO   : 1 build con 16 jobs           -> mide t16
#   B  PAR   : 2 builds de 8 jobs a la vez   -> mide t8 en paralelo (comparten el sccache:
#                                                el 2no compila lo mismo y NO pega)
#   C  SERIE : 2 builds de 8 jobs, uno tras otro, COMPARTIENDO el sccache -> el 2do pega
#
# En A y B el cache esta limpio en cada repeticion (SCCACHE_DIR por repeticion). En C el
# cache es el MISMO para los dos builds a proposito: asi se mide el efecto real, que es el
# del gate que compila dos veces el mismo workspace.
#
# La metrica que sale: BUILDS POR HORA de cada reparto.
# ------------------------------------------------------------------
set -u
CRATE_ARGS="-p solidcraft-sketch -p solidcraft-doc"
PROFILE=ci
REPO=/home/user/solidcraft
T=/home/user/.hermes/cache/scratch/exp-paralelismo
OUT=/home/user/.local/share/solidcraft-orch/reports/experimento-paralelismo.json
mkdir -p "$T" "$(dirname "$OUT")"

log(){ echo "[$(date +%H:%M:%S)] $*"; }

# la caja es compartida: si hay una compilacion de otro trabajo, se espera.
# (un experimento medido sobre una caja ocupada no sirve)
# 2026-11-04: la primera corrida se arruino porque los dos agentes de los fixes empezaron a
# compilar en el medio del caso A. Por eso ahora la caja tiene que estar libre en TRES
# chequeos seguidos (60 s) antes de arrancar, y ademas se mide la carga durante cada caso:
# un caso con el loadavg por encima de lo que el caso puede explicar esta CONTAMINADO y
# se descarta. Sin eso, el numero es una mezcla del reparto y de la competicion.
LIBRES_SEGUIDOS=0
caja_libre(){
  local n=0
  LIBRES_SEGUIDOS=0
  while [ $n -lt 540 ]; do
    if ! pgrep -x cargo >/dev/null 2>&1 && ! pgrep -x rustc >/dev/null 2>&1; then
      LIBRES_SEGUIDOS=$((LIBRES_SEGUIDOS+1))
      [ "$LIBRES_SEGUIDOS" -ge 3 ] && return 0
    else
      LIBRES_SEGUIDOS=0
    fi
    n=$((n+1)); sleep 20
  done
  return 1
}

# el loadavg maximo durante un comando: si supera lo que el caso puede explicar, hay
# competencia de otro trabajo y el caso no sirve.
LOADMAX=0
medir_carga(){
  LOADMAX=0
  ( while [ -f "$T/cargando" ]; do
      l=$(awk '{print $1}' /proc/loadavg)
      awk -v a="$l" -v b="$LOADMAX" 'BEGIN{exit !(a+0>b+0)}' && LOADMAX="$l"
      sleep 5
    done ) &
  MEDIR_PID=$!
}
fin_carga(){ rm -f "$T/cargando"; [ -n "${MEDIR_PID:-}" ] && kill "$MEDIR_PID" 2>/dev/null; wait 2>/dev/null; true; }

# un caso esta contaminado si el loadavg supero el techo del caso
contaminado(){
  local techo="$1"
  awk -v m="$LOADMAX" -v t="$techo" 'BEGIN{exit !(m+0 > t+0)}'
}

build(){
  local dir="$1" jobs="$2" cache="$3"
  mkdir -p "$dir" "$cache"
  local t0 t1
  t0=$(date +%s)
  cd "$REPO" || return 1
  CARGO_TARGET_DIR="$dir" CARGO_BUILD_JOBS="$jobs" CARGO_INCREMENTAL=0 \
  SCCACHE_DIR="$cache" RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}" \
    nice -n 19 cargo build $CRATE_ARGS --profile "$PROFILE" -q \
    > "$T/build-$(basename "$dir").log" 2>&1
  local rc=$?
  t1=$(date +%s)
  echo $((t1-t0)) "$rc"
}

run_case_uno(){   # 1 build, 16 jobs
  local rep=$1
  local d="$T/A$rep"; local c="$T/cacheA$rep"
  rm -rf "$d" "$c"
  caja_libre
  touch "$T/cargando"; medir_carga
  local res; res=$(build "$d" 16 "$c")
  fin_carga
  local seg=$(echo "$res" | awk '{print $1}')
  local cont=0; contaminado 20 && cont=1
  echo "$seg $cont"
}
run_case_par(){   # 2 builds de 8 jobs EN PARALELO, cache compartido
  local rep=$1
  local da="$T/B${rep}a" db="$T/B${rep}b"; local c="$T/cacheB$rep"
  rm -rf "$da" "$db" "$c"
  caja_libre
  local t0 t1
  cd "$REPO" || return 1
  t0=$(date +%s)
  touch "$T/cargando"; medir_carga
  ( build "$da" 8 "$c" > "$T/B${rep}a.res" ) &
  ( build "$db" 8 "$c" > "$T/B${rep}b.res" ) &
  wait
  fin_carga
  t1=$(date +%s)
  CONTAMINADO=0; contaminado 20 && CONTAMINADO=1
  echo "$((t1-t0)) $CONTAMINADO"
}
run_case_serie(){ # 2 builds de 8 jobs EN SERIE, cache compartido
  local rep=$1
  local da="$T/C${rep}a" db="$T/C${rep}b"; local c="$T/cacheC$rep"
  rm -rf "$da" "$db" "$c"
  caja_libre
  local t0 t1
  cd "$REPO" || return 1
  t0=$(date +%s)
  touch "$T/cargando"; medir_carga
  build "$da" 8 "$c" > "$T/C${rep}a.res"
  build "$db" 8 "$c" > "$T/C${rep}b.res"
  fin_carga
  t1=$(date +%s)
  CONTAMINADO=0; contaminado 11 && CONTAMINADO=1
  echo "$((t1-t0)) $CONTAMINADO"
}

REPS=${REPS:-2}
log "experimento: $REPS repeticiones de cada caso (crate: $CRATE_ARGS, perfil: $PROFILE)"

A=(); B=(); C=(); DESCARTADOS=0
for r in $(seq 1 "$REPS"); do
  log "CASO A (uno, 16 jobs) repeticion $r"
  res=$(run_case_uno "$r"); a=$(echo "$res" | awk '{print $1}'); f=$(echo "$res" | awk '{print $2}')
  if [ "${f:-1}" = "0" ]; then A+=("$a"); log "  A rep $r: ${a}s (limpio)"; else DESCARTADOS=$((DESCARTADOS+1)); log "  A rep $r: ${a}s CONTAMINADO -> descartado"; fi
  log "CASO B (dos en paralelo, 8+8) repeticion $r"
  res=$(run_case_par "$r"); b=$(echo "$res" | awk '{print $1}'); f=$(echo "$res" | awk '{print $2}')
  if [ "${f:-1}" = "0" ]; then B+=("$b"); log "  B rep $r: ${b}s (limpio)"; else DESCARTADOS=$((DESCARTADOS+1)); log "  B rep $r: ${b}s CONTAMINADO -> descartado"; fi
  log "CASO C (dos en serie, 8+8, cache compartido) repeticion $r"
  res=$(run_case_serie "$r"); c=$(echo "$res" | awk '{print $1}'); f=$(echo "$res" | awk '{print $2}')
  if [ "${f:-1}" = "0" ]; then C+=("$c"); log "  C rep $r: ${c}s (limpio)"; else DESCARTADOS=$((DESCARTATES+1)); log "  C rep $r: ${c}s CONTAMINADO -> descartado"; fi
done

prom(){ printf '%s\n' "$@" | awk '{s+=$1; n++} END {if(n) printf "%.0f", s/n; else print 0}'; }
a_avg=$(prom "${A[@]}"); b_avg=$(prom "${B[@]}"); c_avg=$(prom "${C[@]}")
# builds por hora
bph(){ awk -v t="$1" -v n="$2" 'BEGIN { if (t>0) printf "%.2f", 3600*n/t; else print 0 }'; }
a_bph=$(bph "$a_avg" 1); b_bph=$(bph "$b_avg" 2); c_bph=$(bph "$c_avg" 2)

cat > "$OUT" <<JSON
{
  "fecha": "$(date -Iseconds)",
  "crate": "$CRATE_ARGS",
  "perfil": "$PROFILE",
  "reps": $REPS,
  "descartados_por_contaminacion": $DESCARTADOS,
  "caso_A_uno_16jobs": {"segundos": ${A[@]:-0}, "promedio": $a_avg, "builds_por_hora": $a_bph},
  "caso_B_par_8mas8": {"segundos": ${B[@]:-0}, "promedio": $b_avg, "builds_por_hora": $b_bph},
  "caso_C_serie_8mas8_cache_compartido": {"segundos": ${C[@]:-0}, "promedio": $c_avg, "builds_por_hora": $c_bph},
  "lectura": "El caso C incluye el efecto del sccache: el 2do build del MISMO crate pega en el cache. El caso B simula la realidad de dos gates del mismo workspace compitiendo."
}
JSON
log "RESULTADO:"
log "  A uno 16 jobs : ${a_avg}s por build   -> ${a_bph} builds/h"
log "  B dos en paralelo : ${b_avg}s por 2 builds -> ${b_bph} builds/h"
log "  C dos en serie    : ${c_avg}s por 2 builds -> ${c_bph} builds/h"
log "  escrito en $OUT"
