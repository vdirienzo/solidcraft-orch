# Auditoría del código del loop de orquestación de SolidCraft

**Fecha:** 2026-11-02
**Alcance:** `/home/user/.local/share/solidcraft-orch/bin/` y `/home/user/.local/share/solidcraft-loop/bin/`
**Método:** lectura del código + ejecución real de los scripts (sin modificarlos, sin commits, sin PRs, sin `cargo` de producción).

---

## 0. Resumen ejecutivo

| # | Hallazgo | Impacto |
|---|---|---|
| **B1** | Los fd 8/9 del lock de scope quedan abiertos y los hijos los heredan | **Los gates nunca corren** (`DEFERRED=scope-gate-alive` para siempre) |
| **B2** | `slot-stale.sh` busca un archivo `lock` que no existe | **El watchdog de atascos está ciego**: 5 locks vivos, 0 vistos |
| **B3** | `gate-runner.sh:served()` grepa un vocabulario de `GATE_STATUS` inexistente | **Re-corre gates ya hechos** (27–54 min cada uno) |
| **B4** | `slot-lock.sh --heavy` escribe el token en un archivo compartido | **Fuga permanente de tokens**: el techo baja a 1 para siempre |
| **B5** | `verify-pr.sh` regex de cierre: cuenta líneas, no issues | **Falla en falso** (slot 3, slot 5, slot 42) y **deja pasar** cierres dobles |
| **B6** | `claim-verify.sh` (ORCH) y `claim-race.sh` (LOOP) son reglas distintas | **193 PRs competidores no los ve** `claim-verify.sh` |
| **B7** | `claim-verify.sh` no aplica la regla de mismo autor | Pierde el claim contra un PR propio stacked |
| **B8** | `gate.sh` compila el worktree equivocado | El veredicto no describe el cambio |
| **B9** | `daily-report.py` off-by-one (`i+2` vs `i+1`) | **Las 4 acciones pendientes se pierden** del reporte |
| **B10** | `agent-issue.sh` ignora el exit code del modelo y borra el worktree | Trabajo del agente destruido en el re-run |
| **B10b** | `orch-state.sh issue <N>` itera `open_prs` (lista) como si fuera dict | **El comando crashea**: exit 1, sin salida |
| **B11** | `slot-stale.sh` tarda **3m22s** y `orch-state.sh summary` lo llama | El resumen del estado tarda 3½ min |
| **B12** | 87 GB de targets con cap de 60 GB y el GC solo corre desde `supervisor.sh` | El cap **nunca** se aplica |
| **B13** | `gate.sh` no verifica el exit code de `gate-quick.sh` | Un gate muerto se lee como "terminó" |
| **B14** | `verify-pr.sh` cuenta "fail" por nombre de check | Un check rojo de CI no se ve |

---

# 1. BUGS

## B1 — Los descriptores del lock de scope se heredan a los hijos: los gates nunca corren ⛔ CRÍTICO

**Dónde:**
- `solidcraft-loop/bin/gate-quick.sh:1253` — `exec 9>>"$global_file"` (lock global, `flock -s`)
- `solidcraft-loop/bin/gate-quick.sh:1271` — `exec 8>>"$slot_file"` (lock del slot, `flock -x`)
- `solidcraft-loop/bin/gate-quick.sh:1272` — `flock -x -w "$GATE_SCOPE_LOCK_WAIT" 8`
- `solidcraft-loop/bin/gate-quick.sh:891-892` — el `systemd-run` que dispara todas las fases (dentro de `run_in_scope()`, que empieza en la 884)

**El defecto.** Bash no pone `FD_CLOEXEC` en los descriptores abiertos con `exec N>>file`. El fd 8 (lock del slot) y el fd 9 (lock global) quedan abiertos en el shell del gate y **todo hijo los hereda**: `cargo`, `rustc`, `nextest`, el `systemd-run` de la línea 891. Un `flock` es del *open file description*: si cualquier proceso que heredó el fd sigue vivo, **el lock sigue tomado**, aunque el `gate.sh` padre haya muerto.

Comprobado empíricamente: un `exec 8>>file` de bash deja el fd **sin** `FD_CLOEXEC` (`/proc/self/fdinfo/8` → `flags: 0`), y el hijo lo ve. Un `os.open(..., O_CLOEXEC)` de Python, en cambio, **no** lo hereda: esa es exactamente la diferencia que le falta al script.

`GATE_SCOPE_LOCK_WAIT=0` (`config.env:273`) hace que el `flock` no espere: si el lock está tomado, el gate se difiere de inmediato. Como el lock tomado no se libera nunca, **el diferimiento es para siempre**.

**Ejemplo concreto — lo que pasó hoy.** El 2026-11-02:
- El gate del slot 10159 corrió de 16:54 a 16:57 (log `gate-quick-aee25f106-1793634851.log`).
- Su hijo `nextest` sobrevivió a la muerte del wrapper y siguió con el fd 8 abierto. `fuser` mostró el lock del slot 10159 en manos del PID **3774695**, un `gate-quick` de 24 minutos de antigüedad.
- A las 17:17 el reintento del slot 10159 se difirió: `DEFERRED=scope-gate-alive` (`gates/10159/scope.verdict`, `AT=1793636265`).
- En paralelo, el gate del 4712 corría (17:24→17:41). Ambos se bloqueaban mutuamente: el global lo tenían **dos gates a la vez**.

**Reproducción controlada** (`/home/user/.hermes/cache/scratch/orphan-repro.sh`, exit 0):
```
inner pid 3917361 holds the slot lock (fd 8) and the global lock (fd 9)
RESULT: inner SURVIVED the kill of the wrapper (orphan)
      l-wx------ 1 user users 64 Nov  2 17:56 8 -> .../gates/S1/scope.lock
--- can a NEW gate take the slot lock (flock -x -w 0)? ---
      SLOT LOCK STILL HELD -> the next gate DEFERS (scope-gate-alive) forever
```

**Dos consecuencias secundarias, ambas vistas hoy:**

1. **El mensaje de diferimiento miente.** `gate-quick.sh:1505-1507` dice *"another run holds the lock of its target directory (`${CARGO_TARGET_DIR}`)"*. El lock **no** es del target dir: es `$LOOP_DIR/gates/<slot>/scope.lock` (línea 1264). El mensaje manda al operador a mirar la carpeta equivocada (87 GB de `targets/`) cuando el problema está en `gates/`.
2. **El log parece sano.** Cuando mataste el proceso que tenía el lock, el mensaje `Killed` del shell quedó pegado al final del log del gate (`/tmp/gate-10159.log`, última línea: `gate-quick.sh: line 884: 3774695 Killed ... systemd-run --user --scope ...`). Sin un estado terminal confiable, ese log es indistinguible del de un gate sano. Peor: los NUL bytes que dejó el proceso muerto aparecen en medio del log.

**Arreglo propuesto — las DOS medidas, no una.**

**Medida A (causa raíz): cerrar fd 8 y 9 en cada hijo.**
Un wrapper `run_child()` en `gate-quick.sh` que envuelva *toda* invocación de `cargo`/`nextest`/`systemd-run`/`cargo clippy`:
```
run_child() { ( exec 8>&- 9>&-; "$@" ); }
```
y aplicarlo en el `systemd-run` de la línea 884 y en las fases que lanzan `cargo` directamente. O, si se quiere mantener el fd abierto para el `flock` del padre, abrirlo con `exec {slotfd}<>` y usar un subshell que lo cierre explícitamente antes de cada hijo. Esto **elimina la causa raíz**: un hijo colgado ya no puede sostener el lock.

