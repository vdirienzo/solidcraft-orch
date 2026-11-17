# Brief: mergear GitHub y arrancar con los scripts nuevos (para la maquina del orquestador)

> **Este brief es para el agente de la maquina que tiene la mitad LOOP del orquestador.**
> La otra maquina (la que no tiene ni el LOOP ni los crons) lo leera para poder correr el
> loop en paralelo: esa maquina comparte el arbitro de los claims con esta (GitHub), pero
> tiene su propio estado, sus propios locks y su propia cola de pedidos.
>
> Copiar el brief entero y pegarlo. No hace falta contexto previo.

---

## 1. Que sos y donde estas

Sos el agente de la **maquina del orquestador de SolidCraft**: la que tiene la mitad LOOP
del sistema (`$LOOP_DIR`), los crons instalados con `hermes`, los worktrees por slot y el
estado del loop en disco.

Tu maquina tiene algo que ninguna otra tiene: **la mitad del sistema que no esta en ningun
repo**. Por eso el trabajo de hoy es delicado: hay que adoptar lo nuevo **sin perder lo
que solo esta maquina tiene**.

## 2. Que hay en GitHub

El repo `vdirienzo/solidcraft-orch` tiene **los cambios en `main`**: el PR #1
("The orchestrator stops lying about what it knows") esta mergeado, con 30 commits
y el CI en verde.

```
origin/main   (todo lo de abajo ya esta ahi)
```

La rama `origin/fix/orchestrator-truthfulness` es el origen de esos commits. **No la
borres ni te pongas en ella**: esta mergeada y no cambia nada.

Trae, entre otras cosas:

- `bin/pipeline.py` (el cron de 5 minutos) dejo de mentir: un `gh` que falla ya no es
  "no hay PRs", el verdict se busca por SHA con prefijo, el comentario del verdict es
  idempotente, la lista de PRs no esta truncada a 30.
- `bin/verify-pr.sh` decide el CI por **estado** y no por nombre.
- `bin/claim-verify.sh` es el **unico** arbitro del claim: la union de las dos reglas de
  upstream, con el ruido fuera, las referencias a otro repo fuera, y la regla de que
  nuestros propios PRs no compiten con nosotros.
- `bin/gate.sh` falla (rc=5) si no hay worktree del slot, en vez de compilar el checkout
  principal y escribir un verdict que no describe el cambio.
- `bin/slot-stale.sh` ve los locks en el formato real del productor y no destruye su propia
  senal.
- `bin/merge-state.sh --split` ya no pierde la edicion mas nueva, y `published.sha256` es
  obligatorio.
- `bin/orch-state.sh issue <N>` no crashea mas; `orch-state.sh history` tampoco.
- `bin/comment_watch.py` tiene lock, siembra la primera corrida, distingue a un humano de
  un bot, y la cola de pedidos tiene tope (3 por PR, 12 en total) y deadline.
- `bin/test-all.sh` corre todas las suites; `bin/preflight.sh` dice que falta;
  `bin/crons.txt` es el registro de los crons; `workflow.yaml` esta cruzado con ese registro.
- `briefs/bring-the-loop.md`: como traer la mitad LOOP a este repo.
- `docs/work-at-risk.md`: el trabajo que vive en una sola maquina.

**Ese `briefs/bring-the-loop.md` es la Fase 5 de este prompt.** Hago el merge de las
correcciones **primero** (Fases 1-4, 6-7) y la traida del LOOP **despues** (Fase 5), con
un motivo: las correcciones del repo arreglan cosas que esta maquina esta haciendo mal
**ahora** (el cron de 5 minutos mintiendo, el gate compilando el arbol equivocado), y
eso no puede esperar a que termine un brief largo.

## 3. Lo que cambia en el comportamiento de esta maquina (leelo antes de tocar nada)

Estos son los puntos donde el software nuevo se comporta distinto al viejo. Cada uno es un
riesgo real:

