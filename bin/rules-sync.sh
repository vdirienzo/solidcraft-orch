#!/usr/bin/env bash
# ------------------------------------------------------------------
# rules-sync.sh - the snapshot of the upstream rules must not age.
#
# WHY THIS EXISTS (2026-11-17): RULES.md said "read 2026-10-30" and listed
# the "DISCREPANCIAS" with upstream. Nothing verified that snapshot, and
# upstream moves: 81 commits in five hours. It already showed. The README
# claimed the position of the `Changes a default:` line matters; the
# upstream parser (scripts/pr-checks/pr-checks.js, flag /im) says it does
# not. An agent that follows a stale rule produces pull requests the
# upstream CI rejects.
#
# LA WAVE PARA (2026-11-21): ahora se mide el origin/main de upstream (con
# `git fetch origin` antes), no el checkout local, y cuando upstream mueve
# AGENTS.md, CONTRIBUTING.md, una .agents/skills/*/SKILL.md o el parser de
# pr-checks.js, este script sale con 1 y con la LISTA de los archivos en
# stdout. Una wave que lo corre antes de despachar se detiene hasta que
# alguien revise RULES.md y los prompts contra el cambio. La implementacion
# (que archivos, como se hashean) es UNA: bin/rules-snapshot.sh --check.
#
# USAGE:
#   bash bin/rules-sync.sh               -> fetch + check
#   bash bin/rules-sync.sh --verbose     -> also the files that did not move
#   bash bin/rules-sync.sh --no-fetch    -> against the local origin/main
#
# OUTPUT: one line per changed file on stdout, "CAMBIO|NUEVO|SE-FUE  <path>";
# what to do next on stderr.
#
# Exit code: 0 the snapshot is current, 1 upstream moved (or there is no
# snapshot), 2 it could not be checked (no clone, no origin/main, a failed
# fetch with nothing visible moved).
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/rules-snapshot.sh" --check "$@"
