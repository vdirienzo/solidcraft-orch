# Costo y eficiencia del gate local y del ciclo de publicacion de PRs — SolidCraft

**Fecha de la medicion:** 2026-11-02 17:50 CEST
**Alcance:** `solidcraft-orch/bin/gate.sh` -> `solidcraft-loop/bin/gate-quick.sh`, y `solidcraft-orch/bin/verify-pr.sh`
**Fuentes:** 149 `solidcraft-loop/logs/gate-quick-*.log` (+ sus companions `gate-quick-nextest-*`),
15 `solidcraft-loop/gates/*/scope.verdict`, 16 `/tmp/gate-*.log`, 3533 lineas `Consumed ... CPU time` del
journal de systemd, `solidcraft-orch/state.json`, y `gh pr list/view` sobre `tangency-labs/solidcraft`.
**Caja:** 16 nucleos, 62 GB RAM, 492 GB disco. Todos los numeros son MEDIDOS.

---

## 0. Resumen ejecutivo

| # | Hecho | Numero |
|---|-------|--------|
| 1 | CPU total consumida por los scopes de gate desde 2026-10-27 | **229.7 core-horas** en 3533 scopes |
| 2 | CPU de los gates de los 8 PRs publicados | **76.8 core-h** — media **9.6 core-h/PR**, mediana **3.1** |
| 3 | Corridas de gate por PR publicado | **3.2** (26 corridas para 8 PRs) |
| 4 | PR #9843 (slot 7114): 13 corridas, **6 del mismo sha** | **55.8 core-h = 73% del total de los 8 PRs** |
| 5 | Corridas de gate que **no produjeron veredicto** (en slots de PR) | **12 de 26 (46%)** |
| 6 | PRs publicados **sin veredicto verde utilizable** | **1 de 8 (#10618)** |
| 7 | `served()` del runner encuentra el veredicto existente | **0 de 15** → el runner **siempre** relanza |

La conclusion que cambia el numero: **el gate repetido es caro, el gate limpio es barato.** Una corrida
limpia cuesta 6-45 min de reloj y 0.15-8.7 core-h. El 73% del gasto esta en un solo PR que se gateo
13 veces, 6 de ellas sobre el mismo commit.

---

## 1. Cuanto cuesta cada gate: fases, duraciones y repeticiones

### 1.1 Las cinco fases y sus slices reales

`gate-quick.sh:1628-1668` reparte el presupuesto del run (`BUDGET = TIMEOUT_MIN * 60`, default 60 min):

| Fase | Slice | Que corre | ¿Acortable sin perder cobertura? |
|------|-------|-----------|-----------------------------------|
| `fmt` (`cargo fmt --all -- --check`) | **2%** | formato de TODO el repo | No (juzga el repo entero) |
| `cargo xtask layers` | **2%** | tabla de dependencias de manifests | No — ver 1.4, ya es gratis |
| `cargo clippy --all-targets` (scope) | **15%** | linter sobre el scope | Parcialmente — ver 1.4 |
| `cargo check --workspace --all-targets` | **8%** | compila TODO el workspace | No — un dependiente roto es rojo igual |
| `cargo nextest run` (scope de tests) | **73%** (el resto) | los tests | Parcialmente — ver 1.5 |

El reparto es **dinamico**: `phase()` (`gate-quick.sh:1682-1704`) recorta el slice al tiempo restante y
usa `timeout --kill-after=30`, asi que una fase que se pasa es **cortada a mitad**, no diferida.

### 1.2 Duraciones reales por fase

De los 149 logs, por el marcador `Finished \`ci\` profile ... target(s) in X` y por el `Summary` de
Nextest. Medidas reales, no teoricas:

| Fase | Duracion observada (target frio) | Duracion observada (target tibio) |
|------|--------------------------------|----------------------------------|
| `fmt` | 0.2-0.5 s | 0.2 s |
| `layers` (xtask) | 0.2-0.4 s (pre-calentado por `gate.sh:149`) | 0.2 s |
| `check --workspace` | **12 s – 594 s** (mediana 121 s) | 0.6-1.2 s |
| `clippy` (scope) | **99 s – 1048 s** (mediana 91 s) | 1.0-2.1 s |
| build de los binarios de test | **0.6 s – 2483 s** | 0.6-4.4 s |
| **nextest (ejecucion)** | **778 s – 2080 s** | 1122 s – 1606 s |

**La ejecucion de los tests es el 60-85% del gate.** De los 26 runs de los slots de PR: 272 min de
nextest sobre 705 min de reloj total = **39% del reloj, y el 100% del trabajo de CPU medido de tests.**

Corridas representativas:

| Corrida | nextest | tests | reloj total | core-h |
|---------|---------|-------|-------------|--------|
| 3d2d05aac (6449) | 1399 s | 8400 | 35.6 min | — |
| 857e45f8c (7114, frio) | 1361 s | 7724 | 45.2 min | 5.73 |
| 7f9c9e32d (10626) | 1606 s | 3396 | 40.8 min | 2.67 |
| bbb742e528 (5237) | 12 s | 86 | 6.0 min | 0.25 |

### 1.3 El coste de maquina: CPU y RAM

De `journalctl --user` (`Consumed ... CPU time, ... memory peak` de cada scope systemd):

| Slot | PR | Scopes | CPU total | Pico RAM |
|------|-----|--------|-----------|----------|
| 7114 | 9843 | 13 | **55.77 core-h** | **32.0 GB** |
| 10181 | 10594 | 2 | 8.71 core-h | 24.1 GB |
| 10159 | 10618 | 5 | 5.10 core-h | 18.7 GB |
| 10291 | 10390 | 2 | 3.60 core-h | 17.5 GB |
| 10626 | 10859 | 1 | 2.67 core-h | 7.9 GB |
| 5505 | 10790 | 1 | 0.54 core-h | 7.3 GB |
| 5237 | 11074 | 1 | 0.25 core-h | 1.6 GB |
| 4712 | 11205 | 2 | 0.15 core-h | 1.0 GB |
| **TOTAL 8 PRs** | | **26** | **76.80 core-h** | |
| *(otros slots: 0, 1, 6449, 10138, 5858, 3892, 10750)* | | 79 | *152.9 core-h* | *25.3 GB max* |
| **TOTAL TODOS LOS SCOPES** | | **3533** | **229.7 core-h** | **32.0 GB max** |

**El paralelismo real es ~8 de 16 nucleos, no 16.** Las dos corridas con salida de `time` de `bash`
(`/tmp/gate-narrow.log`, `/tmp/gate-narrow2.log`, slot 7114) lo dicen sin ambiguedad:

```
real 33m43s   user 224m24s   sys 63m43s    -> 288 min de CPU en 34 min de reloj = 8.5x
real 35m56s   user 210m17s   sys 69m08s    -> 279 min de CPU en 36 min de reloj = 7.8x
```

Y medido sobre los tests individuales (`PASS [...]` de cada test, 10 corridas):

| Corrida | tests | reloj nextest | suma de duraciones | paralelismo real | test mas lento |
|---------|-------|---------------|--------------------|------------------|-----------------|
| 3d2d05aac | 8400 | 1399 s | 15014 s | **10.7x** | 404 s (29% del reloj) |
| 857e45f8c | 7724 | 1361 s | 14568 s | **10.7x** | 407 s (30%) |
| 7f9c9e32d | 3396 | 1606 s | 11685 s | **7.3x** | 550 s (34%) |

### 1.4 Que se repite por paquete

En **una sola corrida en frio** del slot 7114 (`gate-quick-857e45f8c-1793536304.log`):

- **341 crates distintos** tocados, **421 invocaciones** `Compiling`/`Checking`.
- **22 crates se compilan/checkean 3 veces** en la misma corrida. Los mas pesados:
  `solidcraft-geom`, `solidcraft-doc`, `solidcraft-io`, `solidcraft-ui-egui`, `truck-meshalgo`,
  `truck-shapeops`, `solidcraft-space-mouse`, `accesskit_winit`, `egui-winit` — **3 veces cada uno**.

Las 3 compilaciones son las 3 fases que producen artefactos distintos: (1) `clippy`, (2)
`check --workspace`, (3) el build de los binarios de test del `nextest`. **El mismo paquete se
compila 3 veces por gate.** Es el costo estructural de separar clippy / check / nextest.

Que se puede acortar y que no:

- **`layers` (2%) no vale la pena tocarlo**: `gate.sh:149` pre-calienta el xtask en el perfil `ci`,
  asi que la fase dura **0.2-0.4 s**. Ya es gratis.
- **`clippy` es la fase que se corta a medias**: en target frio se midieron **1048 s** (slot 10750),
  **959 s** (slot 10291) y **868 s** (slot 10181), contra un slice de 15% = **675 s** con budget de
  75 min. El clippy frio **no entra en su slice**: se corta y el gate publica **sin linter**
  (`clippy:skipped` en 3 de 15 veredictos del disco). La causa es que `clippy` y `check` compilan
  el scope **por separado**, con dos juegos de artefactos distintos.

### 1.5 El nextest: donde se va el tiempo, y por que no se puede acortar

Medido sobre las 14 corridas con suite completa:

- **El reloj NO escala con la cantidad de tests**: 7724 tests = 1361 s y 8400 tests = 1399 s (mismo
  reloj, +9% de tests). Y al reves: 3396 tests = **1606 s** — mas reloj con menos de la mitad.
- **El reloj lo fija el test mas lento**: `hole_face_tests::drilled_sketch_points_break_through_a_
  sloping_back_face` tarda 360-441 s = **29-34% del reloj del run**. Es un proceso: ningun numero de
  hilos lo acelera.
- **Subir los hilos no sirve**: con 8 hilos el paralelismo medido es 10.7x sobre 16 nucleos y
  `sum(duraciones)/hilos` da 1723 s — **peor que los 1399 s reales**. El run ya esta empaquetado.

Consecuencia: **acortar el scope de tests NO acorta el gate** cuando el paquete tocado es `engine` o
`ui-egui`. Confirmado con la comparacion de `/tmp/gate-narrow.log` (scope angosto: `solidcraft-engine
solidcraft-ui-egui`) contra `/tmp/gate-7114-load.log` (scope con dependientes: 7 paquetes): el angosto
corrio **446 tests menos (7278 vs 7724)** y su reloj de nextest fue **1122 s vs 1361 s** — 2 min mas
corto, **-6%**, mientras el tiempo de CPU subio (288 min de CPU en 34 min de reloj = 8.5x de
paralelismo, contra 10.7x de la corrida ancha). **El angosto no paga: gasta la misma CPU por menos
tests.** El angosto solo sirve cuando el crate tocado es chico (slot 5237: 86 tests, 12 s, 0.25 core-h).

---

## 2. Gates que fallan o se difieren, con el error exacto

### 2.1 Los 15 veredictos del disco

| Slot | PR | GATE_STATUS | VERDICT | CHECKS | DEFERRED |
|------|-----|-------------|---------|--------|----------|
| 0 | — | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|**check:skipped** | — |
| 1 | — | **skipped** | **SKIP** | fmt:ok\|layers:ok\|clippy:ok\|check:ok | **nextest-timeout** |
| 10138 | — | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |
| **10159** | **10618** | **skipped** | **SKIP** | **fmt:skipped\|layers:skipped\|clippy:skipped\|check:skipped** | **scope-gate-alive** |
| 10181 | 10594 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |
| 10291 | 10390 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |
| 10626 | 10859 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |
| **10750** | — | finished | **ROJO-SCOPE** | fmt:ok\|layers:ok\|clippy:skipped\|check:skipped | — |
| 3892 | 9823 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|**clippy:skipped\|check:skipped** | — |
| **4712** | **11205** | finished | **ROJO-SCOPE** | **fmt:fail\|layers:ok\|clippy:fail\|check:fail** | — |
| 5237 | 11074 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|**check:skipped** | — |
| 5505 | 10790 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |
| 5858 | 9606 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |
| 6449 | — | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |
| 7114 | 9843 | finished | VERDE-SCOPE | fmt:ok\|layers:ok\|clippy:ok\|check:ok | — |

**2 de 15 slots (13%) no tienen veredicto utilizable** (slot 1 diferido por timeout, slot 10159 diferido
por `scope-gate-alive`). En 5 slots mas hay al menos una fase saltada: `check:skipped` en 3,
`clippy:skipped` en 3. `skipped` significa **"no nos enteramos"**, no "esta bien".

> Nota sobre el estado: **el slot 4712 cambio de SKIP a ROJO-SCOPE a las 17:41 CEST**, mientras se
> escribia este informe (corrida `0d74d8cae`, ver seccion 2.2 modo F). El PR #11205 ahora tiene un ROJO
> **real** de codigo, no un diferimiento. Los demas verdicts no cambiaron durante la medicion.

### 2.2 Los seis modos de fallo, con el error textual exacto

**(A) `DEFERRED=scope-gate-alive` — el gate no corrio (slots 10159 y 4712)**

```
gate-quick: the scope of the slot 10159 is deferred: another run holds the lock of its target
directory (/home/user/.local/share/solidcraft-orch/targets/slot-10159)
```
```
gate-quick: the scope of the slot 10626 is deferred: another run holds the lock of its target
directory (/home/user/.local/share/solidcraft-orch/targets/slot-10626)
```

Causa raiz en el codigo: el lock GLOBAL (`$GATES_DIR/scope.lock`) se toma en modo **SHARED**
(`flock -s`, `gate-quick.sh:1256`) y el del SLOT (`$GATES_DIR/<slot>/scope.lock`) en modo
**EXCLUSIVE** (`flock -x`, `gate-quick.sh:1272`), ambos con `GATE_SCOPE_LOCK_WAIT=0` (default,
`gate-quick.sh:368`). **Con dos gates del mismo slot vivos, el segundo no espera: se difiere al
instante.** Consecuencia medida: **11 arranques de scope del slot 10159 en 93 minutos** (journal, 15:44 a 17:17
CEST del 02-11) para **solo 4 logs**: 7 de los 11 arrancos mueren sin escribir log, y el veredicto que
queda en disco es un SKIP de diferenciacion.

**(B) `DEFERRED=nextest-timeout` — se acabo el presupuesto (slot 1, y la primera del 6449)**

```
gate-quick: the budget ran out during the clippy (...) phase
gate-quick: the phase clippy (...) did not finish: it is skipped
gate-quick: the budget ran out during the nextest (...) phase
gate-quick: the phase nextest (...) did not finish: it is skipped
gate-quick: the tests were cut by the timeout of the gate: the scope is deferred, not red
gate-quick: the scope is deferred (nextest-timeout), not red
gate-quick: SKIP, 0 new failure(s) in the scope
gate-quick: the scope was deferred (nextest-timeout): it is not a verdict
```
(`/tmp/gate-6449.log`, budget de 30 min). **38 de los 149 logs terminan en `EXIT=124`**, que es
exactamente el corte por presupuesto/timeout (`timeout --kill-after=30` en `phase()`).

**(C) `ROJO-SCOPE` de 4994 fallos que NO son una regresion (slot 10750)**

```
error: [double-spawn] failed to exec `"/home/user/.local/share/solidcraft-orch/targets/slot-10750/
ci/deps/solidcraft_ui_egui-92eab496131ebfcc" "--exact" "menu_tests::appearance_submenu_keyboard_
opens_beside_parent_and_left_returns_to_it" "--nocapture"`, current_dir:
`/home/user/solidcraft-wt/issue-10750/crates/ui-egui`

    Caused by:
      No such file or directory (os error 2)

    (test failed with exit code 70)
```
**4994 ocurrencias de `double-spawn failed to exec`, 0 `panicked at`, 0 asserts rotos.** El veredicto
registra `ROJO-SCOPE NEW_FAILURES=2501`. El target dir se borro con el gate vivo (esta en
`state.json` -> `errores_mios.borrar_el_target_de_un_slot_con_su_gate_vivo`).

**(D) Syntax error que mato DOS gates en paralelo (01-11 17:54 y 18:32)**

```
/home/user/.local/share/solidcraft-loop/bin/gate-quick.sh: line 1886: syntax error near unexpected
token `then'
/home/user/.local/share/solidcraft-loop/bin/gate-quick.sh: line 1886: ` "$NEXTEST_STATUS" -eq 137
]; then'
```
`A_RC=2` y `B_RC=2` en `/tmp/gate-A.log` y `/tmp/gate-B.log`. Causa: **una edicion a medio hacer de
`gate-quick.sh` mientras dos gates lo estaban leyendo**. Bash lee el script por offset de byte: si el
archivo cambia mientras corre, lee basura. Hoy `bash -n gate-quick.sh` da rc=0 (esta arreglado), pero
el modo de fallo queda: **editar `gate-quick.sh` con gates corriendo los mata**.

**(E) Target dir borrado con el gate vivo (slot 7114, `gate-quick-f4c4061ca6-1793535629.log`)**

```
error: could not parse/generate dep info at: /home/user/.local/share/solidcraft-orch/targets/
slot-7114/ci/deps/solidcraft_kernel-b6a3087487c8211f.d
error: Unable to proceed. Could not locate working directory.: No such file or directory (os error 2)
```
`EXIT=1` a los 7.3 min. Mismo modo que (C).

**(F) Codigo roto de verdad (slot 4712, `gate-quick-nextest-0d74d8cae-1793636675.log`, 02-11 17:41)**

```
error: this file contains an unclosed delimiter
    --> crates/engine/src/cmd/sketch_modify_tests.rs:4793:3
     |
