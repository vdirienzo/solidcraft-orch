# Brief: elegir 3 issues REALES de bug para atacar (y dejar cada uno con test RED)

## Contexto
Repo upstream: tangency-labs/solidcraft. Fork propio: vdirienzo/solidcraft.
Hay ~3598 issues abiertos con label `needs-triage` y SIN `in progress` (o sea, sin claim).
Ya atacamos y tenemos PR o trabajo hecho sobre estos: 2216, 2130, 2721, 2160, 5857, 3599, 4712,
9086, 10747, 12124, 12293, 12085, 12219. NO los repitas.
Ya DESCARTADOS por ser limite de diseno / falta repro / kernel: 2379, 2323, 2253, 632, 2422,
2369, 2703, 979, 1030, 1322, 1793, 2328, 2183, 2239, 2699.

## El recorte que tenes que revisar
Los issues con label `needs-triage` y SIN label `in progress`, del mas nuevo al mas viejo.
Empieza por estos 60 y segui si hace falta:
12411 12410 12409 12408 12407 12406 12401 12393 12391 12390 12388 12384 12383 12382 12381
12380 12378 12376 12375 12374 12371 12370 12367 12366 12365

## QUE ES UN BUG REAL (criterio estricto)
El triage del maintainer (dudedagger42) tiene que confirmar que es un bug. Leé los comentarios:
  gh api repos/tangency-labs/solidcraft/issues/<N>/comments
DESCARTA si el triage dice cualquiera de estos:
- "by design" / "a stated limit" / "works as intended"
- "not enough to reproduce" / "no steps" / "cannot reproduce"
- "please add steps" / "needs info"
- es del area kernel (label `area:kernel` o `kernel-paused`)
- "same as #X" (ya se agrupo)
- "usage question" (el usuario no relleno un campo)
- "not a bug"

ACEPTA si: el triage dice que es un bug real, o el issue tiene un repro claro (pasos o el JSON
de la operacion fallida) y el error es un crash, un resultado incorrecto, o un mensaje de error
equivocado.

## Para CADA uno de los 3 que elijas
1. Traza la causa raiz en el codigo. Se explicito: archivo:linea y por que pasa.
2. Crea el worktree:
   git -C /home/user/solidcraft fetch origin
   git -C /home/user/solidcraft worktree add /home/user/solidcraft-wt/issue-<N> -b fix/issue-<N>-<slug> origin/main
3. Escribe el test RED en el archivo de tests EXISTENTE del area (PROHIBIDO crear un archivo de
   test nuevo por bug: AGENTS.md:24 lo prohibe explicitamente). Si el area no tiene archivo de
   tests, usa el modulo `mod tests` que ya exista en el archivo fuente del area.
4. Corre el test dirigido para confirmar que falla (RED):
   cd /home/user/solidcraft-wt/issue-<N>
   CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-loop/targets/slot-<N> CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 nice -n 19 cargo test -p <crate> <nombre_test> --lib
   (si el crate no tiene --lib, proba --bins o el filtro que corresponda)
   Si el build se pasa de 4 GiB de RAM, no es fallo tuyo. Si te falta tiempo, deja el test
   commiteado y reportalo.
5. Commitea SOLO el test RED: mensaje `test: reproduce <N> (<descripcion corta>)`
6. Pushea SOLO la rama al fork:
   git push -u fork fix/issue-<N>-<slug>
   Verifica con `git remote -v` que 'fork' = vdirienzo/solidcraft. Si ese remote no existe, NO lo
   crees: reportalo.
7. NO hagas el fix. NO abras PR. NO toques el repo principal ni el worktree de otro agente.
   NO toques crates/kernel.

## LO MAS IMPORTANTE: el triage
Antes de aceptar un issue, PEGA en tu informe el texto LITERAL del triage (la frase exacta del
maintainer que dice que es un bug). Si no hay triage, decilo explicitamente: un issue sin triage
del maintainer no se publica, pero puede quedar con el RED listo para cuando el maintainer lo
confirme.

## Entrega
Por cada uno de los 3: numero, titulo, el texto literal del triage, la causa raiz con
archivo:linea, el worktree, la rama, el SHA completo del commit RED, el comando del test y la
salida del fallo (el mensaje del assert, recortado). Y una lista de los issues que descartaste
con el motivo (una linea cada uno).
Maximo 120 iteraciones. Ponete un tope propio de 80 y devolve lo que tengas si no terminaste.
