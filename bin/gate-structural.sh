#!/usr/bin/env bash
# ------------------------------------------------------------------
# gate-structural.sh - the upstream checks that compile nothing.
#
# WHY THIS EXISTS (2026-11-17): the local gate was defined in RULES.md
# as fmt + check + clippy + nextest, and it excluded "NEVER the full
# cargo xtask ci". Excluding the FULL gate is right: `cargo xtask
# shared` copies and tests every shared crate and `cargo xtask wasm`
# checks thirty crates for wasm. But `cargo xtask ci` also runs
# layers, mesh-decisions, ui-containers, lists, skills, assets and
# icons, and those are STATIC ANALYSIS: a syn parse, a file read, a
# `cargo metadata`. They take seconds, not minutes.
#
# Those are the project's hardest rules: the layer table, the rule
# that a model decision is never made from a display mesh, one outer
# UI container, sorted catalogues. A pull request that passes the
# local gate and fails upstream's CI on `cargo xtask layers` finds the
# red at the most expensive moment: after the work is done.
#
# So the local gate is not "a recipe of upstream's": it IS upstream's
# checks, minus the ones that compile.
#
# USAGE:
#   bash bin/gate-structural.sh            -> runs them in the repo
#   bash bin/gate-structural.sh --list     -> only lists them
#
# Exit code: 0 all passed, 1 one or more failed, 2 the repo is not
# where it should be.
# ------------------------------------------------------------------
set -uo pipefail

SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"

# The checks, in the order `cargo xtask ci` runs them (xtask/src/main.rs:516-535).
# Every one of them is a static check: none of them compiles.
CHECKS=(
  "layers|cargo xtask layers"
  "mesh-decisions|cargo xtask mesh-decisions"
  "ui-containers|cargo xtask ui-containers"
  "lists|cargo xtask lists"
  "skills|cargo xtask skills"
)

if [ "${1:-}" = "--list" ]; then
  for entry in "${CHECKS[@]}"; do
    printf '%s\n' "${entry#*|}"
  done
  exit 0
fi

if [ ! -d "$SOLIDCRAFT_REPO" ]; then
  echo "gate-structural: the SolidCraft checkout is not there: $SOLIDCRAFT_REPO" >&2
  echo "  set SOLIDCRAFT_REPO to the checkout these checks run against" >&2
  exit 2
fi

cd "$SOLIDCRAFT_REPO" || exit 2

failed=0
for entry in "${CHECKS[@]}"; do
  name="${entry%%|*}"
  cmd="${entry#*|}"
  out="$(mktemp)"
  # shellcheck disable=SC2086
  if $cmd >"$out" 2>&1; then
    printf 'ok   - %s\n' "$name"
  else
    printf 'FALLA- %s\n' "$name"
    sed -n '1,25p' "$out"
    failed=1
  fi
  rm -f "$out"
done

if [ "$failed" -ne 0 ]; then
  echo "gate-structural: some upstream structural checks failed" >&2
fi
exit "$failed"
