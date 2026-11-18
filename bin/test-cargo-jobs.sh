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

echo "== cada cargo cuenta, sea cual sea su nombre =="

# 1. A clippy IS a compilation (before the fix it was invisible).
out="$(conc_with_table 'timeout --kill-after=30 1080 cargo clippy -p solidcraft -p solidcraft-engine')"
if [ "$out" = "1" ]; then
  ok "un clippy cuenta como una compilación"
else
  bad "un clippy cuenta como una compilación" "esperado 1, obtenido ${out:-0}"
fi

# 2. A nextest IS a compilation.
out="$(conc_with_table '/home/user/.cargo/bin/cargo-nextest nextest run -p solidcraft-doc')"
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
if [ "$out" = "16" ]; then
  ok "una compilación: los 16 cores"
else
  bad "una compilación: los 16 cores" "esperado 16, obtenido $out"
fi

# 5. Two compilations: half of the box.
out="$(jobs_with_table '/usr/bin/cargo
/home/user/.cargo/bin/cargo-nextest nextest run')"
if [ "$out" = "8" ]; then
  ok "dos compilaciones: la mitad de los cores"
else
  bad "dos compilaciones: la mitad de los cores" "esperado 8, obtenido $out"
fi

# 6. Three compilations: a third of the box.
out="$(jobs_with_table '/usr/bin/cargo
/home/user/.cargo/bin/cargo-nextest nextest run
timeout --kill-after=30 1080 cargo clippy -p solidcraft')"
if [ "$out" = "5" ]; then
  ok "tres compilaciones: un tercio de los cores"
else
  bad "tres compilaciones: un tercio de los cores" "esperado 5, obtenido $out"
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
out="$(conc_with_table 'bash /home/user/.local/share/solidcraft-orch/bin/cargo-jobs.sh
/usr/bin/cargo')"
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
out="$(conc_with_table '/home/user/.rustup/toolchains/1.99.1-x86_64-unknown-linux-gnu/bin/rustc --crate-name solidcraft_engine')"
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
