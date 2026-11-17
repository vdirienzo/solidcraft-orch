# Brief: issue #6738 - split body con dos piezas separadas (SPLIT BODY: unable to split body)

## El bug (triage LITERAL del maintainer, dudedagger42)
> "Reproduced on 0.25.1 (official `solidcraft-cli`, Windows) with a design I built from your
> steps: one sketch with two separate squares (20 mm, 50 mm apart), both extruded 10 mm as New
> Body, then Combine (join). Splitting that body with a plane through the middle of both squares
> (`solid.split_body`, plane z = 5) stops with `the tool does not split the body`."
>
> "Root cause (likely): the split in `crates/doc/src/eval.rs` (FeatureKind::Split, via
> `split_by_plane_traced`) keeps only the non-empty halves from `kernel::half_space` and refuses
> with this message when fewer than two come back"

## Causa raiz trazada
- `crates/doc/src/eval.rs:7748`:
    if parts.len() < 2 { return Err(DocError::Invalid("the tool does not split the body")) }
- `crates/doc/src/eval.rs:9236-9248` (`split_by_plane_traced`): solo conserva las mitades NO VACIAS
  que devuelve `kernel::half_space`.
- Para un cuerpo formado por DOS piezas separadas (unidas con Combine), el plano de corte pasa
  por el medio de ambas, pero `half_space` devuelve las mitades de cada pieza por separado:
  los volumenes se duplican o se pierden y nunca llegan 2 mitades no vacias del cuerpo entero.

## Que hay que hacer (LITERAL, no explores de mas)
1. Worktree YA EXISTE: /home/user/solidcraft-wt/issue-6738 en la rama
   fix/issue-6738-split-body-two-pieces. Verifica que este en origin/main (git log -1).
   Si el worktree quedo con el codigo viejo, rehacelo desde origin/main.
2. Escribi el test RED en el archivo de tests EXISTENTE del area. El area es eval/split:
   busca el archivo de tests de eval (crates/doc/src/eval_*_tests.rs o el modulo `mod tests` de
   crates/doc/src/eval.rs). PROHIBIDO crear un archivo de test nuevo por bug (AGENTS.md:24).
   - El test debe construir el caso: un sketch con DOS cuadrados separados (20 mm y 50 mm
     aparte), extruidos 10 mm como New Body, combinados (Combine/join), y despues un
     `solid.split_body` con un plano por el medio de ambos (z = 5).
   - El test debe fallar con el error "the tool does not split the body" antes del fix.
   - Name: test_split_body_of_two_joined_pieces_returns_both_halves
3. Corre el test dirigido (RED):
   cd /home/user/solidcraft-wt/issue-6738
   CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-loop/targets/slot-6738 CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 nice -n 19 cargo test -p solidcraft-doc <nombre_del_test> --lib
   Si el build se pasa de 4 GiB de RAM, no es fallo tuyo: usa un scope propio con memoria
   (systemd-run --user --scope --quiet --unit=sc6738 -p MemoryMax=24G).
4. EL FIX: en `split_by_plane_traced`, cuando el corte atraviesa VARIAS piezas del mismo cuerpo,
   las mitades de cada pieza hay que reunirlas por cuerpo: el resultado del split son las
   mitades de TODAS las piezas, no solo de una. El error "the tool does not split the body"
   solo corresponde a un cuerpo que realmente no se pudo cortar.
   Concreto: mira como `split_by_plane_traced` arma `parts` y de donde saca los ids de las
   entidades. Si agrupa por id de pieza, hay que agrupar por el cuerpo al que pertenecen.
   OJO: no inventes una arquitectura nueva. El fix mas chico: al contar las mitades, contá las
   que corresponden al cuerpo completo (sumando las de todas sus piezas), no las de una sola pieza.
5. Dejalo en VERDE con el mismo test.
6. Commits (en este orden):
   1. `test: reproduce 6738 (split a body of two joined pieces)`
   2. `fix: split every piece of the body the plane cuts`
7. Push SOLO al fork:
   git push -u fork fix/issue-6738-split-body-two-pieces
   Verificar con `git remote -v` que 'fork' = vdirienzo/solidcraft.
8. NO abras PR todavia: el entregable de este agente es el fix + test en verde + commits
   pusheados. El PR lo abre la wave.
9. NO toques crates/kernel. NO toques el repo principal ni el worktree de otro agente.

## Entrega
- SHA de cada commit
- La salida del test en RED (con el mensaje del error) y en GREEN
- Una linea de como explicaste el fix
- Si el fix resulto mas invasivo de lo esperado, dilo explicitamente
Maximo 120 iteraciones. Ponete un tope propio de 60 y devolve lo que tengas si no terminaste.
