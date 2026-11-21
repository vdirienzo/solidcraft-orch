#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-kill-orphan-browsers.sh - the tests of the reaper of orphan browsers.
#
# WHY THE TESTS EXIST: an agent that opens a browser leaves it alive when its
# turn is cut: the process of the MCP of chrome-devtools dies and the browser
# stays, with 40 processes and 3,7 GB of RAM in a box of 15 GB. The reaper
# kills the browsers whose MCP is gone and leaves the ones whose MCP is alive.
#
# THE INCIDENT OF 2026-11-21: the first reaper split the `ps` output by WORDS
# and killed every word, the PPID included. The PPID of an orphan browser on
# a systemd desktop is `systemd --user`: the test killed it and GNOME closed
# the whole session, three times in a row. So:
#   - the cases of the logic run on a FAKE process list (KOB_PS_FILE), which
#     the reaper never kills (it forces --dry-run);
#   - the one case with real processes is limited with --match to a tag of
#     this run, and checks that the adopter of the orphan (systemd --user on
#     the desktop) is STILL ALIVE afterwards.
#
# EXIT CODES:
#   0  every test passed
#   1  at least one failed
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAPER="$REPO_ROOT/bin/kill-orphan-browsers.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FALLA- %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-kob.XXXXXX")"
TAG="kobtest$$"
CHILDREN=""
cleanup() {
  local p
  for p in $CHILDREN; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

U="$(id -u)"
PROF="--user-data-dir=/home/u/.cache/chrome-devtools-mcp/chrome-profile"
BROWSER="/opt/google/chrome/chrome --remote-debugging-pipe $PROF --window-size=800,600 1 -1 about:blank"

# The fake list: "<pid> <ppid> <uid> <args>".
#   4000 systemd --user (the adopter)       4100 the MCP (alive)
#   5001 orphan, adopted by systemd --user  5002 orphan, ppid 1
#   5003 orphan, its parent is not listed   5004 browser of a live MCP
#   5005 renderer of an orphan               5006 the user's own Chrome
#   5007 orphan of another user              5008 orphan, isolated profile
#   5009 orphan adopted by a non-systemd subreaper (claude)
cat > "$TMP/ps.txt" <<EOF
    1     0     0 /sbin/init splash
 4000     1  $U /usr/lib/systemd/systemd --user
 4100  4000  $U node /home/u/.npm/_npx/x/node_modules/.bin/chrome-devtools-mcp --no-usage-statistics
 4200  4000  $U claude --dangerously-skip-permissions
 5001  4000  $U $BROWSER
 5002     1  $U $BROWSER
 5003 77777  $U $BROWSER
 5004  4100  $U $BROWSER
 5005  5001  $U /opt/google/chrome/chrome --type=renderer $PROF --remote-debugging-pipe
 5006  4000  $U /opt/google/chrome/chrome --remote-debugging-port=9222 --user-data-dir=/home/u/.config/google-chrome
 5007  4000  4242 $BROWSER
 5008  4000  $U /opt/google/chrome/chrome --remote-debugging-pipe --user-data-dir=/tmp/puppeteer_dev_chrome_profile-AbC123
 5009  4200  $U $BROWSER
broken line without numbers
EOF

out="$(KOB_PS_FILE="$TMP/ps.txt" bash "$REAPER" 2>&1)"
targets="$(printf '%s\n' "$out" | awk '$1=="would-kill"{print $2}' | sort -n | tr '\n' ' ')"

# --- 1. THE LOGIC, ON A FAKE LIST -------------------------------------------
[ "$targets" = "5001 5002 5003 5008 " ] \
  && ok "solo los navegadores huerfanos del MCP (5001 5002 5003 5008)" \
  || no "solo los navegadores huerfanos del MCP (5001 5002 5003 5008)" "salio: '$targets' / $out"

case " $targets " in
  *" 4000 "*|*" 1 "*|*" 0 "*) no "nunca el padre: systemd --user, el init" "salio: '$targets'" ;;
  *) ok "nunca el padre: systemd --user, el init" ;;
esac
if printf '%s\n' "$out" | grep -qE '^would-kill [^0-9]|^would-kill -'; then
  no "una palabra de los argumentos nunca es un pid" "$out"
else
  ok "una palabra de los argumentos nunca es un pid"