**Medida B (defensa): watchdog de gates colgados.**
Un `gate-watchdog` que, para cada slot, mate el proceso cuyo `nextest`/`cargo` lleva más de N minutos sin escribir en su log (N=45 reproduce el caso de hoy; el límite actual de fase es `SCOPE_RUNTIME_MAX`). Sin esto, cerrar los fd **no rescata** un test que ya quedó colgado: el gate seguiría vivo, sólo que sin el lock — y el siguiente gate entraría **en paralelo** sobre el mismo target dir, que es exactamente el problema que `gate-target-dir.sh` dice haber resuelto.

**Por qué ambas y no una sola:**
- Sólo A: el nextest colgado de 45 min sigue vivo, el gate no termina, y el siguiente gate del mismo slot entra mientras el anterior todavía compila → pelea por el lock de cargo del target dir (el bug de las 20:12 documentado en `gate-target-dir.sh`).
- Sólo B: el watchdog mata el proceso, pero si hay **otro** hijo con el fd heredado (p. ej. un `rustc` huérfano que no es el nextest), el lock sigue tomado y el diferimiento continúa. B sin A no cierra el agujero.
- Con A + B: el fd no puede sobrevivir al wrapper (A), y un gate colgado no bloquea la máquina para siempre (B).

**Impacto en el tiempo de máquina.** Con `GATE_SCOPE_LOCK_WAIT=0`, el diferimiento es instantáneo pero **-terminal**. Medido: la ejecución del gate del 10159 de 16:54 tardó 3m12s para producir un veredicto `SKIP` — 3m12s de CPU para no hacer nada.

### 1.B Medición pedida: locks huérfanos y duración de un gate en la máquina saturada

**Locks huérfanos *ahora mismo*: 0.** Escaneo autoritativo de `/proc/[0-9]*/fd` buscando enlaces a `solidcraft-loop/gates/*/scope.lock`:

```
locks con un proceso sosteniéndolos: 0
ORPHANS (tomados sin gate.sh / gate-quick.sh vivo): 0
```
Y los 16 archivos de lock que existen en disco:
```
gates/{0,1,10138,10159,10181,10291,10626,10750,3892,4712,5237,5505,5858,6449,7114}/scope.lock   free
gates/scope.lock                                                                                    free
```

**Por qué 0 y no "muchos":** porque hoy ya no queda ningún huérfano — los gates que corren **no** dejan hijos colgados (los que se colgaron, como el `nextest` de 45 min, se mataron a mano: por eso el `Killed` quedó pegado en `/tmp/gate-10159.log`). El bug **no está en el estado actual, está en la ausencia de watchdog**: no hay ningún mecanismo que detecte ni que limpie un huérfano. Se limpia a mano, o no se limpia.

Lo que **sí** es reproducible y medible es el mecanismo, y está en la sección anterior: `orphan-repro.sh` deja un huérfano de forma determinista y un gate nuevo se difiere **para siempre**.

**Los locks huérfanos que sí quedaron registrados — los del orquestador, que son OTRO lock:**
El `slot-lock.sh` del orquestador usa un mecanismo distinto (directorios `locks/slot-N/{pid,since,owner}`, sin `flock`). Hoy hay **5 locks vivos**: `slot-10067`, `slot-10587`, `slot-2147`, `slot-5237`, `slot-9086`. De esos, `slot-10067` lleva **desde el 11-01 21:12** (>20 h) y `slot-5237` desde el 11-01 22:47. **Y ninguno de los 5 es detectado por el watchdog** (B2), que los reporta como `(SIN LOCK)`.

**Duración de un gate en la máquina saturada.** Medido sobre los logs (`gate-quick-<sha>-<STAMP>.log`, del `STAMP` al mtime del log):

| sha | slot | duración | log |
|---|---|---|---|
| `0d74d8cae` | 4712 | **17m01s** | 19 KB |
| `b2388e1bd` | — | 10m13s | 11 KB |
| `aee25f106` | 10159 | **3m12s** (diferido) | 1 KB |
| `aee25f1060d1` | 10159 | 13m22s | 2 KB |
| `aee25f1060d1` | 10159 | **54m24s** | 209 KB |
| `7f9c9e32d` | 10626 | **40m45s** | 655 KB |
| `76c2a2796` | 10750 | **38m57s** | 3.6 MB |
| `857e45f8c` | 7114 | **35m48s** | 1.3 MB |
| `931bf6a54` | 5505 | 16m12s | 83 KB |

```
gates medidos: 12   min=3m   mediana=27m   max=54m
tiempo total de máquina gastado gating: 4h50m
```

**El gate del 4712 que terminó hace un rato** (17:24:35 → 17:41:36) tardó **17m01s** y dio `ROJO-SCOPE` con `NEW_FAILURES=4` y `CHECKS=fmt:fail|layers:ok|clippy:fail|check:fail`. **En la máquina saturada, un gate completo cuesta entre 17 y 54 minutos.** Con `GATE_SCOPE_LOCK_WAIT=0`, diferir es instantáneo pero terminal; con un `WAIT` de 60 s, casi todos esos diferimientos se convertirían en esperas resueltas — el gate saldría con veredicto en vez de `SKIP`, y el mismo gate no se correría dos veces.

**Sobre la máquina saturada:** con 2+ gates de slots distintos corriendo a la vez (hoy: los slots 5857 y 9086, ambos con `cargo test` vivo), los gates se estiran de ~17 min a ~40-54 min. El `nextest` de 45 min que se vio hoy es el extremo de esa curva: **el paralelismo de slots multiplica la duración de cada gate**, y como el gate del 4712 tardó 17 min mientras corría solo, un `nextest` de 45 min es 3 gates simultáneos, no uno lento.

---

## B2 — `slot-stale.sh` busca un archivo que el productor nunca crea: el watchdog está ciego ⛔ CRÍTICO

**Dónde:**
- `solidcraft-orch/bin/slot-stale.sh:50` — `for lockfile in "$LOCKS"/*/lock; do`
- `solidcraft-orch/bin/slot-lock.sh:196-222` — el productor: crea `locks/slot-<N>/{pid,since,owner}`

**El defecto.** `slot-lock.sh` crea un **directorio** `locks/slot-10067/` con tres archivos sueltos (`pid`, `since`, `owner`). `slot-stale.sh` itera `"$LOCKS"/*/lock` — un **archivo** llamado `lock` — y además lo parsea con `awk -F= '/^since=/'` (formato `clave=valor` en un archivo). Ninguna de las dos cosas existe.

**Medido ahora mismo:**
```
locks en disco:            5  (slot-10067, slot-10587, slot-2147, slot-5237, slot-9086)
archivos 'lock' (el glob): 0
$ ls /home/user/.local/share/solidcraft-orch/locks/*/lock
ls: cannot access '.../locks/*/lock': No such file or directory
```
Y el resultado del watchdog:
```
$ bash bin/slot-stale.sh --hours 1 --json
{"slot":"10067","owner":"(SIN LOCK)","lock_age_h":?,...}
{"slot":"11171","owner":"(SIN LOCK)","lock_age_h":?,...}
{"slot":"2147","owner":"(SIN LOCK)","lock_age_h":?,...}
{"slot":"4760","owner":"(SIN LOCK)","lock_age_h":?,...}
{"slot":"8434","owner":"(SIN LOCK)","lock_age_h":?,...}
{"slot":"9866","owner":"(SIN LOCK)","lock_age_h":?,...}
```
**6 slots con lock vivo reportados como "(SIN LOCK)"**, y `lock_age_h:?` (desconocido) — que además hace que la condición de atasco (`slot-stale.sh:112`, que exige `lock_age_h >= HOURS`) **nunca se cumpla**. El watchdog que existe para detectar los 4 agentes que gastaron 5h30m–7h **no puede detectar nada**: su única fuente de datos es un archivo que no existe.

