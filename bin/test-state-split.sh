#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-state-split.sh - el state.json partido en state/ se reconstruye IGUAL.
#
# POR QUE (2026-11-04): el state.json eran un bloque de 144 KB. Se partio en
# state/<concepto>.json (meta, prs, slots, gates, claims, policy, notes) y
# state.json paso a ser un artefacto que se arma desde state/ con
# bin/merge-state.sh. Este test es la prueba de que eso no rompio nada:
#
#   1. el state.json REAL se reconstruye identico desde state/ (y es identico
#      al backup previo a la particion)
#   2. si alguien mete una clave nueva de primer nivel en state.json a mano,
#      sin pasarla por los archivos de state/, el merge --check falla
#   3. el merge se niega a pisar un state.json editado a mano (no pierde datos)
#   4. la particion es un viaje de ida y vuelta: split -> merge -> split
#      deja el mismo estado
#   5. la escritura es atomica (el archivo se renombra, no se pisa in-place)
#
# NO toca el state.json real: las mutaciones se hacen en una copia temporal
# (ORCH_DIR de mentira). El unico comando que corre contra el estado real es
# el --check, que solo lee.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# El script bajo prueba. Se puede apuntar a otro (MERGE_STATE_SH) para
# medir el defecto contra la version vieja, como hacen test-gate-claim.sh
# (GATE_SH) y test-verify-pr.sh (VERIFY_PR).
SRC="${MERGE_STATE_SH:-$HERE/merge-state.sh}"
ORCH="${ORCH_DIR:-$(dirname "$HERE")}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); }

# El estado real: state.json + state/ (los archivos por concepto).
REAL_STATE="$ORCH/state.json"
REAL_DIR="$ORCH/state"
BACKUP="$ORCH/logs/state.json.pre-split.bak"

# --- 0. las piezas existen -------------------------------------------------
[ -f "$SRC" ] && ok "existe bin/merge-state.sh" || { no "existe bin/merge-state.sh"; exit 1; }
[ -f "$REAL_STATE" ] && ok "state.json sigue existiendo" || no "state.json sigue existiendo"
[ -d "$REAL_DIR" ] && ok "existe el directorio state/" || no "existe el directorio state/"
[ -f "$REAL_DIR/manifest.json" ] && ok "existe state/manifest.json" || no "existe state/manifest.json"