| Cambio | Consecuencia aca |
|---|---|
| `merge-state.sh` **se niega a escribir** sin `state/published.sha256` | el estado deja de regenerarse hasta la migracion de la Fase 3 |
| `pipeline.py` ahora sale con **rc=1** (hubo problemas) o **rc=6** (no se pudo leer) | el cron puede marcar el job como fallido. Hay que ver que hace el wrapper |
| `verify-pr.sh` sale con **rc=6** si no encuentra el validador del upstream | quien lo llame tiene que distinguir 6 de 1 |
| `claim-verify.sh` ahora dice **TAKEN** para issues que antes decia **LIBRES** | va a rechazar trabajo que antes tomaba. Es la correccion (193 competidores), pero el numero de slots baja |
| `gate.sh` sale con **rc=5** si no hay worktree | los slots cuyo worktree esta en `$LOOP_DIR/work` dejan de gatear hasta que se apunte al lugar correcto |
| `orch-state.sh summary` **ya no llama a GitHub** (3m22s -> 9ms) | la seccion "PRs que esperan una respuesta nuestra" ahora es un puntero: `bash bin/slot-stale.sh --prs` |
| el watcher **necesita un cron** que no existe todavia | hasta crearlo (Fase 4), los comentarios del maintainer no se atienden |
| `orch-state.sh issue <N>` sale con **rc=1** si nadie sabe del issue | antes moria con un traceback |

## 4. El orden importa

1. **Parar los crons.** Un cron que corre un script a medio mergear es un script
   corrompido en produccion.
2. **Respaldar.** El estado, los locks, la mitad LOOP y cualquier cambio local del repo.
3. **Mergear** las correcciones.
4. **Migrar** el estado (el `published.sha256`).
5. **Actualizar las copias** de los crons: los crons corren las copias, no el repo.
6. **Traer** la mitad LOOP al repo (el brief).
7. **Verificar.**
8. **Arrancar** de nuevo.

Si algo sale mal en el paso 3 o 4, se vuelve atras con el respaldo. **Los pasos 1 y 2 no se
saltan.**

---

# Fase 1 — Parar y respaldar

```bash
# 1.1 Ver que crons hay, y anotarlo (este listado se usa en la Fase 4 y la 7)
hermes cron list
hermes cron status
hermes cron doctor

# 1.2 Parar los crons: sin esto, uno puede correr un script a medio mergear.
#     El job_id es el de la primera columna de 'hermes cron list'.
hermes cron pause <job_id>          # uno por cron

# 1.3 Respaldar el estado del loop. Es la memoria del sistema.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$HOME/backup/solidcraft-orch-$STAMP"
mkdir -p "$BACKUP"
cp -a "$HOME/.local/share/solidcraft-orch" "$BACKUP/orch"       # state/, locks/, gates/, logs/
cp -a "$HOME/.local/share/solidcraft-loop"  "$BACKUP/loop"       # la mitad LOOP
cp -a "$HOME/.hermes/scripts"             "$BACKUP/hermes-scripts"
echo "el respaldo esta en $BACKUP"
```

**Si `$HOME/.local/share/solidcraft-orch` no existe**, esa maquina no es la del
orquestador: parate y decilo.

```bash
# 1.4 El repo. Si no esta clonado:
if [ ! -d "$HOME/.local/share/solidcraft-orch/.git" ]; then
  git clone https://github.com/vdirienzo/solidcraft-orch.git "$HOME/.local/share/solidcraft-orch"
fi
cd "$HOME/.local/share/solidcraft-orch"

# 1.5 Un cambio local en el repo es TRABAJO. No se descarta nunca.
git status --short
git branch backup/antes-del-merge-$STAMP
git stash push -u -m "antes del merge $STAMP"    # si hay cambios sin commitear
```

**Si `git status` muestra cambios locales**: son trabajo de alguien. Se respaldan con el
`stash` o se commitean en la rama de backup. **No se descartan.** Si son cambios que ya
estaban en el remoto (alguien los pusheo), el merge los trae solo.

## Fase 2 — Mergear lo de GitHub

```bash
cd "$HOME/.local/share/solidcraft-orch"
git fetch origin
git log --oneline -5 origin/main

# El merge va a main: esta maquina corre desde main.
git checkout main
git merge --no-ff origin/main
```

**Si el merge dice que hay conflictos**, la regla es una sola, y es la del repo:

- Un conflicto en un archivo que **el merge cambio** y que ademas esta modificado local:
  gana **el merge** (son correcciones con test). El cambio local quedo en el stash y en
  la rama de backup.
- Un conflicto en un archivo que **solo** esta modificado local: gana **lo local**, y se
  avisa en el informe. Eso es trabajo que nadie mas tiene.

Nunca `git checkout --theirs` a ciegas y nunca `git reset --hard`.

## Fase 3 — Migrar el estado (esto no es opcional)

