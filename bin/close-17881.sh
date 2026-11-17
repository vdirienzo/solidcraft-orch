#!/usr/bin/env bash
# Cierra el slot 17881: RED -> GREEN -> commit -> rebase -> push al fork.
# El fix ya esta commiteado (0b3ca9ce9); el test RED quedo escrito y sin commitear.
# El RED se hace revirtiendo SOLO shell.rs y viewport.rs al padre del fix, dejando
# el test: con el fix el modelo cae en el centro del area libre (0 px de distancia),
# sin el fix cae 58 px del centro (medido por el agente).
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-${ORCH_DIR}}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-${SOLIDCRAFT_REPO}}"
WORKTREES_DIR="${WORKTREES_DIR:-${WORKTREES_DIR}}"
W=${WORKTREES_DIR}/issue-17881
LOGS=${ORCH_DIR}/logs
# El servicio systemd no hereda el PATH del shell de Hermes: sin esto cargo
# no se encuentra y todos los comandos salen con rc=127.
export PATH="${HOME}/.cargo/bin:${HOME}/.rustup/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export CARGO_TARGET_DIR="$(bash ${ORCH_DIR}/bin/slot-target-dir.sh --slot 17881)"
export CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0
TEST_NAME=home_frames_the_part_in_the_area_the_panels_leave_free
FIX=0b3ca9ce9
PARENT=$(git -C "$W" rev-parse "$FIX^")

echo "=== 0. rebase lineal del fix sobre origin/main ==="
cd ${SOLIDCRAFT_REPO} && git fetch origin --quiet
git -C "$W" rebase origin/main > "$LOGS/17881-rebase.log" 2>&1
if [ $? -ne 0 ]; then
  echo "REBASE CON CONFLICTO: se aborta y se sigue con la base vieja"
  git -C "$W" rebase --abort >> "$LOGS/17881-rebase.log" 2>&1
else
  echo "rebase limpio -> $(git -C "$W" rev-parse HEAD)"
  FIX=$(git -C "$W" rev-parse HEAD)
  PARENT=$(git -C "$W" rev-parse "$FIX^")
fi

echo "=== 1. RED: solo el test, sin el fix ==="
git -C "$W" checkout "$PARENT" -- crates/ui-egui/src/shell.rs crates/ui-egui/src/viewport.rs
cd "$W"
timeout 2400 cargo test -p solidcraft-ui-egui --lib "$TEST_NAME" -- --nocapture \
  > "$LOGS/17881-RED.log" 2>&1
RED_RC=$?
echo "RED rc=$RED_RC (1 = el test falla como debe)"
grep -E 'test result|panicked at|assertion' "$LOGS/17881-RED.log" | head -6

echo "=== 2. GREEN: el fix de vuelta ==="
git -C "$W" checkout "$FIX" -- crates/ui-egui/src/shell.rs crates/ui-egui/src/viewport.rs
timeout 2400 cargo test -p solidcraft-ui-egui --lib "$TEST_NAME" -- --nocapture \
  > "$LOGS/17881-GREEN.log" 2>&1
GREEN_RC=$?
echo "GREEN rc=$GREEN_RC (0 = pasa)"
grep -E 'test result|panicked at' "$LOGS/17881-GREEN.log" | head -4

echo "=== 3. modulo completo del area ==="
timeout 2400 cargo test -p solidcraft-ui-egui --lib view_home > "$LOGS/17881-MODULE.log" 2>&1
echo "modulo rc=$?"
grep -E 'test result' "$LOGS/17881-MODULE.log" | head -3

echo "=== 4. fmt y clippy ==="
cargo fmt --all > "$LOGS/17881-fmt.log" 2>&1; echo "fmt rc=$?"
timeout 2400 cargo clippy -p solidcraft-ui-egui --all-targets -- -D warnings > "$LOGS/17881-clippy.log" 2>&1
echo "clippy rc=$?"
grep -E '^(error|warning)' "$LOGS/17881-clippy.log" | head -5

echo "=== 5. commit del test ==="
git -C "$W" add crates/ui-egui/src/view_home_tests.rs
git -C "$W" -c user.email=agent@solidcraft.local -c user.name=solidcraft-agent commit -q \
  -m "UI: a regression test for Home framing the part in the free area (#17881)" 2>&1 | tail -2
git -C "$W" log --oneline -2

echo "=== 6. push SOLO al fork ==="
git -C "$W" push -f fork HEAD:refs/heads/wip/issue-17881-home 2>&1 | tail -2
git -C "$W" push -f fork HEAD:refs/heads/fix/issue-17881-home-occluding-panels 2>&1 | tail -2
git ls-remote fork 'refs/heads/*issue-17881*'
echo "=== FIN 17881 (RED rc=$RED_RC GREEN rc=$GREEN_RC) ==="