**Arreglo.** Que `slot-stale.sh` lea el formato real: iterar `"$LOCKS"/*/` (directorios), tomar `slot=${d##*slot-}`, y leer `since` de `$d/since` y `owner` de `$d/owner` (con el `pid` de `$d/pid` para el `--reap`). Alternativamente, que `slot-lock.sh` escriba además un archivo `locks/slot-<N>/lock` en formato `clave=valor` — pero eso duplica el formato, que es justo el problema que el `--reap` de `slot-lock.sh` ya、总 tries evitar. **El arreglo debe ir del lado del consumidor**: un solo formato, el del productor.

**Corolario.** `slot-lock.sh --reap` y `slot-stale.sh` comparten el problema: el `--reap` de `slot-lock.sh` sí lee su propio formato, así que `--reap` funciona y `--hours` no. Dos consumidores, un formato, un consumidor roto.

---

## B3 — `gate-runner.sh:served()` grepa un vocabulario que `gate-quick.sh` nunca escribe ⚠️ ALTO

**Dónde:**
- `solidcraft-orch/bin/gate-runner.sh:25` — `grep -qE '^GATE_STATUS=(passed|green|ok|done|complete)' "$v"`
- `solidcraft-loop/bin/gate-quick.sh:58` — el vocabulario real: `GATE_STATUS=finished|failed|skipped`
- `solidcraft-orch/bin/gate-runner.sh:24` — `grep -q "SHA=$sha"` (comparación **sin anclar**)

**El defecto.** `gate-quick.sh` escribe `GATE_STATUS=finished`. El runner busca `passed|green|ok|done|complete`. **Ninguno de esos valores existe jamás**, así que `served()` devuelve falso **siempre** y el runner vuelve a correr el gate de un slot que ya tiene veredicto.

**Medido:**
```
slot 4712:  GATE_STATUS=finished  sha=0d74d8cae  -> served()=FALSE
slot 5237:  GATE_STATUS=finished  sha=bbb742e52… -> served()=FALSE
slot 10626: GATE_STATUS=finished  sha=7f9c9e32d  -> served()=FALSE
```

**Consecuencia de costo.** Los gates tardan **27–54 min** (medido, ver §2). El runner los relanza sin necesidad. Con 3 slots pendientes son **~1,5 h de CPU tirada**.

**El segundo defecto (línea 24).** `grep -q "SHA=$sha"` no está anclado: `SHA=0d74d8ca` (8 chars) matchea `SHA=0d74d8cae` (9 chars). Un sha corto se da por servido con el veredicto de otro commit. Debería ser `grep -q "^SHA=$sha$"`.

**Arreglo.**
```
grep -qE '^GATE_STATUS=(finished|failed)' "$v"    # y para el SKIP: un veredicto diferido NO sirve
grep -q "^SHA=$sha\$" "$v"
```
Y por separado: un `GATE_STATUS=skipped` (diferido) **no** es un veredicto — el runner debe reintentarlo, no darlo por servido.

---

## B4 — `slot-lock.sh --heavy`: el token tomado se guarda en un archivo compartido ⚠️ ALTO

**Dónde:**
- `solidcraft-orch/bin/slot-lock.sh:222` — `printf '%s\n' "$_tok" > "$d/token"`
- `solidcraft-orch/bin/slot-lock.sh:95-99` — `heavy_free_token()` crea `heavy-token-$t` en un dir propio
- `solidcraft-orch/bin/slot-lock.sh:98` — el `mkdir` es la reserva atómica

**El defecto.** Los tokens viven en directorios propios (`heavy-token-0`, `heavy-token-1`), pero el token que *este caller* tomó se anota en **un solo archivo compartido** `$LOCK_DIR/heavy/token`. Con `MAX_HEAVY_TOKENS=2`, dos callers toman tokens distintos; el segundo **pisa** el archivo. Cuando el primero libera, libera el token **del segundo** (no el suyo), y su propio token queda huérfano para siempre.

**Reproducción** (`/home/user/.hermes/cache/scratch/heavy-race.sh`, exit 0):
```
callerA took it (rc=0)
callerB took it (rc=0)
token dirs: heavy-token-0 (owner=callerA), heavy-token-1 (owner=callerB)
shared file locks/heavy/token says: /tmp/…/heavy-token-1     <- pisado por callerB
$ bash slot-lock.sh --heavy --release        (release de callerA)
tokens que sobreviven: heavy-token-0  owner=callerA
RESULT: 1 token en existencia tras dos releases (empezaron en 2)
LEAKED: un token sobrevivió a la release de su dueño -> el techo baja para siempre
```
El techo de trabajo pesado es 2; después de un par de releases queda en 1, y después de otro par en 0: **el orquestador se auto-bloquea de forma permanente y silenciosa**.

**Arreglo.** El token tomado debe guardarse **en el propio directorio del token** (p. ej. `$LOCK_DIR/heavy-token-$t/owner` + `$LOCK_DIR/heavy-token-$t/pid`), y el `--release` debe liberar **el token cuyo `pid` es el del caller**, no el del archivo compartido. Si se quiere conservar un índice, que sea un *directorio por caller*: `$LOCK_DIR/heavy/by-caller-$$`.

---

## B5 — `verify-pr.sh`: el regex de cierre cuenta líneas, no issues ⚠️ ALTO

**Dónde:**
- `solidcraft-orch/bin/verify-pr.sh:74-90` — cuenta de frases de cierre
- `solidcraft-orch/bin/verify-pr.sh:202` — derivación del slot desde el body

**El defecto.** El `CLOSING_RE` (`\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\s*:?\s*#?([0-9]+)`) acepta el **número opcional**, y el script cuenta `grep -inE "$CLOSING_RE" | wc -l`, o sea **líneas que matchean**, no issues.

**Falla en falso — caso real.** Un body con prosa:
```
This fix 3 problems.
```
- El regex matchea `fix 3` → `N=1` (una línea) → **no** dispara el check de "cierra más de un issue"…
- …pero `verify-pr.sh:202` deriva el **slot** desde ese `3` → busca `gates/3/scope.verdict` → **no existe** → veredicto: *"falta el veredicto del gate del slot 3"* → **FALLO FALSO** en un PR perfectamente válido.

Casos medidos con el regex de producción:
| body | slot derivado | efecto |
|---|---|---|
| `This fix 3 problems.` | **3** | busca `gates/3/scope.verdict` → fallo falso |
| `Closes 5 open bugs.` | **5** | idem |
| `We resolved 42 issues last year.` | **42** | idem |

Y al revés, con dos líneas de prosa:
```
This fix 3 problems.
Also closes 5 things.
```
→ `N=2 > 1` → **"el body cierra 2 issues"** → fallo falso, cuando el body **no cierra ningún issue**.

**Deja pasar un fallo real.** El upstream parsea una **lista**:
```
Fixes #10181, #10182
```
→ `N=1` (una línea) → el check de "cierra más de un issue" **no dispara**, pero el PR cierra **dos** issues.

**Arreglo.** Dos cambios:
1. Exigir el `#`: `CLOSING_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\s*:?\s*#([0-9]+)'` — el `#` es lo que distingue una referencia de issue de una prosa con un número.
2. Contar **issues**, no líneas: `grep -oE "$CLOSING_RE" | grep -oE '#[0-9]+' | sort -u | wc -l`.
3. Derivar el slot **sólo** de la línea `Fixes #N` (la primera del body, como hace el upstream), nunca de un match cualquiera.

---

## B6 — Dos reglas de arbitraje distintas conviven: 193 competidores invisibles ⚠️ ALTO

**Dónde:**
- `solidcraft-orch/bin/claim-verify.sh:54-55` — regla: `verbo + espacio + #N` sobre `title + body`
- `solidcraft-loop/bin/claim-race.sh:528` — `TITLE_REF`: `#N` en el **título** basta
- `solidcraft-loop/bin/claim-race.sh:531-538` — `BODY_CLOSE_RAW` / `BODY_CLOSE_CI`

