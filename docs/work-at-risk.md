# Trabajo que vive en una sola maquina

**Fecha:** 2026-11-17

Este repo tiene una regla que el propio `HANDOFF.md` enuncia: *"el estado tiene que ser
cierto, no completo"* y *"GitHub manda; el disco se corrige"*. Y otra, de `README.md`:
*"el trabajo que no esta pusheado es trabajo invisible"*.

Esta pagina es el inventario de lo que **no** esta en GitHub. Es corta a proposito: si
crece, algo anda mal.

---

## 1. El fork de SolidCraft: dos ramas que solo existen en la laptop del mantenedor

La auditoria del propio repo (`reports/loop-codigo.md`, seccion 3.2, 2026-11-02) encontro
**12 ramas locales con commits reales que no estaban en el fork**. De esas 12, **10 ya
estan en el fork** (verificado hoy contra `vdirienzo/solidcraft`): el trabajo esta a
salvo.

Las dos que **no** estan:

| Rama | Commit | Que es |
|---|---|---|
| `perf/issue-3892-browser-tree-hover` | `2211fd87a` | "perf(#3892): index the hidden joints and folders" — 1 commit |
| `fix/issue-5505-sketch-constraint-dof` | `77665cb5b` | "fix(#5505): a zero dimension keeps constraining" — 3 commits |

**Como recuperarlas** (desde la maquina del mantenedor, donde si existen):

```bash
cd /ruta/al/solidcraft
git push fork perf/issue-3892-browser-tree-hover fix/issue-5505-sketch-constraint-dof
```

**Que se pierde y que no:**

- `fix/issue-5505-sketch-constraint-dof` es el **mismo fix** que `wt/issue-5505-evidence`
  (que si esta en el fork), y su trabajo **llego a upstream** por otro camino: el PR #10790
  de #5505 fue mergeado por el mantenedor. Perder la rama no pierde trabajo de upstream;
  pierde la rama y su historia.
- `perf/issue-3892-browser-tree-hover` es el **primer intento** del agente sobre #3892, que
  se quedo sin iteraciones; el orquestador encontro la causa raiz y lo redespacho. Si el
  trabajo del primer intento tiene algo que el segundo no tiene, esa parte se pierde.

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

El gate para saber si una rama tiene trabajo propio es que su punta **no** sea alcanzable
desde `fork/main`:

```bash
git rev-list --count fork/main..<rama>
```
