#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Banco de pruebas (dry-run) del supervisor del loop de SolidCraft.
#
# Que hace: ensaya la plumbing COMPLETA del supervisor (estado, ledger,
# worktree del issue, gate, veredicto y reporte) dentro de un temporal,
# sin tocar el loop vivo.
#
# Ademas ensaya las DOS SENALES del loop (el gate rapido y la senal del
# merge) contra el state.py de verdad: un veredicto PARCIAL no publica.
#
# Por que hace falta: `bin/supervisor.sh` fija
#   LOOP_DIR="$HOME/.local/share/solidcraft-loop"
# asi que no hay forma de ensayar contra otro directorio, y su DRY_RUN=1
# escribe sobre el state.json REAL. Con la fase actual `gating`, el delta
# simulado {"phase": "idle"} transiciona desde `gating` (esta permitido en
# TRANSITIONS) y se lleva el trabajo en vuelo del issue.
#
# Como se aisla el ensayo:
#   - el supervisor se ejecuta sobre una COPIA, con la linea de LOOP_DIR
#     parcheada por sed para que apunte al temporal;
#   - el REPO del config.env copiado es un worktree del repo real, asi que
#     el fetch, el reset_checkout y el worktree del issue no tocan el
#     checkout real;
#   - el estado es SINTETICO: el banco NO copia el state.json real, lo
#     escribe segun el escenario (con el DEFAULT de state.py como plantilla);
#   - el gate es un `sleep` propio del banco, con su log sintetico: el gate
#     real no se lee ni se mata;
#   - HOME apunta a un temporal con un `opencode` de mentira: el janitor no
#     puede listar ni borrar sesiones reales;
#   - el fetch se anula (GIT_CONFIG_*) para no tocar las refs del repo real;
#   - las refs del repo real se fotografian antes y despues: si el ensayo
#     movio alguna, el banco la restaura y lo dice.
#
# Uso:
#   bin/dry-run.sh              # escenario idle
#   bin/dry-run.sh gating       # escenario gating (estado y gate sinteticos)
#   bin/dry-run.sh --keep       # no borra el temporal (para depurar)
#
# Salida: 0 si todas las comprobaciones pasan, 1 si falla alguna.
# ---------------------------------------------------------------------------
set -uo pipefail

# --- el loop real (lo que NO se toca) --------------------------------------
REAL_LOOP="${SOLIDCRAFT_LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
REAL_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"

SCENARIO="idle"
KEEP=0

usage() {
  cat <<'USAGE'
uso: bin/dry-run.sh [escenario] [--keep]

  escenario   idle    (por defecto): el loop esta ocioso, sin issue en vuelo
              gating  : hay un issue en vuelo en fase 'gating', con un gate
                        sintetico (un 'sleep' propio del banco)
  --keep               no borra el temporal (para depurar)

Variables de entorno:
  DRY_RUN_EXPECT_PHASE   la fase que se espera al final del ensayo
                         (por defecto, la de cada escenario)
  SOLIDCRAFT_LOOP_DIR    el loop real (por defecto, el del HOME)
  SOLIDCRAFT_REPO        el repo real (por defecto, /home/user/solidcraft)

Salida: 0 si todas las comprobaciones pasan, 1 si falla alguna.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    idle|gating) SCENARIO="$arg" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dry-run: escenario desconocido: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# La fase que se espera al final. Por defecto es la de HOY (la que produce
# el state.py de ahora): el banco documenta el comportamiento, y cuando el
# cambio que lo arregla este en pie, se afirma la nueva con
# DRY_RUN_EXPECT_PHASE (por ejemplo `gating`: el trabajo en vuelo sobrevive).
case "$SCENARIO" in
  idle)   EXPECT_PHASE="${DRY_RUN_EXPECT_PHASE:-idle}" ;;
  gating) EXPECT_PHASE="${DRY_RUN_EXPECT_PHASE:-idle}" ;;
esac

# --- el temporal -----------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/loop-dryrun.XXXXXX")" || exit 1
LOOP="$TMP/loop"
REPO_WT="$TMP/repo"
WT="$TMP/wt"
GATE_WT="$TMP/gate-worktree"
EVID_WT="$TMP/evidence-worktree"
TARGET_DIR="$TMP/target"
GATE_TARGET_DIR="$TMP/gate-target"
FAKE_HOME="$TMP/home"
FAKE_BIN="$FAKE_HOME/.opencode/bin"
SUP_OUT="$TMP/supervisor.out"

FAKE_GATE_PID=""
ISSUE_WT=""
CREATED_BRANCH=""
CLEANED=0
REFS_BEFORE=""
REFS_AFTER=""
MAIN_SHA_BEFORE=""
MAIN_SHA_AFTER_RUN=""