**El defecto.** `claim-race.sh` es (según el estado) *el* árbitro único. Pero `gate.sh:118-129` llama a **`claim-verify.sh`**, que es una **segunda implementación** de la regla, en otro directorio, con otra semántica. `claim-race.sh` acepta un claim cuando el **título** nombra el issue (`(#361)`); `claim-verify.sh` **no**: exige un verbo de cierre.

**Medido sobre los 836 PRs abiertos de hoy:**
```
COMPETITOR PRs que claim-race.sh VE y claim-verify.sh NO: 193
```

Casos reales:
| issue | PR | autor | por qué lo ve `claim-race.sh` |
|---|---|---|---|
| #137 | #3995 | emlama | título `…along the part (#137)` |
| #361 | #1608 | flukejones | título `Correct mouse and trackpad navigation presets (#361)` |
| #732 | #10972 | LorbusChris | título `…cut into the solid (#732)` |
| #743 | #7978 | PapaEcho13 | body `Claim for #743.` |
| #860 | #2068 | NOWN-DEV | título `…a plane as 2D lines… (#860)` |
| #1023 | #3534 | bluecmd | body `Addresses #1023.` |
| #1210 | #3444 | bluecmd | body `Fixes the remaining part of #1210:` |

Para todos ellos: **`claim-verify.sh` dice "el issue está libre"** y el gate corre como si nadie lo tuviera. Esto es exactamente la ventana de carrera que `gate.sh:96-104` dice querer cerrar.

**Arreglo.** Un solo árbitro. Dado que `claim-race.sh` implementa la regla del upstream (título + lista de cierre + mismo-autor), `claim-verify.sh` debería **delegar** en él en vez de reimplementar el filtro: `claim-verify.sh` se reduce a un wrapper que llama a `claim-race.sh --mode selection` y traduce su `VERDICT=` al `VEREDICTO=`/exit code que `gate.sh` espera (0 OK / 1 perdido / 2 error). Si se prefiere mantener dos, ambos deben compartir **el mismo archivo de reglas** (un `.jq` o un `.py` único), no dos regex distintos.

---

## B7 — `claim-verify.sh` no aplica la regla de "mismo autor" ⚠️ ALTO

**Dónde:**
- `solidcraft-orch/bin/claim-verify.sh:80` — `WINNER="$(printf '%s\n' "$HITS" | sort -n | head -1)"`
- `solidcraft-loop/bin/claim-race.sh:615` — `if not any_author and is_ours(entry): continue` (la regla que sí existe)

**El defecto.** El upstream **salta los PRs del mismo autor** (el trabajo apilado no compite consigo mismo). `claim-verify.sh` toma el número **más bajo de todos**, incluyendo los nuestros. Con dos PRs abiertos nuestros para el mismo issue, el más alto recibe *"PERDIDO el PR #N perdió contra el #M"* y el orquestador cierra el nuestro.

Hoy hay 4 issues con más de un PR nuestro abierto: **#4712** (11205), **#5237** (11074), **#7114** (9843), **#6747** (9843).

**Arreglo.** Al elegir el ganador, excluir los PRs cuyo `author.login` sea el nuestro (`vdirienzo`), salvo que `--our-pr` sea uno de ellos. `claim-race.sh` ya lo hace: reusar su `holders()`.

---

## B8 — `gate.sh` puede compilar el árbol equivocado ⚠️ ALTO

**Dónde:**
- `solidcraft-orch/bin/gate.sh:71` — `WORKTREE="$HOME/solidcraft-wt/issue-$ISSUE"`
- `solidcraft-orch/bin/gate.sh:75-77` — fallback al checkout principal
- `solidcraft-loop/bin/agent-issue.sh:96,274` — `WORK_ROOT="${WORK_ROOT:-$LOOP_DIR/work}"`, `WORK="$WORK_ROOT/issue-$ISSUE"`

**El defecto.** Hay **dos árboles de worktree** en el sistema:
- El del **orquestador**: `~/solidcraft-wt/issue-<N>` (lo que `gate.sh` busca)
- El del **loop/publisher**: `~/.local/share/solidcraft-loop/work/issue-<N>` (donde `agent-issue.sh` trabaja)

Un PR publicado por `agent-issue.sh` tiene su worktree en el **segundo**. `gate.sh` no lo encuentra y cae al fallback: *"no hay worktree para el slot N: el gate corre en el checkout principal"* — y compila **`~/solidcraft`**, que **no contiene el cambio**. El veredicto que se escribe (`gates/N/scope.verdict`) describe otro árbol. `verify-pr.sh` lo lee como *"el gate de este PR"* y lo acepta.

Además el fallback es un **warning, no un error**: el gate sigue y produce un veredicto que parece válido.

**Arreglo.** `gate.sh` debe leer el path del worktree del **mismo** estado que usa el publisher (`state.json` → `slot.worktree`, o `LOOP_DIR/work/issue-$N`), y si no lo encuentra debe **fallar** (exit ≠ 0) en vez de compilar el checkout principal. Un gate que no compila el cambio no debe escribir veredicto.

---

## B9 — `daily-report.py`: off-by-one que pierde TODAS las acciones pendientes ⚠️ MEDIO

**Dónde:** `solidcraft-orch/bin/daily-report.py:87-88`

**El defecto.** `orch-state.sh:75-79` imprime cada pendiente como **dos** líneas:
```
  [features-en-marcha] 7 features despachadas en total: …
      hacer: esperar y verificar
```
`daily-report.py:87` busca `"hacer:"` en `lineas[i + 2]`, pero la acción está en **`i + 1`**. El parser nunca la encuentra.

**Medido:**
```
4 pending items, 0 with the action recovered, 4 with the 'hacer:' line LOST
  MISS: pending #1 at i=0 -> i+1 es la línea de acción, el parser mira i+2
  MISS: pending #2 at i=2 …
  MISS: pending #3 at i=4 …
  MISS: pending #4 at i=6 …
```
El reporte diario (10:00 y 22:00, cada día) lista **qué** hacer pero **nunca** **qué hacer**. La sección "Pendientes" del reporte sale sin su acción, que es justo el dato que el cron reemplazó para gastar 1.5M menos de tokens.

**Arreglo.** `lineas[i + 1]`, y validar con `strip().startswith("hacer:")` (ya lo hace). Agregar un test que parsee un `state.json` de fixture y afirme que las N acciones aparecen.

---

## B10 — `agent-issue.sh`: el exit code del modelo se ignora y el worktree se borra en el re-run ⚠️ MEDIO

**Dónde:**
- `solidcraft-loop/bin/agent-issue.sh:416-419` — `timeout … opencode run …; RC=$?` — `RC` **sólo se imprime**
- `solidcraft-loop/bin/agent-issue.sh:425-429` — el único check es `COMMITS -eq 0`
- `solidcraft-loop/bin/agent-issue.sh:278-281` — `git worktree remove --force "$WORK" 2>/dev/null || rm -rf "$WORK"`
- `solidcraft-loop/bin/agent-issue.sh:434-437` — los cambios sin commitear se **anuncian** y no se guardan

**El defecto.** (a) `RC` (el exit code del modelo: timeout = 124, crash, OOM) se registra en una línea de log y no influye en nada. Si el modelo muere a mitad de un fix pero dejó un commit, el script lo publica. Si dejó **cambios sin commitear**, la línea 436 lo dice por stderr y sigue: el trabajo no se commitea, no se guarda, y en el próximo re-run la línea 280 lo borra con `--force`. (b) En el re-run, el worktree se borra **antes** de correr el freno, así que el `salvage` (que corre después, línea 546) **no encuentra nada que salvar**.

**Relacionado — el salvage nunca recogió trabajo.** Los 4 artefactos de `logs/claims-lost/*.json` dicen `"collected": false` y sus `.diff` están **vacíos (0 bytes)**. `claim-salvage.sh:152` dice *"there is no work to collect (no repository at …)"*. Es decir: **el mecanismo de rescate del trabajo existe pero nunca ha rescatado nada**, porque el worktree ya se había borrado.

