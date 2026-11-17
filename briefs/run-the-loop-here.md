# Brief: correr el orquestador desde ESTA maquina (la que no tiene la mitad LOOP)

> **Para el agente de esta maquina.** No es la maquina del orquestador: aqui no esta la
> mitad LOOP (`agent-issue.sh`, `claim-race.sh`, `gate-quick.sh`, `pr-defaults-line.sh`,
> `gc-disk.sh`, `supervisor.sh`, `config.env`). Lo que si esta es la mitad ORCH completa,
> con sus 30 commits de correccion y su CI.
>
> **La regla que manda en este brief: NADA TOCA GITHUB DE VERDAD.** El token de `gh` de
> esta maquina tiene scope `repo`: si el pipeline corre de verdad, edita bodies de PRs
> reales, los pasa a ready y comenta en el upstream. Eso es "publicar de verdad", y el repo
> lo prohibe fuera de una intencion explicita.

---

## 1. Que hay y que falta en esta maquina

| | |
|---|---|
| El repo del orquestador | `/home/user/Projects/solidcraft-orch/solidcraft-orch` (30 commits, `main`) |
| El checkout de SolidCraft | `/home/user/Projects/solidcraft-orch` — **NO** en el path por defecto (`/home/user/solidcraft` no existe) |
| La caja | **12 cores, 15,7 GB de RAM** (9,9 libres). La maquina del orquestador tiene 16/62. **No es la misma caja.** |
| El gateway de hermes | corre (los crons dispararían), pero **no hay ningun job registrado** |
| La mitad LOOP | **no esta** |
| El estado | no existia; se creo en la preparacion de abajo |
| `~/.hermes/scripts/` | no existia (las copias que corren los crons) |
| Compilacion de SolidCraft | **nunca se compilo aqui** (no hay `target/`) |

**El `gh` de esta maquina puede pushear al fork y abrir PRs al upstream.** Por eso el
sandbox.

---

## 2. La preparacion (ya validada, los comandos estan probados)

```bash
# 2.1 ORCH_DIR es la RAIZ DEL REPO: los scripts se buscan entre si por ahi.
#     El default es ~/.local/share/solidcraft-orch, que no existe todavia.
ln -sfn /home/user/Projects/solidcraft-orch/solidcraft-orch ~/.local/share/solidcraft-orch

# 2.2 El checkout de SolidCraft, en el path por defecto.
#     SIN esto, gate.sh y los checks que leen el repo.compile fallan.
sudo ln -sfn /home/user/Projects/solidcraft-orch /home/user/solidcraft

# 2.3 El estado, partido por concepto. EL BOOTSTRAP NO EXISTE: merge-state.sh --split
#     exige un state/manifest.json previo, y sin el se niega (rc=3).
O=~/.local/share/solidcraft-orch
mkdir -p "$O/state"
cat > "$O/state/manifest.json" <<'EOF'
{"version": 1, "generated_at": "", "order": ["slots", "open_prs", "gates", "claims", "abandoned"],
 "groups": {"meta": [], "prs": ["open_prs"], "slots": ["slots"], "gates": ["gates"],
            "claims": ["claims", "abandoned"], "policy": [], "notes": []}}
EOF
cat > "$O/state.json" <<'EOF'
{"slots": {}, "open_prs": [], "gates": {}, "claims": {}, "abandoned": []}
EOF
ORCH_DIR="$O" bash "$O/bin/merge-state.sh" --split
ORCH_DIR="$O" bash "$O/bin/merge-state.sh" --check     # tiene que dar rc=0
```

**Sin el manifest, las claves caen todas en `notes.json`**: el split es util solo si cada
concepto tiene su grupo.

```bash
# 2.4 El `gh` de mentira. FUERA del PATH (regla 4 del repo), se elige con GH_BIN.
#     Ya esta escrito y probado: ~/.local/share/solidcraft-orch-sandbox/gh
#     Devuelve la lista de PRs VACIA y anota cada llamada en $GH_STUB_LOG.
#     Con el, el pipeline no edita bodies, no pasa nada a ready y no comenta nada.
export GH_BIN=~/.local/share/solidcraft-orch-sandbox/gh
export GH_STUB_LOG=/tmp/opencode/gh-calls.log
```

