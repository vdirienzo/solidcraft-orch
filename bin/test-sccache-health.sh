#!/usr/bin/env bash
# test-sccache-health.sh - the cache's health says the right thing, and says
# it in the right way.
#
# POR QUE EXISTE: un hit rate de 0% tiene dos causas y dos acciones
# opuestas. El cache puede no tener nada que acertar (borrarlo) o puede ser
# DEMASIADO CHICO (su LRU se lleva justo lo que el proximo build necesita):
# el segundo caso se ve igual que el primero en `sccache --show-stats` y hace
# que cada gate pague el precio del build frio para siempre.
#
# El stub de sccache vive FUERA del PATH (README rule 4) y lo apunta la
# variable SCCACHE_BIN: el test nunca toca el cache de la maquina.
#
# Run: bash bin/test-sccache-health.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCCACHE_HEALTH_SH:-$HERE/sccache-health.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-sccache-health.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); [ $# -gt 1 ] && printf '       %s\n' "$2"; }

[ -f "$SRC" ] || { echo "no encuentro $SRC"; exit 1; }

# Un sccache de mentira que responde las stats que se le escriben.
STUB="$TMP/sccache"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat "$SCCACHE_FAKE_STATS"
STUBEOF
chmod +x "$STUB"

CACHE_DIR="$TMP/cache"
mkdir -p "$CACHE_DIR"

stats() { # stats <hits> <misses> <cache size> <max size>
  cat > "$TMP/stats.txt" <<EOF
Compile requests                    $(( $1 + $2 ))
Cache hits                         $1
Cache misses                       $2
Cache hit rate                     $(( $1 * 100 / ( $1 + $2 + 1 )))%
Cache size                         $3
Max cache size                     $4
EOF
}

run() { # run <hits> <misses> <size> <max>
  stats "$1" "$2" "$3" "$4"
  SCCACHE_BIN="$STUB" SCCACHE_CACHE_DIR="$CACHE_DIR" SCCACHE_FAKE_STATS="$TMP/stats.txt" \
    bash "$SRC" 2>&1
}

# 1) un cache al tope de su cap que no acierta nada: es DEMASIADO CHICO.
out="$(run 0 300 "10 GiB" "10 GiB")"; rc=$?
if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "too small"; then
  ok "un cache lleno que no acierta nada se dice demasiado chico (rc=1)"
else
  no "un cache lleno que no acierta nada se dice demasiado chico (rc=$rc)" "$out"
fi
if printf '%s' "$out" | grep -q "SCCACHE_MAX_CACHE_SIZE"; then
  ok "el veredicto dice como se agranda el cache"
else
  no "el veredicto dice como se agranda el cache" "$out"
fi

# 2) un cache con espacio de sobra que tampoco acierta: no esta ganando disco.
out="$(run 0 300 "3 GiB" "10 GiB")"; rc=$?
if [ "$rc" = "2" ] && printf '%s' "$out" | grep -q "not earning"; then
  ok "un cache con espacio que no acierta nada se dice que no gana disco (rc=2)"
else
  no "un cache con espacio que no acierta nada se dice que no gana disco (rc=$rc)" "$out"
fi

# 3) un cache que acierta: el cache esta trabajando.
out="$(run 270 30 "8 GiB" "10 GiB")"; rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "working"; then
  ok "un cache que acierta se dice que esta trabajando (rc=0)"
else
  no "un cache que acierta se dice que esta trabajando (rc=$rc)" "$out"
fi

# 4) un cache que no contesta: se dice, y el rc lo dice tambien.
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
out="$(SCCACHE_BIN="$STUB" SCCACHE_CACHE_DIR="$CACHE_DIR" bash "$SRC" 2>&1)"; rc=$?
if [ "$rc" = "3" ] && printf '%s' "$out" | grep -q "did not answer"; then
  ok "un sccache que no contesta se dice (rc=3)"
else
  no "un sccache que no contesta se dice (rc=$rc)" "$out"
fi

# 5) sin sccache: se dice (rc=3), no se inventa un veredicto.
out="$(SCCACHE_BIN="$TMP/no-existe-sccache" SCCACHE_CACHE_DIR="$CACHE_DIR" bash "$SRC" 2>&1)"; rc=$?
if [ "$rc" = "3" ] && printf '%s' "$out" | grep -q "is not there"; then
  ok "sin sccache se dice que no esta (rc=3)"
else
  no "sin sccache se dice que no esta (rc=3)" "$out"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
