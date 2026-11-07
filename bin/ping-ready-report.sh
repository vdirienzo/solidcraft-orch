#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ping-ready-report.sh - the summary of ping-ready.sh, WITHOUT commenting.
#
#   bash bin/ping-ready-report.sh [<pr> ...]
#
# WHY: the agent has to decide whom to ping BEFORE it touches GitHub. This
# script prints the same summary that ping-ready.sh prints at the end:
#
#   <pr> <sha-corto> <n-atras> <si|no|desconocido> <verde|rojo|pendiente>
#   <si|no> LISTO|FALTA <que falta>
#
# Field by field, one line per pull request:
#
#   <pr>          the number of the pull request
#   <sha-corto>   the head sha it is judged on (the first 12 characters)
#   <n-atras>     how many commits the branch is behind main. It is DATA, not
#                 a block: upstream merges so fast that "0 behind" is a race
#                 that is always lost. It never decides the verdict.
#   <si|no|desconocido>
#                 the CONFLICT with main: 'si' it conflicts, 'no' it merges
#                 cleanly, 'desconocido' it could not be measured (a safe
#                 failure: the pull request is NOT pinged)
#   <verde|rojo|pendiente>
#                 the state of the CI of the HEAD SHA
#   <si|no>       whether the pull request ALREADY has the 'approved-for-ci'
#                 label
#   LISTO|FALTA   the verdict, and what is missing (why it is not LISTO)
#
# It only READS. It never leaves a comment and never edits one. It is the
# same script with --report, so the two can never disagree about what a pull
# request needs.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/ping-ready.sh" --report "$@"
