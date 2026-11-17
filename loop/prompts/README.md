# Los prompts del loop

Este directorio tiene los prompts que el supervisor despacha a los agentes
`sc-*` de OpenCode. **Cada prompt es la especificación de una tarea**: el
supervisor lo pasa tal cual al agente, no lo reescribe.

Este README es un inventario: dice qué hay, para qué sirve cada cosa y
cuánto pesa. **No copia el contenido de los prompts** — para eso están los
archivos.

Los `.bak*` son instantáneas de versiones anteriores de un prompt, guardadas
a mano cuando se tocó el prompt. No los usa nadie: el loop sólo lee los
archivos sin sufijo.

## Los prompts que están vivos

Los pesos de la tabla los **mide** `bin/prompts-inventory.py`: no se
escriben a mano, porque un prompt cambia de peso cada vez que se edita y una
tabla escrita a mano acaba mintiendo. El script tiene dos modos: `--write`
regenera el bloque de abajo y `--check` dice qué fila quedó desfasada (y con
eso falla).

<!-- prompts-inventory:start -->
| Archivo | Bytes |
|---|---:|
| `agent-issue.md` | 1.677 |
| `claim.md` | 8.024 |
| `evidence.md` | 15.040 |
| `gate.md` | 20.919 |
| `implement.md` | 7.815 |
| `iteration.md` | 65.751 |
| `publish.md` | 24.184 |
| `review.md` | 5.511 |
| `triage.md` | 9.307 |

Total de los 9 prompts vivos: **158.228 bytes**.
<!-- prompts-inventory:end -->

Para qué sirve cada uno:

| Archivo | Agente | Para qué sirve |
|---|---|---|
| `iteration.md` | `sc-orchestrator` | La especificación de **una vuelta** del loop. Es el prompt del orquestador: qué leer, qué delegar, qué no hacer. |
| `triage.md` | `sc-triage` | Triaje: decide si un issue **se toma** o **se suelta**. No implementa nada. |
| `claim.md` | `sc-claim` | Reclamo del issue: rama, commit de claim y PR draft en el fork. |
| `implement.md` | `sc-implement` | Implementación del fix en la rama del issue, con TDD real. |
| `gate.md` | `sc-gate` | Análisis del gate de CI (el gate ya está lanzado en background por `bin/start-gate.sh`). |
| `evidence.md` | `sc-evidence` | Evidencia visual del cambio: capturas **antes y después**. |
| `review.md` | `sc-review` | Revisión del diff contra las reglas del repo; emite el veredicto. |
| `publish.md` | `sc-publish` | Publica un PR que ya pasó el gate (verde). |
| `agent-issue.md` | lo usa `bin/agent-issue.sh` | Apertura del issue: el texto que se le pasa al modelo que propone la idea, ya con las reglas del repo dentro. |

## Las instantáneas (`.bak*`)

No las lee nadie. Cada una es una foto de un prompt **antes** de un cambio.
El inventario lleva **bytes**, no fechas: la fecha de una instantánea está en
su nombre, y una fecha escrita a mano se desfasca sin que nadie lo note.

| Archivo | Instantánea de | Bytes |
|---|---|---:|
| `iteration.md.bak-20261027-034937` | `iteration.md` | 61.810 |
| `iteration.md.bak2` | `iteration.md` | 33.698 |
| `iteration.md.bak3` | `iteration.md` | 34.544 |
| `iteration.md.bak5` | `iteration.md` | 37.005 |
| `evidence.md.bak-20261027-034937` | `evidence.md` | 14.410 |
| `evidence.md.bak5` | `evidence.md` | 9.657 |
| `gate.md.bak2` | `gate.md` | 6.203 |
| `gate.md.bak5` | `gate.md` | 6.659 |
| `publish.md.bak5` | `publish.md` | 9.930 |
| `review.md.bak2` | `review.md` | 4.938 |

Total de las instantáneas: **218.854 bytes**. Se pueden borrar (o archivar)
cuando ya no hagan falta: el historial que de verdad importa está en el
`CHANGELOG.md` de este directorio.

## Secretos

Revisados los 18 archivos de este directorio (el 2026-10-28): **no hay
ningún token, clave ni certificado**. Se buscó `ghp_`, `gho_`, `github_pat_`,
`sk-`, claves `AKIA…`, claves privadas PEM y asignaciones con
`password`/`secret`/`api_key`/`bearer`/`authorization`. Los únicos aciertos
fueron falsos positivos (palabras que aparecen en texto normal, como
`crates/kernel/tests/boolean_props`).

Los credenciales del loop **no** viven acá: viven en `~/.config/opencode/`
y en `$LOOP/gh.env`, y ninguno de los dos se copia a este directorio.

## Propuesta de versionado (para que la haga una persona)

Hoy los prompts **no están versionados**: `$LOOP` no es un repositorio git
(lo confirma `git status` en `$LOOP`: *"not a git repository"*). Un prompt
editado a mano se pierde sin dejar rastro, y una vuelta puede empezar con
un prompt a medio cambiar. La propuesta es llevarlos al repo de SolidCraft.

**Destino:** `/home/user/solidcraft/ops/loop-prompts/` (un directorio nuevo
en la raíz del repo). Se propone `ops/` y no `docs/` porque `docs/` es la
documentación del producto que se publica, ni `skills/` porque ahí viven
las skills de OpenCode y estos prompts no son skills: los despacha el
supervisor. El destino deja los prompts fuera del crate de Rust: no tocan la
compilación.

**Qué versionar:** sólo los 9 prompts vivos. Las instantáneas `.bak*` se
quedan acá (o se archivan), no van al repo.

**Comandos** (los ejecuta una persona, con el repo ya clonado y sin
cambios pendientes):

```bash
cd /home/user/solidcraft
git switch -c ops/loop-prompts            # rama propia: nunca a `origin`
mkdir -p ops/loop-prompts
for f in agent-issue claim evidence gate implement iteration publish review triage; do
  cp "$HOME/.local/share/solidcraft-loop/prompts/$f.md" "ops/loop-prompts/$f.md"
done
git add ops/loop-prompts
git commit -m "ops: add the loop prompts (sc-* agents) of the SolidCraft loop"
git push fork ops/loop-prompts             # al fork, NO a `origin`
```

Después, para actualizar un prompt sin perder el rastro, el mismo
`cp` + `git commit` alcanza: el diff dice exactamente qué cambió en la
especificación de cada agente.

**Nota:** el loop nunca pushea a `origin` (el upstream es del maintainer) y
nunca mergea. La propuesta usa `fork` (`vdirienzo/solidcraft`) a propósito.