# --- limpieza (idempotente; se llama al final y desde la trampa) ----------
cleanup() {
  [ "$CLEANED" -eq 1 ] && return 0
  CLEANED=1

  # 1. el gate de mentira: un 'sleep' propio, nunca el gate real
  if [ -n "$FAKE_GATE_PID" ] && kill -0 "$FAKE_GATE_PID" 2>/dev/null; then
    kill -TERM "$FAKE_GATE_PID" 2>/dev/null || true
    wait "$FAKE_GATE_PID" 2>/dev/null || true
  fi

  # 2. los worktrees del ensayo (los del repo real)
  if [ -n "$ISSUE_WT" ]; then
    git -C "$REAL_REPO" worktree remove --force "$ISSUE_WT" >/dev/null 2>&1 || true
  fi
  git -C "$REAL_REPO" worktree remove --force "$REPO_WT" >/dev/null 2>&1 || true
  git -C "$REAL_REPO" worktree prune >/dev/null 2>&1 || true

  # 3. la rama que creo el ensayo (wt/issue-N): solo si no estaba antes
  if [ -n "$CREATED_BRANCH" ]; then
    git -C "$REAL_REPO" branch -D "$CREATED_BRANCH" >/dev/null 2>&1 || true
  fi

  # 4. las refs del repo real: si el ensayo movio alguna, se restaura.
  # Solo se restaura si la ref sigue como la dejo el ensayo: si otro actor
  # (el loop vivo) la movio despues, no se toca.
  #
  # LIMITACION (real, no hipotetica): el reset_checkout del supervisor hace
  # `checkout main` + `merge --ff-only origin/main` DENTRO del worktree temporal,
  # pero `main` es un ref COMPARTIDO: el `merge --ff-only` mueve el `main` real al
  # sha de origin/main. Este restore lo devuelve, pero SOLO si `main` sigue
  # como el ensayo lo dejo (MAIN_SHA_AFTER_RUN). Si el loop vivo mueve `main`
  # durante el ensayo, el banco NO lo restaura (no pisa trabajo ajeno) y la
  # comprobacion "el repo real quedo como estaba" falla: es el aviso de que
  # el ensayo se solapo con una operacion real sobre `main`.
  if [ -n "$MAIN_SHA_BEFORE" ] && [ -n "$MAIN_SHA_AFTER_RUN" ]; then
    now_main="$(git -C "$REAL_REPO" rev-parse refs/heads/main 2>/dev/null || true)"
    if [ -n "$now_main" ] && [ "$now_main" = "$MAIN_SHA_AFTER_RUN" ] \
       && [ "$now_main" != "$MAIN_SHA_BEFORE" ]; then
      git -C "$REAL_REPO" update-ref refs/heads/main "$MAIN_SHA_BEFORE" >/dev/null 2>&1 || true
    fi
  fi
}

# El temporal se borra al FINAL (despues del informe): el informe lee los
# ficheros del ensayo.
remove_tmp() {
  case "$TMP" in
    "${TMPDIR:-/tmp}"/loop-dryrun.*)
      if [ "$KEEP" -eq 1 ]; then
        say "dry-run: temporal conservado en $TMP"
      else
        rm -rf "$TMP" 2>/dev/null || true
      fi
      ;;
  esac
}
trap 'cleanup; remove_tmp' EXIT
trap 'cleanup; remove_tmp; exit 130' INT
trap 'cleanup; remove_tmp; exit 143' TERM

# --- helpers ---------------------------------------------------------------
say() { printf '%s\n' "$*"; }
hr() { printf '%s\n' "------------------------------------------------------------------"; }

md5_of() {
  if [ -f "$1" ]; then
    md5sum "$1" 2>/dev/null | awk '{print $1}'
  else
    echo "(no existe)"
  fi
}

lines_of() {
  if [ -f "$1" ]; then
    wc -l < "$1" 2>/dev/null | tr -dc '0-9'
  else
    echo "0"
  fi
}

snapshot_refs() {
  git -C "$REAL_REPO" for-each-ref --format='%(refname) %(objectname)' refs/heads 2>/dev/null | sort
}

CHECK_LINES=""
CHECK_FAILS=0
check() {  # check <OK|FALLO> <descripcion>
  CHECK_LINES="${CHECK_LINES}$1|$2
"
  [ "$1" = "FALLO" ] && CHECK_FAILS=$((CHECK_FAILS + 1))
  return 0
}

# ===========================================================================
# 1. El estado real, fotografiado ANTES del ensayo
# ===========================================================================
REAL_STATE="$REAL_LOOP/state.json"
REAL_LEDGER="$REAL_LOOP/ledger.md"
MD5_STATE_BEFORE="$(md5_of "$REAL_STATE")"
MD5_LEDGER_BEFORE="$(md5_of "$REAL_LEDGER")"
REFS_BEFORE="$(snapshot_refs)"
MAIN_SHA_BEFORE="$(git -C "$REAL_REPO" rev-parse refs/heads/main 2>/dev/null || true)"

# ===========================================================================
# 2. El temporal: la copia del loop, con el LOOP_DIR parcheado
# ===========================================================================
mkdir -p "$LOOP/bin" "$LOOP/logs/turns" "$LOOP/gates/default" "$LOOP/results" \
         "$LOOP/reports" "$LOOP/evidence" "$WT" "$GATE_WT" "$EVID_WT" \
         "$TARGET_DIR" "$GATE_TARGET_DIR" "$FAKE_BIN" 2>/dev/null

# El supervisor: la copia con la linea de LOOP_DIR parcheada por sed.
cp "$REAL_LOOP/bin/supervisor.sh" "$LOOP/bin/supervisor.sh" || exit 1
sed -i "s|^LOOP_DIR=.*|LOOP_DIR=\"$LOOP\"|" "$LOOP/bin/supervisor.sh"
if ! grep -q "^LOOP_DIR=\"$LOOP\"" "$LOOP/bin/supervisor.sh"; then
  echo "dry-run: no se pudo parchear LOOP_DIR en la copia del supervisor" >&2
  exit 1
