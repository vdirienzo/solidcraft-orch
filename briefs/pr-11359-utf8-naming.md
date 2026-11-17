# Brief: PR #11359 - arreglar el panic UTF-8 de face_name_end (issue #5857)

## Contexto
PR abierto: https://github.com/tangency-labs/solidcraft/pull/11359 (head 56d824fa, rama del fork).
El maintainer bherbruck dijo LITERALMENTE en el PR:
> "One real problem before this can go in: `face_name_end` in `crates/doc/src/naming.rs` steps `at` one byte at a time and then slices `&s[at..]`. A name with a non-ASCII character inside a blend edge, for example `F5:blend(F2:side:\u66f2|F2:top)`, makes the slice start inside the character and panics, and `blend_seams` calls it for every blend face. Please walk the string by `char_indices` (or on bytes without slicing a `str`) and add a test with a non-ASCII curve id. This also changes the names written into saved designs, so please add the pending format note for it too."

## Lo que hay que hacer (LITERAL, sin explorar)
1. Worktree: /home/user/solidcraft-wt/issue-5857 ya existe. Trae el head del PR. Si no, crealo con:
   git -C /home/user/solidcraft fetch origin
   git -C /home/user/solidcraft worktree add /home/user/solidcraft-wt/issue-5857 -b fix/issue-5857-name-inside-parens fork/fix/issue-5857-name-inside-parens
2. Abrir crates/doc/src/naming.rs y ver face_name_end (cerca de la linea 378-384). Hoy hace:
   - `let rest = &s[at..];` con `at` incrementado de a UN BYTE (`at += 1` en las lineas 394, 399, 407, 412).
   Eso corta un `str` UTF-8 por la mitad y hace panic.
3. EL FIX: recorrer la cadena con `char_indices()` en vez de avanzar de a un byte, y NO cortar un `str` por la mitad.
   - La funcion DEBE seguir devolviendo un indice de BYTE valido (quien la llama la usa para cortar), pero ese indice tiene que caer en un limite de caracter.
   - Concretamente: cuando busques el delimitador (':' o '|'), avanzá sobre los bytes hasta el delimitador y guardá ese indice; los caracteres multibyte se saltean enteros.
   - Reemplazar todos los `at += 1` por avance seguro.
4. EL TEST (RED primero): en el archivo de tests EXISTENTE del area de naming (NO crees un archivo de test nuevo: AGENTS.md:24 lo prohibe). Buscar el modulo de tests en crates/doc/src/naming.rs o el archivo de tests de naming que ya exista.
   - Test: un nombre con un curve id NO-ASCII dentro de un blend edge, por ejemplo `F5:blend(F2:side:u66f2|F2:top)`.
   - Debe PANIQUEAR antes del fix y NO panicear despues. El assert es que face_name_end devuelve Ok/None con el indice correcto y que el nombre reconstruido es identico.
   - Nombre del test: test_face_name_end_handles_non_ascii_curve_id
5. LA NOTA DE FORMATO PENDIENTE: el maintainer pide la nota. Ya existe el directorio crates/doc/src/format/pending/ con README.md y fillet-turn.rs.
   - Crear crates/doc/src/format/pending/nested-face-name.rs siguiendo EXACTAMENTE el formato de los archivos que ya estan ahi (misma estructura, mismos comentarios, mismo estilo de doc).
   - Leer crates/doc/src/format/pending/README.md primero y seguir lo que dice.
6. Correr el test dirigido:
   cd /home/user/solidcraft-wt/issue-5857
   CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-loop/targets/slot-5857 CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 nice -n 19 cargo test -p solidcraft-doc face_name_end --lib
   Si el build se pasa de 4 GiB de RAM, no es fallo tuyo: la wave tiene slots. En ese caso deja el codigo commiteado y reportalo.
7. Commit: `fix: name a nested face without splitting a UTF-8 character`
8. Push SOLO al fork:
   git push fork HEAD:fix/issue-5857-name-inside-parens
   Verificar con `git remote -v` que 'fork' = vdirienzo/solidcraft. Si no existe ese remote, NO lo crees: reporta y listo.
9. NO abras PR nuevo (el PR #11359 ya existe). NO toques origin. NO toques otro worktree. NO toques crates/kernel.
10. Ademas, si te queda tiempo, el hallazgo de CodeRabbit en crates/doc/src/history_names.rs:560 (canonicalizar nombres legacy en matches_read antes de los chequeos Piece/alias/synonym/Stem) es un SEPARADO commit: `fix: canonicalize legacy names before the piece checks`. NO lo mezcles con el fix del panic: son dos commits.

## Entrega
- SHA del commit del fix del panic
- SHA del commit de la nota de formato (si lo hiciste)
- SHA del commit de CodeRabbit (si lo hiciste)
- La salida del test dirigido (PASS/FAIL y el nombre del test)
- Si el gate local lo corriste: el veredicto. NO corras el gate entero (40 min): lo corre la wave.
