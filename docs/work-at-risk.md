# Trabajo que vive en una sola maquina

**Fecha:** 2026-11-17

Este repo tiene una regla que el propio `HANDOFF.md` enuncia: *"el estado tiene que ser
cierto, no completo"* y *"GitHub manda; el disco se corrige"*. Y otra, de `README.md`:
*"el trabajo que no esta pusheado es trabajo invisible"*.

Esta pagina es el inventario de lo que **no** esta en GitHub. Es corta a proposito: si
crece, algo anda mal.

**Actualizado el 2026-11-18: hoy el inventario esta VACIO.** Las 83 ramas que el script
de riesgo reportaba estan a salvo en el fork (bajo `archive/`), y el script de riesgo
dejo de mentir (ver la seccion 1).

---

## 1. El fork de SolidCraft: hoy, nada en riesgo

**El 2026-11-18 el script de riesgo reportaba 83 ramas "en riesgo". Todas estaban a
salvo despues de empujarlas al fork** (`git push fork <sha>:refs/heads/archive/<rama>`,
83 ramas en 5 lotes). La cuenta final: **0 en riesgo, 160 salvadas con otro nombre, 46
mergeadas en `origin/main`**.

**El script moria, y por eso el numero era falso.** `bin/branch-risk.sh` comparaba cada
rama contra `fork/main`, y el `fork/main` esta **6034 commits atrasado** respecto del
`origin/main` (el fork solo recibe lo que uno mergea en el). La pregunta que hace el
script es "este trabajo esta en el fork?", y medir contra el fork contaba **toda la
historia del upstream** como "trabajo que solo existe en este disco": una rama con 5
commits propios aparecia con 4323.

**El arreglo**: la base es el `main` del **upstream** (`origin/main`), no el del fork. La
razon: lo que se pregunta es "este trabajo MIO esta en el fork?", y la historia del
upstream no es trabajo nuestro.

**Lo que el numero NO dice (y hay que decirlo)**: 83 ramas en riesgo es una cota
superior, y ninguna medicion de "cuanto trabajo queda pendiente" sale de un solo numero:

- La mitad son la MISMA idea en tres ramas (`backup/*`, `tmp-*`, `salvage/*`, `rebase/*`
  del mismo issue).
- Un **squash-merge cambia el SHA**: un commit ya mergeado upstream aparece como
  "propio" hasta que se compara por **patch-id** y no por SHA. Medido: los 3 commits de
  `fix/issue-2130-hover-pan` NO estan en `origin/main` por patch-id, aunque su PR
  (#11886) esta mergeado como `23d61d702`.
- Comparar por **contenido** (blob a blob) tampoco alcanza: `main` sigue avanzando, y
  un fichero que el PR toco cambia despues por otros motivos, asi que da "contenido
  propio" en 82 de las 83 ramas. El numero de "trabajo real pendiente" NO sale de ahi.

Por eso las ramas se empujaron **todas**: empujar de mas no cuesta, empujar de menos
pierde trabajo. El estado real de "cuanto queda" se lee issue por issue, no con un
contador.

### La rama que se creia perdida

La version anterior de esta pagina decia que **dos** ramas estaban en riesgo. **Estaba
mal en una de las dos**, y el error era del metodo, no de los datos:

| Rama | Commit | Que es |
|---|---|---|
| `perf/issue-3892-browser-tree-hover` | `2211fd87a` | "perf(#3892): index the hidden joints and folders" — 1 commit |
| `fix/issue-5505-sketch-constraint-dof` | `77665cb5b` | "fix(#5505): a zero dimension keeps constraining" — 3 commits |

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

**Actualizado el 2026-11-18: esta seccion estaba en riesgo y ya no.**

La mitad LOOP del orquestador (`agent-issue.sh`, `claim-race.sh`, `claim-brake.sh`,
`claim-salvage.sh`, `gate-quick.sh`, `pr-defaults-line.sh`, `gc-disk.sh`, `supervisor.sh`,
`config.env`, `prompts/agent-issue.md` y sus dos suites) vivia **solo** en `$LOOP_DIR` de
la maquina del orquestador. **Hoy esta en git**: la rama `origin/fix/orchestrator-truthfulness`
(28 commits) se integro con merge `--no-ff` (commit de movimiento `149f7fa`), y los
ficheros de apoyo que la suite necesitaba quedaron adoptados en `loop/`.

Lo que **sigue** sin estar en git, a proposito:

| Que | Por que | Como se recupera |
|---|---|---|
| `loop/config.env` | lleva las rutas de UNA maquina y secretos | `loop/config.env.example` esta en git; `cp config.env.example config.env` |
| `state/`, `logs/`, `targets/`, `locks/`, `gates/`, `state.json` | estado de la maquina, se regenera | `bash bin/merge-state.sh --split --prefer-artifact` |
| El `config.env` real del LOOP (`$LOOP_DIR/config.env`) | idem, mas los labels de excepcion de cada repo | el backup portable (`vdirienzo/hermes-harness`) lo lleva |

**Verificado hoy:** un clon limpio de este repo (`git clone` sin ningun fichero local)
pasa `bin/test-all.sh --fast` (20/20) **y** `python3 loop/bin/test-rules.py` (todas las
reglas, RC=0). La suite crea su `config.env` desde la plantilla si no lo encuentra, y lo
borra al terminar.

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
