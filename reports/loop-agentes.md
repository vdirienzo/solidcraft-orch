# El loop de subagentes de SolidCraft: 129 agentes, 283 horas, 5 entregas

**Fecha:** 2026-11-02 · **Fuente:** transcripts completos en
`/home/user/.hermes/cache/delegation/live/*/task-*.log` (132 archivos, 87 delegaciones;
3 corresponden a este mismo lote de análisis y quedan fuera de las mediciones).

**Alcance del corpus:** 2026-10-30 01:48 → 2026-11-02 17:12.

**Cómo se cuentan las lecturas y las escrituras.** Cada línea de un transcript tiene la
forma `HH:MM:SS tool | -> <herramienta>(<args>)`. Se clasifica la *llamada*:
`read_file`, `search_files`, `web_extract`, `web_search`, `vision_analyze`, `skill_view`
y las llamadas `terminal` cuyo comando es de solo lectura (`grep`, `cat`, `ls`, `sed -n`,
`head`, `tail`, `git status|log|diff|show|branch`, `gh pr|issue|api|search`, `ps`, `df`,
`du`) cuentan como **lectura**; `write_file`, `patch`, `skill_manage` y las llamadas
`terminal` cuyo comando escribe (`git commit|add|push|apply`, `sed -i`, `cp`, `mv`, `>`,
`>>`, `gh pr create|edit|ready`, `cargo build|test|clippy|fmt|nextest`, `git worktree add`)
cuentan como **escritura**. El resto queda en «otras». La duración es la del campo
`duration=` de la línea `final`, o el delta entre la primera y la última marca de tiempo
del transcript si falta.

**Nota sobre `state.json`.** El bloque `medicion_del_loop` de
`/home/user/.local/share/solidcraft-orch/state.json` cuenta 132 subagentes, 54 091
«lecturas» y 1 946 escrituras (ratio 28:1). Sus «lecturas» son **líneas de evento**
(llamadas + resultados: 53 801 de las 77 748 líneas del corpus), no lecturas semánticas.
Con la clasificación semántica de arriba el ratio real es **11:1** (19 202 lecturas /
1 675 escrituras). Las dos cifras no se contradicen: miden cosas distintas, y la que
importa para decidir es la segunda.

---

## 1. Los 129 subagentes, uno por uno

Leyenda de estado: `completed` = terminó con `exit_reason=completed`; `max_iter` =
`exit_reason=max_iterations` (**el subagente se reporta como `status=completed` — ver
error E1**); `interrupted` = la entrega se cortó; `error` = falló; `en-curso` = el
transcript no tiene línea final (aún corriendo o cortado antes de escribir).

Commit / PR: `sí` = verificado en el transcript (salida real de `git commit` o URL de
`gh pr create`); `declarado` = el subagente afirma un SHA o un número de PR en su
informe pero no se verificó la operación en el transcript; `cmd s/e` = se ejecutó el
comando pero su salida no lo confirma; `no` = no dejó nada.

