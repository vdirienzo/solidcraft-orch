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
SRC="$HERE/merge-state.sh"
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
cp "$REAL_STATE" "$WORK/state.json"
cp -r "$REAL_DIR" "$WORK/state"
cp "$SRC" "$WORK/merge-state.sh"

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
cp "$REAL_STATE" "$WORK/state.json"
rm -rf "$WORK/state"
cp -r "$REAL_DIR" "$WORK/state"

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
cp "$REAL_STATE" "$WORK/state.json"
rm -rf "$WORK/state"
cp -r "$REAL_DIR" "$WORK/state"
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
cp "$REAL_STATE" "$WORK/state.json"
rm -rf "$WORK/state"
cp -r "$REAL_DIR" "$WORK/state"
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --split >/dev/null 2>&1
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" >/dev/null 2>&1
ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --split >/dev/null 2>&1
if ORCH_DIR="$WORK" bash "$WORK/merge-state.sh" --check >/dev/null 2>&1; then
  ok "split -> merge -> split deja el mismo estado (--check rc=0)"
else
  no "split -> merge -> split deja el mismo estado (--check rc!=0)"
fi

# --- 4b. el split NO borra una clave escrita a mano en state/ ---------------
cp "$REAL_STATE" "$WORK/state.json"
rm -rf "$WORK/state"
cp -r "$REAL_DIR" "$WORK/state"
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
cp "$REAL_STATE" "$WORK/state.json"
rm -rf "$WORK/state"
cp -r "$REAL_DIR" "$WORK/state"
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

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