El `state.json` de esta maquina **fue editado a mano** (los agentes lo actualizan al
terminar cada tarea, asi lo dice el prompt del orquestador). Y ahora `merge-state.sh` exige
`state/published.sha256`, que todavia no existe aca: sin el, **el merge se niega a
escribir**.

```bash
cd "$HOME/.local/share/solidcraft-orch"

# 3.1 Adoptar el state.json editado a mano y generar el hash.
#     --prefer-artifact: gana el state.json (que es el editado a mano).
bash bin/merge-state.sh --split --prefer-artifact

# 3.2 A partir de aca, el estado tiene hash y el merge normal funciona.
bash bin/merge-state.sh --check        # tiene que dar rc=0
```

**El `--split` muestra el diff antes de escribir.** Leelo: si el diff no es el esperado,
**parate** y reportalo. Un `--split` con el default (`--prefer-source`) **descartaria** las
ediciones a mano: ese es exactamente el bug que se corrigio.

## Fase 4 — Las copias de los crons (el paso que hace que serve de nada omitir)

**Los crons no corren los scripts del repo: corren las COPIAS en `~/.hermes/scripts/`.**
Un fix en el repo no llega al cron hasta que la copia se actualiza. Por eso
`bin/preflight.sh` ahora compara cada copia con su script.

```bash
# 4.1 Que crons hay y que script corre cada uno
hermes cron list

# 4.2 Actualizar las copias: el nombre del archivo es el del script del repo.
HERMES="$HOME/.hermes/scripts"
mkdir -p "$HERMES"
REPO="$HOME/.local/share/solidcraft-orch"
for s in gate-queue.sh pipeline.py comment_watch.py nice-compilations.sh \
         ping-ready.sh daily-report.py; do
  [ -f "$REPO/bin/$s" ] && cp "$REPO/bin/$s" "$HERMES/$s" && echo "copiado: $s"
done

# 4.3 La copia del ping-ready tiene que ser IDENTICA (el cron la corre)
diff -q "$HERMES/ping-ready.sh" "$REPO/bin/ping-ready.sh" && echo "ping-ready: identica"

# 4.4 El cron NUEVO del watcher: el maintainer pidio cambios, y no hay nadie que los lea
hermes cron create '*/15 * * * *' \
  --name solidcraft-comment-watch \
  --script comment_watch.py \
  --no-agent --deliver local

# 4.5 El preflight dice que falta
bash bin/preflight.sh
```

Si `preflight.sh` sigue diciendo que falta la mitad LOOP, es lo esperado: es la Fase 5.

## Fase 5 — Traer la mitad LOOP al repo

Este paso tiene su propio brief, que esta en el repo:

**`briefs/bring-the-loop.md`**

Leelo y seguilo. Resumen de lo que hace:

1. Copiar `$LOOP_DIR/bin/*` a `loop/` **sin cambiar el contenido** (commit de movimiento).
2. Parametrizar las rutas: cada ruta absoluta pasa a `ORCH_DIR`/`LOOP_DIR`/... con default.
3. **`claim-race.sh` pasa a ser un shim** que delega en `bin/claim-verify.sh` (que ahora es
   el arbitro, con la regla de upstream) y traduce el exit code: 0 -> 0, 1 -> 10, 2 -> 12.
   El caso 11 (RESOLVED) lo produce el chequeo de "el issue esta abierto?" del publisher, no
   el arbitro. Asi el freno (`claim-brake.sh`) sigue funcionando sin cambios.
4. El rescate (`claim-salvage.sh`): el borrado del worktree pasa **despues** del freno, y
   lo que el agente dejo sin commitear se guarda.
5. El gate (`gate-quick.sh`): los fd 8 y 9 se cierran en cada hijo (el wrapper
   `run_child()`), porque si no un hijo sobreviviente deja el lock tomado y los gates se
   difieren para siempre.
6. El disco (`gc-disk.sh`): un cron/timer que lo corra de verdad, y el sondeo del lock sin
   tomarlo.
7. El preflight y el README: como se instala.

**Antes de la Fase 5, revisá `config.env`**: puede traer secretos. Si los trae, se
versiona una **plantilla** (`config.env.example`) y el real queda fuera de git (el
`.gitignore` ya cubre `.env` y `*.env`).

### Fase 5b — SUBIRLO A GITHUB (sin esto, el trabajo se queda en esta maquina)

El objetivo de traer la mitad LOOP al repo es que **sea de todos**. Si el commit queda
solo en esta maquina, el repo sigue sin el LOOP y la otra maquina no puede correr el
loop. **El push es parte del paso, no una cortesia.**

