#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-briefs.sh - the briefs point at code that has to exist.
#
# POR QUE EXISTEN: un brief es la instruccion LITERAL que recibe un
# subagente. Un brief que apunta a un archivo que se movio hace que el
# agente busque en el lugar viejo, gaste su tope de iteraciones en un
# callejon sin salida y no entregue nada. Eso es exactamente lo que el
# README previene con "un brief con 'busca el bug' produce exploracion,
# no codigo" - pero con un ancla rota el problema es peor: el brief SI
# parece literal.
#
# La auditoria del propio repo (reports/loop-codigo.md) ya lo habia
# pedido y no se hizo: 7 de los 15 briefs apuntaban a rutas que ya no
# existian, y 3 apuntaban a areas con el kernel en pausa.
#
# QUE MIDE:
#   1. cada ruta crates/... / apps/... / solidcore/... / assets/... que
#      menciona un brief tiene que existir en el checkout de upstream,
#      O el brief tiene que decir que la va a crear, O que la va a
#      borrar (esas dos son instrucciones, no anclas)
#   2. ningun brief puede mandar a un archivo por bug: la regla del
#      repo es "un test de regresion va en el archivo de test del AREA,
#      nunca en un archivo por bug" (AGENTS.md, issue #3226)
#   3. ningun brief puede mandar a una area con el kernel en pausa
#      sin decirlo (RULES.md: el kernel esta en pausa)
#
# NECESITA el checkout de upstream: SOLIDCRAFT_REPO. Sin el, sale con
# rc=2 (UNKNOWN: no se pudo medir, no es un verde).
#
# Run:  bash bin/test-briefs.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="$(dirname "$HERE")"
# The machine's own paths know where the checkout is (bin/paths.sh, 2026-11-24): the default
# below is only the fallback for a machine without that file.
if [ -z "${SOLIDCRAFT_REPO:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
fi
REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
# Los briefs que se leen de verdad viven en el directorio canonico de la
# maquina (este repo guarda una copia). Los dos se miden: una copia vieja
# rompe la maquina y la canonica rompe al agente.
BRIEFS="$ORCH_DIR/briefs"
BRIEFS_CANON="${ORCH_BRIEFS_DIR:-$HOME/.local/share/solidcraft-orch/briefs}"

if [ ! -d "$REPO" ] || [ ! -d "$BRIEFS" ]; then
  echo "test-briefs: no hay checkout de upstream ($REPO) o no hay briefs: no se puede medir" >&2
  echo "  (SOLIDCRAFT_REPO=... bash bin/test-briefs.sh)" >&2
  exit 2
fi

# Los dos directorio de briefs, como una lista.
BRIEF_LIST=()
for d in "$BRIEFS" "$BRIEFS_CANON"; do
  [ -d "$d" ] || continue
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    BRIEF_LIST+=("$f")
  done
done

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); }

# Las areas con el kernel en pausa (RULES.md: booleans, fillets,
# chamfers, shell, offsets, sweeps, lofts, threads, holes, STEP/IGES,
# tessellation). Un brief que apunte a una de ellas tiene que decirlo.
KERNEL_EN_PAUSA='crates/kernel|crates/smlib|solidcore/|STEP|IGES|tessell'

# --- 1. las anclas existen -------------------------------------------------
TMP_ROTAS="$(mktemp)"
TMP_CREADAS="$(mktemp)"
trap 'rm -f "$TMP_ROTAS" "$TMP_CREADAS"' EXIT
: > "$TMP_ROTAS"

# Las rutas que ALGUN brief crea: son instrucciones, no anclas rotas. Un
# brief puede crear un archivo y otro brief despues commitearlo.
CREADAS="$TMP_CREADAS"
: > "$CREADAS"
for brief in "${BRIEF_LIST[@]}"; do
  [ -f "$brief" ] || continue
  while IFS=: read -r line path; do
    [ -n "${path:-}" ] || continue
    sed -n "${line}p" "$brief" | grep -qiE 'crea|crear|create|nuevo archivo|new file' \
      && echo "$path" >> "$CREADAS"
  done < <(grep -onE '(crates|apps|solidcore|assets)/[A-Za-z0-9_./-]+\.(rs|json|md|wgsl|yml|toml)' "$brief")
done

