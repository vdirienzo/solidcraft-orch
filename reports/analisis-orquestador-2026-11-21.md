# Análisis del orquestador: de issue a PR (2026-11-21)

Cuatro análisis en paralelo, solo de lectura: despacho y prompts, selección y claims, gate y
publicación, estado y resultados. Los hallazgos marcados con ✔ se volvieron a comprobar a mano
contra el código, los logs o GitHub. Se descartó todo lo que dependía de hermes: el agente es
opencode y el planificador es el crontab del usuario.

## 0. Resultados reales (gh, PRs desde 2026-10-22)

- 117 PRs: 88 mergeados, 20 cerrados sin merge y 9 abiertos.
- Mediana hasta el merge: 22,4 h (p90: 96 h). Entre 14 y 23 merges por semana.
- De los 20 cerrados sin merge, unos 11 (55 %) se perdieron por claims ganados por otro PR,
  duplicados o "ya cubierto". También hubo dos PRs de prueba abiertos en upstream
  (#6188 y #14821), que no deberían repetirse.
- 5 PRs con `approved-for-ci` y CI verde esperan al maintainer desde hace 5 a 8 días
  (#16496, #16718, #17609, #17862 y #20017).
- Agentes (`agentes-metricas.csv`, 132 delegaciones): el 61 % terminó sin completar
  (49 interrupciones y 32 por tope de iteraciones). Solo 20 produjeron un PR.
- Costo aproximado: entre 1 y 2 USD en tokens y unas 3 horas de agente por PR mergeado. Los
  tokens no son el cuello de botella: lo son el tiempo de reloj, los claims perdidos y la
  atención del maintainer.

## 1. Caído AHORA (arreglar hoy)

| # | Qué | Evidencia | Arreglo |
|---|---|---|---|
| 1 ✔ | 5 crons de Python corren con bash y fallan siempre: pipeline, comment_watch, daily-report, loop-status y wave-prompt-guard | `bin/install-crontab.sh:74`; `logs/cron-solidcraft-pipeline.log` con `import: command not found` | Ejecutar cada script por su shebang (`python3` para los `.py`) |
| 2 ✔ | ping-ready no encuentra `gh`: el PATH del cron no incluye `~/.local/bin` | `logs/cron-solidcraft-ping-ready.log` | Poner `PATH=$HOME/.local/bin:$HOME/.cargo/bin:/usr/bin:/bin` al principio del bloque del crontab |
| 3 ✔ | La cola de gates está trabada desde el 20-11 17:50 (gate de 19690): el lock nunca se libera | `bin/gate-queue.sh:68`: `pgrep -f gate-queue.sh` se encuentra a sí mismo (la subshell y el `sh -c` del cron), así que `alive` nunca queda vacío | `flock -n` sobre un descriptor de archivo, que se libera solo si el proceso muere o la máquina se reinicia |
| 4 ✔ | La wave puede girar sin fin: si falla prepare o dispatch, hace `continue` sin descontar `FREE` y `next-issue.py` devuelve el mismo issue | `bin/wave.sh:366-376` | Llevar un conjunto TRIED, pasar `--exclude` a `next-issue.py` y hacer `break` o descontar `FREE` cuando falla |
| 5 | La wave no arranca agentes: reintenta 19690 y 20011 en cada pasada y `2>/dev/null` oculta la causa | `bin/wave.sh:334,364`; `logs/cron-solidcraft-wave.log` | Registrar stderr y el rc de prepare-slot y cortar tras N intentos |
| 6 ✔ | Los briefs viejos ordenan `rm -rf` del target y `worktree remove --force` (lo que mató el gate de #20017) con un `git -C` que apunta al repo del orquestador. `prepare-slot` reutiliza el brief existente, así que el texto nunca se actualiza | `prompts/agent-19690.md:109-110`, `agent-20011.md:119-120`, `bin/prepare-slot.sh:123` | Generar siempre el brief desde la plantilla; la reparación va en `prompts/repair-<n>.md` adjunto con `-f`; la limpieza es solo del `close-slot.sh` |

## 2. Menos errores: causas de fondo

1. **El claim se abre tarde.** El draft PR se abre al final del trabajo del agente, así que la
   ventana de carrera dura toda la corrida (40 min o más). Así se perdieron #18686 y #18691.
   → En `prepare-slot.sh`, justo después del lock: commit vacío en `fix-N`, draft
   `"TÍTULO (#N)"` con `Fixes #N` y enseguida `claim-verify N <pr>`. Si el claim está perdido,
   se cierra el draft y se libera el slot antes de gastar el agente. `publish-pr.sh` pasa a
   hacer solo `gh pr ready`.
2. **El filtro de área mira solo el título.** Así pasaron #19570 (STEP) y #19690 (el error
   `solidcore failed (status 1001)`). → Una ficha por issue (`bin/issue-card.py` →
   `state/cards/<N>.json`): buscar con grep las cadenas de error en el checkout, mapear lo
   encontrado a crates con `scripts/ci/affected.py --owners` y vetar `crates/kernel` y
   `solidcore/`. Después, un `opencode run` con un modelo chico y salida JSON fija que
   clasifique: muerto, decidido por el maintainer (`git log -S` para detectar una eliminación
   intencional, caso #19749), crash sin replay (caso #20141) y un solo tema.
3. **La regla del claim tiene cuatro implementaciones distintas** (`claim-verify.sh`,
   `claim-race.sh`, `claim-guard.sh` y el `claim.js` de upstream). `claim-verify` descarta
   como ruido un `Fixes #N` dentro de un bloque de código, mientras que `claim.js` lo cuenta:
   la peor dirección posible, porque da por libre algo que upstream ya considera reclamado.
   → Un solo módulo `bin/claim_rule.py` copiado de `referencedIssues` y `linkedPulls`, más un
   test que ejecute `scripts/claim/claim.js` sobre los mismos fixtures. Hay que unificar
   también las listas de labels (`VETO_LABELS` y `CLAIM_EXCLUDED_LABELS` dicen cosas
   distintas).
4. **El gate local diverge de upstream.** `gate-quick.sh` corre nextest con
   `--ignore-default-filter` y `SOLIDCRAFT_REQUIRE_GPU=1`, y el baseline tiene 18 días contra
   un tope de 14. Resultado: un falso ROJO en #20017, que en upstream pasó Native Linux tests
   ✔. Además, el gate no comprueba `HEAD == SHA` ni que el árbol esté limpio, y le faltan
   assets, icons, lists y licences. → El cuerpo del gate pasa a ser
   `cargo xtask fast --base origin/main` en el worktree, después de verificar el SHA y que el
   árbol esté limpio; un baseline viejo da DESCONOCIDO, no ROJO. Se borra
   `bin/gate-structural.sh`, que no tiene ningún llamador.
5. **Gate solo al final.** El agente da el trabajo por terminado cuando "pasa un test nuevo";
   un rojo deja el PR en draft y nadie se lo devuelve a un agente. → La definición de
   terminado del agente pasa a ser `cargo xtask fast` en verde (en su propio target, ya
   caliente). Las reparaciones ocurren en la misma sesión, no en un despacho nuevo.
6. **Publicación.** `Changes a default: no` sale de una regex sobre el texto, no del diff;
   `Fixes #N` no se exige al crear el PR y después `pipeline.py:905` edita el body (lo que
   `publish-pr.sh:23` prohíbe); `pipeline.py:1016` deja comentarios en castellano en
   upstream, que exige inglés. → Exigir `Fixes #N` antes de `gh pr create`, quitar la
   edición del body, comentar en inglés y decidir la línea del default a partir del diff
   (si toca prefs o valores por defecto).
7. **La cola gatea un SHA viejo.** `enqueue` deduplica solo por issue (`gate-queue.sh:44`).
   → Usar como clave issue+sha.
8. **Tests no herméticos.** `bin/test-orch-state.sh:324` pisó el `history.jsonl` real.
   → `ORCH_DIR` temporal obligatorio en los tests y negarse a correr si apunta al árbol vivo.

## 3. Menos tokens

1. **Límites al agente.** `dispatch-slot.sh:71-79` lanza opencode sin `timeout`, sin sesión y
   sin `--format json`. → `timeout --kill-after=120 ${MAX_TURN_MIN}m`,
   `--session slot-N --title issue-N --format json`, log con `>>`, reanudación con `-s`, y un
   agente `slot-fix` en `opencode.json` con `steps:` y su modelo.
2. **Brief de unos 17k tokens antes de empezar:** el brief de 6 a 10 KB, más
   `CONTRIBUTING.md` (39 KB), la skill de contribución (17 KB) y `AGENTS.md`, que opencode ya
   carga solo, más tres servidores MCP en cada issue. → Un brief de unos 2 KB (IDs, contrato
   de claim, push y no limpiar, y el gate), la skill del área nombrada por ruta, nada de
   CONTRIBUTING, y chrome-devtools solo en la fase de evidencia. Hay que quitar también las
   contradicciones: `cargo run -p solidcraft-cli` compila el kernel, el consejo de
   rendimiento no tiene lugar en un bugfix y esperar 3600 s el lock bloquea el contexto.
3. **Fases con entregas en JSON** en `slots/<n>/`, usando los prompts que ya existen en
   `loop/prompts/` (triage, implement, evidence, review) instalados como agentes de opencode:
   - triage (modelo barato, unos 20 steps): `{area, crate, test_file, error_site, kernel_cause, decision_risk, skill}`; aborta antes de gastar el modelo fuerte;
   - red: `{test, file, cmd, failing_output}` y push;
   - fix (modelo fuerte): `{commits, crates}`;
   - gate: un script, no un agente;
   - pr: `{pr, url}`.

   Un agente que muere se reanuda desde el último artefacto y no vuelve a derivar lo ya
   hecho.
4. **Cargo fuera del contexto del agente.** La fase termina escribiendo `build-request.json`;
   el build corre en segundo plano y la fase siguiente arranca con el resultado. Así no se
   paga la pérdida de caché garantizada de un build de 10 a 27 minutos.
5. **Paralelismo dentro del triage:** subagentes con la herramienta `task` de opencode para la
   repro, ubicar el archivo de test y leer la skill, cada uno devolviendo alrededor de 1 KB.
6. **Una foto de GitHub por wave** (GraphQL paginado de los PRs y los issues abiertos en
   `state/snapshot.json`, con `claim-verify --snapshot`). Hoy cada `claim-verify` baja los
   2.000 PRs con sus bodies (unas 11 páginas) y se pagan entre 25 y 50 páginas por slot.
   Además, `next-issue.py` ve solo 150 issues de 6.815.
7. **Contabilidad:** con `--format json`, tokens por slot y por fase, un tope por fase y el
   costo por PR mergeado en el reporte diario.

## 4. Arquitectura y deuda

- 82k líneas en dos árboles con responsabilidades duplicadas (`bin/` y `loop/bin/`: gate,
  claim, gc y publish). El camino `loop/` está muerto en esta máquina: apunta al agente
  `sc-orchestrator`, que no está instalado, y no hay unidades activas. Hay que elegir un árbol.
- `workflow.yaml` (555 líneas) no ejecuta nada: es documentación sincronizada por un
  validador. O lo lee el supervisor o se borra.
- Estado repartido entre `state/*.json`, un `state.json` generado, `locks/`, `gates/` y
  `$LOOP_DIR`, sin transacciones ni leases. → Un supervisor único (unidad de usuario de
  systemd con timer, o de transición un solo job de cron `supervisor tick` con `flock`) con
  SQLite: `issues`, `slots` (con lease y heartbeat) y `events` (append-only, reemplaza
  `history.jsonl`). Pasos idempotentes con clave (issue, sha). GitHub sigue siendo la fuente
  de verdad y se reconcilia en cada tick.
- 34 GB en `targets/` (29 GB solo en slot-19690), con un tope de gc de 60 GB que nunca se
  alcanza. → Worktrees efímeros y un target compartido por perfil, apoyado en sccache.
- Restos de hermes: 204 líneas en 55 archivos. Borrar `bin/wave-prompt-guard.py` y su cron,
  la rama `HERMES_SCRIPTS` de `preflight.sh:37,83-104`, la resolución de la copia en
  `ping-ready.sh:141-151`, el fallback de `next-issue.py:34-40`, la referencia a
  `hermes_kernel_runner.py` en `slot-busy.sh:66-76`, la ruta de caché de `dup-scan.sh:51` y
  el consejo de `max_iterations`, `execute_code` y `compression` en
  `docs/costo-de-tokens.md`. `HANDOFF.md` está desactualizado: data del 31-10 y describe
  una máquina de 62 GB; esta tiene 15 GB, y los límites de memoria del gate
  (`MemoryMax=32G`) no protegen nada.
- Throttle propio: `MAX_PEDIDOS=2` frena una cola donde ya hay 5 PRs aprobados esperando.
  Conviene revisarlo.

## 5. Orden propuesto

1. Hoy: los puntos 1 a 6 de la sección 1, que son cambios chicos y desbloquean el pipeline.
2. Semana 1: claim al seleccionar, `xtask fast` como definición de terminado y cuerpo del
   gate, `timeout` y sesión de opencode, y brief de 2 KB.
3. Semana 2: ficha por issue con triage barato, foto de GitHub, una sola regla de claim y
   tests herméticos.
4. Después: fases con JSON, supervisor con SQLite, un solo árbol y borrado de hermes.

---

# Gap analysis del plan (v2, mismo día)

Se contrastó el plan con los datos de los PRs y con las reglas de **upstream en
`origin/main` (df0859994, 2026-11-21)**. El checkout local estaba atrasado.

## A. El plan partía de reglas viejas (gap principal)

En #19134 upstream movió las skills de desarrollo a `.agents/skills/` y agregó un flujo de PR
completo para agentes. El orquestador (`RULES.md`, briefs, `rules-snapshot/`) cita las rutas
y las reglas anteriores, y nada lo detectó.

| Regla de upstream hoy | Qué hace el orquestador o qué decía el plan | Corrección |
|---|---|---|
| "Kernel and geometry work is welcome… goes in `solidcore/`" (CONTRIBUTING §Kernel work) | Veta kernel, STEP, IGES y tessellation como "pausados"; el plan proponía vetarlos mejor | **Invertir:** abrir un carril de kernel que use `solidcore/`, `solidcraft-kernel-rules` y `xtask fast --units`. Multiplica la cantidad de issues disponibles |
| `solidcraft-full-stop`: de cambio a PR listo, sin nadie mirando, con veredictos Ready / Waiting for a maintainer / Blocked | Brief propio de 6 a 10 KB y fases propias | El brief nombra el issue, el worktree y la rama y dice "sigue full-stop"; el veredicto de la skill es la salida del agente |
| `solidcraft-babysit-pr` + `scripts/pr-wait` (una consulta cada 90 s, exit 0/1/2) | `ci-status.sh`, `pipeline.py` y `ping-ready.sh` propios | Usar `pr-wait` desde un script, no dentro de la sesión del LLM, y despertar al agente solo con exit 1 |
| "Heavy tests start only after a maintainer adds approved-for-ci… Don't ask again and again"; "No status comments" | `ping-ready.sh` pide el label en cada head sha; `pipeline.py` publica estados (en castellano) | **Borrar el ping y los comentarios de estado.** Pedir el label va contra la guía y gasta la atención del maintainer, que es el cuello de botella |
| CI completo en el fork con runners gratis: `gh workflow run ci.yml --ref <rama> -f cross_compile=true -R vdirienzo/solidcraft` (variables `CI_RUNNER` y `CI_RUNNER_WINDOWS`) | Gate pesado local en una caja de 15 GB, con falsos rojos | Reemplazar el gate pesado local por el CI del fork. En local queda solo `cargo xtask fast` |
| `xtask fast` antes de cada commit; `tests/KNOWN_FAILING_TESTS` (REGRESSION y FIXED) | Baseline propio de 18 días | Borrar el baseline y usar la lista de upstream |
| Título `Area: behaviour`, **sin número de issue** al pasarlo a ready; el draft del claim usa `<summary> (#N)` | No se retitula | Retitular al pasar a ready |
| Línea `Test change: <reason>` si cambia una línea de un test o golden existente | No existe | Exigirla en `publish` cuando el diff toca tests existentes |
| `Changes a default:` solo para defaults de UX; un resultado de kernel es `no`; las opciones van al panel de la herramienta o al valor legacy del formato | `RULES.md` dice "behind a preference" | Actualizar la regla |
| Claim con commit vacío: `git commit --allow-empty -m "claim: #N"` + draft | Draft al final | Confirma el punto "claim al seleccionar" del plan |
| Draft sin pushes durante 72 h: se puede tomar después de comentar, conservando el crédito (`solidcraft-takeover`) | El orquestador usa 14 días y nunca toma | Fuente nueva de issues; y nuestros drafts tienen que pushear a diario |
| "Keep one long-running session; don't `--resume` one whose cache has gone cold" | El plan proponía reanudar con `-s` y partir en muchas fases | Una sesión por issue hasta el fix; nunca reanudar en frío; después de una espera larga (CI), sesión nueva con un artefacto chico |
| CodeRabbit: actuar solo ante crashes, resultados erróneos, pérdida de datos o seguridad | `comment_watch` encola todo | Filtrar con esa regla |
| `solidcraft-repro-first`: los bugs de SO, gráficos o updater necesitan evidencia de un build publicado | Sin filtro | Vetarlos en la selección si no traen evidencia |
| Carga mayor que 24: esperar; compilar con `nice` | `cargo-jobs.sh` roto | Aplicar la regla de upstream |

## B. Gaps de método

1. **Se optimizaban tokens, no el cuello de botella.** Datos: los PRs de 80 líneas o menos
   se mergean en 20,7 h de mediana y los de más de 300 líneas en 96 h. Las áreas `ui` y `doc`
   suman 43 de 88 merges; `kernel` tiene 2 merges y 4 cierres. → La selección tiene que
   preferir issues de diff chico, y full-stop ya pide "the smallest change".
2. **La selección es pobre en cantidad y en calidad.** `next-issue.py --list` (hoy) lee 150
   issues de 6.815 y deja 17 libres, así que la wave no despacha por otra causa: falla
   `prepare-slot` y `2>/dev/null` lo oculta. Además entran issues que no sirven: #20223 es una
   feature grande, #20178 mezcla varios temas y #20181 es de Drawings, que upstream manda a la
   rama `drawings`. → Foto completa de GitHub, carril de kernel, takeover de drafts parados,
   y la ficha por issue con veto de "feature grande", "varios temas" y "Drawings → rama
   `drawings`".
3. **No había detección de deriva de reglas que frene el despacho.** → Si `AGENTS.md` o
   `.agents/skills/` cambian en `origin/main`, se pausa la wave y se avisa. Borrar `RULES.md`
   y las copias: el agente lee upstream.
4. **El plan agregaba código (supervisor SQLite, fases) en vez de borrar.** Con full-stop,
   `pr-wait` y el CI del fork sobran `gate-quick.sh` (2,3k líneas), `gate-baseline`,
   `ci-status`, `ping-ready` (1,2k), las correcciones de body del pipeline, `claim-guard` y
   `claim-race`, y el árbol `loop/` entero. Primero borrar y después decidir si hace falta el
   supervisor.
5. **No se dimensionaba el paralelismo.** Con 12 núcleos y 15 GB, y sin gate pesado local,
   caben unos 2 slots de `xtask fast` con target compartido y sccache. El tercero tiene que
   medirse.
6. **No había forma de validar los cambios.** → Una métrica base antes de tocar nada (merges
   por semana, claims perdidos, horas de agente y tokens por merge), un slot canario y
   comparar después de 1 semana.

## C. Plan revisado

1. **Hoy:** actualizar el checkout local a `origin/main` y volver a hacer el snapshot de
   reglas. Arreglar el crontab (shebang y PATH) **apagando antes** `ping-ready` y los
   comentarios de `pipeline.py`. Lock de la cola con `flock`. Arreglar el bucle de la wave.
   Briefs viejos fuera.
2. **Brief full-stop de unos 1 KB** con `timeout` y `--format json`; el agente devuelve el
   veredicto de full-stop en JSON.
3. **Claim con commit vacío al seleccionar.**
4. **CI del fork en lugar del gate pesado local.** Requiere configurar 2 variables en el fork:
   es una acción del usuario.
5. **Selección:** foto completa, carril de kernel (1 slot), takeover a las 72 h, preferencia
   por diffs chicos y veto de repro-first.
6. **Borrar** lo que reemplaza upstream, más hermes y `loop/`.
7. **Métricas** y, solo si sigue haciendo falta, el supervisor.