4725 | fn breaking_again_where_a_curve_was_broken_adds_nothing() {
     |                                                           - unclosed delimiter
...
4793 | }
     |  ^
error: could not compile `solidcraft-engine` (lib test) due to 1 previous error
error: command `... cargo '--color=always' test --no-run ... --package solidcraft-engine
--profile ci --locked' exited with code 101
```
`EXIT=101`. Este **si** es un fallo real de codigo (un archivo de test sin cerrar), y es el unico de
la muestra que no es de infraestructura.

### 2.3 Recuento de los exits en los 149 runs

| `EXIT=` | Corridas | Significado |
|---------|----------|-------------|
| `0` | 25 | verde |
| `124` | **38** | cortado por presupuesto/timeout |
| sin `EXIT=` | **72** | matado (no llego a escribir exit) |
| `100` | 11 | test run failed (9 de ellos con 32 fallos de UI, 1 el 10750 con 4994, 1 el ec34a51c7 con 2 reales) |
| `1` / `101` / `102` | 1 / 1 / 1 | target borrado / codigo roto / `cargo metadata` fallo |

**46% de los runs de los slots de PR (12 de 26) no llegaron a la suite de tests completa.**

### 2.4 Un fallo latente de la logica del gate (no aparece en los logs)

`gate-quick.sh:1508` escribe el veredicto SKIP de la diferenciacion **encima del veredicto anterior del
slot** (`write_scope_file` hace `rm -f "$file"` al principio, `gate-quick.sh:1325`).
La proteccion "este sha ya esta" (`scope_verdict_is_fresh`, `:1498`) **solo se evalua cuando el lock
se pudo tomar**. Cuando el lock esta tomado y el sha es DISTINTO, la diferenciacion **borra el
veredicto bueno y deja un SKIP**.