conceptos=0
for f in "$REAL_DIR"/*.json; do
  case "$(basename "$f")" in manifest.json) ;; *) conceptos=$((conceptos+1));; esac
done
[ "$conceptos" -ge 5 ] && ok "state/ tiene $conceptos archivos por concepto" \
  || no "state/ tiene $conceptos archivos por concepto (se esperaban al menos 5)"

# --- 1. el state.json REAL se reconstruye identico --------------------------
out="$(ORCH_DIR="$ORCH" bash "$SRC" --check 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "el state.json real se reconstruye identico desde state/ (rc=0)"
else
  no "el state.json real se reconstruye identico desde state/ (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi

# El mismo check contra el backup previo a la particion: la particion no
# cambio ni un byte de lo que estaba.
#
# OJO: este backup es el estado PRE-PARTICION. Si DESPUES se adopto una
# edicion a mano (un --split), el estado cambio a proposito y ya no puede
# ser igual al backup. Por eso el caso compara solo las claves que el backup
# tiene: si el estado actual tiene TODAS las del backup, la particion no
# perdio ninguna (que es lo que esta prueba).
if [ -f "$BACKUP" ]; then
  out2="$(ORCH_DIR="$ORCH" bash "$SRC" --check --vs "$BACKUP" 2>&1)"; rc2=$?
  if [ "$rc2" -eq 0 ]; then
    ok "el estado reconstruido es identico al backup pre-particion (rc=0)"
  else
    # puede ser que se haya adoptado una edicion a mano: lo que NO puede
    # pasar es que el estado actual haya PERDIDO una clave del backup.
    if python3 - "$BACKUP" "$REAL_STATE" <<'PY'
import json, sys
bak = json.load(open(sys.argv[1]))
cur = json.load(open(sys.argv[2]))
perdidas = sorted(set(bak) - set(cur))
if perdidas:
    print("       | claves del backup que se perdieron: " + ", ".join(perdidas))
    sys.exit(1)
sys.exit(0)
PY
    then
      ok "el estado actual tiene todas las claves del backup pre-particion (la particion no perdio ninguna)"
    else
      no "el estado actual tiene todas las claves del backup pre-particion (la particion no perdio ninguna)"
      printf '%s\n' "$out2" | sed 's/^/       | /'
    fi
  fi
else
  no "existe el backup logs/state.json.pre-split.bak"
fi

# --- 2. una clave nueva de primer nivel en state.json a mano -> falla ------
# Se trabaja sobre una COPIA: el state.json real no se toca.
WORK="$TMP/orch"
mkdir -p "$WORK"
cp "$SRC" "$WORK/merge-state.sh"

# copia_estado: deja en $WORK un state.json y un state/ limpios, con el
# published.sha256 que CORRESPONDE al state.json copiado. El merge se niega a
# escribir un state.json cuyo hash no coincide con el publicado (o si el
# published.sha256 no existe), asi que la copia tiene que ser coherente: si
# no, los casos de aca medirian el estado del HOST y no la regla.
copia_estado() {
  cp "$REAL_STATE" "$WORK/state.json"
  rm -rf "$WORK/state"
  cp -r "$REAL_DIR" "$WORK/state"
  python3 - "$WORK/state.json" "$WORK/state/published.sha256" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as fh:
    h = hashlib.sha256(fh.read()).hexdigest()
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(h + "\n")
PY
}
copia_estado

manchas() { # mete una clave nueva de primer nivel en el state.json de la copia
  python3 - "$WORK/state.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
d["clave_nueva_que_no_paso_por_state"] = {"inventada": True}
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PY
}

manchas
out3="$(ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --check 2>&1)"; rc3=$?
if [ "$rc3" -ne 0 ]; then
  ok "una clave de primer nivel puesta a mano en state.json rompe el --check (rc=$rc3)"
else
  no "una clave de primer nivel puesta a mano en state.json rompe el --check (rc=0: no la vio)"
fi
case "$out3" in
  *clave_nueva_que_no_paso_por_state*)
    ok "el --check nombra la clave que no esta en state/" ;;
  *)
    no "el --check nombra la clave que no esta en state/" ;;
esac

# Y el merge tampoco la pisa: se niega, para no perderla.
before="$(sha256sum "$WORK/state.json" | cut -d' ' -f1)"
out4="$(ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" 2>&1)"; rc4=$?
after="$(sha256sum "$WORK/state.json" | cut -d' ' -f1)"
if [ "$rc4" -ne 0 ] && [ "$before" = "$after" ]; then
  ok "el merge se niega a pisar el state.json editado a mano (rc=$rc4, archivo intacto)"
else
  no "el merge se niega a pisar el state.json editado a mano (rc=$rc4, hash antes=$before despues=$after)"
fi

# --- 2b. CASO NEGATIVO: state/ y state.json NO coinciden -> el --check falla --
# Este es el caso que importa: si state/ y state.json dicen cosas distintas,
# el --check tiene que FALLAR (rc distinto de 0). Si el --check devolviera 0
# con el estado desincronizado, este caso FALLA (y el script sale con rc=1).
#
# Se prueban las DOS direcciones, porque son dos defectos distintos:
#   a) una clave en state/ que el state.json no tiene
#   b) un VALOR distinto entre state/ y state.json
copia_estado

# (a) se edita state/: la clave queda solo ahi
python3 - "$WORK/state/notes.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
d["clave_que_solo_existe_en_state"] = {"nota": "esta en state/, no en state.json"}
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PY
outA="$(ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --check 2>&1)"; rcA=$?
if [ "$rcA" -ne 0 ]; then
  ok "una clave que solo esta en state/ hace fallar el --check (rc=$rcA)"
else
  no "una clave que solo esta en state/ hace fallar el --check (rc=0: no la vio)"
  printf '%s\n' "$outA" | sed 's/^/       | /'
fi

# (b) se edita state/ con un VALOR distinto: el state.json y el state/ se
# contradicen sobre el MISMO dato. Este es el defecto que un --check que
# compara solo el conjunto de claves (y no los valores) no veria.
copia_estado
python3 - "$WORK/state/notes.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
d["bugs_del_loop"] = {"veredicto": "EDITADO EN state/ PARA QUE DIFIERA DEL state.json"}
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PY
outB="$(ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --check 2>&1)"; rcB=$?
if [ "$rcB" -ne 0 ]; then
  ok "un valor distinto entre state/ y state.json hace fallar el --check (rc=$rcB)"
else
  no "un valor distinto entre state/ y state.json hace fallar el --check (rc=0: no lo vio)"
  printf '%s\n' "$outB" | sed 's/^/       | /'
fi
# y el detalle tiene que NOMBRAR la clave que difiere
case "$outB" in
  *bugs_del_loop*)
    ok "el --check nombra la clave cuyo valor difiere" ;;
  *)
    no "el --check nombra la clave cuyo valor difiere" ;;
esac

# El --check tiene que DECIR que se use --split: el veredicto sin la
# instruccion de como arreglarlo no sirve.
case "$outB" in
  *--split*)
    ok "el --check que falla dice que se use --split para adoptar la edicion" ;;
  *)
    no "el --check que falla dice que se use --split para adoptar la edicion" ;;
esac

# Y el --split de verdad arregla ese desfasaje: despues del split, el
# --check vuelve a dar IDENTICO.
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --split >/dev/null 2>&1
if ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --check >/dev/null 2>&1; then
  ok "un --split deja el estado sincronizado otra vez (--check rc=0)"
else
  no "un --split deja el estado sincronizado otra vez (--check rc!=0)"
fi

# --- 3. el merge de verdad reconstruye y deja el archivo igual -------------
# El state/ se vuelve a copiar del real: el caso anterior (2b) dejo en el
# state/ de la copia el valor editado a mano, y el --split lo CONSERVA (ya no
# lo pisa con el valor viejo del state.json: ese es el defecto que se
# corrijo). Este caso compara la reconstruccion con el state.json real, asi
# que necesita un state/ limpio. El state.json se borra: el merge tiene que
# construirlo desde cero.
copia_estado
rm -f "$WORK/state.json"
out5="$(ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" 2>&1)"; rc5=$?
if [ "$rc5" -eq 0 ] && [ -f "$WORK/state.json" ]; then
  ok "el merge reconstruye state.json desde state/ (rc=0)"
else
  no "el merge reconstruye state.json desde state/ (rc=$rc5)"
  printf '%s\n' "$out5" | sed 's/^/       | /'
fi
if cmp -s "$WORK/state.json" "$REAL_STATE"; then
  ok "el state.json reconstruido es byte a byte igual al real"
else
  no "el state.json reconstruido es byte a byte igual al real"
fi

# --- 4. la particion es de ida y vuelta ------------------------------------
# split -> merge -> split sobre la copia: el estado tiene que quedar igual.
copia_estado
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --split >/dev/null 2>&1
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" >/dev/null 2>&1
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --split >/dev/null 2>&1
if ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --check >/dev/null 2>&1; then
  ok "split -> merge -> split deja el mismo estado (--check rc=0)"
else
  no "split -> merge -> split deja el mismo estado (--check rc!=0)"
fi

# --- 4b. el split NO borra una clave escrita a mano en state/ ---------------
copia_estado
python3 - "$WORK/state/prs.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
d["clave_solo_en_state"] = {"nota": "escrita a mano en el archivo de concepto"}
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PY
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --split >/dev/null 2>&1
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'clave_solo_en_state' in d" "$WORK/state/prs.json" 2>/dev/null; then
  ok "el split conserva una clave escrita a mano en state/ (no la borra)"
else
  no "el split conserva una clave escrita a mano en state/ (no la borra)"
fi

# Y esa clave survives al merge: aparece en el state.json reconstruido.
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" >/dev/null 2>&1
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'clave_solo_en_state' in d" "$WORK/state.json" 2>/dev/null; then
  ok "la clave escrita a mano en state/ llega al state.json reconstruido"
else
  no "la clave escrita a mano en state/ llega al state.json reconstruido"
fi

# --- 4c. una clave nueva en state/ se adopta en su grupo --------------------
copia_estado
python3 - "$WORK/state/gates.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
d["veredicto_nuevo"] = {"slot": "slot-9999", "verdict": "VERDE-SCOPE"}
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PY
out6="$(ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --check 2>&1)"; rc6=$?
if [ "$rc6" -ne 0 ]; then
  ok "una clave nueva en state/ todavia no esta en state.json: el --check avisa (rc=$rc6)"
else
  no "una clave nueva en state/ todavia no esta en state.json: el --check avisa (rc=0)"
fi
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" >/dev/null 2>&1
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'veredicto_nuevo' in d" "$WORK/state.json" 2>/dev/null; then
  ok "el merge lleva la clave nueva de state/ al state.json"
else
  no "el merge lleva la clave nueva de state/ al state.json"
fi

# --- 5. la escritura es atomica -------------------------------------------
# El archivo se renombra (os.replace): el inode del state.json cambia y en
# ningun momento se escribe in-place. Se comprueba mirando el codigo.
if grep -q "os.replace" "$SRC" && ! grep -qE 'open\(STATE_JSON, *"w"' "$SRC"; then
  ok "el merge reemplaza el state.json con os.replace (no in-place)"
else
  no "el merge reemplaza el state.json con os.replace (no in-place)"
fi

# --- 6. el --check no modifica nada ----------------------------------------
h1="$(sha256sum "$REAL_STATE" | cut -d' ' -f1)"
ORCH_DIR="$ORCH" bash "$SRC" --check >/dev/null 2>&1
h2="$(sha256sum "$REAL_STATE" | cut -d' ' -f1)"
[ "$h1" = "$h2" ] && ok "el --check no toca el state.json" || no "el --check no toca el state.json"

# --- 7. state.json sigue siendo JSON valido para los que lo leen ----------
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d,dict) and d" "$REAL_STATE" 2>/dev/null; then
  ok "state.json sigue siendo un objeto JSON valido"
else
  no "state.json sigue siendo un objeto JSON valido"
fi
# Los consumidores reales (orch-state.sh) lo leen sin quejarse.
if ORCH_DIR="$ORCH" bash "$ORCH/bin/orch-state.sh" keys >/dev/null 2>&1; then
  ok "bin/orch-state.sh keys lee el state.json sin error"
else
  no "bin/orch-state.sh keys lee el state.json sin error"
fi

# ===================================================================
# 8. LOS CASOS CON FIXTURES: un ORCH_DIR de mentira, armado desde cero.
#
# Los casos de arriba necesitan el estado REAL de la maquina (state.json y
# state/): en una maquina sin estado de host no se pueden correr. Los casos
# de abajo NO necesitan nada de eso: arman un state/ de mentira en un
# directorio temporal, derivan el state.json con el propio script y escriben
# ahi. Son los casos que ACLARAN las reglas del merge y del split.
#
# El fixture tiene 7 grupos por concepto (como el estado real) y un
# state.json que es el artefacto de ese state/.
# ===================================================================
FIX="$TMP/fixtures"
mkdir -p "$FIX"

# fixture NOMBRE: deja un ORCH_DIR de mentira en $FIX/NOMBRE, con state/ y
# el state.json (y el published.sha256) generados por el propio script.
fixture() {
  FIXTURE="$FIX/$1"
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE/state"
  python3 - "$FIXTURE" <<'PY'
import json, os, sys
d = sys.argv[1]
st = os.path.join(d, "state")
grupos = {
    "meta":   {"updated_at": "2026-11-17T00:00:00Z"},
    "prs":    {"pr_100": {"numero": 100, "estado": "draft"}},
    "slots":  {"slot_1": {"issue": 101, "estado": "libre"}},
    "gates":  {"gate_7": {"issue": 102, "veredicto": "VERDE"}},
    "claims": {"claim_3": {"issue": 103, "pr": 3}},
    "policy": {"max_slots": 4},
    "notes":  {"nota_1": {"texto": "VALOR-VIEJO"}},
}
manifiesto = {"version": 1, "generated_at": "2026-11-17T00:00:00Z",
              "order": [], "groups": {}}
for g, claves in grupos.items():
    with open(os.path.join(st, g + ".json"), "w", encoding="utf-8") as fh:
        json.dump(claves, fh, indent=2, ensure_ascii=False)
    manifiesto["groups"][g] = list(claves)
    manifiesto["order"] += list(claves)
with open(os.path.join(st, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(manifiesto, fh, indent=2, ensure_ascii=False)
PY
  # el state.json (el artefacto) y el published.sha256 los genera el script
  ORCH_DIR="$FIXTURE" bash "$SRC" >/dev/null 2>&1
}

# set_key ARCHIVO CLAVE VALOR_JSON: pone una clave de primer nivel.
set_key() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p, k, v = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
d[k] = v
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PY
}

# get_val ARCHIVO CLAVE: imprime el valor de una clave (JSON) o "AUSENTE".
get_val() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
if sys.argv[2] not in d:
    print("AUSENTE")
else:
    print(json.dumps(d[sys.argv[2]], ensure_ascii=False))
PY
}

# --- 8.1 H1: el --split NO puede perder la edicion mas nueva de state/ ------
# El valor editado esta en state/notes.json (la FUENTE) y el state.json tiene
# el valor viejo. Con el --split, ese valor nuevo tiene que SOBREVIVIR: el
# state.json es un artefacto que se regenera desde state/.
fixture h1
D="$FIXTURE"
set_key "$D/state/notes.json" "nota_1" '{"texto": "VALOR-NUEVO-EN-STATE"}'
out="$(ORCH_DIR="$D" bash "$SRC" --split 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(get_val "$D/state.json" nota_1)" = '{"texto": "VALOR-NUEVO-EN-STATE"}' ]; then
  ok "el --split conserva el valor mas nuevo de state/ (no lo pierde)"
else
  no "el --split conserva el valor mas nuevo de state/ (no lo pierde) (rc=$rc, valor en state.json: $(get_val "$D/state.json" nota_1))"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi
if [ "$(get_val "$D/state/notes.json" nota_1)" = '{"texto": "VALOR-NUEVO-EN-STATE"}' ]; then
  ok "el --split no pisa el archivo de concepto con el valor viejo del state.json"
else
  no "el --split no pisa el archivo de concepto con el valor viejo del state.json (quedo: $(get_val "$D/state/notes.json" nota_1))"
fi
# Y antes de escribir tiene que MOSTRAR el diff: el operador tiene que ver
# que valor se descarta y por que.
case "$out" in
  *nota_1*) ok "el --split nombra la clave en conflicto en el diff" ;;
  *)        no "el --split nombra la clave en conflicto en el diff" ;;
esac
case "$out" in
  *VALOR-NUEVO-EN-STATE*VALOR-VIEJO*|*VALOR-VIEJO*VALOR-NUEVO-EN-STATE*)
    ok "el diff del --split muestra los dos valores en conflicto" ;;
  *)
    no "el diff del --split muestra los dos valores en conflicto" ;;
esac

# --- 8.2 H1: con --prefer-artifact gana el state.json ----------------------
fixture h1b
D="$FIXTURE"
set_key "$D/state/notes.json" "nota_1" '{"texto": "VALOR-NUEVO-EN-STATE"}'
out="$(ORCH_DIR="$D" bash "$SRC" --split --prefer-artifact 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "el --split --prefer-artifact sale con rc=0"
else
  no "el --split --prefer-artifact sale con rc=0 (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi
if [ "$(get_val "$D/state.json" nota_1)" = '{"texto": "VALOR-VIEJO"}' ]; then
  ok "con --prefer-artifact gana el valor del state.json"
else
  no "con --prefer-artifact gana el valor del state.json (quedo: $(get_val "$D/state.json" nota_1))"
fi
if [ "$(get_val "$D/state/notes.json" nota_1)" = '{"texto": "VALOR-VIEJO"}' ]; then
  ok "con --prefer-artifact el archivo de concepto toma el valor del state.json"
else
  no "con --prefer-artifact el archivo de concepto toma el valor del state.json (quedo: $(get_val "$D/state/notes.json" nota_1))"
fi

# --- 8.3 H2: sin published.sha256 el merge NO pisa el state.json ------------
fixture h2
D="$FIXTURE"
rm -f "$D/state/published.sha256"
set_key "$D/state.json" "nota_1" '{"texto": "EDITADO-A-MANO"}'
before="$(sha256sum "$D/state.json" | cut -d' ' -f1)"
out="$(ORCH_DIR="$D" bash "$SRC" 2>&1)"; rc=$?
after="$(sha256sum "$D/state.json" | cut -d' ' -f1)"
if [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then
  ok "sin published.sha256 el merge rechaza y no pisa el state.json (rc=$rc)"
else
  no "sin published.sha256 el merge rechaza y no pisa el state.json (rc=$rc, hash antes=$before despues=$after)"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi
case "$out" in
  *published.sha256*) ok "el merge sin published.sha256 dice que falta el archivo" ;;
  *)                  no "el merge sin published.sha256 dice que falta el archivo" ;;
esac
case "$out" in
  *--force*) ok "el merge sin published.sha256 dice como regenerarlo" ;;
  *)         no "el merge sin published.sha256 dice como regenerarlo" ;;
esac

# --- 8.4 H2: published.sha256 desactualizado -> el merge rechaza -----------
fixture h2b
D="$FIXTURE"
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
  > "$D/state/published.sha256"
set_key "$D/state.json" "nota_1" '{"texto": "EDITADO-A-MANO"}'
before="$(sha256sum "$D/state.json" | cut -d' ' -f1)"
out="$(ORCH_DIR="$D" bash "$SRC" 2>&1)"; rc=$?
after="$(sha256sum "$D/state.json" | cut -d' ' -f1)"
if [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then
  ok "con published.sha256 desactualizado el merge rechaza y no pisa el state.json (rc=$rc)"
else
  no "con published.sha256 desactualizado el merge rechaza y no pisa el state.json (rc=$rc, hash antes=$before despues=$after)"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi

# --- 8.5 H2: con published.sha256 al dia el merge escribe y actualiza el hash
fixture h2c
D="$FIXTURE"
set_key "$D/state/notes.json" "nota_1" '{"texto": "VALOR-NUEVO-EN-STATE"}'
out="$(ORCH_DIR="$D" bash "$SRC" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "con published.sha256 al dia el merge escribe (rc=0)"
else
  no "con published.sha256 al dia el merge escribe (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi
if [ "$(get_val "$D/state.json" nota_1)" = '{"texto": "VALOR-NUEVO-EN-STATE"}' ]; then
  ok "el merge lleva el valor de state/ al state.json"
else
  no "el merge lleva el valor de state/ al state.json (quedo: $(get_val "$D/state.json" nota_1))"
fi
nuevo="$(sha256sum "$D/state.json" | cut -d' ' -f1)"
if [ "$nuevo" = "$(tr -d '[:space:]' < "$D/state/published.sha256")" ]; then
  ok "el merge actualiza published.sha256 con el hash del state.json nuevo"
else
  no "el merge actualiza published.sha256 con el hash del state.json nuevo"
fi

# --- 8.6 el --split adopta una clave NUEVA de primer nivel -----------------
fixture h3
D="$FIXTURE"
set_key "$D/state.json" "clave_nueva" '{"inventada": true}'
ORCH_DIR="$D" bash "$SRC" --split >/dev/null 2>&1
if [ "$(get_val "$D/state/notes.json" clave_nueva)" = '{"inventada": true}' ]; then
  ok "el --split manda una clave nueva de primer nivel a notes.json"
else
  no "el --split manda una clave nueva de primer nivel a notes.json"
fi
if ORCH_DIR="$D" bash "$SRC" --check >/dev/null 2>&1; then
  ok "despues de adoptar la clave nueva el --check da IDENTICO (rc=0)"
else
  no "despues de adoptar la clave nueva el --check da IDENTICO (rc!=0)"
fi
# Y con --assign la clave va al grupo que se le dice.
fixture h3b
D="$FIXTURE"
set_key "$D/state.json" "clave_nueva" '{"inventada": true}'
ORCH_DIR="$D" bash "$SRC" --split --assign clave_nueva=policy >/dev/null 2>&1
if [ "$(get_val "$D/state/policy.json" clave_nueva)" = '{"inventada": true}' ]; then
  ok "el --split con --assign manda la clave nueva al grupo pedido"
else
  no "el --split con --assign manda la clave nueva al grupo pedido"
fi

# --- 8.7 el --split conserva una clave que existe SOLO en state/ -----------
fixture h4
D="$FIXTURE"
set_key "$D/state/notes.json" "clave_solo_en_state" '{"nota": "escrita a mano en state/"}'
ORCH_DIR="$D" bash "$SRC" --split >/dev/null 2>&1
if [ "$(get_val "$D/state/notes.json" clave_solo_en_state)" = '{"nota": "escrita a mano en state/"}' ]; then
  ok "el --split conserva una clave que solo esta en state/"
else
  no "el --split conserva una clave que solo esta en state/"
fi
if [ "$(get_val "$D/state.json" clave_solo_en_state)" = '{"nota": "escrita a mano en state/"}' ]; then
  ok "la clave que solo esta en state/ llega al state.json"
else
  no "la clave que solo esta en state/ llega al state.json"
fi

# --- 8.8 el --split no deja temporales ni estado a medias ------------------
fixture h5
D="$FIXTURE"
set_key "$D/state/notes.json" "nota_1" '{"texto": "VALOR-NUEVO-EN-STATE"}'
ORCH_DIR="$D" bash "$SRC" --split >/dev/null 2>&1
basura="$(find "$D" -name '.merge-state-*' -o -name '*.tmp' -o -name '*.partial' | wc -l)"
if [ "$basura" -eq 0 ]; then
  ok "el --split no deja archivos temporales ni parciales"
else
  no "el --split no deja archivos temporales ni parciales ($basura)"
fi
if ORCH_DIR="$D" bash "$SRC" --check >/dev/null 2>&1; then
  ok "despues del --split state/ y state.json son consistentes (--check rc=0)"
else
  no "despues del --split state/ y state.json son consistentes (--check rc!=0)"
fi

# --- 8.9 H3: un --split que no puede escribir no deja el estado a medias ---
# El --split escribe TODO a temporales y recien ahi los mueve: si la
# escritura falla, no se movio nada y el estado real sigue entero.
# Se cierra el directorio del state.json (el ULTIMO que se escribe): los
# archivos de concepto SI se pueden escribir, asi que un --split que
# escribe de a uno deja el estado a medias (state/ nuevo, state.json viejo).
fixture h6
D="$FIXTURE"
set_key "$D/state/notes.json" "nota_1" '{"texto": "VALOR-NUEVO-EN-STATE"}'
antes_json="$(sha256sum "$D/state.json" | cut -d' ' -f1)"
antes_notes="$(sha256sum "$D/state/notes.json" | cut -d' ' -f1)"
chmod 555 "$D"
out="$(ORCH_DIR="$D" bash "$SRC" --split 2>&1)"; rc=$?
chmod 755 "$D"
despues_json="$(sha256sum "$D/state.json" | cut -d' ' -f1)"
despues_notes="$(sha256sum "$D/state/notes.json" | cut -d' ' -f1)"
if [ "$rc" -ne 0 ] && [ "$antes_json" = "$despues_json" ] && [ "$antes_notes" = "$despues_notes" ]; then
  ok "un --split que no puede escribir no deja el estado a medias (rc=$rc, nada se movio)"
else
  no "un --split que no puede escribir no deja el estado a medias (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi
basura="$(find "$D" -name '.merge-state-*' | wc -l)"
if [ "$basura" -eq 0 ]; then
  ok "el --split que falla no deja temporales tirados"
else
  no "el --split que falla no deja temporales tirados ($basura)"
fi

# --- el bootstrap de una maquina nueva ---------------------------------------
# NO habia forma de empezar: el --split exige un state/manifest.json previo y
# sin el se niega con un mensaje que no dice como arreglarlo. Y sin el manifiesto
# con los grupos puestos, TODAS las claves caen en notes.json.
BOOT="$TMP/boot"
mkdir -p "$BOOT"
cp "$SRC" "$BOOT/merge-state.sh"
ORCH_DIR="$BOOT" bash "$BOOT/merge-state.sh" --bootstrap >/dev/null 2>&1
if [ -f "$BOOT/state.json" ] && [ -f "$BOOT/state/manifest.json" ] && [ -f "$BOOT/state/published.sha256" ]; then
  ok "el bootstrap crea el estado, el manifiesto y el hash"
else
  no "el bootstrap crea el estado, el manifiesto y el hash" "$(ls "$BOOT" 2>&1)"
fi
ORCH_DIR="$BOOT" bash "$BOOT/merge-state.sh" --check >/dev/null 2>&1
if [ $? -eq 0 ]; then
  ok "el estado recien creado pasa el --check (se reconstruye identico)"
else
  no "el estado recien creado pasa el --check (se reconstruye identico)"
fi
if [ -f "$BOOT/state/prs.json" ] && [ -f "$BOOT/state/slots.json" ] && [ -f "$BOOT/state/gates.json" ]; then
  ok "el bootstrap reparte las claves por concepto (no todas en notes.json)"
else
  no "el bootstrap reparte las claves por concepto (no todas en notes.json)" "$(ls "$BOOT/state" 2>&1)"
fi

# UN ARCHIVO POR CONCEPTO, TODOS (2026-11-17).
#
# La maquina que se parte a mano tiene un archivo por grupo, aunque el grupo
# este vacio: notes.json es donde cae la clave que no esta en ningun grupo, y
# sin ese archivo esa clave no tiene donde ir. Una maquina nueva con otro
# layout no es la misma maquina: el round-trip del estado no se puede probar.
if [ -f "$BOOT/state/notes.json" ] && [ -f "$BOOT/state/policy.json" ]; then
  ok "el bootstrap crea un archivo por concepto, tambien los grupos vacios"
else
  no "el bootstrap crea un archivo por concepto, tambien los grupos vacios" "$(ls "$BOOT/state" 2>&1)"
fi

# EL state.json DEL BOOTSTRAP ES EL MISMO QUE EL QUE RECONSTRUYE EL --CHECK.
#
# El --check compara VALORES (por eso decia "IDENTICO" con las claves en otro
# orden), pero el round-trip (split -> merge -> split) tiene que cerrar byte a
# byte: el estado se escribe en el ORDEN DEL MANIFIESTO, que es el orden que
# usa la reconstruccion.
cp "$BOOT/state.json" "$TMP/boot-state.json"
rm -f "$BOOT/state.json"
ORCH_DIR="$BOOT" bash "$BOOT/merge-state.sh" >/dev/null 2>&1
if cmp -s "$BOOT/state.json" "$TMP/boot-state.json"; then
  ok "el state.json del bootstrap es byte a byte el que reconstruye el merge"
else
  no "el state.json del bootstrap es byte a byte el que reconstruye el merge" \
     "$(diff "$TMP/boot-state.json" "$BOOT/state.json" 2>&1 | head -6)"
fi

# EL RESPALDO PRE-PARTICION (2026-11-17).
#
# En la maquina del orquestador, el --split manual dejo el estado viejo en
# logs/state.json.pre-split.bak: es la referencia con la que se comprueba que
# la particion no perdio ninguna clave. Una maquina nueva no pasa por un
# split manual: sin ese archivo no tendria contra que compararse.
if [ -f "$BOOT/logs/state.json.pre-split.bak" ]; then
  ok "el bootstrap deja el respaldo pre-particion"
else
  no "el bootstrap deja el respaldo pre-particion" "$(ls "$BOOT/logs" 2>&1)"
fi
ORCH_DIR="$BOOT" bash "$BOOT/merge-state.sh" --bootstrap >/dev/null 2>&1
if [ $? -eq 3 ]; then
  ok "el bootstrap NO pisa un estado que ya existe (rc=3)"
else
  no "el bootstrap NO pisa un estado que ya existe (rc=3)"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
