#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-dup-scan.sh - el detector de duplicados por PARCHE ve al competidor que
# no nombra el issue.
#
# POR QUE ESTE TEST EXISTE (2026-11-11): el PR #14822 nuestro era duplicado
# byte a byte del #14811 de otro autor (DuBearte). Ni el Duplicate PR check del
# upstream ni claim-verify.sh lo detectaron, porque los dos buscan SOLO el
# verbo de cierre (Fixes/Closes/Resolves #N) y DuBearte describio el fallo en
# prosa. Nuestro guard dio "VEREDICTO=OCUPADO el PR #14822 ya reclama #14801"
# cuando el rival era el nuestro. La wave abrio un PR que no podia mergear.
#
# dup-scan.sh no razona sobre el issue: razona sobre el PARCHE. Compara las
# lineas agregadas contra cada PR abierto que toca los mismos archivos.
#
# Lo que estos tests miden:
#   a) un PR abierto que agrega las MISMAS lineas se detecta como duplicado;
#   b) un PR abierto que toca el archivo pero con OTRAS lineas NO es duplicado;
#   c) nuestro propio PR no se marca a si mismo (ni por numero ni por head);
#   d) un PR con la MISMA linea pero de otro autor SI cuenta (el numero mas
#      bajo gana, sea nuestro o no);
#   e) un competitor que describe el fallo en prosa (sin verbo de cierre) es
#      invisible para claim-verify.sh y VISIBLE para dup-scan.sh.
#
# NADA DE ESTE SCRIPT TOCA LA RED: el gh es un stub, el repo es un checkout
# throwaway con un commit y un branch, y el diff sale de ahi.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUP_SCAN="$HERE/dup-scan.sh"
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/dup-scan-test-XXXXXX")"
trap 'rm -rf "$TESTDIR"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FALLA- %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

# --- el stub de gh ---------------------------------------------------------
# Responde a `gh pr list --json number,files,headRefOid` con la fixture, y a
# `gh pr diff N` con el parche de ese PR. Todo lo demas responde vacio.
mkdir -p "$TESTDIR/bin"
cat > "$TESTDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# El stub de gh de este test.
#
# `gh pr list --json number,files,headRefOid` (sin --jq) -> $GH_LIST_FIXTURE
# `gh pr list ... --jq <filtro>`                          -> el filtro aplicado
#                                                           a $GH_FIXTURE
# `gh pr diff <n>`                                       -> $GH_DIFF_DIR/<n>.patch
# El resto -> vacio.
#
# El --jq se aplica con jq, como hace el gh real: un stub que lo ignorara
# responderia "todo pull request es un competidor" y el test mediria el stub,
# no la regla.
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  jq_filter=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--jq" ]; then jq_filter="$a"; fi
    prev="$a"
  done
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter" <"${GH_FIXTURE:-/dev/null}" 2>/dev/null
  else
    cat "${GH_LIST_FIXTURE:-/dev/null}"
  fi
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  f="${GH_DIFF_DIR:-/dev/null}/$3.patch"
  if [ -f "$f" ]; then
    cat "$f"
  fi
  exit 0
fi

exit 0
STUB
chmod +x "$TESTDIR/bin/gh"
export GH_LOG="$TESTDIR/gh.log"
export GH_LIST_FIXTURE="$TESTDIR/list.json"
export GH_DIFF_DIR="$TESTDIR/diffs"
PATCH_SRC="$TESTDIR/patches"
mkdir -p "$GH_DIFF_DIR" "$PATCH_SRC"
# El stub va PRIMERO en el PATH, o el gh real contesta y el test mide el
# upstream en vez de la fixture.
export PATH="$TESTDIR/bin:$PATH"

# --- el repo de mentira ----------------------------------------------------
# Un checkout throwaway con un commit y un branch. El diff de dup-scan.sh es
# `origin/main...<branch>`, asi que hace falta un ref "origin/main".
REPO="$TESTDIR/repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email "test@example.com"
  git config user.name "test"
  mkdir -p crates/demo
  printf 'fn original() {}\n' >crates/demo/mod.rs
  git add -A
  git commit -q -m "base"
  git branch -f origin/main main
  git checkout -q -b feature
  printf 'fn original() {}\nfn added() {}\n' >crates/demo/mod.rs
  git add -A
  git commit -q -m "change"
) >/dev/null 2>&1

export SC_WORKTREE="$REPO"
export SC_SCRATCH="$TESTDIR"

