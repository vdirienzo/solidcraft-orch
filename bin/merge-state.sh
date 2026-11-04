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
#                                        state.json: sale 0 si son identicos
#   bash bin/merge-state.sh --check --vs FILE
#                                        compara contra FILE (por ejemplo
#                                        logs/state.json.pre-split.bak)
#   bash bin/merge-state.sh --split      reparte state.json de vuelta en
#                                        state/<concepto>.json (adopta cambios
#                                        hechos a mano) y actualiza el manifiesto
#   bash bin/merge-state.sh --list       los grupos y cuantas claves tiene cada uno
#
# REGLAS:
#   - Reemplazo atomico: se escribe un temporal y se hace os.replace. Un
#     lector concurrente ve el estado viejo COMPLETO o el nuevo COMPLETO.
#   - El merge se NIEGA a pisar un state.json que cambio desde el ultimo merge
#     (state/published.sha256 no coincide): eso seria perder una edicion a
#     mano. La salida es `bash bin/merge-state.sh --split`, que la adopta.
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


def concept_files():
    if not os.path.isdir(STATE_DIR):
        die(f"no existe el directorio de estado: {STATE_DIR}")
    return sorted(f for f in os.listdir(STATE_DIR)
                  if f.endswith(".json") and f != MANIFEST_NAME)


def load_manifest():
    m = load_json(MANIFEST)
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


def rebuild():
    """state/*.json -> dict. Devuelve (datos, avisos).

    El archivo fisico manda: una clave escrita a mano en state/prs.json que no
    esta en el manifiesto se ADOPTA en ese grupo (con aviso). Lo que si es un
    error es el conflicto: la clave esta en el manifiesto pero en OTRO grupo
    que el archivo donde esta.
    """
    m, groups, key2group = load_manifest()
    data = {}
    avisos = []
    files = concept_files()
    sin_grupo = [f for f in files if f[:-5] not in groups]
    if sin_grupo:
        die("archivo de concepto sin grupo en el manifiesto: " + ", ".join(sin_grupo))
    for fname in files:
        grupo = fname[:-5]
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


def diff(rebuilt, ref):
    out = []
    rk, fk = set(rebuilt), set(ref)
    for k in sorted(fk - rk):
        out.append(f"  SOLO en la referencia: {k}")
    for k in sorted(rk - fk):
        out.append(f"  SOLO en lo reconstruido: {k}")
    for k in sorted(rk & fk):
        if rebuilt[k] != ref[k]:
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
    ref = load_json(ref_path)
    d = diff(rebuilt, ref)
    print(f"merge-state: {len(rebuilt)} claves de primer nivel reconstruidas "
          f"desde {len(concept_files())} archivo(s) de state/")
    if d:
        print(f"merge-state: NO es identico a {ref_path}:")
        for line in d:
            print(line)
        return 1
    with open(ref_path, "rb") as fh:
        raw = fh.read()
    same_bytes = raw == dump(rebuilt).encode("utf-8")
    print(f"merge-state: IDENTICO a {ref_path} "
          f"(mismas claves de primer nivel, mismos valores; "
          f"byte a byte: {'si' if same_bytes else 'no'})")
    return 0


def split():
    """state.json -> state/<concepto>.json (adopta lo editado a mano).

    DIRECCION: el state.json manda para las claves que estan en los dos lados
    (por eso se llama split: uno edito state.json a mano y pide que se adopte).
    Las claves que solo estan en state/ NO se borran: se conservan y se
    avisa. Perder una clave escrita a mano en un archivo de concepto seria
    peor que el problema que este comando viene a resolver.
    """
    state = load_json(STATE_JSON)
    m, groups, key2group = load_manifest()
    huerfanas = [k for k in state if k not in key2group]
    if huerfanas:
        # no tienen grupo: van a notes y el manifiesto queda al dia. El aviso
        # dice que conviene moverlas al grupo que les corresponde.
        groups = dict(groups)
        groups.setdefault(DEFAULT_GROUP, [])
        for k in huerfanas:
            groups[DEFAULT_GROUP].append(k)
            key2group[k] = DEFAULT_GROUP
        print("merge-state: aviso: claves sin grupo, van a "
              f"{DEFAULT_GROUP}.json: " + ", ".join(sorted(huerfanas)))
    # lo que ya esta escrito en state/ y NO esta en el state.json: se conserva
    conservadas = {}
    for fname in concept_files():
        grupo = fname[:-5]
        obj = load_json(os.path.join(STATE_DIR, fname))
        extra = [k for k in obj if k not in state]
        if extra:
            conservadas[grupo] = extra
            print("merge-state: aviso: estas claves de state/%s no estan en "
                  "state.json y SE CONSERVAN: %s" % (fname, ", ".join(extra)))
    nuevos = {}
    for grupo in groups:
        claves = [k for k in state if key2group.get(k) == grupo]
        # las que solo estan en state/ se quedan en su grupo
        for k in conservadas.get(grupo, []):
            if k not in claves:
                claves.append(k)
        if claves:
            nuevos[grupo] = claves
    for grupo, claves in sorted(nuevos.items()):
        ruta = os.path.join(STATE_DIR, f"{grupo}.json")
        previo = {}
        if os.path.isfile(ruta):
            previo = load_json(ruta)
        obj = {}
        for k in claves:
            if k in state:
                obj[k] = state[k]        # el state.json manda
            elif k in previo:
                obj[k] = previo[k]      # se conserva lo que estaba
        write_atomic(ruta, dump(obj))
        print(f"merge-state: state/{grupo}.json <- {len(obj)} claves")
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
    write_atomic(MANIFEST, dump(manifest))
    # lo que se acaba de adoptar es ahora el estado publicado
    publish_hash(sha256_file(STATE_JSON) or "")
    print(f"merge-state: manifest actualizado ({len(nuevos)} grupos, "
          f"{len(state)} claves)")
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
            print("merge-state: no lo piso (se perderian). Corré "
                  "`bash bin/merge-state.sh --split` para adoptar esos cambios, "
                  "o `--force` para pisar de todos modos.")
            return 3
        # si state.json cambio desde el ultimo merge, algo lo edito a mano:
        # el merge no pisa eso en silencio.
        pub = published_hash()
        actual = sha256_file(STATE_JSON)
        if pub and actual and pub != actual and not force:
            print("merge-state: state.json cambio desde el ultimo merge (el "
                  "hash no coincide con state/published.sha256): no lo piso.")
            print("merge-state: si la edicion a mano es la buena, corré "
                  "`bash bin/merge-state.sh --split` para adoptarla; si lo que "
                  "manda es state/, corré con `--force`.")
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


USAGE = ("merge-state.sh [--check [--vs FILE]] [--split] [--list] [--force]\n"
         "  (sin opcion) reconstruye state.json desde state/ (reemplazo atomico)")

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
    raise SystemExit(split())
if comando == "--list":
    raise SystemExit(list_groups())
force = "--force" in args
raise SystemExit(write_state(force))
PY
