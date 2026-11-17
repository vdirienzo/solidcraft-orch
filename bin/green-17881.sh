#!/usr/bin/env bash
# Verifica el GREEN de 17881 sobre el rebase (cb8360621) y pushea al fork.
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

cd "$W"
echo "=== GREEN sobre el rebase ==="
timeout 2400 cargo test -p solidcraft-ui-egui --lib "$TEST_NAME" -- --nocapture \
  > "$LOGS/17881-GREEN.log" 2>&1
GR=$?
echo "GREEN rc=$GR"
grep -E 'test result|panicked' "$LOGS/17881-GREEN.log" | head -3

echo "=== modulo completo del area ==="
timeout 2400 cargo test -p solidcraft-ui-egui --lib view_home > "$LOGS/17881-MODULE.log" 2>&1
echo "modulo rc=$?"
grep -E 'test result' "$LOGS/17881-MODULE.log" | head -2

echo "=== fmt y clippy ==="
cargo fmt --all > "$LOGS/17881-fmt.log" 2>&1; echo "fmt rc=$?"
timeout 2400 cargo clippy -p solidcraft-ui-egui --all-targets -- -D warnings > "$LOGS/17881-clippy.log" 2>&1
echo "clippy rc=$?"
grep -E '^(error|warning)' "$LOGS/17881-clippy.log" | head -5

echo "=== push SOLO al fork ==="
git -C "$W" push -f fork HEAD:refs/heads/fix/issue-17881-home-occluding-panels 2>&1 | tail -2
git -C "$W" push -f fork HEAD:refs/heads/wip/issue-17881-home 2>&1 | tail -2
git ls-remote fork 'refs/heads/*issue-17881*'
echo "HEAD=$(git -C "$W" rev-parse HEAD)"
echo "=== FIN ==="
