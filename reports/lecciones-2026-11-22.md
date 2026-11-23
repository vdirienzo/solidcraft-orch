# Lecciones aprendidas (2026-11-21 / 2026-11-22)

Lo que se rompió en la maquina y que reglas salio de ahi. Todas las cifras de este documento se
midieron en esta maquina el 22-11-2026; la seccion 5 tiene los comandos para volver a mirarlas.

## 1. Que paso

- El loop corria sobre hermes, que no esta instalado: `~/.hermes` no existe, asi que no habia
  ningun cron (la wave no corria, la pipeline solo vivia con una sesion abierta y la cola de
  gates no drenaba) y `bin/dispatch-slot.sh` no arrancaba ni un agente.
- Los slots se acumularon: tres slots "corriendo" sin agente, 53 GB de worktrees y target dirs y
  un PR en draft sin veredicto de gate (la medicion esta en la cabecera de `bin/install-crontab.sh:9`).
- Se reconfiguro: el agente de los slots paso a ser `opencode run` y el planificador paso a ser el
  crontab del usuario, que corre EL SCRIPT DEL REPO y no una copia (`bin/install-crontab.sh`).
- La limpieza del slot (target, worktree, brief, lock) paso del agente al orquestador
  (`bin/close-slot.sh`), porque el agente que borra su worktree mataba el gate de su propio slot.
- El kernel quedo pausado: la ficha del issue lo detecta antes de gastar un agente
  (`bin/issue-card.py`, `bin/prepare-slot.sh` sale con 6).

## 2. Lecciones

Cada leccion trae el hecho medido, por que la regla anterior no lo impedia y la regla que sale de
ahi. Donde la regla ya esta en el codigo, se dice en que archivo vive; donde no, se dice donde
tiene que vivir.

### 2.1 El planificador

**L1. Un planificador que no esta instalado no es un planificador.**

- Que paso: `~/.hermes` no existe (`ls -d ~/.hermes`: No such file or directory). Los crons del
  loop eran jobs de hermes, asi que no habia ninguno: la wave no corria, la pipeline solo
  corria mientras una sesion estaba abierta y la cola de gates no drenaba nunca. Resultado
  medido: tres slots "corriendo" sin agente, 53 GB de worktrees y target dirs y un PR en draft sin
  veredicto de gate (`bin/install-crontab.sh:9-11`).
- Por que la regla anterior no lo impedia: el estado del slot se escribia al despachar, no al
  arrancar el agente. El estado decia "running" con un proceso que no existia, y nada miraba si
  el planificador estaba instalado.
- Regla: **el planificador se instala desde el repo y se comprueba que esta**: el registro es
  `bin/crons.txt` y lo instala `bin/install-crontab.sh`; `bin/preflight.sh` dice que falta.

**L2. Una copia del script del loop falla en silencio y nadie se entera.**

- Que paso: hermes corria COPIAS de los scripts en `~/.hermes/scripts`. La wave estuvo corriendo
  un `wave.sh` de una semana, el que no pusheaba al fork la rama de un slot muerto, y el unico
  aviso era una linea bajo un "todo lo necesario esta" que se lee como un ok
  (`bin/install-crontab.sh:16-19`).
- Por que la regla anterior no lo impedia: no habia ninguna regla que dijera "el cron corre el
  script del repo". La copia es un segundo arbol de codigo, y el segundo arbol no se versiona ni
  se revisa.
- Regla: **el cron corre el script del repo, nunca una copia**: `bin/install-crontab.sh` escribe
  `cd <repo> && /usr/bin/env bash bin/<script>`; si aparece una copia del loop, es un bug.

**L3. Los crons no pueden caer todos en el mismo minuto.**

