#!/usr/bin/env bash
# RED corregido del slot 17881.
#
# ERROR DEL PRIMER INTENTO (medido): el script tomo FIX=HEAD (el commit del TEST,
# despues del rebase) y PARENT=HEAD^ (el commit del FIX): al "revertir" dejaba
# el fix PUESTO, asi que el test pasaba y el RED no era RED. La forma correcta:
# el commit del FIX es HEAD^ y su padre (sin el fix) es HEAD^^.
#
# Se restaura SOLO crates/ui-egui/src/shell.rs y crates/ui-egui/src/viewport.rs
# desde HEAD^^, dejando el test (en view_home_tests.rs) como esta: el test corre
# contra el codigo sin el fix y debe FALLAR.
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-${ORCH_DIR}}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-${SOLIDCRAFT_REPO}}"
WORKTREES_DIR="${WORKTREES_DIR:-${WORKTREES_DIR}}"
W=${WORKTREES_DIR}/issue-17881
LOGS=${ORCH_DIR}/logs
export PATH="${HOME}/.cargo/bin:${HOME}/.rustup/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export CARGO_TARGET_DIR="$(bash ${ORCH_DIR}/bin/slot-target-dir.sh --slot 17881)"
export CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0
TEST_NAME=home_frames_the_part_in_the_area_the_panels_leave_free

FIX_COMMIT=$(git -C "$W" rev-parse HEAD^)      # el commit del fix
NO_FIX=$(git -C "$W" rev-parse HEAD^^)         # el padre: el codigo sin el fix
echo "commit del fix:   $FIX_COMMIT"
echo "commit sin fix:   $NO_FIX"
echo "diff del fix:"; git -C "$W" show --stat "$FIX_COMMIT" | tail -4

echo "=== RED: se revierte el fix, el test queda ==="
git -C "$W" checkout "$NO_FIX" -- crates/ui-egui/src/shell.rs crates/ui-egui/src/viewport.rs
cd "$W"
git diff --stat
timeout 2400 cargo test -p solidcraft-ui-egui --lib "$TEST_NAME" -- --nocapture \
  > "$LOGS/17881-RED.log" 2>&1
RED_RC=$?
echo "RED rc=$RED_RC (1 = falla como debe; 0 = el test NO discrimina)"
grep -E 'test result|panicked at|assertion|Home puts the part' "$LOGS/17881-RED.log" | head -8

echo "=== GREEN: el fix vuelve ==="
git -C "$W" checkout "$FIX_COMMIT" -- crates/ui-egui/src/shell.rs crates/ui-egui/src/viewport.rs
timeout 2400 cargo test -p solidcraft-ui-egui --lib "$TEST_NAME" -- --nocapture \
  > "$LOGS/17881-GREEN.log" 2>&1
GREEN_RC=$?
echo "GREEN rc=$GREEN_RC (0 = pasa)"
grep -E 'test result' "$LOGS/17881-GREEN.log" | head -3

echo "=== estado final del worktree ==="
git -C "$W" status --porcelain | head -5
git -C "$W" log --oneline -2
echo "=== FIN (RED rc=$RED_RC GREEN rc=$GREEN_RC) ==="
