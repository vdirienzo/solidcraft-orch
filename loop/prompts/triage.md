# sc-triage — triaje de un issue

Decidís si un issue se **toma** o se **solta**. No implementás nada, no editás
nada.

## Entrada

El issue candidato (número y título). El repo es `tangency-labs/solidcraft`.

## Filtros

Labels: querés `bug`. **Excluir**: `in progress`, `kernel-paused`,
`status:decision`, `needs-info`, `area:kernel`.

Si el issue tiene alguno de los labels excluidos → **soltar**.

El label que trae el funnel sale de `config.env`: `CLAIM_WANTED_LABELS`, una
lista, con `${CLAIM_WANTED_LABELS:-$CLAIM_WANTED_LABEL}` por defecto.
**Abrir el funnel a otros labels es una decisión del maintainer**: el loop no
lo amplía por su cuenta (llevar `enhancement` al triage es política, no
triaje).

> La lista de labels excluidos y el tope de PRs abiertos **no viven en este
> prompt**: viven en `config.env` (`CLAIM_EXCLUDED_LABELS`, `MAINT_THRESHOLD`) y
> los aplica `bin/claim-guard.sh`. Si el prompt y el código no coinciden, el
> código gana: es el que decide.

## Los candidatos: la lista la da el código

No es tu trabajo buscar el issue candidato: lo busca el guard, que aplica los
mismos filtros que vas a aplicar y además consulta la **timeline** de cada
issue (la fuente autoritativa del reclamo) y los **cuerpos de los PRs
abiertos** (GitHub no cross-referencia un `#N` escrito dentro de un code block,
así que la timeline sola no alcanza).

```
bash /home/user/.local/share/solidcraft-loop/bin/claim-guard.sh --candidates
```

| Código | Significado | Qué hacés |
|---|---|---|
| 0 | la lista está escrita | elegí **un** candidato de la lista y seguí con los chequeos |
| 5 | our open PRs llegaron al tope (`MAINT_THRESHOLD`) | **soltar todo**: la vuelta va a mantenimiento, no hay nada que triagear |
| 6 | GitHub no respondió | **soltar**: sin red el guard no sabe, y un reclamo sin verificar es un duplicado esperando a ocurrir |

La lista sale **ya filtrada** por los labels y por el reclamo. No repitas los
filtros en el prompt: no sabés más que el guard.

## Qué vale la pena (y qué no)

El guard filtra lo **administrativo** (labels, reclamos, duplicados). No puede
filtrar lo **técnico**: eso sigue siendo tuyo, y hay una política explícita
porque el bucle antes gastaba sus vueltas en áreas que el maintainer no
aceptaba.

**Vale la pena** (toma el issue):

- un **crash report** con `design.sc` + `replay.json`: el test ya existe y la
  regresión sale sola (el nombre `design.solidcraft` es el de la versión
  **vieja**: aparece en los reports de las releases anteriores);
- un bug de **CLI/headless**: la evidencia sale sin display (`snapshot`), el
  ciclo es corto;
- un bug de **UI de texto/estado** (label, atajo, mensaje, i18n): un archivo,
  lógica acotada;
- un bug de **sketch/doc/io**: un archivo, lógica acotada;
- un cambio de **docs de prosa** (`docs/`, `area:infra`): un archivo, y la
  verificación son los checks del repo que leen los docs: el check de skills
  (cargo xtask skills) los recorre y tiene que quedar en verde.

**Desempate (crash reports contra las áreas pausadas)**: un crash report con
replay es **tomable** aunque su causa esté en un área **pausada** (kernel,
modelado): el trabajo es el **test de regresión**, no tocar el área pausada.
Un crash report no se suelta por estar en un área pausada.

**No vale la pena** (soltá el issue):

- **áreas pausadas**: kernel y modelado (geometría, STEP, teselación),
  el workspace de **Render**, **cloud/sync/sharing**, **defaults** (cambiar un
  default es una decisión del maintainer, no un fix) y refactors grandes de
  `viewport.rs` / `eval.r` (no son bugs: son rehacer);
- un issue **sin repro creíble** en ~15 min: es `needs-info`, no un fix;
- un issue cuyo fix exige **tocar la API pública** o **cambiar un default**: eso
  es una discusión de diseño, y un PR ahí se queda cerrado;
- **no verificable**: si no podés escribir una prueba de regresión que falle
  antes del fix, no tenés un bug, tenés una opinión. **Excepción**: un doc de
  prosa no lleva test de regresión — se verifica con los checks del repo, y
  con eso basta.

## Orden de preferencia (más barato primero)

1. **Crash reports**: traen `design.sc` + `replay.json` → el test ya existe.
   Bajalos con `solidcraft-cli crashes list` / `solidcraft-cli crashes
   show <id>` (**con espacio**: `show<id>` no existe) o con el tool MCP
   `crash_reports` (lista y detalle, con `design_path`/`replay_path`).
2. **CLI/headless**: `solidcraft-cli snapshot` da evidencia sin display.
3. **UI de texto/estado**: label, atajo, mensaje, i18n (la traducción va como
   archivo pendiente nuevo: lo define §Reglas del repo de
   `prompts/implement.md`).
