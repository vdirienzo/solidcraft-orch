#!/usr/bin/env bash
# Detecta que un PR nuestro DUPLICA un PR abierto de otro autor.
#
# Por que existe (11-11-2026): el PR #14822 era duplicado byte a byte del #14811
# (DuBearte) y NO lo detectaron ni el Duplicate PR check del upstream ni nuestro
# claim-verify.sh, porque los dos buscan SOLO el verbo de cierre (Fixes/Closes/
# Resolves #N). DuBearte describio el fallo en prosa, sin el verbo, asi que su PR
# era invisible para el guard. Nuestro guard dio VEREDICTO=OCUPADO cuando el
# rival era el nuestro, y la wave abrio un PR que no podia mergear nunca.
#
# Este script no razona sobre el issue: razona sobre el PARCHE.
#
# Uso:
#   bash bin/dup-scan.sh <issue> <branch|head-sha> [<repo>]
#
# Salida:
#   0  -> ningun PR abierto (distinto del nuestro) replica nuestro parche
#   1  -> hay al menos un PR abierto con las MISMAS lineas agregadas
#   2  -> error de uso / no se pudo verificar
#
# El parche se compara por LINEA AGREGADA (las que empiezan con '+'), que es lo
# que define el cambio: dos PRs que agregan las mismas lineas compiten por el
# mismo merge, mas alla de como cada uno redacte su descripcion.
#
# Variables de entorno:
#   SC_OUR_PR   numero de nuestro PR, para que no se marque a si mismo
#   SC_WORKTREE repo local (default ~/solidcraft)
#   SC_REPO     repo remoto (default tangency-labs/solidcraft)
set -uo pipefail

ISSUE="${1:-}"
OUR_REF="${2:-}"
# The gh of the machine, or the one of a test (the stub lives OUTSIDE the
# PATH: README rule 4). Without this the only way to test the script is a
# fake gh on the PATH, which is exactly what rule 4 forbids.
GH_BIN="${GH_BIN:-gh}"

REPO="${3:-${SC_REPO:-tangency-labs/solidcraft}}"
OUR_PR="${SC_OUR_PR:-0}"

if [[ -z "$ISSUE" || -z "$OUR_REF" ]]; then
  echo "uso: bash bin/dup-scan.sh <issue> <branch|sha> [repo]" >&2
  exit 2
fi
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "el issue tiene que ser un numero: '$ISSUE'" >&2
  exit 2
fi

WORKTREE="${SC_WORKTREE:-${HOME}/solidcraft}"
# El scratch de la corrida (2026-11-21): era el cache de hermes, que ya no
# existe en la caja, y el mktemp de abajo fallaba. Ahora es el TMPDIR.
SCRATCH="${SC_SCRATCH:-${TMPDIR:-/tmp}}"

# El --head de publish-pr.sh viene como "vdirienzo:<branch>" (fork:branch).
# Para el diff solo sirve la parte del branch.
OUR_REF="${OUR_REF#*:}"

# Si SC_WORKTREE no es un checkout (publish-pr.sh pasa --repo owner/name, que
# no es un path), se busca el worktree que tiene el branch. El branch de un
# PR vive en solidcraft-wt/issue-NNNNN, no en el checkout principal.
if [[ ! -e "$WORKTREE/.git" ]]; then
  WORKTREE=""
  for wt in $(git -C "${HOME}/solidcraft" worktree list --porcelain 2>/dev/null \
                | awk '/^worktree /{print $2}'); do
    br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$br" == "$OUR_REF" ]]; then
      WORKTREE="$wt"
      break
    fi
  done
  # Si no hay worktree con ese branch, el checkout principal (puede tener el
  # branch como ref remoto).
  [[ -z "$WORKTREE" ]] && WORKTREE="${HOME}/solidcraft"
fi

TMP="$(mktemp -d "${SCRATCH}/dup-scan-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# 1) Las lineas que agrega nuestro cambio, contra el main de upstream.
#    El diff es de tres puntos (origin/main...sha): el de dos puntos miente
#    cuando la rama esta atras.
git -C "$WORKTREE" diff "origin/main...$OUR_REF" >"$TMP/ours.diff" 2>/dev/null
if [[ ! -s "$TMP/ours.diff" ]]; then
  echo "no se pudo leer el diff de $OUR_REF contra origin/main en $WORKTREE" >&2
  exit 2