# --- el helper -------------------------------------------------------------
# dup_scan <issue> <branch> [our_pr] -> la salida en $OUT y el rc en $RC
dup_scan() {
  OUT="$(SC_OUR_PR="${3:-0}" bash "$DUP_SCAN" "$@" 2>&1)"
  RC=$?
}

# La fixture de la lista de PRs: cada argumento es
# <numero>|<head-sha>|<archivos separados por coma>|<archivo con el parche>
#
# El parche se copia a <numero>.patch porque el stub de gh sirve
# `gh pr diff <n>` desde $GH_DIFF_DIR/<n>.patch: el parche de un PR vive bajo
# SU numero, no bajo el nombre del archivo del que venga.
write_list() {
  local arr="[]" spec n sha files patch
  for spec in "$@"; do
    n="${spec%%|*}"; spec="${spec#*|}"
    sha="${spec%%|*}"; spec="${spec#*|}"
    files="${spec%%|*}"; patch="${spec#*|}"
    local fl="[]" f
    for f in ${files//,/ }; do
      fl="$(jq -n --argjson arr "$fl" --arg p "$f" '$arr + [{"path":$p}]')"
    done
    arr="$(jq -n --argjson arr "$arr" --argjson number "$n" --arg sha "$sha" \
             --argjson files "$fl" \
             '$arr + [{"number":$number,"headRefOid":$sha,"files":$files}]')"
    if [ -f "$patch" ]; then
      cp "$patch" "$GH_DIFF_DIR/$n.patch"
    else
      rm -f "$GH_DIFF_DIR/$n.patch"
    fi
  done
  printf '%s\n' "$arr" >"$GH_LIST_FIXTURE"
}

OUR_SHA="$(git -C "$REPO" rev-parse HEAD)"
OTHER_SHA="1111111111111111111111111111111111111111"

# --- 1) el competidor con las MISMAS lineas --------------------------------
echo "== un PR abierto con las mismas lineas es un duplicado =="

cat >"$PATCH_SRC/500.patch" <<'PATCH'
diff --git a/crates/demo/mod.rs b/crates/demo/mod.rs
--- a/crates/demo/mod.rs
+++ b/crates/demo/mod.rs
@@ -1 +1,2 @@
 fn original() {}
+fn added() {}
PATCH

write_list "500|$OTHER_SHA|crates/demo/mod.rs|$PATCH_SRC/500.patch"
dup_scan 9999 feature
if [ "$RC" -eq 1 ]; then
  ok "el PR #500 que replica nuestro parche es un duplicado (rc=1)"
else
  bad "el PR #500 que replica nuestro parche es un duplicado" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

if printf '%s' "$OUT" | grep -q '500'; then
  ok "el mensaje nombra al PR duplicado (#500)"
else
  bad "el mensaje nombra al PR duplicado" "$(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

if printf '%s' "$OUT" | grep -qi 'mas bajo gana\|lower number\|numero mas bajo'; then
  ok "el mensaje dice que gana el numero mas bajo"
else
  bad "el mensaje dice que gana el numero mas bajo" "$(printf '%s' "$OUT" | head -4 | tr '\n' ' ')"
fi

# --- 2) un PR que toca el archivo pero con OTRAS lineas --------------------
echo
echo "== un PR abierto con otras lineas NO es un duplicado =="

cat >"$PATCH_SRC/600.patch" <<'PATCH'
diff --git a/crates/demo/mod.rs b/crates/demo/mod.rs
--- a/crates/demo/mod.rs
+++ b/crates/demo/mod.rs
@@ -1 +1,2 @@
 fn original() {}
+fn otra_cosa() {}
PATCH

write_list "600|$OTHER_SHA|crates/demo/mod.rs|$PATCH_SRC/600.patch"
dup_scan 9999 feature
if [ "$RC" -eq 0 ]; then
  ok "un PR con otras lineas no es un duplicado (rc=0)"
else
  bad "un PR con otras lineas no es un duplicado" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

# --- 3) nuestro propio PR no se marca a si mismo --------------------------
echo
echo "== nuestro propio PR no es un competidor =="

cat >"$PATCH_SRC/700.patch" <<'PATCH'
diff --git a/crates/demo/mod.rs b/crates/demo/mod.rs
--- a/crates/demo/mod.rs
+++ b/crates/demo/mod.rs
@@ -1 +1,2 @@
 fn original() {}
+fn added() {}
PATCH

# 3a) por numero
write_list "700|$OTHER_SHA|crates/demo/mod.rs|$PATCH_SRC/700.patch"
dup_scan 9999 feature 700
if [ "$RC" -eq 0 ]; then
  ok "nuestro PR #700 (excluido por numero) no es un duplicado (rc=0)"
else
  bad "nuestro PR #700 (excluido por numero) no es un duplicado" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

# 3b) por head sha: el PR es nuestro aunque no sepamos el numero
write_list "701|$OUR_SHA|crates/demo/mod.rs|$PATCH_SRC/700.patch"
dup_scan 9999 feature
if [ "$RC" -eq 0 ]; then
  ok "nuestro PR (excluido por head sha) no es un duplicado (rc=0)"
else
  bad "nuestro PR (excluido por head sha) no es un duplicado" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

# --- 4) el competidor de otro autor cuenta --------------------------------
echo
echo "== un competidor de otro autor con el mismo parche SI cuenta =="

write_list "300|$OTHER_SHA|crates/demo/mod.rs|$PATCH_SRC/500.patch"
dup_scan 9999 feature
if [ "$RC" -eq 1 ]; then
  ok "un PR de otro autor con las mismas lineas es un duplicado (rc=1)"
else
  bad "un PR de otro autor con las mismas lineas es un duplicado" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

# --- 5) el competidor en prosa: invisible para claim-verify, visible aca ---
echo
echo "== el competidor que describe el fallo en prosa =="

# El caso real: #14811 no llevaba "Fixes #14801", asi que claim-verify.sh no
# lo veia. dup-scan.sh lo ve igual, porque compara el parche.
write_list "500|$OTHER_SHA|crates/demo/mod.rs|$PATCH_SRC/500.patch"
dup_scan 9999 feature
if [ "$RC" -eq 1 ]; then
  ok "un competidor sin verbo de cierre tambien se detecta (rc=1)"
else
  bad "un competidor sin verbo de cierre tambien se detecta" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

# Y el contraste: claim-verify.sh, que solo mira el verbo de cierre, NO lo
# ve. El fixture del competitor no lleva el verbo.
write_fixture_claim() {
  local arr="[]" spec n t b
  for spec in "$@"; do
    n="${spec%%|*}"; rest="${spec#*|}"
    t="${rest%%|*}"; b="${rest#*|}"
    arr="$(jq -n --argjson number "$n" --arg title "$t" --arg body "$b" \
             --argjson arr "$arr" \
             '$arr + [{"number":$number,"title":$title,"body":$body}]')"
  done
  printf '%s\n' "$arr" >"$TESTDIR/claim-fixture.json"
}
write_fixture_claim '500|Tests: the menu test no longer panics|The test panics with Dropped TexturesDelta'
export GH_FIXTURE="$TESTDIR/claim-fixture.json"
CLAIM_OUT="$(bash "$HERE/claim-verify.sh" 9999 2>&1)"
CLAIM_RC=$?
export GH_FIXTURE="$GH_LIST_FIXTURE"

if [ "$CLAIM_RC" -eq 0 ]; then
  ok "claim-verify.sh NO ve al competidor en prosa (rc=0): el hueco que cubre dup-scan"
else
  bad "claim-verify.sh NO ve al competidor en prosa (rc=0)" \
      "rc=$CLAIM_RC $(printf '%s' "$CLAIM_OUT" | head -2 | tr '\n' ' ')"
fi

# --- 6) el uso -------------------------------------------------------------
echo
echo "== el uso =="

if bash "$DUP_SCAN" >/dev/null 2>&1; then
  bad "sin argumentos es un error de uso (rc=2)"
else
  RC=$?
  if [ "$RC" -eq 2 ]; then
    ok "sin argumentos es un error de uso (rc=2)"
  else
    bad "sin argumentos es un error de uso (rc=2)" "rc=$RC"
  fi
fi

if bash "$DUP_SCAN" "no-es-un-numero" feature >/dev/null 2>&1; then
  bad "un issue que no es numero es un error de uso (rc=2)"
else
  RC=$?
  if [ "$RC" -eq 2 ]; then
    ok "un issue que no es numero es un error de uso (rc=2)"
  else
    bad "un issue que no es numero es un error de uso (rc=2)" "rc=$RC"
  fi
fi

# --- el resumen ------------------------------------------------------------
echo
echo "== el resumen =="
if [ "$FAIL" -eq 0 ]; then
  echo "$PASS casos pasan, 0 fallan"
  exit 0
fi
echo "$PASS caso(s) pasan, $FAIL fallan"
exit 1