for brief in "${BRIEF_LIST[@]}"; do
  [ -f "$brief" ] || continue
  while IFS=: read -r line path; do
    [ -n "${path:-}" ] || continue
    # La ruta existe: no hay nada que mirar.
    [ -e "$REPO/$path" ] && continue
    # La ruta la crea otro brief: es una instruccion, no un ancla rota.
    grep -qxF "$path" "$CREADAS" && continue
    linea="$(sed -n "${line}p" "$brief")"
    # "Crea <ruta>": la ruta no existe todavia y es lo que el brief pide
    # hacer. Es una instruccion, no un ancla rota.
    printf '%s' "$linea" | grep -qiE 'crea|crear|create|nuevo archivo|new file' && continue
    # "git rm <ruta>": la ruta no existe y el brief pide borrarla.
    printf '%s' "$linea" | grep -qiE 'git rm|borrar|remove|eliminar' && continue
    echo "$(basename "$brief"):$line $path" >> "$TMP_ROTAS"
  done < <(grep -onE '(crates|apps|solidcore|assets)/[A-Za-z0-9_./-]+\.(rs|json|md|wgsl|yml|toml)' "$brief")
done

if [ -s "$TMP_ROTAS" ]; then
  no "toda ruta que menciona un brief existe en upstream"
  sed 's/^/     /' "$TMP_ROTAS"
else
  ok "toda ruta que menciona un brief existe en upstream (o el brief dice que la va a crear o borrar)"
fi

# --- 2. ningun brief manda a un archivo por bug ----------------------------
porbug=""
for brief in "${BRIEF_LIST[@]}"; do
  [ -f "$brief" ] || continue
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Un archivo por bug: el nombre lleva el numero del issue.
    if printf '%s' "$path" | grep -qE '_[0-9]{3,}(_tests)?\.rs$'; then
      porbug="$porbug$(basename "$brief"): $path"$'\n'
    fi
  done < <(grep -ohE '(crates|apps)/[A-Za-z0-9_./-]+\.rs' "$brief" | sort -u)
done
if [ -z "$porbug" ]; then
  ok "ningun brief manda a un archivo por bug (la regla es el archivo de test del AREA)"
else
  no "ningun brief manda a un archivo por bug"
  printf '%s' "$porbug" | sed 's/^/     /'
fi

# --- 3. las areas con el kernel en pausa se dicen -------------------------
pausa=""
for brief in "${BRIEF_LIST[@]}"; do
  [ -f "$brief" ] || continue
  # Un brief que toca el kernel tiene que decir que esta en pausa: si
  # se dispatcha igual, el agente trabaja en un area congelada.
  if grep -qE "$KERNEL_EN_PAUSA" "$brief"; then
    if ! grep -qiE 'kernel|pausad|en pausa|PAUSED' "$brief"; then
      pausa="$pausa$(basename "$brief")"$'\n'
    fi
  fi
done
if [ -z "$pausa" ]; then
  ok "todo brief que toca el kernel dice que el kernel esta en pausa"
else
  no "todo brief que toca el kernel dice que el kernel esta en pausa"
  printf '%s' "$pausa" | sed 's/^/     /'
fi

# --- 4. las rutas absolutas y las skills que cita el brief existen ----------
# (2026-11-28) Un brief que apuntaba a
# /home/user/Projects/solidcraft-orch/skills/solidcraft-agent-tools/SKILL.md
# apuntaba a un archivo que no existe: upstream movio esa skill a
# .agents/skills/ y el brief seguia mandando al agente a un callejon sin
# salida. Estas dos medidas cazan esa clase de ancla rota.
rotas_abs=""
rotas_skill=""
for brief in "${BRIEF_LIST[@]}"; do
  while IFS=: read -r line abs; do
    [ -n "${abs:-}" ] || continue
    [ -e "$abs" ] && continue
    # "escribe <ruta>": la ruta no existe todavia y es lo que el brief pide
    # hacer. Es una instruccion, no un ancla rota.
    sed -n "${line}p" "$brief" | grep -qiE 'crea|crear|create|write|escribe|guarda|save|new file|nuevo archivo' && continue
    rotas_abs="$rotas_abs$(basename "$brief"):$line $abs"$'\n'
  done < <(grep -onE '/(home|Users)/[A-Za-z0-9_./-]+\.(md|rs|json|py|sh|toml)' "$brief" 2>/dev/null | sort -u -t: -k2)
  while IFS= read -r sk; do
    [ -n "$sk" ] || continue
    [ -e "$REPO/$sk" ] || rotas_skill="$rotas_skill$(basename "$brief"): $sk"$'\n'
  done < <(grep -oE '\.agents/skills/[A-Za-z0-9._-]+/SKILL\.md' "$brief" 2>/dev/null | sort -u)
done
if [ -z "$rotas_abs" ]; then
  ok "toda ruta absoluta que cita un brief existe en esta maquina"
else
  no "toda ruta absoluta que cita un brief existe en esta maquina"
  printf '%s' "$rotas_abs" | sed 's/^/     /'
fi
if [ -z "$rotas_skill" ]; then
  ok "toda skill que cita un brief existe en upstream (.agents/skills/)"
else
  no "toda skill que cita un brief existe en upstream (.agents/skills/)"
  printf '%s' "$rotas_skill" | sed 's/^/     /'
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