**El sandbox no es opcional: es la diferencia entre "probar" y "publicar".** Con el stub,
la lista de PRs sale vacia y el loop entero recorre su camino sin tocar nada. Si el log de
llamadas muestra algo que no sea una lectura, el sandbox fallo.

---

## 3. La prueba del loop (los comandos ya corrieron y estan verificados)

```bash
export ORCH_DIR=~/.local/share/solidcraft-orch
export GH_BIN=~/.local/share/solidcraft-orch-sandbox/gh
cd "$ORCH_DIR"

bash bin/orch-state.sh summary          # el estado, por partes (nunca entero)
bash bin/slot-lock.sh --slot 1001 --take --owner "prueba-local"
python3 bin/comment_watch.py            # el watcher: ES PYTHON, no bash
python3 bin/pipeline.py                 # el cron de 5 minutos
bash bin/slot-stale.sh --locks --hours 1  # los locks, sin GitHub (9 ms)
bash bin/slot-stale.sh --prs             # lo que espera respuesta nuestra (GitHub)
bash bin/gate.sh 1001 deadbeef           # sin la mitad LOOP tiene que NEGARSE
bash bin/slot-lock.sh --slot 1001 --release
```

**Lo que se espera, y por que:**

| Que | Resultado esperado | Por que |
|---|---|---|
| `orch-state.sh summary` | las secciones, y "PRs que esperan una respuesta nuestra" con un puntero a `--prs` | el summary no llama a GitHub (3m22s -> 9 ms) |
| `slot-lock.sh --take` | rc=0 y `locks/slot-1001/` con `pid`, `since`, `owner` | el lock es un DIRECTORIO con tres archivos |
| `comment_watch.py` | "issues=0 prs=0 / sin delta" | el stub no tiene PRs que seguir |
| `pipeline.py` | "PRs nuestros abiertos: 0 (0 en draft)" y rc=0 | no hay PRs que tocar |
| `slot-stale.sh --locks` | el lock aparece con su dueño y su edad | el formato es el del PRODUCTOR |
| `gate.sh 1001 deadbeef` | **rc=2** y "the gate script is not there" | sin `gate-quick.sh` el gate NO compila el checkout principal |
| el log del stub | solo lecturas | la prueba de que no se toco GitHub |

**El `gate.sh` que se niega con rc=2 NO es un fallo: es el comportamiento correcto.** Es
la mitad LOOP ausente. Lo mismo va a pasar con `publish-pr.sh` (necesita
`pr-defaults-line.sh`).

---

## 4. Los checks de upstream, contra el checkout real

Estos no necesitan la mitad LOOP y son los que miden el proyecto de verdad:

```bash
cd /home/user/solidcraft
cargo xtask layers           # las capas
cargo xtask mesh-decisions   # la regla de la geometria exacta
cargo xtask ui-containers    # un contenedor de UI
cargo xtask lists            # los catalogos ordenados
cargo xtask skills           # el router de AGENTS.md
```

Son analisis estatico: **no compilan nada**. El repo tiene un atajo que los corre todos:
`bash bin/gate-structural.sh` (desde el repo del orquestador).

**La compilacion, con cuidado — esta caja es mas chica que la del orquestador.** El
propio repo dice que el perfil `dev` de siete paquetes llena **66 GB** y que el perfil
`ci` son **1,5 GB**. Con 9,9 GB libres:

```bash
cd /home/user/solidcraft
cut -d' ' -f1 /proc/loadavg      # la carga, antes de una compilación grande
nice -n 19 cargo check --workspace --all-targets --profile ci
```

**No corras `cargo xtask ci` completo en esta caja**: el clippy + el build de tests +
el nextest de 815 paquetes no entran en 9,9 GB. Si hace falta el gate completo, es en
la maquina del orquestador.

---

## 5. Las suites

```bash
cd ~/.local/share/solidcraft-orch
bash bin/test-all.sh --fast              # 16/16
bash bin/test-all.sh --fast --           # (todo)
```

