#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-agent-turn.sh - the turn of the agent, with its nudges.
#
# Lo que se prueba (con un opencode STUB, sin modelo):
#   1. una corrida que termina con el JSON del veredicto no se empuja
#   2. una corrida sin veredicto recibe un empujon EN LA MISMA SESION
#      (--session <id>), y el turno termina cuando el empujon lo trae
#   3. sin veredicto nunca: a lo sumo AGENT_NUDGES empujones, y se dice
#   4. una corrida que falla (rc distinto de 0) no se empuja
# Run:  bash bin/test-agent-turn.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TURN="$HERE/agent-turn.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-agent-turn.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

# The stub: MODE says when it answers with the verdict. It logs its argv.
cat > "$TMP/opencode" <<'EOF'
#!/usr/bin/env bash
{ printf '%s' "$*" | tr '\n' ' '; echo; } >> "$STUB_CALLS"
n=$(wc -l < "$STUB_CALLS")
ev() { printf '{"type":"text","sessionID":"ses_test","part":{"text":%s}}\n' "$1"; }
case "$STUB_MODE" in
  first) ev '"done {\"verdict\": \"ready\", \"pr\": 1}"' ;;
  second) if [ "$n" -ge 2 ]; then ev '"{\"verdict\": \"blocked\", \"pr\": 0}"'; else ev '"Let me instrument it."'; fi ;;
  never) ev '"Let me look at one more thing."' ;;
  fail) ev '"boom"'; exit 3 ;;
esac
exit 0
EOF
chmod +x "$TMP/opencode"
echo "the brief" > "$TMP/brief.md"

run_turn() {  # $1 = mode
  : > "$TMP/calls"; : > "$TMP/events.jsonl"
  STUB_MODE="$1" STUB_CALLS="$TMP/calls" AGENT_NUDGES=2 \
    bash "$TURN" "$TMP/opencode" m/x build "$TMP/brief.md" 7 5 "$TMP/events.jsonl" > "$TMP/out" 2>&1
  echo $?
}

rc=$(run_turn first)
if [ "$(wc -l < "$TMP/calls")" -eq 1 ] && [ "$rc" -eq 0 ] && grep -q 'veredicto=ready' "$TMP/out"; then
  ok "con el veredicto en la primera corrida no hay empujon"
else
  no "con el veredicto en la primera corrida no hay empujon" "rc=$rc calls=$(wc -l < "$TMP/calls") $(cat "$TMP/out")"
fi

rc=$(run_turn second)
if [ "$(wc -l < "$TMP/calls")" -eq 2 ] && grep -q -- '--session ses_test' <(sed -n 2p "$TMP/calls") \
   && grep -q 'veredicto=blocked' "$TMP/out"; then
  ok "sin veredicto, un empujon en la MISMA sesion lo trae"
else
  no "sin veredicto, un empujon en la MISMA sesion lo trae" "calls: $(cat "$TMP/calls") out: $(cat "$TMP/out")"
fi
if ! grep -q -- '--session' <(sed -n 1p "$TMP/calls"); then
  ok "la primera corrida es una sesion nueva (sin --session)"
else
  no "la primera corrida es una sesion nueva (sin --session)" "$(sed -n 1p "$TMP/calls")"
fi

rc=$(run_turn never)
if [ "$(wc -l < "$TMP/calls")" -eq 3 ] && grep -q 'sin veredicto despues de 2 empujones' "$TMP/out"; then
  ok "sin veredicto nunca: dos empujones y se dice"
else
  no "sin veredicto nunca: dos empujones y se dice" "calls=$(wc -l < "$TMP/calls") $(cat "$TMP/out")"
fi

rc=$(run_turn fail)
if [ "$(wc -l < "$TMP/calls")" -eq 1 ] && [ "$rc" -eq 3 ]; then
  ok "una corrida que falla no se empuja y su rc sale"
else
  no "una corrida que falla no se empuja y su rc sale" "rc=$rc calls=$(wc -l < "$TMP/calls")"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ]
