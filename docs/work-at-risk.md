# Trabajo que vive en una sola maquina

**Fecha:** 2026-11-17

Este repo tiene una regla que el propio `HANDOFF.md` enuncia: *"el estado tiene que ser
cierto, no completo"* y *"GitHub manda; el disco se corrige"*. Y otra, de `README.md`:
*"el trabajo que no esta pusheado es trabajo invisible"*.

Esta pagina es el inventario de lo que **no** esta en GitHub. Es corta a proposito: si
crece, algo anda mal.

---

## 1. El fork de SolidCraft: una rama en riesgo, y una que se creia perdida

La auditoria del propio repo (`reports/loop-codigo.md`, seccion 3.2, 2026-11-02) encontro
**12 ramas locales con commits reales que no estaban en el fork**. De esas 12, **10 ya
estan en el fork** (verificado hoy contra `vdirienzo/solidcraft`): el trabajo esta a
salvo.

La version anterior de esta pagina decia que **dos** ramas estaban en riesgo. **Estaba
mal en una de las dos**, y el error era del metodo, no de los datos:

| Rama | Commit | Que es |
|---|---|---|
| `perf/issue-3892-browser-tree-hover` | `2211fd87a` | "perf(#3892): index the hidden joints and folders" — 1 commit |
| `fix/issue-5505-sketch-constraint-dof` | `77665cb5b` | "fix(#5505): a zero dimension keeps constraining" — 3 commits |

**Verificado el 2026-11-17 contra las 237 ramas de `vdirienzo/solidcraft`:**

- **`fix/issue-5505-sketch-constraint-dof` NO esta en riesgo.** El commit `77665cb5b`
  esta en el fork, bajo otro nombre: `wip/issue-5505-sketch-constraint-dof`. Lo que se
  perdio fue el **nombre** de la rama, no el trabajo. Ademas el fix llego a upstream por
  otro camino: el PR #6345 (el de esa rama) se **cerro** sin mergearse, y el trabajo
  merged como **#10790** (`fix/issue-5505-length-dof`, MERGED). El issue #5505 esta
  **cerrado como COMPLETED** en upstream.
- **`perf/issue-3892-browser-tree-hover` SI esta en riesgo**, y no se puede recuperar
  desde esta maquina: el commit `2211fd87a` no existe en ninguno de los 237 refs del
  fork, ni en el checkout local. Es el **primer intento** del agente sobre #3892, que se
  quedo sin iteraciones; el orquestador encontro la causa raiz y lo redespacho. El issue
  #3892 esta **cerrado como COMPLETED** en upstream (por el PR #3894, de otro autor), asi
  que no bloquea a nadie: lo que se pierde es un intento descartado, no un fix pendiente.

**Como recuperarla** (desde la maquina del mantenedor, donde si existe):

```bash
cd /ruta/al/solidcraft
git push fork perf/issue-3892-browser-tree-hover
```

### El gate, ahora ejecutable

La version anterior de esta pagina usaba este comando como gate:

```bash
git rev-list --count fork/main..<rama>
```

**Ese gate esta mal.** Responde "la punta NO es alcanzable desde `fork/main`", que no
es lo mismo que "el commit no esta en GitHub": una rama mergeada bajo otro nombre (o
alcanzable desde otra rama del fork) da un numero > 0 y NO esta en riesgo. Por eso esta
pagina llamaba en riesgo a un commit que estaba en el fork.

La pregunta correcta es: **el commit existe en algun ref del fork?** Y hay un script que
la hace:

```bash
bash bin/branch-risk.sh          # la lista, y rc=1 si hay trabajo solo en este disco
```

Dice tres cosas, y no las confunde: **EN RIESGO** (el commit no esta en ningun ref del
fork: existe solo en este disco), **SALVADA** (el commit esta en GitHub bajo otro
nombre: el trabajo esta a salvo, el nombre no), y **mergeada** (ya esta en
`fork/main`). Cada rama en riesgo sale con el comando exacto que la salva.

**Ademas, el `main` del fork esta 415 commits atras del upstream.** Es la consecuencia de
la estrategia de merge (`git merge tangency-labs:main`): el `main` del fork es un merge, no
un fast-forward. No es un problema de trabajo perdido, pero explica por que el `main` del
fork no se parece al upstream.

---

## 2. El orquestador: la mitad LOOP

La mitad LOOP del orquestador (`agent-issue.sh`, `claim-race.sh`, `claim-brake.sh`,
`claim-salvage.sh`, `gate-quick.sh`, `pr-defaults-line.sh`, `gc-disk.sh`, `supervisor.sh`,
`config.env`, `prompts/agent-issue.md` y sus dos suites) **no esta en git**: vive en
`$LOOP_DIR` de la maquina del orquestador.

**No es un problema de trabajo perdido** (esa maquina los tiene), pero es un problema de
reproducibilidad: un clone de este repo no puede publicar, ni gatear, ni arbitrar.

- El inventario completo: [`docs/la-otra-mitad.md`](la-otra-mitad.md)
- Como traerlo: [`briefs/bring-the-loop.md`](../briefs/bring-the-loop.md)
- Que falta en cada maquina: `bash bin/preflight.sh`

---

## 3. La regla

Una rama que no esta en GitHub es un commit que no existe para nadie mas, y una rama que
esta en GitHub y no se sabe de que es, es ruido que esconde la que si importa.

**Despues de cada tanda de trabajo del orquestador, esto se revisa**: las ramas nuevas
del fork se pushean, y las que tienen trabajo propio que no esta en ningun PR se anotan
aca.

El gate para saber si una rama tiene trabajo propio **no** es "su punta no sea alcanzable
desde `fork/main`" (esa pregunta da un numero > 0 para un commit que esta en el fork
bajo otro nombre, y por eso esta pagina se equivoco una vez). El gate es: **el commit
existe en algun ref del fork?**

```bash
bash bin/branch-risk.sh    # rc=1 si hay trabajo que solo existe en este disco
```

El `rc` es lo que importa: `0` es "no se perdio nada", `1` es "hay commits que muerecon
el disco". La lista dice por que y como salvar cada uno.
