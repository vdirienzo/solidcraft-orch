# sc-claim — reclamo de un issue

Reclamás el issue: rama, commit de claim, PR draft en el fork.

## Procedimiento

1. **El guard decide si podés reclamar.** Es un script, no una instrucción:
   aplica los labels excluidos, consulta la **timeline** del issue (la fuente
   autoritativa del reclamo) y los **cuerpos de los PRs abiertos** (GitHub no
   cross-referencia un `#N` dentro de un code block, así que la timeline sola
   no alcanza), y mira el tope de PRs abiertos nuestros:

```
bash /home/user/.local/share/solidcraft-loop/bin/claim-guard.sh <N>
```

   | Código | Significado | Qué hacés |
   |---|---|---|
   | 0 | el issue se puede reclamar | seguí con el paso 2 |
   | 2 | tiene un label excluido (`in progress`, `kernel-paused`, `status:decision`, `needs-info`, `area:kernel`) | **no abras el PR**: soltá el issue |
   | 3 | **ya lo reclama un PR abierto** (de cualquier autor) | **no abras el PR**: soltá el issue y decí el número del PR y su autor |
   | 4 | el issue está cerrado o no existe | soltá el issue |
   | 5 | our open PRs llegaron al tope (`MAINT_THRESHOLD`) | soltá el issue: la vuelta va a mantenimiento |
   | 6 | GitHub no respondió **o la lista de PRs vino truncada** | soltá el issue: sin verificación no hay reclamo |

   Los labels y el tope salen de `config.env` (`CLAIM_EXCLUDED_LABELS`,
   `CLAIM_WANTED_LABELS`, `MAINT_THRESHOLD`): **no repitas la lista a mano**, y
   si el código y el prompt no coinciden, el código gana.

   El **6** también es "la lista vino truncada": una lista de cien PRs dice
   "cien" cuando hay doscientos, y un tope medido sobre una lista truncada es
   un tope inventado. El guard no sabe y lo dice.

   Un código distinto de 0 **termina el reclamo**: no renombres la rama, no
   commitees, no abras el PR.

2. **Re-verificá** que el issue sigue abierto y sin label `in progress` (puede
   haberlo tomado otro entre el guard y ahora). Si cambió, soltá el issue.

3. **Renombrá la rama del worktree** (la vuelta corre DENTRO del worktree del
   issue, que el orquestador ya creó con la rama `wt/issue-<N>`):

```
git branch -m fix/issue-<N>-<slug>
```

   **No** hagas `git checkout` (cambiarías la rama del issue) y **no** trabajes en
   `/home/user/solidcraft`: es el checkout principal del loop y tiene cambios
   locales (el overlay de `AGENTS.md`), así que cualquier `git checkout` ahí
   falla y se lleva el trabajo de los demás.

4. **Commit vacío de claim** (el mensaje, en inglés):

```
git commit --allow-empty -m "claim: #<N>"
```

5. **Push al remoto `fork`** (nunca `origin`), **por refspec completo** (la rama
   está checkouteada en el worktree y git no la pushea por nombre):

```
git push fork HEAD:refs/heads/fix/issue-<N>-<slug>
```

6. **PR draft** al repo upstream, con el **camino unico**: el script arma el
   body (le agrega la linea `Changes a default:` si falta, y lo valida con el
   parser del upstream) **antes** de que el pull request exista, y recien ahi
   lo abre en draft. El titulo va **`<summary> (#<N>)`**: el bot busca el
   `#N` **en el titulo** (asi lo dice el AGENTS.md del repo), pero el titulo
   es un resumen del cambio, no el numero pelado. Ej.:
   `Fillet: variable radius along a chain (#123)`. El cuerpo arranca con
   `Fixes #<N>.` (lo que el bot lee para asignar el issue) y lleva la línea
   `Changes a default: no` (lo que el check del repo lee: sin esa línea
   el PR se frena). El valor de esa línea lo decide el **cambio**: si el
   cambio toca un default, el loop **no publica** (ver el freno de
   publicación) — el PR que el loop publica dice siempre `no`. Todo —título
   y cuerpo— **en inglés**:

```
bash /home/user/.local/share/solidcraft-orch/bin/publish-pr.sh --repo tangency-labs/solidcraft --base main --head vdirienzo:fix/issue-<N>-<slug> --title "<summary> (#<N>)" --body "Fixes #<N>.
Changes a default: no" --issue <N>
```

   El script imprime el numero del pull request y su URL. Si el body no pasa
   el check de la linea de los defaults, **no abre nada**: y tampoco se abre
   a mano.

   **El pull request no se abre a mano:**