Verificado en disco: `gates/10159/scope.verdict` dice hoy `GATE_STATUS=skipped / VERDICT=SKIP /
SHA=aee25f106 / DEFERRED=scope-gate-alive`, mientras el espejo `gates/scope-10159/verdict` conserva el
veredicto anterior (`aee25f1060d1...`, `EXIT_CODE=124`, `RUN_CUT=true`). El PR #10618 tiene head
`aee25f1060` y su veredicto vigente es un SKIP de diferenciacion: **`verify-pr.sh` lo reportaria como
FAIL**, que es el resultado correcto, pero por el motivo equivocado.

---

## 3. El costo por PR abierto

### 3.1 La tabla

| PR | Slot | Corridas | Reloj total | nextest | **core-h** | Tests | `Compiling` | `Checking` | Veredicto |
|----|------|----------|-------------|---------|-----------|-------|-------------|-------------|----------|
| 9843 | 7114 | **13** | 403.5 min | 203.7 min | **55.77** | 58 674 | 1 033 | 790 | VERDE |
| 10390 | 10291 | 2 | 42.5 min | 9.0 min | 3.60 | 4 348 | 321 | 258 | VERDE |
| 10594 | 10181 | 2 | 74.6 min | 22.5 min | 8.71 | 7 696 | 348 | 282 | VERDE |
| 10618 | 10159 | 4 | 93.8 min | 8.8 min | 5.10 | 4 477 | 311 | 73 | **SKIP** |
| 10790 | 5505 | 1 | 16.2 min | 1.5 min | 0.54 | 336 | 95 | 381 | VERDE |
| 10859 | 10626 | 1 | 40.8 min | 26.8 min | 2.67 | 3 396 | 93 | 384 | VERDE |
| 11074 | 5237 | 1 | 6.0 min | 0.2 min | 0.25 | 86 | 82 | 338 | VERDE |
| 11205 | 4712 | 2 | 27.2 min | 0.0 min | 0.15 | 0 | 138 | 370 | **ROJO** |
| **TOTAL** | | **26** | **705 min (11.7 h)** | **272 min** | **76.80** | **79 013** | **2 421** | **2 876** | |
| **MEDIA/PR** | | **3.2** | **88 min** | **34 min** | **9.60** | **9 877** | **303** | **360** | |