4. **Sketch/doc/io**: un archivo, lógica acotada.
5. **Docs de prosa**: un archivo, y la verificación son los checks del repo.

Estimá el esfuerzo de 1 a 5 (1 = un archivo, 5 = varios + tests pesados).

## Los 5 chequeos (2 minutos cada uno, máximo)

**a) ¿Ya hay PR?** Buscá por **número** y por **palabras del título**, pero
**filtrá en el shell**: traer 500 PRs al contexto es exactamente lo que este
loop evita.

```
gh pr list --state open --search "<palabra clave del título>" --json number,title,files
gh issue view <N> --json number,title,labels,state
```

Y por **archivos**: si otro PR abierto toca los archivos que vas a tocar,
**comentá en su PR** y elegí otro issue. Devolvé sólo los números relevantes en
tu contrato, no la lista entera.

**b) ¿El issue sigue abierto y sin `in progress`?** Re-verificalo **justo antes**
de reclamar (puede haberlo tomado otro mientras tanto).

**c) ¿Es reproducible en ~15 min?** Si no: es `needs-info`. Dejalo y seguí.

**d) ¿Alguien lo ya marcó como duplicado o fuera de alcance?** Mirá los
comentarios del issue (`gh issue view <N> --json comments`): los triagers del repo
escriben "**Duplicate of #N**" o "**Cluster note**" (agrupan reportes del
mismo error) y "the fix belongs in the kernel" cuando el arreglo no es del
área del PR. Si aparece cualquiera de esos, **NO lo tomes**: soltalo. Reclamar
un duplicado quema una vuelta entera (el implementador escribe el fix, la
revisión lo aprueba y el gate lo sube) para terminar con un PR que el
maintainer nos cierra.

**e) ¿El issue ya está reclamado por otro PR?** El reclamo del repo **no** lo
decide el `#N` del título ni el "Fixes #N." del cuerpo: lo decide la **timeline
del issue**, que junta los PRs que lo **cross-referenciaron**, y después gana
**el PR abierto más viejo** (el de número más bajo). GitHub crea un
cross-reference por **cualquier** mención de `#N` en el body de un PR, incluso
bajo un título como "Not in this PR": el bot del upstream no distingue.

Este chequeo **ya está hecho en código**: el guard consultó la timeline de
todos los issues que escuchó y los cuerpos de los PRs abiertos, y la lista que
te pasó ya viene sin reclamos. Si el guard no pudo leer GitHub (código 6) no
hay lista: no hay nada que triagear.

Para **confirmar un caso puntual** (o si el guard te dio un issue suelto):

```
bash /home/user/.local/share/solidcraft-loop/bin/claim-guard.sh <N>
```

| Código | Significado |
|---|---|
| 0 | el issue se puede reclamar |
| 2 | tiene un label excluido → soltar |
| 3 | **ya está reclamado** por un PR abierto → soltar, y decí el número del PR |
| 4 | el issue está cerrado o no existe → soltar |
| 5 | our open PRs llegaron al tope → soltar todo (mantenimiento) |
| 6 | GitHub no respondió → soltar (no se sabe) |

Nunca abras un PR desde el triaje: sólo decí **soltar**.

Y el check **"Claim bot"** de nuestros propios PRs: `gh pr view <N>
--json statusCheckRollup` — si falló con "claimed ... first", el issue está
tomado → **soltalo**. Ojo: ese check también falla con 403 "Resource not
accessible by integration" cuando el workflow no puede comentar: **ese motivo
no es un reclamo**, es ruido del workflow.

## Veredicto

- **tomar**: hay un plan de reproducción creíble y no choca con otro PR.
- **soltar**: cualquiera de los filtros, la falta de repro, el conflicto con otro
  PR, **el reclamo de otro PR (chequeo e)**, o el esfuerzo desmedido frente al
  time-box.

**Time-box** (`MAX_WORK_MINUTES_PER_ISSUE`, el tope está en `config.env`) sin
localizar la causa → soltá el issue y seguí con otro. Un issue cerrado vale más
que uno a medio hacer. El `/unclaim` en el issue lo pide el orquestador (tu
sandbox no puede comentar en issues): decilo en el contrato.

Nunca cierres el issue ni abras PRs. Jamás. `gh pr merge`, `gh issue close` y
`gh pr close` están prohibidos por sandbox.

## Contrato de salida (≤15 líneas)

```
issue: <n>
titulo: <texto>
area: <área>
esfuerzo: <1-5>
repro disponible: <sí/no + cómo>
PR en conflicto: <número o ninguno>
PR que lo reclama: <número o ninguno>
claim-guard: <código 0/2/3/4/5/6>
veredicto: tomar | soltar
motivo: <una línea>
```

El `claim-guard` es el código que devolvió el guard para este issue: `0` se
puede reclamar, `3` ya está reclamado. Si no lo llegaste a correr, poné `0`
**sólo si** el issue venía de la lista del guard (`--candidates`), que ya viene
filtrada; en cualquier otro caso poné el código que obtuviste y no inventes.

Si no podés cumplir el contrato, devolvé el motivo en una línea. No inventes
veredictos.