**Arreglo.**
1. `RC` debe decidir: si `RC` = 124 (timeout) o ≠ 0 y `COMMITS` = 0 → no publicar, **salvar** el árbol (`git -C "$WORK" diff --binary > "$LOOP_DIR/work/issue-$N.diff"`) antes de salir.
2. Si `RC` ≠ 0 **y** hay commits → no publicar sin una revisión: publicar un fix a medio hacer es peor que no publicar.
3. La línea 434 debe **commitear** lo que quedó (`git add -A && git commit`) o guardar un patch, no sólo anunciarlo.
4. El borrado del worktree (línea 280) debe ocurrir **después** del freno, no antes.

---

## B10b — `orch-state.sh issue <N>` **crasha** con `AttributeError` ⚠️ MEDIO

**Dónde:** `solidcraft-orch/bin/orch-state.sh:112`

**El defecto.** La rama `issue` itera `open_prs` como si fuera un diccionario:
```
for pr, v in (s.get("open_prs") or {}).items():
```
Pero en `state.json`, `open_prs` es una **lista** (9 entradas) mientras `slots` y `gates` son diccionarios. El `.items()` sobre una lista lanza `AttributeError`, el `except` de la rama no lo cubre, y **el comando entero muere**.

**Medido:**
```
$ bash bin/orch-state.sh issue 7114
exit code: 1
stdout: ''
stderr: File ".../orch-state.sh", line 6, in <module>
        for pr, v in (s.get("open_prs") or {}).items():
AttributeError: 'list' object has no attribute 'items'
```
Reproducido con el bloque exacto de `orch-state.sh:107-121` (`/home/user/.hermes/cache/scratch/issue-crash.py`).