**"Corridas" = logs de gate con su timestamp.** El journal muestra **mas arranques que logs** en los
slots conflictivos: 10159 tiene **11 arranques** de scope para 4 logs (7 de los 11 mueren sin escribir
log: los lanzados mientras otro gate tenia el lock), 4712 tiene **3 arranques** para 2 logs, y
7114 tiene **15 arranques** para 13 logs. El desfaste ES el diferimiento: cada arranque que no obtiene
el lock muere en segundos sin log.

**Sin el outlier 7114** (7 PRs): **41 min de reloj y 3.00 core-h por PR, 1.9 corridas por PR.**
Mediana de core-h por PR: **3.13** (0.15, 0.25, 0.54, 2.67, 3.60, 5.10, 8.71, 55.77).

### 3.2 Lectura

- **9.6 core-h por PR es un promedio inflado por un solo PR.** La mediana real es **3.1 core-h**.
- **Llamadas de compilacion por PR**: el gate hace **5 invocaciones de cargo por corrida** (`fmt`,
  `xtask layers`, `clippy`, `check --workspace`, `nextest`), de las cuales **3 compilan** (clippy,
  check, nextest). Medido en el PR #9843: **1 033 `Compiling` + 790 `Checking` = 1 823 unidades de
  compilacion para un solo PR**, con **3 compilaciones del mismo crate por corrida**.