```bash
cd "$HOME/.local/share/solidcraft-orch"

# Revisar que no haya nada que no deba subir (secretos, estado de maquina)
git status --short
git diff --cached --stat

# Un commit por cosa, en ingles, con el porque en el cuerpo.
git commit -m "orchestrator: the loop half of the orchestrator, versioned" \
           -m "POR QUE: la mitad que publica, arbitra los claims y compila el gate
vivia fuera de git, en \$LOOP_DIR. Un clone del repo no podia publicar, ni gatear,
ni arbitrar, y el repo decia lo contrario."

git push origin main
```

**Que no se suba nunca**: `$ORCH_DIR/state/`, `state.json`, `locks/`, `gates/`, `logs/`,
`targets/` (ya estan en el `.gitignore`), ni ningun `.env` ni `config.env` con secretos.
Revisalo antes de pushear:

```bash
git diff --cached --name-only | grep -E '\.env$|config\.env$|state\.json|^(state|locks|gates|logs|targets)/' \
  && echo "ALTO: eso no debe subir" || echo "ok: no hay estado ni secretos en el commit"
```

## Fase 6 — Verificar

```bash
cd "$HOME/.local/share/solidcraft-orch"

# 6.1 Las suites del repo
bash bin/test-all.sh --fast

# 6.2 El preflight: no falta nada (incluida la mitad LOOP)
bash bin/preflight.sh

# 6.3 Las suites del LOOP, que ahora estan en el repo.
#     ESTE compila Rust: tomá el turno del gate pesado antes.
bash bin/slot-lock.sh --heavy --take --wait 3600
bash loop/bin/test-gate-quick.sh
python3 loop/bin/test-rules.py
bash bin/slot-lock.sh --heavy --release

# 6.4 El grafo y los crons siguen de acuerdo
python3 bin/workflow-validate.py

# 6.5 Las reglas de upstream no envejecieron
SOLIDCRAFT_REPO="$HOME/solidcraft" bash bin/rules-sync.sh

# 6.6 Los briefs apuntan a codigo que existe
SOLIDCRAFT_REPO="$HOME/solidcraft" bash bin/test-briefs.sh

# 6.7 El arbitro del claim: los dos dicen lo mismo
bash bin/test-claim-verify.sh

# 6.8 La maquina esta sana
hermes cron doctor
hermes cron list
```

**Los siete tienen que dar rc=0.** Si alguno falla, **no sigas a la Fase 7**: volvé a la
Fase 1 y reportalo.

## Fase 7 — Arrancar de nuevo

```bash
# 7.1 Reanudar los crons que se pausaron en la Fase 1
hermes cron resume <job_id>        # uno por cron

# 7.2 Mirar que el cron nuevo quedo bien y que los demas corrieron
hermes cron list
hermes cron runs                   # las ultimas ejecuciones

# 7.3 El estado, por partes (NUNCA entero: son 30-144 KB que se reenvian en cada turno)
bash bin/orch-state.sh summary
```

La primera pasada del pipeline puede mostrar problemas: es la primera vez que corre con
la logica nueva. **Miralos y reportalos.** Un cron que sale con rc=1 (hubo problemas) o
rc=6 (no se pudo leer) **no es un crash**: es el codigo nuevo diciendo la verdad.

## 8. Que puede hacer la OTRA maquina con esto (y que no)

Esta seccion es para que sepas que tu trabajo no termina en tu maquina. **La otra maquina
va a correr el loop en paralelo**, y hay que entender que es de cada una.