fi
chmod +x "$LOOP/bin/supervisor.sh" 2>/dev/null || true

# El resto de la plumbing del loop.
for f in state.py gate-check.sh start-gate.sh gate-watchdog.sh \
         config-check.sh config-preflight.sh; do
  cp "$REAL_LOOP/bin/$f" "$LOOP/bin/$f" 2>/dev/null || true
done
cp "$REAL_LOOP/baseline-failures.txt" "$LOOP/baseline-failures.txt" 2>/dev/null || true
cp "$REAL_LOOP/ledger.md" "$LOOP/ledger.md" 2>/dev/null || true
cp -r "$REAL_LOOP/patches" "$LOOP/patches" 2>/dev/null || true
cp -r "$REAL_LOOP/prompts" "$LOOP/prompts" 2>/dev/null || true
# El gh.env real NO se copia (lleva el token): el token se pasa por el
# entorno, asi que el temporal no guarda ningun secreto en disco.
: > "$LOOP/gh.env"
chmod 600 "$LOOP/gh.env" 2>/dev/null || true

# El config.env copiado, con TODO apuntando al temporal. SeOverrides se
# anade AL FINAL: en bash, la ultima asignacion gana al hacer `. config.env`.
cp "$REAL_LOOP/config.env" "$LOOP/config.env" || exit 1
cat >> "$LOOP/config.env" <<EOF

# --- banco de pruebas (bin/dry-run.sh): todo apunta al temporal ---
REPO=$REPO_WT
GATE_WORKTREE=$GATE_WT
EVIDENCE_WORKTREE=$EVID_WT
CARGO_TARGET_DIR=$TARGET_DIR
GATE_TARGET_DIR=$GATE_TARGET_DIR
BASELINE_FAILURES=$LOOP/baseline-failures.txt
# Un fork que no existe: si state.py intentara crear el issue del log
# diario, fallaria en vez de crear algo real en el fork de verdad.
FORK=https://github.com/solidcraft-dryrun-noexiste/solidcraft.git
# El ensayo jamas mata un gate (el watchdog no tiene edad ni silencio para
# dispararse: los dos umbrales son inalcanzables).
GATE_TIMEOUT_MIN=100000
GATE_SILENT_MIN=100000
# La carga de la maquina no decide si el ensayo corre (el banco es
# determinista: la carga real no es su asunto).
MAX_LOAD=100000
MIN_FREE_GB=0
SKIP_FREE_GB=0
EOF

# El HOME del ensayo: un `opencode` de mentira (el janitor del supervisor no
# puede borrar sesiones reales) y el .gitconfig de verdad (git se comporta
# igual que en el loop).
cat > "$FAKE_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
# Stub del opencode para el banco de pruebas: el janitor del supervisor no
# debe listar ni borrar sesiones reales durante el ensayo.
exit 0
STUB
chmod +x "$FAKE_BIN/opencode" 2>/dev/null || true
if [ -f "$HOME/.gitconfig" ]; then
  cp "$HOME/.gitconfig" "$FAKE_HOME/.gitconfig" 2>/dev/null || true
fi

# El PATH del ensayo: el `opencode` de mentira delante, el de verdad fuera.
RUN_PATH="$FAKE_BIN"
IFS=':' read -r -a _path_parts <<< "$PATH"
for _p in "${_path_parts[@]}"; do
  case "$_p" in
    ""|*/.opencode/bin) continue ;;
  esac
  RUN_PATH="$RUN_PATH:$_p"
done

# ===========================================================================
# 3. El repo de ensayo: un worktree del repo real (nada del checkout real)
# ===========================================================================
if ! git -C "$REAL_REPO" worktree add --detach "$REPO_WT" origin/main >/dev/null 2>&1; then
  echo "dry-run: no se pudo crear el worktree de ensayo en $REPO_WT" >&2
  exit 1
fi

# ===========================================================================
# 4. El estado SINTETICO (el state.json real no se copia nunca)
# ===========================================================================
NOW_EPOCH="$(date -u +%s)"
FAKE_SHA="dryrun0000000000000000000000000000000000"
GATE_LOG="$LOOP/logs/gate-$FAKE_SHA.log"

# El gate de mentira: un `sleep` propio, con su log sintetico.
if [ "$SCENARIO" = "gating" ]; then
  sleep 600 &
  FAKE_GATE_PID=$!
  printf '%s\n' "$GATE_LOG" > "$LOOP/gate.path"
  printf '%s\n' "$FAKE_GATE_PID" > "$LOOP/gate.pid"
  printf '%s\n' "$NOW_EPOCH" > "$LOOP/gate.started"
  printf '%s\n' "$FAKE_SHA" > "$LOOP/gate.sha"
  # Un log de gate sintetico: el gate sigue corriendo (no hay EXIT= todavia).
  cat > "$GATE_LOG" <<'GATELOG'
$ cargo nextest run --workspace
    Finished `test` profile [unoptimized + debuginfo] target(s) in 3.21s
     Starting 214 tests across 21 binaries
GATELOG
fi

python3 - "$LOOP/bin/state.py" "$LOOP/state.json" "$SCENARIO" "$GATE_LOG" "$NOW_EPOCH" <<'PY'
import importlib.util
import json
import sys

state_py, out_path, scenario, gate_log, now = sys.argv[1:6]