- Que paso: en la maquina de hermes, diez crons en el mismo minuto abritersen diez escritores
  sobre el SQLite de hermes: "writer mutex unavailable ... held for 12.4s", el bucle de eventos
  del gateway dejo de responder y su watchdog lo mato ("missed 3 consecutive liveness probes ...
  exiting with code 75"). El 20-11 el gateway se reinicio 6 veces y con cada reinicio se cortaron
  los turnos de los agentes ("session turn lease lost") (`bin/crons.txt:30-51`).
- Por que la regla anterior no lo impedia: los horarios se escribieron uno por uno, sin mirar los
  demas.
- Regla: **cada cron tiene sus minutos y ningun par cae en el mismo minuto**. Hoy hay 8 jobs
  (`crontab -l | grep -c 'cd .*solidcraft-orch'` = 8) con los minutos {1,2,3,4,6,8,11,13,14,16,
  17,18,19,21,22,23,27,28,31,32,33,34,36,37,38,41,42,43,44,46,47,48,49,51,52,53,57,58} mas la
  wave (`*/10`); el registro es `bin/crons.txt` y `bin/workflow-validate.py` lo comprueba.

**L4. El PATH del cron no es el PATH de la sesion, y un `.py` corrido con bash no falla: se calla.**

- Que paso: cron arranca los jobs con `PATH=/usr/bin:/bin`, y aca `gh` esta en `~/.local/bin`,
  `opencode` en `~/.opencode/bin` y `cargo` en `~/.cargo/bin`: `claim-verify.sh` respondia ERROR
  en cada pasada, `prepare-slot.sh` no preparaba ningun slot y la wave arrancaba CERO agentes sin
  decir por que (`logs/cron-solidcraft-ping-ready.log`: "gh: command not found"). Y cinco crons de
  Python corridos con `bash` fallaban en cada pasada con "import: command not found"
  (`logs/cron-solidcraft-pipeline.log:217` y siguientes).
- Por que la regla anterior no lo impedia: el bloque del crontab estaba escrito a mano y el
  interprete salia del nombre del archivo por costumbre, no por regla.
- Regla: **el bloque del crontab lleva su PATH y el interprete sale de la extension**
  (`cron_path()` e `interpreter_for()` en `bin/install-crontab.sh`); `bin/preflight.sh` avisa si
  falta el PATH.

**L5. La cola de gates no se traba con un lock de proceso: se traba con `flock`.**

- Que paso: la cola estaba trabada desde el 20-11 17:50 (gate de 19690) porque el lock se
  comprobaba con `pgrep -f gate-queue.sh`, que se encontra a si mismo (la subshell y el `sh -c` del
  cron): `alive` nunca queda vacio y el lock nunca se libera
  (`reports/analisis-orquestador-2026-11-21.md`, §1 #3).
- Por que la regla anterior no lo impedia: se usaba la presencia de un proceso como si fuera un
  candado, y el proceso que busca el lock es el mismo que lo pide.
- Regla: **la cola de gates toma un `flock` sobre `gates/queue.flock`**; si el lock se libera solo
  cuando el proceso muere, el candado tiene que ser del kernel, no del `pgrep`.

### 2.2 El agente

**L6. Un turno sin veredicto es un turno perdido, y el modelo termina cuando quiere.**

- Que paso: el primer agente del brief nuevo (slot 19690) corrio 51 min 12 s (23:10:12 a 00:01:24
  del 21 al 22-11), 33 pasos, $0,048, y termino con "Let me instrument all doc-level boolean
  calls with a backtrace.": nada pusheado, ningun veredicto
  (`bin/agent-turn.sh:5-9`, commit `e092a56`). `opencode run` termina cuando el modelo escribe un
  texto sin llamar a una herramienta, aunque el texto anuncie el paso siguiente.
- Por que la regla anterior no lo impedia: la regla era "el agente responde con un JSON", pero no
  habia nada que empujara al agente a hablar si el turno se terminaba solo.
- Regla: **si la corrida no trae el JSON del veredicto, la MISMA sesion recibe un empujon** con
  la cache caliente (`bin/agent-turn.sh`, `AGENT_NUDGES=2` por defecto) y el brief termina con el
  JSON como unica salida (`prompts/agent-brief.md`).

**L7. El techo de tiempo y la muerte del turno no son un veredicto.**

- Que paso: en 7 dias hubo 10 corridas de agente con 33 % de exito (3 de 9 con veredicto
  `ready`/`waiting`, `reports/daily-2026-11-22-2117.md`). Dos de ellas: #17196 (206 turnos,
  $0,616) y #18344 (308 turnos, $1,26) salieron con rc=124 (techo de tiempo) y #20011 con rc=143
  (SIGTERM), las tres sin veredicto. Los tres slots de la semana: $2,609 y 779 turnos.
- Por que la regla anterior no lo impedia: se media el exito como "PR abierto", no como "veredicto
  con rc"; un turno que muere no deja veredicto y no se ve en ningun sitio.
- Regla: **el veredicto del turno va en el exit code y en el log**: `bin/agent-turn.sh` escribe una
  linea por corrida con `rc` y `veredicto`, y el que informa propaga el rc (README §2, regla 7).

**L8. El agente no es el dueno de la limpieza del slot.**

- Que paso: los briefs viejos mandaban al agente borrar su propio trabajo:
  `prompts/old/agent-19690.md:109-110`, `prompts/old/agent-20011.md:119-120` (y los de 19523,
  19570 y 19749) tenian `rm -rf .../targets/slot-N` y
  `git -C /home/user/Projects/solidcraft-orch/solidcraft-orch worktree remove --force ...`. El gate
  compila en el worktree y en el target, y el pipeline encola ese gate DESPUES de que el agente
  abre el PR: el gate arrancaba sobre un arbol que ya no estaba, se moria con "Could not locate
  working directory" y escribia un veredicto ROJO de un PR sano (PR #20017, 20-11;
  `bin/close-slot.sh:77-111`).