```
# DENIED: el pull request se abre con publish-pr.sh, nunca a mano
gh pr create
```

7. Si el bot de claim dice que otro ya lo tiene, soltá el issue.

## Freno de publicación

El freno corre **antes de publicar** y su resultado manda: si el freno dice que
no, no se publica nada. El turno lo reporta y termina.

1. **El guard corre antes de publicar.** `claim-guard.sh` se ejecuta **antes de publicar**
   (es el paso 1) y su **código** de salida **decide**: si no es `0`, no se
   publica el PR y el reclamo termina. El prompt dice *cuándo* reclamar; el
   guard dice *si* se puede, y si los dos no coinciden, gana el guard.
2. **El loop no publica un cambio de default.** Si el cambio altera un default,
   el loop **no publica**: deja el trabajo en el issue, escribe el motivo y lo
   escala a una **persona** (la decisión del mantenedor; la regla del repo es
   conservar el comportamiento viejo detrás de una preferencia). Un `yes`
   **nunca** lo decide el loop: el PR que el loop publica dice
   `Changes a default: no`.
3. **Un rebase fallido aborta la publicación.** Si el rebase contra `main`
   falla, la publicación se **aborta**: la rama se queda **local** (no se
   pushea), el turno lo reporta y no se abre nada. No se publica sobre una
   rama que no está sobre `main`.
4. **La línea de defaults se valida antes de publicar.**
   `bin/pr-defaults-line.sh --body <archivo>` se corre contra el **cuerpo que
   se va a publicar**, **antes** de que salga de la máquina (es un modo
   **offline**: ni GitHub, ni red, ni token). Si sale con `1`, **bloquea** la
   publicación; si sale con `2`, el archivo no se pudo leer; si sale con `6`,
   el check **no se hizo** (UNKNOWN), nunca "la línea falta". Por eso el
   cuerpo lleva siempre la línea `Changes a default: no`.
5. **El PR que se va a publicar no se reclama a sí mismo.**
   `claim-guard.sh --ours <pr> <issue>` consulta el reclamo **dejando de
   lado** ese PR: el PR propio no puede ser el que bloquea su propio issue.
   La exclusión sólo aplica cuando el autor del PR es **nuestro** o
   **desconocido**: un PR que se puede atribuír a otra persona **conserva** el
   reclamo. Si el modo devuelve `3`, hay otro PR abierto que sí lo reclama:
   soltá el issue.
6. **La carrera de un issue.** `claim-guard.sh --duplicates` devuelve los PRs
   abiertos **nuestros** que **perdieron** la carrera de su issue contra un PR
   abierto de **número menor** (la regla del upstream: gana el PR abierto de
   número más bajo). Salida `1`: perdimos la carrera; ese PR se cierra o se
   deja en el issue, y **no** se abre otro.

## Prohibido

- `git push origin` (jamás, ni a una rama de trabajo).
- `gh pr merge`, `gh issue close`, `gh pr close`.
- Cambios de código: acá sólo el commit vacío de claim.
- Abrir el PR con un guard que devolvió un código distinto de 0.
- Publicar un cambio de default (el loop lo deja en el issue y lo escala).
- Publicar con un rebase fallido (la rama se queda local).
- Publicar con un cuerpo sin la línea `Changes a default: no`.
- Publicar con un `--body` que devolvió `1` o `2`, o con un `--ours` que
  devolvió `3`.
- Publicar sin haber corrido el `--ours`: el PR propio no se consulta solo.

## Contrato de salida (≤15 líneas)

```
rama: <nombre>
pr: <número>
url: <link>
guard: <código 0/2/3/4/5/6>
defaults-line: <código 0/1/2/6>
ours: <código 0/3>
claim ok: sí | no
motivo: <si no, una línea>
```

El `guard` es el código que devolvió `claim-guard.sh`: `0` es el único código
que habilita el PR. Si no lo corriste, el reclamo **no** está verificado: no
publiques nada y decilo en el motivo.

El `defaults-line` es el código de `pr-defaults-line.sh --body`: sólo el `0`
deja publicar. El `ours` es el de `claim-guard.sh --ours`: el `3` significa
que otro PR abierto reclama el issue.

Si no podés cumplir el contrato, devolvé el motivo en una línea.