# La plantilla es el DEFAULT del state.py de verdad: asi el estado sintetico
# tiene TODAS las claves que el supervisor y el state.py esperan.
spec = importlib.util.spec_from_file_location("loop_state", state_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

state = dict(mod.DEFAULT)
state["counters"] = dict(mod.DEFAULT["counters"])
state["report"] = dict(mod.DEFAULT["report"])
# El issue del log diario: un numero inventado y NO CERO, para que
# state.py no intente crear un issue real en el fork (ensure_report_issue
# solo pregunta cuando vale 0).
state["report"]["issue"] = 1

if scenario == "gating":
    state["phase"] = "gating"
    state["issue"] = 5302
    state["branch"] = "dryrun/issue-5302-sintetico"
    state["gate_log"] = gate_log
    state["in_flight"] = {"issue": 5302, "started": int(now)}
else:
    state["phase"] = "idle"
    state["issue"] = 0
    state["branch"] = ""
    state["gate_log"] = ""
    state["in_flight"] = None

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
if [ ! -f "$LOOP/state.json" ]; then
  echo "dry-run: no se pudo escribir el estado sintetico" >&2
  exit 1
fi

LEDGER_LINES_BEFORE="$(lines_of "$LOOP/ledger.md")"

# ===========================================================================
# 5. El ensayo: el supervisor sobre la copia, con DRY_RUN=1
# ===========================================================================
GH_TOKEN="$(sed -n 's/^GH_TOKEN=//p' "$REAL_LOOP/gh.env" 2>/dev/null | head -1)"

# El ensayo necesita que `gh` responda (es una precondición del supervisor:
# sin `gh` la vuelta se salta y no se ensaya nada). El HOME del ensayo no
# tiene el OAuth de ~/.config/gh/hosts.yml, así que se le pasa el directorio
# de configuración de gh de verdad: el ensayo sólo lee (el PAT de escritura no
# se usa para esto y el modelo no corre en el ensayo).
#
# OJO: bash evalúa las asignaciones de un prefijo de comando EN ORDEN, así que
# `HOME=... GH_CONFIG_DIR="$HOME/..."` pondría el HOME del ensayo en el
# GH_CONFIG_DIR. Por eso el path se guarda ANTES, en una variable.
GH_CONFIG_DIR_REAL="$HOME/.config/gh"
HOME="$FAKE_HOME" \
LOOP_DIR="$LOOP" \
SOLIDCRAFT_WT_ROOT="$WT" \
PATH="$RUN_PATH" \
GH_TOKEN="$GH_TOKEN" \
GH_CONFIG_DIR="$GH_CONFIG_DIR_REAL" \
DRY_RUN=1 \
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=remote.origin.url \
GIT_CONFIG_VALUE_0="$TMP/no-existe-este-remoto" \
  bash "$LOOP/bin/supervisor.sh" > "$SUP_OUT" 2>&1
SUP_RC=$?

# El worktree del issue (si el escenario lo creo) y la rama que trajo.
if [ -d "$WT/issue-5302" ]; then
  ISSUE_WT="$WT/issue-5302"
fi
if ! printf '%s\n' "$REFS_BEFORE" | grep -q 'refs/heads/wt/issue-5302 '; then
  CREATED_BRANCH="wt/issue-5302"
fi

# ===========================================================================
# 6. El estado real, fotografiado DESPUES del ensayo
# ===========================================================================
MD5_STATE_AFTER="$(md5_of "$REAL_STATE")"
MD5_LEDGER_AFTER="$(md5_of "$REAL_LEDGER")"
REFS_AFTER="$(snapshot_refs)"
MAIN_SHA_AFTER_RUN="$(git -C "$REAL_REPO" rev-parse refs/heads/main 2>/dev/null || true)"
LEDGER_LINES_AFTER="$(lines_of "$LOOP/ledger.md")"

# --- las comprobaciones ----------------------------------------------------
PHASE_OBSERVED="$(jq -r '.phase // "?"' "$LOOP/state.json" 2>/dev/null)"
ISSUE_OBSERVED="$(jq -r '.issue // 0' "$LOOP/state.json" 2>/dev/null)"
INFLIGHT_OBSERVED="$(jq -c '.in_flight // null' "$LOOP/state.json" 2>/dev/null)"

if [ -f "$LOOP/state.json" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$LOOP/state.json" >/dev/null 2>&1; then
  check "OK" "el state.json del temporal se escribio y es JSON valido"
else
  check "FALLO" "el state.json del temporal se escribio y es JSON valido"
fi

if [ "$PHASE_OBSERVED" = "$EXPECT_PHASE" ]; then
  check "OK" "la fase es la esperada (esperada: $EXPECT_PHASE, observada: ${PHASE_OBSERVED:-?})"
else
  check "FALLO" "la fase es la esperada (esperada: $EXPECT_PHASE, observada: ${PHASE_OBSERVED:-?})"
fi

if [ "${LEDGER_LINES_AFTER:-0}" -gt "${LEDGER_LINES_BEFORE:-0}" ]; then
  check "OK" "el ledger.md del temporal tiene linea nueva (+$((LEDGER_LINES_AFTER - LEDGER_LINES_BEFORE)))"
else
  check "FALLO" "el ledger.md del temporal tiene linea nueva (antes: $LEDGER_LINES_BEFORE, despues: $LEDGER_LINES_AFTER)"
fi

if [ "$MD5_STATE_BEFORE" = "$MD5_STATE_AFTER" ]; then
  check "OK" "el state.json REAL del loop no cambio (md5 $MD5_STATE_BEFORE)"
else
  check "FALLO" "el state.json REAL del loop no cambio (antes: $MD5_STATE_BEFORE, despues: $MD5_STATE_AFTER)"
fi

if [ "$MD5_LEDGER_BEFORE" = "$MD5_LEDGER_AFTER" ]; then
  check "OK" "el ledger.md REAL del loop no cambio (md5 $MD5_LEDGER_BEFORE)"
else
  check "FALLO" "el ledger.md REAL del loop no cambio (antes: $MD5_LEDGER_BEFORE, despues: $MD5_LEDGER_AFTER)"
fi

# Las refs del repo real: solo pueden cambiar las que el propio ensayo
# crea (la rama wt/issue-N) o las que mueve el reset_checkout (main), que el
# banco restaura. Cualquier otra es un FALLO.
REFS_TOUCHED="$(diff <(printf '%s\n' "$REFS_BEFORE") <(printf '%s\n' "$REFS_AFTER") 2>/dev/null | awk '/^[<>]/ {print $2}' | sort -u)"
REFS_BAD=""
for ref in $REFS_TOUCHED; do
  case "$ref" in
    refs/heads/main|refs/heads/wt/issue-*) ;;
    *) REFS_BAD="$REFS_BAD $ref" ;;
  esac