- **El PR #9843 costo 6x el PR mas caro del resto** (55.8 vs 8.7 core-h) y **13 corridas para un PR**.
  Se gateo **6 veces el mismo sha `857e45f8c`**:

  ```
  11-01 09:31  wall 45.2m  nextest 22.7m  7724 tests  comp=371  <- corrida en frio
  11-01 11:49  wall 22.5m  nextest 21.7m  7724 tests  comp=0    <- ya tibio, PERO CORRIO IGUAL
  11-01 12:20  wall 33.6m  nextest 18.7m  7278 tests  comp=111  <- scope angosto, CORRIO IGUAL
  11-01 13:19  wall 35.2m  nextest 34.5m  7724 tests  comp=0    <- CORRIO IGUAL
  11-01 14:05  wall 27.1m  (sin nextest)                  <- CORRIO IGUAL
  11-01 15:03  wall 35.8m  nextest 34.9m  7278 tests  comp=0    <- CORRIO IGUAL
  ```
  Esas 6 corridas: **199 min de reloj y 28.2 core-h** para producir **un** veredicto. El veredicto que
  hay en disco (`gates/7114/scope.verdict`, `AT=1793558384`, `SHA=857e45f8c`) es el de la **ultima**
  (15:03). Las 5 anteriores fueron trabajo tirado.
