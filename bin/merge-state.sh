#!/usr/bin/env bash
# ------------------------------------------------------------------
# merge-state.sh - state.json se GENERA a partir de los archivos de state/.
#
# POR QUE (2026-11-04): state.json eran 144 KB en un bloque unico (PRs, merges,
# slots, gates, claims, politicas, notas). Nadie lo podia leer entero y las
# escrituras in-place lo dejaban a medio escribir para los crons que lo leen
# (solidcraft-pipeline cada 5 min, solidcraft-gate-queue cada 3 min).
#
# QUE HACE:
#   state/<concepto>.json   la verdad, partida por concepto (meta, prs, slots,
#                            gates, claims, policy, notes)
#   state/manifest.json     que clave vive en que grupo (y en que orden)
#   state/published.sha256   el hash del state.json que genero el ultimo merge
#   state.json              un ARTEFACTO: se arma desde state/ y se reemplaza
#                           atomico (nunca in-place).
#
# COMANDOS:
#   bash bin/merge-state.sh              reconstruye state.json desde state/
#   bash bin/merge-state.sh --check      reconstruye en memoria y COMPARA con
#                                        state.json: sale 0 SOLO si son
#                                        identicos; si difieren sale distinto
#                                        de 0 y dice que se use --split
#   bash bin/merge-state.sh --check --vs FILE
#                                        compara contra FILE (por ejemplo
#                                        logs/state.json.pre-split.bak)
#   bash bin/merge-state.sh --split [--assign CLAVE=GRUPO]
#                                        [--prefer-source|--prefer-artifact]
#                                        reparte state.json de vuelta en
#                                        state/<concepto>.json (adopta cambios
#                                        hechos a mano) y actualiza el manifiesto.
#                                        --assign CLAVE=GRUPO dice en que
#                                        archivo de concepto queda una clave
#                                        NUEVA de primer nivel (si no se dice,
#                                        va a notes.json).
#                                        --prefer-source (el default) gana la
#                                        fuente (state/); --prefer-artifact
#                                        gana el state.json.
#   bash bin/merge-state.sh --list       los grupos y cuantas claves tiene cada uno
#
# REGLAS:
#   - Reemplazo atomico: se escribe un temporal y se hace os.replace. Un
#     lector concurrente ve el estado viejo COMPLETO o el nuevo COMPLETO.
#   - El merge se NIEGA a pisar un state.json que cambio desde el ultimo merge
#     (state/published.sha256 no coincide): eso seria perder una edicion a
#     mano. La salida es `bash bin/merge-state.sh --split --prefer-artifact`,
#     que la adopta.
#   - state/published.sha256 es OBLIGATORIO: sin el, el merge no puede saber
#     si el state.json fue editado a mano desde el ultimo merge, asi que se
#     niega a escribirlo. `--force` lo permite (y lo vuelve a generar).
#   - En un --split, cuando los dos lados dicen cosas distintas, GANA LA
#     FUENTE (state/<concepto>.json): el state.json es un artefacto que se
#     regenera desde state/, y su valor puede ser el viejo. Con
#     --prefer-artifact gana el state.json. Antes de escribir, el --split
#     muestra el diff de lo que va a cambiar.
#   - La variable ORCH_DIR manda (los tests la usan para trabajar en un
#     directorio de mentira).
# ------------------------------------------------------------------
set -uo pipefail
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
export ORCH_DIR

exec python3 - "$@" <<'PY'
import hashlib
import json
import os
import sys
import tempfile

ORCH = os.environ.get("ORCH_DIR") or os.path.expanduser("~/.local/share/solidcraft-orch")
STATE_DIR = os.path.join(ORCH, "state")
STATE_JSON = os.path.join(ORCH, "state.json")
MANIFEST = os.path.join(STATE_DIR, "manifest.json")
PUBLISHED = os.path.join(STATE_DIR, "published.sha256")
MANIFEST_NAME = "manifest.json"
DEFAULT_GROUP = "notes"
# Que lado gana cuando los dos lados dicen cosas distintas.
PREFER_SOURCE = "source"      # la fuente: state/<concepto>.json
PREFER_ARTIFACT = "artifact"  # el artefacto: state.json


