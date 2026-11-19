#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-install-wave-cron.sh - the cron of the wave, installed como tiene que
# estar.
#
# QUE MIRA (todo SIN RED, todo en un directorio de prueba):
#   1. la copia del script del cron existe en $HERMES_SCRIPTS y es
#      BYTE-IDENTICA a bin/wave.sh (una copia vieja es un cron que corre
#      codigo viejo);
#   2. el job se registra con el nombre, la expresion y el modo que el
#      registro del repo exige (--no-agent: el cron no gasta tokens);
#   3. instalarlo dos veces NO duplica el job: el segundo paso lo EDITA;
#   4. --remove saca el job y borra la copia.
#
# EL HERMES DE MENTIRA: un stub en el PATH del test que anota lo que le
# piden. El hermes de verdad no se toca.
#
# Run: bash bin/test-install-wave-cron.sh
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FALLA- %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-install-wave-cron.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- el hermes de mentira ----------------------------------------------------
mkdir -p "$TMP/bin" "$TMP/scripts"
cat > "$TMP/bin/hermes" <<'STUB'
#!/usr/bin/env bash
# Un hermes que anota lo que le piden y dice que hay un job solo.
case "$1" in
  cron)
    case "$2" in
      list)
        # El listado de hermes es un bloque por job: la linea del id y, debajo,
        # las filas. El stub copia esa forma.
        if [ -f "$HERMES_FAKE_JOBS" ]; then
          while read -r id name; do
            [ -n "$id" ] || continue
            printf '  %s [active]\n' "$id"
            printf '    Name:        %s\n' "$name"
            printf '    Schedule:    */10 * * * *\n'
            printf '\n'
          done < "$HERMES_FAKE_JOBS"
        fi
        exit 0
        ;;
      create)
        printf 'create\t%s\n' "$*" >> "$HERMES_FAKE_LOG"
        printf 'a1b2c3d4\tsolidcraft-wave\n' >> "$HERMES_FAKE_JOBS"
        exit 0
        ;;
      edit)
        printf 'edit\t%s\n' "$*" >> "$HERMES_FAKE_LOG"
        exit 0
        ;;
      remove)
        printf 'remove\t%s\n' "$*" >> "$HERMES_FAKE_LOG"
        : > "$HERMES_FAKE_JOBS"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/hermes"
export PATH="$TMP/bin:$PATH"
export HERMES_FAKE_JOBS="$TMP/jobs.txt"
export HERMES_FAKE_LOG="$TMP/calls.log"
: > "$HERMES_FAKE_JOBS"
: > "$HERMES_FAKE_LOG"

export HERMES_SCRIPTS="$TMP/scripts"

# --- 1. la copia es byte-identica -------------------------------------------
bash "$REPO_ROOT/bin/install-wave-cron.sh" >/dev/null 2>&1
if [ -f "$HERMES_SCRIPTS/wave.sh" ]; then
  ok "la copia del script del cron existe"
else
  no "la copia del script del cron existe" "$HERMES_SCRIPTS"
fi
if diff -q "$REPO_ROOT/bin/wave.sh" "$HERMES_SCRIPTS/wave.sh" >/dev/null 2>&1; then
  ok "la copia es identica a bin/wave.sh"
else
  no "la copia es identica a bin/wave.sh"
fi

# --- 2. el job se registra como tiene que ser -------------------------------
CREATE="$(grep '^create' "$HERMES_FAKE_LOG" | head -1)"
case "$CREATE" in
  *"--name solidcraft-wave"*) ok "el job se llama solidcraft-wave" ;;
  *) no "el job se llama solidcraft-wave" "$CREATE" ;;
esac
case "$CREATE" in
  *"--no-agent"*) ok "el job corre sin agente (no gasta tokens)" ;;
  *) no "el job corre sin agente (no gasta tokens)" "$CREATE" ;;
esac
case "$CREATE" in
  *"--script wave.sh"*) ok "el job corre la copia del script" ;;
  *) no "el job corre la copia del script" "$CREATE" ;;
esac
case "$CREATE" in
  *"*/10 * * * *"*) ok "el job corre cada 10 minutos" ;;
  *) no "el job corre cada 10 minutos" "$CREATE" ;;
esac

# --- 3. instalar dos veces no duplica el job --------------------------------
bash "$REPO_ROOT/bin/install-wave-cron.sh" >/dev/null 2>&1
if [ "$(grep -c '^create' "$HERMES_FAKE_LOG")" = "1" ] && grep -q '^edit' "$HERMES_FAKE_LOG"; then
  ok "instalarlo otra vez EDITA el job y no lo duplica"
else
  no "instalarlo otra vez EDITA el job y no lo duplica" "$(cat "$HERMES_FAKE_LOG")"
fi

# --- 4. --remove lo saca ----------------------------------------------------
bash "$REPO_ROOT/bin/install-wave-cron.sh" --remove >/dev/null 2>&1
if grep -q '^remove' "$HERMES_FAKE_LOG" && [ ! -f "$HERMES_SCRIPTS/wave.sh" ]; then
  ok "--remove saca el job y borra la copia"
else
  no "--remove saca el job y borra la copia" "$(cat "$HERMES_FAKE_LOG")"
fi

printf '\n%d casos, %d fallan\n' "$((PASS + FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