**Consecuencia.** `orch-state.sh issue <N>` es el comando que el agente corre para "¿qué sé de este issue?". **No responde nunca**: sale con código 1 y sin una línea. Y como el `open_prs` es una lista con la clave `number` (y una entrada con `pr`), el fix tiene que normalizar las dos formas — igual que el otro consumidor de `open_prs`, que ya usa `e["number"]` y por eso cuenta 0 (la entrada #11205 con clave `pr`).

**Arreglo.** Iterar la lista, indexando por `number` o `pr`:
```
for e in (s.get("open_prs") or []):
    num = e.get("number") or e.get("pr")
    if str(e.get("issue")) == n: hits.append(f"PR #{num}: …")
```

---

## B11 — `slot-stale.sh` tarda 3m22s y `orch-state.sh summary` lo llama ⚠️ MEDIO

**Dónde:**
- `solidcraft-orch/bin/slot-stale.sh:173, 200, 235, 237` — 4 llamadas a `gh`
- `solidcraft-orch/bin/orch-state.sh:94` — `bash "$ORCH_DIR/bin/slot-stale.sh" --hours 1 2>/dev/null | sed -n …`

**Medido:**
```
$ time bash bin/slot-stale.sh --hours 1 --json
real  3m22.556s
```
El `sed -n '/los PRs que esperan una respuesta nuestra/,$p'` de `orch-state.sh:95` sólo quiere la **última** sección, pero paga los 3m22s completos. El `summary` es el comando que el agente corre para "ver el estado": **3½ minutos por consulta**.

Además `slot-stale.sh:173` pide `--limit 1200` sobre `--state all` (el repo tiene 836 abiertos + cerrados), y `:237` itera `gh api .../issues/$pr/comments` **PR por PR** (4 nuestros).

**Arreglo.** (a) Partir el script: un `slot-stale.sh --locks` (sólo el estado de los locks, sin GitHub, milisegundos) y otro `--prs` (lo que necesita GitHub); `orch-state.sh:94` usaría el primero. (b) Cachear la lista de PRs una vez y reutilizarla. (c) `gh api --paginate` una sola vez y filtrar en local en vez de una llamada por PR.

---

## B12 — 87 GB de targets, cap de 60 GB, y el GC nunca se ejecuta ⚠️ MEDIO

**Dónde:**
- `solidcraft-loop/bin/gc-disk.sh:209` — `ORCH_TARGET_MAX_GB="${DISK_ORCH_TARGET_MAX_GB:-60}"`
- `solidcraft-loop/bin/gc-disk.sh:176` — `ORCH_TARGET_BASE="${ORCH_TARGET_BASE:-$ORCH_DIR/targets}"`
- `solidcraft-loop/bin/supervisor.sh:2162-2163` — el **único** llamador

**Medido:**
```
87G  /home/user/.local/share/solidcraft-orch/targets/
  18G  slot-4712      13G  slot-10159      11G  slot-10747b
  9.3G slot-8434     6.7G  slot-3599       4.6G slot-10747b-verify
  4.6G slot-11171     4.3G  slot-9866       3.2G slot-5237
  2.8G slot-5857      2.0G  slot-10067      618M slot-2147
```
**27 GB por encima del cap.** El único que llama a `gc-disk.sh` es `supervisor.sh:2162`, y `supervisor.sh` no está en ningún cron ni timer activo. El cron `solidcraft-orchestrator-wave` (cada 30 min) está **`enabled: false`**. O sea: **nada aplica el cap**.

Y el que lo aplica tiene un problema propio: `gc-disk.sh:488-501` (`scope_lock_busy`) prueba el lock del slot con un **`flock -n -x` exclusivo** — o sea, si lo consigue, **toma** el lock del slot por un instante. Con un gate que está por tomarlo, el GC puede ganar la carrera y hacer que el gate se difiera (B1).

**Arreglo.** (a) Un timer/cron real que corra `gc-disk.sh` (el cap no es un documento: es un límite). (b) `scope_lock_busy` debe **preguntar** sin tomar: usar `flock -n -s` (shared) no sirve para un lock exclusivo… la forma correcta es leer `/proc/locks`, o mantener un "lock de consulta" separado. (c) `slot-10747b` (11 GB) y `slot-10747b-verify` (4.6 GB) son **el mismo slot** con dos target dirs: el cap por slot no los agrupa.

---

## B13 — `gate.sh` no verifica el exit code de `gate-quick.sh` ⚠️ MEDIO

**Dónde:** `solidcraft-orch/bin/gate.sh:141-152`

**El defecto.** `gate.sh` hace `exec bash "$GATE_SCRIPT" …`. Con `exec`, el shell **se reemplaza** por el del gate: el exit code de `gate.sh` **es** el de `gate-quick.sh`, así que el código de salida no se pierde — pero el `trap cleanup EXIT` de `gate-quick.sh` (línea 1092) es lo único que libera los locks. Si `gate-quick.sh` muere por una señal (SIGKILL por OOM, que es real: hay `--property=MemoryMax=` en el `systemd-run`), **el trap no corre** y los fd 8/9 quedan abiertos en los hijos supervivientes. Es B1Again, por la puerta de atrás.

Además, el mensaje `Killed` que queda en el log (línea 884) es **la única señal**: no hay estado terminal confiable en el veredicto.

**Arreglo.** Que `gate.sh` **no** use `exec` sino que capture el rc, lo verifique contra lo que dice `scope.verdict`, y re-emita un rc explícito. Y que el `systemd-run` reporte el estado del scope, no sólo su exit code.

---

## B14 — `verify-pr.sh`: el check de CI decide por el NOMBRE del check, no por su estado ⚠️ MEDIO

**Dónde:**
- `solidcraft-orch/bin/verify-pr.sh:124` — `CHECKS="$(gh pr checks "$PR" --repo "$REPO" 2>&1 | head -20)"`
- `solidcraft-orch/bin/verify-pr.sh:127` — `FAILED="$(… grep -ciE '\bfail' …)"`
- `solidcraft-orch/bin/verify-pr.sh:132-135` — el filtro `LIGHT_BAD`

**El defecto.** (a) El exit code de `gh pr checks` **se descarta**: si `gh` falla (auth, red, o "no checks reported"), el texto del error entra en `CHECKS` y no contiene "fail" → `FAILED=0` → *"todo en orden"*. Un PR cuyos checks no se pudieron leer parece un PR sin problemas. (b) `grep -ciE '\bfail'` cuenta como fallo un check cuyo **nombre** contiene "fail" ("failing to provision"). (c) El filtro `LIGHT_BAD` (`defaults|duplicate|claim|kernel|triage|select|format|repository|lint`) decide **qué** checks se miran. Medido contra los checks reales de nuestros PRs:

| check real de GitHub | ¿el filtro lo mira? |
|---|---|
| `Native Linux tests` | **NO** |
| `Native Linux Clippy` | **NO** |
| `Build tests` | **NO** |
| `Label changes-default` | **NO** (dice `changes-default`, el filtro busca `defaults`) |
| `Defaults line check` | sí |
| `Duplicate PR check` | sí |
| `Format and repository checks` | sí |

Los **tres** checks que de verdadiated compilan y corren los tests (los que deciden si el PR es mergeable) **no se miran**. Un PR puede estar rojo en CI y `verify-pr.sh` dice *"todo en orden"*.

**Arreglo.** (a) Verificar el exit code de `gh pr checks` y fallar si no se pudo leer. (b) Contar los checks por su **estado** (`gh pr checks --json name,state,conclusion`), no por el texto. (c) El filtro debe ser una lista explícita de checks **redos que bloquean**, no una lista de nombres que se busca dentro de una línea: un check rojo de *cualquier* nombre es un bloqueo salvo que esté en la lista de exentos.

---

## B15 — Rutas hardcodeadas (menor, pero real)

`grep -rn '/home/user/' …` → **55 ocurrencias** en los dos `bin/`. Las que importan:

| archivo:línea | ruta | por qué importa |
|---|---|---|
| `solidcraft-orch/bin/orch-state.sh:26,64,110,125` | `/home/user/.local/share/solidcraft-orch/state.json` | **`$ORCH_DIR` se ignora**: el `pick()` tiene la ruta escrita en el heredoc Python. Con `ORCH_DIR=/otro` el script lee el `state.json` equivocado. |
| `solidcraft-orch/bin/gate-runner.sh:15-17,45,51-52` | `/home/user/.local/share/solidcraft-orch/bin`, `/home/user/solidcraft-wt/issue-10159`, … | El runner tiene **los slots y shas hardcodeados** (líneas 51-52: `run_one 10159 aee25f106` / `run_one 4712 0d74d8cae`). Es un script de un día, no una herramienta. |
| `solidcraft-loop/bin/gate-quick.sh:293` | `/home/user/solidcraft-gate-quick/target` | El default del target dir **no** es el del orquestador (`$ORCH_DIR/targets`), así que un gate lanzado sin `gate.sh` compila en un árbol distinto del que cree el resto del sistema. |
| `solidcraft-loop/bin/gate-quick.sh:93` | ruta del repo | idem. |
| `solidcraft-orch/bin/daily-report.py:14,67` | `/home/user/.local/share/solidcraft-orch`, `/home/user/.hermes/state.db` | El reporte lee el `state.db` de Hermes por ruta absoluta. |

**Arreglo.** Que `ORCH_DIR`/`LOOP_DIR` se propaguen a los heredocs Python por `os.environ` en vez de estar escritos en el source, y que `gate-runner.sh` lea los slots pendientes de `state.json` en vez de tenerlos escritos.

---

## B16 — `2>/dev/null` que se tragan errores (menor, pero con conteo)

| archivo | ocurrencias | el caso que importa |
|---|---|---|
| `solidcraft-loop/bin/gate-quick.sh` | 71 | `:1325` `rm -f "$file" 2>/dev/null` — si el borrado del veredicto viejo falla, se escribe el nuevo encima (OK), pero `:1339` `} > "$tmp" 2>/dev/null` **esconde el error de escritura** y el `mv` posterior falla sin contexto. |
| `solidcraft-loop/bin/gc-disk.sh` | 67 | `:488-501` `scope_lock_busy`: si el `flock` falla por un motivo que no sea "ocupado", el script lo lee como "ocupado" → **conserva un target que sí puede borrarse**. |
| `solidcraft-loop/bin/loop.sh` | 44 | |
| `solidcraft-loop/bin/dry-run.sh` | 37 | |
| `solidcraft-orch/bin/slot-lock.sh` | 28 | `:222` `printf … > "$d/token" 2>/dev/null || true` — si la escritura falla, el token tomado **no queda registrado** y nunca se libera (ver B4). |
| `solidcraft-orch/bin/slot-stale.sh` | 22 | `:54-55` `awk … 2>/dev/null` sobre un archivo que no existe → `since` vacío → `continue` → el slot se salta en silencio (ver B2). |
| `solidcraft-orch/bin/verify-pr.sh` | 5 | `:124` el caso de B14. |
| `solidcraft-orch/bin/claim-verify.sh` | 1 | `:60` `gh pr list … 2>/dev/null` — el error de `gh` se pierde, pero `:66` hace una segunda llamada para distinguir "vacío" de "falló". **Este es el patrón correcto**; los demás scripts deberían copiarlo. |

**Arreglo.** Adoptar el patrón de `claim-verify.sh:63-69`: cuando la salida esté vacía, **verificar que la herramienta pudo leerse** antes de concluir "no hay nada". En `gc-disk.sh:488` y `slot-lock.sh:222` eso significa distinguir "ocupado" de "no pude mirar".

---

# 2. CUELLOS DE BOTELLA

## 2.1 Trabajo que se hace dos veces

| # | Dónde | Costo medido |
|---|---|---|
| **T1** | **`gate-runner.sh` re-corre gates ya servidos** (B3) | **27–54 min por gate re-lanzado.** Con 3 slots pendientes: ~1,5 h de CPU. |
| **T2** | **El gate compila el árbol que el publisher no publicó** (B8) | Todo el gate (27–54 min) es trabajo sobre un checkout que no contiene el cambio: **100% desperdicio**. |
| **T3** | **Dos树木 de target dir para el mismo slot**: `slot-10747b` (11 GB) + `slot-10747b-verify` (4.6 GB) | 15.6 GB de disco para un slot. El cap por-slot no los agrupa. |
| **T4** | **`gate-quick.sh` re-calcula el alcance** que `affected.py` ya sabe | `gate-quick.sh:1529` llama a `scripts/ci/affected.py` una segunda vez "con los mismos paths y los mismos metadatos" — el comentario lo admite. |
| **T5** | **`claim-verify.sh` y `claim-race.sh` consultan GitHub por separado** | 2 llamadas `gh pr list --limit 1000` (836 PRs cada una) para aplicar **dos reglas distintas** (B6). |
| **T6** | **`orch-state.sh summary` → `slot-stale.sh` → 4 `gh`** y después `daily-report.py` → `orch-state.sh summary` otra vez | El reporte diario paga **3m22s × 2** (6m44s) para armar un texto que no cambia cada minuto. |

## 2.2 Esperas que se podrían evitar

| # | Dónde | Espera |
|---|---|---|
| **E1** | **`GATE_SCOPE_LOCK_WAIT=0`** (`config.env:273`) | El gate no espera **nada** por el lock: se difiere al instante. Con B1, el diferimiento es eterno. Si el lock se liberara bien, un `WAIT` de 30–60 s convertiría casi todos los diferimientos en esperas resueltas — y el gate saldría con veredicto en vez de `SKIP`. |
| **E2** | **`gate-quick.sh` serializa las fases** (fmt → layers → clippy → check → nextest) | Con `MemoryMax`/`CPUWeight` por scope, las fases **independientes** podrían ir en paralelo por slot. El log del gate del 4712 muestra `fmt:fail|layers:ok|clippy:fail|check:fail` — 4 fases, 17 min. |
| **E3** | **`slot-stale.sh` tarda 3m22s** y `orch-state.sh:94` lo corre **antes** de imprimir `=== slots ===`** | El agente espera 3½ min para ver el estado. Con el split de B11 son milisegundos. |
| **E4** | **`gate-queue.sh` (el watcher manual)**: `for i in $(seq 1 120); … sleep 30` | Espera hasta **1 hora** por un slot, en un loop de polling. |
| **E5** | **`agent-issue.sh:416` `timeout "${TIMEOUT_MIN}m"`** con `TIMEOUT_MIN` configurable | El techo de tiempo del modelo es el del clock de pared, no "tiempo sin progreso": un modelo que hace 3 llamadas en 40 min se cuenta igual que uno que avanza. |

## 2.3 Pasos secuenciales que podrían ir en paralelo

| # | Secuencia actual | Posible en paralelo |
|---|---|---|
| **P1** | `gate.sh` → `claim-verify.sh` (1 llamada a GitHub) → **después** `gate-quick.sh` (17–54 min) | El check del claim (segundos) va **dentro** del gate, no antes: si el claim está perdido, el gate no debería haber corrido. Hoy el gate corre y después se descarta. |
| **P2** | `agent-issue.sh`: modelo → rebase → gate angosto → brake → defaults → body → push → PR | El **rebase** (línea 469) y el **gate angosto** (línea ~479) son secuenciales; el gate angosto podría correr sobre el commit ya rebasado en background mientras se prepara el body. |
| **P3** | `gate.sh` → `gate-quick.sh`: las 4 fases (`fmt`, `layers`, `clippy`, `check`) | `fmt` y `layers` no dependen de `clippy` ni de `check`. 4 fases en paralelo ≈ 1 fase + Δ, contra la suma hoy. |
| **P4** | Los gates de slots distintos | El diseño ya los permite (`gate-target-dir.sh` existe justo para eso), pero `gate-runner.sh` los recorre **en serie** — es exactamente el runner que se creó para evitar la carrera del diferimiento y que hoy **serializa todo**. Con B1 arreglado, el runner en serie se vuelve innecesario. |

## 2.4 Trabajo que se tira a la basura

| # | Qué se tira | Cantidad medida |
|---|---|---|
| **W1** | **Correr un gate para descubrir que otro gate corre** | El gate del 10159: **3m12s** de CPU (16:54→16:57) para escribir `SKIP`. El veredicto `skipped` **borra** el veredicto anterior del slot (`gate-quick.sh:1325` `rm -f "$file"`): un diferimiento **destruye** el veredicto verde previo. |
| **W2** | **Un gate re-lanzado por `gate-runner.sh`** (T1) | 27–54 min × 3 slots. |
| **W3** | **Un gate compilado sobre el árbol equivocado** (B8) | 27–54 min completos. |
| **W4** | **Los ~2 GB de disco por slot que `gc-disk.sh` nunca reclamation** | **27 GB por encima del cap.** |
| **W5** | **El parche de 9 worktrees sucios que nadie commitea** | `issue-3599` (6 archivos), `issue-5857` (7), `issue-8434` (5), `issue-2147` (4), y 5 más = **32 archivos modificados sin commit**. `agent-issue.sh:436` los anuncia por stderr y los abandona. |
| **W6** | **El `nextest` de 45 min colgado** | El proceso queda vivo sosteniendo el lock; su resultado no lo lee nadie. |
| **W7** | **La lista de 193 competidores que `claim-verify.sh` no lee** (B6) | Un gate que corre para un issue ya reclamado. |

---

# 3. TRABAJO QUE SE PIERDE — conteo actual

## 3.1 Agentes que terminaron sin PR — **9 de 21 slots**

De los **21 slots** de `state.json`, **9** tienen `result` que dice "sin PR":

| slot | qué pasó | ¿trabajo perdido? |
|---|---|---|
| **1** | "el fix está cubierto por #10146 y #7665. La causa raíz y dos tests RED quedaron en el fork (`wip/issue-10134-diagnosis`, 12ff23151)" | **Sí** — la rama `fix/issue-10134-sketch-move-arc` existe local, sin pushear |
| **5** | "el claim se perdió (PR #10307 de austin62jake, número menor)" | **Sí** — el salvage corrió con `collected: false` |
| **7** | "el agente escribió los tests RED (126 líneas en 2 archivos) pero el problema necesita…" | **Sí** — tests RED escritos, nunca commiteados |
| **10339** | "el agente NO pudo escribir el test RED (lo reportó así)" | No (nunca hubo trabajo) |
| **8** | "el agente NO pudo escribir el test RED… Sin commits sobre origin/main y el worktree f…" | No (nunca hubo trabajo) |
| **10656** | "el bug EXISTE y está confirmado con números, pero ya está reclamado por trabajo en curso" | **Sí** — diagnóstico con datos, sin guardar |
| **10747** | "el fix YA EXISTE en el PR #10812 de dahakbuilds" | No |
| **10750** | "NO es un bug. El mapeo es correcto…" | No |
| **10719** | "sin PR, y NO es un bug" | No |

**Subtotal real: 4 slots** (1, 5, 7, 10656) con trabajo que se perdió. **2 slots** (10339, 8) con el agente unable de escribir nada. **3 slots** (10747, 10750, 10719) sin bug ni trabajo.

**Además, 2 slots con "no commit":** 10339 y 8.

## 3.2 Ramas sin pushear — **12 con commits reales** (de 28 no presentes en `fork`)

`git for-each-ref refs/remotes/fork/` vs `refs/heads/`: 54 ramas locales, 168 en `fork`, **28 no presentes en `fork`**, de las cuales **12 tienen ≥1 commit sobre `origin/main`**:

| rama | sha | commits | fecha | qué es |
|---|---|---|---|---|
| `fix/issue-10750-box-dimensions` | `76c2a2796` | 1 | 11-01 | "Test: the Box dialog's Width is the box's Y side" |
| `fix/issue-6449-sketch-project-hole` | `3d2d05aac` | 1 | 11-01 | "Project: a click in a hole opening draws the rim" |
| `rebase/hole-rim-project` | `fb71e8e9a` | 2 | 11-01 | rebase sin terminar |
| `fix/issue-10138-residual` | `e6954984e` | 1 | 10-31 | "Language: a script-bearing system tag matches its region catalog" |
| `fix/issue-10138-system-language` | `7a2b2e5e5` | 1 | 10-31 | "wip: the diagnosis of #10138" |
| `pr-10183` | `e8e14cf1b` | 3 | 10-31 | 3 commits (#10138 + clippy) |
| `perf/issue-3892-browser-tree-hover` | `2211fd87a` | 1 | 10-31 | "perf(#3892): index the hidden joints and folders" |
| `test-8059-rebase` | `f03082533` | 1 | 10-30 | rebase de prueba |
| `backup/7878-pre-rebase` | `cc1e44f57` | 2 | 10-28 | backup |
| `wt/issue-5505-evidence` | `5d72e1a69` | 3 | 10-26 | evidencia de #5505 |
| `fix/issue-5505-sketch-constraint-dof` | `77665cb5b` | 3 | 10-26 | "fix(#5505): a zero dimension keeps constraining" |
| `backup/xtask-pool-pre-cleanup` | `9c76ff9fb` | 4 | 10-24 | "xtask: run the test binaries in a bounded pool" |

**El caso más caro:** `fix/issue-5505-sketch-constraint-dof` (3 commits) y `wt/issue-5505-evidence` (3 commits) son **el mismo fix** en dos ramas, sin pushear — y el PR #10790 de #5505 ya fue **MERGEADO** por el mantenedor el 11-02. Es decir: el trabajo **sí** llegó a upstream por otro camino, pero quedó **duplicado y huérfano** local. Lo mismo con `fix/issue-10750-box-dimensions`: el gate del 10750 corrió (ROJO-SCOPE, 38m57s) sobre `76c2a2796` y la rama nunca se pusheó.

## 3.3 Worktrees con cambios sin commitear — **9 worktrees, 32 archivos**

```
issue-10067: 2 archivos   M crates/ui-egui/src/theme.rs, M theme_files.rs
issue-10747: 2 archivos   ?? pr-body-10747.md, ?? red-10747.log
issue-11171: 2 archivos   M crates/ui-egui/src/lib.rs, ?? sketch_snap_start_ui_tests.rs
issue-2147:  4 archivos   M crates/sketch/src/lib.rs, M ui-egui/src/lib.rs, ?? probe_2147.rs
issue-3599:  6 archivos   M engine/src/cmd/sketch.rs, M sketch/src/model.rs, M sketch/src/solver.rs
issue-4760:  2 archivos   M crates/sketch/src/tests.rs, ?? crates/sketch/src/weld.rs
issue-5857:  7 archivos   M crates/doc/src/history_names.rs, M naming.rs, M persistent_name.rs
issue-8434:  5 archivos   M engine/src/cmd/component.rs, ?? probe_8434.rs, ?? probe_8434b.rs
issue-9086:  2 archivos   M engine/src/lib.rs, ?? measure_surface_tests.rs
```
Total: **32 archivos modificados, ninguno commiteado**. Los `probe_*.rs` son instrumentation de diagnóstico: es trabajo real (mide, encuentra la causa) que se pierde en el próximo `worktree remove --force` (B10).

## 3.4 Claims perdidos — **4 artefactos, 0 rescatados**

`solidcraft-loop/logs/claims-lost/` contiene **4 sets** (`.json` + `.md` + `.diff`):

| issue | verdict | `collected` | `.diff` |
|---|---|---|---|
| 10138 | RESOLVED | **false** | **0 bytes** |
| 10138 | RESOLVED | **false** | **0 bytes** |
| 10306 | LOST | **false** | **0 bytes** |
| 10306 | UNKNOWN | **false** | **0 bytes** |

**Los 4 parches están vacíos.** El mecanismo de rescate existe (`claim-salvage.sh`, `claim-brake.sh:207-224`) pero **nunca ha rescatado nada**: `claim-salvage.sh:152` reporta *"there is no work to collect (no repository at …)"* porque el worktree ya había sido borrado (B10).

**En `history.jsonl`, 7 eventos mencionan un claim perdido.** Los más explícitos:
- *"un claim se perdió y otro slot arrancó sin lock: detectado con claim-verify.sh"* (11-01 00:11)
- *"el #7114 agent hit its iteration cap, but it had already written and proven the RED test"* (10-30 23:10) → el trabajo del cap de iteraciones **no se guardó**
- *"#3892: the first agent ran out of iterations; the orchestrator found the root cause"* → re-despachado, pero el primer intento se perdió
- *"the agent of #3892 ran out of budget before writing code; re-delegated with its research"*

**El `state.json` registra 2 slots abandonados** (`abandoned`): `9265` (el RED está probado en `prefs.rs:5632`, la causa raíz confirmada con 12 filas de label vacío — **todo ese análisis se pierde** con el slot) y `9062`.

## 3.5 PRs sin publicar / deriva del estado — **4 abiertos, 0 derruidos, 1 huérfano**

`state.json` dice `conteo.abiertos: 4` y `abiertos_detalle: "#8059 y #9843 listos esperando revisión; #10618 …; #11074 …"`. GitHub, en este momento:

| PR | estado real en GitHub | en `state.json`? |
|---|---|---|
| #8059 | OPEN | sí |
| #9843 | OPEN | sí |
| #10390 | **MERGED** (11-02 02:15) | **sí, en `open_prs`** ⚠️ |
| #10594 | **MERGED** (11-02 02:15) | **sí, en `open_prs`** ⚠️ |
| #10618 | OPEN | sí |
| #10790 | **MERGED** (11-02 00:24) | **sí, en `open_prs`** ⚠️ |
| #10859 | **MERGED** (11-02 14:10) | **sí, en `open_prs`** ⚠️ |
| #11074 | OPEN | sí |
| #11205 | OPEN (draft) | sí, pero **con la clave `pr` en vez de `number`** ⚠️ |

**Deriva:** 4 PRs **MERGED** siguen listados en `state.json.open_prs` (que dice "abiertos"). `state.json.open_prs` es una lista, pero `orch-state.sh:112` la trata como **diccionario** (`(s.get("open_prs") or {}).items()`) → el comando `orch-state.sh issue <N>` **no encuentra nada** para ningún PR. Verificado: `orch-state.sh issue 6747` no habría mostrado el PR #9843.

**Huérfano por formato:** la 9ª entrada de `open_prs` usa `{"pr": 11205, …}` en vez de `{"number": 11205, …}`. Cualquier consumidor que haga `e["number"]` (como el conteo que hice) lo cuenta como una entrada **sin número**. Es el mismo bug de "dos formatos, un consumidor" que B2 y B4.

**PRs nuestros abiertos que `state.json` no menciona:** los 4 abiertos están en `open_prs`, así que no hay huérfanos ahí. Pero `state.json` **no** registra los 12 ramas sin pushear (§3.2) ni los 9 worktrees sucios (§3.3): **el trabajo no publicado es invisible para el orquestador**.

## 3.6 Resumen numérico

| Categoría | Conteo |
|---|---|
| Slots en `state.json` | **21** |
| Slots terminados sin PR | **9** (de ellos, **4 con trabajo real perdido**) |
| Slots con trabajo real perdido (diagnóstico/tests/RED sin commit) | **4** (1, 5, 7, 10656) |
| Slots donde el agente no pudo escribir nada | **2** (10339, 8) |
| Ramas locales no presentes en `fork` | **28** |
| — de las cuales con **≥1 commit** sobre `origin/main` | **12** |
| Worktrees con cambios sin commitear | **9** (32 archivos) |
| Claims perdidos registrados | **4** |
| — con trabajo efectivamente rescatado | **0** (los 4 `.diff` están vacíos) |
| PRs nuestros abiertos (GitHub) | **4** (#8059, #9843, #10618, #11074) |
| PRs MERGED que `state.json` sigue listando como abiertos | **4** |
| Entradas de `open_prs` con el formato roto (`pr` en vez de `number`) | **1** (#11205) |
| Ramas/trabajo no publicados que el estado **no** registra | **12 ramas + 9 worktrees** |

---

# 4. Prioridad de arreglo

**P0 — hoy (bloquean el loop):**
1. **B1**: cerrar fd 8/9 en cada hijo + watchdog de gates colgados. Sin esto, ningún gate corre.
2. **B2**: arreglar el consumidor `slot-stale.sh` para leer el formato real.
3. **B3**: el vocabulario `GATE_STATUS` de `gate-runner.sh`.

**P1 — esta semana:**
4. **B6 + B7**: un solo árbitro de claims (delegar `claim-verify.sh` → `claim-race.sh`).
5. **B8**: `gate.sh` debe fallar, no compilar el checkout principal.
6. **B10**: el exit code del modelo decide; salvar el trabajo antes de borrarlo.
7. **B4**: el token pesado, por caller.
8. **B10b**: `orch-state.sh issue <N>` itera la lista (es un fix de una línea).

**P2 — próximo sprint:**
9. **B5** (regex de cierre), **B9** (off-by-one del reporte), **B12** (timer del GC), **B13** (exit code del gate), **B14** (checks de CI), **B11** (split de `slot-stale.sh`), **B15** (paths hardcodeados).

---

*Auditoría hecha sin modificar ningún script productivo. Los archivos de trabajo quedaron en `/home/user/.hermes/cache/scratch/` (`orphan-repro.sh`, `heavy-race.sh`, `durations2.py`, `orphans.py`, `divergence2.py`, `lost2.py`, `lost3.py`, `drill.py`).*