fi

# 2) Los PRs abiertos, con sus archivos y su head. Una sola llamada.
"$GH_BIN" pr list --repo "$REPO" --state open --limit 2000 \
  --json number,files,headRefOid >"$TMP/open.json" 2>/dev/null
if [[ ! -s "$TMP/open.json" ]]; then
  echo "no se pudo leer la lista de PRs de $REPO" >&2
  exit 2
fi

# 3) Los parches de los candidatos, en paralelo.
python3 - "$TMP/ours.diff" "$TMP/open.json" "$REPO" "$ISSUE" "$OUR_REF" "$OUR_PR" <<'PY' >"$TMP/result.txt"
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ours_path, open_json, repo, issue, our_ref, our_pr = sys.argv[1:7]
our_pr = int(our_pr or 0)

def added_lines(text):
    out = set()
    for line in text.splitlines():
        if line.startswith('+') and not line.startswith('+++'):
            out.add(line[1:].rstrip())
    return {l for l in out if l.strip()}

ours_text = open(ours_path, encoding='utf-8', errors='replace').read()
ours = added_lines(ours_text)

our_files = set()
for line in ours_text.splitlines():
    if line.startswith('diff --git'):
        our_files.add(line.rstrip('\n').split(' b/')[-1])

prs = json.load(open(open_json, encoding='utf-8'))
prs = [p for p in prs if p['number'] != our_pr]

# El PR cuyo head es NUESTRO commit es el nuestro, aunque el numero no lo sepamos.
our_sha = subprocess.run(['git', '-C', os.environ.get('SC_WORKTREE', os.path.expanduser('~/solidcraft')),
                          'rev-parse', '--verify', our_ref + '^{commit}'],
                         capture_output=True, text=True).stdout.strip()
if our_sha:
    prs = [p for p in prs if (p.get('headRefOid') or '') != our_sha]

candidates = [p['number'] for p in prs if our_files & {f['path'] for f in p.get('files', [])}]

def patch_of(pr):
    try:
        # El gh que se usa: el de la maquina o el de un test (GH_BIN). El
        # 'gh' a pelo lo resolvia por el PATH, y con el stub FUERA del PATH
        # (regla 4) este python pedia el gh de verdad.
        gh_bin = os.environ.get("GH_BIN") or "gh"
        r = subprocess.run([gh_bin, 'pr', 'diff', str(pr), '--repo', repo],
                           capture_output=True, text=True, timeout=180)
        return pr, r.stdout or ''
    except Exception:
        return pr, ''

dups = []
with ThreadPoolExecutor(max_workers=12) as ex:
    for pr, d in ex.map(patch_of, candidates):
        if not d:
            continue
        theirs = added_lines(d)
        if not ours or not theirs:
            continue
        # Mismo cambio: todas las lineas que agregamos estan en el otro PR, y el
        # otro PR no agrega un mar de lineas extra (si agrega 100 lineas y ours
        # tiene 2, es otro cambio que happens to contain ours).
        if ours <= theirs and len(ours) >= 0.4 * len(theirs):
            dups.append(pr)

dups.sort()
print(f"issue={issue} our_files={len(our_files)} our_lines={len(ours)} "
      f"candidates={len(candidates)} dups={','.join(map(str, dups))}")
PY

RESULT="$(cat "$TMP/result.txt")"
echo "$RESULT"

DUPS="$(printf '%s\n' "$RESULT" | sed -n 's/.*dups=\([0-9,]*\)$/\1/p')"
if [[ -n "$DUPS" ]]; then
  echo "  DUPLICADO: el PR abierto $DUPS agrega las mismas lineas que $OUR_REF."
  echo "  El numero mas bajo gana, aunque lo haya abierto otro autor."
  echo "  Cerrar el nuestro y ayudar en ese, o hacer un fix distinto."
  exit 1
fi

echo "  ningun PR abierto replica nuestro parche."
exit 0
