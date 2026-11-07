#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ping-ready-report.sh - the summary of ping-ready.sh, WITHOUT commenting.
#
#   bash bin/ping-ready-report.sh [<pr> ...]
#
# WHY: the agent has to decide whom to ping BEFORE it touches GitHub. This
# script prints the same summary that ping-ready.sh prints at the end:
#
#   <pr> <sha> <atras-de-main> <verde|rojo|pendiente> <si|no> LISTO|FALTA <que falta>
#
# It only READS. It never leaves a comment and never edits one. It is the
# same script with --report, so the two can never disagree about what a pull
# request needs.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/ping-ready.sh" --report "$@"
