#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Mide el before/after REAL de #17881 sobre el app desktop.
#
# El fix de #17881 esta mergeado en main como 3f886e460 (#17921), que es el
# commit que busca el centro de la pieza DENTRO del area que dejan los
# paneles. El PR #18192 (nuestro) toca la rama SIN host, que el desktop no
# usa: por eso no puede cambiar lo que se ve.
#
# Este script mide los dos builds:
#   BEFORE = 3f886e460^  (04c3a24e)  -- sin el fix de #17921
#   AFTER  = 3f886e460   -- con el fix
#
# La medicion usa el canal de control del app real (ui.worldToScreen del
# centro de la pieza, ui.inspect del viewport), con el navegador dockeado a
# la izquierda, igual que el script capture-17881-evidence.py.
# ---------------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-${ORCH_DIR}}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-${SOLIDCRAFT_REPO}}"
WORKTREES_DIR="${WORKTREES_DIR:-${WORKTREES_DIR}}"

REPO=${SOLIDCRAFT_REPO}
LOGS=${ORCH_DIR}/logs
OUT=${ORCH_DIR}/evidence/17881-before-after
BEFORE_SHA=04c3a24eab71949d89e2343d93b53140430d151c
AFTER_SHA=3f886e460e604cecb4d05ca9637af165f0c117a2
PORT_BEFORE=27983
PORT_AFTER=27984
DISP=:98

export PATH="${HOME}/.cargo/bin:${HOME}/.rustup/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
mkdir -p "$OUT" "$LOGS"

note() { echo "[$(date -u +%H:%M:%S)] $*"; }

build_and_measure() {
  local sha="$1" label="$2" port="$3"
  local wt="${WORKTREES_DIR}/measure-17881-$label"
  local slot="measure-17881-$label"

  note "=== $label: worktree en $sha ==="
  git -C "$REPO" fetch origin main -q 2>/dev/null
  if [ ! -d "$wt" ]; then
    git -C "$REPO" worktree add --detach "$wt" "$sha" >>"$LOGS/17881-ba-$label.log" 2>&1 || {
      note "  FALLO el worktree"; return 1; }
  fi

  export CARGO_TARGET_DIR="$REPO/targets-measure/$slot"
  export CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0
  export CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_DEV_OPT_LEVEL=1
  mkdir -p "$CARGO_TARGET_DIR"

  note "  compilando el app desktop ($label)..."
  ( cd "$wt" && nice -n 19 cargo build -p solidcraft --bin solidcraft ) \
      >>"$LOGS/17881-ba-$label.log" 2>&1
  local brc=$?
  if [ $brc -ne 0 ]; then
    note "  FALLO el build ($label) rc=$brc"; tail -30 "$LOGS/17881-ba-$label.log"; return 1
  fi
  local bin="$CARGO_TARGET_DIR/debug/solidcraft"
  [ -x "$bin" ] || { note "  FALLO no hay binario en $bin"; return 1; }

  note "  lanzando el app en el puerto $port y capturando..."
  local token
  token="$(openssl rand -hex 32)"
  SOLIDCRAFT_CONTROL_TOKEN="$token" bash "$REPO/../.local/share/solidcraft-orch/bin/launch-app.sh" \
      "$bin" "$port" "$token" "$DISP" "$LOGS" >>"$LOGS/17881-ba-$label.log" 2>&1
  local lrc=$?
  if [ $lrc -ne 0 ]; then
    note "  FALLO el arranque ($label) rc=$lrc"; tail -20 "$LOGS/17881-ba-$label.log"; return 1
  fi

  python3 "$REPO/../.local/share/solidcraft-orch/bin/capture-17881-evidence.py" \
      "$port" "$token" "$OUT/$label" "$label" >>"$LOGS/17881-ba-$label.log" 2>&1
  local crc=$?
  note "  captura rc=$crc ($label)"

  # La app queda viva: se mata por pid.
  if [ -f "$LOGS/app-10291-$port.pid" ]; then
    kill "$(cat "$LOGS/app-10291-$port.pid")" 2>/dev/null && note "  app parada"
  fi
  return $crc
}

note "######## BEFORE ($BEFORE_SHA) ########"
build_and_measure "$BEFORE_SHA" before "$PORT_BEFORE"
note "######## AFTER ($AFTER_SHA) ########"
build_and_measure "$AFTER_SHA" after "$PORT_AFTER"

note "######## comparacion ########"
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
for label in ("before", "after"):
    p = os.path.join(out, label, f"{label}-estado.json")
    if not os.path.exists(p):
        print(f"{label}: SIN ESTADO"); continue
    d = json.load(open(p))
    for step in d.get("pasos", []):
        if step.get("tag") == "navegador-abierto-despues-de-home":
            vp = step.get("viewport") or [0,0,0,0]
            c = (step.get("centro_pieza") or [None])[0]
            print(f"{label}: viewport={vp}  centro_pieza_x={c}")
PY
note "######## fin ########"