- Por que la regla anterior no lo impedia: la limpieza estaba en el brief, o sea en el prompt del
  agente, y un prompt no es un sitio donde meter una accion con consecuencias para el resto del
  loop.
- Regla: **la limpieza la hace el orquestador, nunca el agente**: `bin/close-slot.sh` borra el
  target, el worktree, el brief y suelta el lock; el brief lo dice ("Do not clean up", punto 7 de
  `prompts/agent-brief.md`).

**L9. Un brief viejo gana sobre la plantilla si el slot se reusa.**

- Que paso: `bin/prepare-slot.sh` reusaba `prompts/agent-<N>.md` si ya existia, asi que los
  briefs viejos seguian mandando lo que la plantilla ya no decia (el `rm -rf` de L8). El arreglo
  esta en el propio script: el brief se genera SIEMPRE desde `prompts/agent-brief.md`
  (`bin/prepare-slot.sh:170-177`).
- Por que la regla anterior no lo impedia: la plantilla era la fuente, pero el fichero ya escrito
  tambien lo era, y el mas viejo ganaba.
- Regla: **el brief sale siempre de la plantilla** (`prompts/agent-brief.md`); los briefs viejos
  quedan en `prompts/old/` como historia y no se usan.

**L10. Un proceso que sobrevive al turno mantiene vivo el slot para siempre.**

- Que paso: el agente del slot 20011 abrio un `python3 -m http.server 8781` para probar el menu
  contextual del navegador y dejo el servidor y su shell vivos al morir (pids 1983725 y 1983723,
  con el cwd en `/home/user/solidcraft-wt/issue-20011/dist/web`, arrancados el 22-11 00:34:04 y
  todavia vivos 20 h 54 min despues). El chequeo de "alguien trabaja en este slot"
  (`bin/slot-busy.sh`, que mira el cwd de los procesos) lo vio VIVO: `logs/cron-solidcraft-wave.log`
  tiene 143 lineas "el slot 20011 esta VIVO (alguien trabaja en el): se lo deja" en 164 pasadas
  de la wave.
- Por que la regla anterior no lo impedia: en `bin/wave.sh` el chequeo de slot vivo esta ANTES
  que la regla de la edad y hace `continue` (`bin/wave.sh:205`), asi que el lock de 240 min
  (`SLOT_LOCK_STALE_MIN`) nunca llega a evaluarse (`bin/wave.sh:294-305`). Y el mata-huerfanos
  (`bin/kill-orphan-browsers.sh`) solo mata el Chrome del MCP, no un servidor http.
