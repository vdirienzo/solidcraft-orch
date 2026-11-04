#!/usr/bin/env bash
# ------------------------------------------------------------------
# experimento-paralelismo.sh (v2) - responde con numeros si conviene
# compilar de a 1 (16 jobs) o de a 2 (8+8), en serie o en paralelo.
#
# POR QUE LA v1 NO SIRVIO: el caso B (dos builds en paralelo) se cuelgo 3,5 h con los logs
# vacios. La causa probable: cada caso usaba su propio SCCACHE_DIR y el cliente del sccache
# se queda esperando el lock del server. Ademas los subshells anidados con cd y traps hacian
# el debug imposible.
#
# QUE CAMBIO EN LA v2:
#   - UN SOLO SCCACHE_DIR para toda la corrida (se mide con sccache --show-stats, que es
#     justamente el dato que interesa: cuantos hits da cada reparto)
#   - timeout 900 por build: un build colgado se corta solo
#   - sin subshells anidados ni traps: los dos builds del caso B se lanzan con & y wait
#   - el cache NO se borra entre casos: el caso C (serie) tiene que PEGAR en el cache del
#     primero, que es el efecto real de dos gates del mismo workspace
#
# LOS TRES CASOS (mismo crate, mismo perfil que los gates):
#   A UNO      : 1 build con 16 jobs
#   B PARALELO : 2 builds de 8 jobs a la vez, con el sccache COMPARTIDO
#   C SERIE    : 2 builds de 8 jobs, uno tras otro, con el sccache COMPARTIDO
#
# METRICA: builds por hora de cada reparto.
# ------------------------------------------------------------------
set -u
REPO=/home/user/solidcraft
CRATE_ARGS="-p solidcraft-sketch -p solidcraft-doc"
PROFILE=ci
T=/home/user/.hermes/cache/scratch/exp2
OUT=/home/user/.local/share/solidcraft-orch/reports/experimento-paralelismo.json
export SCCACHE_DIR="$T/sccache"
export CARGO_INCREMENTAL=0
export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
mkdir -p "$T" "$SCCACHE_DIR"
REPS=${REPS:-2}

log(){ echo "[$(date +%H:%M:%S)] $*"; }

# cache limpio por caso: sin esto, la repeticion 2 arranca con el cache caliente y el
# promedio de los tres casos deja de significar nada. El caso C comparte UN cache entre sus
# dos builds a proposito: ese es el efecto real de dos gates del mismo workspace.
cache_limpio(){
  export SCCACHE_DIR="$T/cache_$1"
  rm -rf "$SCCACHE_DIR"; mkdir -p "$SCCACHE_DIR"
}

hits(){ sccache --show-stats 2>/dev/null | awk -F: '/cache hit/{gsub(/[^0-9]/,"",$2); print $2+0}' | head -1; }

# la caja es compartida: si hay una compilacion de otro trabajo, se espera. Tres chequeos
# seguidos (60 s) antes de arrancar, para que un build que viene no contamine el caso.
caja_libre(){
  local libres=0 n=0
  while [ $n -lt 270 ]; do
    if ! pgrep -x cargo >/dev/null 2>&1 && ! pgrep -x rustc >/dev/null 2>&1; then
      libres=$((libres+1)); [ "$libres" -ge 3 ] && return 0
    else
      libres=0
    fi
    n=$((n+1)); sleep 20
  done
  return 1
}

build_sync(){   # $1=dir $2=jobs -> imprime "<segundos> <rc>"
  local dir="$1" jobs="$2"
  rm -rf "$dir"; mkdir -p "$dir"
  local t0 t1 rc
  t0=$(date +%s)
  ( cd "$REPO" && CARGO_TARGET_DIR="$dir" CARGO_BUILD_JOBS="$jobs" timeout 900 \
      nice -n 19 cargo build $CRATE_ARGS --profile "$PROFILE" -q ) > "$T/$(basename "$dir").log" 2>&1
  rc=$?
  t1=$(date +%s)
  echo "$((t1-t0)) $rc"
}

caso_a(){       # 1 build con 16 jobs
  cache_limpio A
  caja_libre
  local h0 h1 res
  h0=$(hits)
  res=$(build_sync "$T/A" 16)
  h1=$(hits)
  local seg=$(echo "$res" | awk '{print $1}')
  echo "$seg $(( ${h1:-0} - ${h0:-0} )) $(echo "$res" | awk '{print $2}')"
}