**Lo que es COMPARTIDO (GitHub):**
- La lista de PRs y el bot de claim del upstream. La regla 5 del repo es un mutex que
  funciona **entre maquinas**: el draft ES el claim, y despues de abrirlo se RE-VERIFICA.
  Si dos maquinas toman el mismo issue, ambas abren draft, ambas re-verifican, y gana la
  de numero menor; la otra cierra su PR y libera su slot. Ese protocolo ya existe y ya
  perdio trabajo una vez (#10134, #10138, #10079) — por eso el draft se abre en el commit
  y no despues del gate.

**Lo que es LOCAL de cada maquina (y no se comparte):**
- El estado (`state/`, `state.json`, `history.jsonl`): los slots, los PRs abiertos, los
  claims. **Cada maquina tiene su propia memoria.** La otra maquina arranca sin estado:
  eso es normal y esta bien.
- Los locks de slot (`$ORCH_DIR/locks/`), los worktrees (`$WORKTREES_DIR/issue-<N>`) y los
  target dirs.
- La cola de pedidos del watcher (`state/pending_tasks.json`) y el tope `MAX_INFLIGHT`.

**Lo que NO hay que hacer para que las dos maquinas no se pisen:**

- **El camino del REPAIR no tiene mutex entre maquinas.** Si el maintainer comenta en un
  PR, las dos maquinas lo ven, las dos encolan el pedido (la clave de la tarea es la misma,
  pero las colas son archivos separados) y las dos lo arreglan. **El arreglo antes de
  tocar nada**: si el PR ya tiene commits que no son tuyos, otro agente ya esta en eso:
  no lo arregles. Es la misma primitiva del claim, aplicada al repair.
- **El gate de las dos maquinas puede compilar el mismo slot.** El lock pesado es local:
  cada maquina tiene el suyo. Se gasta CPU de a mas, pero no se corrompe nada (los target
  dirs son distintos).
- **Los crons de las dos maquinas van a correr los mismos scripts.** El pipeline y el ping
  son idempotentes por head sha (el pipeline busca su marcador en los comentarios del PR; el
  ping tambien), asi que **no** van a duplicar comentarios. Si aun asi ves dos, es un bug:
  reportalo.

## Lo que NO hay que hacer
- **No compiles Rust** para verificar los cambios de shell o python. Las suites no
  compilan. El gate si, y es serializado (un gate a la vez).
- **No dejes un cron corriendo** con un script a medio mergear: por eso la Fase 1 pausa
  primero.
- **No descartes trabajo local**: ni con `git checkout --`, ni con `git reset --hard`, ni
  con `git clean`. El stash y la rama de backup son el seguro.
- **No corras el publisher contra GitHub de verdad** (no abras PRs, no comentes) para
  "probar" que funciona: `agent-issue.sh` publica de verdad.
- **No toques nada de `crates/` ni del repo de SolidCraft**: este trabajo es sobre el
  orquestador, no sobre el CAD.
- **No subas nada al upstream de SolidCraft** (`tangency-labs/solidcraft`): el fork es
  `vdirienzo/solidcraft`.
- **No uses `pkill`, `killall` ni `kill -9`** (maquina compartida: matan gates y crons
  ajenos). Para cortar lo tuyo: guardá el PID y `kill -TERM` solo a ese.
- **No borres los `.bak`**: son de otro trabajo.

## Que devuelves

Un informe, en texto plano, con:

1. **El listado de crons** antes y despues, y cuales se pausaron y cuales se reanudaron.
2. **La ruta del respaldo**, y que se puede volver atras con el.
3. **El merge**: el SHA, los conflictos que hubo (y como se resolvieron), y si quedo
   trabajo local sin commitear (con su stash).
4. **La migracion del estado**: la salida del `--split --prefer-artifact` y el diff que
   mostro, y el rc del `--check`.
5. **La salida de los ocho pasos de verificacion**, con el rc de cada uno.
6. **La Fase 5**: que archivos entraron a `loop/`, si `config.env` traia secretos, y
   **el push a GitHub** (la rama, el commit, y la confirmacion de que se subio).
7. **Lo que rompio o no se pudo hacer**, con el error exacto.
8. **Como queda la maquina**: los crons corriendo, el estado, y que queda pendiente de
   arriba.
9. **Si la otra maquina ya puede correr el loop**: que le falta, segun `bin/preflight.sh`
   corrido desde un clon limpio del repo.

Si algo de este prompt no aplica en esta maquina (un script que no existe, un cron que
no esta instalado, un directorio con otro nombre), **decilo y segui**: no lo inventes ni
lo fuerces. Un paso que se reporta como PENDIENTE es util; uno que se inventa es peor que
no hacer nada.

---

## Nota de la maquina que escribe este brief

El workflow de CI (`.github/workflows/ci.yml`) **todavia no esta en el repo**: GitHub
rechaza cualquier push que cree un archivo de workflow sin el scope `workflow` en el
token. El archivo esta listo y se sube en cuanto el scope este.

**Esto no cambia nada de este brief**: la maquina del orquestador no necesita el CI de
GitHub para funcionar (tiene sus propias suites y su gate local). El CI sirve para que la
*otra* maquina verifique sus cambios sin montar la caja grande.