- **Por que se repitio**: la unica proteccion contra esto esta en `gate-quick.sh:1497-1504`
  (`scope_verdict_is_fresh`), y **solo se evalua en la rama de la diferenciacion**. En el camino normal
  del gate **no hay ninguna comprobacion de "este sha ya tiene veredicto"**: el gate no tiene salida
  temprana por veredicto existente.
- Y el orquestador tiene el mismo bug en su runner: `gate-runner.sh:25` busca
  `GATE_STATUS=(passed|green|ok|done|complete)`, pero **el gate escribe `GATE_STATUS=finished`**
  (13 de 15 veredictos) o `skipped` (2). Verificado sobre los 15 veredictos del disco: **`served()` da
  "servido" en 0 de 15 casos.** El runner, por tanto, **siempre relanza el gate, aunque el veredicto
  verde del sha ya este en disco.** Ese es el mecanismo exacto de las 6 corridas repetidas del sha
  `857e45f8c` y de las 12 del `f075348aa2` (slot 0).
- Nota: el runner pasa shas **cortos** (`run_one 10159 aee25f106`, `gate-runner.sh:51-52`) y
  `served()` compara con `grep -q "SHA=$sha"`. En los veredictos del disco la longitud del SHA es
  **inconsistente** (40 chars en 10181/10291/0/1, **9 chars en 10138 y 10159**), asi que el
  `grep` de prefijo matchea por suerte en unos casos y no en otros. Con `GATE_STATUS=finished` el
  segundo `grep` falla siempre, de modo que hoy **el atajo nunca se toma**.

---

## 4. Tres optimizaciones concretas

### OPTIMIZACION 1 — Que el gate NO se relance cuando el sha ya tiene veredicto, y que el runner reconozca el veredicto real

**Que cambia:**
1. En `gate-quick.sh`, invocar `scope_verdict_is_fresh` **antes** de las fases (no solo en la rama de
   la diferenciacion): un gate cuyo sha ya esta verificado sale con rc=0 sin compilar.
2. En `gate-runner.sh:25`, corregir el vocabulario de `served()` a
   `GATE_STATUS=(finished|passed|green|ok|done|complete)`.
3. De paso, `write_scope_file` (`gate-quick.sh:1325`) no debe hacer `rm -f` de un veredicto de otro sha
   cuando lo que se escribe es un SKIP de diferenciacion.

**El numero que lo justifica:**
- `served()` hoy da "servido" en **0 de 15** veredictos del disco → **el runner relanza el 100% de los
  gates**, aunque el veredicto verde ya este ahi.
- El PR #9843 tiene **6 corridas del mismo sha** que costaron **199 min de reloj y 28.2 core-h**
  (28.2 de los 55.8 core-h del PR) para producir **un** veredicto. El slot 0 tiene **12** corridas del
  mismo sha, el slot 10138 **9**, el slot 1 **7 y 6**.
- Con los 26 runs de los 8 PRs, **12 (46%) fueron redundantes o no produjeron veredicto**.
- Ahorro estimado: **~30 core-h (39% del total de los 8 PRs) y ~3 h de reloj de maquina**, sin tocar
  una sola fase ni perder una sola cobertura.