def die(msg, code=2):
    sys.stderr.write(f"merge-state: {msg}\n")
    raise SystemExit(code)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        die(f"no existe: {path}")
    except json.JSONDecodeError as e:
        die(f"JSON invalido en {path}: {e}")


def dump(obj):
    # el mismo formato que usa el state.json original (indent=2, sin escapes
    # ASCII): asi lo reconstruido es byte a byte igual a lo que hay ahi.
    return json.dumps(obj, indent=2, ensure_ascii=False)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    try:
        with open(path, "rb") as fh:
            return sha256_bytes(fh.read())
    except OSError:
        return None


def published_hash():
    """El hash del state.json que genero el ultimo merge (o None)."""
    if not os.path.isfile(PUBLISHED):
        return None
    try:
        with open(PUBLISHED, encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def publish_hash(digest):
    write_atomic(PUBLISHED, digest + "\n")


def write_atomic(path, text):
    """Escribe a un temporal en el MISMO directorio y lo renombra (os.replace).
    Un lector concurrente nunca ve un state.json a medio escribir."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".merge-state-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        dfd = os.open(d, os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def stage_files(entradas):
    """Escribe TODO a temporales y devuelve la lista de movimientos.

    entradas: [(ruta_definitiva, texto), ...]

    Nada se toca en el lugar definitivo hasta que TODOS los temporales estan
    escritos: si algo falla (disco lleno, un valor que no se puede
    serializar), el estado real queda como estaba, ENTERO. Los movimientos
    son renombres (os.replace): un lector concurrente nunca ve un archivo a
    medio escribir.
    """
    movs = []
    try:
        for dst, texto in entradas:
            d = os.path.dirname(dst) or "."
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".merge-state-")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(texto)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.chmod(tmp, 0o644)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
            movs.append((tmp, dst))
    except BaseException:
        for tmp, _ in movs:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        raise
    return movs


def aplicar_movimientos(movs):
    """Mueve los temporales a su lugar (renombres) y sincroniza los
    directorios. Los movimientos son rapidos: la ventana en la que el
    estado esta a medias es la de los renombres, no la de las escrituras."""
    dirs = set()
    for tmp, dst in movs:
        os.replace(tmp, dst)
        dirs.add(os.path.dirname(dst) or ".")
    for d in dirs:
        try:
            dfd = os.open(d, os.O_DIRECTORY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass


def concept_files():
    if not os.path.isdir(STATE_DIR):
        die(f"no existe el directorio de estado: {STATE_DIR}")
    return sorted(f for f in os.listdir(STATE_DIR)
                  if f.endswith(".json") and f != MANIFEST_NAME)


def is_concept_file(fname):
    """Un archivo de CONCEPTO es un diccionario de claves de primer nivel.

    En state/ puede haber otros JSON que no son conceptos: el vigilante de
    comentarios (bin/comment_watch.py) escribe state/pending_tasks.json, que
    es una LISTA de tareas pendientes. Un archivo asi no es un concepto: no
    tiene claves de primer nivel y el round-trip (split/check) se debe morir
    con un mensaje claro, no con un TypeError de python a mitad de camino.
    """
    ruta = os.path.join(STATE_DIR, fname)
    try:
        obj = load_json(ruta)
    except Exception:
        return False
    return isinstance(obj, dict)


def parse_manifest(m):
    """Valida un manifiesto y devuelve (manifiesto, grupos, clave->grupo)."""
    groups = m.get("groups")
    if not isinstance(groups, dict) or not groups:
        die("el manifiesto no tiene 'groups'")
    key2group = {}
    for g, keys in groups.items():
        if not isinstance(keys, list):
            die(f"el grupo {g} del manifiesto no es una lista de claves")
        for k in keys:
            if k in key2group:
                die(f"la clave {k} esta en dos grupos ({key2group[k]} y {g})")
            key2group[k] = g
    return m, groups, key2group


def load_manifest():
    return parse_manifest(load_json(MANIFEST))


def rebuild(overrides=None, manifest=None):
    """state/*.json -> dict. Devuelve (datos, avisos).

    El archivo fisico manda: una clave escrita a mano en state/prs.json que no
    esta en el manifiesto se ADOPTA en ese grupo (con aviso). Lo que si es un
    error es el conflicto: la clave esta en el manifiesto pero en OTRO grupo
    que el archivo donde esta.

    overrides: {archivo_de_concepto: objeto}. El contenido que TENDRIA ese
    archivo, todavia no escrito en el disco. Lo usa el --split para calcular
    y VERIFICAR el estado que quedara antes de mover nada.
    manifest: el manifiesto que se va a usar (por defecto, el del disco).
    """
    if manifest is None:
        m, groups, key2group = load_manifest()
    else:
        m, groups, key2group = parse_manifest(manifest)
    data = {}
    avisos = []
    files = [f for f in concept_files() if is_concept_file(f)]
    if overrides:
        # los archivos que el plan va a CREAR todavia no estan en el disco
        for fname in overrides:
            if fname != MANIFEST_NAME and fname not in files:
                files.append(fname)
        files.sort()
    sin_grupo = [f for f in files if f[:-5] not in groups]
    if sin_grupo:
        die("archivo de concepto sin grupo en el manifiesto: " + ", ".join(sin_grupo))
    for fname in files:
        grupo = fname[:-5]
        if overrides is not None and fname in overrides:
            obj = overrides[fname]
        else:
            obj = load_json(os.path.join(STATE_DIR, fname))
        if not isinstance(obj, dict):
            die(f"{fname} no es un objeto JSON")
        for k, v in obj.items():
            declarado = key2group.get(k)
            if declarado is not None and declarado != grupo:
                die(f"la clave {k} esta en {fname} pero el manifiesto la "
                    f"declara en el grupo {declarado}")
            if declarado is None:
                avisos.append(f"la clave {k} no estaba en el manifiesto: se "
                              f"adopta en el grupo {grupo}")
            data[k] = v
    order = [k for k in m.get("order", []) if k in data]
    extra = sorted(k for k in data if k not in order)
    for k in extra:
        avisos.append(f"la clave {k} no estaba en el orden del manifiesto: va al final")
    return {k: data[k] for k in order + extra}, avisos


def canon(v):
    """La forma canonica de un valor JSON.

    Se usa para COMPARAR VALORES, no para guardarlos: en python `True == 1` y
    `1 == 1.0`, pero en JSON son valores distintos. Un --check que compara con
    `!=` de python puede declarar IDENTICO un estado que en realidad cambio.
    sort_keys no importa para el contenido de un objeto JSON (el orden de sus
    claves no es parte del valor); el orden de primer nivel se mira aparte.
    """
    return json.dumps(v, sort_keys=True, ensure_ascii=False)


def diff(rebuilt, ref):
    out = []
    rk, fk = set(rebuilt), set(ref)
    for k in sorted(fk - rk):
        out.append(f"  SOLO en la referencia: {k}")
    for k in sorted(rk - fk):
        out.append(f"  SOLO en lo reconstruido: {k}")
    for k in sorted(rk & fk):
        if canon(rebuilt[k]) != canon(ref[k]):
            out.append(f"  VALOR DISTINTO: {k}")
    return out


def check(args):
    ref_path = STATE_JSON
    i = 0
    while i < len(args):
        if args[i] == "--vs":
            i += 1
            if i >= len(args):
                die("--vs necesita un archivo")
            ref_path = args[i]
        else:
            die(f"opcion desconocida para --check: {args[i]}")
        i += 1
    rebuilt, avisos = rebuild()
    for a in avisos:
        print(f"merge-state: aviso: {a}")
    if published_hash() is None:
        print("merge-state: aviso: no existe state/published.sha256: el merge "
              "normal se va a negar a escribir hasta que se regenere")
    ref = load_json(ref_path)
    d = diff(rebuilt, ref)
    print(f"merge-state: {len(rebuilt)} claves de primer nivel reconstruidas "
          f"desde {len(concept_files())} archivo(s) de state/")
    if d:
        solo_ref = sorted(set(ref) - set(rebuilt))
        solo_rebuilt = sorted(set(rebuilt) - set(ref))
        distintos = sorted(k for k in set(rebuilt) & set(ref)
                            if canon(rebuilt[k]) != canon(ref[k]))
        print(f"merge-state: NO es identico a {ref_path}:")
        for line in d:
            print(line)
        # Que hay que hacer: el detalle de las diferencias y el comando que
        # las resuelve. Sin esto el que lee la salida no sabe si puede
        # arreglarlo con un --split o si hay que tocar un archivo de state/.
        print(f"merge-state: el state.json NO se puede reconstruir desde state/ "
              f"({len(d)} diferencia(s)).")
        if solo_ref:
            print("merge-state: estas claves estan SOLO en el state.json (un "
                  "merge las perderia): " + ", ".join(solo_ref))
        if solo_rebuilt:
            print("merge-state: estas claves estan SOLO en state/ (un merge las "
                  "agrega al state.json: no se pierde nada): "
                  + ", ".join(solo_rebuilt))
        if distintos:
            print("merge-state: estos VALORES difieren entre state/ y el "
                  "state.json (no se puede saber cual es el nuevo): "
                  + ", ".join(distintos))
        print("merge-state: para reconciliar, hay que elegir de que lado queda "
              "el valor:")
        print("merge-state:   si manda state/ (el default del --split): "
              "`bash bin/merge-state.sh --split` (muestra el diff antes de "
              "escribir)")
        print("merge-state:   si manda el state.json: `bash bin/merge-state.sh "
              "--split --prefer-artifact`")
        print("merge-state:   si lo que se quiere es perder la edicion a mano: "
              "`bash bin/merge-state.sh --force` lo pisa con state/.")
        return 1
    with open(ref_path, "rb") as fh:
        raw = fh.read()
    same_bytes = raw == dump(rebuilt).encode("utf-8")
    print(f"merge-state: IDENTICO a {ref_path} "
          f"(mismas claves de primer nivel, mismos valores; "
          f"byte a byte: {'si' if same_bytes else 'no'})")
    return 0


def fmt_val(v, limite=200):
    """Un valor JSON en una linea, para el diff."""
    s = json.dumps(v, ensure_ascii=False, sort_keys=True)
    if len(s) > limite:
        s = s[:limite] + "..."
    return s


def split(args):
    """state.json <-> state/<concepto>.json (reconcilia los dos lados).

    DIRECCION: por defecto GANA LA FUENTE (state/<concepto>.json). El
    state.json es un ARTEFACTO: se regenera desde state/. Cuando los dos
    lados dicen cosas distintas, el valor del state.json puede ser el VIEJO
    (alguien edito state/ y todavia no se regenero el artefacto): escribirlo
    encima del archivo de concepto pierde la edicion mas nueva. Con
    --prefer-artifact gana el state.json (esa es la forma de adoptar una
    edicion a mano del artefacto). Los dos modos se ven: antes de escribir
    se imprime el diff de lo que va a cambiar.

    Lo que NO se pierde en ningun modo:
      - una clave NUEVA de primer nivel (que no esta en el manifiesto) se
        adopta: va a notes.json, o al grupo que diga --assign CLAVE=GRUPO.
      - una clave que existe SOLO en state/ se conserva en su grupo.
    """
    state = load_json(STATE_JSON)
    m, groups, key2group = load_manifest()
    # --assign CLAVE=GRUPO: donde va una clave nueva de primer nivel.
    asigna = {}
    # Que lado gana en un conflicto (None = el default: la fuente).
    prefer = None
    i = 0
    while i < len(args):
        opt = args[i]
        if opt in ("--prefer-source", "--prefer-artifact"):
            nuevo = PREFER_SOURCE if opt == "--prefer-source" else PREFER_ARTIFACT
            if prefer is not None and prefer != nuevo:
                die("--prefer-source y --prefer-artifact se contradicen: "
                    "decidi uno")
            prefer = nuevo
            i += 1
            continue
        if opt == "--assign":
            i += 1
            if i >= len(args):
                die("--assign necesita CLAVE=GRUPO")
            spec = args[i]
        elif opt.startswith("--assign="):
            spec = opt.split("=", 1)[1]
        else:
            die(f"opcion desconocida para --split: {opt}")
        if "=" not in spec:
            die(f"--assign necesita CLAVE=GRUPO, no '{spec}'")
        k, g = spec.split("=", 1)
        k, g = k.strip(), g.strip()
        if not k or not g:
            die(f"--assign necesita CLAVE=GRUPO, no '{spec}'")
        if k not in state:
            die(f"--assign: la clave '{k}' no esta en state.json")
        asigna[k] = g
        i += 1
    if prefer is None:
        prefer = PREFER_SOURCE
    grupos = dict(groups)
    archivos_en_disco = {f[:-5] for f in concept_files() if is_concept_file(f)}
    huerfanas = [k for k in state if k not in key2group]
    if huerfanas:
        # no tienen grupo: van a notes y el manifiesto queda al dia. El aviso
        # dice que conviene moverlas al grupo que les corresponde.
        grupos.setdefault(DEFAULT_GROUP, [])
        for k in huerfanas:
            destino = asigna.get(k)
            if destino is None:
                destino = DEFAULT_GROUP
                print(f"merge-state: aviso: la clave '{k}' no tiene grupo: va a "
                      f"{DEFAULT_GROUP}.json. Para ponerla en otro grupo: "
                      f"--assign {k}=<grupo>")
            else:
                print(f"merge-state: la clave '{k}' va al grupo {destino} "
                      f"(--assign)")
            grupos.setdefault(destino, [])
            grupos[destino].append(k)
            key2group[k] = destino
    groups = grupos
    # lo que ya esta escrito en state/ y NO esta en el state.json: se conserva
    conservadas = {}
    claves_fuente = set()
    for fname in [f for f in concept_files() if is_concept_file(f)]:
        grupo = fname[:-5]
        obj = load_json(os.path.join(STATE_DIR, fname))
        claves_fuente.update(obj.keys())
        extra = [k for k in obj if k not in state]
        if extra:
            conservadas[grupo] = extra
            print("merge-state: aviso: estas claves de state/%s no estan en "
                  "state.json y SE CONSERVAN: %s" % (fname, ", ".join(extra)))
    nuevos = {}
    for grupo in sorted(set(groups) | archivos_en_disco):
        claves = [k for k in state if key2group.get(k) == grupo]
        # las que solo estan en state/ se quedan en su grupo
        for k in conservadas.get(grupo, []):
            if k not in claves:
                claves.append(k)
        # Un grupo con claves se escribe siempre. Un grupo sin claves se
        # escribe SOLO si ya hay un archivo con ese nombre: si no, el archivo
        # queda huerfano en state/ y el manifiesto no lo declara, y el
        # rebuild se muere con "archivo de concepto sin grupo".
        if claves or grupo in archivos_en_disco:
            nuevos[grupo] = claves
    # Que valor gana en cada clave. Solo hay CONFLICTO cuando la clave esta
    # en los dos lados y los valores son distintos.
    conflictos = []
    planes = {}
    for grupo in sorted(nuevos):
        ruta = os.path.join(STATE_DIR, f"{grupo}.json")
        previo = {}
        if os.path.isfile(ruta):
            previo = load_json(ruta)
            if not isinstance(previo, dict):
                die(f"state/{grupo}.json no es un objeto JSON: no se puede "
                    f"partir (seria una escritura a ciegas)")
        obj = {}
        for k in nuevos[grupo]:
            if k in state and k in previo:
                if canon(state[k]) == canon(previo[k]):
                    obj[k] = state[k]      # los dos dicen lo mismo
                    continue
                # CONFLICTO: el state.json puede tener el valor viejo.
                if prefer == PREFER_ARTIFACT:
                    obj[k] = state[k]      # el state.json manda
                    lado = PREFER_ARTIFACT
                else:
                    obj[k] = previo[k]     # la fuente manda (el default)
                    lado = PREFER_SOURCE
                conflictos.append((grupo, k, previo[k], state[k], lado))
            elif k in state:
                obj[k] = state[k]          # clave nueva en este grupo
            elif k in previo:
                obj[k] = previo[k]         # se conserva lo que estaba
        planes[grupo] = obj
    # EL DIFF, ANTES DE ESCRIBIR: el operador tiene que ver que valor se
    # descarta y por que. Un remedio que destruye el dato en silencio no es
    # un remedio.
    if conflictos:
        gana = ("el state.json (--prefer-artifact)" if prefer == PREFER_ARTIFACT
                else "state/ (--prefer-source, el default)")
        print(f"merge-state: {len(conflictos)} clave(s) difieren entre state/ y "
              f"el state.json. GANA {gana}:")
        for grupo, k, v_fuente, v_artefacto, lado in conflictos:
            print(f"  state/{grupo}.json: '{k}'")
            print(f"      state/ (fuente)      : {fmt_val(v_fuente)}")
            print(f"      state.json (artefacto): {fmt_val(v_artefacto)}")
            if lado == PREFER_SOURCE:
                print(f"      -> SE CONSERVA el valor de state/{grupo}.json; el "
                      f"del state.json SE DESCARTA (con --prefer-artifact seria "
                      f"al reves)")
            else:
                print(f"      -> SE ADOPTA el valor del state.json; el de "
                      f"state/{grupo}.json SE DESCARTA (con --prefer-source "
                      f"seria al reves)")
    else:
        print("merge-state: sin conflictos: state/ y el state.json dicen lo "
              "mismo")
    # el orden: primero el del state.json, y al final las claves que solo
    # estan en state/ (las conservadas), para que el merge las reconstruya
    # en el mismo lugar.
    orden = list(state.keys())
    for grupo in sorted(nuevos):
        for k in nuevos[grupo]:
            if k not in orden:
                orden.append(k)
    manifest = {
        "version": 1,
        "generated_at": state.get("updated_at", ""),
        "order": orden,
        "groups": {g: ks for g, ks in nuevos.items()},
    }
    # VERIFICACION, ANTES DE MOVER NADA: el estado que QUEDARA se calcula
    # sobre el plan (sin tocar el disco). Si el plan pierde una clave, no se
    # escribe nada: el estado real sigue entero.
    plan = {f"{grupo}.json": planes[grupo] for grupo in planes}
    esperado, avisos = rebuild(overrides=plan, manifest=manifest)
    for a in avisos:
        print(f"merge-state: aviso: {a}")
    perdidas = sorted(k for k in state if k not in esperado)
    if perdidas:
        die("el --split perderia estas claves del state.json: "
            + ", ".join(perdidas))
    perdidas_fuente = sorted(k for k in claves_fuente if k not in esperado)
    if perdidas_fuente:
        die("el --split perderia estas claves de state/: "
            + ", ".join(perdidas_fuente))
    # El state.json que quedara es el que se reconstruye desde el plan (con
    # el manifiesto nuevo): se calcula ANTES de escribir, asi que se puede
    # stagear junto con los archivos de concepto.
    texto = dump(esperado)
    # TODO a temporales, y recien ahi los movimientos: un crash mientras se
    # escribe no deja el estado a medias (queda el viejo, completo).
    entradas = [(os.path.join(STATE_DIR, f), dump(obj))
                for f, obj in sorted(plan.items())]
    entradas.append((MANIFEST, dump(manifest)))
    entradas.append((STATE_JSON, texto))
    entradas.append((PUBLISHED, sha256_bytes(texto.encode("utf-8")) + "\n"))
    try:
        movs = stage_files(entradas)
    except OSError as e:
        die(f"no se pudo preparar la escritura (no se movio nada): {e}")
    aplicar_movimientos(movs)
    for grupo in sorted(planes):
        print(f"merge-state: state/{grupo}.json <- {len(planes[grupo])} claves")
    print(f"merge-state: manifest actualizado ({len(nuevos)} grupos, "
          f"{len(state)} claves)")
    print(f"merge-state: state.json regenerado desde state/: {len(esperado)} "
          f"claves, {len(texto.encode('utf-8')):,} bytes (reemplazo atomico)")
    if conflictos:
        descartadas = sorted(k for (_g, k, _vf, _va, lado) in conflictos
                             if lado == PREFER_SOURCE)
        if descartadas:
            print(f"merge-state: ATENCION: se descarto el valor del state.json de "
                  f"{len(descartadas)} clave(s): " + ", ".join(descartadas) +
                  ". Si esa edicion a mano era la buena: `bash bin/merge-state.sh "
                  "--split --prefer-artifact` la adopta (y muestra el diff antes "
                  "de escribir).")
    return 0


def write_state(force):
    rebuilt, avisos = rebuild()
    for a in avisos:
        print(f"merge-state: aviso: {a}")
    if os.path.exists(STATE_JSON):
        cur = load_json(STATE_JSON)
        huerfanas = [k for k in cur if k not in rebuilt]
        if huerfanas and not force:
            print("merge-state: state.json tiene claves que NO estan en state/: "
                  + ", ".join(sorted(huerfanas)))
            print("merge-state: no lo piso (se perderian). Para adoptarlas: "
                  "`bash bin/merge-state.sh --split` (la clave nueva va a "
                  "notes.json); si lo que se quiere es perderlas, `--force` lo "
                  "pisa con state/.")
            return 3
        # si state.json cambio desde el ultimo merge, algo lo edito a mano:
        # el merge no pisa eso en silencio.
        pub = published_hash()
        actual = sha256_file(STATE_JSON)
        if pub is None and not force:
            # SIN EL HASH NO HAY GUARDA: sin published.sha256 no se puede
            # saber si el state.json fue editado a mano desde el ultimo
            # merge. La guarda "no pises una edicion a mano" estaria apagada,
            # asi que el merge se niega (y no pisa nada).
            print("merge-state: no existe state/published.sha256: no puedo saber "
                  "si el state.json fue editado a mano desde el ultimo merge, "
                  "asi que NO lo piso.")
            print("merge-state: para regenerarlo: `bash bin/merge-state.sh "
                  "--force` (pisa el state.json con state/ y vuelve a escribir "
                  "el hash) o `bash bin/merge-state.sh --split --prefer-artifact` "
                  "(adopta la edicion a mano y publica el hash nuevo).")
            return 3
        if pub and actual and pub != actual and not force:
            print("merge-state: state.json cambio desde el ultimo merge (el "
                  "hash no coincide con state/published.sha256): no lo piso.")
            print("merge-state: si la edicion a mano es la buena: `bash bin/"
                  "merge-state.sh --split --prefer-artifact` la adopta; si lo que "
                  "manda es state/, `bash bin/merge-state.sh --force` lo pisa.")
            return 3
        cambiado = [k for k in cur if k in rebuilt and cur[k] != rebuilt[k]]
        if cambiado:
            print("merge-state: aviso: estas claves cambian respecto del "
                  "state.json actual: " + ", ".join(sorted(cambiado)))
    texto = dump(rebuilt)
    write_atomic(STATE_JSON, texto)
    publish_hash(sha256_bytes(texto.encode("utf-8")))
    print(f"merge-state: state.json reescrito desde state/: {len(rebuilt)} "
          f"claves, {len(texto.encode('utf-8')):,} bytes (reemplazo atomico)")
    print("merge-state: state/published.sha256 actualizado")
    return 0


def list_groups():
    m, groups, key2group = load_manifest()
    archivos = concept_files()
    print(f"state/: {len(archivos)} archivo(s) de concepto + {MANIFEST_NAME}")
    for grupo in sorted(groups):
        ruta = os.path.join(STATE_DIR, f"{grupo}.json")
        tam = os.path.getsize(ruta) if os.path.isfile(ruta) else 0
        print(f"  {grupo:<12} {len(groups[grupo]):>3} claves  {tam:>7,} bytes")
    return 0


USAGE = ("merge-state.sh [--check [--vs FILE]] "
         "[--split [--assign CLAVE=GRUPO] "
         "[--prefer-source|--prefer-artifact]] [--list] [--force]\n"
         "  (sin opcion) reconstruye state.json desde state/ (reemplazo atomico)\n"
         "  --check sale 0 SOLO si el state.json se reconstruye identico desde "
         "state/;\n"
         "         si difiere sale distinto de 0 y dice que --split lo adopte\n"
         "  --split reparte el state.json de vuelta en state/<concepto>.json\n"
         "         --prefer-source (default) gana state/ (la fuente)\n"
         "         --prefer-artifact gana el state.json (el artefacto)\n"
         "         antes de escribir muestra el diff de lo que va a cambiar")

args = sys.argv[1:]
comando = "write"
if args and args[0] in ("--check", "--split", "--list", "--help", "-h"):
    comando = args[0]
    args = args[1:]

if comando in ("--help", "-h"):
    print(USAGE)
    raise SystemExit(0)
if comando == "--check":
    raise SystemExit(check(args))
if comando == "--split":
    raise SystemExit(split(args))
if comando == "--list":
    raise SystemExit(list_groups())
force = "--force" in args
raise SystemExit(write_state(force))
PY
