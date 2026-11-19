#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-cargo-jobs.sh - the number of jobs of a compilation has to follow the
# compilations that are running at the same time.
#
# WHY THIS EXISTS (2026-11-18): the count of the concurrent compilations was
# made with `pgrep -x cargo`, which matches the process NAME exactly. A clippy
# runs as `cargo-clippy` and a nextest as `cargo-nextest`: neither is called
# `cargo`, so the script counted ONE compilation while a clippy of seven
# packages was running, and asked for 16 jobs (the whole box). Its
# clippy-driver of solidcraft_engine reached 4.7 GB of RSS, the OOM killer
# took it, and with it the whole scope of the build that was next to it: a
# nextest of another slot died with exit 143 and no fault of its own.
#
# The rule this suite fixes: every cargo counts, whatever its name is.
# ---------------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CARGO_JOBS="$ORCH_DIR/bin/cargo-jobs.sh"

pass=0
fail=0

ok() { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; printf '         %s\n' "$2"; fail=$((fail + 1)); }

# A fake process table: the script counts with `ps -eo cmd=`, so the test
# puts its own ps in the PATH.
FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/cargo-jobs-test.XXXXXX")"
trap 'rm -rf "$FAKE_BIN"' EXIT

cat >"$FAKE_BIN/ps" <<'PSEOF'
#!/usr/bin/env bash
# The fake ps: it prints the table that the test put in PS_TABLE and ignores
# everything else.
if [ "${1:-}" = "-eo" ] && [ "${2:-}" = "cmd=" ]; then
  printf '%s\n' "$PS_TABLE"
  exit 0
fi
exec /usr/bin/ps "$@"
PSEOF
chmod +x "$FAKE_BIN/ps"

# The jobs that the script asks for with the given table.
jobs_with_table() {
  PS_TABLE="$1" PATH="$FAKE_BIN:$PATH" bash "$CARGO_JOBS" 2>/dev/null
}

# The number of compilations that the script counted with the given table.
conc_with_table() {
  PS_TABLE="$1" PATH="$FAKE_BIN:$PATH" bash "$CARGO_JOBS" --explain 2>/dev/null \
    | sed -n 's/.*concurrent_compilations=\([0-9]*\).*/\1/p'
}

# The cores of THIS machine. The rule is about the box: with one compilation
# it asks for the whole box, with two for half of it. The numbers were
# written for the orchestrator's 16 cores, and the suite failed on every
# other box (12 cores here, 2 on the runner of the CI).
CORES="$(nproc 2>/dev/null || echo 4)"

# The name of the real rustc of THIS machine: the rule counts a compilation by
# the name of its process, so the test has to exercise the name that the box
# really uses (a rustc in ~/.rustup/toolchains/<toolchain>/bin/rustc), not a
# made-up one in /usr/bin.
RUSTC_BIN="$(command -v rustc 2>/dev/null || echo /usr/bin/rustc)"

# The jobs the rule asks for with N compilations: CORES/N, at least 4 and
# never more than the box.
jobs_for() {
  local n="$1" j
  j=$(( CORES / n ))
  [ "$j" -lt 4 ] && j=4
  [ "$j" -gt "$CORES" ] && j="$CORES"
  printf '%s' "$j"
}

echo "== cada cargo cuenta, sea cual sea su nombre =="

# 1. A clippy IS a compilation (before the fix it was invisible).
out="$(conc_with_table 'timeout --kill-after=30 1080 cargo clippy -p solidcraft -p solidcraft-engine')"
if [ "$out" = "1" ]; then
  ok "un clippy cuenta como una compilación"
else
  bad "un clippy cuenta como una compilación" "esperado 1, obtenido ${out:-0}"
fi

# 2. A nextest IS a compilation.
out="$(conc_with_table '/usr/bin/cargo-nextest nextest run -p solidcraft-doc')"
if [ "$out" = "1" ]; then
  ok "un nextest cuenta como una compilación"
else
  bad "un nextest cuenta como una compilación" "esperado 1, obtenido ${out:-0}"
fi

# 3. A plain cargo IS a compilation.
out="$(conc_with_table '/usr/bin/cargo build -p solidcraft')"
if [ "$out" = "1" ]; then
  ok "un cargo cuenta como una compilación"
else
  bad "un cargo cuenta como una compilación" "esperado 1, obtenido ${out:-0}"
fi

echo
echo "== los jobs siguen a las compilaciones =="

# 4. One compilation: the whole box.
out="$(jobs_with_table '/usr/bin/cargo')"
want="$(jobs_for 1)"
if [ "$out" = "$want" ]; then
  ok "una compilación: todos los cores ($want)"
else
  bad "una compilación: todos los cores" "esperado $want, obtenido $out"
fi

# 5. Two compilations: half of the box.
out="$(jobs_with_table '/usr/bin/cargo
/usr/bin/cargo-nextest nextest run')"
want="$(jobs_for 2)"
if [ "$out" = "$want" ]; then
  ok "dos compilaciones: la mitad de los cores ($want)"
else
  bad "dos compilaciones: la mitad de los cores" "esperado $want, obtenido $out"
fi

# 6. Three compilations: a third of the box.
out="$(jobs_with_table '/usr/bin/cargo
/usr/bin/cargo-nextest nextest run
timeout --kill-after=30 1080 cargo clippy -p solidcraft')"
want="$(jobs_for 3)"
if [ "$out" = "$want" ]; then
  ok "tres compilaciones: un tercio de los cores ($want)"
else
  bad "tres compilaciones: un tercio de los cores" "esperado $want, obtenido $out"
fi

# 7. Many compilations: the floor of 4 jobs.
out="$(jobs_with_table '/usr/bin/cargo
/usr/bin/cargo
/usr/bin/cargo
/usr/bin/cargo
/usr/bin/cargo
/usr/bin/cargo
/usr/bin/cargo
/usr/bin/cargo')"
if [ "$out" = "4" ]; then
  ok "muchas compilaciones: el piso de 4 jobs se respeta"
else
  bad "muchas compilaciones: el piso de 4 jobs se respeta" "esperado 4, obtenido $out"
fi

echo
echo "== lo que NO es una compilación =="

# 8. The script itself is not counted (it would divide forever).
out="$(conc_with_table "bash $CARGO_JOBS
/usr/bin/cargo")"
if [ "$out" = "1" ]; then
  ok "el propio cargo-jobs.sh no cuenta como compilación"
else
  bad "el propio cargo-jobs.sh no cuenta como compilación" "esperado 1, obtenido ${out:-0}"
fi

# 9. An empty table: the compilation that is starting counts as one.
out="$(conc_with_table '')"
if [ "$out" = "1" ]; then
  ok "sin compilación visible: cuenta la que está empezando"
else
  bad "sin compilación visible: cuenta la que está empezando" "esperado 1, obtenido ${out:-0}"
fi

# 10. A rustc alone is not a compilation (it is the child of one).
out="$(conc_with_table "$RUSTC_BIN --crate-name solidcraft_engine")"
if [ "$out" = "1" ]; then
  ok "un rustc suelto no infla el conteo"
else
  bad "un rustc suelto no infla el conteo" "esperado 1, obtenido ${out:-0}"
fi

echo
echo "== el resumen =="
printf '%d ok, %d fallos\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