fi
case " $targets " in *" 5004 "*) no "el navegador de un MCP vivo no se toca" ;; *) ok "el navegador de un MCP vivo no se toca" ;; esac
case " $targets " in *" 5005 "*) no "un renderer no se cuenta (muere con su navegador)" ;; *) ok "un renderer no se cuenta (muere con su navegador)" ;; esac
case " $targets " in *" 5006 "*) no "el Chrome del usuario (sin el perfil del MCP) no se toca" ;; *) ok "el Chrome del usuario (sin el perfil del MCP) no se toca" ;; esac
case " $targets " in *" 5007 "*) no "el navegador de otro usuario no se toca" ;; *) ok "el navegador de otro usuario no se toca" ;; esac
case " $targets " in *" 5009 "*) no "adoptado por otro subreaper: no se mata (lado seguro)" ;; *) ok "adoptado por otro subreaper: no se mata (lado seguro)" ;; esac

# --- 2. A FAKE LIST NEVER KILLS ----------------------------------------------
# A real process of ours is written in the fake list as an orphan browser:
# without --dry-run the reaper must still not kill it.
sleep 60 &
VICTIM=$!
CHILDREN="$CHILDREN $VICTIM"
printf '%s 4000 %s %s\n 4000 1 %s /usr/lib/systemd/systemd --user\n' "$VICTIM" "$U" "$BROWSER" "$U" > "$TMP/ps-real-pid.txt"
KOB_PS_FILE="$TMP/ps-real-pid.txt" bash "$REAPER" >/dev/null 2>&1
if kill -0 "$VICTIM" 2>/dev/null; then
  ok "una lista de mentira nunca mata (fuerza --dry-run)"
else
  no "una lista de mentira nunca mata (fuerza --dry-run)" "el proceso $VICTIM murio"
fi

# --- 3. REAL PROCESSES, LIMITED TO THIS RUN ---------------------------------
# A fake browser of the MCP: `exec -a` gives `sleep` the argv of a browser.
FAKE_ARGV="chrome --remote-debugging-pipe --user-data-dir=$TMP/chrome-devtools-mcp/chrome-profile-$TAG"

# 3a. Its parent (this shell) is alive: it is not touched.
bash -c "exec -a \"$FAKE_ARGV-live\" sleep 120" >/dev/null 2>&1 &
LIVE=$!
CHILDREN="$CHILDREN $LIVE"
sleep 1
bash "$REAPER" --match "$TAG-live" >/dev/null 2>&1
if kill -0 "$LIVE" 2>/dev/null; then
  ok "real: el navegador con su dueno vivo no se toca"
else
  no "real: el navegador con su dueno vivo no se toca" "el reaper mato $LIVE"
fi

# 3b. An orphan: its parent exits right away and the kernel gives it to the
# nearest subreaper (systemd --user on the desktop, maybe the agent that runs
# the test). The reaper is told that this adopter is an adopter, and is
# limited to the tag of this run: nothing else of the machine can match.
( bash -c "exec -a \"$FAKE_ARGV-orphan\" sleep 120" >/dev/null 2>&1 & )
sleep 1
ORPHAN="$(pgrep -f -- "$TAG-orphan" | head -1)"
if [ -z "$ORPHAN" ]; then
  no "real: el huerfano se mata" "el navegador de mentira no arranco"
else
  CHILDREN="$CHILDREN $ORPHAN"
  ADOPTER="$(awk '{print $4}' "/proc/$ORPHAN/stat" 2>/dev/null)"
  ADOPTER_NAME="$(ps -o args= -p "$ADOPTER" 2>/dev/null | awk '{print $1}')"
  ADOPTER_NAME="${ADOPTER_NAME##*/}"
  if [ "$ADOPTER" = "$$" ]; then
    no "real: el huerfano se mata" "el huerfano no se desprendio de este shell"
  else
    KOB_ADOPTERS="systemd init $ADOPTER_NAME" bash "$REAPER" --match "$TAG-orphan" >/dev/null 2>&1
    sleep 1
    if kill -0 "$ORPHAN" 2>/dev/null; then
      no "real: el huerfano se mata" "sigue vivo $ORPHAN (adoptado por $ADOPTER $ADOPTER_NAME)"
    else
      ok "real: el huerfano se mata"
    fi
    if [ "$ADOPTER" = "1" ] || kill -0 "$ADOPTER" 2>/dev/null; then
      ok "real: el que lo adopto ($ADOPTER_NAME) sigue vivo (la regresion del 2026-11-21)"
    else
      no "real: el que lo adopto ($ADOPTER_NAME) sigue vivo (la regresion del 2026-11-21)" "murio $ADOPTER"
    fi
  fi
fi

# 3c. The systemd --user of this user, if there is one, is alive after all.
SDU="$(pgrep -u "$U" -f '^/usr/lib/systemd/systemd --user' | head -1)"
if [ -n "$SDU" ]; then
  kill -0 "$SDU" 2>/dev/null \
    && ok "real: systemd --user ($SDU) sigue vivo" \
    || no "real: systemd --user ($SDU) sigue vivo"
fi

printf '\n%s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