done
if [ -z "$REFS_BAD" ]; then
  if [ -z "$REFS_TOUCHED" ]; then
    check "OK" "las refs del repo real no cambiaron"
  else
    check "OK" "las refs del repo real solo tocaron lo del ensayo ($REFS_TOUCHED), restauradas al final"
  fi
else
  check "FALLO" "las refs del repo real no cambiaron (tocaron:$REFS_BAD)"
fi

# ===========================================================================
# 7. La limpieza y las comprobaciones posteriores
# ===========================================================================
cleanup

WT_LEFTOVER="$(git -C "$REAL_REPO" worktree list 2>/dev/null | grep -c 'loop-dryrun' || true)"
if [ "${WT_LEFTOVER:-0}" -eq 0 ]; then
  check "OK" "no queda ningun worktree del ensayo en el repo real"
else
  check "FALLO" "no queda ningun worktree del ensayo en el repo real (quedan $WT_LEFTOVER)"
fi

MAIN_SHA_NOW="$(git -C "$REAL_REPO" rev-parse refs/heads/main 2>/dev/null || true)"
if [ "$MAIN_SHA_NOW" = "$MAIN_SHA_BEFORE" ]; then
  check "OK" "el repo real quedo como estaba (main = ${MAIN_SHA_BEFORE:0:8})"
else
  check "FALLO" "el repo real quedo como estaba (main antes: ${MAIN_SHA_BEFORE:0:8}, ahora: ${MAIN_SHA_NOW:0:8})"
fi

if [ -n "$FAKE_GATE_PID" ] && kill -0 "$FAKE_GATE_PID" 2>/dev/null; then
  check "FALLO" "no queda ningun proceso 'sleep' del banco colgado"
else
  check "OK" "no queda ningun proceso 'sleep' del banco colgado"
fi

# ===========================================================================
# 8. The signals of the loop: the quick gate and the lane of the merge
# ===========================================================================
# Two files, written by other scripts, that the state exposes to the
# orchestrator:
#
#   gate.quick.verdict   the quick gate (bin/gate-quick.sh): it checks only
#                        the packages the change touches, so its verdict is
#                        PARTIAL and it NEVER publishes (PUBLISHABLE=no).
#   merge.verdict        the signal of the merge (bin/merge-verdict.sh): the
#                        CHEAP lane of the CI of the upstream.
#
# The rule that is checked here: a PARTIAL verdict does NOT publish. Only the
# COMPLETE gate (VERDE) publishes.
#
# The cases run against the REAL bin/state.py (the copy of the temporary loop)
# with a synthetic state, a synthetic turn log and a `gh` of their own: the
# network is not touched and the live loop is not.
# ===========================================================================
SIG_DIR="$TMP/signals"
SIG_STATE="$SIG_DIR/state.json"
SIG_LEDGER="$SIG_DIR/ledger.md"
SIG_TURN="$SIG_DIR/turn.jsonl"
SIG_OUT="$SIG_DIR/state.out"
SIG_ERR="$SIG_DIR/state.err"
SIG_BIN="$SIG_DIR/bin"
SIG_ISSUE=5302
SIG_PR=5531
SIG_RC=0
TIP_SHA=""

mkdir -p "$SIG_DIR" "$SIG_BIN" "$SIG_DIR/reports" \
         "$FAKE_HOME/solidcraft-wt/issue-$SIG_ISSUE" 2>/dev/null
: > "$SIG_LEDGER"

# The tip of the branch in flight: a repository of the bank, in the fake HOME
# (that is where state.py looks for the worktree of an issue). It is NOT a
# worktree of the real repository: the bank does not leave refs behind.
git -C "$FAKE_HOME/solidcraft-wt/issue-$SIG_ISSUE" init -q -b main >/dev/null 2>&1
git -C "$FAKE_HOME/solidcraft-wt/issue-$SIG_ISSUE" \
  -c user.name=dryrun -c user.email=dryrun@example.invalid \
  commit -q --allow-empty -m "the tip of the issue" >/dev/null 2>&1
TIP_SHA="$(git -C "$FAKE_HOME/solidcraft-wt/issue-$SIG_ISSUE" rev-parse HEAD 2>/dev/null || true)"

