# Changelog de los prompts del loop

Cada entrada es un cambio de un prompt (o del inventario del directorio).
El formato es el del resto del loop: fecha, qué cambió y por qué.

## 2026-10-28 — Snapshot inicial del directorio

- **8 prompts vivos**: `claim.md`, `evidence.md`, `gate.md`, `implement.md`,
  `iteration.md`, `publish.md`, `review.md`, `triage.md` — 142.244 bytes en
  total. Cada uno es la especificación de una tarea que el supervisor
  despacha a su agente `sc-*`.
- **10 instantáneas `.bak*`** — 218.854 bytes. No las lee nadie: son fotos
  manuales de un prompt antes de un cambio.
- **El inventario**: se agrega `README.md` con la tabla de archivos
  (propósito, bytes, mtime) y la propuesta de versionado.
- **Los prompts siguen SIN versionar**: `$LOOP` no es un repositorio git.
  La propuesta para versionarlos (destino `ops/loop-prompts/` en el repo de
  SolidCraft, con los comandos) está en `README.md`, para que la ejecute
  una persona.
- **Secretos**: revisados los 18 archivos del directorio, no hay ninguno.

### Cambios de esta misma fecha

- `iteration.md`: las referencias al RUNBOOK apuntaban a **números de línea**
  del archivo monolítico (`§El gate de scope (L841)`, `§La señal del merge
  (L939-986)`, `§El reporte diario (L1150-1190)`, `§La limpieza del disco
  (L1348-1350)`). Como el RUNBOOK ahora es un índice con un archivo por
  sección, esas referencias apuntaban a la nada: se cambian por la ruta del
  archivo nuevo (`RUNBOOK/el-gate-de-scope-y-la-señal-del-merge-lote-2.md`,
  `RUNBOOK/el-reporte-diario.md`,
  `RUNBOOK/la-limpieza-del-disco-bingc-disksh.md`) y se saca el número de
  línea, que ya estaba desactualizado antes de este cambio.
- `iteration.md`: se aclara que el `RUNBOOK.md` es un índice y que cada
  sección vive en `RUNBOOK/`, para que el modelo no lo lea entero.

## 2026-10-28 — Los prompts que valen un agente (y los frenos del gate y de los claims)

Una sola entrada para el lote entero: los cuatro prompts que definen **qué se
toma** (`triage.md`), **cómo se delega** (`iteration.md`), **cómo se
implementa** (`implement.md`) y **cómo se publica** (`claim.md`), más el
inventario que los pesa.

- **`triage.md`: qué issues valen un agente.** La lista de categorías cambia:
  entra la **documentación de prosa** (`docs/`, `area:infra`) —un archivo, y la
  verificación son los checks del repo— y se la marca como **excepción** a la
  regla de "no verificable": un doc de prosa no lleva test de regresión, se
  verifica con los checks. La **i18n** se mide por el **archivo pendiente
  nuevo** y no por el catálogo ordenado (y el `cargo xtask lists --fix` sale
  del prompt). La referencia al formato del diseño pasa a `design.sc`; el
  nombre viejo, `design.solidcraft`, queda sólo como nota para los reportes de
  las releases anteriores.
- **`triage.md`: el desempate de los crash reports y el filtro de labels.**
  Un crash report con replay es **tomable** aunque su causa esté en un área
  **pausada**: el trabajo es el **test de regresión**, no tocar el área. El
  label del funnel sale de `CLAIM_WANTED_LABELS` (con `CLAIM_WANTED_LABEL`
  como fallback) y **ampliar el funnel es una decisión del maintainer**, no
  del loop.
- **`triage.md`: el time-box se nombra con su knob.** El prompt escribía "45
  min" al lado de `MAX_WORK_MINUTES_PER_ISSUE`: un número que el `config.env`
  puede cambiar sin que el prompt lo note. Ahora el prompt nombra el knob
  (`MAX_WORK_MINUTES_PER_ISSUE`, el tope está en `config.env`) y no el número.
- **`iteration.md`: las referencias por número de línea salen.** Las 22
  referencias `(L<n>)` apuntaban a un archivo que cambia de forma: cada una
  cita ahora la sección por su **título** (`§Procedimiento`, `§El gate de
  scope`, `§Definición de verde`, ...), que es lo que sobrevive a una edición.
  El bloque del funnel deja de repetir la lista de categorías y cita las
  secciones del triage que la definían.
- **`iteration.md`: los frenos del gate quedan escritos.** El directorio de
  build es **por slot** (`<GATE_QUICK_TARGET_DIR>/slot-<slot>`) y el lock es
  **por directorio de destino**, y los dos van juntos. El que pierde el lock
  queda **aplazado** (sale con `0` y con `DEFERRED=scope-gate-alive`), no
  fallido, y el aplazamiento nombra el slot y el directorio de destino.
- **`implement.md`: la i18n se mide por el archivo nuevo.** Cada cambio de
  texto agrega un archivo en `assets/locales/pending/<slug>.json` y **nunca**
  agrega una cadena editando `assets/locales/<locale>.json`; el pliegue de
  `pending` lo hace el workflow, sobre `main`, no un PR.
- **`claim.md`: el freno de publicación.** El guard corre **antes de
  publicar** y su **código** decide; el loop **no publica** un cambio de
  default (lo deja en el issue y lo escala a una **persona**; un `yes`
  nunca lo decide el loop); un **rebase** fallido **aborta** la publicación y
  deja la rama **local**; y `bin/pr-defaults-line.sh` con exit 1 **bloquea**
  la publicación. El cuerpo del PR emite `Changes a default: no`: el valor lo
  decide el cambio y un `yes` es de una **persona**.
- **`publish.md`: el freno, junto a la plantilla del cuerpo.** El prompt que
  publica dice lo mismo que `claim.md`: el loop **no publica** un cambio de
  default (lo deja en el issue y lo escala) y la línea que escribe es
  `Changes a default: no`.
- **Los prompts se reconcilian con el código que los cumple.** `gate.md` e
  `iteration.md` describen los **dos** locks que el gate toma de verdad: el
  global (`gates/scope.lock`) en modo **compartido** —dos slots compilan a la
  vez— y el del slot (`gates/<slot>/scope.lock`) en modo **exclusivo**. El
  lock se suelta **cuando termina la vuelta**, no al final de cada fase, y el
  aplazamiento lo causa otra vuelta **del mismo slot**, no otro slot.
- **`claim.md`: los modos del guard que ya existen.** `claim-guard.sh
  --ours <pr> <issue>` (el PR propio no se reclama a sí mismo),
  `--duplicates` (los PRs nuestros que perdieron la carrera contra un PR
  abierto de número menor) y `pr-defaults-line.sh --body <archivo>` (el
  **pre-vuelo offline** de la línea `Changes a default:`) quedan escritos en
  el prompt, con sus códigos de salida: el `6` del guard también es "la lista
  de PRs vino truncada", que es un tope medido sobre una lista inventada.
- **El inventario de `prompts/` pasa a ser generado.** `bin/prompts-inventory.py`
  pesa los 9 prompts vivos (**153.037 bytes**) y `prompts/README.md` lleva esa
  tabla; `--check` falla diciendo qué fila quedó desfasada. El inventario lleva
  **bytes**, no fechas: la fecha de una instantánea está en su nombre.