**Riesgo:** bajo. La comprobacion ya existe (`scope_verdict_is_fresh`) y ya compara el sha; lo que
falta es invocarla en el camino feliz. Es una guarda, no una reescritura.

---

### OPTIMIZACION 2 — Que el clippy entre en su slice: una compilacion del scope en vez de dos, y target tibio por slot

**Que cambia:**
1. Reordenar para que `clippy` y `check --workspace` **compartan el build del scope**, en vez de que
   cada uno compile el suyo: hoy el mismo crate se compila **3 veces por gate** (clippy, check, build de
   los binarios de test).
2. Cuando `clippy` no entre en su slice, **no cortarlo a medias**: hoy se corta, y el gate publica
   `clippy:skipped` (3 de 15 veredictos) — es decir, **publica sin linter** y el linter se descubre
   tarde, en el CI del upstream.
3. En el cold start, **copiar el `ci/` de un slot ya caliente** al slot nuevo, como ya prescribe el
   skill del orquestador.

**El numero que lo justifica:**
- **22 crates se compilan 3 veces** en una sola corrida en frio (341 crates distintos, 421
  invocaciones `Compiling`/`Checking` en `gate-quick-857e45f8c-1793536304.log`). Los 3 juegos de
  artefactos son clippy, check y nextest.
- El **clippy frio medido** fue de **1048 s** (slot 10750), **959 s** (slot 10291) y **868 s** (slot
  10181) contra un slice de 15% = **675 s** (budget 75 min): **el clippy no entra y se corta**, dejando
  3 slots sin linter en el veredicto.
- **El target tibio vale la mitad del reloj**: mismo sha, mismo slot — 09:31 con target frio
  (**45.2 min**, `comp=371`) vs 11:49 con target tibio (**22.5 min**, `comp=0`). **22.7 min por
  corrida, 50% menos.**
- El precio de no compartir: `du -sh` da **79 GB** en `solidcraft-orch/targets/` (slot-4712 = 18 GB,
  slot-10159 = 13 GB, slot-10747b = 11 GB) y **225 GB libres** de 492.

**Riesgo:** medio. Cambiar el orden de las fases toca la logica de budgets, que tiene reglas propias
(el slice del clippy tiene que cubrir una compilacion entera). **La copia del target tibio es la de
mejor rendimiento por unidad de esfuerzo: 22.7 min por corrida, a cambio de un `cp -a`.**

---

### OPTIMIZACION 3 — Un gate a la vez, de verdad: consolidar los lanzadores, esperar en vez de diferir, y no pisar el veredicto

**Que cambia:**
1. Consolidar `gate-runner.sh`, `gate-watcher.sh`, `gate-watcher2.sh` y `gate-queue.sh` en **un
   unico corredor en serie**. Hoy los cuatro coexisten y relanzan el mismo slot en paralelo: el
   runner existe justamente para evitar eso, pero no es el unico que lanza.
2. Cambiar `GATE_SCOPE_LOCK_WAIT=0` por una **espera con timeout** (p. ej. 300 s), para que el segundo
   gate del mismo slot **espere** en vez de escribirse como SKIP.
3. No borrar el target dir de un slot mientras su gate sigue vivo (causa de los modos de fallo C y E).

**El numero que lo justifica:**
- **11 arranques de scope del slot 10159 en 93 minutos** (journal, 15:44-17:17 CEST) para solo **4 logs**
  — los 7 sobrantes mueren en segundos al no obtener el lock — con **5.1 core-h** consumidos y el
  veredicto final del slot siendo un SKIP de diferenciacion: el PR #10618 sigue sin veredicto verde.
