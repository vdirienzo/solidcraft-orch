# Brief: issue #11367 - el thread modelado rompe el segundo cilindro (INTERFERENCE)

## El bug (triage LITERAL del maintainer, dudedagger42)
> "Reproduced on the official solidcraft-cli 0.30.1 (CLI only). On an 80 x 80 x 20 mm block with
> two 5 mm holes, a modelled M6 thread on the first hole works; threading the second hole,
> modelled or cosmetic, then fails with 'no cylindrical face there to thread'."
>
> "Root cause (likely): a modelled thread cuts the whole body as facets (crates/doc/src/eval.rs,
> the Thread feature: `faceted_boolean` at pitch/200), so the second hole is no longer a cylinder
> and `thread_on_impl` refuses it with 'no cylindrical face there to thread'."

## Causa raiz trazada
- `crates/doc/src/eval_thread.rs:204`:
    ok_or_else(|| DocError::Invalid("no cylindrical face there to thread".into()))?
  dentro de `thread_on`.
- Busca el cilindro con `kernel::cylinder_face_at` sobre un cuerpo YA FACETADO por el primer
  thread modelado: la cara cilindrica del segundo dejo de existir como tal (es un poligono de
  facetas), y la seleccion se agota.

## Que hay que hacer (LITERAL, no explores de mas)
1. Worktree YA EXISTE: /home/user/solidcraft-wt/issue-11367 en la rama
   fix/issue-11367-thread-breaks-second-cylinder. Verifica que este en origin/main.
2. Escribi el test RED en el archivo de tests EXISTENTE del area. El area es thread:
   busca crates/doc/src/eval_thread_tests.rs o el modulo `mod tests` de crates/doc/src/eval_thread.rs.
   PROHIBIDO crear un archivo de test nuevo por bug (AGENTS.md:24).
   - El test: un bloque 80 x 80 x 20 mm con DOS agujeros de 5 mm. Un thread M6 modelado en el
     primero funciona; en el SEGUNDO falla con "no cylindrical face there to thread".
   - El test debe fallar con ese error antes del fix.
   - Name: test_thread_finds_the_second_hole_after_a_modelled_thread
3. Corre el test dirigido (RED):
   cd /home/user/solidcraft-wt/issue-11367
   CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-loop/targets/slot-11367 CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 nice -n 19 cargo test -p solidcraft-doc <nombre_del_test> --lib
   Si el build se pasa de 4 GiB de RAM, no es fallo tuyo: usa un scope propio con memoria
   (systemd-run --user --scope --quiet --unit=sc11367 -p MemoryMax=24G).
4. EL FIX: el thread modelado no debe facetar TODO el cuerpo, o la busqueda del cilindro debe
   funcionar sobre la geometria exacta. Opciones, en orden de preferencia:
   a) Que `thread_on` busque la cara cilindrica por la GEOMETRIA EXACTA del hole (el cilindro
      original del agujero) y no por la cara facetada que quedo despues del primer thread.
   b) Que el thread modelado solo recorte el hueco que rosca, sin facetar el resto del cuerpo.
   c) Si (a) y (b) son invasivos: que la busqueda acepte una cara poligonal-cilindrica
      (facetas de un cilindro) como candidata.
   OJO: NO toques crates/kernel (esta pausado). El fix va en crates/doc.
   OJO 2: no inventes arquitectura. Empieza por la opcion (a): el hole es un cilindro exacto
   antes de roscarlo; el thread modelado no puede cambiar la cara del AGUJERO QUE NO SE ROSCA.
   Si el codigo no conserva esa referencia, decilo y elegi la opcion que puedas implementar.
5. Dejalo en VERDE con el mismo test.
6. Commits (en este orden):
   1. `test: reproduce 11367 (a thread breaks the second hole)`
   2. `fix: find the hole to thread on its exact cylinder`
7. Push SOLO al fork:
   git push -u fork fix/issue-11367-thread-breaks-second-cylinder
   Verificar con `git remote -v` que 'fork' = vdirienzo/solidcraft.
8. NO abras PR todavia: el entregable es el fix + test en verde + commits pusheados. El PR lo
   abre la wave.
9. NO toques crates/kernel. NO toques el repo principal ni el worktree de otro agente.

## Entrega
- SHA de cada commit
- La salida del test en RED (con el mensaje del error) y en GREEN
- Una linea de como explicaste el fix
- Si el fix resulto mas invasivo de lo esperado, o si tuviste que ir a la opcion (c), dilo
Maximo 120 iteraciones. Ponete un tope propio de 60 y devolve lo que tengas si no terminaste.