- Regla: **el agente cierra lo que abre** (el punto 7 del brief pide cerrar las paginas del
  navegador) **y el chequeo de vida tiene que distinguir el trabajo de un resto**: un proceso
  vivo no puede ser la unica prueba de vida de un slot para siempre.

**L11. El kernel no se compila en esta caja: se aparca antes de gastar el agente.**

- Que paso: el error del issue 19690 era "planar regions: solidcore failed (status 1001)",
  armado con `format!()`, y el grep de la ficha no lo encontraba: la causa es del kernel y el
  agente gastó 51 minutos y $0,048 en ella (commit `e092a56`).
- Por que la regla anterior no lo impedia: el veto de kernel era por titulo y por label, no por
  la causa que nombra el issue.
- Regla: **la ficha del issue decide antes de gastar el agente**: un error que nombra a
  `solidcore` ya es causa del kernel (`bin/issue-card.py`), `bin/prepare-slot.sh` sale con 6 y la
  wave aparca el slot (`parked-kernel`).

### 2.3 El gate, el PR y el disco

**L12. El gate que no es el de upstream da falsos rojos.**

- Que paso: el gate propio (`loop/bin/gate-quick.sh`, nextest con su scope y un baseline de 18
  dias) dio ROJO en el PR #20017 mientras el "Native Linux tests" de upstream pasaba sobre el
  mismo head. Hoy el veredicto que queda para el issue 19523 es ROJO-SCOPE con 6 fallos nuevos de
  `ui-egui` (`state/gates.json`), o sea un rojo real, distinto del falso.
- Por que la regla anterior no lo impedia: el gate propio (`LOCAL_GATE=quick`) decidia que compilar
  y con que features, y su baseline era nuestro, no el de upstream.
- Regla: **el gate es el CI del fork (`GATE_MODE=fork-ci`) o `cargo xtask fast`**; el gate propio
  queda como alternativa (`GATE_MODE=local`, `LOCAL_GATE=fast`) y `bin/gate.sh` exige que el HEAD
  del worktree sea el sha pedido y el arbol limpio.

**L13. Un PR en draft sin el body terminado no lo arregla nadie.**

- Que paso: hay 13 PRs abiertos y 6 en draft (`reports/daily-2026-11-22-2117.md`). El #20933
  lleva 5 h esperando al maintainer con `approved-for-ci` y el CI en verde, pero el pipeline lo
  deja en draft con "falta la linea 'Changes a default:' -> NO la invento" (19 veces seguidas en
  `logs/cron-solidcraft-pipeline.log`, de 16:27 a 17:57). Los otros 5 drafts tienen el CI del fork
  en rojo (3 a 6 jobs: "Build tests", "Native Linux tests", "SolidCore checks (tests)", "ci").
- Por que la regla anterior no lo impedia: el pipeline edita bodies (lo prohibe upstream: `gh pr
  edit --body` vuelve a correr los checks) y el agente abre el draft con el commit del claim, antes
  de tener el trabajo.