# The `gh` of the bank: it answers the head of the pull request with the sha
# of the case and it fails at everything else. The cases of the signals do
# not need the network (and they must not touch GitHub).
cat > "$SIG_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '%s\n' "${FAKE_HEAD_SHA:-}"
  exit 0
fi
exit 1
STUB
chmod +x "$SIG_BIN/gh" 2>/dev/null || true

write_sig_state() {
  # write_sig_state <phase> : the synthetic state of a case (the DEFAULT of
  # the real state.py, so every key the supervisor expects is there).
  python3 - "$LOOP/bin/state.py" "$SIG_STATE" "$1" "$SIG_ISSUE" "$SIG_PR" <<'PY'
import importlib.util
import json
import sys

state_py, out_path, phase, issue, pr = sys.argv[1:6]

spec = importlib.util.spec_from_file_location("loop_state", state_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

state = dict(mod.DEFAULT)
state["counters"] = dict(mod.DEFAULT["counters"])
state["report"] = dict(mod.DEFAULT["report"])
# The daily log issue is not created (its number is not zero).
state["report"]["issue"] = 1
state["phase"] = phase
state["issue"] = int(issue)
state["pr"] = int(pr)
state["branch"] = ""
state["gate_log"] = ""
# The issue is in flight but it did not start: the rule of the 3 hours does
# not apply to a case of the bank.
state["in_flight"] = {"issue": int(issue), "started": 0}

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

write_sig_turn() {
  # write_sig_turn <proposed phase> : the turn proposes the publication and
  # the review worker approves the tip of the branch. The ONLY thing that can
  # stop the publication is the gate.
  python3 - "$SIG_TURN" "$1" "$SIG_ISSUE" "$SIG_PR" "$TIP_SHA" <<'PY'
import json
import sys

path, phase, issue, pr, sha = sys.argv[1:6]

delta = {
    "phase": phase,
    "issue": int(issue),
    "pr": int(pr),
    "review": "aprobado",
    "summary": "dry run: the publication is proposed",
}
review = "sha revisado: %s\nveredicto: aprobar\n" % sha
lines = [
    json.dumps({"type": "text",
                "part": {"text": "dry run\n```json\n%s\n```"
                                  % json.dumps(delta)}}),
    json.dumps({"type": "tool_use",
                "part": {"state": {"input": {"agent": "sc-review"},
                                   "output": review}}}),
]
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
}

run_sig_state() {
  # run_sig_state <phase before> <proposed phase> : the REAL state.py decides
  # (the copy of the temporary loop): the model proposes, the supervisor
  # disposes. Its stderr is kept: the refusal says WHY.
  write_sig_state "$1"
  write_sig_turn "$2"
  REPO="$REPO_WT" \
  HOME="$FAKE_HOME" \
  PATH="$SIG_BIN:$PATH" \
  FAKE_HEAD_SHA="$TIP_SHA" \
    python3 "$LOOP/bin/state.py" \
      --state "$SIG_STATE" \
      --ledger "$SIG_LEDGER" \
      --turn-log "$SIG_TURN" \
      --config "$LOOP/config.env" \
      --reports-dir "$SIG_DIR/reports" \
      --loop-dir "$LOOP" \
      --session-id "ses_loop-dryrun-signals" > "$SIG_OUT" 2> "$SIG_ERR"
  SIG_RC=$?
}

sig_json() {
  # sig_json <jq filter> : a field of the state of the last case
  jq -r "$1" "$SIG_STATE" 2>/dev/null
}

write_quick_verdict() {
  # write_quick_verdict <verdict> : the verdict of the quick gate, with the
  # format of bin/gate-quick.sh (PUBLISHABLE=no, always).
  cat > "$LOOP/gate.quick.verdict" <<EOF
GATE_STATUS=finished
SCOPE=solidcraft-geom
VERDICT=$1
NEW_FAILURES=0
PUBLISHABLE=no
SHA=$TIP_SHA
AT=$NOW_EPOCH
EOF
}

write_merge_verdict() {
  # write_merge_verdict <verdict> : the signal of the merge, with the format
  # of bin/merge-verdict.sh.
  cat > "$LOOP/merge.verdict" <<EOF
MERGE_VERDICT=$1
MERGE_SHA=$TIP_SHA
MERGE_JOBS=Quick compile
MERGE_PR=$SIG_PR
AT=$NOW_EPOCH
EOF
}

# --- the cases -------------------------------------------------------------
if [ -z "$TIP_SHA" ]; then
  check "FALLO" "the signals cases have a tip of the branch to work with"
else
  check "OK" "the signals cases have a tip of the branch to work with (${TIP_SHA:0:8})"

  # --- case A1: the phase is 'implemented' and the quick gate is green ------
  # The delta proposes the publication: it is refused (the phase
  # 'implemented' does not reach 'published').
  write_quick_verdict VERDE-PARCIAL
  rm -f "$LOOP/merge.verdict"
  run_sig_state implemented published

  PHASE_SIG="$(sig_json '.phase')"
  QUICK_VERDICT="$(sig_json '.quick_verdict.verdict')"
  QUICK_PUBLISHABLE="$(sig_json '.quick_verdict.publishable')"
  QUICK_STALE="$(sig_json '.quick_verdict.stale')"
  PUBLISHED_N="$(sig_json '[.published[]?[]?] | length')"

  if [ "$SIG_RC" -eq 0 ]; then
    check "OK" "state.py ran the case 'implemented' without crashing"
  else
    check "FALLO" "state.py ran the case 'implemented' without crashing (EXIT=$SIG_RC)"
  fi

  if [ "$QUICK_VERDICT" = "VERDE-PARCIAL" ] && [ "$QUICK_PUBLISHABLE" = "no" ] \
     && [ "$QUICK_STALE" = "false" ]; then
    check "OK" "the quick verdict (VERDE-PARCIAL) is in the state and it is not obsolete"
  else
    QUICK_DETAIL="verdict=$QUICK_VERDICT publishable=$QUICK_PUBLISHABLE stale=$QUICK_STALE"
    check "FALLO" "the quick verdict (VERDE-PARCIAL) is not obsolete ($QUICK_DETAIL)"
  fi

  if [ "$PHASE_SIG" != "published" ] && [ "$PUBLISHED_N" = "0" ]; then
    check "OK" "the phase 'implemented' does not publish with the quick gate"
  else
    PHASE_DETAIL="phase=$PHASE_SIG published=$PUBLISHED_N"
    check "FALLO" "the phase 'implemented' does not publish ($PHASE_DETAIL)"
  fi

  # --- case A2: the phase allows the publication and the review is approved
  # The phase is 'gated' (the one from which 'published' IS reachable) and
  # the review worker approved the tip of the branch: the only thing that can
  # stop the publication is the gate, and the gate is not green.
  run_sig_state gated published

  PHASE_SIG="$(sig_json '.phase')"
  REVIEW_SIG="$(sig_json '.review')"
  PUBLISHED_N="$(sig_json '[.published[]?[]?] | length')"

  if [ "$PHASE_SIG" != "published" ] && [ "$PUBLISHED_N" = "0" ]; then
    check "OK" "a partial verdict does not publish in the phase 'gated'"
  else
    PHASE_DETAIL="phase=$PHASE_SIG published=$PUBLISHED_N"
    check "FALLO" "a partial verdict does not publish in 'gated' ($PHASE_DETAIL)"
  fi

  if [ "$REVIEW_SIG" = "aprobado" ]; then
    check "OK" "the refusal is not about the review: it was approved about the tip"
  else
    check "FALLO" "the refusal is not about the review (review=$REVIEW_SIG)"
  fi

  if grep -q "VERDE-PARCIAL" "$SIG_ERR" 2>/dev/null \
     && grep -q "COMPLETE gate" "$SIG_ERR" 2>/dev/null; then
    check "OK" "the refusal says WHY: a partial verdict does not publish"
  else
    check "FALLO" "the refusal says WHY: a partial verdict does not publish"
  fi

  # --- case B: the merge signal is RED -------------------------------------
  # The signal is about the pull request in flight and about its commit, so
  # it is not obsolete: the orchestrator receives it, and it does not publish.
  rm -f "$LOOP/gate.quick.verdict"
  write_merge_verdict ROJO
  run_sig_state gated published

  PHASE_SIG="$(sig_json '.phase')"
  MERGE_VERDICT="$(sig_json '.merge_verdict.verdict')"
  MERGE_STALE="$(sig_json '.merge_verdict.stale')"
  MERGE_PR="$(sig_json '.merge_verdict.pr')"
  PUBLISHED_N="$(sig_json '[.published[]?[]?] | length')"

  if [ "$MERGE_VERDICT" = "ROJO" ] && [ "$MERGE_STALE" = "false" ] \
     && [ "$MERGE_PR" = "$SIG_PR" ]; then
    check "OK" "the merge signal (ROJO) reaches the orchestrator (it is in the state)"
  else
    MERGE_DETAIL="verdict=$MERGE_VERDICT stale=$MERGE_STALE pr=$MERGE_PR"
    check "FALLO" "the merge signal (ROJO) does not reach the orchestrator ($MERGE_DETAIL)"
  fi

  if [ "$PHASE_SIG" != "published" ] && [ "$PUBLISHED_N" = "0" ]; then
    check "OK" "the merge signal does not publish either"
  else
    PHASE_DETAIL="phase=$PHASE_SIG published=$PUBLISHED_N"
    check "FALLO" "the merge signal does not publish ($PHASE_DETAIL)"
  fi
fi

# ===========================================================================
# 9. El informe
# ===========================================================================
ERR_FILE="$(ls -1 "$LOOP/logs"/*.err 2>/dev/null | head -1)"
TURN_FILE="$(ls -1 "$LOOP/logs/turns"/*.jsonl 2>/dev/null | head -1)"

hr
say "BANCO DE PRUEBAS DEL SUPERVISOR -- escenario: $SCENARIO"
hr
say "loop real (intocable): $REAL_LOOP"
say "repo real (intocable):  $REAL_REPO"
say "temporal del ensayo:    $TMP"
say "supervisor ensayado:    $LOOP/bin/supervisor.sh (LOOP_DIR parcheado por sed)"
say "repo del ensayo:        $REPO_WT (worktree de $REAL_REPO)"
if [ -n "$ISSUE_WT" ]; then
  say "worktree del issue:      $ISSUE_WT (creado por el supervisor del ensayo)"
else
  say "worktree del issue:      (no se creo: el escenario '$SCENARIO' no tiene issue en vuelo)"
fi
say
say "-- configuracion del ensayo (para que sea determinista) --"
say "REPO=$REPO_WT  GATE_WORKTREE=$GATE_WT  BASELINE_FAILURES=$LOOP/baseline-failures.txt"
say "SOLIDCRAFT_WT_ROOT=$WT (el worktree del issue se crea aqui, no en \$HOME/solidcraft-wt)"
say "GATE_TIMEOUT_MIN=100000 (el ensayo jamas mata un gate)  MAX_LOAD=100000"
say "FORK=https://github.com/solidcraft-dryrun-noexiste/solidcraft.git (el log diario no se publica)"
say "HOME=$FAKE_HOME (opencode de mentira: el janitor no toca sesiones reales)"
say "el fetch esta anulado (GIT_CONFIG_*): el ensayo no toca las refs del repo real"
say "AVISO (limitacion real): el reset_checkout del ensayo hace 'checkout main' +"
say "       'merge --ff-only origin/main' en el worktree temporal, pero 'main' es un"
say "       ref COMPARTIDO: el ensayo mueve el 'main' real y el banco lo restaura"
say "       al final. El restore solo se hace si 'main' sigue como el ensayo lo"
say "       dejo: si el loop vivo mueve 'main' durante el ensayo, el banco NO lo"
say "       restaura (no pisa trabajo ajeno) y la comprobacion 'el repo real"
say "       quedo como estaba' falla."
if [ -n "$FAKE_GATE_PID" ]; then
  say "gate sintetico: pid $FAKE_GATE_PID (un 'sleep' del banco)  log $GATE_LOG"
fi
say
say "-- codigo de retorno del supervisor --"
say "EXIT=$SUP_RC"
say
say "-- log del supervisor ($(basename "${ERR_FILE:-sin-log}")) --"
if [ -n "$ERR_FILE" ] && [ -f "$ERR_FILE" ]; then
  tail -40 "$ERR_FILE"
else
  say "(no hay log de error: el supervisor no escribio ninguno)"
fi
say
say "-- salida del supervisor (stdout+stderr) --"
if [ -s "$SUP_OUT" ]; then
  tail -20 "$SUP_OUT"
else
  say "(vacia)"
fi
say
say "-- turno simulado ($(basename "${TURN_FILE:-sin-turno}")) --"
if [ -n "$TURN_FILE" ] && [ -f "$TURN_FILE" ]; then
  cat "$TURN_FILE"
else
  say "(no hay log de turno)"
fi
say
say "-- state.json resultante (temporal) --"
if [ -f "$LOOP/state.json" ]; then
  cat "$LOOP/state.json"
else
  say "(no se escribio)"
fi
say
say "-- ledger.md del temporal: las ultimas lineas --"
if [ -f "$LOOP/ledger.md" ]; then
  tail -3 "$LOOP/ledger.md"
else
  say "(no hay ledger)"
fi
say
say "-- efecto sobre el trabajo en vuelo --"
say "fase:     ${PHASE_OBSERVED:-?} (esperada: $EXPECT_PHASE)"
say "issue:    ${ISSUE_OBSERVED:-?}"
say "in_flight: ${INFLIGHT_OBSERVED:-null}"
if [ "$SCENARIO" = "gating" ] && [ "$PHASE_OBSERVED" = "idle" ]; then
  say "AVISO: el delta del DRY_RUN ({phase: idle}) transiciona desde 'gating' y deja el"
  say "       trabajo en vuelo sin vuelo (in_flight=null). Este es el comportamiento"
  say "       que el banco hace visible: contra el loop real, ese turno se lleva el"
  say "       trabajo del issue. Cuando se corrija, affirmselo con"
  say "       DRY_RUN_EXPECT_PHASE=gating y el banco pasa a exigirlo."
fi
say
say "-- las señales del loop (gate rápido y señal del merge) --"
if [ -f "$LOOP/gate.quick.verdict" ]; then
  say "gate.quick.verdict:"
  sed 's/^/       /' "$LOOP/gate.quick.verdict"
else
  say "gate.quick.verdict: (no hay)"
fi
if [ -f "$LOOP/merge.verdict" ]; then
  say "merge.verdict:"
  sed 's/^/       /' "$LOOP/merge.verdict"
else
  say "merge.verdict: (no hay)"
fi
if [ -f "$SIG_STATE" ]; then
  say "estado del último caso de las señales:"
  say "       fase:            $(sig_json '.phase')"
  say "       review:          $(sig_json '.review')"
  say "       quick_verdict:   $(sig_json '.quick_verdict.verdict')"
  say "       publishable:     $(sig_json '.quick_verdict.publishable')"
  say "       quick stale:     $(sig_json '.quick_verdict.stale')"
  say "       merge_verdict:   $(sig_json '.merge_verdict.verdict')"
  say "       merge pr/stale:  $(sig_json '.merge_verdict.pr') / $(sig_json '.merge_verdict.stale')"
  say "       publicados:      $(sig_json '[.published[]?[]?] | length')"
  say "refusal del último caso (stderr de state.py):"
  sed 's/^/       /' "$SIG_ERR" 2>/dev/null | tail -6
fi
say
say "-- comprobaciones --"
printf '%s' "$CHECK_LINES"
hr
if [ "$CHECK_FAILS" -eq 0 ]; then
  say "VEREDICTO: OK ($SCENARIO) -- todas las comprobaciones pasan"
  exit 0
fi
say "VEREDICTO: FALLO ($SCENARIO) -- $CHECK_FAILS comprobacion(es) fallan"
exit 1
