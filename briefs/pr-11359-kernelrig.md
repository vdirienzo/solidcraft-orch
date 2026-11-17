# Brief: PR #11359 - el Kernel rig falla por un comentario en crates/kernel/src/history.rs

## El problema (diagnosticado, no lo re-investigues)
El job "Kernel rig (history)" del PR #11359 (issue #5857) falla con:
  REGRESSION (fail): cov-timeline-reorder-cut-bead

CAUSA RAIZ EXACTA:
- El PR cambio `crates/kernel/src/history.rs` (+1/-1): es SOLO una linea de comentario de doc,
  donde `F7:blend:...` paso a ser `F7:blend(...)`.
- PERO `crates/kernel/src/history.rs` esta en `tests/kernel-cases/PATHS-ALL`: tocarlo dispara
  TODOS los areas del kernel rig y el ladder (scripts/ci/kernel_rig_plan.py).
- El area `history` entonces corre sus casos, y el caso `cov-timeline-reorder-cut-bead` falla.
  Ese nombre de caso NO existe en el repo: lo mas cercano en main es
  `cov-timeline-reorder-cut-before-its-sketch-refused`.
- Ademas el PR regenero `tests/action_matrix/baseline.json` (+2407/-2407), una regeneracion masiva.

POR QUE ESTO ES LO QUE HAY QUE ARREGLAR:
- El repo tiene el trabajo de kernel PAUSADO. Un PR de docs (area:doc) no debe tocar
  crates/kernel/ en absoluto, ni para un comentario. Es la regla "Never touch crates/kernel".
- El cambio de sintaxis de nombres (`F7:blend:...` -> `F7:blend(...)`) es correcto y es lo que
  pidio el maintainer (la nota de formato pendiente). NO lo reviertas.

## Lo que hay que hacer (LITERAL)
1. Worktree: /home/user/solidcraft-wt/issue-5857 (verificar a que rama apunta; la rama del PR
   es fix/issue-5857-name-inside-parens en el fork).
2. REVERTIR el cambio de `crates/kernel/src/history.rs`: la linea de doc debe volver a decir
   `F7:blend:...` exactamente como esta en main. Ese archivo NO debe aparecer en el diff del PR.
   Verificalo despues con: git diff origin/main -- crates/kernel/   (tiene que dar VACIO)
3. Mirar `tests/action_matrix/baseline.json` (+2407/-2407). Ese archivo es un baseline generado.
   Si la regeneracion masiva es necesaria para el cambio de nombres, dejala. Si NO es necesaria
   (o sea, el PR lo regenero entero sin necesidad), revierte SOLO ese archivo a main:
     git checkout origin/main -- tests/action_matrix/baseline.json
   Decidi con evidencia: mira el diff (git diff origin/main -- tests/action_matrix/baseline.json
   | head -60) y decime si los cambios son coherentes con el renombrado de nombres. Si SI lo son,
   dejalo. Si son ruido, revertilo.
   OJO: no lo hagas a ciegas. Este baseline lo lee el CI de otra forma.
4. Commit: `fix: keep the kernel rig out of a docs change`
   (un solo commit con el revert de crates/kernel/; el archivo del baseline va en el mismo
   commit solo si lo cambiaste)
5. Push SOLO al fork: git push fork HEAD:fix/issue-5857-name-inside-parens
   Verificar con `git remote -v` que 'fork' = vdirienzo/solidcraft.
6. NO abras PR nuevo, NO toques origin, NO toques crates/kernel de otra forma, NO hagas push a
   otro worktree, NO compiles el workspace entero.
7. Despues del push, NO corras el gate entero (40 min): lo corre la cola de gates. Solo verifica
   que el diff ya no toca crates/kernel/.

## Si el kernel rig sigue fallando despues
Si con el revert de crates/kernel/ el caso `cov-timeline-reorder-cut-bead` sigue fallando,
NO lo arregles a mano. Reportalo con el log exacto y decilo: significaria que el PR cambia de
verdad el comportamiento que el caso mide (los nombres), y eso es una decision del maintainer.

## Entrega
- SHA del commit
- La salida de `git diff origin/main -- crates/kernel/` (tiene que estar vacia)
- Que decidiste con el baseline (dejarlo o revertirlo) y por que, con el diff de muestra
- Si el kernel rig sigue rojo, el log del fallo exacto