Las 5 que se saltan necesitan la maquina del orquestador (la copia desplegada, los
worktrees, los scripts del LOOP) o el checkout de upstream en el path por defecto — con
el symlink de la Fase 2.2, `test-briefs.sh` corre.

---

## 6. Los crons: por que NO se registran todavia

`hermes cron create` **no tiene `--env`**: los jobs heredan el entorno del gateway, asi
que no se les puede dar un `GH_BIN` de mentira a cada uno. Las copias que corren los
crons viven en `~/.hermes/scripts/` (aun no existe ese directorio).

Por eso el bucle se prueba **a mano**: un cron es `bash <script>` cada N minutos, y
correr el script a mano ejercita el mismo codigo. Registrar los crons con el `gh` real
es el paso en el que el loop empieza a **publicar de verdad**, y eso es una decision de
la persona, no del agente.

**Cuando la persona lo pida**, los crons se registran asi:

```bash
mkdir -p ~/.hermes/scripts
cp bin/{gate-queue.sh,pipeline.py,comment_watch.py,nice-compilations.sh,ping-ready.sh,daily-report.py} ~/.hermes/scripts/
hermes cron create '*/3 * * * *'  --name solidcraft-gate-queue       --script gate-queue.sh       --no-agent --deliver local
hermes cron create '*/5 * * * *'  --name solidcraft-pipeline         --script pipeline.py         --no-agent --deliver local
hermes cron create '*/15 * * * *' --name solidcraft-comment-watch    --script comment_watch.py    --no-agent --deliver local
hermes cron create '*/2 * * * *'  --name solidcraft-nice-compilations --script nice-compilations.sh --no-agent --deliver local
hermes cron create '*/30 * * * *' --name solidcraft-ping-ready       --script ping-ready.sh       --no-agent --deliver local
hermes cron create '0 10,22 * * *' --name solidcraft-reporte-diario --script daily-report.py     --no-agent --deliver local
```

**`comment_watch.py` es Python**: el cron lo corre con el interprete que tenga, pero el
archivo no tiene bit de ejecucion — si el cron lo invoca como `./comment_watch.py`,
falla. Va con `python3 ~/.hermes/scripts/comment_watch.py` o con bit de ejecucion.

`bash bin/preflight.sh` dice si falta algo.

---

## 7. Lo que NO se puede hacer en esta maquina (y por que)

| No se puede | Por que |
|---|---|
| **Publicar un PR de verdad** | el publisher (`agent-issue.sh`) esta en la mitad LOOP, que no esta |
| **Arbitrar claims contra el LOOP** | hay dos reglas hasta que `claim-race.sh` sea un shim de `bin/claim-verify.sh` (brief `bring-the-loop.md`, paso 3) |
| **Gatear de verdad** | `gate-quick.sh` (el que compila) esta en la mitad LOOP |
| **Correr el loop completo con la caja del orquestador** | esta caja tiene 12 cores y 15,7 GB; la otra tiene 16 y 62 |
| **Que el loop_publico de verdad** | seria con el `gh` real, y el token tiene scope `repo` |

---

## 8. Que devuelves

1. **La salida de cada paso de la seccion 3**, con el rc de cada uno, y si se aparto de lo
   esperado, el error exacto.
2. **El log del stub de `gh`**: la prueba de que nada toco GitHub. Si aparece algo que no
   sea una lectura, decilo primero.
3. **La salida de los cinco checks de upstream** de la seccion 4.
4. **El `bin/preflight.sh`**: que falta, con nombre y consecuencia.
5. **Si la compilacion entro en la RAM** o si se comio la caja: el `loadavg` antes y
   despues, y que habria que ajustar.
6. **Lo que quedo hecho y lo que quedo pendiente**, en el formato del informe final del
   repo (que es el mismo de `briefs/adopt-the-new-scripts.md`).

Si algo no se puede hacer en esta maquina, **decilo y segui**. Un paso que se reporta
como PENDIENTE es util; uno que se inventa es peor que no hacer nada.
