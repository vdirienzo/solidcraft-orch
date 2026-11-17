#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-all.sh - one command, every suite, and a verdict that is honest.
#
# WHY THIS EXISTS (2026-11-17): README.md:280 says "las suites de
# bin/test-*.sh y bin/test-rules.py tienen que dar rc=0 antes de
# commitear cualquier cambio del orquestador" - and nothing ran them.
# There was no runner and no CI, so the rule was kept in the head and
# the head was not there. Two of the sixteen suites also could not run
# on a clean clone at all: test-slot-parallelism.sh tested the
# DEPLOYED copy under $HOME, and test-state-split.sh read the real
# state.json. A suite that cannot run is not a pass.
#
# So: every suite runs, a suite that cannot run is reported as a
# FAILURE, and the exit code is the aggregate. Never a "skip" that
# reads like a green.
#
# USAGE:
#   bash bin/test-all.sh              -> runs every suite
#   bash bin/test-all.sh --fast       -> only the fast ones (see below)
#   bash bin/test-all.sh <pattern>    -> only the suites whose name matches
#
# Exit code: 0 every suite passed, 1 at least one failed or could not
# run.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE"

pattern=""
fast=0
for arg in "$@"; do
  case "$arg" in
    --fast) fast=1 ;;
    *) pattern="$arg" ;;
  esac
done

# The suites that need a working checkout of SolidCraft, a deploy
# directory or the loop's scripts do not run anywhere else. They are
# skipped by --fast and reported as failures otherwise.
HEAVY="test-slot-parallelism.sh test-deploy-drift.sh test-publish-pr.sh test-state-split.sh test-briefs.sh"

suites=()
while IFS= read -r f; do
  name="$(basename "$f")"
  # This runner is not a suite: it would run itself.
  [ "$name" = "test-all.sh" ] && continue
  [ -n "$pattern" ] && case "$name" in *"$pattern"*) ;; *) continue ;; esac
  suites+=("$name")
done < <(ls -1 "$BIN"/test-*.sh "$BIN"/test-*.py 2>/dev/null | sort -u)

if [ "${#suites[@]}" -eq 0 ]; then
  echo "test-all: no hay suites que coincidan con '${pattern}'" >&2
  exit 1
fi

passed=0
failed=0
failed_names=""
skipped=0

for name in "${suites[@]}"; do
  is_heavy=0
  for h in $HEAVY; do
    [ "$name" = "$h" ] && is_heavy=1
  done
  if [ "$fast" -eq 1 ] && [ "$is_heavy" -eq 1 ]; then
    printf 'SKIP- %s (pesada: necesita la maquina del orquestador)\n' "$name"
    skipped=$((skipped + 1))
    continue
  fi

  printf '\n=== %s ===\n' "$name"
  out="$(mktemp)"
  case "$name" in
    *.py) python3 "$BIN/$name" >"$out" 2>&1 ;;
    *) bash "$BIN/$name" >"$out" 2>&1 ;;
  esac
  rc=$?
  # The tail is what the reader needs; the whole output is in the file.
  tail -n 12 "$out"
  if [ "$rc" -eq 0 ]; then
    printf 'ok   - %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FALLA- %s (rc=%s)\n' "$name" "$rc"
    failed=$((failed + 1))
    failed_names="$failed_names $name"
  fi
  rm -f "$out"
done

printf '\n=== resumen ===\n'
printf '%d pasaron, %d fallaron, %d saltadas\n' "$passed" "$failed" "$skipped"
if [ "$failed" -ne 0 ]; then
  echo "fallaron:$failed_names"
  exit 1
fi
exit 0