caso_b(){       # 2 builds de 8 jobs EN PARALELO
  cache_limpio B
  caja_libre
  local h0 h1 t0 t1 p1 p2
  h0=$(hits)
  rm -rf "$T/Ba" "$T/Bb"; mkdir -p "$T/Ba" "$T/Bb"
  t0=$(date +%s)
  ( cd "$REPO" && CARGO_TARGET_DIR="$T/Ba" CARGO_BUILD_JOBS=8 timeout 900 nice -n 19 \
      cargo build $CRATE_ARGS --profile "$PROFILE" -q ) > "$T/Ba.log" 2>&1 & p1=$!
  ( cd "$REPO" && CARGO_TARGET_DIR="$T/Bb" CARGO_BUILD_JOBS=8 timeout 900 nice -n 19 \
      cargo build $CRATE_ARGS --profile "$PROFILE" -q ) > "$T/Bb.log" 2>&1 & p2=$!
  wait $p1; wait $p2
  t1=$(date +%s)
  h1=$(hits)
  echo "$((t1-t0)) $(( ${h1:-0} - ${h0:-0} )) 0"
}

caso_c(){       # 2 builds de 8 jobs EN SERIE (el 2do pega en el cache del 1ro)
  cache_limpio C
  caja_libre
  local h0 h1 r1 r2 s1 s2
  h0=$(hits)
  r1=$(build_sync "$T/Ca" 8); s1=$(echo "$r1" | awk '{print $1}')
  r2=$(build_sync "$T/Cb" 8); s2=$(echo "$r2" | awk '{print $1}')
  h1=$(hits)
  echo "$((s1+s2)) $(( ${h1:-0} - ${h0:-0} )) $(echo "$r1" | awk '{print $2}')"
}

A=(); B=(); C=(); AH=(); BH=(); CH=()
for r in $(seq 1 "$REPS"); do
  log "CASO A (uno, 16 jobs) rep $r"
  res=$(caso_a); a=$(echo "$res"|awk '{print $1}'); ah=$(echo "$res"|awk '{print $2}'); rc=$(echo "$res"|awk '{print $3}')
  log "  A rep $r: ${a}s (cache hits +$ah) rc=$rc"; A+=("$a"); AH+=("$ah")
  log "CASO B (dos en paralelo, 8+8) rep $r"
  res=$(caso_b); b=$(echo "$res"|awk '{print $1}'); bh=$(echo "$res"|awk '{print $2}')
  log "  B rep $r: ${b}s (cache hits +$bh)"; B+=("$b"); BH+=("$bh")
  log "CASO C (dos en serie, 8+8, cache compartido) rep $r"
  res=$(caso_c); c=$(echo "$res"|awk '{print $1}'); ch=$(echo "$res"|awk '{print $2}')
  log "  C rep $r: ${c}s (cache hits +$ch)"; C+=("$c"); CH+=("$ch")
done

prom(){ printf '%s\n' "$@" | awk '{s+=$1;n++} END {if(n) printf "%.0f", s/n; else print 0}'; }
a_avg=$(prom "${A[@]}"); b_avg=$(prom "${B[@]}"); c_avg=$(prom "${C[@]}")
ah_avg=$(prom "${AH[@]}"); bh_avg=$(prom "${BH[@]}"); ch_avg=$(prom "${CH[@]}")
bph(){ awk -v t="$1" -v n="$2" 'BEGIN{if(t>0) printf "%.2f", 3600*n/t; else print 0}'; }
a_bph=$(bph "$a_avg" 1); b_bph=$(bph "$b_avg" 2); c_bph=$(bph "$c_avg" 2)

cat > "$OUT" <<JSON
{
  "fecha": "$(date -Iseconds)",
  "crate": "$CRATE_ARGS",
  "perfil": "$PROFILE",
  "reps": $REPS,
  "caso_A_uno_16jobs": {"segundos": ${A[@]:-0}, "promedio": $a_avg, "builds_por_hora": $a_bph, "cache_hits_promedio": $ah_avg},
  "caso_B_paralelo_8mas8": {"segundos": ${B[@]:-0}, "promedio": $b_avg, "builds_por_hora": $b_bph, "cache_hits_promedio": $bh_avg},
  "caso_C_serie_8mas8_cache_compartido": {"segundos": ${C[@]:-0}, "promedio": $c_avg, "builds_por_hora": $c_bph, "cache_hits_promedio": $ch_avg},
  "nota": "El caso C es el caso real de dos gates del mismo workspace: el 2do build pega en el sccache del 1ro. El caso B simula dos gates que compilan lo mismo a la vez: los dos compiten por el cache."
}
JSON
log "RESULTADO:"
log "  A uno 16 jobs      : ${a_avg}s por build    -> ${a_bph} builds/h (cache +$ah_avg)"
log "  B dos en paralelo  : ${b_avg}s por 2 builds -> ${b_bph} builds/h (cache +$bh_avg)"
log "  C dos en serie     : ${c_avg}s por 2 builds -> ${c_bph} builds/h (cache +$ch_avg)"
log "  escrito en $OUT"