- Regla: **el body lo escribe el autor del PR, con la linea `Changes a default:` antes de abrir el
  draft** (punto 1 de `prompts/agent-brief.md`); el pipeline no la inventa (README §4, "El
  pipeline").

**L14. Un target sin dueno no lo borra nadie, y el gc perdona lo que tiene lock.**

- Que paso: `targets/slot-20011` ocupa 83,4 GB (78 GiB con `du -sh`) y `targets/slot-14359` 34,9 GB
  (33 GiB): 111 GiB en `targets/`. El gc de disco tiene un tope de 60 GB y no lo puede cumplir:
  "se conserva .../targets/slot-20011 (tiene un lock vivo)" y "el tope del arbol del
  orquestador no se puede cumplir: todos sus targets estan en uso"; la ultima pasada libero
  0,0 GB y conservo 11 (`logs/cron-solidcraft-gc-disk.log`, `~/.local/share/solidcraft-loop/disk.status`:
  `FREED_GB=0.0`, `SKIPPED=11`). En `/home` quedan 125 GB libres de 421 GB (`df -h /home`).
- Por que la regla anterior no lo impedia: el gc perdona el target si hay un lock vivo, y el lock
  vive mientras el slot figure "running" en el estado; a nadie se le ocurrio medir la EDAD del
  target contra la del slot, y el estado miente (L10).
- Regla: **un target se borra cuando su slot no tiene PR y su lock es viejo, aunque el estado diga
  "running"**: el estado no es la prueba de vida de un slot, los procesos si (y el orden de los
  chequeos en `bin/wave.sh`, y el guardado por lock en `loop/bin/gc-disk.sh`).

**L15. `approved-for-ci` no se pide: se lee.**

- Que paso: el cron `solidcraft-ping-ready` salio del registro el 21-11 (`bin/crons.txt:62-68`) y
  su log se quedo con "gh: command not found" (`logs/cron-solidcraft-ping-ready.log`). La guia de
  upstream dice "Don't ask again and again" y "No status comments", y 6 PRs nuestros esperan al
  maintainer (4 con el label ya puesto; los dos mas viejos, 7,0 y 8,8 dias).
- Por que la regla anterior no lo impedia: el ping estaba en el crontab desde antes de que
  existiera la guia, y el maintainer es el cuello de botella: pedir no es un trabajo.
- Regla: **no se pide `approved-for-ci`**: se lee (`bash bin/ping-ready.sh --report`,
  `bash bin/ci-status.sh <pr>`).

## 3. Lo que quedo SIN resolver

> **Actualizado 2026-11-22 22:00 (orquestador).** Los puntos 1 y 2 ya se resolvieron:
> el huerfano se mato, el PR #20605 (issue #20011) fue MERGED por el maintainer a las
> 07:03Z, el slot se cerro con `bin/close-slot.sh 20011 20605` y el target (79 GB) y el
> worktree (1,1 GB) se fueron. El disco paso de 124 GB libres a 203 GB. Queda la
> CAUSA (que un resto del turno keeps vivo un slot) sin arreglar en el codigo: eso es
> el punto 1, que sigue abierto como regla, no como proceso.

1. **El huerfano que mantiene vivo un slot: RESUELTO, la regla NO.** El `python3 -m
   http.server 8781` (pid 1983725) y su shell (pid 1983723), con el cwd en el worktree
   de 20011, llevaron 20 h 54 min vivos (desde el 22-11 00:34:04) y el `slot-busy.sh`
   lo vio como slot vivo 143 veces en el log de la wave: el lock no se soltaba y los
   79 GB del target no se liberaban. `bin/kill-orphan-browsers.sh` no lo mata: solo ve
   el Chrome del MCP. **Resuelto a mano el 22-11** (kill de los dos pids + cierre del
   slot con `bin/close-slot.sh`, que borro el target y el worktree). **La regla que
   falta**: que es un resto, y a quien le corresponde matarlo. Hoy el reaper de
   navegadores sabe que es un resto (el MCP se fue) pero no sabe nada de los procesos
   que un agente deja tirados (un servidor http, un Xvfb, un `cargo` zombi).
2. **El target del slot 20011 (79 GB): RESUELTO.** El gc lo conservaba porque "tiene un
   lock vivo", y el lock vivia porque el estado decia "running" con un agente muerto.
   Con el huerfano muerto y el PR mergeado, `bin/close-slot.sh` borro el target, el
   worktree y el brief, y libero el lock (203 GB libres de 421 GB). **La regla que
   falta**: la edad del target. El gc tiene tope (`DISK_ORCH_TARGET_MAX_GB`) pero no
   edad, y un target de un slot que murio con su agente se conserva mientras el lock
   exista.
3. **Los 6 drafts con el cuerpo a medio hacer.** El #20933 esta en verde y con
   `approved-for-ci`, y sigue en draft porque le falta la linea `Changes a default:`. El agente
   que lo escribio ya termino y el pipeline no la inventa. Falta decidir quien la escribe: un
   humano, un agente de reparación, o aceptar el PR sin ella.
4. **El ping de `approved-for-ci` que ya no existe.** El cron salio del registro, pero
   `bin/ping-ready.sh` (45 KB) y `bin/test-ping-ready.sh` siguen en el repo, y el log viejo
   (`logs/cron-solidcraft-ping-ready.log`) queda con el error del PATH. Falta decidir si se borran
   o si quedan como lector con otro nombre.
5. **El kernel sigue pausado y no es una decision del repo.** La maquina no compila
   `solidcore/`: `bin/issue-card.py` marca `kernel_cause` y `bin/prepare-slot.sh` sale con 6. Upstream
   si acepta trabajo de kernel; el veto es nuestro, por la caja (15 GB de RAM). Si la maquina
   cambia, el veto se levanta: el veto no es una regla de upstream.
6. **El CI del fork es el gate y depende de una configuracion a mano.** En `vdirienzo/solidcraft`
   hay que habilitar Actions en la web, crear `CI_RUNNER` y `CI_RUNNER_WINDOWS` y dejar solo
   `ci.yml` activo (los otros 16 workflows estan apagados con `gh workflow disable`). Sin eso no
   hay gate: `GATE_MODE=local` compila aca.

## 4. El mapa de las piezas del loop (antes -> ahora)

| Pieza | Antes (hasta el 2026-11-21) | Ahora | Donde vive |
|---|---|---|---|
| Agente | `hermes --in <worktree> -z "<brief>"`, que no esta instalado: la wave no arrancaba ni un agente | `opencode run --standalone --auto --format json --title issue-N -m <modelo> --agent <agente>`, con techo de tiempo y empujones a la misma sesion | `bin/dispatch-slot.sh`, `bin/agent-env.sh`, `bin/agent-turn.sh` |
| Planificador | los jobs de hermes, sobre COPIAS de los scripts en `~/.hermes/scripts` (0 jobs: `~/.hermes` no existe) | el crontab del usuario, instalado desde el registro; 8 jobs, minutos escalonados, cada uno con su log | `bin/install-crontab.sh`, `bin/crons.txt`, `bin/loop-pause.sh` |
| Gate | el gate propio (`loop/bin/gate-quick.sh`: nextest con scope y baseline de 18 dias), que dio un falso rojo en el PR #20017 | `GATE_MODE=fork-ci`: el `ci.yml` de upstream corrido en el fork (`vdirienzo/solidcraft`, solo `ci.yml` activo); en local, `cargo xtask fast --base origin/main` | `bin/pipeline.py`, `bin/fork-ci.sh`, `bin/gate.sh`, `bin/gate-queue.sh` |
| Limpieza | el agente, por pedido del brief (`rm -rf` del target y `git worktree remove --force` del worktree) | el orquestador: target, worktree, brief y lock, y solo si no hay un gate corriendo | `bin/close-slot.sh` (`cleanup_slot()`), `bin/wave.sh` |
| Politica | scripts de hermes y `~/.hermes/scripts` | un solo archivo de politica en la maquina: binario, modelo, nombre del agente, techo, modo del gate, slots y cinturones | `$LOOP_DIR/config.env`, leida por `bin/agent-env.sh` y `bin/slots.sh` |
| Plantilla del brief | un brief por slot, escrito a mano y reusado (los viejos mandaban borrar el worktree) | una sola plantilla, renderizada siempre | `prompts/agent-brief.md`, `bin/prepare-slot.sh` |
| Seleccion | el titulo y las labels | la ficha del issue (`state/cards/<N>.json`): causa, crates y veto de kernel antes de gastar un agente | `bin/issue-card.py`, `bin/next-issue.py` |

## 5. Como volver a medir esto

```bash
crontab -l | grep -c 'cd .*solidcraft-orch'   # jobs del loop (8)
ls -d ~/.hermes                                # hermes: no existe
du -sh targets/*                               # targets por slot (78G + 33G)
ps -eo pid,lstart,etime,args | grep http.server # el huerfano del slot 20011
grep -c "el slot 20011 esta VIVO" logs/cron-solidcraft-wave.log   # 143
bash bin/orch-state.sh                         # slots, PRs y gates
cat reports/latest.md                          # el reporte de las 21:17
```