- **12 de 26 corridas (46%)** de los slots de PR quedaron diferenciadas, cortadas o con error, y **1 de
  los 8 PRs (#10618) no tiene veredicto utilizable** = **13% de los PRs publicados sin gate valido**
  (el #11205 paso de SKIP a ROJO real durante la medicion; ver seccion 2.1).
- La diferenciacion **borra el veredicto anterior del slot** (`gate-quick.sh:1325` + `:1508`): el
  PR #10618 tiene hoy un SKIP en disco donde deberia tener su veredicto. Con espera en vez de
  diferenciacion, ese archivo nunca se pisa.
- El costo de un ROJO de infraestructura (slot 10750) fue **4994 falsos fallos y 0.88 core-h**
  quemados en una hora de trabajo que no era de codigo.
- Regla de higiene que sale de (D): **no editar `gate-quick.sh` con gates corriendo** — el syntax error
  de las 17:54 y 18:32 mato dos gates y los dos dejaron sin veredicto.

**Riesgo:** bajo. Es coordinacion, no logica de gate. El unico cambio de comportamiento real es
`GATE_SCOPE_LOCK_WAIT` de 0 a 300 s, que convierte "diferirse" en "esperar y despues correr".

---

## 5. Que NO se puede acortar (para no perder cobertura)

Se deja deliberadamente sin tocar, con su numero:

1. **`check --workspace --all-targets` (8% del budget).** Un dependiente que no compila es rojo igual,
   asi que no se puede angostar al scope. Medido: 12-594 s.
2. **`fmt` (2%).** Juzga el repo entero: es donde se atrapa el violation de formato de un commit
   anterior. Cuesta 0.2-0.5 s.
3. **La suite completa del nextest en `engine`/`ui-egui`.** Acortar el scope **no** acorta el gate
   ahi: 7278 tests (angosto) tardaron **1122 s** y 7724 (ancho) **1361 s** — y el angosto gastó
   **8.5x de paralelismo contra 10.7x** del ancho: **misma CPU por menos tests**. Solo paga en crates
   chicos (slot 5237: 86 tests, 12 s).
4. **Subir el numero de hilos del nextest.** Con 8 hilos el paralelismo medido es 10.7x sobre 16
   nucleos y el reloj ya esta empaquetado (`sum/hilos` = 1723 s > los 1399 s reales). El reloj lo fija
   un unico test lento (360-441 s = 29-34% del run).
5. **Correr dos gates en paralelo.** `state.json` -> `medicion_caja` ya lo midio: la caja esta
   **saturada de CPU (99.5%, 15.9 de 16 nucleos)**, no de RAM, y **2 gates en paralelo NO duplican el
   rendimiento (cada uno ~3x mas lento)**. El paralelismo que si rinde es mas agentes implementando
   mientras un gate corre.

---

## 6. Metodo y reproducibilidad

- **Fases y duraciones:** de los 149 `gate-quick-*.log` (`solidcraft-loop/logs/`), leyendo
  `Finished \`ci\` profile ... target(s) in X` y `Summary [X.XXXs] N tests run: N passed (M slow),
  K skipped`. Los logs traen secuencias ANSI: se quitan antes de parsear. Los `Summary` van con
  corchetes con padding (`Summary [  87.633s]`) y parentesis opcionales (`(60 slow, 1 leaky)`): un
  regex estricto los pierde — por eso el total de tests se tomo de los 231 logs
  `gate-quick-nextest-*.log` (no del log principal, que no los tiene).
- **CPU y RAM por corrida:** `journalctl --user | grep 'solidcraft-gate-quick.*Consumed'`, que systemd
  emite al cerrar cada scope con `Consumed X CPU time, Y memory peak`. **3533 lineas parseadas**
  (de 3536; 3 sin formato de CPU). El nombre del scope es
  `solidcraft-gate-quick-<slot>-<pid>.scope` y el PID es el que correlaciona el run con su scope.
- **Wall clock por corrida:** `mtime(log) - epoch_del_nombre` (el nombre del log lleva el epoch de
  arranque).
- **Repeticion por paquete:** `grep -oE '(Compiling|Checking) <crate> v'` sobre el log de la corrida,
  contado por crate.
- **Veredictos:** `solidcraft-loop/gates/*/scope.verdict` (los 15). El mirror de la version vieja esta
  en `gates/scope-<slot>/verdict` y conserva `EXIT_CODE`/`RUN_CUT`.
- **PRs:** `gh pr list --repo tangency-labs/solidcraft --state all` filtrado por
  `author.login == "vdirienzo"` (9 PRs; el #8059 es docs-only y no lleva gate por la exencion de docs
  del upstream). Mapa slot↔PR: `7114→9843`, `10291→10390`, `10181→10594`, `10159→10618`, `5505→10790`,
  `10626→10859`, `5237→11074`, `4712→11205`.
- **Zona horaria:** el journal y los logs usan CEST (+01:00); `state.json` usa -03:00. Las duraciones
  son relativas (epoch a epoch) y no dependen de esa conversion.

### Lo que NO se hizo (por instruccion)

No se modifico ningun script, no se hizo ningun commit, no se abrio ningun PR, no se corrio cargo y
no se lanzo ningun gate. `verify-pr.sh` **no** se ejecuto (para no generar efectos); se leyo su
codigo para confirmar como lee el veredicto. Todos los scripts citados fueron leidos, no modificados.
Los indices de analisis quedaron en `/home/user/.hermes/cache/scratch/` (`gate_index3.json`,
`slot_cpu2.json`, `scope_cpu2.json`, `journal-gate.txt`).