| Subagente | Inicio | Objetivo | Issue | Lect | Esc | Calls | min | Estado (razón) | Commit | PR |
|---|---|---|---|---|---|---|---|---|---|---|
| `deleg_3ddb905e/0` | 2026-10-30 01:48 | Read the SolidCraft agent-facing policy docs on disk and return a COMPACT rule sheet (max 45… | — | 40 | 0 | 42 | 3 | completed (completed) | — | — |
| `deleg_3ddb905e/1` | 2026-10-30 01:48 | Produce a ranked, actionable triage list of open SolidCraft issues for an agent to claim. Up… | — | 12 | 0 | 21 | 18 | interrupted (interrupted) | — | — |
| `deleg_3ddb905e/2` | 2026-10-30 01:48 | Inventory every local git worktree, branch and build directory for the SolidCraft work, map… | — | 66 | 2 | 84 | 18 | interrupted (interrupted) | — | — |
| `deleg_3ddb905e/3` | 2026-10-30 01:48 | Audit the 4 open PRs owned by vdirienzo on tangency-labs/solidcraft and report their exact h… | — | 49 | 1 | 67 | 18 | interrupted (interrupted) | — | — |
| `deleg_fd304640/0` | 2026-10-30 02:07 | Produce a ranked, actionable triage list of open SolidCraft issues for an agent to claim. Re… | — | 110 | 1 | 139 | 45 | completed (completed) | — | — |
| `deleg_2a7459ae/0` | 2026-10-30 04:21 | Deep-verify two candidate SolidCraft issues (#9080 and #9087) for pickability, so one can be… | #9080,#9087 | 137 | 0 | 140 | 23 | completed (completed) | — | — |
| `deleg_3c60dd73/0` | 2026-10-30 05:46 | Find the single best clean, single-topic, unclaimed SolidCraft issue to work in parallel (is… | #9087 | 74 | 0 | 122 | 45 | completed (completed) | — | — |
| `deleg_4e5c2fa3/0` | 2026-10-30 07:12 | Pick the single best next SolidCraft issue to implement: a clean, single-topic, unclaimed bu… | — | 44 | 1 | 56 | 11 | completed (completed) | — | — |
| `deleg_57ff0d50/0` | 2026-10-30 08:53 | Pick the 2 best unclaimed, implementable issues in the SolidCraft repo for a multi-agent PR… | — | 4 | 0 | 110 | 70 | completed (completed) | — | — |
| `deleg_d86067fe/0` | 2026-10-30 10:19 | Fix issue #7114 in the tangency-labs/solidcraft repo (Rust CAD app), verify it with a RED->G… | #7114 | 84 | 6 | 253 | 255 | interrupted (interrupted) | — | — |
| `deleg_ca46cbe0/0` | 2026-10-30 10:35 | Fix issue #9062 in the tangency-labs/solidcraft repo (Rust CAD app): a construction line in… | #9062 | 259 | 72 | 340 | 127 | completed (max_iter) | — | — |
| `deleg_ca46cbe0/1` | 2026-10-30 10:35 | Fix issue #3892 in the tangency-labs/solidcraft repo (Rust CAD app): hovering the browser tr… | #3892 | 266 | 27 | 356 | 174 | completed (max_iter) | — | — |
| `deleg_a6fcaabc/0` | 2026-10-30 11:31 | Fix SolidCraft issue #7114: 'Sketch snapping is not apparent at visible grid intersections d… | #7114 | 470 | 0 | 472 | 257 | completed (max_iter) | — | — |
| `deleg_a6fcaabc/1` | 2026-10-30 11:31 | Fix SolidCraft issue #9062: 'Sketch: construction line deletes itself'. Produce a draft PR o… | #9062 | 245 | 48 | 330 | 145 | completed (max_iter) | — | — |
| `deleg_a6fcaabc/2` | 2026-10-30 11:31 | Fix SolidCraft issue #5858: 'A sketch curve id with a pipe character breaks face names'. Pro… | #5858 | 108 | 2 | 272 | 224 | completed (max_iter) | — | — |
| `deleg_6019ae49/0` | 2026-10-30 13:36 | Fix issue #3892 in the tangency-labs/solidcraft repo (Rust CAD app): hovering the browser tr… | #3892 | 62 | 8 | 75 | 59 | interrupted (interrupted) | — | — |
| `deleg_52e15b89/0` | 2026-10-30 16:16 | Terminar el fix de performance para el issue #3892 (browser tree lento con un assembly STEP… | #3892 | 27 | 0 | 27 | 7 | interrupted (interrupted) | — | — |
| `deleg_52e15b89/1` | 2026-10-30 16:16 | Arreglar el issue #5858 ("A sketch curve id with \"/\" breaks face names") en SolidCraft y a… | #5858 | 45 | 0 | 46 | 7 | interrupted (interrupted) | — | — |
| `deleg_52e15b89/2` | 2026-10-30 16:16 | Arreglar el issue #7114 ("Sketch snapping is not apparent at visible grid intersections desp… | #7114 | 52 | 0 | 52 | 7 | interrupted (interrupted) | — | — |
| `deleg_52e15b89/3` | 2026-10-30 16:16 | Arreglar el issue #9062 ("Sketch: construction line deletes itself") en SolidCraft y abrir e… | #9062 | 58 | 1 | 68 | 7 | interrupted (interrupted) | — | — |
| `deleg_bc82aff0/0` | 2026-10-30 16:18 | Reconciliar el PR draft #8059 con el main actual y dejarlo listo para review en https://gith… | #8059 | 21 | 2 | 28 | 5 | interrupted (interrupted) | — | — |
| `deleg_b87aa87a/0` | 2026-10-30 17:46 | Triaje de issues abiertos de SolidCraft: produce una lista de candidatos accionables para un… | — | 2 | 0 | 20 | 9 | interrupted (interrupted) | — | — |
| `deleg_b87aa87a/1` | 2026-10-30 17:46 | Implementa el fix de performance del issue #3892 y abre el PR draft. El trabajo previo ya es… | #3892 | 25 | 0 | 26 | 9 | interrupted (interrupted) | — | — |
| `deleg_b87aa87a/2` | 2026-10-30 17:46 | Implementa el fix del issue #7114 (snapping de sketch no aparente en intersecciones visibles… | #7114 | 62 | 0 | 62 | 9 | interrupted (interrupted) | — | — |
| `deleg_b87aa87a/3` | 2026-10-30 17:46 | Termina el PR draft #8059 de SolidCraft: rebasa sobre main actual, pushea y pasalo a READY F… | #8059 | 41 | 2 | 50 | 9 | interrupted (interrupted) | — | — |
| `deleg_efcc0ddb/0` | 2026-10-30 17:47 | Limpieza de disco y de worktrees muertos del proyecto SolidCraft, sin tocar nada que este en… | — | 22 | 1 | 24 | 9 | interrupted (interrupted) | — | — |
| `deleg_b2d8beb7/0` | 2026-10-30 17:48 | Termina el fix del issue #5858 ("A sketch curve id with / breaks face names") y abre el PR d… | #5858 | 36 | 0 | 36 | 8 | interrupted (interrupted) | — | — |
| `deleg_8ab13997/0` | 2026-10-30 18:25 | Publicar el fix del issue #5858 (SolidCraft, upstream tangency-labs/solidcraft) como un PR d… | #5858 | 147 | 19 | 225 | 128 | completed (completed) | sí (verificado) | sí (verificado) |
| `deleg_8ab13997/1` | 2026-10-30 18:25 | Terminar el fix de performance del issue #3892 (SolidCraft, upstream tangency-labs/solidcraf… | #3892 | 165 | 5 | 183 | 192 | completed (completed) | — | — |
| `deleg_8ab13997/2` | 2026-10-30 18:25 | Arreglar el issue #7114 (SolidCraft, upstream tangency-labs/solidcraft) y publicarlo como PR… | #7114 | 383 | 8 | 459 | 343 | completed (max_iter) | — | — |
| `deleg_610c98d5/0` | 2026-10-30 21:56 | Terminar el fix de performance del issue #3892 (SolidCraft) y publicarlo como PR draft desde… | #3892 | 183 | 38 | 238 | 321 | completed (completed) | declarado | sí (verificado) |
| `deleg_d4f43dd2/0` | 2026-10-31 00:09 | Terminar el fix del issue #7114 (SolidCraft) conectando los helpers ya escritos al snapping… | #7114 | 370 | 36 | 426 | 226 | completed (max_iter) | cmd, sin salida | — |
| `deleg_538f0296/0` | 2026-10-31 05:06 | Corregir la regresión que el gate detectó en el PR #9843 (issue #7114): el criterio con el q… | #7114,#9843 | 128 | 27 | 205 | 303 | completed (completed) | — | — |
| `deleg_0b5f1db2/0` | 2026-10-31 10:11 | Corregir el criterio con el que un punto del sketch cae en el cruce de la grilla visible (PR… | #7114,#9843 | 96 | 29 | 165 | 87 | completed (completed) | — | — |
| `deleg_5a2f9716/0` | 2026-10-31 12:48 | Capturar la evidencia visual del issue #7114 (SolidCraft): dos PNG del viewport que muestren… | #7114,#9843 | 179 | 32 | 242 | 85 | completed (completed) | — | — |
| `deleg_f2f71df1/0` | 2026-10-31 16:36 | Resolver el issue #10134 de SolidCraft: el comando sketch.move falla con "unknown sketch ent… | #10134 | 293 | 32 | 356 | 163 | completed (completed) | — | no |
| `deleg_f2f71df1/1` | 2026-10-31 16:36 | Resolver el issue #10116 de SolidCraft (parte B): al guardar las preferencias, el modo de ve… | #10116 | 188 | 3 | 200 | 110 | completed (completed) | no | no |
| `deleg_7049cde9/0` | 2026-10-31 17:02 | Resolver el issue #10138 de SolidCraft: la app debe seguir el idioma del sistema por defecto… | #10138 | 204 | 4 | 219 | 163 | interrupted (interrupted) | — | — |
| `deleg_7049cde9/1` | 2026-10-31 17:02 | Resolver el issue #10079 de SolidCraft: al renombrar una segunda extrusión desde el browser,… | #10079 | 308 | 16 | 334 | 163 | interrupted (interrupted) | — | — |
| `deleg_abcad5ff/0` | 2026-10-31 19:54 | Retomar el issue #10079 de SolidCraft: al renombrar una segunda extrusión desde el browser s… | #10079 | 225 | 27 | 352 | 159 | completed (completed) | no | no |
| `deleg_abcad5ff/1` | 2026-10-31 19:54 | Retomar el issue #10138 de SolidCraft (idioma del sistema por defecto) sabiendo que el PR #1… | #10138,#10183 | 262 | 28 | 378 | 230 | completed (max_iter) | declarado | declarado |
| `deleg_e6daa4ac/0` | 2026-10-31 19:56 | Resolver el issue #10181 de SolidCraft: al proyectar una cara a un sketch la operación funci… | #10181 | 105 | 11 | 286 | 172 | completed (max_iter) | — | no |
| `deleg_e6daa4ac/1` | 2026-10-31 19:56 | Resolver el issue #10159 de SolidCraft: en Wayland el File > Open no usa el file chooser del… | #10159 | 107 | 4 | 308 | 177 | completed (max_iter) | — | no |
| `deleg_bdfde19c/0` | 2026-10-31 22:54 | Arreglar el bug de matching de idioma con subtag de script: macOS reporta el chino tradicion… | #10306 | 88 | 17 | 137 | 81 | completed (completed) | declarado | no |
| `deleg_cddfe059/0` | 2026-10-31 22:54 | Retomar el issue #10181 de SolidCraft: determinar si el panel que no se puede cerrar al proy… | #10181 | 380 | 16 | 447 | 243 | completed (max_iter) | — | — |
| `deleg_cddfe059/1` | 2026-10-31 22:54 | Retomar el issue #10159 de SolidCraft: el File > Open en Wayland cae en silencio al fallback… | #10159 | 406 | 0 | 481 | 223 | completed (max_iter) | no | no |
| `deleg_1dacab98/0` | 2026-10-31 23:42 | Arreglar el issue #6449 de SolidCraft: con la herramienta Sketch -> Reference -> Project act… | #6449 | 339 | 2 | 424 | 178 | completed (max_iter) | — | cmd, sin salida |
| `deleg_2d65dba0/0` | 2026-10-31 23:46 | Resolver el issue #10291 de SolidCraft: proyectar geometria desde un sketch en un plano para… | #10291 | 214 | 65 | 344 | 168 | completed (completed) | declarado | sí (verificado) |
| `deleg_2d65dba0/1` | 2026-10-31 23:46 | Resolver el issue #10331 de SolidCraft: la app solo acepta un joint planar y no deja crear u… | #10331 | 193 | 29 | 294 | 117 | completed (max_iter) | — | declarado |
| `deleg_225bd5f5/0` | 2026-11-01 00:22 | Endurecer el loop de claims de SolidCraft: que un PR nuestro NUNCA se publique si ya perdio… | — | 26 | 13 | 261 | 306 | completed (max_iter) | — | — |
| `deleg_8e04b29b/0` | 2026-11-01 02:41 | Contribuir al PR upstream #6457 (issue #6449, SolidCraft): verificar si su fix rebasa sobre… | #6449,#6457 | 129 | 56 | 272 | 196 | en-curso (—) | — | — |
| `deleg_60f5417b/0` | 2026-11-01 02:58 | Terminar el issue #10181 de SolidCraft: convertir la sonda de diagnóstico en un test RED rea… | #10181 | 194 | 8 | 219 | 179 | interrupted (interrupted) | — | — |
| `deleg_60f5417b/1` | 2026-11-01 02:58 | Terminar el issue #10159 de SolidCraft: que el host detecte la indisponibilidad del portal d… | #10159 | 154 | 1 | 212 | 179 | interrupted (interrupted) | — | — |
| `deleg_b888e674/0` | 2026-11-01 05:31 | Cerrar el trabajo del guard de claims: conectar claim-brake.sh al publisher (agent-issue.sh)… | — | 60 | 11 | 77 | 27 | en-curso (—) | — | cmd, sin salida |
| `deleg_e45e2e8d/0` | 2026-11-01 05:35 | Auditar el loop de SolidCraft en busca de bugs reales y arreglarlos con tests, dejando las d… | — | 67 | 4 | 79 | 22 | en-curso (—) | — | — |
| `deleg_55c98f84/0` | 2026-11-01 05:36 | Arreglar dos bugs de resultado falso en verify-pr.sh: un PR sin veredicto de gate sale como… | — | 37 | 1 | 40 | 21 | en-curso (—) | — | — |
| `deleg_d76f2e01/0` | 2026-11-01 05:40 | Arreglar el bug del gc-disk.sh que barre un arbol de targets muerto (28 GB) y nunca toca el… | — | 35 | 1 | 40 | 17 | interrupted (interrupted) | — | — |
| `deleg_cae06280/0` | 2026-11-01 05:42 | Arreglar el bug del slot-lock.sh: un lock de slot huerfano (sin 'since') queda tomado para s… | — | 18 | 0 | 32 | 16 | interrupted (interrupted) | — | — |
| `deleg_13439f46/0` | 2026-11-01 05:59 | UNA SOLA TAREA: convertir la sonda de diagnóstico del issue #10181 en un test RED real que f… | #10181 | 31 | 4 | 41 | 21 | completed (completed) | — | — |
| `deleg_13439f46/1` | 2026-11-01 05:59 | UNA SOLA TAREA: escribir la función de decisión del file picker y su test RED en los archivo… | — | 30 | 8 | 52 | 20 | completed (completed) | — | — |
| `deleg_754bcbeb/0` | 2026-11-01 06:01 | Completar el arreglo del gc-disk.sh: que la limpieza de disco conozca tambien los target dir… | — | 256 | 47 | 354 | 209 | completed (max_iter) | — | — |
| `deleg_b4e36260/0` | 2026-11-01 06:02 | Conectar el guard de claims al publisher de SolidCraft (agent-issue.sh): re-verificar el rec… | — | 219 | 38 | 304 | 255 | completed (max_iter) | — | cmd, sin salida |
| `deleg_ccae529f/0` | 2026-11-01 06:24 | UNA SOLA TAREA: implementar el fix de #10181 para que un error de contexto no ofrezca el bot… | #10181 | 109 | 22 | 155 | 99 | completed (completed) | declarado | — |
| `deleg_ccae529f/1` | 2026-11-01 06:24 | UNA SOLA TAREA: implementar el fix de #10159 (que el host detecte la indisponibilidad del po… | #10159 | 341 | 38 | 505 | 367 | completed (max_iter) | — | — |
| `deleg_b08d012a/0` | 2026-11-01 06:41 | UNA SOLA TAREA: escribir un test RED que demuestre que al reabrir un diseño guardado el hist… | — | 379 | 11 | 417 | 185 | completed (max_iter) | — | — |
| `deleg_bd30096a/0` | 2026-11-01 09:53 | UNA SOLA TAREA: correr el gate scoped del fix de #10181 (ya commiteado y verde) y abrir el P… | #10181 | 76 | 24 | 155 | 147 | completed (completed) | — | sí (verificado) |
| `deleg_65f3e9ea/0` | 2026-11-01 09:54 | UNA SOLA TAREA: escribir un test RED del issue #10339 para el caso de una pieza importada o… | #10339 | 321 | 48 | 386 | 170 | completed (max_iter) | — | — |
| `deleg_4c198635/0` | 2026-11-01 10:41 | Actualizar el test 53 de test-rules.py al contrato nuevo del freno de claims (claim-brake.sh… | — | 142 | 16 | 180 | 98 | interrupted (interrupted) | — | — |
| `deleg_e94e1396/0` | 2026-11-01 12:34 | UNA SOLA TAREA: correr el gate scoped del fix de #10159 (ya commiteado y verde) y abrir el P… | #10159 | 71 | 10 | 124 | 48 | completed (completed) | — | sí (verificado) |
| `deleg_1b236ffe/0` | 2026-11-01 13:01 | Rebasear la rama fix/issue-7114-snap-grid-visible sobre origin/main, resolver los conflictos… | #9843 | 89 | 8 | 137 | 80 | completed (completed) | declarado | — |
| `deleg_1b236ffe/1` | 2026-11-01 13:01 | Abrir el PR draft del trabajo ya commiteado de #10159 (file chooser portal fallback), con el… | #10159 | 62 | 3 | 72 | 13 | completed (completed) | — | sí (verificado) |
| `deleg_0da28c8a/0` | 2026-11-01 13:03 | Escribir una suite de tests para /home/user/.local/share/solidcraft-orch/bin/verify-pr.sh qu… | — | 41 | 18 | 94 | 78 | completed (completed) | — | — |
| `deleg_97a18525/0` | 2026-11-01 13:28 | Rebasear la rama fix/issue-7114-snap-grid-visible sobre origin/main en un worktree recreado,… | #9843 | 50 | 6 | 75 | 55 | completed (completed) | — | — |
| `deleg_956dce5f/0` | 2026-11-01 16:15 | Evaluar el issue #10626 de SolidCraft (sketch.project falla con 'already projected into this… | #10626 | 77 | 0 | 81 | 22 | completed (completed) | — | no |
| `deleg_ee684044/0` | 2026-11-01 18:14 | Salvar y publicar el trabajo sin pushear de la rama pr-10183 (i18n/localizacion, 19 archivos… | #10183 | 61 | 18 | 138 | 108 | completed (completed) | — | declarado |
| `deleg_ee684044/1` | 2026-11-01 18:14 | Salvar y publicar el trabajo sin pushear de las ramas fix/issue-10138-system-language y las… | #5505 | 139 | 24 | 214 | 129 | completed (completed) | — | cmd, sin salida |
| `deleg_83ff5751/0` | 2026-11-01 19:24 | Encontrar UN issue de SolidCraft con replay adjunto o error en la operacion (bug real y repr… | — | 195 | 2 | 333 | 171 | completed (max_iter) | — | no |
| `deleg_83ff5751/1` | 2026-11-01 19:24 | Encontrar UN issue de SolidCraft con replay adjunto o error en la operacion (bug real y repr… | — | 171 | 10 | 338 | 210 | completed (max_iter) | — | no |
| `deleg_498d22bc/0` | 2026-11-01 19:35 | Agregar un verificador del config.env del loop que detecte valores con espacios sin comillas… | — | 85 | 20 | 166 | 38 | completed (completed) | — | — |
| `deleg_904a99ba/0` | 2026-11-01 19:49 | Confirmar y arreglar el issue #10750 de SolidCraft (las dimensiones de la caja se permutan:… | #10750 | 301 | 33 | 416 | 231 | completed (max_iter) | — | — |
| `deleg_904a99ba/1` | 2026-11-01 19:49 | Confirmar y arreglar el issue #10656 de SolidCraft (rotar un body durante un move altera su… | #10656 | 411 | 8 | 453 | 261 | completed (max_iter) | — | — |
| `deleg_be329a7b/0` | 2026-11-01 20:29 | Agregar al GC de disco (bin/gc-disk.sh) un cap de tamano para el arbol de targets del orques… | — | 67 | 35 | 130 | 86 | completed (completed) | — | — |
| `deleg_dc4f85e4/0` | 2026-11-01 20:34 | Confirmar y arreglar el issue #10747 de SolidCraft (el valor de un parametro se reporta en u… | #10747 | 238 | 51 | 365 | 236 | failed (error) | cmd, sin salida | cmd, sin salida |
| `deleg_87f006e6/0` | 2026-11-01 20:41 | Capturar la evidencia visual del PR #10594 (el panel Project que muestra la fila roja con "C… | #10594 | 216 | 23 | 260 | 47 | completed (completed) | — | declarado |
| `deleg_87f006e6/1` | 2026-11-01 20:41 | Capturar la evidencia visual del PR #10618 (el mensaje del session log que dice que el file… | #10618 | 186 | 22 | 245 | 53 | completed (completed) | — | — |
| `deleg_f2476af0/0` | 2026-11-01 20:42 | Capturar la evidencia visual del PR #10390 (el dialogo Project que aceptaba la recta de otro… | #10390 | 214 | 17 | 270 | 61 | completed (completed) | — | declarado |
| `deleg_94ee5ea7/0` | 2026-11-01 21:36 | Arreglar el bug del mensaje vacio en LinkSource::describe() de SolidCraft (el mensaje 'face… | — | 125 | 38 | 236 | 167 | completed (completed) | — | cmd, sin salida |
| `deleg_08543365/0` | 2026-11-01 22:09 | Encontrar features del upstream SolidCraft que el mantenedor haya aprobado o invitado explic… | — | 38 | 0 | 88 | 12 | completed (completed) | — | — |
| `deleg_5c0fd3bc/0` | 2026-11-01 22:12 | Implementar la feature #10067 de SolidCraft (un color de theme por plano de origen: XY, XZ y… | #10067 | 283 | 1 | 291 | 126 | completed (completed) | — | — |
| `deleg_f61c6f03/0` | 2026-11-01 22:47 | Implementar la feature #5237 de SolidCraft (el command reference generado legible para un hu… | #5237 | 80 | 10 | 286 | 321 | completed (max_iter) | — | — |
| `deleg_e747db20/0` | 2026-11-01 23:41 | Implementar la feature upstream #9866 "Distribute selected objects within a specified bounda… | #9866 | 173 | 1 | 332 | 427 | completed (max_iter) | — | — |
| `deleg_e747db20/1` | 2026-11-01 23:41 | Implementar la feature upstream #4760 "Weld tool to create intersect point": un comando nuev… | #4760 | 466 | 2 | 472 | 234 | completed (max_iter) | — | — |
| `deleg_f87382ef/0` | 2026-11-02 00:17 | Capturar la evidencia visual del PR #10859 (el mensaje de rechazo de sketch.project): el BEF… | #10859 | 13 | 8 | 148 | 60 | completed (completed) | — | declarado |
| `deleg_b95fcbbe/0` | 2026-11-02 00:19 | Implementar la feature #10067 de SolidCraft: un color de theme por plano de origen (tokens o… | #10067 | 385 | 14 | 450 | 389 | completed (max_iter) | — | no |
| `deleg_9d98645b/0` | 2026-11-02 02:16 | Implementar la feature #3599 de SolidCraft: el constraint de sketch 'Pierce', que pone un pu… | #3599 | 472 | 5 | 479 | 374 | completed (max_iter) | — | — |
| `deleg_9d98645b/1` | 2026-11-02 02:16 | Implementar la feature #8434 de SolidCraft: una 'carbon copy' de un body, que sigue al origi… | #8434 | 208 | 40 | 252 | 262 | completed (completed) | — | — |
| `deleg_9d98645b/2` | 2026-11-02 02:16 | Encontrar UN bug real y reproducible del upstream SolidCraft (fuera del kernel, sin claim, c… | — | 139 | 0 | 320 | 131 | completed (max_iter) | — | — |
| `deleg_8bda54fd/0` | 2026-11-02 04:08 | Implementar la feature #5237 de SolidCraft: que el command reference generado (xtask/src/boo… | #5237 | 175 | 47 | 319 | 343 | completed (max_iter) | — | — |
| `deleg_1c27af77/0` | 2026-11-02 06:48 | Terminar la feature #10067 de SolidCraft (un color de theme por plano de origen: origin_plan… | #10067 | 225 | 0 | 414 | 460 | interrupted (interrupted) | — | — |
| `deleg_cb1f9157/0` | 2026-11-02 06:49 | Implementar la feature #9866 de SolidCraft: el comando nuevo solid.distribute que reparte lo… | #9866 | 446 | 0 | 448 | 243 | failed (error) | — | — |
| `deleg_cb1f9157/1` | 2026-11-02 06:49 | Implementar la feature #4760 de SolidCraft: el comando nuevo sketch.weld que une en un unico… | #4760 | 432 | 1 | 434 | 454 | interrupted (interrupted) | — | — |
| `deleg_c6a3e080/0` | 2026-11-02 08:32 | Terminar la feature #3599 de SolidCraft: implementar el constraint de sketch 'Pierce' partie… | #3599 | 432 | 9 | 453 | 310 | failed (error) | — | — |
| `deleg_c6a3e080/1` | 2026-11-02 08:32 | Arreglar el issue #4712 de SolidCraft: el item 4 (los errores que nombran comandos internos… | #4712 | 84 | 4 | 336 | 351 | interrupted (interrupted) | — | — |
| `deleg_c6a3e080/2` | 2026-11-02 08:32 | Terminar la feature #8434 de SolidCraft (una 'carbon copy' de un body que sigue al original… | #8434 | 386 | 16 | 416 | 356 | interrupted (interrupted) | — | — |
| `deleg_ba3ac879/0` | 2026-11-02 09:53 | Terminar la feature #5237 de SolidCraft: la implementacion YA esta escrita y en GREEN; falta… | #5237 | 66 | 16 | 126 | 45 | completed (completed) | sí (verificado) | sí (verificado) |
| `deleg_50c60574/0` | 2026-11-02 10:38 | Cerrar el gap del PR #11074: extender el parser de params para que no saltee los 48 comandos… | #11074 | 118 | 18 | 275 | 245 | completed (max_iter) | — | — |
| `deleg_41f47dc5/0` | 2026-11-02 10:52 | Escribir, en crates/doc/src/distribute.rs, la matematica de repartir N objetos dentro de un… | — | 45 | 25 | 85 | 46 | completed (completed) | cmd, sin salida | — |
| `deleg_9a28dceb/0` | 2026-11-02 11:38 | Integrar la feature #9866: con la matematica ya escrita y probada en crates/doc/src/distribu… | #9866 | 103 | 0 | 342 | 204 | interrupted (interrupted) | — | — |
| `deleg_e24e92cc/0` | 2026-11-02 13:42 | Escribir el constraint de sketch 'Pierce' en el crate solidcraft-sketch (la variante, sus me… | — | 16 | 0 | 49 | 70 | interrupted (interrupted) | — | — |
| `deleg_20fdfbf4/0` | 2026-11-02 14:23 | Escribir en el crate solidcraft-sketch la operacion de weld (unir en un punto compartido las… | — | 40 | 4 | 44 | 29 | interrupted (interrupted) | — | — |
| `deleg_20fdfbf4/1` | 2026-11-02 14:23 | Arreglar el issue #4712 de SolidCraft: que los errores nombren el comando PUBLICO y no un no… | #4712 | 93 | 0 | 94 | 29 | interrupted (interrupted) | — | — |
| `deleg_a06a6af5/0` | 2026-11-02 14:24 | Publicar el aporte complementario del issue #10747: que el comando inspect reporte el 'value… | #10747 | 113 | 22 | 167 | 173 | en-curso (—) | — | — |
| `deleg_64e6f922/0` | 2026-11-02 14:28 | Completar la plumbing de los tres tokens de color de plano (origin_plane_xy, origin_plane_xz… | — | 81 | 0 | 83 | 23 | interrupted (interrupted) | — | — |
| `deleg_64e6f922/1` | 2026-11-02 14:28 | Implementar en el crate solidcraft-doc el override por instancia (una copia de un body que s… | — | 65 | 0 | 71 | 23 | interrupted (interrupted) | — | — |
| `deleg_f2dcf821/0` | 2026-11-02 14:31 | Responder los dos cambios que pidio el mantenedor en el PR #10618: reescribir como mensajes… | #10618 | 83 | 12 | 160 | 142 | interrupted (interrupted) | — | — |
| `deleg_3536a9fc/0` | 2026-11-02 14:53 | Crear UN archivo nuevo, crates/sketch/src/weld.rs, con la funcion publica que weld las curva… | — | 17 | 0 | 17 | 15 | interrupted (interrupted) | — | — |
| `deleg_3536a9fc/1` | 2026-11-02 14:53 | Crear UN archivo nuevo, crates/sketch/src/pierce.rs, con la geometria del punto donde la cur… | — | 44 | 13 | 66 | 46 | completed (completed) | sí (verificado) | — |
| `deleg_3536a9fc/2` | 2026-11-02 14:53 | Crear UN archivo nuevo, crates/doc/src/occurrence_override.rs, con la logica del override po… | — | 47 | 0 | 47 | 15 | interrupted (interrupted) | — | — |
| `deleg_3bc23a05/0` | 2026-11-02 14:53 | Completar, con siete ediciones puntuales localizadas por grep, la plumbing de los tres token… | — | 83 | 0 | 83 | 16 | interrupted (interrupted) | — | — |
| `deleg_3bc23a05/1` | 2026-11-02 14:53 | Arreglar el issue #4712: que los errores de sketch.modify nombren el comando PUBLICO ('sketc… | #4712 | 127 | 14 | 160 | 119 | interrupted (interrupted) | — | — |
| `deleg_c7001e70/0` | 2026-11-02 15:01 | Crear UN archivo nuevo, crates/sketch/src/weld.rs, con la funcion publica que weld las curva… | — | 62 | 7 | 69 | 111 | interrupted (interrupted) | — | — |
| `deleg_c7001e70/1` | 2026-11-02 15:01 | Crear UN archivo nuevo, crates/sketch/src/pierce.rs, con la geometria del punto donde la cur… | — | 16 | 0 | 16 | 6 | interrupted (interrupted) | — | — |
| `deleg_c7001e70/2` | 2026-11-02 15:01 | Aplicar el cambio de cinco lineas que hace que los errores de sketch.modify nombren el coman… | — | 65 | 12 | 111 | 113 | interrupted (interrupted) | — | — |
| `deleg_b96b4dea/0` | 2026-11-02 15:03 | Agregar al crate solidcraft-doc el FeatureKind::Distribute y su evaluacion (con la matematic… | — | 44 | 0 | 44 | 7 | interrupted (interrupted) | — | — |
| `deleg_ad989aac/0` | 2026-11-02 15:07 | Arreglar el issue #5857 de SolidCraft: que el nombre de una cara con un nombre anidado deje… | #5857,#5861 | 173 | 4 | 190 | 127 | en-curso (—) | — | — |
| `deleg_ad989aac/1` | 2026-11-02 15:07 | Encontrar UN bug real del upstream SolidCraft (fuera del kernel, sin claim, con la causa rai… | — | 217 | 30 | 341 | 94 | en-curso (—) | — | — |
| `deleg_3c717bc5/0` | 2026-11-02 15:09 | Encontrar UN bug real y reciente del upstream SolidCraft (fuera del kernel, sin claim, con l… | — | 104 | 16 | 208 | 123 | en-curso (—) | — | — |
| `deleg_1a43a5b2/0` | 2026-11-02 15:11 | Cerrar el gap del PR #11074: arreglar el parser de params para los comandos cuyos params son… | #11074 | 20 | 0 | 20 | 4 | interrupted (interrupted) | — | — |
| `deleg_083c00cb/0` | 2026-11-02 15:40 | Agregar al crate solidcraft-sketch el constraint ConstraintKind::Pierce (la variante con sus… | — | 116 | 5 | 125 | 97 | en-curso (—) | — | — |
---

## 2. Patrones de fracaso, medidos

Sobre los **129** subagentes previos (excluye los 3 de este lote de análisis):

| Métrica | Valor | % |
|---|---|---|
| Subagentes (87 delegaciones) | 129 | — |
| Horas de subagente | 283,6 h | — |
| Lecturas / escrituras | 19 202 / 1 675 | ratio **11:1** |
| Llamadas a herramientas | 26 880 | 183 por agente (mediana) |
| **Leyeron >20 veces y escribieron 0** | **23** | **17,8 %** |
| Leyeron >25 veces y escribieron 0 | 22 | 17,1 % |
| `read_file` >20 y escribieron 0 | 19 | 14,7 % |
| **Nunca escribieron nada** | **31** | **24,0 %** |
| **Llegaron al tope de iteraciones** (`max_iterations`) | **32** | **24,8 %** |
| **INTERRUPTED** | **43** | **33,3 %** |
| **Fallaron sin reply** (`No reply`) | **3** | 2,3 % |
| Sin línea final (en curso / cortados) | 9 | 7,0 % |
| Terminaron `completed` | 74 | 57,4 % |
| Dejosaron commit (verificado o declarado) | 9 | 7,0 % |
| Dejaron PR (verificado o declarado) | 13 | 10,1 % |
| **Dejaron commit Y PR** | **5** | **3,9 %** |

**Horas perdidas sin escribir: 33,2 h** — el 11,7 % de las 283,6 h del corpus. Y de
esas, **29,7 h** son las de los 23 agentes que leyeron más de 20 veces y escribieron cero.

### 2.1 Los tres subgrupos que matan el presupuesto

**a) El que lee y nunca escribe (23 agentes, 29,7 h).** El patrón es siempre el mismo:
el agente entra en bucle de exploración y el transcript termina con una frase de
intención, no de resultado. **25 agentes** entregando un `summary:` que es una
**narración de lo que iban a hacer** (y no un informe) lo confirman — 19 de ellos
interrumpidos y 14 con cero escrituras; 11 arrancaban la frase con un *«Let me…»*,
que es la fórmula que la skill ya documenta («one last API check, then I write»):

- `deleg_9a28dceb/0` (#9866): 103 lecturas, **0 escrituras**, 342 llamadas, 204 min,
  `interrupted`. Último `summary:`: *«Now let me read the frame/state helpers and the
  walk test fixtures/goldens.»* (`task-0.log:837`).
- `deleg_a6fcaabc/0` (#7114): 470 lecturas, **0 escrituras**, 472 llamadas, 257 min,
  `max_iterations`. Su propio informe dice: *«No source or test files were modified, no
  RED/GREEN logs were produced, no gates were run, and no PR was opened.»*
  (`task-0.log:1331`).
- `deleg_cb1f9157/0` (#9866): 446 lecturas, **0 escrituras**, 448 llamadas, 243 min,
  `error`/`No reply` (`task-0.log:1113`).
- `deleg_cddfe059/1` (#10159): 406 lecturas, **0 escrituras**, 481 llamadas, 223 min,
  `completed` — y el brief pedía abrir un PR (`task-1.log`).

**b) El que se come el tope de iteraciones (32 agentes).** Es el modo de muerte
dominante y es invisible: **32 de los 32 reportan `status=completed`**. Ningún
consumidor de `state.json` puede distinguirlos de un éxito. Agotaron el presupuesto
leyendo: **266 lecturas de media** (mediana 260), hasta 472
(`deleg_a6fcaabc/0`), y sólo **1 de los 32 dejó commit**. El tope corta la
exploración, no la entrega.

**c) El INTERRUPTED (43 agentes, el 33 %).** La causa es casi siempre la misma y es
**del lado del orquestador, no del modelo**: la línea final dice
`error: Operation interrupted: waiting for model response (N.Ns elapsed)` — 30 de los
43. El tiempo de espera va de 1,2 s a 560 s (mediana 48,7 s). El patrón se agrupa en
ráfagas: **22 de las 87 delegaciones quedaron completamente borradas** (todas sus tareas
interrumpidas en el mismo segundo), y las ráfagas más grandes son
`deleg_b87aa87a` + `deleg_b2d8beb7` + `deleg_efcc0ddb` (6 agentes, 2026-10-30 17:55:57),
`deleg_52e15b89` (4 agentes, 16:23:30), `deleg_3ddb905e` (3 agentes, 02:06:23),
`deleg_c7001e70` (3 agentes, 2026-11-02 16:54:41). Un corte del proceso padre mata
en bloque a los subagentes que estaban en vuelo; **su trabajo no se recoge**.

**d) Los tres `No reply`.** `deleg_c6a3e080/0` (453 llamadas, 9 escrituras),
`deleg_cb1f9157/0` (448 llamadas, 0 escrituras) y `deleg_dc4f85e4/0` (365 llamadas, 51
escrituras) — los tres con `exit_reason=error` y el texto
`⚠️ No reply: the turn stopped while a tool result was still pending and the model
produced no follow-up text`. En dos de los tres el trabajo ya estaba escrito en disco
(51 escrituras en `deleg_dc4f85e4/0`) y se perdió **solo el informe**.

### 2.2 El coste oculto: lecturas repetidas

**2 036 relecturas** sobre 19 202 lecturas (10,6 %) apuntan a archivos que el agente
ya había abierto. Los peores:

| Subagente | Relecturas | Ficheros distintos | Lecturas | Escrituras |
|---|---|---|---|---|
| `deleg_e747db20/1` (#4760) | 140 | 38 | 466 | 2 |
| `deleg_c6a3e080/0` (#3599) | 94 | 26 | 432 | 9 |
| `deleg_a6fcaabc/0` (#7114) | 92 | 24 | 470 | 0 |
| `deleg_cb1f9157/1` (#4760) | 92 | 28 | 432 | 1 |
| `deleg_5c0fd3bc/0` (#10067) | 50 | **10** | 283 | 1 |

`deleg_5c0fd3bc/0` leyó 283 veces **10 archivos distintos**: leyó lo mismo 50 veces.
Cada relectura reenvía el prompt del sistema (~87 KB), así que 283 llamadas son ~24 MB
de entrada para un agente que no escribió una línea.

---

## 3. La tarea que SÍ funcionó, y la diferencia

### El caso winners: `deleg_3536a9fc/1` — el pierce (#3599)

| | `deleg_3536a9fc/1` (ÉXITO) | `deleg_c7001e70/1` (MISMO BRIEF, FALLO) |
|---|---|---|
| Inicio | 2026-11-02 **14:53:01** | 2026-11-02 **15:01:52** (8 min después) |
| Objetivo | `Crear UN archivo nuevo, crates/sketch/src/pierce.rs` … | idéntico, pero *«usando la geometria de crates/sketch/src/shape.rs»* |
| Lecturas / escrituras | 44 / **13** | 16 / **0** |
| Llamadas | 66 | 16 |
| Duración | **46,4 min** | 6,3 min (interrumpido) |
| Resultado | **commit `fb9505eba`**, 211 líneas + 10 tests, pusheado a `fork` | nada; `summary:` = *«I'll start by exploring the repo structure»* |

La diferencia **no es el modelo, ni el repo, ni la hora**: es **el brief** y **el
momento del despacho**.

1. **El brief que funcionó daba la API resuelta.** El contexto de
   `deleg_3536a9fc/1` incluye los números de línea de las funciones de la geometría que
   había que usar, la convención de firma y **los 6 casos de test con sus números de
   línea**. El de `deleg_c7001e70/1` solo dice *«usando la geometria de shape.rs»* —
   el agente tiene que **decidir** qué de ese archivo usar, y para eso lee.
2. **El criterio de aceptación es binario en los dos**: *«`cargo test -p solidcraft-sketch`
   en verde con un commit. Nada más: sin el constraint, sin el solver, sin PR.»* — y
   ese sí funcionó.
3. **El segundo dispatch estaba solapado.** `deleg_c7001e70/1` arrancó a las 15:01:52
   mientras `deleg_3536a9fc/1` seguía corriendo (terminó a las 15:39:26): **8,5 minutos
   de solape**, sobre el **mismo worktree** (`/home/user/solidcraft-wt/issue-3599`) y el
   **mismo artefacto** (`crates/sketch/src/pierce.rs`). El segundo agente no escribió
   nada; y su worktree compartido era el del primero.

### Los otros cuatro casos con entrega completa (commit + PR)

| Subagente | Objetivo | Lect/Esc | Calls | min | Entrega |
|---|---|---|---|---|---|
| `deleg_ba3ac879/0` | #5237: *«la implementación YA está escrita y en GREEN; falta commitearla, correr el gate, generar evidencia y abrir el PR»* | 66/16 | 126 | 44,6 | commit `bbb742e52` + **PR #11074** + gate VERDE |
| `deleg_8ab13997/0` | #5858: *«El fix YA ESTÁ ESCRITO y sus RED/GREEN logs existen»* | 147/19 | 225 | 127,8 | 2 commits + **PR draft** |
| `deleg_2d65dba0/0` | #10291 | 214/65 | 344 | 168,4 | commit + **PR** |
| `deleg_610c98d5/0` | #3892: *«El test RED ya está escrito y probado»* | 183/38 | 238 | 321,3 | commit + **PR draft** |

**Los cuatro comparten lo mismo**: el brief empieza por *«ya está»*. Los cinco agentes
que salieron con la mejor relación escrituras/lecturas son precisamente los que
recibieron el contenido, no el encargo.

### La regla, quantificada

| Tipo de brief | n | % con 0 escrituras | min (mediana) | calls (mediana) |
|---|---|---|---|---|
| **Ancho** (investigar + implementar + gate + publicar) | 105 | 21 % | 128 | 225 |
| **Estrecho** (*«UNA SOLA TAREA»*, *«UN archivo nuevo»*, *«Nada más:»*) | 24 | **37 %** | **46** | **83** |

El brief estrecho **acorta el ciclo a la mitad** (mediana 83 calls y 46 min, contra
225 calls y 128 min) y **sus agentes que llegan a `completed` escriben todos**: de los
24 estrechos, 10 llegaron a `completed` y **ninguno** de esos 10 tiene cero
escrituras. El 37 % de ceros del grupo estrecho **no es un problema del formato**: son
**13 de los 24 interrumpidos antes de terminar** (corte del padre, no del modelo).
El formato del brief es la palanca; la custodia del proceso es la que pierde el
trabajo.

---

## 4. Errores concretos del loop, con evidencia

### E1 — `max_iterations` se reporta como `completed`: 32 agentes parecen exitosos

**Evidencia** — `deleg_a6fcaabc/task-0.log:1332`:
```
15:48:44 final | end status=completed exit_reason=max_iterations (iteration budget exhausted)
```
Lo mismo en `deleg_1dacab98/task-0.log:1308`, `deleg_225bd5f5`, `deleg_50c60574`,
`deleg_65f3e9ea`, `deleg_754bcbeb`, `deleg_83ff5751` (×2), `deleg_a6fcaabc`… (32 en total).

**Por qué importa** — `state.json` clasifica por `status`, y 32 agentes que agotaron el
presupuesto se cuentan como completados. Un agente que leyó 470 veces y no escribió
nada (`deleg_a6fcaabc/0`) queda registrado igual que uno que entregó un PR.

**Arreglo** — el consumidor debe leer `exit_reason`, no `status`: `max_iterations` es un
**fracaso**, y `status=completed` solo es éxito cuando `exit_reason=completed`. En
`state.json`, `medicion_del_loop.completed` debería ser `exit_reason=completed` (74) y
`max_iterations` una categoría propia (32). Lo mismo en el script que resume el
lote: nunca inferir "entregó" del estado, sino de un artefacto (un SHA verificable en
la rama del fork).

### E2 — Despacho duplicado sobre el mismo artefacto mientras el primero sigue vivo

**Evidencia** — `deleg_3536a9fc/task-1.log` corre de 14:53:01 a 15:39:26 sobre
`/home/user/solidcraft-wt/issue-3599`; `deleg_c7001e70/task-1.log` arranca a las
**15:01:52** con el mismo objetivo (`crates/sketch/src/pierce.rs`) y el mismo worktree.
El transcript del segundo (`task-1.log:11`) arranca con
`-> terminal(ls /home/user/solidcraft-wt/issue-3599 ...)` y termina
(`task-1.log:43`) sin escribir nada.

**Por qué importa** — el segundo dispatch fue **peor que inútil**: no sólo no escribió,
sino que consumió 6,3 min y dejó al primero sin saber que había un gemelo. El
mismo patrón aparece 4 veces sobre el **mismo issue** con solape real:
`#7114` (`deleg_a6fcaabc/0` ∥ `deleg_d86067fe/0`, 184 min), `#9062`
(`deleg_a6fcaabc/1` ∥ `deleg_ca46cbe0/0`, 71 min), `#9843`
(`deleg_1b236ffe/0` ∥ `deleg_97a18525/0`, 53 min), `#10159`
(`deleg_1b236ffe/1` ∥ `deleg_e94e1396/0`, 13 min). **320 minutos de agente solapados
sobre el mismo issue.**

**Arreglo** — el brief debe llevar el **worktree y la rama exactos** y el dispatcher
debe **verificar que ese worktree no está ocupado** antes de arrancar (lock por
worktree, no sólo por issue). Si el worktree ya existe con una rama viva, el brief es
*«retoma esto»* (con el SHA del commit en curso), no *«crea el archivo»*.

### E3 — El cleanup del orquestador borra el worktree de un gate en marcha

**Evidencia** — `deleg_1b236ffe/task-0.log:267-268`:
```
13:28:41 think    | My commits survive (branch ref intact), but the worktree was deleted mid-gate by
13:28:41 assistant| ... the orchestrator's cleanup, and the gate came back ROJO. Let me read the actual gate log.
13:28:56 think    | The gate's ROJO is infrastructure: the worktree was deleted mid-run by the orche...
```
Y `task-0.log:261`: *«The worktree was removed by something external.»*

**Por qué importa** — el gate devuelve **ROJO** (que se lee como «el fix rompió algo»)
cuando en realidad lo rompió la infraestructura. El agente tuvo que gastar llamadas
en demostrar que el ROJO era falso. El `state.json` ya tiene una entrada
`errores_mios.borrar_el_target_de_un_slot_con_su_gate_vivo` — el mismo error, otra
iteración, y el árbol de worktrees sigue teniendo 22 entradas.

**Arreglo** — el cleanup debe **respetar el lock del slot**: `git worktree remove` sólo
si no hay un `cargo`/`nextest` vivo bajo ese target dir y el lock está liberado. Y un
gate cuyo worktree desaparece debe escribir **`DEFERRED`**, no ROJO.

### E4 — `node` no está en el PATH: la validación de cuerpo de PR no se ejecuta

**Evidencia** — 4 transcripts, 6 ocurrencias:
`deleg_0da28c8a/task-0.log:126`, `deleg_1b236ffe/task-1.log:124`,
`deleg_94ee5ea7/task-0.log:312`, `deleg_ee684044/task-1.log:586` y `:594`:
```
22:05:12 result | terminal ok 0.3s: {"output": "/usr/bin/bash: line 15: node: command not found", ...}
```
`deleg_ee684044/task-1.log:586` es el caso grave: el título del comando es
*«upstream: does upstream's own pr-checks parser accept our body?»* — **la validación
contra el parser del upstream no ocurrió**, y el `exit_code` fue **0**: el script
falló y nadie lo notó.

**Por qué importa** — la skill ya documenta que `pr-defaults-line.sh` debe buscar node
por sí mismo (PATH → toolchain de `$HOME` → home real del usuario). Los subagentes
que corren el script **a mano** heredan el PATH roto y producen un fallo silencioso.

**Arreglo** — `pr-defaults-line.sh` debe hacer el lookup de node **antes** de
cualquier modo (incluido el modo offline `--body`), y debe salir con un **código
distinto de 0** cuando node no está: hoy el `exit_code=0` con `node: command not
found` en la salida es un fallo que se lee como éxito. Además, el brief de todo agente
que publique un PR debe nombrar el **script** (no el parser de upstream directo), porque
el script ya sabe encontrar node.

### E5 — El `summary:` que llega al orquestador es una narración, no un informe

**Evidencia** — `deleg_c7001e70/task-1.log:43`:
```
15:08:12 final | status=interrupted duration=379.5s summary: I'll start by exploring the repo structure and reading the two key files.
```
25 agentes entregan un `summary:` que es una intención (`«Now let me check…»`,
`«Let me read the remaining pieces I need for the RED test and the fix.»`,
`«Let me look for issues with directly headless-runnable repro scripts»`), no un
resultado. En `deleg_a6fcaabc/0` el `summary:` (`task-0.log:1331`) sí dice la verdad
(*«No source or test files were modified…»*), pero 25 veces el orquestador recibe un
`«voy a…»` y no un `«hice…»`.

**Por qué importa** — el orquestador resume y decide a partir de ese `summary:`. Un
`«Let me read the remaining pieces»» no distingue «investigación en curso» de
«investigación que se terminó y no encontró nada». El dato que falta siempre es el
mismo: **cuántas líneas escribió**.

**Arreglo** — el brief debe exigir un `summary:` con **cinco campos fijos** y el
dispatch debe **parsearlos**: `ESCRITURAS: <n>`, `COMMIT: <sha|ninguno>`,
`PR: <url|ninguno>`, `GATE: <verdict|sha>`, `BLOQUEOS: <texto|nada>`. Un `summary:`
sin esas cinco líneas se trata como **fallo de entrega**, no como informe.

### E6 — `No reply` se come el trabajo ya escrito

**Evidencia** — `deleg_dc4f85e4/task-0.log:1079`:
```
00:30:11 final | status=failed duration=14166.17s summary: ⚠️ No reply: the turn stopped while a tool result was still pending and the model produced no follow-up text. Send `continue` to let it summarize.
```
El agente había hecho **51 escrituras**. Las 3 muertes por `No reply` son
`deleg_c6a3e080/0` (9 escrituras), `deleg_cb1f9157/0` (0) y `deleg_dc4f85e4/0` (51).

**Por qué importa** — el mensaje dice literalmente *«Send `continue` to let it
summarize»*: el mecanismo de recuperación existe y **no se usó**. No se mandó el
`continue` y el resultado quedó en disco; el trabajo se perdió del reporte.

**Arreglo** — el dispatcher debe hacer `continue` (o re-preguntar) automáticamente
cuando el `summary:` sea el de `No reply`, **antes** de dar el slot por perdido. Y
el commit del trabajo debe hacerse **antes** del informe (regla del `wip` commit), para
que el `No reply` nunca borre código.

### E7 — 2 036 relecturas del mismo archivo, y 29,7 h de exploración estéril

**Evidencia** — `deleg_5c0fd3bc/0` (#10067) leyó **283 veces 10 ficheros distintos**
(50 relecturas sobre lo ya leído) y escribió **1 vez**, en 126 min. Peor:
`deleg_a6fcaabc/0` leyó 470 veces 24 ficheros y escribió 0.

**Por qué importa** — el coste no es el tiempo, es el **contexto reenviado**: con el
prompt del sistema (~87 KB) reenviado en cada llamada, 283 llamadas son ~24 MB de
entrada para un agente que no produce nada. Un tope de *llamadas* (no de *minutos*)
es el freno que funciona: el skill ya lo dice, pero no está implementado en el loop.

**Arreglo** — dos:topes duros en el dispatcher: (a) **tope de llamadas** (≈80) con
`continue` automático en vez de muerte; (b) prohibition explícita de releer un rango
ya leído — el brief debe decir *«no leas el archivo entero: un `read_file` de 2000
líneas es lo que te hizo perder las horas»* y nombrar el `grep` exacto de cada
edición.

### E8 — 23 de 40 issues nombrados en los briefs recibieron **más de un** subagente

**Evidencia** — el recuento por issue (del corpus completo) da `#7114` con **9**
subagentes (26,2 h, 138 escrituras), `#10181` con **6** (14,3 h), `#10159` con **6**
(16,8 h), `#3892` con **6** (12,7 h), `#9843` con **5** (10,2 h), `#5858` con **4**,
y `#9866`, `#4760`, `#3599`, `#8434`, `#4712`, `#9062`, `#5237`, `#10067`, `#11074`
con 2–3 cada uno. `#9866` es el caso extremo: **3 agentes, 14,6 h, 1 escritura total**.

**Por qué importa** — el re-despacho de un issue es correcto *cuando el anterior
murió*, pero **incorrecto cuando el anterior sigue vivo** (E2) o cuando el trabajo ya
está hecho y sólo falta publicarlo. `#9866` acumuló 14,6 h para 1 escritura: la
feature se partió, se re-despachó, y nadie cerró el círculo.

**Arreglo** — antes de despachar un issue, el orquestador debe mirar **si ya existe
un artefacto** (una rama en `fork` con commits sobre ese issue, o un PR abierto que lo
cierre). Si existe, el brief es *«publica esto»*, no *«implementa esto»*. Es la regla
que ya funciona: 5 de los 6 agentes con entrega completa tienen *«ya está»* en la
primera frase.

---

## 5. Tres reglas accionables

### Regla 1 — El brief entrega el CONTENIDO, no el encargo. Si el contenido no existe, el brief NO se despacha: se escribe primero.

El disparador está medido: **contenido dado → escribe (5 de los 6 agentes con entrega completa dicen *«ya está»*
en el brief — `#5237` 16 escrituras, `#5858` 19, `#3892` 38, `#10159` 10, `#10181` 24;
el sexto, `#10291`, tuvo 65 escrituras con un brief de issue normal, pero su fix
cayó en **2 ficheros** — `crates/ui-egui/src/tools.rs` y
`crates/ui-egui/tests/projection_preselection.rs`, 44 líneas —, o sea un artefacto
único);
**contenido ausente → lee hasta morir (23 agentes con >20 lecturas y 0 escrituras,
29,7 h)**.

Forma concreta del brief que funciona (`deleg_3536a9fc/1`, 46 min, 13 escrituras):

> **UN** archivo. `crates/sketch/src/pierce.rs`. Contenido: la geometría del cruce,
> con estas 3 funciones **y estos números de línea**: `plane_of_sketch()` en
> `crates/sketch/src/model.rs:1174`, `Curve::point_at()` en `curves.rs:88`.
> **Seis** casos de test, con **estos** números de entrada: (1) … (6) …
> Criterio de aceptación **binario**: `cargo test -p solidcraft-sketch` en verde y
> **un commit**. Nada más: sin el constraint, sin el solver, sin PR.
> **Tope: 80 llamadas.** A las 40, si no has escrito, el brief está mal: dilo y paras.

Y el gate del dispatcher, en una línea:
```
if el brief no contiene el contenido a escribir:
    NO despachar. Escribir el contenido primero (o elegir otro issue).
```

### Regla 2 — Un artefacto por subagente, con worktree exclusivo y lock por worktree. Nada de solapes.

Separar por **artefacto**, no por «feature». Medido: los agentes estrechos
(`«UNA SOLA TAREA»`) usan la **mediana** (83 calls, 46 min) y los anchos 219 calls /
127 min — la mitad de coste por entrega.

Concreto:
1. Cada dispatch recibe **un worktree y una rama propios**, y **verifica que el
   worktree está libre** antes de arrancar (E2: el solape de 8 min entre
   `deleg_3536a9fc/1` y `deleg_c7001e70/1` sobre el mismo `issue-3599` fue el que
   mató al segundo).
2. El brief **no puede** pedir «investigar + implementar + capturar + gate + publicar».
   Un artefacto = una tarea. El que publica hereda el commit del que implementó.
3. Un subagente **no se re-despacha sobre un issue que ya tiene un artefacto**: se
   publica. `#9866` gastó 14,6 h en 3 agentes para 1 escritura porque nadie comprobó
   que el contenido ya estaba.

### Regla 3 — Instrumentar el transcript como la fuente de verdad, y cortar por llamada, no por tiempo.

El estado del subagente (`completed`) miente: **32 de los 32 `max_iterations` reportan
`completed`**. Lo que sí es verdad está en el transcript. Instrumentar y automatizar:

1. **Tope de llamadas** (≈80) con `continue` automático, no muerte. Un agente a las 80
   llamadas sin escribir **no va a escribir**: se cancela, se devuelve el worktree y se
   registra como fallo — se gastan **183 calls de mediana** por agente hoy, y
   **138 de las 283 h del corpus (49 %) están en los 36 agentes que leyeron 200 o más veces**.
2. **Lecturas repetidas**: 2 036 relecturas (10,6 %). Contarlas y avisar al pasar 20
   lecturas del mismo archivo.
3. **Un `summary:` con cinco campos parseables** (`ESCRITURAS`, `COMMIT`, `PR`, `GATE`,
   `BLOQUEOS`); sin ellos, el slot se marca **no entregado** (E5).
4. **`No reply` → `continue` automático** antes de declarar el slot perdido (E6).
5. **`exit_reason` es la verdad, `status` no** (E1). Y `completed` **no** significa
   «entregó»: de 74 completados, sólo **5** dejaron commit **y** PR.

**El indicador de un loop sano, en una línea:** *un subagente que no escribió nada en
80 llamadas se cancela, y el trabajo de los que mueren se recoge del worktree, no se
pierde en un `summary:` que dice «voy a…».*

---

### Cómo reproducir estas mediciones

Los transcripts son texto plano, append-only, uno por subagente, con líneas
`HH:MM:SS tool | -> <herramienta>(<args>)` y `HH:MM:SS result | <salida>`. La
clasificación de lectura/escritura es la de la cabecera de este informe; el corte por
`exit_reason` está en la línea `final` de cada transcript. Las rutas de los 129
subagentes están en la tabla de la sección 1; cada evidencia puntual de la sección 4
cita el archivo y el número de línea.
